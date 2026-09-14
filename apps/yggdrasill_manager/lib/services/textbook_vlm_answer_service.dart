import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 답지에서 문항 하나를 특정하기 위해 VLM 에 넘기는 한 줄.
///
/// 번호만으로 충분한 시리즈(쎈/RPM/개념원리)는 [corner]·[bodyPage] 를 비운다.
class TextbookExpectedAnswer {
  const TextbookExpectedAnswer({
    required this.number,
    this.corner = '',
    this.blockTitle = '',
    this.bodyPage,
  });

  /// Stage 1 이 저장한 문항번호. VLM 도 이 문자열 그대로 돌려줘야 한다.
  final String number;

  /// 답지에 인쇄된 코너 이름 (예: "STEP1 쏙쏙 개념 익히기").
  final String corner;

  /// 답지 묶음 머리에 인쇄된 이름 (예: "여러 가지 사각형").
  ///
  /// 고쟁이 워크북 답지는 한 지면에 "중단원 TEST" 보라 배지 묶음이 일곱 개까지
  /// 서고, 쪽 배지(174~177 / 178~181 / 182~185)가 서로 붙어 있어 모델이 옆
  /// 묶음을 집는다. 소단원 이름은 크게 인쇄되므로 코너·쪽보다 튼튼한 단서다.
  final String blockTitle;

  /// 답지 박스 오른쪽 위의 본문 페이지 배지 (예: P.109 → 109).
  final int? bodyPage;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'problem_number': number,
        if (corner.trim().isNotEmpty) 'corner': corner.trim(),
        if (blockTitle.trim().isNotEmpty) 'title': blockTitle.trim(),
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
    this.requireExpectedIndex = false,
  }) : assert(positions.length == entries.length);

  /// 호출자의 전체 기대 목록에서의 위치.
  final List<int> positions;

  /// 이번 호출에 실제로 보낸 기대 문항.
  final List<TextbookExpectedAnswer> entries;

  /// 번호로 되짚는 보정을 끌지 여부.
  ///
  /// 블록마다 번호가 01부터 다시 시작하는 교재(개념+유형·수력충전)는 한 호출에
  /// 같은 "02" 가 블록 수만큼 들어 있다. 게이트웨이가 배지로 블록을 특정하지
  /// 못해 위치를 못 돌려준 항목을 번호로 되짚으면 **목록에서 먼저 나온 블록**의
  /// 크롭에 붙는다. 실제로 해설 좌표 8쌍이 서로 다른 소단원의 같은 자리를
  /// 가리켰다. 근거 없이 붙이느니 비워 두고 다음 지면에서 다시 찾게 한다.
  final bool requireExpectedIndex;

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
    if (requireExpectedIndex) return const <int>[];
    final key = textbookAnswerNumberKey(detectedNumber);
    if (key.isNotEmpty) {
      for (var i = 0; i < entries.length; i += 1) {
        if (textbookAnswerNumberKey(entries[i].number) == key) {
          return <int>[positions[i]];
        }
      }
    }
    // "1~5" 처럼 범위로 묶인 정답은 범위에 드는 기대 항목 전부에 붙는다.
    final range = textbookAnswerNumberRange(detectedNumber);
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

/// 수력충전 크롭의 section → 답지 블록 이름.
///
/// 소단원 블록에는 코너 이름 대신 소단원 이름이 찍혀 있어 크롭 정보만으로는
/// 알 수 없다. 대신 블록 머리의 본문 페이지 배지("▶p.10~11")가 블록을
/// 특정하므로 코너는 비우고 [TextbookExpectedAnswer.bodyPage] 로 가른다.
/// 단원 마무리 평가만 이름이 고정이라 코너로 쓸 수 있다.
const Map<String, String> _kSuryeokAnswerCorners = <String, String>{
  'unit_review': '단원 마무리 평가',
};

