// 목차 자동 인식 공용 로직.
//
// 교재 등록 위저드(textbook_register_wizard.dart)와 단원분석 다이얼로그
// (textbook_unit_authoring_dialog.dart) 양쪽에서 쓴다:
//   1. [showTocRangeDialog] — 목차 페이지 범위 + 페이지 보정값 입력.
//   2. [buildTocAutofillTree] — VLM 목차 결과를 이름 정리(번호 제거, 카테고리
//      라벨 필터) + 페이지 자동 채움(시작 = 인쇄 페이지 + 보정,
//      끝 = 다음 항목 시작 − 1)까지 끝낸 중립 트리로 변환. 호출 측은 이
//      트리를 각자의 편집 모델로만 옮기면 된다.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/textbook_vlm_test_service.dart';

/// 개념원리 목차/트리에서 단원명이 아니라 문제 카테고리 라벨인 항목들.
/// VLM 이 이런 라벨을 단원으로 잘못 올려보내면 트리에서 걸러낸다.
const Set<String> kWonriCategoryLabels = <String>{
  '개념원리 이해',
  '개념원리 익히기',
  '필수유형',
  '확인 체크',
  '확인체크',
  '연습문제',
  '특강',
  'STEP1',
  'STEP2',
  '실력 UP',
  '실력UP',
  '수능 기출',
  '수능기출',
  '평가원 기출',
  '평가원기출',
  '교육청 기출',
  '교육청기출',
};

/// 목차에서 읽어온 단원 이름 앞의 번호 표기를 제거한다.
/// 예: "I. 다항식" → "다항식", "Ⅰ. 다항식" → "다항식",
///     "1. 다항식의 연산" → "다항식의 연산", "01 다항식의 덧셈과 뺄셈" → "다항식의 덧셈과 뺄셈"
String stripTocUnitNumbering(String raw) {
  var s = raw.trim();
  // 유니코드 로마숫자 (Ⅰ, Ⅱ, …) — 구분자 없이도 제거.
  s = s.replaceFirst(RegExp(r'^[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅪⅫⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹ]+\s*[.)\-·]?\s*'), '');
  // ASCII 로마숫자 (I, II, IV …) — 뒤에 구분자가 있을 때만 (일반 단어 보호).
  s = s.replaceFirst(RegExp(r'^[IVXivx]+\s*[.)\-·]\s*'), '');
  // 쎈 목차처럼 구분자 없이 "IV 통계"로 오는 경우. 뒤가 한글일 때만 제거해
  // 영문 단원명의 첫 단어를 로마숫자로 오인하지 않는다.
  s = s.replaceFirst(RegExp(r'^[IVXivx]+\s+(?=[가-힣])'), '');
  // 아라비아 숫자 ("1.", "01", "1-1." 등).
  s = s.replaceFirst(RegExp(r'^\d+(\s*-\s*\d+)?\s*[.)\-·]?\s+'), '');
  s = s.replaceFirst(RegExp(r'^\d+(\s*-\s*\d+)?\s*[.)\-·]\s*'), '');
  final out = s.trim();
  return out.isEmpty ? raw.trim() : out;
}

// ─────────── VLM 목차 결과 → 중립 트리 변환 ───────────

class TocAutofillSubUnit {
  TocAutofillSubUnit({
    required this.name,
    this.isExercise = false,
    this.printedPage,
  });

  final String name;
  final bool isExercise;

  /// 목차에 인쇄된 시작 페이지 숫자 (보정 전).
  final int? printedPage;

  /// 보정 적용 후 PDF raw 페이지. [buildTocAutofillTree] 가 채운다.
  int? startPage;
  int? endPage;
}

class TocAutofillMidUnit {
  TocAutofillMidUnit({required this.name, this.printedPage});
  final String name;
  final int? printedPage;
  int? startPage;
  int? endPage;
  final List<TocAutofillSubUnit> subUnits = <TocAutofillSubUnit>[];

  /// RPM 전용 A/B/C 자동 범위. key는 A, B, C.
  final Map<String, TocAutofillPageRange> rpmPartRanges =
      <String, TocAutofillPageRange>{};
}

