// Client for `POST /textbook/crops/batch-upsert` on the gateway.
//
// The manager app produces hi-res PNG crops (one per problem) and the
// bounding boxes/coordinates the VLM returned. We chunk them into modest
// batches, base64-encode the bytes, compute a sha256 hash for dedup, and
// let the gateway upload to Supabase Storage + upsert the companion row in
// `textbook_problem_crops` in a single round-trip.
//
// Design notes:
// - Flutter -> gateway payloads are capped at `maxCropsPerBatch` so we
//   never build a single 25MB+ JSON string.
// - We include the VLM detection snapshot (bbox_1k / item_region_1k /
//   section / is_set_header / …) so later HWPX matching can be done
//   entirely from the stored row — no need to rerun the VLM.
// - `onProgress` reports processed item counts so the UI can render a
//   determinate progress bar across multiple HTTP round-trips.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Single crop entry. Keep the fields aligned with what
/// `textbook_problem_crops` stores — the gateway performs a direct upsert
/// using the same names.
///
/// [pngBytes] is optional: omit (or pass `null`) when uploading in
/// `regions_only` mode (see [TextbookCropUploader.uploadCropBatch]). In
/// that mode we only persist the VLM-detected coordinates so the student
/// app can do tap-to-identify without ever downloading a crop image.
class TextbookCropUploadItem {
  const TextbookCropUploadItem({
    required this.rawPage,
    this.displayPage,
    this.section,
    required this.problemNumber,
    this.label = '',
    this.isSetHeader = false,
    this.setFrom,
    this.setTo,
    this.contentGroupKind = 'none',
    this.contentGroupLabel = '',
    this.contentGroupTitle = '',
    this.contentGroupOrder,
    this.columnIndex,
    this.bbox1k,
    this.itemRegion1k,
    this.pngBytes,
    this.cropRectPx,
    this.paddingPx,
    this.cropLongEdgePx,
    this.deskewAngleDeg,
    this.widthPx,
    this.heightPx,
  });

  final int rawPage;
  final int? displayPage;
  final String? section;
  final String problemNumber;
  final String label;
  final bool isSetHeader;
  final int? setFrom;
  final int? setTo;
  final String contentGroupKind;
  final String contentGroupLabel;
  final String contentGroupTitle;
  final int? contentGroupOrder;
  final int? columnIndex;
  final List<int>? bbox1k; // [ymin, xmin, ymax, xmax] on 0..1000
  final List<int>? itemRegion1k;

  /// Crop image bytes. `null` when the caller is in `regions_only` mode.
  final Uint8List? pngBytes;
  final List<int>? cropRectPx; // [x, y, w, h] in source
  final int? paddingPx;
  final int? cropLongEdgePx;
  final double? deskewAngleDeg;
  final int? widthPx;
  final int? heightPx;
}

class TextbookCropBatchResult {
  const TextbookCropBatchResult({
    required this.upserted,
    required this.bucket,
    required this.rows,
  });

  final int upserted;
  final String bucket;
  final List<Map<String, dynamic>> rows;
}

class TextbookCropUploader {
  TextbookCropUploader({
    http.Client? httpClient,
    String? gatewayBaseUrl,
    String? gatewayApiKey,
    int? maxCropsPerBatch,
  })  : _http = httpClient ?? http.Client(),
        _gatewayBaseUrl = _resolveGatewayUrl(gatewayBaseUrl),
        _gatewayApiKey = (gatewayApiKey ??
                const String.fromEnvironment('PB_GATEWAY_API_KEY',
                    defaultValue: ''))
            .trim(),
        _maxCropsPerBatch = maxCropsPerBatch ?? 40;

  static String _resolveGatewayUrl(String? explicit) {
    if (explicit != null && explicit.trim().isNotEmpty) {
      return explicit.trim();
    }
    const dartDefine =
        String.fromEnvironment('PB_GATEWAY_URL', defaultValue: '');
    if (dartDefine.isNotEmpty) return dartDefine;
    try {
      final envValue = Platform.environment['PB_GATEWAY_URL'] ?? '';
      if (envValue.isNotEmpty) return envValue;
    } catch (_) {}
    return 'http://localhost:8787';
  }

  final http.Client _http;
  final String _gatewayBaseUrl;
  final String _gatewayApiKey;

  /// Server-side hard limit is 120 rows; we default lower so we never hit
  /// the Node `http` default body limits on slower machines.
  final int _maxCropsPerBatch;

