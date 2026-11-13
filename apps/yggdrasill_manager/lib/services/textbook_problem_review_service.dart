import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'problem_bank_service.dart';
import 'textbook_review_solution_image_service.dart';

/// 공통 발문(common_stem)이 개별 발문(stem) 앞머리에 그대로 들어 있으면(공백·[문단] 차이는 무시)
/// 공통 부분을 뗀 개별 본문을 돌려준다. 중복이 없거나 떼어내면 본문이 비는 경우 null.
/// Edge `stripCommonStem` 과 같은 규칙이다. 학생 화면은 공통 발문 + 개별 발문을 이어 그리므로
/// 이 중복은 지시문이 두 번 보이는 데이터 오류다.
String? stripCommonStem(String commonStem, String stem) {
  final c = commonStem.replaceAll(RegExp(r'\s+'), '');
  final s = stem;
  if (c.isEmpty || s.trim().isEmpty) return null;
  const para = '[문단]';
  final ws = RegExp(r'\s');
  var i = 0;
  var j = 0;
  while (i < s.length && j < c.length) {
    final ch = s[i];
    if (ws.hasMatch(ch)) {
      i++;
      continue;
    }
    if (s.startsWith(para, i) && !c.startsWith(para, j)) {
      i += para.length;
      continue;
    }
    if (ch != c[j]) break;
    i++;
    j++;
  }
  String rest;
  if (j >= c.length) {
    rest = s.substring(i);
  } else {
    final exact = commonStem.trim();
    final at = exact.isEmpty ? -1 : s.indexOf(exact);
    if (at < 0) return null;
    rest = s.substring(0, at) + s.substring(at + exact.length);
  }
  rest = rest.replaceFirst(RegExp(r'^(\s|\[문단\])+'), '').replaceFirst(RegExp(r'(\s|\[문단\])+$'), '');
  return rest.trim().isEmpty ? null : rest;
}

/// 공통 발문 중복을 고치는 데 필요한 변경. [stem] 은 개별 발문의 새 값, [commonStem] 은 공통 발문의 새 값(바꿀 필요 없으면 null).
class CommonStemFix {
  const CommonStemFix({required this.stem, this.commonStem});
  final String stem;
  final String? commonStem;
}

String _squash(String s) => s.replaceAll(RegExp(r'\s+|\[문단\]'), '');

/// 서술형으로 봐야 하는 표현(Edge `ESSAY_PATTERN` 과 같다)
/// 발문이 선지를 가리키는 표현(있으면 주관식으로 낼 수 없다)
final kChoiceReferencePattern = RegExp(r'다음\s*중|보기|옳지\s*않은|틀린|알맞지\s*않은|아닌\s*것|고르|짝\s*지은|모두\s*찾');

final kEssayPattern = RegExp(r'서술하(시오|여라)|과정을\s*(쓰|서술|설명)|풀이\s*과정|이유를\s*(쓰|설명|서술)|설명하(시오|여라)|증명하(시오|여라)');

/// 빈칸형 문항 판별: 발문·공통발문·수식에 빈칸 채우기 지시나 네모(□, [[공백:n]], box{~~}, \square, \Box 등)가 있는 문항(Edge `FILL_IN_BLANK_PATTERN` 과 같다).
final kFillInBlankPattern = RegExp(
  r'\[\[?\s*공백\s*:\s*\d+(?:\.\d+)?\s*\]\]?|\bbox\s*\{|\\(?:square|Box|boxed)\b|[□▢]|(?:빈칸|네모|\(\s*\)|\[\s*\])\s*(?:에|안에)|알맞은\s*(?:수|말|식|값|기호|것|숫자)를?\s*(?:써넣|쓰시오|써라|채우)',
);

bool isFillInBlankProblem(String commonStem, String stem) => kFillInBlankPattern.hasMatch('$commonStem\n$stem');

/// 빈칸형 문항에서 모델이 정상 조판된 네모(□)·빈칸 자체를 '불명확한 빈칸 추가'·'단독 빈칸'·'빈칸 노출'로 잘못 지적한 경우인가
bool isFalseBlankComplaint(bool isFillInBlank, Object? title, Object? detail) {
  if (!isFillInBlank) return false;
  final text = '${title ?? ''} ${detail ?? ''}'.trim();
  if (text.isEmpty) return false;
  if (RegExp(r'\[\[?\s*공백|박스시작|박스끝|표시작|표끝|PB_FIG', caseSensitive: false).hasMatch(text)) return false;
  return RegExp(r'(?:용도가\s*불명확한\s*빈칸|단독\s*빈칸|빈칸이\s*(?:추가|하나\s*더|더\s*보|노출|있)|네모가\s*(?:추가|더\s*보|노출))').hasMatch(text);
}

/// 지시문 문장으로 볼 수 있는 표현(Edge `looksLikeInstruction` 과 같다).
final _instructionPattern = RegExp(
  r'(다음|아래|보기|위|오른쪽|왼쪽)|(구하|쓰|써넣|채우|고르|찾|연결|나타내|계산|비교|완성|판단|말하|답하|표시|그리|그려|풀어|인수분해|소인수분해|약분|통분|정리)(여라|시오|라|자|기|고)|\?',
);

bool looksLikeInstruction(String text) {
  final t = text.trim();
  return t.length >= 4 && _instructionPattern.hasMatch(t);
}

/// 공통 발문의 첫 지시문: 첫 [문단]/줄바꿈 앞, 없으면 첫 문장(. ? ! 로 끝남). 뒤에 이어지는 내용이 없거나 지시문이 아니면 null.
String? leadingInstruction(String common) {
  final parts = common.split(RegExp(r'\[문단\]|\n')).map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
  if (parts.length >= 2) return looksLikeInstruction(parts.first) ? parts.first : null;
  final m = RegExp(r'^(.+?[.?!])\s*(\S[\s\S]*)$').firstMatch(common.trim());
  final first = m?.group(1)?.trim();
  return first != null && looksLikeInstruction(first) ? first : null;
}

/// 답 비교용 정규화: 공백·$·중괄호·\left/\right 를 지우고 곱셈·부등호·원 기호를 하나로 맞춘다.
String normalizeAnswerForCompare(String s) => s
    .replaceAll(RegExp(r'\\left|\\right'), '')
    .replaceAll(RegExp(r'\\times|\\cdot|·|\*'), '×')
    .replaceAll(RegExp(r'\\leq|\\le\b'), '≤')
    .replaceAll(RegExp(r'\\geq|\\ge\b'), '≥')
    .replaceAll(RegExp(r'\\bigcirc|○|◯'), 'o')
    .replaceAll(RegExp(r'[\s${}\\]'), '')
    .toLowerCase();

/// V2 정답+해설 카드에 넣을 정답 문자열 포맷:
/// 1) '1) 1, 2, 4, 8 2) 1, 2, 3, 4, 6, 12' 처럼 소문항 번호가 이어진 정답은 한 줄에 그리면
///    오른쪽 끝이 카드 밖으로 잘리거나 앞 답과 다음 번호가 붙어 보이므로 소문항마다 줄바꿈([문단])하고 번호 뒤에 [공백:0.4]를 넣는다.
/// 2) 여러 줄(\n)로 된 정답도 줄바꿈([문단])을 유지한다.
String formatAnswerForCard(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return s;
  if (RegExp(r'^\s*(?:\(\s*1\s*\)|1\)|⑴)\s*\S').hasMatch(s)) {
    s = s.replaceAllMapped(
      RegExp(r'(?<=\S)\s+(?=(?:\(\s*(?:[2-9]|\d{2,})\s*\)|(?:[2-9]|\d{2,})\)|[⑵-⑼])\s*)'),
      (_) => '[문단]',
    );
    s = s.replaceAllMapped(
      RegExp(r'((?:^|\[문단\]|\[공백:[\d.]+\])\s*(?:\(\s*\d+\s*\)|\d+\)|[⑴-⑼]))\s*'),
      (m) => '${m.group(1)}[공백:0.4]',
    );
  }
  s = s.replaceAll(RegExp(r'\s*\n+\s*'), '[문단]');
  return s;
}

/// 공통 발문이 비어 있지 않은데 지시문이 아니라 숫자·수식 조각(예: '36', '36=2^2×3^2')만 들어 있는 손상 상태인가
bool isCorruptedCommonStem(String commonStem) {
  final c = commonStem.trim();
  if (c.isEmpty) return false;
  final parts = c.split(RegExp(r'\[문단\]|\n')).map((p) => p.trim()).where((p) => p.isNotEmpty);
  return !parts.any(looksLikeInstruction);
}

/// 원본 해설 전사 텍스트에서 이중 추출된 '[해설]'/'[풀이]' 머리말과 '16 답 ×'·'[정답] ③' 같은 정답 줄을 제거한다.
String cleanSolutionTranscribedText(
  String rawText, {
  String? problemNumber,
  String? solutionAnswer,
}) {
  var s = rawText.replaceAll('\r\n', '\n').trim();
  if (s.isEmpty) return '';
  final numDigits = (problemNumber ?? '').replaceAll(RegExp(r'[^0-9]'), '').replaceFirst(RegExp(r'^0+'), '');
  final numEsc = numDigits.isNotEmpty ? '0*$numDigits(?:\\s*번|\\.|\\))?' : '(?:0*\\d{1,3}(?:\\s*번|\\.|\\))?)';
  final ansNorm = normalizeAnswerForCompare(solutionAnswer ?? '');

  for (var pass = 0; pass < 6 && s.isNotEmpty; pass++) {
    final prev = s;
    s = s.replaceFirst(RegExp(r'^(?:\s|\[문단\])+'), '');
    s = s.replaceFirst(
      RegExp(r'^(?:\[\s*(?:해설|풀이|정답과\s*해설|정답\s*및\s*해설)\s*\]|<\s*(?:해설|풀이)\s*>|(?:해설|풀이)\s*[:：])\s*', caseSensitive: false),
      '',
    );
    s = s.replaceFirst(RegExp(r'^(?:해설|풀이)\s*(?:\n|\[문단\])+'), '');
    s = s.replaceFirst(RegExp(r'^(?:\s|\[문단\])+'), '');

    final firstBreak = RegExp(r'\n|\[문단\]').firstMatch(s);
    final firstLine = (firstBreak != null ? s.substring(0, firstBreak.start) : s).trim();
    final restAfterFirst =
        firstBreak != null ? s.substring(firstBreak.start).replaceFirst(RegExp(r'^(?:\s|\[문단\])+'), '') : '';

    final isProseDap = RegExp(r'^(?:답|정답)(?:[은는이가을를도만]|(?:\s*없음))').hasMatch(firstLine);
    final bracketOrNumberedAnsRe = RegExp(
      '^(?:$numEsc\\s*(?:\\[\\s*(?:답|정답)\\s*\\]|(?:답|정답))(?![은는이가을를도만])(?:\\s*[:：]?\\s*\\S.*|\$)|\\[\\s*(?:답|정답)\\s*\\]\\s*[:：]?\\s*\\S.*|(?:답|정답)\\s*[:：]\\s*\\S.*)',
      caseSensitive: false,
    );
    final bareDapMatch = !isProseDap ? RegExp(r'^(?:답|정답)\s+(\S.*)$').firstMatch(firstLine) : null;
    final isBareDapHeader = bareDapMatch != null &&
        (restAfterFirst.isNotEmpty ||
            (ansNorm.isNotEmpty && normalizeAnswerForCompare(bareDapMatch.group(1)!) == ansNorm));
    if (!isProseDap && (bracketOrNumberedAnsRe.hasMatch(firstLine) || isBareDapHeader)) {
      final inlineSol = RegExp(r'(?:\[\s*(?:해설|풀이)\s*\]|(?:해설|풀이)\s*[:：])\s*(.+)$').firstMatch(firstLine);
      s = inlineSol != null
          ? '${inlineSol.group(1)!.trim()}${restAfterFirst.isNotEmpty ? '\n$restAfterFirst' : ''}'
          : restAfterFirst;
      continue;
    }

    if (numDigits.isNotEmpty) {
      final m = RegExp('^0*$numDigits(?:\\s*번|\\.|\\))?\\s+(.+)\$').firstMatch(firstLine);
      if (m != null && ansNorm.isNotEmpty && normalizeAnswerForCompare(m.group(1)!.trim()) == ansNorm) {
        s = restAfterFirst;
        continue;
      }
    }

    if (ansNorm.isNotEmpty && firstLine.isNotEmpty && normalizeAnswerForCompare(firstLine) == ansNorm && restAfterFirst.isNotEmpty) {
      s = restAfterFirst;
      continue;
    }

    if (s == prev) break;
  }

  s = s
      .replaceAll(RegExp(r'(?:^|\n|\[문단\])\s*\[\s*(?:해설|풀이)\s*\]\s*(?=\n|\[문단\]|$)'), '\n')
      .replaceFirst(RegExp(r'^\s*\[\s*(?:해설|풀이)\s*\]\s*'), '')
      .replaceFirst(RegExp(r'^(?:\s|\[문단\])+'), '')
      .replaceFirst(RegExp(r'(?:\s|\[문단\])+$'), '')
      .trim();
  return s;
}

/// 공통 발문 중복의 두 형태를 모두 다룬다.
/// 1) 공통 발문(지시문)이 개별 발문 앞머리에 다시 들어 있음 → 개별 발문에서 공통 부분만 뺀다(단, 공통 발문이 숫자·식 조각이면 떼어내지 않는다).
/// 2) 공통 발문에 개별 문항 본문까지 통째로 들어 있음(common_stem == stem 등) →
///    (가) 첫 문단이 지시문이면 공통 발문은 첫 문단(지시문)만 남기고 개별 발문은 지시문을 뺀 나머지,
///    (나) 첫 문단이 숫자·식이고 두 번째 문단이 지시문이면(예: "36=2^2×3^2\n다음 표의 빈칸에...") 공통 발문은 그 지시문 문단만 남기고,
///         개별 발문에서도 앞머리 중복 지시문을 뺀다.
/// 3) 공통 발문이 이미 숫자·식 조각('36=2^2×3^2', '36' 등)으로만 잘려 있고 개별 발문 첫 문단에 실제 공통 지시문이 남아 있는 경우 복구한다.
/// Edge `commonStemFix` 와 같은 규칙이다.
CommonStemFix? computeCommonStemFix(String commonStem, String stem) {
  final common = commonStem.trim();
  if (common.isEmpty || stem.trim().isEmpty) return null;
  if (looksLikeInstruction(common)) {
    final direct = stripCommonStem(common, stem);
    if (direct != null) return CommonStemFix(stem: direct);
  }

  final instr = leadingInstruction(common);
  if (instr != null) {
    final rest = stripCommonStem(instr, stem);
    if (rest != null) {
      final sqCommon = _squash(common);
      final sqRest = _squash(rest);
      if (sqRest.isNotEmpty && sqCommon.endsWith(sqRest)) {
        return CommonStemFix(stem: rest, commonStem: instr);
      }
    }
  }

  final parts = common.split(RegExp(r'\[문단\]|\n')).map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
  if (parts.length >= 2 && !looksLikeInstruction(parts.first)) {
    final instrPart = parts.skip(1).where(looksLikeInstruction).firstOrNull;
    if (instrPart != null) {
      final strippedFromStem = stripCommonStem(instrPart, stem) ?? stripCommonStem('${parts.first}\n$instrPart', stem);
      final nextStem = strippedFromStem ?? stem.trim();
      if (nextStem.isNotEmpty) return CommonStemFix(stem: nextStem, commonStem: instrPart);
    }
  }

  if (isCorruptedCommonStem(common)) {
    final stemInstr = leadingInstruction(stem);
    if (stemInstr != null) {
      final rest = stripCommonStem(stemInstr, stem);
      if (rest != null) return CommonStemFix(stem: rest, commonStem: stemInstr);
    }
  }
  return null;
}

final _figureMarkerRe = RegExp(r'\[\[PB_FIG_[^\]]+\]\]|\[(?:그림|도형|도표)\]');

/// 본문 안 그림 마커 수. 렌더러는 마커 순서대로 그림 자산을 놓는다(Edge `figureMarkerCount` 와 같다).
int figureMarkerCount(String stem) => _figureMarkerRe.allMatches(stem).length;

/// 렌더러(hydrateFiguresForXeLatex)와 같은 규칙으로 고른 그림 자산: figure_index 별 승인 우선·최신 우선 하나, figure_index 순.
List<Map<String, dynamic>> orderedFigureAssets(List<Map<String, dynamic>> assets) {
  final byIdx = <int, Map<String, dynamic>>{};
  for (final a in assets) {
    final idx = int.tryParse('${a['figure_index'] ?? ''}');
    if (idx == null || idx <= 0) continue;
    final prev = byIdx[idx];
    if (prev == null) {
      byIdx[idx] = a;
      continue;
    }
    final pa = prev['approved'] == true ? 1 : 0;
    final ca = a['approved'] == true ? 1 : 0;
    if (ca > pa || (ca == pa && '${a['created_at'] ?? ''}'.compareTo('${prev['created_at'] ?? ''}') > 0)) byIdx[idx] = a;
  }
  final keys = byIdx.keys.toList()..sort();
  return [for (final k in keys) byIdx[k]!];
}

/// 원본 이미지(쪽 영역 [region1k] 를 찍은 것) 안의 상자 [box]([ymin, xmin, ymax, xmax] 0..1000)를 쪽 좌표로 바꾼다.
/// [margin] 은 이미지 기준 0..1000 여유(그림 가장자리 선이 잘리지 않게).
List<int>? cropBoxToPageRegion(List<int> region1k, List<int> box, {int margin = 12}) {
  if (region1k.length != 4 || box.length != 4) return null;
  final b0 = (box[0] - margin).clamp(0, 1000);
  final b1 = (box[1] - margin).clamp(0, 1000);
  final b2 = (box[2] + margin).clamp(0, 1000);
  final b3 = (box[3] + margin).clamp(0, 1000);
  final h = region1k[2] - region1k[0];
  final w = region1k[3] - region1k[1];
  if (b2 <= b0 || b3 <= b1 || h <= 0 || w <= 0) return null;
  return [
    region1k[0] + (b0 * h / 1000).floor(),
    region1k[1] + (b1 * w / 1000).floor(),
    region1k[0] + (b2 * h / 1000).ceil(),
    region1k[1] + (b3 * w / 1000).ceil(),
  ];
}

/// 해설지 풀이 머리(문항 번호) 좌표 한 개. [region1k] 는 풀이 영역(없으면 번호 영역).
class SolutionRefBox {
  const SolutionRefBox({required this.rawPage, required this.numberTop, required this.region1k});

  final int rawPage;
  final int numberTop;
  final List<int> region1k;

  int get column => (region1k[1] + region1k[3]) / 2 < 500 ? 0 : 1;
}

