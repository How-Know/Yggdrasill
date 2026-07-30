import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 답지에서 문항 하나를 특정하기 위해 VLM 에 넘기는 한 줄.
///
/// 번호만으로 충분한 시리즈(쎈/RPM/개념원리)는 [corner]·[bodyPage] 를 비운다.
class TextbookExpectedAnswer {
  const TextbookExpectedAnswer({
    required this.number,
    this.corner = '',
    this.bodyPage,
  });

  /// Stage 1 이 저장한 문항번호. VLM 도 이 문자열 그대로 돌려줘야 한다.
  final String number;

  /// 답지에 인쇄된 코너 이름 (예: "STEP1 쏙쏙 개념 익히기").
  final String corner;

  /// 답지 박스 오른쪽 위의 본문 페이지 배지 (예: P.109 → 109).
  final int? bodyPage;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'problem_number': number,
        if (corner.trim().isNotEmpty) 'corner': corner.trim(),
        if (bodyPage != null && bodyPage! > 0) 'page': bodyPage,
      };
}

/// 한 번의 VLM 호출에 실어 보낸 기대 문항 목록.
///
/// 번호를 Map 키로 쓰면 안 된다. 개념+유형은 코너마다, 소단원마다 번호가
/// 1번부터 다시 시작해서 한 중단원 안에 "1" 인 문항이 다섯 개까지 생긴다.
/// 실제로 1-1 교재에서 기대 82개가 번호키 43개로 뭉개졌고, 나머지 39개는
/// 정답이 영원히 비어 있었다.
///
/// 그래서 목록의 **위치**를 열쇠로 쓴다. 게이트웨이는 결과마다 우리가 보낸
/// 배열에서의 위치(`expected_index`)를 되돌려 주고, 못 되돌려 주면 번호로
/// 되짚는다. [positions] 는 이 호출에 담은 항목이 호출자의 전체 목록에서
/// 몇 번째였는지를 담는다(남은 항목만 골라 보내므로 호출마다 달라진다).
class TextbookExpectedAnswerBatch {
  TextbookExpectedAnswerBatch({
    required this.positions,
    required this.entries,
  }) : assert(positions.length == entries.length);

  /// 호출자의 전체 기대 목록에서의 위치.
  final List<int> positions;

  /// 이번 호출에 실제로 보낸 기대 문항.
  final List<TextbookExpectedAnswer> entries;

  bool get isEmpty => entries.isEmpty;

  List<String> get numbers => <String>[for (final e in entries) e.number];

  /// 결과 항목 하나가 가리키는 전체 목록 위치.
  ///
  /// [expectedIndex] 가 유효하면 그것만 믿는다. 없으면 번호로 찾고, 번호가
  /// 겹치는 항목이 여럿이면 **하나만** 집는다. 근거 없이 여러 크롭에 같은
  /// 정답을 붙이면 틀린 정답이 조용히 저장된다.
  List<int> resolve({
    required String detectedNumber,
    int expectedIndex = -1,
  }) {
    if (expectedIndex >= 0 && expectedIndex < positions.length) {
      return <int>[positions[expectedIndex]];
    }
    final key = textbookAnswerNumberKey(detectedNumber);
    if (key.isNotEmpty) {
      for (var i = 0; i < entries.length; i += 1) {
        if (textbookAnswerNumberKey(entries[i].number) == key) {
          return <int>[positions[i]];
        }
      }
    }
    // "1~5" 처럼 범위로 묶인 정답은 범위에 드는 기대 항목 전부에 붙는다.
    final range = _answerNumberRange(detectedNumber);
    if (range == null) return const <int>[];
    final out = <int>[];
    for (var i = 0; i < entries.length; i += 1) {
      final n = int.tryParse(textbookAnswerNumberKey(entries[i].number));
      if (n == null || n < range.$1 || n > range.$2) continue;
      out.add(positions[i]);
    }
    return out;
  }
}

