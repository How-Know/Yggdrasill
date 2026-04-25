import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Thin client for the gateway's Stage-2 endpoints:
/// - POST `/textbook/vlm/extract-answers` — per-page VLM extraction.
/// - POST `/textbook/answers/batch-upsert` — persists 1:1 matched rows into
///   the `textbook_problem_answers` sidecar table.
///
/// Kept separate from `TextbookVlmTestService` (which drives the Stage-1
/// detector) so each stage can evolve its prompts/schemas independently.
class TextbookVlmAnswerService {
  TextbookVlmAnswerService({
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

  /// Runs VLM answer-extraction on a single answer-PDF page image.
  ///
  /// [expectedNumbers] lets the prompt reason over the exact set of
  /// Stage-1 문항번호 the caller wants answers for. Pass `null` to extract
  /// every number that shows up on the page.
  Future<TextbookVlmAnswerPageResult> extractAnswersOnPage({
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
      _uri('/textbook/vlm/extract-answers'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    final json = _decode(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300 || json['ok'] != true) {
      throw Exception(
        'vlm_extract_answers_failed(${res.statusCode}): '
        '${json['error'] ?? json['message'] ?? res.body}',
      );
    }
    return TextbookVlmAnswerPageResult.fromMap(json);
  }

  /// Upserts a batch of (crop_id → answer) rows into the Stage-2 sidecar.
  ///
  /// Each entry must carry a `crop_id` (FK to `textbook_problem_crops.id`);
  /// the gateway keys the upsert on that column.
  Future<int> batchUpsertAnswers({
    required String academyId,
    required List<TextbookAnswerUpload> answers,
  }) async {
    if (answers.isEmpty) return 0;
    final body = <String, dynamic>{
      'academy_id': academyId,
      'answers': answers.map((a) => a.toJson()).toList(),
    };
    final res = await _http.post(
      _uri('/textbook/answers/batch-upsert'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    final json = _decode(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300 || json['ok'] != true) {
      throw Exception(
        'answers_batch_upsert_failed(${res.statusCode}): '
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

/// One row returned by the Stage-2 VLM per-page extractor.
class TextbookVlmAnswerItem {
  const TextbookVlmAnswerItem({
    required this.problemNumber,
    required this.kind,
    required this.answerText,
    required this.answerLatex2d,
    this.bbox,
  });

  final String problemNumber;

  /// 'objective' | 'subjective'.
  final String kind;

  /// Canonical form: 객관식은 "①" 같은 원문자, 주관식은 1D LaTeX 원문.
  final String answerText;

  /// Optional 2D render LaTeX (주관식 전용). 객관식은 빈 문자열.
  final String answerLatex2d;

  /// Normalized [ymin, xmin, ymax, xmax] in 0..1000, if the VLM returned one.
  final List<int>? bbox;

  bool get isObjective => kind == 'objective';
  bool get isSubjective => kind == 'subjective';

  factory TextbookVlmAnswerItem.fromMap(Map<String, dynamic> map) {
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

    final kindRaw = '${map['kind'] ?? ''}'.toLowerCase();
    return TextbookVlmAnswerItem(
      problemNumber: '${map['problem_number'] ?? ''}'.trim(),
      kind: kindRaw == 'objective' ? 'objective' : 'subjective',
      answerText: '${map['answer_text'] ?? ''}',
      answerLatex2d: '${map['answer_latex_2d'] ?? ''}',
      bbox: parseBbox(map['bbox']),
    );
  }
}

/// Response of `/textbook/vlm/extract-answers`.
class TextbookVlmAnswerPageResult {
  const TextbookVlmAnswerPageResult({
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
  final List<TextbookVlmAnswerItem> items;
  final String notes;
  final int elapsedMs;
  final String model;

  factory TextbookVlmAnswerPageResult.fromMap(Map<String, dynamic> map) {
    int asInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('$v') ?? 0;
    }

    final rawItems = (map['items'] as List?) ?? const [];
    final parsed = <TextbookVlmAnswerItem>[];
    for (final r in rawItems) {
      if (r is Map) {
        parsed.add(TextbookVlmAnswerItem.fromMap(
          r.map((k, dynamic v) => MapEntry('$k', v)),
        ));
      }
    }
    return TextbookVlmAnswerPageResult(
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

/// Payload for a single row in `/textbook/answers/batch-upsert`.
class TextbookAnswerUpload {
  const TextbookAnswerUpload({
    required this.cropId,
    required this.answerKind,
    required this.answerText,
    this.answerLatex2d,
    this.answerSource = 'vlm',
    this.rawPage,
    this.displayPage,
    this.bbox1k,
    this.note,
  });

  final String cropId;
  final String answerKind;
  final String answerText;
  final String? answerLatex2d;
  final String answerSource;
  final int? rawPage;
  final int? displayPage;
  final List<int>? bbox1k;
  final String? note;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'crop_id': cropId,
        'answer_kind': answerKind,
        'answer_text': answerText,
        if (answerLatex2d != null) 'answer_latex_2d': answerLatex2d,
        'answer_source': answerSource,
        if (rawPage != null) 'raw_page': rawPage,
        if (displayPage != null) 'display_page': displayPage,
        if (bbox1k != null) 'bbox_1k': bbox1k,
        if (note != null) 'note': note,
      };
}

/// Result of matching a batch of VLM answer items back to Stage-1 문항번호.
///
/// The Stage-2 UI consumes this: [matched] drives the main row renderer,
/// [missing] drives a "VLM이 이 번호를 찾지 못했어요" warning block, and
/// [unexpected] flags answers the VLM returned but Stage-1 never registered
/// (usually typos like "0001" vs "001").
class TextbookAnswerMatchReport {
  TextbookAnswerMatchReport({
    required this.matched,
    required this.missing,
    required this.unexpected,
  });

  final Map<String, TextbookVlmAnswerItem> matched;
  final List<String> missing;
  final List<TextbookVlmAnswerItem> unexpected;

  /// [expectedNumbers] are the Stage-1 문항번호 strings (same case/shape the
  /// UI hands the service). [items] are the flat list of VLM results across
  /// all pages.
  static TextbookAnswerMatchReport match({
    required List<String> expectedNumbers,
    required List<TextbookVlmAnswerItem> items,
  }) {
    final expectedSet = <String>{
      for (final n in expectedNumbers)
        if (n.trim().isNotEmpty) n.trim(),
    };
    final byNumber = <String, TextbookVlmAnswerItem>{};
    final unexpected = <TextbookVlmAnswerItem>[];
    for (final it in items) {
      final key = it.problemNumber.trim();
      if (key.isEmpty) continue;
      if (!expectedSet.contains(key)) {
        unexpected.add(it);
        continue;
      }
      // Keep the first non-empty answer; later duplicates win only if the
      // prior entry had an empty answer_text.
      final prev = byNumber[key];
      if (prev == null || prev.answerText.trim().isEmpty) {
        byNumber[key] = it;
      }
    }
    final missing = <String>[
      for (final n in expectedSet)
        if (!byNumber.containsKey(n) ||
            byNumber[n]!.answerText.trim().isEmpty)
          n,
    ];
    return TextbookAnswerMatchReport(
      matched: byNumber,
      missing: missing,
      unexpected: unexpected,
    );
  }
}