/// 풀이 영역이 단 맨 아래(ymax >= 980)까지 닿았고, 다음 단(왼쪽 단이면 같은 쪽 오른쪽 단, 오른쪽 단이면 다음 쪽 왼쪽 단)의
/// 첫 번호가 평소 단 첫 번호 자리보다 눈에 띄게 아래에 있으면, 그 위의 번호 없는 부분을 이어진 풀이로 본다.
/// 평소 자리는 [refs] 에 있는 단마다의 첫 번호 높이의 중앙값이다. 다음 단에 번호가 하나도 없으면 판단하지 않는다.
TextbookSolutionSegment? solutionContinuationSegment({
  required int rawPage,
  required List<int> region1k,
  required List<SolutionRefBox> refs,
}) {
  if (region1k.length != 4 || region1k[2] < 980) return null;
  final firstTop = <String, int>{};
  final xRange = <String, List<int>>{};
  for (final r in refs) {
    if (r.region1k.length != 4) continue;
    final k = '${r.rawPage}|${r.column}';
    final cur = firstTop[k];
    if (cur == null || r.numberTop < cur) firstTop[k] = r.numberTop;
    final x = xRange[k];
    xRange[k] = x == null
        ? [r.region1k[1], r.region1k[3]]
        : [r.region1k[1] < x[0] ? r.region1k[1] : x[0], r.region1k[3] > x[1] ? r.region1k[3] : x[1]];
  }
  if (firstTop.length < 3) return null;
  final tops = firstTop.values.toList()..sort();
  final baseline = tops[tops.length ~/ 2];
  final col = (region1k[1] + region1k[3]) / 2 < 500 ? 0 : 1;
  final nextPage = col == 0 ? rawPage : rawPage + 1;
  final nextKey = '$nextPage|${col == 0 ? 1 : 0}';
  final nextTop = firstTop[nextKey];
  if (nextTop == null || nextTop - baseline < 25) return null;
  final x = xRange[nextKey]!;
  final ymin = (baseline - 12).clamp(0, 1000);
  final ymax = nextTop - 14;
  if (ymax <= ymin) return null;
  return TextbookSolutionSegment(nextPage, [ymin, x[0], ymax, x[1]]);
}

/// 원본 해설에 그림이 있을 수 있다는 표시: [그림] 표시, "그림과 같다", "그래프는 오른쪽과 같다" 등.
final RegExp kSolutionFigureHintPattern = RegExp(r'그림|그래프[는를은]?\s*(?:오른쪽|아래|다음)|(?:오른쪽|아래)과\s*같');

/// 해설 전사본의 그림 표시. 예전 전사본의 [그림: 설명] 도 같은 표시로 본다(Edge SOLUTION_FIGURE_MARKER_RE 와 같은 규칙).
final RegExp kSolutionFigureMarkerRe = RegExp(r'\[그림(?:\s*:[^\]]*)?\]');

/// 해설 PDF 쪽 폭(1000) 기준 본문 글자 1em. 해설 그림 폭(em)을 원본 글자 대비 크기로 정할 때 쓴다.
const double kSolutionTextEm1k = 17.5;

/// 해설 쪽 영역 폭(0..1000)을 V2 그림 폭(em)으로 바꾼다.
double solutionFigureWidthEm(List<int> pageRegion1k) {
  if (pageRegion1k.length != 4) return 10;
  final em = (pageRegion1k[3] - pageRegion1k[1]) / kSolutionTextEm1k;
  return (em.clamp(4.0, 20.0) * 2).round() / 2;
}

/// 정답+해설 V2 카드 본문과 그림 메타. 그림 정답은 정답 자리에, 원본 해설 그림은 해설의 [그림] 자리에 넣는다.
/// 해설의 그림 표시가 그림 수보다 모자라면 남은 그림을 해설 끝에 붙이고, 그림이 없는 표시는 지운다.
({String stem, Map<String, dynamic> meta}) buildAnswerSolutionCardContent({
  required String answer,
  required String solution,
  required String solutionKind,
  String answerImageBucket = '',
  String answerImagePath = '',
  List<Map<String, dynamic>> solutionFigures = const [],
}) {
  final assets = <Map<String, dynamic>>[];
  final layoutItems = <Map<String, dynamic>>[];
  void addFigure(Map<String, dynamic> asset, double widthEm, String anchor, {String position = 'below-stem'}) {
    final idx = assets.length + 1;
    assets.add({...asset, 'figure_index': idx, 'approved': true});
    layoutItems.add({
      'assetKey': 'idx:$idx',
      'widthEm': widthEm,
      'position': position,
      'anchor': anchor,
      'offsetXEm': 0,
      'offsetYEm': 0,
    });
  }

  final buf = StringBuffer();
  final hasAnswerImage = answerImageBucket.isNotEmpty && answerImagePath.isNotEmpty;
  if (hasAnswerImage) {
    buf.write('정답[문단][그림]');
    addFigure({'bucket': answerImageBucket, 'path': answerImagePath, 'mime_type': 'image/png'}, 10, 'left');
  } else if (answer.isNotEmpty) {
    buf.write('정답  $answer');
  }

  var sol = solution;
  if (sol.isNotEmpty) {
    final figures = solutionKind == 'ai' ? const <Map<String, dynamic>>[] : solutionFigures;
    var used = 0;
    sol = sol.replaceAllMapped(kSolutionFigureMarkerRe, (_) {
      if (used >= figures.length) return '';
      used++;
      return '[문단][그림][문단]';
    });
    for (var i = used; i < figures.length; i++) {
      sol = '$sol[문단][그림]';
    }
    for (final f in figures) {
      final w = (f['width_em'] as num?)?.toDouble() ?? 10;
      final right = f['placement'] == 'right';
      addFigure({
        'bucket': '${f['bucket'] ?? ''}',
        'path': '${f['path'] ?? ''}',
        'mime_type': '${f['mime_type'] ?? 'image/png'}',
      }, w, right ? 'right' : 'center', position: right ? 'inline-right' : 'below-stem');
    }
    if (buf.isNotEmpty) buf.write('[문단]');
    buf.write(solutionKind == 'ai' ? '[AI 풀이]' : '[해설]');
    buf.write('[문단]');
    buf.write(sol);
  }
  return (
    stem: buf.toString(),
    meta: assets.isEmpty
        ? const <String, dynamic>{}
        : {
            'figure_assets': assets,
            'figure_layout': {'version': 1, 'items': layoutItems, 'groups': const []},
          },
  );
}

/// figure_layout 항목 목록(assetKey 별 widthEm·position·anchor·offset). 없으면 빈 목록.
List<Map<String, dynamic>> figureLayoutItems(Map<String, dynamic>? layout) => [
      for (final x in (layout?['items'] as List?) ?? const [])
        if (x is Map && '${x['assetKey'] ?? ''}'.trim().isNotEmpty) Map<String, dynamic>.from(x),
    ];

/// 배치 비교용 서명. jsonb 는 키 순서를 바꾸므로 값만 순서대로 모은다.
String figureLayoutSignature(Map<String, dynamic>? layout) {
  String n(Object? v) => v is num ? v.toDouble().toStringAsFixed(2) : '${v ?? ''}';
  final parts = [
    for (final it in figureLayoutItems(layout))
      '${it['assetKey']}|${n(it['widthEm'])}|${it['position'] ?? ''}|${it['anchor'] ?? ''}|${n(it['offsetXEm'] ?? 0)}|${n(it['offsetYEm'] ?? 0)}',
  ]..sort();
  return parts.join(';');
}

/// 그림 폭(widthEm)을 배율만큼 바꾼 배치(4~40em, 0.5em 단위). [keys] 를 주면 그 그림만.
/// 기존 layout 에 항목이 비어 있어도 [fallbackAssets] 나 [fallbackCount] 가 있으면 기본 폭(20em)에서 배율을 곱해 항목을 만든다.
Map<String, dynamic> scaleFigureLayout(
  Map<String, dynamic> layout,
  double factor, {
  Set<String>? keys,
  List<Map<String, dynamic>> fallbackAssets = const [],
  int fallbackCount = 0,
}) {
  var baseItems = figureLayoutItems(layout);
  if (baseItems.isEmpty) {
    final ordered = orderedFigureAssets(fallbackAssets);
    if (ordered.isNotEmpty) {
      baseItems = [
        for (final a in ordered)
          {
            'assetKey': 'idx:${a['figure_index']}',
            'widthEm': 20.0,
            'position': 'below-stem',
            'anchor': 'center',
            'offsetXEm': 0,
            'offsetYEm': 0,
            'heightEm': 1.6,
          },
      ];
    } else if (fallbackCount > 0) {
      baseItems = [
        for (var i = 1; i <= fallbackCount; i++)
          {
            'assetKey': 'idx:$i',
            'widthEm': 20.0,
            'position': 'below-stem',
            'anchor': 'center',
            'offsetXEm': 0,
            'offsetYEm': 0,
            'heightEm': 1.6,
          },
      ];
    }
  }
  final items = [
    for (final it in baseItems)
      if (keys == null || keys.contains(it['assetKey']))
        {
          ...it,
          'widthEm': ((((it['widthEm'] as num?)?.toDouble() ?? 20) * factor).clamp(4.0, 40.0) * 2).round() / 2,
        }
      else
        it,
  ];
  return {...layout, 'version': layout['version'] ?? 1, 'items': items, 'groups': layout['groups'] ?? const []};
}

/// 그림 번호(figure_index)들을 뺀 그림 자산 목록과 배치. 같은 번호의 옛 크롭까지 모두 뺀다.
({List<Map<String, dynamic>> assets, Map<String, dynamic> layout}) withoutFigures(
  List<Map<String, dynamic>> assets,
  Map<String, dynamic> layout,
  Set<int> indexes,
) {
  final keys = {for (final i in indexes) 'idx:$i'};
  final items = layout['items'] is List ? layout['items'] as List : const [];
  final groups = <dynamic>[];
  for (final g in (layout['groups'] is List ? layout['groups'] as List : const [])) {
    if (g is! Map || g['members'] is! List) {
      groups.add(g);
      continue;
    }
    final rest = [for (final m in g['members'] as List) if (!keys.contains('$m')) m];
    if (rest.length > 1) groups.add({...g, 'members': rest});
  }
  return (
    assets: [
      for (final a in assets)
        if (!indexes.contains(int.tryParse('${a['figure_index'] ?? ''}'))) a,
    ],
    layout: {
      ...layout,
      'version': layout['version'] ?? 1,
      'items': [
        for (final it in items)
          if (it is! Map || !keys.contains('${it['assetKey']}')) it,
      ],
      'groups': groups,
    },
  );
}

/// 렌더 검수에서 그림 크기 비율(V2 ÷ 원본)이 이 범위 밖이면 크기를 다시 맞춘다(Edge FIGURE_SIZE_RATIO_* 와 같다).
const double kFigureSizeRatioMin = 0.9;
const double kFigureSizeRatioMax = 1.1;

/// 예전 흐름에서 승인된 문항은 승인 당시 범위(±15%)를 인정한다(Edge LEGACY_FIGURE_SIZE_RATIO_* 와 같다).
const double kLegacyFigureSizeRatioMin = 0.85;
const double kLegacyFigureSizeRatioMax = 1.15;

/// done/total 을 반올림한 퍼센트. 분모가 0이면 0.
int percentOf(int done, int total) {
  if (total <= 0) return 0;
  return ((done * 100) / total).round().clamp(0, 100);
}

/// 문항 번호 자연순 비교(예: '01' < '02' < '10', '109-2' < '109-10').
int naturalProblemNumberCompare(String a, String b) {
  final tokensA = RegExp(r'\d+|\D+').allMatches(a.trim()).map((m) => m.group(0)!).toList();
  final tokensB = RegExp(r'\d+|\D+').allMatches(b.trim()).map((m) => m.group(0)!).toList();
  final len = tokensA.length < tokensB.length ? tokensA.length : tokensB.length;
  for (var i = 0; i < len; i++) {
    final ta = tokensA[i];
    final tb = tokensB[i];
    final na = int.tryParse(ta);
    final nb = int.tryParse(tb);
    if (na != null && nb != null) {
      final cmp = na.compareTo(nb);
      if (cmp != 0) return cmp;
    } else {
      final cmp = ta.compareTo(tb);
      if (cmp != 0) return cmp;
    }
  }
  return tokensA.length.compareTo(tokensB.length);
}

/// 페이지 흐름(rawPage 오름차순) → 문항 번호 자연순 정렬.
int compareItemsByPageAndNumber(TextbookProblemReviewItem a, TextbookProblemReviewItem b) {
  final pageCmp = a.rawPage.compareTo(b.rawPage);
  if (pageCmp != 0) return pageCmp;
  final numCmp = naturalProblemNumberCompare(a.problemNumber, b.problemNumber);
  if (numCmp != 0) return numCmp;
  return a.cropId.compareTo(b.cropId);
}

/// 페이지·번호 흐름에서 감지된 누락 의심 문항 정보.
class MissingProblemGap {
  const MissingProblemGap({
    required this.missingNumber,
    required this.rawPage,
    this.displayPage,
    required this.subKey,
    required this.subIndex,
    required this.afterCropId,
  });

  final String missingNumber;
  final int rawPage;
  final int? displayPage;
  final String subKey;
  final int subIndex;
  final String afterCropId;
}

/// 정렬된 문항 목록에서 연속 번호 중 빠진 번호(예: 02번 다음 04번 → 03번 누락 의심)를 찾는다.
List<MissingProblemGap> detectMissingProblemGaps(List<TextbookProblemReviewItem> items) {
  if (items.length < 2) return const [];
  final sorted = [...items]..sort(compareItemsByPageAndNumber);
  final existingNums = <String>{for (final it in sorted) it.problemNumber.trim()};
  final gaps = <MissingProblemGap>[];
  for (var i = 0; i < sorted.length - 1; i++) {
    final cur = sorted[i];
    final next = sorted[i + 1];
    if (cur.subKey != next.subKey || cur.subIndex != next.subIndex) continue;
    if ((next.rawPage - cur.rawPage).abs() > 1) continue;
    final curMatch = RegExp(r'^(.*?)(\d+)$').firstMatch(cur.problemNumber.trim());
    final nextMatch = RegExp(r'^(.*?)(\d+)$').firstMatch(next.problemNumber.trim());
    if (curMatch == null || nextMatch == null) continue;
    final prefix = curMatch.group(1)!;
    if (prefix != nextMatch.group(1)!) continue;
    final n1 = int.tryParse(curMatch.group(2)!);
    final n2 = int.tryParse(nextMatch.group(2)!);
    if (n1 == null || n2 == null) continue;
    final diff = n2 - n1;
    if (diff > 1 && diff <= 4) {
      final padWidth = curMatch.group(2)!.startsWith('0') ? curMatch.group(2)!.length : 0;
      for (var m = n1 + 1; m < n2; m++) {
        final formatted = '$prefix${padWidth > 0 ? m.toString().padLeft(padWidth, '0') : m}';
        if (!existingNums.contains(formatted)) {
          gaps.add(MissingProblemGap(
            missingNumber: formatted,
            rawPage: cur.rawPage,
            displayPage: cur.displayPage,
            subKey: cur.subKey,
            subIndex: cur.subIndex,
            afterCropId: cur.cropId,
          ));
        }
      }
    }
  }
  return gaps;
}

class TextbookReviewUnitScope {
  const TextbookReviewUnitScope({
    required this.academyId,
    required this.bookId,
    required this.bookName,
    required this.gradeLabel,
    required this.bigOrder,
    required this.midOrder,
    required this.bigName,
    required this.midName,
    required this.problemCount,
    required this.analyzedCount,
    required this.mathCleanCount,
    required this.mathIssueCount,
    required this.mathApprovedCount,
    required this.qualityCleanCount,
    required this.qualityIssueCount,
    required this.qualityApprovedCount,
    this.qualityHeldCount = 0,
    this.bothApprovedCount = 0,
  });

  factory TextbookReviewUnitScope.fromJson(Map<String, dynamic> m) => TextbookReviewUnitScope(
        academyId: '${m['academy_id'] ?? ''}',
        bookId: '${m['book_id'] ?? ''}',
        bookName: '${m['book_name'] ?? ''}',
        gradeLabel: '${m['grade_label'] ?? ''}',
        bigOrder: (m['big_order'] as num?)?.toInt() ?? 1,
        midOrder: (m['mid_order'] as num?)?.toInt() ?? 1,
        bigName: '${m['big_name'] ?? ''}',
        midName: '${m['mid_name'] ?? ''}',
        problemCount: (m['problem_count'] as num?)?.toInt() ?? 0,
        analyzedCount: (m['analyzed_count'] as num?)?.toInt() ?? 0,
        mathCleanCount: (m['math_clean_count'] as num?)?.toInt() ?? 0,
        mathIssueCount: (m['math_issue_count'] as num?)?.toInt() ?? 0,
        mathApprovedCount: (m['math_approved_count'] as num?)?.toInt() ?? 0,
        qualityCleanCount: (m['quality_clean_count'] as num?)?.toInt() ?? 0,
        qualityIssueCount: (m['quality_issue_count'] as num?)?.toInt() ?? 0,
        qualityApprovedCount: (m['quality_approved_count'] as num?)?.toInt() ?? 0,
        qualityHeldCount: (m['quality_held_count'] as num?)?.toInt() ?? 0,
        bothApprovedCount: (m['both_approved_count'] as num?)?.toInt() ?? 0,
      );

  final String academyId;
  final String bookId;
  final String bookName;
  final String gradeLabel;
  final int bigOrder;
  final int midOrder;
  final String bigName;
  final String midName;
  final int problemCount;
  final int analyzedCount;
  final int mathCleanCount;
  final int mathIssueCount;
  final int mathApprovedCount;
  final int qualityCleanCount;
  final int qualityIssueCount;
  final int qualityApprovedCount;

  /// 렌더 엔진 문제로 보류된 문항 수. 품질 진행률 분모에서 빼고 따로 관리한다.
  final int qualityHeldCount;

  /// 수학·품질이 모두 승인된 문항 수. 교재·중단원 드롭다운 진행률의 분자.
  final int bothApprovedCount;

  /// 품질 검수 분모: 엔진 보류를 뺀 문항 수(승인한 것은 완료로 집계).
  int get qualityTargetCount => (problemCount - qualityHeldCount).clamp(0, problemCount);

  /// (수학·품질 모두 승인) / 전체 문항. 문항이 없으면 0.
  int get bothApprovedPercent => percentOf(bothApprovedCount, problemCount);

  String get key => '$academyId|$bookId|$gradeLabel|$bigOrder|$midOrder';
  String get bookTitle => '$bookName ($gradeLabel)';
  String get unitTitle => '$bigOrder. $bigName › $midOrder. $midName ($problemCount문항)';
}

class TextbookProblemReviewItem {
  const TextbookProblemReviewItem({
    required this.cropId,
    required this.pbQuestionId,
    required this.questionUid,
    required this.documentId,
    required this.subKey,
    required this.subIndex,
    required this.itemName,
    required this.problemNumber,
    required this.label,
    required this.rawPage,
    required this.displayPage,
    required this.storageBucket,
    required this.storageKey,
    required this.answerKind,
    required this.existingAnswer,
    required this.answerManual,
    required this.hasSolutionRef,
    required this.solutionRawPage,
    required this.solutionSourceKind,
    required this.solutionRegion1k,
    required this.stem,
    required this.commonStem,
    required this.setType,
    required this.setHeaderNumber,
    required this.questionType,
    required this.choices,
    required this.solutionTranscribed,
    required this.solutionAnswer,
    required this.solutionSource,
    required this.alternativeSolutions,
    required this.aiSolution,
    required this.aiAnswer,
    required this.matchMode,
    required this.answerMatched,
    required this.mismatchReason,
    required this.conceptScore,
    required this.thinkingScore,
    required this.arithmeticScore,
    required this.totalDifficulty,
    required this.visualTags,
    required this.qualityChecks,
    required this.renderChecks,
    required this.renderCheckedAt,
    required this.draftProposals,
    required this.mathStatus,
    required this.qualityStatus,
    required this.concepts,
    required this.thinkings,
    required this.arithmetics,
    required this.findings,
    this.rawChoices = const [],
    this.pbObjectiveAnswerKey = '',
    this.pbSubjectiveAnswer = '',
    this.pbAllowObjective = false,
    this.pbAllowSubjective = false,
    this.pbAllowEssay = false,
    this.pbObjectiveChoiceCount = 0,
    this.fixProposal = const {},
    this.engineHoldNote,
    this.engineHeldAt,
    this.engineResolvedAt,
    this.engineHoldSnapshot = const {},
    this.itemRegion1k = const [],
    this.setHeaderRawPage,
    this.setHeaderRegion1k = const [],
    this.pbFigureAssets = const [],
    this.pbFigureLayout = const {},
    this.answerRawPage,
    this.answerBbox1k = const [],
    this.answerImageBucket = '',
    this.answerImagePath = '',
    this.solutionFigureAssets = const [],
    this.solutionFiguresCheckedAt,
    this.solutionExtractedAt,
    this.solutionContinuations = const [],
    this.stagedChanges = const {},
    this.dbValues = const {},
    this.conceptProposals = const [],
    this.metaCheckedAt,
    this.metaSources = const {},
    this.consistencyIssues = const [],
  });