/// 개념+유형 크롭의 section(카테고리) → 답지에 인쇄된 코너 이름.
const Map<String, String> _kConceptPlusAnswerCorners = <String, String>{
  'concept_check': '개념 확인',
  'essential_problem': '필수 문제',
  'step_drill': 'STEP1 쏙쏙 개념 익히기',
  'unit_drill': 'STEP2 탄탄 단원 다지기',
  'descriptive': 'STEP3 쓱쓱 서술형 완성하기',
  'extra_practice': '한번 더 연습',
};

/// 코너 이름을 붙일 수 있는 시리즈인지. 지금은 개념+유형만 해당한다.
bool textbookAnswerNeedsCorner(String seriesKey) =>
    seriesKey.trim().toLowerCase() == 'gaeyu';

/// 번호가 블록마다 1번부터 다시 시작하는 코너. 앱은 이 코너의 크롭에만
/// 본문 페이지를 접두어로 붙여 저장한다("14-1").
const Set<String> _kConceptPlusBlockScopedSections = <String>{
  'step_drill',
  'extra_practice',
};

/// 답지·해설에 **인쇄된 대로**의 번호로 되돌린다.
///
/// 쏙쏙·한번 더 연습은 블록마다 번호가 1번부터 다시 시작해서 앱이 본문
/// 페이지를 접두어로 붙여 "14-1" 로 저장한다. 하지만 답지에는 P.14 배지
/// 아래 "1" 로 인쇄돼 있다. 접두어를 붙인 채로 물어보면 모델이 "14-1 은
/// 이 지면에 없다" 며 그 박스를 통째로 건너뛴다(쏙쏙 6문항이 매번 빈 채로
/// 남았다). 어느 박스인지는 코너와 [bodyPage] 로 따로 알려주므로 번호는
/// 인쇄된 로컬 번호만 보낸다. 크롭 연결은 번호가 아니라 기대 목록의
/// 위치(expected_index)로 되짚으므로 접두어를 떼도 안전하다.
String _conceptPlusPrintedNumber({
  required String number,
  required String section,
  int? bodyPage,
}) {
  if (bodyPage == null) return number;
  if (!_kConceptPlusBlockScopedSections.contains(section.trim())) return number;
  final matched = RegExp(r'^(\d+)-(\d+)$').firstMatch(number.trim());
  if (matched == null) return number;
  if (int.tryParse(matched.group(1)!) != bodyPage) return number;
  return matched.group(2)!;
}

/// 크롭 한 건을 답지 조회용 기대 문항으로 바꾼다.
TextbookExpectedAnswer textbookExpectedAnswerFor({
  required String seriesKey,
  required String problemNumber,
  String section = '',
  int? displayPage,
}) {
  if (!textbookAnswerNeedsCorner(seriesKey)) {
    return TextbookExpectedAnswer(number: problemNumber);
  }
  final bodyPage = displayPage != null && displayPage > 0 ? displayPage : null;
  return TextbookExpectedAnswer(
    number: _conceptPlusPrintedNumber(
      number: problemNumber,
      section: section,
      bodyPage: bodyPage,
    ),
    corner: _kConceptPlusAnswerCorners[section.trim()] ?? '',
    bodyPage: bodyPage,
  );
}

String textbookAnswerNumberKey(String raw) {
  final input = raw.trim();
  if (input.isEmpty) return '';
  final numbers = RegExp(r'\d+')
      .allMatches(input)
      .map((m) {
        final n = int.tryParse(m.group(0) ?? '');
        return n == null ? '' : '$n';
      })
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
  if (numbers.isEmpty) return input.replaceAll(RegExp(r'\s+'), '');
  final isRange = RegExp(r'(\d+)\s*(?:~|-|–|—|〜)\s*(\d+)').hasMatch(input);
  if (isRange && numbers.length >= 2) return '${numbers[0]}-${numbers[1]}';
  // "개념확인105", "예제1" 처럼 한글 코너 이름이 번호의 일부인 개념+유형 문항은
  // 숫자만 남기면 같은 숫자를 쓰는 다른 코너 문항과 키가 겹친다. 게이트웨이
  // normalizeProblemNumberKey 와 같은 규칙으로 접두어를 유지한다.
  final compact = input.replaceAll(RegExp(r'\s+'), '');
  if (RegExp(r'^[가-힣]+\d').hasMatch(compact)) {
    return compact.replaceAllMapped(
      RegExp(r'\d+'),
      (m) => '${int.parse(m.group(0)!)}',
    );
  }
  return numbers.first;
}