/// 고쟁이 크롭의 section → 답지·해설에 인쇄된 묶음 배지 이름.
///
/// 본문(A~D)은 번호가 책 전체를 관통하는 세 자리("054")고 워크북(E·F)은 묶음마다
/// 01 부터 다시 시작한다. 서로 다른 체계라 섞여도 안전할 것 같지만 **번호키는
/// 앞자리 0 을 떼기 때문에** 본문 "005" 와 워크북 "05" 가 같은 키 "5" 로 뭉개진다.
/// 한 중단원의 A~E 를 한 번에 물으면 앞 24개가 통째로 겹쳐, 출처를 못 가린
/// 항목이 전부 버려졌다(2-2 중단원 1: 기대 77개 중 29개만 채워지고 48개가 빔 —
/// 정확히 본문 025~053 만 살아남은 수치다).
///
/// 그래서 본문에도 배지를 실어 보낸다. 답지·해설에는 본문 묶음마다
/// "본교재 007~009쪽", 워크북 묶음마다 "워크북 166~169쪽" 이 인쇄돼 있어서
/// 쪽 범위만으로도 두 체계가 완전히 갈린다.
const Map<String, String> _kGojaengiCorners = <String, String>{
  'mid_unit_test': '중단원 TEST',
  'big_unit_test': '대단원 TEST',
};

/// 고쟁이 본문(A~D) 크롭의 배지 이름. 답지·해설 지면 머리의 "본교재" 띠다.
const String _kGojaengiBodyCorner = '본교재';

/// 고쟁이 본문 단계 section. 이 넷만 "본교재" 배지를 받는다.
///
/// section 이 'unknown' 인 크롭까지 본교재로 몰면 워크북 문항이 본교재 묶음에서
/// 찾히기를 기다리다 조용히 빈 채로 남는다. 모르는 값은 배지를 비워 예전처럼
/// 번호로만 짚게 둔다.
const Set<String> _kGojaengiBodySections = <String>{
  'core_type',
  'advanced_type',
  'top_type',
  'creative_type',
};