  factory TextbookProblemReviewItem.fromJson(Map<String, dynamic> m) {
    List<Map<String, dynamic>> mapList(Object? v) => [
          for (final x in (v is List ? v : const []))
            if (x is Map) Map<String, dynamic>.from(x),
        ];
    List<int> ints(Object? v) => [
          for (final x in (v is List ? v : const []))
            if (x is num) x.toInt(),
        ];
    return TextbookProblemReviewItem(
      cropId: '${m['crop_id'] ?? ''}',
      pbQuestionId: '${m['pb_question_id'] ?? ''}'.trim(),
      questionUid: '${m['question_uid'] ?? ''}'.trim(),
      documentId: '${m['document_id'] ?? ''}'.trim(),
      subKey: '${m['sub_key'] ?? ''}',
      subIndex: (m['sub_index'] as num?)?.toInt() ?? 0,
      itemName: '${m['item_name'] ?? ''}',
      problemNumber: '${m['problem_number'] ?? ''}',
      label: '${m['label'] ?? ''}',
      rawPage: (m['raw_page'] as num?)?.toInt() ?? 0,
      displayPage: (m['display_page'] as num?)?.toInt(),
      storageBucket: '${m['storage_bucket'] ?? 'textbook-crops'}',
      storageKey: '${m['storage_key'] ?? ''}',
      answerKind: '${m['answer_kind'] ?? ''}',
      existingAnswer: '${m['existing_answer'] ?? ''}',
      answerManual: m['answer_manual'] == true,
      hasSolutionRef: m['has_solution_ref'] == true,
      solutionRawPage: (m['solution_raw_page'] as num?)?.toInt(),
      solutionSourceKind: '${m['solution_source_kind'] ?? 'sol'}'.trim(),
      solutionRegion1k: [
        for (final x in (m['solution_region_1k'] as List?) ?? const [])
          if (x is num) x.toInt(),
      ],
      stem: '${m['stem'] ?? ''}',
      // 종속형 세트는 본문(stem)만 그려지므로 공통 발문을 따로 두지 않는다(Edge withoutDependentSetCommonStem 과 같다).
      commonStem: '${m['set_type'] ?? ''}'.trim() == 'dependent_set' ? '' : '${m['common_stem'] ?? ''}'.trim(),
      setType: '${m['set_type'] ?? ''}'.trim(),
      setHeaderNumber: '${m['set_header_number'] ?? ''}'.trim(),
      questionType: '${m['question_type'] ?? ''}',
      choices: [
        for (final x in (m['choices'] as List?) ?? const [])
          x is Map ? '${x['label'] ?? ''} ${x['text'] ?? ''}'.trim() : '$x',
      ],
      rawChoices: mapList(m['choices']),
      pbObjectiveAnswerKey: '${m['pb_objective_answer_key'] ?? ''}'.trim(),
      pbSubjectiveAnswer: '${m['pb_subjective_answer'] ?? ''}'.trim(),
      pbAllowObjective: m['pb_allow_objective'] == true,
      pbAllowSubjective: m['pb_allow_subjective'] == true,
      pbAllowEssay: m['pb_allow_essay'] == true,
      pbObjectiveChoiceCount: m['objective_choices'] is List
          ? [for (final c in m['objective_choices'] as List) if (c is Map && '${c['text'] ?? ''}'.trim().isNotEmpty) c].length
          : 0,
      fixProposal: m['fix_proposal'] is Map ? Map<String, dynamic>.from(m['fix_proposal'] as Map) : const <String, dynamic>{},
      engineHoldNote: m['engine_hold_note'] is String ? '${m['engine_hold_note']}' : null,
      engineHeldAt: m['engine_held_at'] is String ? DateTime.tryParse('${m['engine_held_at']}') : null,
      engineResolvedAt: m['engine_resolved_at'] is String ? DateTime.tryParse('${m['engine_resolved_at']}') : null,
      engineHoldSnapshot:
          m['engine_hold_snapshot'] is Map ? Map<String, dynamic>.from(m['engine_hold_snapshot'] as Map) : const <String, dynamic>{},
      itemRegion1k: ints(m['item_region_1k']),
      setHeaderRawPage: (m['set_header_raw_page'] as num?)?.toInt(),
      setHeaderRegion1k: ints(m['set_header_region_1k']),
      pbFigureAssets: mapList(m['pb_figure_assets']),
      pbFigureLayout:
          m['pb_figure_layout'] is Map ? Map<String, dynamic>.from(m['pb_figure_layout'] as Map) : const <String, dynamic>{},
      answerRawPage: (m['answer_raw_page'] as num?)?.toInt(),
      answerBbox1k: ints(m['answer_bbox_1k']),
      answerImageBucket: '${m['answer_image_bucket'] ?? ''}'.trim(),
      answerImagePath: '${m['answer_image_path'] ?? ''}'.trim(),
      solutionFigureAssets: mapList(m['solution_figure_assets']),
      solutionFiguresCheckedAt:
          m['solution_figures_checked_at'] is String ? DateTime.tryParse('${m['solution_figures_checked_at']}') : null,
      solutionExtractedAt:
          m['solution_extracted_at'] is String ? DateTime.tryParse('${m['solution_extracted_at']}') : null,
      solutionContinuations: [
        for (final c in mapList(m['solution_continuations']))
          if ((c['raw_page'] as num?) != null && ints(c['region_1k']).length == 4)
            TextbookSolutionSegment((c['raw_page'] as num).toInt(), ints(c['region_1k'])),
      ],
      solutionTranscribed: m['solution_transcribed'] is String
          ? cleanSolutionTranscribedText(
              '${m['solution_transcribed']}',
              problemNumber: '${m['problem_number'] ?? ''}',
              solutionAnswer: m['solution_answer'] is String ? '${m['solution_answer']}' : null,
            )
          : null,
      solutionAnswer: m['solution_answer'] is String ? '${m['solution_answer']}' : null,
      solutionSource: m['solution_source'] is String ? '${m['solution_source']}' : null,
      alternativeSolutions: mapList(m['alternative_solutions']),
      aiSolution: m['ai_solution'] is String ? '${m['ai_solution']}' : null,
      aiAnswer: m['ai_answer'] is String ? '${m['ai_answer']}' : null,
      matchMode: '${m['match_mode'] ?? '2way'}',
      answerMatched: m['answer_matched'] is bool ? m['answer_matched'] as bool : null,
      mismatchReason: m['mismatch_reason'] is String ? '${m['mismatch_reason']}' : null,
      conceptScore: (m['concept_score'] as num?)?.toDouble() ?? 0.0,
      thinkingScore: (m['thinking_score'] as num?)?.toDouble() ?? 0.0,
      arithmeticScore: (m['arithmetic_score'] as num?)?.toDouble() ?? 0.0,
      totalDifficulty: (m['total_difficulty'] as num?)?.toDouble() ?? 0.0,
      visualTags: [for (final x in (m['visual_tags'] as List?) ?? const []) '$x'],
      qualityChecks: m['quality_checks'] is Map
          ? Map<String, dynamic>.from(m['quality_checks'] as Map)
          : const <String, dynamic>{},
      renderChecks: m['render_checks'] is Map
          ? Map<String, dynamic>.from(m['render_checks'] as Map)
          : const <String, dynamic>{},
      renderCheckedAt: m['render_checked_at'] is String ? DateTime.tryParse('${m['render_checked_at']}') : null,
      draftProposals: mapList(m['draft_proposals']),
      mathStatus: '${m['math_status'] ?? 'pending'}',
      qualityStatus: '${m['quality_status'] ?? 'pending'}',
      concepts: mapList(m['concepts']),
      thinkings: mapList(m['thinkings']),
      arithmetics: mapList(m['arithmetics']),
      findings: mapList(m['findings']),
      stagedChanges:
          m['staged_changes'] is Map ? Map<String, dynamic>.from(m['staged_changes'] as Map) : const <String, dynamic>{},
      dbValues: m['db_values'] is Map ? Map<String, dynamic>.from(m['db_values'] as Map) : const <String, dynamic>{},
      conceptProposals: mapList(m['concept_proposals']),
      metaCheckedAt: m['meta_checked_at'] is String ? DateTime.tryParse('${m['meta_checked_at']}') : null,
      metaSources:
          m['meta_sources'] is Map ? Map<String, dynamic>.from(m['meta_sources'] as Map) : const <String, dynamic>{},
      consistencyIssues: mapList(m['consistency_issues']),
    );
  }

  final String cropId;
  final String pbQuestionId;
  final String questionUid;
  final String documentId;
  final String subKey;
  final int subIndex;
  final String itemName;
  final String problemNumber;
  final String label;
  final int rawPage;
  final int? displayPage;
  final String storageBucket;
  final String storageKey;
  final String answerKind;
  final String existingAnswer;
  final bool answerManual;
  final bool hasSolutionRef;
  final int? solutionRawPage;

  /// 'sol' 해설 PDF · 'body' 본문 PDF · 'none' 출판사 미제공
  final String solutionSourceKind;

  /// [ymin, xmin, ymax, xmax] 0..1000 — 해설 PDF 쪽 안의 풀이 영역(content 우선, 없으면 번호 영역)
  final List<int> solutionRegion1k;

  /// 풀이가 단 맨 아래에서 끊겨 다음 단(같은 쪽 오른쪽 단 또는 다음 쪽 왼쪽 단) 맨 위로 이어지는 부분
  final List<TextbookSolutionSegment> solutionContinuations;

  /// 해설 PDF 에서 잘라 이어 붙일 풀이 조각(첫 조각은 저장된 해설 영역)
  List<TextbookSolutionSegment> get solutionSegments => [
        if (canCropSolution) TextbookSolutionSegment(solutionRawPage!, solutionRegion1k),
        if (canCropSolution) ...solutionContinuations,
      ];
  final String stem;
  final String commonStem;
  final String setType;
  final String setHeaderNumber;
  final String questionType;
  final List<String> choices;
  final String? solutionTranscribed;
  final String? solutionAnswer;

  /// 'textbook_vision' 해설 PDF 좌표 영역을 Vision이 전사 · 'manual' 운영자 입력 · null 없음
  final String? solutionSource;

  /// 추후 확장용 대안 풀이. [{id, source, title, solution, answer, created_at}]
  final List<Map<String, dynamic>> alternativeSolutions;
  final String? aiSolution;
  final String? aiAnswer;
  final String matchMode;
  final bool? answerMatched;
  final String? mismatchReason;
  final double conceptScore;
  final double thinkingScore;
  final double arithmeticScore;
  final double totalDifficulty;
  final List<String> visualTags;
  final Map<String, dynamic> qualityChecks;

  /// V2 렌더 학생 시점 검수 결과 {problem_ok, answer_ok, solution_ok, issue_title, issue_detail, solution_kind}
  final Map<String, dynamic> renderChecks;
  final DateTime? renderCheckedAt;
  final List<Map<String, dynamic>> draftProposals;
  final String mathStatus;
  final String qualityStatus;
  final List<Map<String, dynamic>> concepts;
  final List<Map<String, dynamic>> thinkings;
  final List<Map<String, dynamic>> arithmetics;
  final List<Map<String, dynamic>> findings;

  /// 소단원 확정 때 반영할 값(textbook_problem_analyses.staged_changes). 본문·정답 등 위 필드는 이미 이 값을 겹친 모습이다.
  final Map<String, dynamic> stagedChanges;

  /// 반영 대기 값을 겹치기 전 문제은행·정답 원래 값(overview db_values)
  final Map<String, dynamic> dbValues;

  /// 라이브러리에 맞는 개념이 없어 AI가 낸 새 개념 초안 [{name, type, content, near_concept_id, reason}]. 확정 때 만든다.
  final List<Map<String, dynamic>> conceptProposals;

  /// 단원 기준 개념 후보로 개념·사고를 고른 시각. 비어 있으면 예전 후보 목록에서 고른 태그이거나 아직 고르지 않았다.
  final DateTime? metaCheckedAt;

  /// 사람이 고친 메타 {"concepts": "owner", "thinkings": "owner"}. AI 재실행이 덮어쓰지 않는다.
  final Map<String, dynamic> metaSources;

  /// 코드 정합성 점검(사양 5-2)이 남긴 열린 지적 [{id, code, axis, title, detail, status}].
  /// 일반 지적(findings)과 따로 온다. 고치거나 "문제 없음"으로 닫기 전에는 준비됨이 아니다.
  final List<Map<String, dynamic>> consistencyIssues;

  static const Map<String, String> stagedFieldNames = {
    'stem': '개별 발문',
    'common_stem': '공통 발문',
    'choices': '선지',
    'figure_layout': '그림 크기·배치',
    'figure_assets': '원본 크롭 그림',
    'answer': '정답',
    'solution_transcribed': '해설',
    'solution_answer': '해설 정답',
    'question_kind': '문항 유형',
    'allow_subjective': '주관식 겸용',
  };

  /// 반영 대기 중인 항목 키(확정 때 문제은행·정답에 들어간다)
  List<String> get stagedFields => [for (final k in stagedFieldNames.keys) if (stagedChanges.containsKey(k)) k];
  bool get hasStagedChanges => stagedFields.isNotEmpty;
  bool stagedByOwner(String field) =>
      stagedChanges['sources'] is Map && (stagedChanges['sources'] as Map)[field] == 'owner';

  /// 반영 대기 내역 한 줄 요약. 없으면 null.
  String? get stagedSummary {
    final fields = stagedFields;
    if (fields.isEmpty) return null;
    return '확정 때 반영: ${[for (final f in fields) stagedFieldNames[f]!].join('·')}';
  }

  /// 확정 전 V2 카드를 반영 대기 값으로 찍을 때 게이트웨이에 넘기는 덮어쓰기 값(batch-render questionOverrides)
  Map<String, dynamic>? get previewOverride {
    final s = stagedChanges;
    final o = <String, dynamic>{
      if (s.containsKey('stem')) 'stem': stem,
      if (s.containsKey('choices')) 'choices': rawChoices,
      if (s.containsKey('common_stem')) 'common_stem': commonStem,
      if (s.containsKey('figure_assets')) 'figure_assets': pbFigureAssets,
      if (s.containsKey('figure_layout')) 'figure_layout': pbFigureLayout,
      if (s.containsKey('question_kind')) ...{
        'question_type': questionType,
        'allow_objective': pbAllowObjective,
        'allow_subjective': pbAllowSubjective,
      },
    };
    return o.isEmpty ? null : o;
  }

  /// 정답 축 판정이 통과(AI 통과 또는 확정 승인)
  bool get mathOk => mathStatus == 'clean' || mathStatus == 'approved';

  /// 문항 축 판정이 통과(AI 통과 또는 확정 승인)
  bool get qualityOk => qualityStatus == 'clean' || qualityStatus == 'approved';

  /// 문제은행 선지 원형 [{label, text}]. 수정 적용 때 그대로 보낸다.
  final List<Map<String, dynamic>> rawChoices;

  /// 문제은행 사본의 정답(적재 확인이 채점 정답과 대조하는 값)
  final String pbObjectiveAnswerKey;
  final String pbSubjectiveAnswer;
  final bool pbAllowObjective;
  final bool pbAllowSubjective;
  final bool pbAllowEssay;

  /// 문제은행 객관식 보기 수(원문 선지 또는 AI 가 만든 보기)
  final int pbObjectiveChoiceCount;

  /// 문제은행에 표시된 유형: objective | subjective | essay | '' (미분류). 문제은행 화면 배지와 같은 기준.
  String get currentQuestionKind {
    final t = questionType.trim();
    if (t.contains('서술')) return 'essay';
    if (t.contains('객관식')) return 'objective';
    if (t.contains('주관식')) return 'subjective';
    if (pbAllowEssay && pbAllowSubjective) return 'essay';
    if (pbAllowObjective && !pbAllowSubjective) return 'objective';
    if (pbAllowSubjective && !pbAllowObjective) return 'subjective';
    return '';
  }

  /// 발문에 들어 있는 서술형 표현(있으면 무조건 서술형)
  String? get essayKeyword => kEssayPattern.firstMatch(displayStem)?.group(0);

  /// 규칙 기준 유형: 서술형 표현 → essay, 선지 2개 이상 → objective, 그 외 subjective
  String get expectedQuestionKind => essayKeyword != null ? 'essay' : (rawChoices.length >= 2 ? 'objective' : 'subjective');

  /// AI(2단계)가 본 유형
  String? get aiQuestionKind {
    final v = '${qualityChecks['question_kind_ai'] ?? ''}';
    return const {'objective', 'subjective', 'essay'}.contains(v) ? v : null;
  }

  /// 채점 정답의 선지 번호 수(①, ④ → 2). 원문자가 아닌 글자가 섞이면 0.
  int get answerChoiceCount {
    final a = existingAnswer.replaceAll(RegExp(r'[\s,，、ㆍ·/]'), '');
    if (a.isEmpty || !RegExp(r'^[①②③④⑤⑥⑦⑧⑨⑩]+$').hasMatch(a)) return 0;
    return a.runes.toSet().length;
  }

  /// 객관식 문항을 주관식으로도 낼 수 있는가: 답이 선지 하나이고, 발문이 선지를 가리키지 않으며(다음 중·옳은 것 등),
  /// 선지가 ㄱ·ㄴ·ㄷ 조합이 아니다.
  bool get subjectiveAlsoPossible {
    if (rawChoices.length < 2) return true;
    if (essayKeyword != null || answerChoiceCount != 1) return false;
    if (kChoiceReferencePattern.hasMatch('$commonStem\n$displayStem')) return false;
    final picked = rawChoices.firstWhere(
      (c) => '${c['label'] ?? ''}'.trim() == existingAnswer.replaceAll(RegExp(r'\s'), ''),
      orElse: () => const <String, dynamic>{},
    );
    final text = '${picked['text'] ?? ''}'.trim();
    return text.isNotEmpty && !RegExp(r'^[ㄱ-ㅎ](\s*[,，]\s*[ㄱ-ㅎ])*$').hasMatch(text);
  }

  /// 표시된 유형이 규칙 기준과 다르거나, 그 유형에 필요한 허용 표시가 빠져 있는가
  bool get questionKindMismatch {
    if (pbQuestionId.isEmpty) return false;
    final want = expectedQuestionKind;
    if (currentQuestionKind != want) return true;
    return switch (want) {
      'objective' => !pbAllowObjective || (answerChoiceCount > 0 && pbAllowSubjective != subjectiveAlsoPossible),
      'essay' => !pbAllowSubjective || !pbAllowEssay || pbAllowObjective,
      _ => !pbAllowSubjective || pbAllowEssay,
    };
  }

  /// AI 데이터 수정 제안 {kind, stem, choices, reason, source, created_at, applied_at?, applied_fields?}
  final Map<String, dynamic> fixProposal;

