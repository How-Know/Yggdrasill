import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Thin client for the gateway's `/textbook/vlm/detect-problems` endpoint.
///
/// Deliberately kept in its own file (not merged into `TextbookPdfService`)
/// so the dual-track migration surface stays untouched while we iterate on
/// the VLM test harness. The migration pane already reuses the upload path
/// from `TextbookPdfService`; this detection service is opt-in and only
/// referenced from the new "VLM 테스트" action row in the migration pane.
///
/// SECURITY TODO (pre-release): this uses the shared `PB_GATEWAY_API_KEY`.
/// Before we let end users trigger VLM detection, gate it behind per-user
/// JWT + academy membership just like the rest of `/textbook/*`.
class TextbookVlmTestService {
  TextbookVlmTestService({
    http.Client? httpClient,
    String? gatewayBaseUrl,
    String? gatewayApiKey,
  })  : _http = httpClient ?? http.Client(),
        _gatewayBaseUrl = _resolveGatewayUrl(gatewayBaseUrl),
        _gatewayApiKey = (gatewayApiKey ??
                const String.fromEnvironment('PB_GATEWAY_API_KEY',
                    defaultValue: ''))
            .trim();

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

  Uri _uri(String path) {
    final base = _gatewayBaseUrl.endsWith('/')
        ? _gatewayBaseUrl.substring(0, _gatewayBaseUrl.length - 1)
        : _gatewayBaseUrl;
    final p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$p');
  }

  Map<String, String> _headers() {
    final out = <String, String>{
      'Content-Type': 'application/json',
    };
    if (_gatewayApiKey.isNotEmpty) {
      out['x-api-key'] = _gatewayApiKey;
    }
    return out;
  }

  /// Sends a single rendered PDF page to the gateway for VLM analysis.
  ///
  /// [imageBytes] should be a PNG (or JPEG/WebP) of the rendered page at a
  /// resolution high enough for problem numbers to be legible — we recommend
  /// rendering at least 1200 px on the long edge.
  ///
  /// [rawPage] is the 1-based PDF page index (not the book-face page).
  /// The gateway looks up `textbook_metadata.page_offset` for
  /// `(academyId, bookId, gradeLabel)` and returns `display_page` so the
  /// caller does not need to recompute.
  Future<TextbookVlmDetectResult> detectProblemsOnPage({
    required Uint8List imageBytes,
    required int rawPage,
    required String academyId,
    required String bookId,
    required String gradeLabel,
    String mimeType = 'image/png',
  }) async {
    final body = <String, dynamic>{
      'image_base64': base64Encode(imageBytes),
      'mime_type': mimeType,
      'raw_page': rawPage,
      'academy_id': academyId,
      'book_id': bookId,
      'grade_label': gradeLabel,
    };
    final res = await _http.post(
      _uri('/textbook/vlm/detect-problems'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(res.body);
      json = decoded is Map<String, dynamic>
          ? decoded
          : (decoded is Map
              ? decoded.map((k, dynamic v) => MapEntry('$k', v))
              : <String, dynamic>{});
    } catch (_) {
      json = <String, dynamic>{};
    }
    if (res.statusCode < 200 || res.statusCode >= 300 || json['ok'] != true) {
      throw Exception(
        'vlm_detect_failed(${res.statusCode}): '
        '${json['error'] ?? json['message'] ?? res.body}',
      );
    }
    return TextbookVlmDetectResult.fromMap(json);
  }
}

/// Parsed response of `/textbook/vlm/detect-problems`.
class TextbookVlmDetectResult {
  const TextbookVlmDetectResult({
    required this.rawPage,
    required this.displayPage,
    required this.pageOffset,
    required this.pageOffsetFound,
    required this.section,
    required this.pageKind,
    required this.layout,
    required this.items,
    required this.notes,
    required this.model,
    required this.elapsedMs,
    required this.finishReason,
    this.usage,
  });

  final int rawPage;
  final int displayPage;
  final int pageOffset;
  final bool pageOffsetFound;