class TocAutofillPageRange {
  const TocAutofillPageRange({required this.startPage, required this.endPage});
  final int startPage;
  final int endPage;
}

class TocAutofillBigUnit {
  TocAutofillBigUnit({required this.name});
  final String name;
  final List<TocAutofillMidUnit> midUnits = <TocAutofillMidUnit>[];
}

/// VLM 목차 결과를 이름 정리 + 페이지 자동 채움까지 끝낸 트리로 변환한다.
///
/// [subUnitRows] 가 true(개념원리)면 책의 소단원/연습문제 행을 midUnits 아래
/// subUnits 로 담고, false(쎈/RPM)면 대/중단원 이름만 담는다.
/// [tocPageOffset] = PDF raw 페이지 − 목차에 인쇄된 페이지.
List<TocAutofillBigUnit> buildTocAutofillTree(
  TextbookTocParseResult toc, {
  required bool subUnitRows,
  int tocPageOffset = 0,
  int? lastRawPage,
}) {
  final bigs = <TocAutofillBigUnit>[];
  for (final big in toc.bigUnits) {
    final bigOut = TocAutofillBigUnit(name: stripTocUnitNumbering(big.name));
    for (final mid in big.midUnits) {
      final midName = stripTocUnitNumbering(mid.name);
      // 카테고리 라벨이 단원명으로 잘못 올라온 경우 스킵한다.
      if (kWonriCategoryLabels.contains(midName)) continue;
      final midOut = TocAutofillMidUnit(
        name: midName,
        printedPage: mid.page,
      );
      if (subUnitRows) {
        // 연습문제는 소단원 사이사이에 여러 번 나올 수 있으므로
        // 목차에 인쇄된 순서 그대로 행을 만든다.
        for (final sub in mid.subUnits) {
          final subName = stripTocUnitNumbering(sub.name);
          if (subName.isEmpty) continue;
          if (sub.isExercise || subName == '연습문제') {
            midOut.subUnits.add(TocAutofillSubUnit(
              name: '연습문제',
              isExercise: true,
              printedPage: sub.page,
            ));
            continue;
          }
          if (kWonriCategoryLabels.contains(subName)) continue;
          midOut.subUnits.add(TocAutofillSubUnit(
            name: subName,
            printedPage: sub.page,
          ));
        }
        if (mid.hasExercise && !midOut.subUnits.any((s) => s.isExercise)) {
          midOut.subUnits
              .add(TocAutofillSubUnit(name: '연습문제', isExercise: true));
        }
      }
      bigOut.midUnits.add(midOut);
    }
    bigs.add(bigOut);
  }

  // 페이지 자동 채움 — 책 전체 순서(중단원/대단원 경계 포함)로 계산한다.
  // 시작 = 인쇄 페이지 + 보정, 끝 = 다음으로 페이지가 있는 행의 시작 − 1.
  // 마지막 행이나 페이지 숫자가 감소하는(순서가 어긋난) 행은 끝을 비워 둔다.
  final flat = <TocAutofillSubUnit>[
    for (final big in bigs)
      for (final mid in big.midUnits) ...mid.subUnits,
  ];
  for (var i = 0; i < flat.length; i += 1) {
    final row = flat[i];
    final printed = row.printedPage;
    if (printed == null || printed <= 0) continue;
    final startRaw = printed + tocPageOffset;
    if (startRaw < 1) continue;
    row.startPage = startRaw;
    int? nextPrinted;
    for (var j = i + 1; j < flat.length; j += 1) {
      final p = flat[j].printedPage;
      if (p != null && p > 0) {
        nextPrinted = p;
        break;
      }
    }
    if (nextPrinted == null || nextPrinted <= printed) continue;
    final endRaw = nextPrinted - 1 + tocPageOffset;
    if (endRaw >= startRaw) row.endPage = endRaw;
  }

  // RPM 같은 2단계 목차는 중단원 줄에 시작 페이지가 인쇄된다.
  // 다음 중단원(대단원 경계 포함) 또는 트리에서 제외한 부록 시작 직전까지를
  // 해당 중단원의 본문 범위로 잡는다.
  final flatMids = <TocAutofillMidUnit>[
    for (final big in bigs) ...big.midUnits,
  ];
  for (var i = 0; i < flatMids.length; i += 1) {
    final mid = flatMids[i];
    final printed = mid.printedPage;
    if (printed == null || printed <= 0) continue;
    final startRaw = printed + tocPageOffset;
    if (startRaw < 1) continue;
    mid.startPage = startRaw;
    int? nextPrinted;
    for (var j = i + 1; j < flatMids.length; j += 1) {
      final candidate = flatMids[j].printedPage;
      if (candidate != null && candidate > printed) {
        nextPrinted = candidate;
        break;
      }
    }
    nextPrinted ??= toc.appendixBoundaryPage;
    if (nextPrinted == null || nextPrinted <= printed) {
      if (i == flatMids.length - 1 &&
          lastRawPage != null &&
          lastRawPage >= startRaw) {
        mid.endPage = lastRawPage;
      }
      continue;
    }
    final endRaw = nextPrinted - 1 + tocPageOffset;
    if (endRaw >= startRaw) mid.endPage = endRaw;
  }
  return bigs;
}