  /// 렌더 엔진 보류(quality_status == 'held') 정보
  final String? engineHoldNote;
  final DateTime? engineHeldAt;
  final DateTime? engineResolvedAt;
  final Map<String, dynamic> engineHoldSnapshot;

  /// 본문 PDF 쪽(raw_page) 안의 문항 영역 [ymin, xmin, ymax, xmax] 0..1000 (item_region_1k, 없으면 bbox_1k)
  final List<int> itemRegion1k;

  /// 세트 문항이면 세트 머리(공통 지시문) 크롭의 쪽·영역
  final int? setHeaderRawPage;
  final List<int> setHeaderRegion1k;

  /// 문제은행 그림 자산(meta.figure_assets 원본)과 배치(meta.figure_layout)
  final List<Map<String, dynamic>> pbFigureAssets;
  final Map<String, dynamic> pbFigureLayout;

  /// 답지 PDF 안의 정답 영역(해설 좌표가 따로 없는 문항이나 표·이미지 정답 대조용)
  final int? answerRawPage;
  final List<int> answerBbox1k;

  /// 그림 정답(answer_kind == 'image')을 정답 PDF 에서 잘라 둔 이미지
  final String answerImageBucket;
  final String answerImagePath;

  /// 원본 해설 속 그림(해설 PDF 에서 잘라 둠). 전사본의 [그림] 표시 순서와 figure_index 가 대응한다.
  final List<Map<String, dynamic>> solutionFigureAssets;

  /// 해설 그림 찾기를 마친 시각(그림이 없어도 기록)
  final DateTime? solutionFiguresCheckedAt;

  /// 원본 해설을 마지막으로 전사(추출)한 시각
  final DateTime? solutionExtractedAt;

  /// 렌더 검수 뒤에 해설을 다시 전사해, 남은 렌더 판정이 지금 카드와 다를 수 있다.
  bool get renderCheckStale =>
      renderCheckedAt != null && solutionExtractedAt != null && solutionExtractedAt!.isAfter(renderCheckedAt!);

  bool get hasAnswerImage =>
      answerKind == 'image' && !imageAnswerReplacedByOwner && answerImageBucket.isNotEmpty && answerImagePath.isNotEmpty;

  /// 그림 정답을 운영자가 글자 정답으로 고쳐 반영 대기에 넣었다. 확정 때 그림 정답이 이 글자 정답으로 바뀌므로
  /// (textbook_review_apply_staged) 확정 전 카드·판정도 글자 정답으로 본다.
  bool get imageAnswerReplacedByOwner =>
      answerKind == 'image' &&
      stagedByOwner('answer') &&
      existingAnswer.trim().isNotEmpty &&
      !_imagePlaceholderAnswerRe.hasMatch(existingAnswer.trim());

  /// 정답+해설 카드 캐시 키 원문(글자·그림 정답·해설 그림이 바뀌면 달라진다)
  String get answerSolutionCardSource => '$displayAnswer\n$primarySolutionText\n'
      '${hasAnswerImage ? answerImagePath : ''}\n'
      '${solutionFigureAssets.map((a) => '${a['path']}:${a['width_em']}:${a['placement'] ?? ''}').join(',')}';

  /// 원본 해설에 그림이 있을 수 있는데(그림을 가리키는 문장·[그림] 표시, 또는 렌더 검수가 해설 그림 누락으로 판정)
  /// 아직 해설 PDF 에서 그림을 찾지 않은 문항
  bool get needsSolutionFigures =>
      solutionFiguresCheckedAt == null &&
      canCropSolution &&
      hasOriginalSolution &&
      (kSolutionFigureHintPattern.hasMatch(solutionTranscribed!) || renderFlagsSolutionFigure);

  /// 렌더 검수가 원본 해설과 대조해 해설 카드에 그림이 빠졌다고 판정
  bool get renderFlagsSolutionFigure => renderChecks['solution_ok'] == false && renderChecks['issue_kind'] == 'figure';

  bool get canRenderOriginal => rawPage > 0 && itemRegion1k.length == 4;
  bool get canRenderSetHeader => (setHeaderRawPage ?? 0) > 0 && setHeaderRegion1k.length == 4;
  bool get canCropAnswer => (answerRawPage ?? 0) > 0 && answerBbox1k.length == 4;

  /// 그림이 있는 문항(그림 자산이 있거나 본문에 그림 자리가 있음)
  bool get hasFigures => orderedFigureAssets(pbFigureAssets).isNotEmpty || figureMarkerCount(stem) > 0;

  /// 원본 대조 수정 단계(textbook_problem_fix)를 이번 풀이 뒤에 돌렸는가
  DateTime? get fixPassAt => fixProposal['fix_pass_at'] is String ? DateTime.tryParse('${fixProposal['fix_pass_at']}') : null;
  DateTime? get fixAppliedAt => fixProposal['applied_at'] is String ? DateTime.tryParse('${fixProposal['applied_at']}') : null;

  /// AI·규칙 수정안이 DB 에 반영된 내역 한 줄 요약. 반영된 적이 없으면 null.
  String? get appliedFixSummary {
    if (fixAppliedAt == null) return null;
    final fields = [
      for (final x in (fixProposal['applied_fields'] is List ? fixProposal['applied_fields'] as List : const []))
        switch ('$x') {
          'common_stem' => '공통 발문',
          'stem' => '개별 발문',
          'choices' => '선지',
          'figure_assets' => '원본 크롭 그림',
          'figure_layout' => '그림 크기·배치',
          _ => '$x',
        },
    ];
    final note = '${fixProposal['applied_note'] ?? ''}'.trim();
    final reason = '${fixProposal['reason'] ?? ''}'.trim();
    final parts = <String>[
      if (fields.isNotEmpty) '${fields.join('·')} DB 반영 완료' else if (note.isNotEmpty) '$note 완료' else '수정안 DB 반영 완료',
      if (fields.isNotEmpty && note.isNotEmpty) note,
      if (reason.isNotEmpty && reason != note) reason,
    ];
    return parts.join(' — ');
  }

  /// 수정 단계 대상:
  /// 1) 수학 오류가 있는데 아직 정답 수정안(proposedAnswer)이나 2:1 합의 답이 없는 문항(원본 PDF + 정답/해설 PDF 대조 필요),
  /// 2) 해설 좌표가 어긋나 Vision 이 원본 해설을 찾지 못한 문항(해설 PDF 쪽 전체 탐색으로 복구 필요),
  /// 3) 품질 오류 문항·그림 문항(승인·보류·미검수 제외)과, 품질 승인 뒤라도 2단계/4단계에서 공통 발문·지시문 누락이나 원본 불일치가 남아 있는 문항.
  bool get needsFixPass {
    if (!canRenderOriginal || isEngineHeld) return false;
    final mathNeedsFixPass = mathStatus == 'issue' &&
        proposedAnswer == null &&
        !solutionAndAiAgreeAgainstExisting &&
        !existingConfirmedByAi &&
        !existingMatchesSolution &&
        fixPassAt == null;
    if (mathNeedsFixPass) return true;
    if (solutionVisionFailed && fixPassAt == null) return true;

    final hasTextDiscrepancy = qualityChecks['stem_ok'] == false ||
        qualityChecks['fidelity_ok'] == false ||
        renderChecks['problem_ok'] == false ||
        renderChecks['fidelity_ok'] == false ||
        isCorruptedCommonStem(commonStem) ||
        approvedButDiffers;
    if (qualityStatus == 'approved') {
      if (!hasTextDiscrepancy || stage2Superseded) return false;
    } else if (qualityStatus != 'issue' && qualityStatus != 'clean') {
      return false;
    } else if (qualityStatus == 'clean' && !hasFigures && !hasTextDiscrepancy) {
      return false;
    }
    if (hasPendingFixProposal || hasPendingFigureProposal) return false;
    final ran = fixPassAt;
    if (ran == null) return true;
    final applied = fixAppliedAt;
    if (applied != null && applied.isAfter(ran)) return qualityStatus == 'issue' || hasTextDiscrepancy;
    // 이전 fix_pass 가 돌았지만 수정안을 하나도 못 냈고(당시 공통 발문 누락/판정 버그 등) 여전히 불일치가 남아 있으면 한 번 더 기회를 준다.
    return (qualityStatus == 'issue' || hasTextDiscrepancy) && fixProposal['text_matches_original'] != true;
  }

  /// 수정 단계가 낸 그림 배치(figure_layout)와 원본에서 다시 잘라낼 그림
  Map<String, dynamic>? get proposedFigureLayout =>
      fixProposal['figure_layout'] is Map ? Map<String, dynamic>.from(fixProposal['figure_layout'] as Map) : null;
  List<Map<String, dynamic>> get proposedFigureCrops => [
        for (final x in (fixProposal['figure_crops'] is List ? fixProposal['figure_crops'] as List : const []))
          if (x is Map) Map<String, dynamic>.from(x),
      ];

  /// 원본에는 있는데 본문에 그림 자리가 없어 수정 단계가 자동 등록에서 뺀 그림('해' 풀이 안내 속 그림일 수 있다).
  /// 아직 붙지 않은 것만. 사장님이 원본을 보고 붙인다.
  List<Map<String, dynamic>> get unslottedFigureCrops {
    final present = {
      for (final a in pbFigureAssets) int.tryParse('${a['figure_index'] ?? ''}'),
    }..remove(null);
    return [
      for (final x in (fixProposal['figure_crops_unslotted'] is List ? fixProposal['figure_crops_unslotted'] as List : const []))
        if (x is Map && !present.contains(int.tryParse('${x['figure_index'] ?? ''}'))) Map<String, dynamic>.from(x),
    ];
  }

  /// 수정 단계가 원본에서 문항 그림이 아니라고 본 그림 번호 중 아직 붙어 있는 것. 자동 적용하지 않고 사장님이 뺀다.
  List<int> get proposedFigureRemovals {
    final present = {
      for (final a in pbFigureAssets) int.tryParse('${a['figure_index'] ?? ''}'),
    }..remove(null);
    return [
      for (final x in (fixProposal['figure_removals'] is List ? fixProposal['figure_removals'] as List : const []))
        if (int.tryParse('$x') case final idx? when present.contains(idx)) idx,
    ];
  }

  /// 아직 적용하지 않은 그림 제안(배치가 지금과 다르거나 잘라 등록할 그림이 있음, 또는 그림 문항에서 원본 대조 배치를 아직 DB 에 반영하지 않음)
  bool get hasPendingFigureProposal {
    if (fixProposal['applied_at'] != null) return false;
    final layout = proposedFigureLayout;
    final layoutDiffers = layout != null && figureLayoutSignature(layout) != figureLayoutSignature(pbFigureLayout);
    return layoutDiffers || proposedFigureCrops.isNotEmpty;
  }

  /// 원본과 직접 대조한 V2 렌더 검수를 했는가
  bool get originalCompared => renderChecks['original_compared'] == true;

  /// 문제가 그림 크기뿐인 품질 오류. 잰 비율로 폭을 바로 고치면 되므로 원본 대조 수정안을 만들 필요가 없다.
  bool get figureSizeOnlyIssue =>
      qualityStatus == 'issue' && figureNeedsResize && issueKind == 'figure' && mathStatus != 'issue' && !solutionVisionFailed;

  /// 승인한 뒤 원본 대조에서 차이가 나온 문항(승인은 유지)
  bool get approvedButDiffers => qualityStatus == 'approved' && renderChecks['flagged_after_approval'] == true;

  /// 승인 문항인데 아직 원본과 대조하지 않음
  bool get needsOriginalRecheck => qualityStatus == 'approved' && !originalCompared && canRenderOriginal;

  /// V2 그림 크기 ÷ 원본 그림 크기(글자 대비). 원본 대조에서 잰 값.
  double? get figureSizeRatio => (renderChecks['figure_size_ratio'] as num?)?.toDouble();
  bool get figureNeedsResize => _figureRatioOutOfRange(figureSizeRatio);

  /// 해설 그림 크기 ÷ 원본 해설 그림 크기(글자 대비)
  double? get solutionFigureSizeRatio => (renderChecks['solution_figure_size_ratio'] as num?)?.toDouble();
  bool get solutionFigureNeedsResize => solutionFigureAssets.isNotEmpty && _figureRatioOutOfRange(solutionFigureSizeRatio);

  bool _figureRatioOutOfRange(double? r) {
    if (r == null || r <= 0) return false;
    final approved = qualityStatus == 'approved';
    return r < (approved ? kLegacyFigureSizeRatioMin : kFigureSizeRatioMin) ||
        r > (approved ? kLegacyFigureSizeRatioMax : kFigureSizeRatioMax);
  }

  String get previewLookupKey => questionUid.isNotEmpty ? questionUid : pbQuestionId;

  bool get isEngineHeld => qualityStatus == 'held';

  /// 2단계(문항 카드)·4단계(정답·해설 카드) 판정에서 AI 가 분류한 원인.
  /// 본문·공통발문 수정으로 고칠 수 있는 경우(data 또는 fidelity_ok=false)가 engine 보다 우선한다.
  String get issueKind {
    final a = '${qualityChecks['issue_kind'] ?? ''}';
    final b = '${renderChecks['issue_kind'] ?? ''}';
    if (a == 'figure' || b == 'figure') return 'figure';
    if (a == 'data' ||
        b == 'data' ||
        qualityChecks['fidelity_ok'] == false ||
        renderChecks['fidelity_ok'] == false ||
        hasPendingFixProposal) {
      return 'data';
    }
    if (a == 'engine' || b == 'engine') return 'engine';
    return 'none';
  }

  bool get aiSuspectsEngine =>
      qualityStatus == 'issue' &&
      issueKind == 'engine' &&
      qualityChecks['fidelity_ok'] != false &&
      renderChecks['fidelity_ok'] != false &&
      !hasPendingFixProposal;
  String get engineSymptom => '${renderChecks['engine_symptom'] ?? ''}'.trim();

  /// 수정 제안(공통 발문·개별 발문)이 이미 DB(pb_questions)에 반영되어 있는 상태인가(형제 세트 문항 일괄 갱신 등)
  bool get proposalAlreadyReflectedInDb {
    final pStem = proposedStem?.trim();
    final pCommon = proposedCommonStem?.trim();
    if (pStem == null && pCommon == null) return false;
    final stemMatches = pStem == null || sameRenderedMath(pStem, stem);
    final commonMatches = pCommon == null || sameRenderedMath(pCommon, commonStem);
    return stemMatches && commonMatches;
  }

  /// 아직 적용하지 않은 데이터 수정 제안이 있는가(개별 발문·공통 발문·선지 중 하나라도)
  bool get hasPendingFixProposal {
    if (fixProposal['applied_at'] != null) return false;
    final s = fixProposal['stem'];
    final cs = fixProposal['common_stem'];
    final c = fixProposal['choices'];
    String choiceTexts(List<dynamic> list) =>
        [for (final x in list) mathDelimiterInsensitive(x is Map ? '${x['text'] ?? ''}' : '$x')].join('\u0001');
    return (s is String && s.trim().isNotEmpty && !sameRenderedMath(s, stem)) ||
        (cs is String && cs.trim().isNotEmpty && !sameRenderedMath(cs, commonStem)) ||
        (c is List && c.isNotEmpty && choiceTexts(c) != choiceTexts(rawChoices));
  }