(int, int)? _answerNumberRange(String raw) {
  final match = RegExp(r'^0*(\d+)\s*[~\-\u2013\u2014\u301c]\s*0*(\d+)$')
      .firstMatch(raw.trim());
  if (match == null) return null;
  final from = int.tryParse(match.group(1)!);
  final to = int.tryParse(match.group(2)!);
  if (from == null || to == null || from > to) return null;
  return (from, to);
}

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
  ///
  /// [expectedDetails] 는 번호에 코너 이름과 본문 페이지를 덧붙인 형태다.
  /// 개념+유형 답지는 코너마다 번호가 1번부터 다시 시작해서 번호만으로는
  /// 어느 박스의 몇 번인지 특정할 수 없다. 주어지면 이쪽을 보낸다.
  Future<TextbookVlmAnswerPageResult> extractAnswersOnPage({
    required Uint8List imageBytes,
    required int rawPage,
    required String academyId,
    required String bookId,
    required String gradeLabel,
    List<String>? expectedNumbers,
    List<TextbookExpectedAnswer>? expectedDetails,
    String seriesKey = '',
    String mimeType = 'image/png',
  }) async {
    final expected = expectedDetails != null && expectedDetails.isNotEmpty
        ? expectedDetails.map((e) => e.toJson()).toList()
        : (expectedNumbers != null && expectedNumbers.isNotEmpty
            ? expectedNumbers
            : null);
    final body = <String, dynamic>{
      'image_base64': base64Encode(imageBytes),
      'mime_type': mimeType,
      'raw_page': rawPage,
      'academy_id': academyId,
      'book_id': bookId,
      'grade_label': gradeLabel,
      if (seriesKey.trim().isNotEmpty) 'series': seriesKey.trim(),
      if (expected != null) 'expected_numbers': expected,
    };
    final res = await _http.post(
      _uri('/textbook/vlm/extract-answers'),
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
        'vlm_extract_answers_failed(${res.statusCode}): '
        '${details.isEmpty ? res.body : details.join(' / ')}',
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

  Future<int> syncAnswersToProblemBank({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required int bigOrder,
    required int midOrder,
    required String subKey,
  }) async {
    final body = <String, dynamic>{
      'academy_id': academyId,
      'book_id': bookId,
      'grade_label': gradeLabel,
      'big_order': bigOrder,
      'mid_order': midOrder,
      'sub_key': subKey,
    };
    final res = await _http.post(
      _uri('/textbook/answers/sync-pb'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    final json = _decode(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300 || json['ok'] != true) {
      throw Exception(
        'answers_sync_pb_failed(${res.statusCode}): '
        '${json['error'] ?? json['message'] ?? res.body}',
      );
    }
    final updated = json['updated_questions'];
    if (updated is int) return updated;
    if (updated is num) return updated.toInt();
    return int.tryParse('$updated') ?? 0;
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
    this.answerAssets = const <TextbookVlmAnswerAsset>[],
    this.bbox,
    this.expectedIndex = -1,
  });

  final String problemNumber;

  /// 게이트웨이가 특정한 기대 문항의 위치. 못 특정하면 -1.
  ///
  /// 같은 번호가 코너마다 다시 나오는 개념+유형에서 번호 대신 이 값으로
  /// 크롭을 찾는다. [TextbookExpectedAnswerBatch.resolve] 참고.
  final int expectedIndex;

  /// 'objective' | 'subjective' | 'image'.
  final String kind;

  /// Canonical form: 객관식은 "①" 같은 원문자, 주관식은 1D LaTeX 원문.
  final String answerText;

  /// Optional 2D render LaTeX (주관식 전용). 객관식은 빈 문자열.
  final String answerLatex2d;

  /// Image/table/grid assets the VLM marked inside [answerText].
  final List<TextbookVlmAnswerAsset> answerAssets;

  /// Normalized [ymin, xmin, ymax, xmax] in 0..1000, if the VLM returned one.
  final List<int>? bbox;

  bool get isObjective => kind == 'objective';
  bool get isSubjective => kind == 'subjective';
  bool get isImage => kind == 'image';

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

    String normalizeCompactFractions(String raw) {
      var out = raw;
      for (var i = 0; i < 4; i += 1) {
        final next = out
            .replaceAllMapped(
              RegExp(r'\\(?:dfrac|tfrac|frac)\s*\{([^{}]+)\}\s*\{([^{}]+)\}'),
              (m) => '\\frac{${m.group(1)!.trim()}}{${m.group(2)!.trim()}}',
            )
            .replaceAllMapped(
              RegExp(r'\\(?:dfrac|tfrac|frac)\s*\{([^{}]+)\}\s*([A-Za-z0-9])'),
              (m) => '\\frac{${m.group(1)!.trim()}}{${m.group(2)}}',
            )
            .replaceAllMapped(
              RegExp(r'\\(?:dfrac|tfrac|frac)\s*([A-Za-z0-9])\s*\{([^{}]+)\}'),
              (m) => '\\frac{${m.group(1)}}{${m.group(2)!.trim()}}',
            )
            .replaceAllMapped(
              RegExp(r'\\(?:dfrac|tfrac|frac)\s*([A-Za-z0-9])\s*([A-Za-z0-9])'),
              (m) => '\\frac{${m.group(1)}}{${m.group(2)}}',
            );
        if (next == out) break;
        out = next;
      }
      return out;
    }

    String stripLatexTextWrappers(String raw) {
      var out = raw;
      for (var i = 0; i < 6; i += 1) {
        final next = out
            .replaceAllMapped(
              RegExp(r'\\(?:text|mathrm)\s*\{([^{}]*)\}'),
              (m) => m.group(1) ?? '',
            )
            .replaceAll(RegExp(r'\\(?:textstyle|displaystyle)\b'), '');
        if (next == out) break;
        out = next;
      }
      return out.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    String normalizeAnswer(String raw) {
      return normalizeCompactFractions(stripLatexTextWrappers(raw))
          .replaceAll(
              RegExp(r'\(\s*image\s*\)', caseSensitive: false), '[image]')
          .replaceAll(
              RegExp(r'\[\s*image\s*\]', caseSensitive: false), '[image]')
          .trim();
    }

    List<TextbookVlmAnswerAsset> parseAssets(dynamic raw) {
      if (raw is! List) return const <TextbookVlmAnswerAsset>[];
      final out = <TextbookVlmAnswerAsset>[];
      for (final e in raw) {
        if (e is! Map) continue;
        final map = e.map((k, dynamic v) => MapEntry('$k', v));
        final bbox = parseBbox(map['bbox']);
        if (bbox == null) continue;
        out.add(TextbookVlmAnswerAsset(
          marker: '${map['marker'] ?? '[image]'}'.trim().isEmpty
              ? '[image]'
              : '${map['marker'] ?? '[image]'}'.trim(),
          assetType: '${map['asset_type'] ?? 'image'}'.trim().isEmpty
              ? 'image'
              : '${map['asset_type'] ?? 'image'}'.trim(),
          bbox: bbox,
        ));
      }
      return out;
    }

    String normalizeObjectiveChoiceText(String raw) {
      final parts = raw
          .trim()
          .split(RegExp(r'[/,，、\s]+'))
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty);
      final normalized = <String>[];
      for (final part in parts) {
        final compact = part.replaceAll(RegExp(r'\s+'), '');
        final mapped = const <String, String>{
          '1': '①',
          '①': '①',
          '⑴': '①',
          '(1)': '①',
          '2': '②',
          '②': '②',
          '⑵': '②',
          '(2)': '②',
          '3': '③',
          '③': '③',
          '⑶': '③',
          '(3)': '③',
          '4': '④',
          '④': '④',
          '⑷': '④',
          '(4)': '④',
          '5': '⑤',
          '⑤': '⑤',
          '⑸': '⑤',
          '(5)': '⑤',
        }[compact];
        if (mapped == null) return '';
        if (!normalized.contains(mapped)) normalized.add(mapped);
      }
      return normalized.join(', ');
    }

    var problemNumber = '${map['problem_number'] ?? ''}'.trim();
    var rawAnswerText = normalizeAnswer('${map['answer_text'] ?? ''}');
    final subNumberMatch =
        RegExp(r'^(\d{1,5})\s*(\([0-9]+\))$').firstMatch(problemNumber);
    if (subNumberMatch != null) {
      problemNumber = subNumberMatch.group(1) ?? problemNumber;
      final sub = subNumberMatch.group(2) ?? '';
      if (sub.isNotEmpty && !rawAnswerText.startsWith(sub)) {
        rawAnswerText = '$sub $rawAnswerText'.trim();
      }
    }
    final rawAnswerLatex2d = normalizeAnswer('${map['answer_latex_2d'] ?? ''}');
    final answerAssets = parseAssets(map['answer_assets']);
    final kindRaw = '${map['kind'] ?? ''}'.toLowerCase();
    final generatedTableAnswer = RegExp(
      r'(\\begin\{tabular\}|\\hline|\[표시작\]|\[표\])',
      caseSensitive: false,
    ).hasMatch('$rawAnswerText $rawAnswerLatex2d');
    final imageMarker = RegExp(r'(\[\s*image\s*\]|\(\s*image\s*\)|\bimage\b)',
            caseSensitive: false)
        .hasMatch('$rawAnswerText $rawAnswerLatex2d');
    final objectiveText = normalizeObjectiveChoiceText(rawAnswerText);
    final kind = kindRaw == 'image' ||
            imageMarker ||
            answerAssets.isNotEmpty ||
            generatedTableAnswer
        ? 'image'
        : kindRaw == 'objective' && objectiveText.isEmpty
            ? 'subjective'
            : const {'objective', 'subjective', 'image'}.contains(kindRaw)
                ? kindRaw
                : 'subjective';
    return TextbookVlmAnswerItem(
      problemNumber: problemNumber,
      kind: kind,
      answerText: kind == 'image'
          ? (imageMarker
              ? rawAnswerText
              : '${rawAnswerText.trim()} [image]'.trim())
          : kind == 'objective'
              ? objectiveText
              : rawAnswerText.isNotEmpty
                  ? rawAnswerText
                  : rawAnswerLatex2d,
      answerLatex2d: rawAnswerLatex2d,
      answerAssets: answerAssets,
      bbox: parseBbox(map['bbox']) ??
          (answerAssets.isEmpty ? null : answerAssets.first.bbox),
      expectedIndex: asIntN(map['expected_index']) ?? -1,
    );
  }
}

class TextbookVlmAnswerAsset {
  const TextbookVlmAnswerAsset({
    required this.marker,
    required this.assetType,
    required this.bbox,
  });

  final String marker;
  final String assetType;
  final List<int> bbox;
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
    this.answerImagePngBytes,
    this.answerImageRegion1k,
    this.answerImageWidthPx,
    this.answerImageHeightPx,
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
  final Uint8List? answerImagePngBytes;
  final List<int>? answerImageRegion1k;
  final int? answerImageWidthPx;
  final int? answerImageHeightPx;
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
        if (answerImagePngBytes != null && answerImagePngBytes!.isNotEmpty)
          'answer_image_png_base64': base64Encode(answerImagePngBytes!),
        if (answerImageRegion1k != null)
          'answer_image_region_1k': answerImageRegion1k,
        if (answerImageWidthPx != null)
          'answer_image_width_px': answerImageWidthPx,
        if (answerImageHeightPx != null)
          'answer_image_height_px': answerImageHeightPx,
        if (note != null) 'note': note,
      };
}