typedef ProblemBookSectionClassifier = Future<List<TextbookRpmSectionPage>>
    Function(
  List<int> rawPages,
);

class ProblemBookPartAutofillReport {
  const ProblemBookPartAutofillReport({
    required this.completedMids,
    required this.incompleteMids,
  });

  final int completedMids;
  final List<String> incompleteMids;
}

/// 쎈/RPM 중단원 본문을 경량 분류해 A/B/C 페이지 입력 범위를 채운다.
///
/// A에는 개념 설명과 A 문제가 함께 포함될 수 있으므로 중단원 시작부터 B 헤더
/// 직전까지를 통째로 둔다. 실제 분석 시 문항 없는 개념 페이지는 통과한다.
Future<ProblemBookPartAutofillReport> autofillProblemBookPartRanges(
  List<TocAutofillBigUnit> tree, {
  required ProblemBookSectionClassifier classify,
  void Function(String message)? onProgress,
  int batchSize = 12,
}) async {
  final mids = <TocAutofillMidUnit>[
    for (final big in tree) ...big.midUnits,
  ];
  var completed = 0;
  final incomplete = <String>[];
  for (var midIndex = 0; midIndex < mids.length; midIndex += 1) {
    final mid = mids[midIndex];
    final start = mid.startPage;
    final end = mid.endPage;
    if (start == null || end == null || end < start) {
      incomplete.add('${mid.name}(본문 범위 없음)');
      continue;
    }
    onProgress?.call(
      'RPM 파트 경계 분석 중... (${midIndex + 1}/${mids.length}) ${mid.name}',
    );
    final classified = <TextbookRpmSectionPage>[];
    final allPages = <int>[for (var page = start; page <= end; page += 1) page];
    final safeBatchSize = batchSize.clamp(1, 24);
    for (var offset = 0; offset < allPages.length; offset += safeBatchSize) {
      final hi = (offset + safeBatchSize).clamp(0, allPages.length);
      classified.addAll(await classify(allPages.sublist(offset, hi)));
    }
    classified.sort((a, b) => a.rawPage.compareTo(b.rawPage));

    // 정확한 상단 헤더 플래그를 우선하고, 모델이 헤더 글자를 놓쳤을 때만
    // 단조로운 A→B→C section 판정을 보조 신호로 사용한다.
    int? bStart;
    int? cStart;
    for (final page in classified) {
      if (page.typePracticeHeaderVisible && bStart == null) {
        bStart = page.rawPage;
      }
      if (page.masteryHeaderVisible && cStart == null) {
        cStart = page.rawPage;
      }
    }
    if (bStart == null) {
      for (final page in classified) {
        if (page.section == 'type_practice') {
          bStart = page.rawPage;
          break;
        }
      }
    }
    if (cStart == null) {
      for (final page in classified) {
        if (page.section == 'mastery') {
          cStart = page.rawPage;
          break;
        }
      }
    }

    if (bStart == null ||
        cStart == null ||
        bStart <= start ||
        cStart <= bStart ||
        cStart > end) {
      incomplete.add('${mid.name}(B/C 헤더 확인 실패)');
      continue;
    }
    mid.rpmPartRanges
      ..clear()
      ..addAll(<String, TocAutofillPageRange>{
        'A': TocAutofillPageRange(startPage: start, endPage: bStart - 1),
        'B': TocAutofillPageRange(startPage: bStart, endPage: cStart - 1),
        'C': TocAutofillPageRange(startPage: cStart, endPage: end),
      });
    completed += 1;
  }
  return ProblemBookPartAutofillReport(
    completedMids: completed,
    incompleteMids: incomplete,
  );
}