  /// V2 렌더러는 구분자 없는 LaTeX 도 수식으로 자동 인식한다. `$` 유무와 수식 기호 주변 공백만 다른 본문은 화면이 같다.
  static String mathDelimiterInsensitive(String text) => text
      .replaceAll(RegExp(r'(?<!\\)\$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'\s*\\'), r'\')
      .replaceAllMapped(RegExp(r'\s*([{}^_=+\-(),])\s*'), (m) => m[1]!)
      .trim();

  static bool sameRenderedMath(String a, String b) => mathDelimiterInsensitive(a) == mathDelimiterInsensitive(b);

  String? get proposedStem => fixProposal['stem'] is String && '${fixProposal['stem']}'.trim().isNotEmpty ? '${fixProposal['stem']}' : null;

  /// 공통 발문이 개별 발문에도 들어 있어 학생 화면에 지시문이 두 번 보이는 상태인가(규칙 판정, AI 결과와 무관)
  bool get commonStemDuplicated => commonStemFix != null;

  /// 공통 발문 중복을 고치는 변경(개별 발문 새 값, 필요하면 공통 발문 새 값). 중복이 없으면 null.
  CommonStemFix? get commonStemFix => computeCommonStemFix(commonStem, stem);

  /// 개별 발문에서 공통 발문 부분을 뗀 본문. 중복이 없으면 null.
  String? get stemWithoutCommonStem => commonStemFix?.stem;

  /// 저장된 수정 제안이 "공통 발문 중복 제거" 규칙 제안인가
  bool get fixProposalIsCommonStemDup => fixProposal['reason_code'] == 'common_stem_duplicate';

  /// 수정 제안에 포함된 공통 발문 새 값(공통 발문에 개별 본문이 섞여 있던 경우)
  String? get proposedCommonStem =>
      fixProposal['common_stem'] is String && '${fixProposal['common_stem']}'.trim().isNotEmpty ? '${fixProposal['common_stem']}' : null;

  /// 원본 PDF + 정답/해설 PDF 대조(또는 3단계 대조)에서 제시된 정답 수정안
  String? get proposedAnswer {
    final direct = fixProposal['proposed_answer'];
    if (direct is String && direct.trim().isNotEmpty && direct.trim() != '판단불가') {
      return direct.trim();
    }
    for (final f in findings) {
      if (f['axis'] == 'validity' && f['proposal'] is Map) {
        final after = (f['proposal'] as Map)['after'];
        final val = after is Map ? '${after['value'] ?? ''}'.trim() : '';
        if (val.isNotEmpty && val != '판단불가') return val;
      }
    }
    return null;
  }

  String? get proposedAiAnswer =>
      fixProposal['proposed_ai_answer'] is String && '${fixProposal['proposed_ai_answer']}'.trim().isNotEmpty
          ? '${fixProposal['proposed_ai_answer']}'.trim()
          : null;
  String? get proposedAiSolution =>
      fixProposal['proposed_ai_solution'] is String && '${fixProposal['proposed_ai_solution']}'.trim().isNotEmpty
          ? '${fixProposal['proposed_ai_solution']}'.trim()
          : null;
  String? get proposedSolutionAnswer =>
      fixProposal['proposed_solution_answer'] is String && '${fixProposal['proposed_solution_answer']}'.trim().isNotEmpty
          ? '${fixProposal['proposed_solution_answer']}'.trim()
          : null;
  String? get proposedSolutionTranscribed =>
      fixProposal['proposed_solution_transcribed'] is String && '${fixProposal['proposed_solution_transcribed']}'.trim().isNotEmpty
          ? '${fixProposal['proposed_solution_transcribed']}'.trim()
          : null;
  String? get proposedMathReason =>
      fixProposal['math_reason'] is String && '${fixProposal['math_reason']}'.trim().isNotEmpty
          ? '${fixProposal['math_reason']}'.trim()
          : null;

  /// 해설 정답과 AI 정답이 서로 같은데 채점 정답만 다른가(일괄 채택 대상)
  bool get solutionAndAiAgreeAgainstExisting {
    final sol = normalizeAnswerForCompare(solutionAnswer ?? '');
    final ai = normalizeAnswerForCompare(aiAnswer ?? '');
    if (sol.isEmpty || ai.isEmpty || sol != ai) return false;
    return normalizeAnswerForCompare(existingAnswer) != sol;
  }

  /// 채점 정답과 AI 독립 풀이 답이 같다(해설 답이 없거나 달라도 2:1 다수결로 채점 정답 유지).
  bool get existingConfirmedByAi {
    final cur = normalizeAnswerForCompare(existingAnswer);
    final ai = normalizeAnswerForCompare(aiAnswer ?? '');
    return cur.isNotEmpty && cur == ai;
  }

  /// 채점 정답과 해설 정답이 같다(AI 답만 옛 본문 등으로 판단불가/불일치였을 때 2:1 로 채점 정답 유지).
  bool get existingMatchesSolution {
    final cur = normalizeAnswerForCompare(existingAnswer);
    final sol = normalizeAnswerForCompare(solutionAnswer ?? '');
    return cur.isNotEmpty && sol.isNotEmpty && cur == sol;
  }

  /// 수학 일괄 처리에서 DB 에 반영할 확정 정답(원본·해설 대조 수정안 → 해설·AI 합의 → 채점·AI 합의 → 채점·해설 합의 → 해설 정답 → AI 정답)
  String? get resolvedMathAnswer {
    if (proposedAnswer != null && proposedAnswer!.isNotEmpty) return proposedAnswer;
    if (solutionAndAiAgreeAgainstExisting && (solutionAnswer ?? '').trim().isNotEmpty) return solutionAnswer!.trim();
    if (existingConfirmedByAi && existingAnswer.trim().isNotEmpty) return existingAnswer.trim();
    if (existingMatchesSolution && existingAnswer.trim().isNotEmpty) return existingAnswer.trim();
    if ((solutionAnswer ?? '').trim().isNotEmpty && (solutionAnswer ?? '').trim() != '판단불가') return solutionAnswer!.trim();
    if ((aiAnswer ?? '').trim().isNotEmpty && (aiAnswer ?? '').trim() != '판단불가') return aiAnswer!.trim();
    if (existingAnswer.trim().isNotEmpty && !RegExp(r'^(\[?\s*image\s*\]?|\(\s*image\s*\)|\[그림\])$', caseSensitive: false).hasMatch(existingAnswer.trim())) {
      return existingAnswer.trim();
    }
    return null;
  }

  /// 자동 반영해도 되는 정답: 원본·해설 대조 수정안 또는 두 출처(해설·AI·채점 정답 중 둘)가 합의한 값.
  /// 해설 하나·AI 하나만의 답은 사람 확인 없이 승인하지 않는다.
  String? get agreedMathAnswer {
    if (proposedAnswer != null && proposedAnswer!.isNotEmpty && proposedAnswer != '판단불가') return proposedAnswer;
    if (solutionAndAiAgreeAgainstExisting && (solutionAnswer ?? '').trim().isNotEmpty) return solutionAnswer!.trim();
    if (existingConfirmedByAi && existingAnswer.trim().isNotEmpty) return existingAnswer.trim();
    if (existingMatchesSolution && existingAnswer.trim().isNotEmpty) return existingAnswer.trim();
    return null;
  }

  /// 수학 일괄의 두 규칙(해설·AI 일치 답 채택, 채점 정답 = AI 답 유지)으로 끝나지 않는 수학 오류.
  /// 본문을 고치기 전에 푼 AI 답(판단불가 등)일 수 있어 지금 본문·교재 원본으로 다시 푼다.
  bool get needsMathResolve => mathStatus == 'issue' && !solutionAndAiAgreeAgainstExisting && !existingConfirmedByAi;

  /// AI 가 풀 문항 내용(공통 발문·본문·선지·그림 수). 같은 내용으로 이미 다시 풀었는지 가릴 때 쓴다.
  String get problemTextSignature => [commonStem, stem, jsonEncode(rawChoices), '${pbFigureAssets.length}'].join('\u0001');
  List<Map<String, dynamic>>? get proposedChoices => fixProposal['choices'] is List
      ? [for (final x in fixProposal['choices'] as List) if (x is Map) Map<String, dynamic>.from(x)]
      : null;

  /// 채점 정답이 답지에서 잘라 저장한 그림이다. 문제은행에는 글자 대신 그림 표시가 들어간다.
  bool get isImageAnswer =>
      (answerKind == 'image' && !imageAnswerReplacedByOwner) || _imagePlaceholderAnswerRe.hasMatch(existingAnswer.trim());

  /// 2단계 작업 화면의 "준비됨"을 막는 이유. 비어 있으면 준비됨.
  List<String> get readyBlockers => [
        if (pbQuestionId.isEmpty) '본문 추출 전',
        if (isEngineHeld) '렌더 엔진 수정 필요',
        if (existingAnswer.trim().isEmpty) '채점 정답 없음',
        if (!hasSolutionRef && !solutionMarkedNone) '해설 위치 없음',
        if (!mathOk) '정답 검수 미통과',
        if (!isEngineHeld && !qualityOk) '문항 검수 미통과',
        if (!isEngineHeld && renderBlocksReady) 'V2 렌더 이상',
        if (openSolutionLogicFinding != null) '해설 논리 오류',
        if (openCorrectionNotes.isNotEmpty) '교정 의견 처리 필요',
        if (consistencyIssues.isNotEmpty)
          '정합성: ${{for (final f in consistencyIssues) '${f['title'] ?? ''}'.trim()}.where((t) => t.isNotEmpty).join(', ')}',
        if (missingMeta.isNotEmpty) '메타 누락: ${missingMeta.join(', ')}',
      ];
  bool get isWorkflowReady => readyBlockers.isEmpty;

  /// 교재 원본 오류로 보이는 교정 의견 중 사장님이 아직 처리하지 않은 것
  List<Map<String, dynamic>> get openCorrectionNotes => [
        for (final f in findings)
          if (f['proposal'] is Map && (f['proposal'] as Map)['target'] == 'correction_note') f,
      ];

  /// 원본 해설의 풀이 논리 오류(정답은 맞아도 준비됨이 아니다)
  Map<String, dynamic>? get openSolutionLogicFinding {
    for (final f in findings) {
      if (f['error_type'] == 'solution_logic' && !(f['proposal'] is Map && (f['proposal'] as Map)['target'] == 'correction_note')) {
        return f;
      }
    }
    return null;
  }

  /// 비어 있는 메타 필수 항목(사양 3-1, 3-3).
  /// - 개념: 확정 때 만들 새 개념 초안도 연결로 본다. 예전 후보 목록에서 고른 태그는 근거로 쓰지 않는다(사양 5-6).
  /// - 난이도: 개념·사고 점수는 연결에서, 계산 점수는 AI 풀이에서 나온다. 풀이 뒤 계산 점수 0은 "계산 없음"이다.
  /// - 시각 태그: 시각 요소가 없으면 "없음" 태그를 단다. 빈 목록은 누락이다.
  /// - 교재 라벨: 크롭 확정 때 사장님이 번호·본문과 함께 확인한다. 빈 라벨은 "없음"이다.
  List<String> get missingMeta {
    final solved = (aiSolution ?? '').trim().isNotEmpty;
    final kind = questionType.trim();
    return [
      if (concepts.isEmpty && conceptProposals.isEmpty)
        '개념 연결'
      else if (metaCheckedAt == null)
        '개념 재선정',
      if (thinkings.isEmpty) '사고 코드',
      if (!solved) '난이도',
      if (visualTags.isEmpty) '시각 태그',
      if (kind.isEmpty || kind == '미분류') '문항 유형',
    ];
  }

  String get labelDisplay => label.trim().isNotEmpty ? label.trim() : '없음';

  /// 개념·사고를 아직 단원 기준 후보로 고르지 않았다(사람이 둘 다 고쳤으면 고르지 않는다).
  bool get needsConceptMeta =>
      metaCheckedAt == null && !(metaSources['concepts'] == 'owner' && metaSources['thinkings'] == 'owner');

  /// AI 풀이를 거쳤는데 시각 태그가 비었다. 풀이 전 문항은 2단계 풀이가 태그를 고른다.
  bool get needsVisualTags => (aiSolution ?? '').trim().isNotEmpty && visualTags.isEmpty;

  /// 메타 전용 AI 대상(Edge isMetaTodo 와 같다): 문제은행 문항과 본문이 있고, 개념·사고를 다시 골라야 하거나 시각 태그가 빈 문항.
  bool get needsMetaPass =>
      pbQuestionId.isNotEmpty &&
      (stem.trim().isNotEmpty || commonStem.trim().isNotEmpty) &&
      (needsConceptMeta || needsVisualTags);

  /// 문제은행 사본 정답이 채점 정답과 다른가(표기 공백·$ 제거 후 단순 비교).
  /// 원문 선지가 있고 답이 선지 번호면 객관식 정답 키(비어 있어도 다름)와, 그 밖에는 주관식 정답과 비교한다.
  /// 주관식 문항에 AI 가 만든 객관식 보기의 정답 키는 채점 정답과 표기가 달라 비교하지 않는다.
  bool get pbAnswerDiffers {
    if (isImageAnswer) return false;
    String norm(String s) => s.replaceAll(RegExp(r'[\s$,，]'), '').toLowerCase();
    final mine = norm(existingAnswer);
    if (mine.isEmpty) return false;
    if (rawChoices.length >= 2 && answerChoiceCount > 0) {
      return pbAllowObjective && norm(pbObjectiveAnswerKey) != mine;
    }
    if (pbSubjectiveAnswer.trim().isEmpty) return false;
    return norm(pbSubjectiveAnswer) != mine;
  }

  /// 주관식 문항인데 문제은행 객관식 보기(AI 생성)가 아직 없다. 문제은행과 같은 생성 기능으로 만든다.
  bool get needsObjectiveGeneration =>
      pbQuestionId.isNotEmpty &&
      expectedQuestionKind == 'subjective' &&
      !isImageAnswer &&
      existingAnswer.trim().isNotEmpty &&
      (pbObjectiveChoiceCount < 2 || pbObjectiveAnswerKey.trim().isEmpty);

  /// 빈칸형(□ 안에 알맞은 수를 써넣어라, 표·수형도·결론식의 □ 등) 문항인가
  bool get isFillInBlank => isFillInBlankProblem(commonStem, stem) || qualityChecks['is_fill_in_blank'] == true;

  /// V2 렌더 카드 중 하나라도 이상으로 판정됐는가
  bool get renderHasIssue =>
      renderChecks['problem_ok'] == false ||
      renderChecks['answer_ok'] == false ||
      renderChecks['solution_ok'] == false ||
      renderChecks['fidelity_ok'] == false ||
      renderChecks['figure_position_ok'] == false ||
      renderChecks['solution_figures_ok'] == false ||
      figureNeedsResize;

  /// 준비됨을 막는 V2 렌더 이상(그림 크기 ±10% 와 해설 그림 포함)
  bool get renderBlocksReady => renderHasIssue;

  /// 원본과 직접 대조한 V2 렌더 검수가 통과해 2단계(문항 카드) 판정을 덮어쓴 상태
  bool get stage2Superseded => originalCompared && renderCheckedAt != null && !renderHasIssue;

  /// 2단계 문항 본문 지적이 원본 대조 본문 통과로 대체되었거나 빈칸형 정상 네모를 오판한 경우인가(2단계 배너 숨김 기준)
  bool get stage2TextSuperseded =>
      stage2Superseded ||
      (originalCompared &&
          renderCheckedAt != null &&
          renderChecks['problem_ok'] != false &&
          renderChecks['fidelity_ok'] != false) ||
      isFalseBlankComplaint(isFillInBlank, qualityChecks['issue_title'], qualityChecks['issue_detail']);

  String get displayStem {
    if (commonStem.isEmpty || stem.contains(commonStem)) return stem;
    if (stem.trim().isEmpty) return commonStem;
    return '$commonStem\n\n$stem';
  }

  bool get isSetQuestion =>
      setType.isNotEmpty || commonStem.isNotEmpty || setHeaderNumber.isNotEmpty || canRenderSetHeader || proposedCommonStem != null;
  bool get hasOpenFindings => findings.any((f) => f['status'] != 'held');
  bool get hasIssue =>
      mathStatus == 'issue' ||
      (!isEngineHeld && qualityStatus == 'issue') ||
      (!isEngineHeld && !isFullyApproved && hasOpenFindings) ||
      consistencyIssues.isNotEmpty;
  bool get hasDrafts => draftProposals.isNotEmpty;
  bool get isFullyApproved => mathStatus == 'approved' && qualityStatus == 'approved';

  bool get hasOriginalSolution => (solutionTranscribed ?? '').trim().isNotEmpty;
  bool get hasSolutionAnswer => (solutionAnswer ?? '').trim().isNotEmpty && solutionAnswer!.trim() != '판단불가';
  bool get hasAiSolution => (aiSolution ?? '').trim().isNotEmpty;

  /// 해설 PDF 에서 해당 문항의 정답 또는 해설 블록을 확인했는가
  bool get solutionVisionFound =>
      hasOriginalSolution ||
      hasSolutionAnswer ||
      (qualityChecks['solution_vision'] is Map && (qualityChecks['solution_vision'] as Map)['found'] == true);

  /// 수력충전 등 연산 교재처럼 해설지에 풀이 과정 없이 정답만 한 줄로 인쇄된 문항(정상 확인 상태)
  bool get isAnswerOnlyOriginalSolution =>
      !hasOriginalSolution &&
      (hasSolutionAnswer ||
          (qualityChecks['solution_vision'] is Map && (qualityChecks['solution_vision'] as Map)['found'] == true));

  /// 해설 좌표가 있었으나 해당 크롭에서 문항 해설·정답을 찾지 못한 문항(번호 재시작·좌표 어긋남 가능성)
  bool get solutionVisionFailed =>
      hasSolutionRef &&
      !hasOriginalSolution &&
      !isAnswerOnlyOriginalSolution &&
      qualityChecks['solution_vision'] is Map &&
      (qualityChecks['solution_vision'] as Map)['found'] == false;

  /// 운영자가 '해설 없음'으로 표시한 문항
  bool get solutionMarkedNone => solutionSourceKind == 'none';

  /// 해설 좌표가 있어서 해설 PDF에서 영역을 잘라낼 수 있는 문항
  bool get canCropSolution =>
      hasSolutionRef && solutionSourceKind != 'none' && (solutionRawPage ?? 0) > 0 && solutionRegion1k.length == 4;

  /// 서버(ai_think.isReviewTodo)와 같은 기준: 미검수 · 풀이 없음 · 해설 좌표가 있는데 원본 해설 전사를 아직 시도하지 않은 문항(승인 제외).
  /// Vision 전사를 시도했다가 못 읽은 문항은 다시 대상이 되지 않는다(운영자가 좌표를 고치거나 직접 입력).
  bool get isReviewTodo {
    if (mathStatus == 'pending' || !hasAiSolution) return true;
    if (mathStatus == 'approved') return false;
    final visionTried = qualityChecks['solution_vision'] != null;
    return hasSolutionRef && !hasOriginalSolution && !isAnswerOnlyOriginalSolution && !visionTried;
  }

  /// 해설·정답 카드가 바뀌었거나 아직 V2 렌더 검수를 안 한 문항
  bool get needsRenderCheck => (renderCheckedAt == null || renderCheckStale) && (hasAiSolution || hasOriginalSolution);

  /// 학생에게 보여줄 해설 본문: 원본 해설이 있으면 원본, 없으면 AI 풀이
  String get primarySolutionText => hasOriginalSolution ? solutionTranscribed!.trim() : (aiSolution ?? '').trim();
  String get primarySolutionKind => hasOriginalSolution ? 'textbook' : 'ai';

  static final RegExp _imagePlaceholderAnswerRe =
      RegExp(r'^(\[?\s*image\s*\]?|\(\s*image\s*\)|\[그림\])$', caseSensitive: false);

  /// 가장 신뢰할 정답 표기: 유효한 저장 정답([image] 제외) → 제안 정답 → 해설 정답 → AI 정답
  String get displayAnswer {
    final cur = existingAnswer.trim();
    if (cur.isNotEmpty && !_imagePlaceholderAnswerRe.hasMatch(cur)) return cur;
    if ((proposedAnswer ?? '').trim().isNotEmpty) return proposedAnswer!.trim();
    if ((solutionAnswer ?? '').trim().isNotEmpty) return solutionAnswer!.trim();
    if ((aiAnswer ?? '').trim().isNotEmpty && aiAnswer!.trim() != '판단불가') return aiAnswer!.trim();
    return cur;
  }
}

/// 묶음 검수 때 문항마다 함께 보내는 이미지(해설 크롭 base64 · V2 문항 카드 URL · 교재 원본 base64 · 해설 전체 페이지 폴백)
class TextbookReviewChunkImage {
  const TextbookReviewChunkImage({
    this.solutionImageBase64,
    this.v2ProblemUrl,
    this.original,
    this.setHeader,
    this.solutionPage,
  });

  final String? solutionImageBase64;
  final String? v2ProblemUrl;

  /// 본문 PDF 에서 찍은 문항 영역(원본). 픽셀 크기·쪽 좌표도 함께 보낸다(그림 크기 계산·그림 다시 잘라내기용).
  final TextbookReviewRenderedRegion? original;

  /// 세트 머리(공통 지시문) 원본
  final TextbookReviewRenderedRegion? setHeader;

  /// 해설 좌표가 어긋났거나 해설 답 불일치일 때 보내는 해설 PDF 한 쪽 전체 이미지
  final TextbookReviewRenderedRegion? solutionPage;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (solutionImageBase64 != null && solutionImageBase64!.isNotEmpty) ...{
          'solution_image_base64': solutionImageBase64,
          'solution_image_mime': 'image/png',
        },
        if (v2ProblemUrl != null && v2ProblemUrl!.isNotEmpty) 'v2_problem_url': v2ProblemUrl,
        if (original != null) ...{
          'original_image_base64': base64Encode(original!.bytes),
          'original_image_mime': 'image/png',
          'original_width_px': original!.widthPx,
          'original_height_px': original!.heightPx,
          'original_region_1k': original!.region1k,
          'original_raw_page': original!.rawPage,
        },
        if (setHeader != null) ...{
          'set_header_image_base64': base64Encode(setHeader!.bytes),
          'set_header_image_mime': 'image/png',
          'set_header_width_px': setHeader!.widthPx,
          'set_header_height_px': setHeader!.heightPx,
          'set_header_region_1k': setHeader!.region1k,
          'set_header_raw_page': setHeader!.rawPage,
        },
        if (solutionPage != null) ...{
          'solution_page_image_base64': base64Encode(solutionPage!.bytes),
          'solution_page_image_mime': 'image/png',
          'solution_page_raw_page': solutionPage!.rawPage,
        },
      };

  bool get isEmpty =>
      (solutionImageBase64 ?? '').isEmpty &&
      (v2ProblemUrl ?? '').isEmpty &&
      original == null &&
      setHeader == null &&
      solutionPage == null;
}

/// 엔진 보류 문항이 있는 단원 한 줄(textbook_review_engine_hold_list)
class TextbookReviewEngineHoldUnit {
  const TextbookReviewEngineHoldUnit({
    required this.scope,
    required this.heldCropIds,
    required this.resolvedCropIds,
  });

