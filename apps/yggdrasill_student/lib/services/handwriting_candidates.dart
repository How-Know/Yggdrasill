/// 필기 인식(ML Kit digital ink) 후보 재랭킹.
///
/// en-US 텍스트 모델은 수학 답에서 정답을 2~5번째 후보로 주는 경우가 많다
/// (예: "12"를 쓰면 1순위가 "l2"). 정답 유형을 알고 있으므로 답으로
/// 그럴듯한 후보를 골라 체감 인식률을 올린다.
///
/// 보수적으로 동작한다: 어떤 후보도 답 형태로 보이지 않으면(서술형 답 등)
/// 기존과 동일하게 첫 번째 후보를 쓴다.
library;

/// 숫자 문맥에서 흔히 혼동되는 글자 → 숫자 보정 표.
const Map<String, String> _digitConfusions = <String, String>{
  'l': '1',
  'I': '1',
  '|': '1',
  'O': '0',
  'o': '0',
  'S': '5',
  's': '5',
  'Z': '2',
  'z': '2',
  'b': '6',
  'B': '8',
  'g': '9',
  'q': '9',
};

/// 답에 등장할 수 있는 수식 기호.
const String _mathSymbols = r'+-*/=^().,:%<>±√π°';

/// 답에 등장할 수 있는 변수 글자 (소문자 기준).
const String _variableLetters = 'abcdknptxyz';

/// 공백 제거 — 필기 인식이 "1 2"처럼 획 사이를 띄어 읽는 경우 정규화.
String _canonical(String s) => s.replaceAll(RegExp(r'\s+'), '');

/// 숫자 문맥 혼동 글자를 숫자로 치환한 형태를 돌려준다 (공백도 제거).
String normalizeHandwritingConfusions(String candidate) {
  final buffer = StringBuffer();
  for (final ch in _canonical(candidate).split('')) {
    buffer.write(_digitConfusions[ch] ?? ch);
  }
  return buffer.toString();
}

/// 객관식 답(보기 번호 1~5)으로 보이는지.
bool _isChoice(String s) =>
    s.length == 1 && s.codeUnitAt(0) >= 0x31 && s.codeUnitAt(0) <= 0x35;

/// 주관식 수학 답으로 그럴듯한지 — 숫자를 하나 이상 포함하고,
/// 모든 글자가 숫자·수식 기호·허용 변수 안에 있어야 한다.
bool _looksLikeMathAnswer(String s) {
  if (s.isEmpty) return false;
  var hasDigit = false;
  for (final ch in s.split('')) {
    final code = ch.codeUnitAt(0);
    final isDigit = code >= 0x30 && code <= 0x39;
    if (isDigit) {
      hasDigit = true;
      continue;
    }
    if (_mathSymbols.contains(ch)) continue;
    if (_variableLetters.contains(ch.toLowerCase())) continue;
    return false;
  }
  return hasDigit;
}

/// 인식 후보 중 답으로 그럴듯한 것을 고른다. 없으면 null.
///
/// null 은 "온디바이스 후보 전부가 답 형태가 아님"을 뜻하며,
/// 호출부는 이때 VLM 2차 인식(원격 폴백)을 시도할 수 있다.
///
/// [answerKind]: objective(보기 번호) | subjective | image.
/// 우선순위:
///   1. 원문 그대로 답 형태인 첫 후보 (공백만 정리)
///   2. 혼동 글자 보정 후 답 형태가 되는 첫 후보 (보정본 반환)
String? pickPlausibleHandwritingCandidate(
  List<String> candidates, {
  required String answerKind,
}) {
  final cleaned = <String>[
    for (final c in candidates)
      if (c.trim().isNotEmpty) c.trim(),
  ];
  if (cleaned.isEmpty) return null;

  final bool Function(String) plausible =
      answerKind == 'objective' ? _isChoice : _looksLikeMathAnswer;

  for (final candidate in cleaned) {
    final canonical = _canonical(candidate);
    if (plausible(canonical)) return canonical;
  }
  for (final candidate in cleaned) {
    final normalized = normalizeHandwritingConfusions(candidate);
    if (plausible(normalized)) return normalized;
  }
  return null;
}

/// [pickPlausibleHandwritingCandidate]의 non-null 버전 —
/// 답 형태 후보가 없으면 기존 동작대로 첫 번째 후보를 쓴다.
String pickHandwritingCandidate(
  List<String> candidates, {
  required String answerKind,
}) {
  final plausible = pickPlausibleHandwritingCandidate(
    candidates,
    answerKind: answerKind,
  );
  if (plausible != null) return plausible;
  for (final c in candidates) {
    if (c.trim().isNotEmpty) return c.trim();
  }
  return '';
}