// ─────────── 목차 페이지 범위 + 페이지 보정 입력 다이얼로그 ───────────

class TocParseRequest {
  const TocParseRequest({
    required this.start,
    required this.end,
    this.pageOffset = 0,
  });

  /// 목차가 있는 본문 PDF raw 페이지 범위.
  final int start;
  final int end;

  /// PDF raw 페이지 − 책에 인쇄된 페이지. 목차의 인쇄 페이지 숫자를
  /// PDF 페이지로 환산해 소단원 시작/끝 페이지를 자동으로 채우는 데 쓴다.
  final int pageOffset;
}

Future<TocParseRequest?> showTocRangeDialog(BuildContext context) {
  return showDialog<TocParseRequest>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => const _TocRangeDialog(),
  );
}

class _TocRangeDialog extends StatefulWidget {
  const _TocRangeDialog();

  @override
  State<_TocRangeDialog> createState() => _TocRangeDialogState();
}

class _TocRangeDialogState extends State<_TocRangeDialog> {
  final _startCtrl = TextEditingController();
  final _endCtrl = TextEditingController();
  final _offsetCtrl = TextEditingController(text: '0');

  @override
  void dispose() {
    _startCtrl.dispose();
    _endCtrl.dispose();
    _offsetCtrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final start = int.tryParse(_startCtrl.text.trim());
    final end = int.tryParse(_endCtrl.text.trim());
    if (start == null || end == null || start <= 0 || end < start) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('올바른 시작/끝 페이지를 입력하세요.')),
      );
      return;
    }
    if (end - start + 1 > 12) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('목차는 최대 12페이지까지 지원합니다.')),
      );
      return;
    }
    final offsetText = _offsetCtrl.text.trim();
    final offset =
        offsetText.isEmpty || offsetText == '-' ? 0 : int.tryParse(offsetText);
    if (offset == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('페이지 보정값이 올바르지 않습니다.')),
      );
      return;
    }
    Navigator.of(context)
        .pop(TocParseRequest(start: start, end: end, pageOffset: offset));
  }

  InputDecoration _decoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white70),
      enabledBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: Colors.white24),
      ),
      focusedBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: Color(0xFF1976D2)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('목차 페이지 범위',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '본문 PDF 기준(스캔 파일의 실제 페이지 번호)으로 "차례"가 시작되는 '
              '페이지부터 목차가 끝나는 페이지까지 입력하세요. RPM은 마지막 '
              '중단원의 끝 경계를 계산할 수 있도록 "부록 대표문제 다시 풀기" '
              '항목이 보이는 목차 페이지까지 포함하세요.',
              style: TextStyle(color: Color(0xFF9FB3B3), fontSize: 12),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _startCtrl,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    style: const TextStyle(color: Colors.white),
                    decoration: _decoration('시작 (raw)'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _endCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    style: const TextStyle(color: Colors.white),
                    decoration: _decoration('끝 (raw)'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              '페이지 보정 = PDF 페이지 − 책에 인쇄된 페이지. '
              '예: 책 8쪽이 PDF 10페이지면 2. 목차의 인쇄 페이지 숫자로 '
              '소단원 시작/끝 페이지를 자동으로 채우는 데 사용합니다.',
              style: TextStyle(color: Color(0xFF9FB3B3), fontSize: 12),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _offsetCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.allow(RegExp(r'^-?\d*$')),
              ],
              style: const TextStyle(color: Colors.white),
              decoration: _decoration('페이지 보정 (PDF − 인쇄)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소', style: TextStyle(color: Colors.white70)),
        ),
        FilledButton(
          onPressed: _confirm,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF33A373),
          ),
          child: const Text('인식 시작'),
        ),
      ],
    );
  }
}