  factory TextbookReviewEngineHoldUnit.fromJson(Map<String, dynamic> m) => TextbookReviewEngineHoldUnit(
        scope: TextbookReviewUnitScope(
          academyId: '${m['academy_id'] ?? ''}',
          bookId: '${m['book_id'] ?? ''}',
          bookName: '${m['book_name'] ?? ''}',
          gradeLabel: '${m['grade_label'] ?? ''}',
          bigOrder: (m['big_order'] as num?)?.toInt() ?? 1,
          midOrder: (m['mid_order'] as num?)?.toInt() ?? 1,
          bigName: '${m['big_name'] ?? ''}',
          midName: '${m['mid_name'] ?? ''}',
          problemCount: 0,
          analyzedCount: 0,
          mathCleanCount: 0,
          mathIssueCount: 0,
          mathApprovedCount: 0,
          qualityCleanCount: 0,
          qualityIssueCount: 0,
          qualityApprovedCount: 0,
          qualityHeldCount: (m['held_count'] as num?)?.toInt() ?? 0,
        ),
        heldCropIds: [for (final x in (m['held_crop_ids'] as List?) ?? const []) '$x'],
        resolvedCropIds: [for (final x in (m['resolved_crop_ids'] as List?) ?? const []) '$x'],
      );

  final TextbookReviewUnitScope scope;
  final List<String> heldCropIds;
  final List<String> resolvedCropIds;
}

class TextbookReviewEngineHoldEntry {
  const TextbookReviewEngineHoldEntry({required this.unit, required this.item, required this.resolved});

  final TextbookReviewEngineHoldUnit unit;
  final TextbookProblemReviewItem item;

  /// 보류했다가 승인(해결)된 문항
  final bool resolved;

  TextbookReviewUnitScope get scope => unit.scope;
}

/// 코드 정합성 점검 결과(ai_think textbook_problem_consistency, 사양 5-2)
class TextbookConsistencyReport {
  const TextbookConsistencyReport({
    required this.checked,
    required this.fixed,
    required this.flagged,
    required this.resolved,
    required this.errors,
  });

  factory TextbookConsistencyReport.fromJson(Map<String, dynamic> m) {
    List<Map<String, dynamic>> mapList(Object? v) => [
          for (final x in (v is List ? v : const []))
            if (x is Map) Map<String, dynamic>.from(x),
        ];
    return TextbookConsistencyReport(
      checked: (m['checked'] as num?)?.toInt() ?? 0,
      fixed: mapList(m['fixed']),
      flagged: mapList(m['flagged']),
      resolved: (m['resolved'] as num?)?.toInt() ?? 0,
      errors: [for (final x in (m['errors'] is List ? m['errors'] as List : const [])) '$x'],
    );
  }

  static const empty = TextbookConsistencyReport(checked: 0, fixed: [], flagged: [], resolved: 0, errors: []);

  final int checked;

  /// 이번 점검이 반영 대기 값으로 쌓은 문항 [{crop_id, problem_number, page, sub_key, fixes: [제목]}]
  final List<Map<String, dynamic>> fixed;

  /// 지적이 남은 문항(사장님이 "문제 없음"으로 닫은 것 제외) [{crop_id, problem_number, page, sub_key, issues: [{code, title, detail}]}]
  final List<Map<String, dynamic>> flagged;

  /// 고쳐져서 닫힌 지적 수
  final int resolved;
  final List<String> errors;

  TextbookConsistencyReport operator +(TextbookConsistencyReport o) => TextbookConsistencyReport(
        checked: checked + o.checked,
        fixed: [...fixed, ...o.fixed],
        flagged: [...flagged, ...o.flagged],
        resolved: resolved + o.resolved,
        errors: [...errors, ...o.errors],
      );

  /// 지적 제목별 문항 수
  Map<String, int> get flaggedByTitle {
    final out = <String, int>{};
    for (final f in flagged) {
      for (final i in (f['issues'] is List ? f['issues'] as List : const [])) {
        final t = i is Map ? '${i['title'] ?? ''}'.trim() : '';
        if (t.isNotEmpty) out[t] = (out[t] ?? 0) + 1;
      }
    }
    return out;
  }

  String get summary {
    final parts = <String>[
      '$checked문항 점검',
      if (fixed.isNotEmpty) '수정안 ${fixed.length}문항',
      if (flagged.isNotEmpty) '지적 ${flagged.length}문항(${[for (final e in flaggedByTitle.entries) '${e.key} ${e.value}'].join(', ')})',
      if (fixed.isEmpty && flagged.isEmpty) '걸린 문항 없음',
      if (errors.isNotEmpty) '오류 ${errors.length}건',
    ];
    return '정합성 점검: ${parts.join(' · ')}';
  }
}

class TextbookProblemReviewService {
  TextbookProblemReviewService({
    SupabaseClient? client,
    ProblemBankService? pbService,
    TextbookReviewSolutionImageService? solutionImageService,
  })  : _db = client ?? Supabase.instance.client,
        _pb = pbService ?? ProblemBankService(),
        _solutionImages = solutionImageService ?? TextbookReviewSolutionImageService();

  final SupabaseClient _db;
  final ProblemBankService _pb;
  final TextbookReviewSolutionImageService _solutionImages;

  bool get hasGateway => _pb.hasGateway;

  void dispose() => _solutionImages.dispose();

  Future<List<TextbookReviewUnitScope>> fetchUnits() async {
    final res = await _db.rpc('textbook_review_books_and_units');
    final map = res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
    return [
      for (final r in (map['units'] as List?) ?? const [])
        if (r is Map) TextbookReviewUnitScope.fromJson(Map<String, dynamic>.from(r)),
    ];
  }

  Future<List<TextbookProblemReviewItem>> fetchUnitItems(TextbookReviewUnitScope scope) async {
    final res = await _db.rpc('textbook_review_unit_overview', params: {
      'p_academy_id': scope.academyId,
      'p_book_id': scope.bookId,
      'p_grade_label': scope.gradeLabel,
      'p_big_order': scope.bigOrder,
      'p_mid_order': scope.midOrder,
    });
    final map = res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
    final rows = [
      for (final r in (map['items'] as List?) ?? const [])
        if (r is Map) Map<String, dynamic>.from(r),
    ];
    await _mergeFigureColumns(rows);
    await _mergeSolutionContinuations(scope, rows);
    return [for (final r in rows) TextbookProblemReviewItem.fromJson(r)];
  }

  /// 단 맨 아래에서 끊긴 풀이에 다음 단 맨 위의 이어진 부분을 붙인다. 못 읽으면 붙이지 않는다.
  Future<void> _mergeSolutionContinuations(TextbookReviewUnitScope scope, List<Map<String, dynamic>> rows) async {
    List<int> ints(Object? v) => [for (final x in (v is List ? v : const [])) if (x is num) x.toInt()];
    final pagesByKind = <String, Set<int>>{};
    var anyAtBottom = false;
    for (final r in rows) {
      final page = (r['solution_raw_page'] as num?)?.toInt() ?? 0;
      final region = ints(r['solution_region_1k']);
      if (page <= 0 || region.length != 4) continue;
      final kind = '${r['solution_source_kind'] ?? 'sol'}'.trim();
      pagesByKind.putIfAbsent(kind, () => <int>{}).addAll([page, page + 1]);
      if (region[2] >= 980) anyAtBottom = true;
    }
    if (!anyAtBottom) return;
    for (final entry in pagesByKind.entries) {
      final List refsRaw;
      try {
        refsRaw = await _db
            .from('textbook_problem_solution_refs')
            .select('raw_page,number_region_1k,content_region_1k,textbook_problem_crops!inner(academy_id,book_id,grade_label)')
            .eq('source_kind', entry.key)
            .inFilter('raw_page', entry.value.toList())
            .eq('textbook_problem_crops.academy_id', scope.academyId)
            .eq('textbook_problem_crops.book_id', scope.bookId)
            .eq('textbook_problem_crops.grade_label', scope.gradeLabel);
      } catch (_) {
        continue;
      }
      final refs = <SolutionRefBox>[];
      for (final x in refsRaw) {
        if (x is! Map) continue;
        final number = ints(x['number_region_1k']);
        final content = ints(x['content_region_1k']);
        final page = (x['raw_page'] as num?)?.toInt() ?? 0;
        if (page <= 0 || number.length != 4) continue;
        refs.add(SolutionRefBox(rawPage: page, numberTop: number[0], region1k: content.length == 4 ? content : number));
      }
      for (final r in rows) {
        if ('${r['solution_source_kind'] ?? 'sol'}'.trim() != entry.key) continue;
        final page = (r['solution_raw_page'] as num?)?.toInt() ?? 0;
        final seg = solutionContinuationSegment(rawPage: page, region1k: ints(r['solution_region_1k']), refs: refs);
        if (seg == null) continue;
        r['solution_continuations'] = [
          {'raw_page': seg.rawPage, 'region_1k': seg.region1k},
        ];
      }
    }
  }

  /// 개요 RPC 에 없는 그림 정답 이미지·해설 그림 열을 붙인다. 못 읽어도 나머지 검수는 그대로 한다.
  Future<void> _mergeFigureColumns(List<Map<String, dynamic>> rows) async {
    final byCrop = <String, Map<String, dynamic>>{
      for (final r in rows)
        if ('${r['crop_id'] ?? ''}'.isNotEmpty) '${r['crop_id']}': r,
    };
    final ids = byCrop.keys.toList();
    for (var i = 0; i < ids.length; i += 200) {
      final chunk = ids.sublist(i, (i + 200).clamp(0, ids.length));
      try {
        final answers = await _db
            .from('textbook_problem_answers')
            .select('crop_id,answer_image_bucket,answer_image_path')
            .inFilter('crop_id', chunk);
        for (final a in (answers as List)) {
          final row = byCrop['${a['crop_id']}'];
          if (row == null) continue;
          row['answer_image_bucket'] = a['answer_image_bucket'];
          row['answer_image_path'] = a['answer_image_path'];
        }
      } catch (_) {}
      try {
        final analyses = await _db
            .from('textbook_problem_analyses')
            .select('crop_id,solution_figure_assets,solution_figures_checked_at')
            .inFilter('crop_id', chunk);
        for (final a in (analyses as List)) {
          final row = byCrop['${a['crop_id']}'];
          if (row == null) continue;
          row['solution_figure_assets'] = a['solution_figure_assets'];
          row['solution_figures_checked_at'] = a['solution_figures_checked_at'];
        }
      } catch (_) {}
    }
  }

  /// 학습앱/문제은행 카드와 동일한 서버 PDF 렌더링 엔진(V2 xelatex) 썸네일 URL을 가져온다.
  Future<Map<String, String>> fetchEnginePreviewUrls({
    required String academyId,
    required List<TextbookProblemReviewItem> items,
  }) async {
    final byDoc = <String, List<String>>{};
    final keyToCropIds = <String, List<String>>{};
    final overrides = <String, Map<String, dynamic>>{};
    for (final it in items) {
      final k = it.previewLookupKey;
      if (k.isEmpty) continue;
      final o = it.previewOverride;
      if (o != null) overrides[k] = o;
      keyToCropIds.putIfAbsent(k, () => <String>[]).add(it.cropId);
      if (it.pbQuestionId.isNotEmpty && it.pbQuestionId != k) {
        keyToCropIds.putIfAbsent(it.pbQuestionId, () => <String>[]).add(it.cropId);
      }
      byDoc.putIfAbsent(it.documentId, () => <String>[]).add(k);
    }
    if (byDoc.isEmpty) return const {};

    final out = <String, String>{};
    for (final entry in byDoc.entries) {
      try {
        Map<String, String> urls = {};
        if (_pb.hasGateway) {
          try {
            urls = await _pb.batchRenderThumbnails(
              academyId: academyId,
              questionIds: entry.value,
              documentId: entry.key,
              templateProfile: 'naesin',
              paperSize: 'A4',
              questionOverrides: {
                for (final q in entry.value)
                  if (overrides[q] != null) q: overrides[q]!,
              },
            );
          } catch (_) {
            // 반영 대기 값이 있는 문항은 저장된 카드로 대신하면 고치기 전 모습을 보게 되므로 비워 둔다.
            if (entry.value.any(overrides.containsKey)) continue;
            urls = await _pb.fetchQuestionPreviews(
              academyId: academyId,
              questionIds: entry.value,
            );
          }
        }
        for (final u in urls.entries) {
          final crops = keyToCropIds[u.key.trim()] ?? const <String>[];
          for (final cid in crops) {
            out[cid] = u.value;
          }
        }
      } catch (_) {
        // 게이트웨이 미연결 환경에서는 빈 맵
      }
    }
    return out;
  }

  // ── 교재 원본(본문 PDF 좌표 렌더) ──────────────────────────────────────
  // 크롭 PNG 는 저장소에 없다. 원본은 항상 본문 PDF 의 raw_page + item_region_1k 로 그때그때 찍는다.

  final Map<String, Future<TextbookReviewRenderedRegion?>> _regionCache = {};

  Future<TextbookReviewRenderedRegion?> _cachedBodyRegion(
    TextbookReviewUnitScope scope,
    int rawPage,
    List<int> region1k,
  ) async {
    final key = '${scope.bookId}|${scope.gradeLabel}|$rawPage|${region1k.join(',')}';
    final hit = _regionCache[key];
    if (hit != null) return hit;
    if (_regionCache.length > 400) _regionCache.clear();
    final load = _solutionImages
        .renderRegion(
          academyId: scope.academyId,
          bookId: scope.bookId,
          gradeLabel: scope.gradeLabel,
          sourceKind: 'body',
          rawPage: rawPage,
          region1k: region1k,
        )
        .then<TextbookReviewRenderedRegion?>((r) => r, onError: (Object _) => null);
    _regionCache[key] = load;
    final r = await load;
    if (r == null) _regionCache.remove(key);
    return r;
  }

  /// 문항 영역 원본 이미지. PDF·좌표가 없으면 null.
  Future<TextbookReviewRenderedRegion?> originalImage(TextbookReviewUnitScope scope, TextbookProblemReviewItem it) =>
      it.canRenderOriginal ? _cachedBodyRegion(scope, it.rawPage, it.itemRegion1k) : Future.value(null);

  /// 세트 머리(공통 지시문) 원본 이미지. 세트 문항이 아니거나 좌표가 없으면 null.
  Future<TextbookReviewRenderedRegion?> setHeaderImage(TextbookReviewUnitScope scope, TextbookProblemReviewItem it) =>
      it.isSetQuestion && it.canRenderSetHeader
          ? _cachedBodyRegion(scope, it.setHeaderRawPage!, it.setHeaderRegion1k)
          : Future.value(null);

  /// 렌더 검수·수정 단계에 붙일 원본 이미지 묶음(JSON 필드)
  Future<Map<String, dynamic>> originalImagesJson(TextbookReviewUnitScope scope, TextbookProblemReviewItem it) async {
    final o = await originalImage(scope, it);
    final h = await setHeaderImage(scope, it);
    return TextbookReviewChunkImage(original: o, setHeader: h).toJson();
  }

  /// 렌더 검수에서 해설 카드가 원본 해설을 빠짐없이 옮겼는지 대조할 원본 해설 이미지(다음 단으로 이어진 부분 포함).
  /// 학생에게 원본 해설을 보여주는 문항만 보낸다. 못 찍으면 빈 값.
  Future<Map<String, dynamic>> solutionOriginalJson(TextbookReviewUnitScope scope, TextbookProblemReviewItem it) async {
    if (it.primarySolutionKind != 'textbook' || !it.canCropSolution) return const {};
    try {
      final stack = await _solutionImages.renderSolutionStack(
        academyId: scope.academyId,
        bookId: scope.bookId,
        gradeLabel: scope.gradeLabel,
        sourceKind: it.solutionSourceKind,
        segments: it.solutionSegments,
      );
      if (stack == null || stack.bytes.isEmpty) return const {};
      return {'solution_original_image_base64': base64Encode(stack.bytes), 'solution_original_image_mime': 'image/png'};
    } catch (_) {
      return const {};
    }
  }

  /// 문항의 해설 PDF 쪽 번호를 구한다(직접 좌표가 있으면 그 쪽, 없으면 같은 소단원·인접 본문 쪽 문항의 해설 쪽을 추론).
  int? inferSolutionRawPage(TextbookProblemReviewItem it, List<TextbookProblemReviewItem> allItems) {
    if ((it.solutionRawPage ?? 0) > 0) return it.solutionRawPage;
    if ((it.answerRawPage ?? 0) > 0) return it.answerRawPage;
    int? bestPage;
    var bestDist = 1 << 30;
    for (final other in allItems) {
      final p = other.solutionRawPage ?? other.answerRawPage;
      if (p == null || p <= 0) continue;
      final sameSub = it.subKey.isNotEmpty && other.subKey == it.subKey;
      final dist = (other.rawPage - it.rawPage).abs() * 10 + (sameSub ? 0 : 5);
      if (dist < bestDist) {
        bestDist = dist;
        bestPage = p;
      }
    }
    return bestPage;
  }

  /// 해설 PDF 한 쪽 전체 이미지(캐시). 해설 번호 좌표가 어긋났을 때 쪽 전체에서 블록·문항을 다시 찾는 용도.
  Future<TextbookReviewRenderedRegion?> fullSolutionPage(
    TextbookReviewUnitScope scope,
    TextbookProblemReviewItem it,
    List<TextbookProblemReviewItem> allItems,
  ) async {
    final page = inferSolutionRawPage(it, allItems);
    if (page == null || page <= 0) return null;
    final kind = it.solutionSourceKind != 'none' && it.solutionSourceKind.isNotEmpty ? it.solutionSourceKind : 'sol';
    final key = '${scope.bookId}|${scope.gradeLabel}|$kind|$page|full_page';
    final hit = _regionCache[key];
    if (hit != null) return hit;
    final load = _solutionImages
        .renderFullPage(
          academyId: scope.academyId,
          bookId: scope.bookId,
          gradeLabel: scope.gradeLabel,
          sourceKind: kind,
          rawPage: page,
        )
        .then<TextbookReviewRenderedRegion?>((r) => r, onError: (Object _) => null);
    _regionCache[key] = load;
    final r = await load;
    if (r == null) _regionCache.remove(key);
    return r;
  }

  /// 묶음 검수 전에 문항마다 (1) 해설 PDF 좌표 영역 크롭(원본 해설 Vision 전사용) (2) V2 문항 카드 URL(학생 시점 품질 검수용)
  /// (3) 본문 PDF 문항 영역 원본(원본 대조용, 세트면 세트 머리도)
  /// (4) 필요 시 해설 PDF 한 쪽 전체 이미지(좌표 어긋남·해설 미전사·정답 불일치 폴백용)를 모은다.
  /// 검수에 쓸 원본 PDF(본문·해설)를 미리 받아 연다. 받지 못하면 이유를 담아 예외를 던진다
  /// (이미지 없이 검수를 보내거나 문항마다 다시 받으며 멈춰 있지 않게).
  Future<void> ensureSourcePdfs(
    TextbookReviewUnitScope scope,
    List<TextbookProblemReviewItem> items, {
    void Function(String message)? onProgress,
  }) async {
    final kinds = <String>{
      if (items.any((it) => it.canRenderOriginal)) 'body',
      for (final it in items)
        if (it.canCropSolution) it.solutionSourceKind,
      if (items.any((it) => it.canCropAnswer)) 'sol',
    };
    final seen = <String>{};
    for (final kind in kinds) {
      final label = TextbookReviewSolutionImageService.pdfKindLabel(kind);
      if (!seen.add(label)) continue;
      final doc = await _solutionImages.ensureSourcePdf(
        academyId: scope.academyId,
        bookId: scope.bookId,
        gradeLabel: scope.gradeLabel,
        sourceKind: kind,
        onProgress: onProgress == null
            ? null
            : (received, total) => onProgress(
                  '$label PDF 받는 중 ${received ~/ 1048576}'
                  '${total == null ? '' : '/${total ~/ 1048576}'}MB',
                ),
      );
      if (doc == null) {
        final why = TextbookReviewSolutionImageService.loadError(scope.bookId, scope.gradeLabel, kind);
        throw Exception('$label PDF를 받지 못했습니다${why == null ? '' : ': $why'}');
      }
    }
  }