/// 답지 블록을 코너·본문 페이지로 가려야 하는 시리즈인지.
///
/// 번호가 블록마다 1번(01번)부터 다시 시작해 한 지면에 같은 번호가 여러 번
/// 나오는 교재들이다. 고쟁이는 본문·워크북의 번호 체계가 달라도 번호키가
/// 앞자리 0 을 떼면서 겹치므로 여기 포함한다([_kGojaengiCorners] 주석 참고).
bool textbookAnswerNeedsCorner(String seriesKey) {
  final key = seriesKey.trim().toLowerCase();
  return key == 'gaeyu' || key == 'suryeok' || key == 'gojaengi';
}

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
  String subKey = '',
  int? displayPage,
  String midName = '',
  String bigName = '',
}) {
  if (!textbookAnswerNeedsCorner(seriesKey)) {
    return TextbookExpectedAnswer(number: problemNumber);
  }
  final bodyPage = displayPage != null && displayPage > 0 ? displayPage : null;
  if (seriesKey.trim().toLowerCase() == 'gojaengi') {
    // 본문이든 워크북이든 배지를 실어 보낸다. 한쪽만 비우면 그 항목이 상대편
    // 번호와 같은 키로 겹쳤을 때 어느 쪽인지 가릴 근거가 사라진다
    // ([_kGojaengiCorners] 주석 참고).
    // 예전 크롭과 일부 워크북 크롭은 section 이 unknown/빈 값이다. 하지만
    // 저자가 고른 슬롯(A~F)은 scopeKey에 항상 남으므로 이것이 더 강한 근거다.
    // 특히 E의 출처가 비면 앞 중단원 TEST의 같은 번호가 현재 문항에 붙는다.
    const sectionBySubKey = <String, String>{
      'A': 'core_type',
      'B': 'advanced_type',
      'C': 'top_type',
      'D': 'creative_type',
      'E': 'mid_unit_test',
      'F': 'big_unit_test',
    };
    final scopedSection = sectionBySubKey[subKey.trim().toUpperCase()];
    final trimmed = scopedSection ?? section.trim();
    return TextbookExpectedAnswer(
      number: problemNumber,
      corner: _kGojaengiCorners[trimmed] ??
          (_kGojaengiBodySections.contains(trimmed)
              ? _kGojaengiBodyCorner
              : ''),
      // 워크북 묶음 머리에 인쇄된 이름. 중단원 TEST 는 소단원 이름,
      // 대단원 TEST 는 대단원 이름이 붙는다.
      blockTitle: trimmed == 'mid_unit_test'
          ? midName.trim()
          : (trimmed == 'big_unit_test' ? bigName.trim() : ''),
      bodyPage: bodyPage,
    );
  }
  if (seriesKey.trim().toLowerCase() == 'suryeok') {
    // 수력충전은 번호에 접두어를 붙이지 않는다. 블록은 본문 페이지로 가른다.
    return TextbookExpectedAnswer(
      number: problemNumber,
      corner: _kSuryeokAnswerCorners[section.trim()] ?? '',
      bodyPage: bodyPage,
    );
  }
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

/// 답지에 "05~09" 처럼 범위로 인쇄된 머리표를 양 끝 번호로 읽는다.
///
/// 여러 문항의 답을 그림 하나(좌표평면·표·격자)로 묶어 인쇄한 묶음이 이렇게
/// 나온다. 범위가 아니면 null 이다.
(int, int)? textbookAnswerNumberRange(String raw) {
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
    List<String>? skipBadges,
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
      if (skipBadges != null && skipBadges.isNotEmpty)
        'skip_badges': skipBadges,
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

  /// 수력충전 빠른 정답 지면을 소단원 머리와 번호/정답 순서로 읽는다.
  /// 실제 본문 크롭과의 매칭은 저장된 소단원별 문항 목록으로 앱이 수행한다.
  Future<TextbookVlmAnswerLayoutPage> extractAnswerLayoutOnPage({
    required Uint8List imageBytes,
    required int rawPage,
    String mimeType = 'image/png',
  }) async {
    final res = await _http.post(
      _uri('/textbook/vlm/extract-answer-layout'),
      headers: _headers(),
      body: jsonEncode(<String, dynamic>{
        'image_base64': base64Encode(imageBytes),
        'mime_type': mimeType,
        'raw_page': rawPage,
      }),
    );
    final json = _decode(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300 || json['ok'] != true) {
      throw Exception(
        'vlm_extract_answer_layout_failed(${res.statusCode}): '
        '${json['error'] ?? json['message'] ?? res.body}',
      );
    }
    return TextbookVlmAnswerLayoutPage.fromMap(json);
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
    final chunks = textbookAnswerUploadChunks(answers);
    var upserted = 0;
    final failures = <String>[];
    for (var i = 0; i < chunks.length; i += 1) {
      final chunk = chunks[i];
      final megabytes = utf8.encode(jsonEncode(chunk)).length / 1024 / 1024;
      Object? lastError;
      for (var attempt = 1; attempt <= 3; attempt += 1) {
        try {
          upserted +=
              await _postAnswerBatch(academyId: academyId, answers: chunk);
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          if (attempt < 3) {
            await Future<void>.delayed(Duration(seconds: 2 * attempt));
          }
        }
      }
      debugPrint(
        '[정답저장] ${i + 1}/${chunks.length} 건수=${chunk.length} '
        '${megabytes.toStringAsFixed(1)}MB '
        '${lastError == null ? '저장됨' : '실패 $lastError'}',
      );
      // 한 묶음이 끝내 막혀도 남은 묶음은 보낸다. 320건을 200건씩 나눠 보내다
      // 두 번째에서 걸리면 나머지가 통째로 버려지고, 다시 돌려도 같은 자리에서
      // 또 멈춘다(3-1 중단원3: 앞 200건만 저장돼 본문 추출이 막혔다).
      if (lastError != null) {
        failures.add('${i + 1}번째 묶음 ${chunk.length}건: $lastError');
      }
    }
    if (failures.isNotEmpty) {
      throw Exception(
        '정답 $upserted개 저장 · 묶음 ${failures.length}개 실패 — ${failures.first}',
      );
    }
    return upserted;
  }

  Future<int> _postAnswerBatch({
    required String academyId,
    required List<Map<String, dynamic>> answers,
  }) async {
    final res = await _http.post(
      _uri('/textbook/answers/batch-upsert'),
      headers: _headers(),
      body: jsonEncode(<String, dynamic>{
        'academy_id': academyId,
        'answers': answers,
      }),
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
    int subIndex = 0,
  }) async {
    final body = <String, dynamic>{
      'academy_id': academyId,
      'book_id': bookId,
      'grade_label': gradeLabel,
      'big_order': bigOrder,
      'mid_order': midOrder,
      'sub_key': subKey,
      'sub_index': subIndex,
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
class TextbookVlmAnswerLayoutEntry {
  const TextbookVlmAnswerLayoutEntry({
    required this.isHeader,
    this.title = '',
    this.pageStart = 0,
    this.pageEnd = 0,
    this.answer,
    this.bbox,
  });

  final bool isHeader;
  final String title;
  final int pageStart;
  final int pageEnd;
  final TextbookVlmAnswerItem? answer;

  /// 이 요소가 지면에서 차지한 자리 [ymin, xmin, ymax, xmax] (0..1000).
  ///
  /// 소단원 머리와 정답의 앞뒤 관계를 좌표로 다시 세울 때 쓴다.
  final List<int>? bbox;

  factory TextbookVlmAnswerLayoutEntry.fromMap(Map<String, dynamic> map) {
    int asInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse('$value') ?? 0;
    }

    List<int>? asBbox(dynamic value) {
      if (value is! List || value.length != 4) return null;
      final out = <int>[];
      for (final v in value) {
        if (v is num) {
          out.add(v.toInt());
          continue;
        }
        final parsed = int.tryParse('$v');
        if (parsed == null) return null;
        out.add(parsed);
      }
      return out;
    }

    final isHeader = '${map['kind']}' == 'header';
    return TextbookVlmAnswerLayoutEntry(
      isHeader: isHeader,
      title: '${map['title'] ?? ''}'.trim(),
      pageStart: asInt(map['page_start']),
      pageEnd: asInt(map['page_end']),
      answer: isHeader ? null : TextbookVlmAnswerItem.fromMap(map),
      bbox: asBbox(map['bbox']),
    );
  }
}

/// 게이트웨이가 한 번에 받는 정답 건수. 넘기면 413 answer_batch_too_large 다.
const int kAnswerBatchMaxRows = 200;

/// 한 번에 보내는 본문 바이트 한도. 그림 정답은 PNG 를 base64 로 실어 보내
/// 한 건이 수 MB 가 되므로, 건수만 세면 몸집이 터진다.
const int kAnswerBatchMaxBytes = 6 * 1024 * 1024;

/// 정답 묶음을 게이트웨이가 삼킬 수 있는 크기로 자른다.
///
/// 실력 향상 테스트처럼 소단원 하나에 문항이 454개 붙는 자리가 있어, 통째로
/// 보내면 413 answer_batch_too_large 로 거부되고 "완료" 단추가 아무 반응도
/// 없는 것처럼 보인다. 건수와 바이트를 함께 보고, 한 건이 홀로 한도를 넘어도
/// 버리지 않고 그 건만 담은 묶음으로 내보낸다.
List<List<Map<String, dynamic>>> textbookAnswerUploadChunks(
  List<TextbookAnswerUpload> answers,
) {
  final chunks = <List<Map<String, dynamic>>>[];
  var current = <Map<String, dynamic>>[];
  var currentBytes = 0;
  for (final answer in answers) {
    final row = answer.toJson();
    final bytes = utf8.encode(jsonEncode(row)).length;
    final tooMany = current.length >= kAnswerBatchMaxRows;
    final tooBig =
        current.isNotEmpty && currentBytes + bytes > kAnswerBatchMaxBytes;
    if (tooMany || tooBig) {
      chunks.add(current);
      current = <Map<String, dynamic>>[];
      currentBytes = 0;
    }
    current.add(row);
    currentBytes += bytes;
  }
  if (current.isNotEmpty) chunks.add(current);
  return chunks;
}

/// 답지 판독 결과를 지면 읽기 순서로 다시 세운다.
///
/// 순서는 왼쪽 단 위→아래, 그다음 오른쪽 단 위→아래다. 모델은 대개 그렇게
/// 내놓지만 같은 지면을 조금 다르게 렌더하면 오른쪽 단을 먼저 적어 오기도
/// 한다. 그러면 소단원 머리보다 먼저 온 정답이 "아직 블록이 없다"며 버려져
/// 그 단이 통째로 빈다(1-2 답지 10쪽 "05 도수분포표" 06~45번 40개).
///
/// 좌표가 하나라도 없으면 순서를 건드리지 않고 모델이 준 대로 쓴다.
///
/// 한 정답이 왼쪽 단 맨 아래에서 시작해 오른쪽 단 맨 위로 이어질 때가 있다.
/// 그러면 모델은 두 조각을 아우른 지면만 한 상자를 준다 — 위끝은 오른쪽 단
/// 머리, 왼끝은 왼쪽 단(2-1 답지 10쪽 "12 연립방정식의 활용 – 농도" 09번은
/// [66,93,921,783]). 그 상자를 그대로 믿으면 왼쪽 단 맨 위로 올라가 자기
/// 소단원 머리보다 앞서게 되고, 블록이 정해지기 전이라 통째로 버려진다.
/// 두 단을 함께 덮은 상자는 자리를 못 믿으니 바로 앞 요소의 자리를 물려받아
/// 모델이 적어 준 자리에 그대로 머무르게 한다.
List<TextbookVlmAnswerLayoutEntry> textbookAnswerLayoutReadingOrder(
  List<TextbookVlmAnswerLayoutEntry> entries,
) {
  if (entries.length < 2) return entries;
  for (final entry in entries) {
    final bbox = entry.bbox;
    if (bbox == null || bbox.length != 4) return entries;
  }
  // 단 구분은 지면 가운데(500)를 기준으로 한다. 두 단을 다 덮는 머리 띠는
  // 왼쪽 단 것으로 보아 그 위치의 흐름을 그대로 따른다.
  int columnOf(TextbookVlmAnswerLayoutEntry entry) =>
      entry.bbox![1] >= 500 ? 2 : 1;
  bool spansBothColumns(TextbookVlmAnswerLayoutEntry entry) =>
      entry.bbox![1] < 500 && entry.bbox![3] >= 500;
  final keys = List<(int, int)>.filled(entries.length, (1, 0));
  var last = (1, 0);
  for (var i = 0; i < entries.length; i += 1) {
    if (i > 0 && spansBothColumns(entries[i])) {
      keys[i] = last;
      continue;
    }
    last = (columnOf(entries[i]), entries[i].bbox![0]);
    keys[i] = last;
  }
  final order = <int>[for (var i = 0; i < entries.length; i += 1) i];
  order.sort((a, b) {
    final byColumn = keys[a].$1.compareTo(keys[b].$1);
    if (byColumn != 0) return byColumn;
    final byTop = keys[a].$2.compareTo(keys[b].$2);
    return byTop != 0 ? byTop : a.compareTo(b);
  });
  return <TextbookVlmAnswerLayoutEntry>[for (final i in order) entries[i]];
}

class TextbookVlmAnswerLayoutPage {
  const TextbookVlmAnswerLayoutPage({
    required this.rawPage,
    required this.leadingContinuation,
    required this.entries,
  });

  final int rawPage;
  final bool leadingContinuation;
  final List<TextbookVlmAnswerLayoutEntry> entries;

  factory TextbookVlmAnswerLayoutPage.fromMap(Map<String, dynamic> map) {
    final raw = (map['entries'] as List?) ?? const [];
    return TextbookVlmAnswerLayoutPage(
      rawPage: int.tryParse('${map['raw_page']}') ?? 0,
      leadingContinuation: map['leading_continuation'] == true,
      entries: <TextbookVlmAnswerLayoutEntry>[
        for (final entry in raw)
          if (entry is Map)
            TextbookVlmAnswerLayoutEntry.fromMap(
              entry.map((k, dynamic v) => MapEntry('$k', v)),
            ),
      ],
    );
  }
}

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