  Map<String, String> _headers() {
    final h = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
    };
    if (_gatewayApiKey.isNotEmpty) {
      h['x-api-key'] = _gatewayApiKey;
    }
    return h;
  }

  Uri _uri(String path) {
    final base = _gatewayBaseUrl.endsWith('/')
        ? _gatewayBaseUrl.substring(0, _gatewayBaseUrl.length - 1)
        : _gatewayBaseUrl;
    return Uri.parse('$base${path.startsWith('/') ? path : '/$path'}');
  }

  /// Uploads a list of crops for one 소단원 (A/B/C) in one or more HTTP
  /// round-trips. Returns the aggregate result.
  ///
  /// When [regionsOnly] is true the client skips the PNG payload entirely
  /// and the gateway persists only the coordinate row. This is the fast
  /// path we use now that the student app does tap-to-identify from
  /// `item_region_1k` directly instead of downloading crop images.
  Future<TextbookCropBatchResult> uploadCropBatch({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required int bigOrder,
    required int midOrder,
    required String subKey, // 'A' | 'B' | 'C'
    String? bigName,
    String? midName,
    required List<TextbookCropUploadItem> items,
    void Function(int processed, int total)? onProgress,
    bool regionsOnly = false,
  }) async {
    if (items.isEmpty) {
      return const TextbookCropBatchResult(
        upserted: 0,
        bucket: 'textbook-crops',
        rows: <Map<String, dynamic>>[],
      );
    }
    int processed = 0;
    int totalUpserted = 0;
    String bucket = 'textbook-crops';
    final aggregateRows = <Map<String, dynamic>>[];

    for (var start = 0; start < items.length; start += _maxCropsPerBatch) {
      final end = (start + _maxCropsPerBatch).clamp(0, items.length);
      final chunk = items.sublist(start, end);
      final body = <String, dynamic>{
        'academy_id': academyId,
        'book_id': bookId,
        'grade_label': gradeLabel,
        'big_order': bigOrder,
        'mid_order': midOrder,
        'sub_key': subKey,
        if (bigName != null && bigName.isNotEmpty) 'big_name': bigName,
        if (midName != null && midName.isNotEmpty) 'mid_name': midName,
        if (regionsOnly) 'regions_only': true,
        'crops': chunk
            .map((item) => _itemToMap(item, regionsOnly: regionsOnly))
            .toList(),
      };
      final res = await _http.post(
        _uri('/textbook/crops/batch-upsert'),
        headers: _headers(),
        body: jsonEncode(body),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception(
          'textbook_crops_upsert_failed(${res.statusCode}): ${res.body}',
        );
      }
      Map<String, dynamic> json;
      try {
        final decoded = jsonDecode(res.body);
        json = decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : <String, dynamic>{};
      } catch (_) {
        json = <String, dynamic>{};
      }
      if (json['ok'] != true) {
        throw Exception(
            'textbook_crops_upsert_error: ${json['error'] ?? res.body}');
      }
      totalUpserted += _asInt(json['upserted']) ?? chunk.length;
      bucket = (json['bucket'] as String?) ?? bucket;
      final rows = json['rows'];
      if (rows is List) {
        for (final r in rows) {
          if (r is Map) aggregateRows.add(Map<String, dynamic>.from(r));
        }
      }
      processed = end;
      onProgress?.call(processed, items.length);
    }

    return TextbookCropBatchResult(
      upserted: totalUpserted,
      bucket: bucket,
      rows: aggregateRows,
    );
  }

  Map<String, dynamic> _itemToMap(
    TextbookCropUploadItem item, {
    required bool regionsOnly,
  }) {
    final map = <String, dynamic>{
      'raw_page': item.rawPage,
      if (item.displayPage != null) 'display_page': item.displayPage,
      if (item.section != null && item.section!.isNotEmpty)
        'section': item.section,
      'problem_number': item.problemNumber,
      'label': item.label,
      'is_set_header': item.isSetHeader,
      if (item.setFrom != null) 'set_from': item.setFrom,
      if (item.setTo != null) 'set_to': item.setTo,
      'content_group_kind': item.contentGroupKind,
      if (item.contentGroupLabel.isNotEmpty)
        'content_group_label': item.contentGroupLabel,
      if (item.contentGroupTitle.isNotEmpty)
        'content_group_title': item.contentGroupTitle,
      if (item.contentGroupOrder != null)
        'content_group_order': item.contentGroupOrder,
      if (item.columnIndex != null) 'column_index': item.columnIndex,
      if (item.bbox1k != null) 'bbox_1k': item.bbox1k,
      if (item.itemRegion1k != null) 'item_region_1k': item.itemRegion1k,
      if (item.cropRectPx != null) 'crop_rect_px': item.cropRectPx,
      if (item.paddingPx != null) 'padding_px': item.paddingPx,
      if (item.cropLongEdgePx != null) 'crop_long_edge_px': item.cropLongEdgePx,
      if (item.deskewAngleDeg != null) 'deskew_angle_deg': item.deskewAngleDeg,
      if (item.widthPx != null) 'width_px': item.widthPx,
      if (item.heightPx != null) 'height_px': item.heightPx,
    };
    final bytes = item.pngBytes;
    if (!regionsOnly && bytes != null && bytes.isNotEmpty) {
      map['file_size_bytes'] = bytes.lengthInBytes;
      map['content_hash'] = sha256.convert(bytes).toString();
      map['png_base64'] = base64Encode(bytes);
    }
    return map;
  }

  /// Fire a stubbed call to the answer-key VLM endpoint. Returns the gateway
  /// response as a map so the UI can surface "not implemented" without
  /// crashing on an exception.
  Future<Map<String, dynamic>> requestAnswerExtraction({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    Map<String, dynamic>? extras,
  }) async {
    final body = <String, dynamic>{
      'academy_id': academyId,
      'book_id': bookId,
      'grade_label': gradeLabel,
      if (extras != null) ...extras,
    };
    final res = await _http.post(
      _uri('/textbook/vlm/extract-answers'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map) {
        return <String, dynamic>{
          'status_code': res.statusCode,
          ...Map<String, dynamic>.from(decoded),
        };
      }
    } catch (_) {}
    return <String, dynamic>{
      'status_code': res.statusCode,
      'ok': false,
      'error': 'invalid_response_body',
    };
  }
}

int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}