  Future<Map<String, TextbookReviewChunkImage>> prepareChunkImages({
    required TextbookReviewUnitScope scope,
    required List<TextbookProblemReviewItem> items,
    required Map<String, String> previewUrlsByCropId,
    bool includeSolution = true,
    bool onlyMissingSolutions = false,
    bool includeSolutionPageFallback = false,
    bool forceSolutionPageFallback = false,
    List<TextbookProblemReviewItem> allItems = const [],
  }) async {
    final out = <String, TextbookReviewChunkImage>{};
    final pool = allItems.isNotEmpty ? allItems : items;
    for (final it in items) {
      String? b64;
      if (includeSolution && !(onlyMissingSolutions && (it.hasOriginalSolution || it.isAnswerOnlyOriginalSolution))) {
        if (it.canCropSolution) {
          try {
            final stack = await _solutionImages.renderSolutionStack(
              academyId: scope.academyId,
              bookId: scope.bookId,
              gradeLabel: scope.gradeLabel,
              sourceKind: it.solutionSourceKind,
              segments: it.solutionSegments,
            );
            if (stack != null && stack.bytes.isNotEmpty) b64 = base64Encode(stack.bytes);
          } catch (_) {
            b64 = null;
          }
        }
        if (b64 == null && it.canCropAnswer) {
          try {
            final png = await _solutionImages.renderSolutionCrop(
              academyId: scope.academyId,
              bookId: scope.bookId,
              gradeLabel: scope.gradeLabel,
              sourceKind: 'sol',
              rawPage: it.answerRawPage!,
              region1k: it.answerBbox1k,
            );
            if (png != null && png.isNotEmpty) b64 = base64Encode(png);
          } catch (_) {
            b64 = null;
          }
        }
      }
      TextbookReviewRenderedRegion? solPage;
      final needsSolPage = forceSolutionPageFallback ||
          (includeSolutionPageFallback &&
              (it.solutionVisionFailed ||
                  it.mathStatus == 'issue' ||
                  (!it.hasOriginalSolution && !it.isAnswerOnlyOriginalSolution)));
      if (needsSolPage) {
        solPage = await fullSolutionPage(scope, it, pool);
      }
      final v2 = previewUrlsByCropId[it.cropId];
      final img = TextbookReviewChunkImage(
        solutionImageBase64: b64,
        v2ProblemUrl: v2 != null && v2.startsWith('https://') ? v2 : null,
        original: await originalImage(scope, it),
        setHeader: await setHeaderImage(scope, it),
        solutionPage: solPage,
      );
      if (!img.isEmpty) out[it.cropId] = img;
    }
    return out;
  }

  /// 원본 대조 수정 단계(또는 핀셋 정밀 추출). 원본 이미지가 있는 문항만 처리된다(최대 4문항).
  /// [pincette] 가 true 면 고해상도·상위 추론(high)으로 본문·풀이·정답·해설을 다시 뽑아 DB 에 즉시 반영한다.
  Future<Map<String, dynamic>> runFixPass(
    TextbookReviewUnitScope scope, {
    required List<String> cropIds,
    required Map<String, TextbookReviewChunkImage> images,
    bool pincette = false,
  }) async {
    if (cropIds.isEmpty) return const {'ok': true, 'processed': 0};
    final res = await _invokeAiThink({
      'action': 'textbook_problem_fix',
      'academy_id': scope.academyId,
      'book_id': scope.bookId,
      'grade_label': scope.gradeLabel,
      'big_order': scope.bigOrder,
      'mid_order': midOrderOf(scope),
      'crop_ids': cropIds,
      if (pincette) 'pincette': true,
      'images': {for (final e in images.entries) e.key: e.value.toJson()},
    });
    final data = res.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw Exception('원본 대조 수정 응답을 해석하지 못했습니다.');
  }

  /// 핀셋 추출(PDF 영역 직접 드래그 지정 / 빠진 문항 추가):
  /// 기존 문항이면 crop_id·pb_question_id 를 보존하며 영역 좌표를 갱신하고, 빠진 문항이면 새로 생성해 crop_id 를 돌려준다.
  Future<String> upsertPincetteCrop({
    required TextbookReviewUnitScope scope,
    required String subKey,
    int subIndex = 0,
    required int rawPage,
    int? displayPage,
    required String problemNumber,
    required List<int> itemRegion1k,
    String? cropId,
  }) async {
    _regionCache.clear();
    final res = await _db.rpc('textbook_review_pincette_upsert_crop', params: {
      'p_academy_id': scope.academyId,
      'p_book_id': scope.bookId,
      'p_grade_label': scope.gradeLabel,
      'p_big_order': scope.bigOrder,
      'p_mid_order': midOrderOf(scope),
      'p_sub_key': subKey.isEmpty ? 'A' : subKey,
      'p_sub_index': subIndex,
      'p_raw_page': rawPage,
      'p_display_page': displayPage,
      'p_problem_number': problemNumber.trim(),
      'p_item_region_1k': itemRegion1k,
      'p_bbox_1k': itemRegion1k,
      'p_big_name': scope.bigName,
      'p_mid_name': scope.midName,
      'p_crop_id': cropId,
    });
    if (res is Map && res['crop_id'] != null) {
      return '${res['crop_id']}';
    }
    throw Exception('핀셋 영역 저장 응답을 해석하지 못했습니다.');
  }

  /// 'body' | 'ans' | 'sol' PDF 쪽 수. PDF 가 없으면 0.
  Future<int> sourcePageCount(TextbookReviewUnitScope scope, String sourceKind) => _solutionImages.pageCount(
        academyId: scope.academyId,
        bookId: scope.bookId,
        gradeLabel: scope.gradeLabel,
        sourceKind: sourceKind,
      );

  /// 정답·해설·본문 PDF 한 쪽 전체(2단계 작업 화면에서 원본을 보고 직접 잘라 지정할 때).
  Future<TextbookReviewRenderedRegion?> renderSourcePage({
    required TextbookReviewUnitScope scope,
    required String sourceKind,
    required int rawPage,
    int targetWidthPx = 1400,
  }) =>
      _solutionImages.renderFullPage(
        academyId: scope.academyId,
        bookId: scope.bookId,
        gradeLabel: scope.gradeLabel,
        sourceKind: sourceKind,
        rawPage: rawPage,
        targetWidthPx: targetWidthPx,
      );

  /// 운영자가 고른 영역을 여백 없이 찍는다(그림 정답 저장용).
  Future<TextbookReviewRenderedRegion?> renderSourceRegion({
    required TextbookReviewUnitScope scope,
    required String sourceKind,
    required int rawPage,
    required List<int> region1k,
  }) =>
      _solutionImages.renderRegion(
        academyId: scope.academyId,
        bookId: scope.bookId,
        gradeLabel: scope.gradeLabel,
        sourceKind: sourceKind,
        rawPage: rawPage,
        region1k: region1k,
        pad1k: 0,
      );

  /// 본문(또는 해설) PDF 한 쪽 전체를 PNG 로 렌더링한다(PDF 영역 직접 드래그 지정 모달용).
  Future<TextbookReviewRenderedRegion?> renderFullBodyPage({
    required TextbookReviewUnitScope scope,
    required int rawPage,
    int targetWidthPx = 1500,
  }) =>
      _solutionImages.renderFullPage(
        academyId: scope.academyId,
        bookId: scope.bookId,
        gradeLabel: scope.gradeLabel,
        sourceKind: 'body',
        rawPage: rawPage,
        targetWidthPx: targetWidthPx,
      );

  /// 수정 단계가 고른 그림 영역을 본문 PDF 에서 잘라 문제은행 그림 자산으로 올린다.
  /// 반환: 새 자산 목록(figure_index 는 제안대로). 그림 하나라도 못 자르면 예외.
  Future<List<Map<String, dynamic>>> cropAndUploadFigures({
    required TextbookReviewUnitScope scope,
    required TextbookProblemReviewItem item,
    required List<Map<String, dynamic>> crops,
  }) async {
    if (crops.isEmpty) return const [];
    if (item.documentId.isEmpty) throw Exception('문제은행 문서가 없어 그림을 등록할 수 없습니다.');
    final measure = item.fixProposal['figure_measure'] is Map
        ? Map<String, dynamic>.from(item.fixProposal['figure_measure'] as Map)
        : const <String, dynamic>{};
    final measuredRegion = [
      for (final x in (measure['region_1k'] is List ? measure['region_1k'] as List : const []))
        if (x is num) x.toInt(),
    ];
    final rawPage = (measure['raw_page'] as num?)?.toInt() ?? item.rawPage;
    // 수정 단계에 보낸 원본과 같은 영역(여백 포함). 기록이 없으면 지금 원본을 다시 찍어 영역을 얻는다.
    final region = measuredRegion.length == 4 ? measuredRegion : (await originalImage(scope, item))?.region1k ?? const <int>[];
    // 공통 발문 그림은 세트 머리 원본 기준 좌표로 온다.
    final measuredHeader = [
      for (final x in (measure['set_header_region_1k'] is List ? measure['set_header_region_1k'] as List : const []))
        if (x is num) x.toInt(),
    ];
    final needsHeader = crops.any((c) => c['source'] == 'set_header');
    final headerRegion = !needsHeader
        ? const <int>[]
        : measuredHeader.length == 4
            ? measuredHeader
            : (await setHeaderImage(scope, item))?.region1k ?? const <int>[];
    final headerPage = (measure['set_header_raw_page'] as num?)?.toInt() ?? item.setHeaderRawPage;
    final out = <Map<String, dynamic>>[];
    for (final c in crops) {
      final idx = (c['figure_index'] as num?)?.toInt() ?? 0;
      final fromHeader = c['source'] == 'set_header';
      final srcRegion = fromHeader ? headerRegion : region;
      final srcPage = fromHeader ? headerPage : rawPage;
      if (srcRegion.length != 4 || srcPage == null) {
        throw Exception(fromHeader ? '세트 머리 좌표가 없어 그림을 잘라낼 수 없습니다.' : '원본 문항 좌표가 없어 그림을 잘라낼 수 없습니다.');
      }
      final box = [
        for (final x in (c['bbox_1k'] is List ? c['bbox_1k'] as List : const []))
          if (x is num) x.toInt(),
      ];
      final pageRegion = cropBoxToPageRegion(srcRegion, box);
      if (idx <= 0 || pageRegion == null) throw Exception('그림 $idx 영역이 올바르지 않습니다.');
      final png = await _solutionImages.renderRegion(
        academyId: scope.academyId,
        bookId: scope.bookId,
        gradeLabel: scope.gradeLabel,
        sourceKind: 'body',
        rawPage: srcPage,
        region1k: pageRegion,
        pad1k: 0,
        targetWidthPx: 900,
      );
      if (png == null) throw Exception('그림 $idx 을(를) 본문 PDF 에서 잘라내지 못했습니다.');
      final asset = await _pb.uploadManualFigureAsset(
        academyId: scope.academyId,
        documentId: item.documentId,
        questionNumber: item.problemNumber,
        bytes: png.bytes,
        fileName: 'review_figure_$idx.png',
      );
      out.add({
        ...asset,
        'figure_index': idx,
        'source': 'textbook_review_original_crop',
        'status': 'review_original_crop',
        'approved': true,
        'width_px': png.widthPx,
        'height_px': png.heightPx,
        'raw_page': srcPage,
        'crop_region_1k': pageRegion,
        if (fromHeader) 'crop_source': 'set_header',
        'replace_reason': '${c['reason'] ?? ''}',
      });
    }
    return out;
  }