  /// One of 'basic_drill' | 'type_practice' | 'mastery' | 'unknown'.
  /// Maps to the Korean textbook unit structure
  /// (기본다잡기 / 유형뽀개기 / 만점도전하기) so the UI can group results.
  final String section;

  /// 'problem_page' | 'concept_page' | 'mixed' | 'unknown'.
  /// Concept-only A pages are intentionally returned with zero items so the
  /// UI can mark the page without persisting a fake problem region.
  final String pageKind;

  /// 'two_column' | 'one_column' | 'unknown'
  final String layout;
  final List<TextbookVlmItem> items;
  final String notes;
  final String model;
  final int elapsedMs;
  final String finishReason;
  final Map<String, dynamic>? usage;

  factory TextbookVlmDetectResult.fromMap(Map<String, dynamic> map) {
    int asInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('$v') ?? 0;
    }

    final rawItems = (map['items'] as List?) ?? const [];
    final parsed = <TextbookVlmItem>[];
    for (final r in rawItems) {
      if (r is Map) {
        parsed.add(
          TextbookVlmItem.fromMap(r.map((k, dynamic v) => MapEntry('$k', v))),
        );
      }
    }

    final sec = '${map['section'] ?? 'unknown'}';
    const allowedSections = {
      'basic_drill',
      'type_practice',
      'mastery',
      'unknown',
    };

    return TextbookVlmDetectResult(
      rawPage: asInt(map['raw_page']),
      displayPage: asInt(map['display_page']),
      pageOffset: asInt(map['page_offset']),
      pageOffsetFound: map['page_offset_found'] == true,
      section: allowedSections.contains(sec) ? sec : 'unknown',
      pageKind: '${map['page_kind'] ?? 'unknown'}',
      layout: '${map['layout'] ?? 'unknown'}',
      items: parsed,
      notes: '${map['notes'] ?? ''}',
      model: '${map['model'] ?? ''}',
      elapsedMs: asInt(map['elapsed_ms']),
      finishReason: '${map['finish_reason'] ?? ''}',
      usage: (map['usage'] is Map)
          ? (map['usage'] as Map).map((k, dynamic v) => MapEntry('$k', v))
          : null,
    );
  }
}

class TextbookVlmItem {
  const TextbookVlmItem({
    required this.number,
    required this.label,
    required this.isSetHeader,
    required this.setFrom,
    required this.setTo,
    required this.column,
    required this.bbox,
    required this.itemRegion,
  });

  final String number;
  final String label;
  final bool isSetHeader;
  final int? setFrom;
  final int? setTo;

  /// 1 = left column, 2 = right column, null = single-column or unknown.
  final int? column;

  /// Normalized [ymin, xmin, ymax, xmax] in 0..1000. Minimal box around the
  /// problem *number* glyph itself. null if bbox missing.
  final List<int>? bbox;

  /// Normalized [ymin, xmin, ymax, xmax] in 0..1000. Full region occupied by
  /// the problem on the page (stem + choices + figures). null if the VLM did
  /// not return one or rejected it.
  final List<int>? itemRegion;

  factory TextbookVlmItem.fromMap(Map<String, dynamic> map) {
    int? asIntN(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('$v');
    }

    List<int>? parseBbox(dynamic raw) {
      if (raw is! List || raw.length != 4) return null;
      final out = <int>[];
      for (final v in raw) {
        final n = asIntN(v);
        if (n == null) return null;
        out.add(n);
      }
      return out;
    }

    final setRangeRaw = map['set_range'];
    int? from;
    int? to;
    if (setRangeRaw is Map) {
      from = asIntN(setRangeRaw['from']);
      to = asIntN(setRangeRaw['to']);
    }

    return TextbookVlmItem(
      number: '${map['number'] ?? ''}',
      label: '${map['label'] ?? ''}',
      isSetHeader: map['is_set_header'] == true,
      setFrom: from,
      setTo: to,
      column: asIntN(map['column']),
      bbox: parseBbox(map['bbox']),
      itemRegion: parseBbox(map['item_region']),
    );
  }
}
