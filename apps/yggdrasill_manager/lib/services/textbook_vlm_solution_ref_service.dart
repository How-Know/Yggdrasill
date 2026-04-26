import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Stage-3 client — talks to:
/// - POST `/textbook/vlm/detect-solution-refs`  — per-page bbox detection.
/// - POST `/textbook/solution-refs/batch-upsert` — writes
///   `textbook_problem_solution_refs` rows keyed by `crop_id`.
class TextbookVlmSolutionRefService {
  TextbookVlmSolutionRefService({
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
    final out = <String, String>{'Content-Type': 'application/json'};
    if (_gatewayApiKey.isNotEmpty) {
      out['x-api-key'] = _gatewayApiKey;
    }
    return out;
  }

  Future<TextbookVlmSolutionRefPageResult> detectOnPage({
    required Uint8List imageBytes,
    required int rawPage,
    required String academyId,
    required String bookId,
    required String gradeLabel,
    List<String>? expectedNumbers,
    String mimeType = 'image/png',
  }) async {
    final body = <String, dynamic>{
      'image_base64': base64Encode(imageBytes),
      'mime_type': mimeType,
      'raw_page': rawPage,
      'academy_id': academyId,
      'book_id': bookId,
      'grade_label': gradeLabel,
      if (expectedNumbers != null && expectedNumbers.isNotEmpty)
        'expected_numbers': expectedNumbers,
    };
    final res = await _http.post(
      _uri('/textbook/vlm/detect-solution-refs'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    final json = _decode(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300 || json['ok'] != true) {
      final details = <String>[
        if (json['error'] != null) '${json['error']}',
        if (json['message'] != null) '${json['message']}',
        if (json['fallback_message'] != null)
          'fallback=${json['fallback_message']}',
      ];
      throw Exception(
        'vlm_detect_solution_refs_failed(${res.statusCode}): '
        '${details.isEmpty ? res.body : details.join(' / ')}',
      );
    }
    return TextbookVlmSolutionRefPageResult.fromMap(json);
  }

  Future<int> batchUpsertSolutionRefs({
    required String academyId,
    required List<TextbookSolutionRefUpload> refs,
  }) async {
    if (refs.isEmpty) return 0;
    final body = <String, dynamic>{
      'academy_id': academyId,
      'solution_refs': refs.map((r) => r.toJson()).toList(),
    };
    final res = await _http.post(
      _uri('/textbook/solution-refs/batch-upsert'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    final json = _decode(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300 || json['ok'] != true) {
      throw Exception(
        'solution_refs_batch_upsert_failed(${res.statusCode}): '
        '${json['error'] ?? json['message'] ?? res.body}',
      );
    }
    final upserted = json['upserted'];
    if (upserted is int) return upserted;
    if (upserted is num) return upserted.toInt();
    return int.tryParse('$upserted') ?? 0;
  }

  Map<String, dynamic> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((k, dynamic v) => MapEntry('$k', v));
      }
    } catch (_) {}
    return <String, dynamic>{};
  }
}

class TextbookVlmSolutionRefItem {
  const TextbookVlmSolutionRefItem({
    required this.problemNumber,
    required this.numberRegion1k,
    this.contentRegion1k,
  });

  final String problemNumber;

  /// [ymin, xmin, ymax, xmax] in 0..1000 — bbox of the 문항 번호 글자.
  final List<int> numberRegion1k;

  /// Optional [ymin, xmin, ymax, xmax] in 0..1000 — full 해설 블록 영역.
  final List<int>? contentRegion1k;

  factory TextbookVlmSolutionRefItem.fromMap(Map<String, dynamic> map) {
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

    final num1k = parseBbox(map['number_region']);
    return TextbookVlmSolutionRefItem(
      problemNumber: '${map['problem_number'] ?? ''}'.trim(),
      numberRegion1k: num1k ?? const [0, 0, 0, 0],
      contentRegion1k: parseBbox(map['content_region']),
    );
  }
}

class TextbookVlmSolutionRefPageResult {
  const TextbookVlmSolutionRefPageResult({
    required this.rawPage,
    required this.displayPage,
    required this.pageOffset,
    required this.pageOffsetFound,
    required this.items,
    required this.notes,
    required this.elapsedMs,
    required this.model,
  });

  final int rawPage;
  final int displayPage;
  final int pageOffset;
  final bool pageOffsetFound;
  final List<TextbookVlmSolutionRefItem> items;
  final String notes;
  final int elapsedMs;
  final String model;

  factory TextbookVlmSolutionRefPageResult.fromMap(Map<String, dynamic> map) {
    int asInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('$v') ?? 0;
    }

    final rawItems = (map['items'] as List?) ?? const [];
    final parsed = <TextbookVlmSolutionRefItem>[];
    for (final r in rawItems) {
      if (r is Map) {
        parsed.add(TextbookVlmSolutionRefItem.fromMap(
          r.map((k, dynamic v) => MapEntry('$k', v)),
        ));
      }
    }
    return TextbookVlmSolutionRefPageResult(
      rawPage: asInt(map['raw_page']),
      displayPage: asInt(map['display_page']),
      pageOffset: asInt(map['page_offset']),
      pageOffsetFound: map['page_offset_found'] == true,
      items: parsed,
      notes: '${map['notes'] ?? ''}',
      elapsedMs: asInt(map['elapsed_ms']),
      model: '${map['model'] ?? ''}',
    );
  }
}

class TextbookSolutionRefUpload {
  const TextbookSolutionRefUpload({
    required this.cropId,
    required this.rawPage,
    required this.numberRegion1k,
    this.displayPage,
    this.contentRegion1k,
    this.source = 'vlm',
  });

  final String cropId;
  final int rawPage;
  final int? displayPage;
  final List<int> numberRegion1k;
  final List<int>? contentRegion1k;

  /// 'vlm' | 'manual'
  final String source;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'crop_id': cropId,
        'raw_page': rawPage,
        if (displayPage != null) 'display_page': displayPage,
        'number_region_1k': numberRegion1k,
        if (contentRegion1k != null) 'content_region_1k': contentRegion1k,
        'source': source,
      };
}

/// Matches a batch of VLM items against the expected Stage-1 문항번호 set.
class TextbookSolutionRefMatchReport {
  TextbookSolutionRefMatchReport({
    required this.matched,
    required this.missing,
    required this.unexpected,
  });

  final Map<String, TextbookVlmSolutionRefItem> matched;
  final List<String> missing;
  final List<TextbookVlmSolutionRefItem> unexpected;

  static TextbookSolutionRefMatchReport match({
    required List<String> expectedNumbers,
    required List<TextbookVlmSolutionRefItem> items,
  }) {
    final expectedSet = <String>{
      for (final n in expectedNumbers)
        if (n.trim().isNotEmpty) n.trim(),
    };
    final byNumber = <String, TextbookVlmSolutionRefItem>{};
    final unexpected = <TextbookVlmSolutionRefItem>[];
    for (final it in items) {
      final key = it.problemNumber.trim();
      if (key.isEmpty) continue;
      if (!expectedSet.contains(key)) {
        unexpected.add(it);
        continue;
      }
      byNumber.putIfAbsent(key, () => it);
    }
    final missing = <String>[
      for (final n in expectedSet)
        if (!byNumber.containsKey(n)) n,
    ];
    return TextbookSolutionRefMatchReport(
      matched: byNumber,
      missing: missing,
      unexpected: unexpected,
    );
  }
}