  /// 원본 해설 속 그림을 해설 PDF 에서 찾아 잘라 올리고 문항에 붙인다(그림이 없어도 찾은 기록은 남긴다).
  /// AI 는 그림 상자와 [그림] 자리만 정하고, 그림은 해설 PDF 를 고해상도로 다시 잘라 쓴다.
  /// 반환: 그림이 하나 이상 붙은 crop_id, 실패 메시지.
  Future<({Set<String> withFigures, List<String> errors})> extractSolutionFigures(
    TextbookReviewUnitScope scope,
    List<TextbookProblemReviewItem> items, {
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final withFigures = <String>{};
    final errors = <String>[];
    final targets = [for (final it in items) if (it.canCropSolution && it.documentId.isNotEmpty) it];
    const chunkSize = 4;
    for (var i = 0; i < targets.length; i += chunkSize) {
      if (isCancelled?.call() ?? false) break;
      final chunk = targets.sublist(i, (i + chunkSize).clamp(0, targets.length));
      final regions = <String, TextbookReviewRenderedStack>{};
      final payload = <Map<String, dynamic>>[];
      for (final it in chunk) {
        try {
          final r = await _solutionImages.renderSolutionStack(
            academyId: scope.academyId,
            bookId: scope.bookId,
            gradeLabel: scope.gradeLabel,
            sourceKind: it.solutionSourceKind,
            segments: it.solutionSegments,
          );
          if (r == null) continue;
          regions[it.cropId] = r;
          payload.add({
            'crop_id': it.cropId,
            'solution_image_base64': base64Encode(r.bytes),
            'solution_image_mime': 'image/png',
          });
        } catch (e) {
          errors.add('${it.problemNumber}번 해설 이미지: $e');
        }
      }
      if (payload.isNotEmpty) {
        try {
          final res = await _invokeAiThink({
            'action': 'textbook_solution_figures',
            'academy_id': scope.academyId,
            'items': payload,
          });
          final data = res.data is Map ? Map<String, dynamic>.from(res.data as Map) : const <String, dynamic>{};
          final byId = {for (final it in chunk) it.cropId: it};
          for (final r in (data['results'] as List?) ?? const []) {
            if (r is! Map) continue;
            final it = byId['${r['crop_id']}'];
            final region = it == null ? null : regions[it.cropId];
            if (it == null || region == null) continue;
            try {
              final assets = <Map<String, dynamic>>[];
              final boxes = (r['figures'] as List?) ?? const [];
              final placements = (r['placements'] as List?) ?? const [];
              for (var k = 0; k < boxes.length; k++) {
                final box = [for (final x in (boxes[k] is List ? boxes[k] as List : const [])) if (x is num) x.toInt()];
                final located = region.locate(box);
                if (located == null) continue;
                final pageRegion = cropBoxToPageRegion(located.part.region1k, located.box);
                if (pageRegion == null) continue;
                final png = await _solutionImages.renderRegion(
                  academyId: scope.academyId,
                  bookId: scope.bookId,
                  gradeLabel: scope.gradeLabel,
                  sourceKind: it.solutionSourceKind,
                  rawPage: located.part.rawPage,
                  region1k: pageRegion,
                  pad1k: 0,
                  targetWidthPx: 900,
                );
                if (png == null) throw Exception('그림 ${k + 1} 을(를) 해설 PDF 에서 잘라내지 못했습니다');
                final asset = await _pb.uploadManualFigureAsset(
                  academyId: scope.academyId,
                  documentId: it.documentId,
                  questionNumber: it.problemNumber,
                  bytes: png.bytes,
                  fileName: 'solution_figure_${assets.length + 1}.png',
                );
                assets.add({
                  ...asset,
                  'figure_index': assets.length + 1,
                  'source': 'textbook_solution_crop',
                  'approved': true,
                  'width_px': png.widthPx,
                  'height_px': png.heightPx,
                  'width_em': solutionFigureWidthEm(pageRegion),
                  'placement': k < placements.length && placements[k] == 'right' ? 'right' : 'below',
                  'raw_page': located.part.rawPage,
                  'source_kind': it.solutionSourceKind,
                  'crop_region_1k': pageRegion,
                });
              }
              await _db.rpc('textbook_review_set_solution_figures', params: {
                'p_crop_id': it.cropId,
                'p_assets': assets,
              });
              if (assets.isNotEmpty) withFigures.add(it.cropId);
            } catch (e) {
              errors.add('${it.problemNumber}번 해설 그림: $e');
            }
          }
        } catch (e) {
          errors.add('해설 그림 찾기: $e');
        }
      }
      onProgress?.call((i + chunk.length).clamp(0, targets.length), targets.length);
    }
    return (withFigures: withFigures, errors: errors);
  }

  Future<Map<String, dynamic>> runReviewChunk(
    TextbookReviewUnitScope scope, {
    int chunkSize = 6,
    bool forceRerun = false,
    bool mathOnly = false,
    List<String> cropIds = const [],
    Map<String, TextbookReviewChunkImage> images = const {},
  }) async {
    final res = await _invokeAiThink({
      'action': 'textbook_problem_review',
      'academy_id': scope.academyId,
      'book_id': scope.bookId,
      'grade_label': scope.gradeLabel,
      'big_order': scope.bigOrder,
      'mid_order': midOrderOf(scope),
      'chunk_size': chunkSize,
      'force_rerun': forceRerun,
      if (mathOnly) 'math_only': true,
      if (cropIds.isNotEmpty) 'crop_ids': cropIds,
      if (images.isNotEmpty) 'images': {for (final e in images.entries) e.key: e.value.toJson()},
    });
    final data = res.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw Exception('문항 검수 응답을 해석하지 못했습니다.');
  }

  /// 메타 전용 AI(개념·사고 태그와 새 개념 초안). 제안만 쓰고, 문제은행 반영과 새 개념 생성은 소단원 확정 때 한다.
  Future<Map<String, dynamic>> runMetaChunk(
    TextbookReviewUnitScope scope, {
    required List<String> cropIds,
    bool forceRerun = false,
  }) async {
    final res = await _invokeAiThink({
      'action': 'textbook_problem_meta',
      'academy_id': scope.academyId,
      'book_id': scope.bookId,
      'grade_label': scope.gradeLabel,
      'big_order': scope.bigOrder,
      'mid_order': midOrderOf(scope),
      'chunk_size': cropIds.length.clamp(1, 12),
      'crop_ids': cropIds,
      if (forceRerun) 'force_rerun': true,
    });
    final data = res.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw Exception('메타 응답을 해석하지 못했습니다.');
  }

  /// 코드 정합성 점검(AI 없음, 사양 5-2). 고칠 수 있는 것(공통 발문 중복, '해' 풀이 안내, 엔진이 못 읽는 마크업,
  /// 해설 칸의 정답 줄)은 반영 대기 값으로 쌓고, 나머지(그림 수·자리, 수식 구분자, 정답 불일치)는 지적으로 남긴다.
  /// [cropIds] 가 비면 중단원 전체를 본다. [dryRun] 이면 아무것도 쓰지 않고, 쌓을 수정안([fixed])과 지적만 돌려준다.
  Future<TextbookConsistencyReport> runConsistencyCheck(
    TextbookReviewUnitScope scope, {
    List<String> cropIds = const [],
    bool dryRun = false,
  }) async {
    final res = await _invokeAiThink({
      'action': 'textbook_problem_consistency',
      'academy_id': scope.academyId,
      'book_id': scope.bookId,
      'grade_label': scope.gradeLabel,
      'big_order': scope.bigOrder,
      'mid_order': midOrderOf(scope),
      if (cropIds.isNotEmpty) 'crop_ids': cropIds,
      if (dryRun) 'dry_run': true,
    });
    final data = res.data;
    if (data is Map) return TextbookConsistencyReport.fromJson(Map<String, dynamic>.from(data));
    throw Exception('정합성 점검 응답을 해석하지 못했습니다.');
  }

  /// 소단원 확정 직전 정합성 점검. 새 수정안을 쌓았거나 새 지적이 생겼거나 점검이 실패하면 확정하지 않을 이유를 돌려준다.
  Future<String?> consistencyGateForConfirm(TextbookReviewUnitScope scope, List<TextbookProblemReviewItem> items) async {
    final report = await runConsistencyCheck(scope, cropIds: [for (final it in items) it.cropId]);
    if (report.errors.isNotEmpty) return '정합성 점검 실패(${report.errors.first})';
    if (report.fixed.isEmpty && report.flagged.isEmpty) return null;
    return '${report.summary}. 반영 대기 수정안과 지적을 확인한 뒤 다시 확정하세요';
  }

  /// 정합성 지적을 "문제 없음"으로 닫는다. 문항 내용이 그대로면 다시 점검해도 열지 않는다.
  Future<void> dismissConsistencyIssue({required String findingId, String note = ''}) async {
    await _db.rpc('textbook_review_decide', params: {
      'p_finding_id': findingId,
      'p_action': 'dismiss',
      'p_expected': <String, dynamic>{},
      'p_value': null,
      'p_note': note,
    });
  }

  /// Edge Function 은 최대 400초 안에 끝나므로, 그보다 오래 답이 없으면 응답을 잃은 것으로 보고 끊는다.
  static const Duration kAiCallTimeout = Duration(minutes: 8);

  Future<FunctionResponse> _invokeAiThink(Map<String, dynamic> body) =>
      _db.functions.invoke('ai_think', body: body).timeout(
            kAiCallTimeout,
            onTimeout: () => throw TimeoutException('AI 검수 응답이 ${kAiCallTimeout.inMinutes}분 넘게 없습니다'),
          );

  int midOrderOf(TextbookReviewUnitScope s) => s.midOrder;

  // ── V2 카드(정답·해설) 렌더 ─────────────────────────────────────────────

  /// 정답 + 해설을 한 장의 V2 카드로 찍는다(학생이 보게 될 해설 카드 그대로). URL은 서명 URL.
  Future<String> renderAnswerSolutionCard({
    required String academyId,
    required TextbookProblemReviewItem item,
    required String solutionText,
    required String solutionKind,
    String? answerText,
  }) async {
    final ans = (answerText ?? item.displayAnswer).trim();
    final sol = cleanSolutionTranscribedText(
      solutionText,
      problemNumber: item.problemNumber,
      solutionAnswer: ans,
    );
    if (sol.isEmpty && ans.isEmpty && !item.hasAnswerImage) return '';
    final card = buildAnswerSolutionCardContent(
      answer: formatAnswerForCard(ans),
      solution: sol,
      solutionKind: solutionKind,
      answerImageBucket: item.hasAnswerImage ? item.answerImageBucket : '',
      answerImagePath: item.hasAnswerImage ? item.answerImagePath : '',
      solutionFigures: item.solutionFigureAssets,
    );
    return _pb.renderCustomStemThumbnail(
      academyId: academyId,
      id: 'review-${item.cropId}-$solutionKind',
      stem: card.stem,
      questionNumber: item.problemNumber,
      meta: card.meta,
    );
  }

  /// 해설 본문만 V2 카드로 찍는다(AI 풀이·대안 풀이 카드).
  Future<String> renderSolutionOnlyCard({
    required String academyId,
    required TextbookProblemReviewItem item,
    required String solutionText,
    required String kindKey,
  }) async {
    final sol = solutionText.trim();
    if (sol.isEmpty) return '';
    return _pb.renderCustomStemThumbnail(
      academyId: academyId,
      id: 'review-${item.cropId}-$kindKey',
      stem: sol,
      questionNumber: item.problemNumber,
    );
  }

  /// 수정 제안(또는 운영자가 고친 본문·선지)을 적용하기 전에 V2 로 미리 찍어 본다.
  /// 세트 공통 지시문은 같이 붙여 학생이 볼 모양에 가깝게 한다.
  Future<String> renderProposedProblemCard({
    required String academyId,
    required TextbookProblemReviewItem item,
    required String stem,
    List<Map<String, dynamic>>? choices,
    String? commonStem,
  }) async {
    final body = stem.trim();
    if (body.isEmpty) return '';
    final common = (commonStem ?? item.commonStem).trim();
    final full = common.isNotEmpty && !body.contains(common) ? '$common[문단]$body' : body;
    return _pb.renderCustomStemThumbnail(
      academyId: academyId,
      id: 'review-${item.cropId}-fix',
      stem: full,
      questionNumber: item.problemNumber,
      choices: choices ?? item.rawChoices,
    );
  }

  /// 학생 시점 V2 렌더 검수. 문항 카드 URL과 정답+해설 카드 URL을 ai_think 에 보내 판정받는다.
  Future<Map<String, dynamic>> runRenderCheck({
    required String academyId,
    required List<Map<String, dynamic>> items,
  }) async {
    if (items.isEmpty) return const {'ok': true, 'processed': 0};
    final res = await _db.functions.invoke('ai_think', body: {
      'action': 'textbook_problem_render_check',
      'academy_id': academyId,
      'items': items,
    });
    final data = res.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw Exception('V2 렌더 검수 응답을 해석하지 못했습니다.');
  }

  /// 데이터를 고친 문항만 V2 문항 카드를 새로 찍어 교재 원본과 대조한다(정답·해설 카드는 보내지 않는다).
  /// 통과한 문항은 ai_think 가 품질 승인으로 올리고, 아니면 issue 로 남긴다. 처리한 문항 수를 돌려준다.
  Future<int> recheckProblemCards({
    required TextbookReviewUnitScope scope,
    required List<TextbookProblemReviewItem> items,
    void Function(int done, int total)? onProgress,
  }) async {
    final targets = [for (final it in items) if (it.canRenderOriginal) it];
    if (targets.isEmpty) return 0;
    final urls = await fetchEnginePreviewUrls(academyId: scope.academyId, items: targets);
    const chunkSize = 4;
    const parallel = 3;
    final chunks = <List<TextbookProblemReviewItem>>[
      for (var i = 0; i < targets.length; i += chunkSize) targets.skip(i).take(chunkSize).toList(),
    ];
    var processed = 0;
    var done = 0;
    var next = 0;
    Future<void> worker() async {
      while (next < chunks.length) {
        final chunk = chunks[next++];
        final payload = <Map<String, dynamic>>[];
        for (final p in await Future.wait(chunk.map((it) async {
          final url = urls[it.cropId] ?? '';
          if (url.isEmpty) return null;
          return <String, dynamic>{
            'crop_id': it.cropId,
            'problem_url': url,
            'solution_kind': it.primarySolutionKind,
            'is_fill_in_blank': it.isFillInBlank,
            ...await originalImagesJson(scope, it),
          };
        }))) {
          if (p != null) payload.add(p);
        }
        if (payload.isNotEmpty) {
          final res = await runRenderCheck(academyId: scope.academyId, items: payload);
          processed += (res['processed'] as num?)?.toInt() ?? 0;
        }
        done += chunk.length;
        onProgress?.call(done, targets.length);
      }
    }

    await Future.wait([for (var w = 0; w < parallel && w < chunks.length; w++) worker()]);
    return processed;
  }

  /// 원본 대조에서 잰 비율이 허용 범위를 벗어난 문항의 그림 폭을 그 비율만큼 되돌린다. 바뀐 문항 crop_id 를 돌려준다.
  Future<List<String>> resizeFiguresFromMeasuredRatio(List<TextbookProblemReviewItem> items) async {
    final out = <String>[];
    for (final it in items) {
      if (it.isEngineHeld || !it.figureNeedsResize) continue;
      final scaled = scaleFigureLayout(
        it.pbFigureLayout,
        1 / it.figureSizeRatio!,
        fallbackAssets: it.pbFigureAssets,
        fallbackCount: figureMarkerCount(it.stem),
      );
      if (figureLayoutItems(scaled).isEmpty) continue;
      final changed = await stageChanges(
        cropId: it.cropId,
        patch: {'figure_layout': scaled},
        note: '그림 크기를 원본 글자 비율에 맞춰 재조정',
      );
      if (changed.isNotEmpty) out.add(it.cropId);
    }
    return out;
  }

  /// 해설 그림 폭(width_em)을 잰 비율의 역수만큼 고친다. 반환: 고쳤는가
  Future<bool> resizeSolutionFigures(TextbookProblemReviewItem it) async {
    if (!it.solutionFigureNeedsResize) return false;
    final k = 1 / it.solutionFigureSizeRatio!;
    final assets = [
      for (final a in it.solutionFigureAssets)
        {
          ...a,
          if (a['width_em'] is num) 'width_em': double.parse(((a['width_em'] as num).toDouble() * k).toStringAsFixed(2)),
        },
    ];
    await _db.rpc('textbook_review_set_solution_figures', params: {
      'p_crop_id': it.cropId,
      'p_assets': assets,
    });
    return true;
  }

  Future<int> approveAxis(List<String> cropIds, String axis) async {
    if (cropIds.isEmpty) return 0;
    final res = await _db.rpc('textbook_review_approve_axis', params: {
      'p_crop_ids': cropIds,
      'p_axis': axis,
    });
    return (res is Map ? (res['approved'] as num?)?.toInt() : null) ?? 0;
  }

  /// 정답·풀이·해설 저장(+승인). 정답을 넘기면 문제은행 사본의 주관식·객관식 정답도 함께 맞춘다.
  /// 반환: pb_answer_sync {synced, pb_question_id, changed:[...]} (정답을 안 넘겼으면 null)
  Future<Map<String, dynamic>?> saveItemEdit({
    required String cropId,
    String? newAnswer,
    String? aiSolution,
    String? aiAnswer,
    required List<String> visualTags,
    bool approveMath = false,
    bool approveQuality = false,
    String? solutionTranscribed,
    String? solutionAnswer,
    List<Map<String, dynamic>>? alternativeSolutions,
    bool syncPbAnswer = true,
    bool replaceImageAnswer = false,
  }) async {
    final res = await _db.rpc('textbook_review_save_item_edit', params: {
      'p_crop_id': cropId,
      'p_new_answer': newAnswer,
      'p_ai_solution': aiSolution,
      'p_visual_tags': visualTags,
      'p_approve_math': approveMath,
      'p_approve_quality': approveQuality,
      'p_solution_transcribed': solutionTranscribed,
      'p_solution_answer': solutionAnswer,
      'p_alternative_solutions': alternativeSolutions,
      'p_sync_pb_answer': syncPbAnswer,
      if (aiAnswer != null) 'p_ai_answer': aiAnswer,
      if (replaceImageAnswer) 'p_replace_image_answer': true,
    });
    final sync = res is Map ? res['pb_answer_sync'] : null;
    return sync is Map ? Map<String, dynamic>.from(sync) : null;
  }

  /// 문제은행 문항 유형 설정(objective | subjective | essay). 반환: 실제로 바뀌었는가
  /// 문항 유형을 바꾸고 문제은행 정답을 그 유형에 맞게 다시 맞춘다. [allowSubjective] 는 객관식일 때 주관식 겸용 여부.
  Future<bool> setQuestionKind(String cropId, String kind, {bool? allowSubjective}) async {
    final res = await _db.rpc('textbook_review_set_question_kind', params: {
      'p_crop_id': cropId,
      'p_kind': kind,
      if (allowSubjective != null) 'p_allow_subjective': allowSubjective,
    });
    return res is Map && res['changed'] == true;
  }

  /// 수정안·사장님 수정을 반영 대기 값으로 쌓는다(문제은행·정답 테이블은 쓰지 않는다).
  /// [patch] 의 값이 null 이면 그 항목의 반영 대기를 지운다. [mathStatus]·[qualityStatus] 는 'clean' | 'issue'.
  /// 반환: 바뀐 반영 대기 항목 키
  Future<List<String>> stageChanges({
    required String cropId,
    Map<String, dynamic> patch = const {},
    String source = 'ai',
    String? note,
    String? mathStatus,
    String? qualityStatus,
  }) async {
    final res = await _db.rpc('textbook_review_stage_changes', params: {
      'p_crop_id': cropId,
      'p_patch': patch,
      'p_source': source,
      'p_note': note,
      'p_math_status': mathStatus,
      'p_quality_status': qualityStatus,
    });
    return [for (final x in (res is Map && res['changed'] is List ? res['changed'] as List : const [])) '$x'];
  }

  /// 교정 의견 처리. 교재 원본은 바꾸지 않는다. dismiss=false 면 교재 오류로 확인, true 면 교재 오류 아님으로 기각.
  Future<void> closeCorrectionNote({required String findingId, bool dismiss = false, String note = ''}) async {
    await _db.rpc('textbook_review_close_correction_note', params: {
      'p_finding_id': findingId,
      'p_dismiss': dismiss,
      'p_note': note,
    });
  }

  /// 본문·선지·공통 발문·그림 배치 수정을 반영 대기 값으로 쌓는다. 원본에서 다시 잘라야 할 그림은 먼저 잘라 올리고
  /// 같은 번호의 그림 자산을 바꿔 끼운다(올린 그림 파일 말고는 문제은행에 쓰지 않는다). 반환: 바뀐 반영 대기 항목 키
  Future<List<String>> stageProblemFix({
    required TextbookReviewUnitScope scope,
    required TextbookProblemReviewItem item,
    String? stem,
    List<Map<String, dynamic>>? choices,
    String? commonStem,
    Map<String, dynamic>? figureLayout,
    List<Map<String, dynamic>> figureCrops = const [],
    List<Map<String, dynamic>>? figureAssets,
    String source = 'ai',
    String? note,
    String? qualityStatus,
  }) async {
    var assets = figureAssets;
    if (figureCrops.isNotEmpty) {
      final added = await cropAndUploadFigures(scope: scope, item: item, crops: figureCrops);
      if (added.isNotEmpty) {
        final replaced = {for (final a in added) '${a['figure_index']}'};
        assets = [
          for (final a in assets ?? item.pbFigureAssets)
            if (!replaced.contains('${a['figure_index']}')) a,
          ...added,
        ];
      }
    }
    return stageChanges(
      cropId: item.cropId,
      patch: {
        if (stem != null) 'stem': stem,
        if (choices != null) 'choices': choices,
        if (commonStem != null) 'common_stem': commonStem,
        if (figureLayout != null) 'figure_layout': figureLayout,
        if (assets != null) 'figure_assets': assets,
      },
      source: source,
      note: note,
      qualityStatus: qualityStatus,
    );
  }

  /// 소단원 확정: 문항 유형 불일치를 반영 대기에 넣고, 반영 대기 값을 문제은행·정답에 한 번에 반영한 뒤 두 축을 승인한다.
  /// 한 문항이라도 실패하면 아무것도 반영되지 않고 예외가 난다. 반영 뒤 주관식 문항의 객관식 보기를 만든다(실패해도 확정은 유지).
  Future<({int applied, int generated, List<String> errors})> applyForConfirm(List<TextbookProblemReviewItem> items) async {
    if (items.isEmpty) return (applied: 0, generated: 0, errors: const <String>[]);
    for (final it in [for (final x in items) if (x.questionKindMismatch) x]) {
      final kind = it.expectedQuestionKind;
      await stageChanges(
        cropId: it.cropId,
        patch: {
          'question_kind': kind,
          if (kind == 'objective' && it.answerChoiceCount > 0) 'allow_subjective': it.subjectiveAlsoPossible,
        },
        note: '문항 유형 규칙',
      );
    }
    final res = await _db.rpc('textbook_review_apply_staged', params: {
      'p_crop_ids': [for (final x in items) x.cropId],
    });
    final applied = (res is Map ? (res['applied'] as num?)?.toInt() : null) ?? 0;
    var generated = 0;
    final errors = <String>[];
    for (final it in [for (final x in items) if (x.needsObjectiveGeneration) x]) {
      try {
        if (await generateObjectiveChoices(it)) generated++;
      } catch (e) {
        errors.add('${it.problemNumber}번 객관식 보기: $e');
      }
    }
    return (applied: applied, generated: generated, errors: errors);
  }

  /// 주관식 문항의 객관식 보기를 문제은행과 같은 AI 생성으로 만든다. 만들었으면 true.
  Future<bool> generateObjectiveChoices(TextbookProblemReviewItem item) async {
    if (!_pb.hasGateway || item.pbQuestionId.isEmpty) return false;
    final r = await _pb.generateObjectiveChoices(questionId: item.pbQuestionId);
    return r.success && r.choices.isNotEmpty;
  }

  /// 본문·선지·공통 발문·그림 배치·그림 자산 수정을 문제은행 문항에 적용한다(+품질 승인).
  /// 반환: {changed:[stem|choices|common_stem|figure_assets|figure_layout], pb_question_id, approved}
  Future<Map<String, dynamic>> applyProblemFix({
    required String cropId,
    String? stem,
    List<Map<String, dynamic>>? choices,
    bool approveQuality = false,
    String? note,
    String? commonStem,
    Map<String, dynamic>? figureLayout,
    List<Map<String, dynamic>>? figureAssets,
  }) async {
    final res = await _db.rpc('textbook_review_apply_problem_fix', params: {
      'p_crop_id': cropId,
      'p_stem': stem,
      'p_choices': choices,
      'p_approve_quality': approveQuality,
      'p_note': note,
      'p_common_stem': commonStem,
      'p_figure_layout': figureLayout,
      'p_figure_assets': figureAssets,
    });
    return res is Map ? Map<String, dynamic>.from(res) : const {};
  }

  /// 렌더 엔진 문제로 보류(hold=true) / 보류 해제(hold=false, 다시 '오류' 상태로)
  Future<int> setEngineHold(List<String> cropIds, {required bool hold, String? note}) async {
    if (cropIds.isEmpty) return 0;
    final res = await _db.rpc('textbook_review_set_engine_hold', params: {
      'p_crop_ids': cropIds,
      'p_hold': hold,
      'p_note': note,
    });
    return (res is Map ? (res['updated'] as num?)?.toInt() : null) ?? 0;
  }

  /// 엔진 보류 문항이 있는 단원 목록(보류 중 + 최근 30일 내 해결). 문항 상세는 fetchUnitItems 로 단원별로 읽는다.
  Future<List<TextbookReviewEngineHoldUnit>> fetchEngineHoldUnits() async {
    final res = await _db.rpc('textbook_review_engine_hold_list');
    final map = res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
    return [
      for (final r in (map['units'] as List?) ?? const [])
        if (r is Map) TextbookReviewEngineHoldUnit.fromJson(Map<String, dynamic>.from(r)),
    ];
  }

  /// 엔진 보류 목록의 문항 상세. 단원별 overview 를 읽어 보류·해결 crop 만 고른다.
  Future<List<TextbookReviewEngineHoldEntry>> fetchEngineHoldEntries() async {
    final units = await fetchEngineHoldUnits();
    final out = <TextbookReviewEngineHoldEntry>[];
    for (final u in units) {
      final items = await fetchUnitItems(u.scope);
      final byId = {for (final it in items) it.cropId: it};
      for (final id in u.heldCropIds) {
        final it = byId[id];
        if (it != null) out.add(TextbookReviewEngineHoldEntry(unit: u, item: it, resolved: false));
      }
      for (final id in u.resolvedCropIds) {
        final it = byId[id];
        if (it != null) out.add(TextbookReviewEngineHoldEntry(unit: u, item: it, resolved: true));
      }
    }
    return out;
  }

  Future<int> acceptDraftProposal({
    required String cropId,
    required String proposalCode,
    bool backfillMidunit = true,
  }) async {
    final res = await _db.rpc('textbook_review_accept_draft_proposal', params: {
      'p_crop_id': cropId,
      'p_proposal_code': proposalCode,
      'p_backfill_midunit': backfillMidunit,
    });
    return (res is Map ? (res['backfilled_count'] as num?)?.toInt() : null) ?? 0;
  }
}
