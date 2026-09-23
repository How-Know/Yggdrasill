// 목차 자동 인식 공용 로직.
//
// 교재 등록 위저드(textbook_register_wizard.dart)와 단원분석 다이얼로그
// (textbook_unit_authoring_dialog.dart) 양쪽에서 쓴다:
//   1. [showTocRangeDialog] — 목차 페이지 범위 + 페이지 보정값 입력.
//   2. [buildTocAutofillTree] — VLM 목차 결과를 이름 정리(번호 제거, 카테고리
//      라벨 필터) + 페이지 자동 채움(시작 = 인쇄 페이지 + 보정,
//      끝 = 다음 항목 시작 − 1)까지 끝낸 중립 트리로 변환. 호출 측은 이
//      트리를 각자의 편집 모델로만 옮기면 된다.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../services/textbook_vlm_test_service.dart';

/// 목차 지면을 판독에 보낼 때의 렌더 해상도(긴 변 픽셀).
///
/// 600dpi 스캔 교재는 원본이 4900×6832 쯤이라 여기까지 줄이는 배율이 그대로
/// 화질을 좌우한다. 1600px 로 줄이면 수력충전 2-1 처럼 3단으로 촘촘한 차례는
/// 점선과 쪽 숫자가 뭉개져 판독이 단원을 하나도 못 찾는다(같은 지면으로
/// 확인: 1600px → 대단원 0개, 2400px → 6개 전부). 2400px 은 두 쪽을 보내도
/// 3MB 정도라 왕복에 무리가 없다.
const int kTocRenderLongEdgePx = 2400;

/// 목차 인식이 빈손으로 끝난 까닭을 상태줄에 덧붙일 문구로 만든다.
///
/// "단원을 찾지 못했습니다" 는 두 가지가 겹친다 — 판독이 아무것도 못 읽은
/// 경우와, 읽었지만 [buildTocAutofillTree] 에서 전부 걸러진 경우. 손볼 곳이
/// 달라서 판독이 돌려준 개수를 함께 보여 준다. 판독이 비었다면 애초에 보낸
/// 지면이 차례가 아니었을 수 있으니, 보낸 PNG 를 그대로 떠서 경로를 알린다.
Future<String> describeTocAutofillFailure(
  TextbookTocParseResult toc, {
  required List<Uint8List> pageImages,
  required int startPage,
}) async {
  var midCount = 0;
  for (final big in toc.bigUnits) {
    midCount += big.midUnits.length;
  }
  final counts = ' (판독 대단원 ${toc.bigUnits.length}개 / 중단원 $midCount개'
      '${toc.notes.isEmpty ? '' : ' · ${toc.notes}'})';
  if (toc.bigUnits.isNotEmpty) return counts;
  try {
    final dir = Directory(p.join(
      Directory.systemTemp.path,
      'ygg_toc_debug',
      DateTime.now().millisecondsSinceEpoch.toString(),
    ))
      ..createSync(recursive: true);
    for (var i = 0; i < pageImages.length; i += 1) {
      File(p.join(dir.path, 'p${startPage + i}.png'))
          .writeAsBytesSync(pageImages[i]);
    }
    return '$counts · 보낸 지면: ${dir.path}';
  } catch (_) {
    return counts;
  }
}

/// 개념원리 목차/트리에서 단원명이 아니라 문제 카테고리 라벨인 항목들.
/// VLM 이 이런 라벨을 단원으로 잘못 올려보내면 트리에서 걸러낸다.
const Set<String> kWonriCategoryLabels = <String>{
  '개념원리 이해',
  '개념원리 익히기',
  '필수유형',
  '확인 체크',
  '확인체크',
  '연습문제',
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

/// 중등 개념원리에서 단원이 아닌 학습영역·보조 라벨.
const Set<String> kWonriMiddleCategoryLabels = <String>{
  '개념원리 이해',
  '개념원리 확인하기',
  '핵심문제 익히기',
  '이런 문제가 시험에 나온다',
  '계산력 강화하기',
  '중단원 마무리하기',
  '서술형 대비 문제',
  'STEP 1 기본',
  'STEP 2 발전',
  'STEP 3 실력 UP',
  'KEY POINT',
  '힌트',
  '참고',
};

/// 개념+유형 목차/트리에서 단원명이 아니라 문제 카테고리 라벨인 항목들.
const Set<String> kConceptPlusCategoryLabels = <String>{
  '개념확인',
  '개념 확인',
  '필수문제',
  '필수 문제',
  '따름문제',
  '따름 문제',
  '쏙쏙 개념 익히기',
  '쏙쏙 개념익히기',
  '개념 익히기',
  '개념익히기',
  '탄탄 단원 다지기',
  '탄탄 단원다지기',
  '쓱쓱 서술형 완성하기',
  '쓱쓱 서술형완성하기',
  '한번 더 연습',
  '한 번 더 연습',
  'STEP1',
  'STEP2',
  'STEP3',
};

/// 개념+유형 중단원 끝의 마무리 지면 이름들.
///
/// 목차에는 "• 단원 다지기 / 서술형 완성하기", "• 개념 리뷰 / 마인드맵" 두 줄로
/// 인쇄된다. 네 지면을 "단원 다지기" 소단원 한 행으로 합쳐서 다룬다.
const Set<String> _kConceptPlusUnitEndNames = <String>{
  '단원다지기',
  '서술형완성하기',
  '개념리뷰',
  '마인드맵',
};

bool _isConceptPlusUnitEndName(String name) {
  for (final token in name.split('/')) {
    final compact = token.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) continue;
    if (_kConceptPlusUnitEndNames.contains(compact)) return true;
  }
  return false;
}

/// 수력충전 목차/트리에서 단원명이 아니라 문제 라벨인 항목들.
const Set<String> kSuryeokCategoryLabels = <String>{
  '유형',
  '개념 체크',
  '개념체크',
  '계산 조심',
  '계산조심',
  '생각 더하기',
  '생각더하기',
  '조건 확인',
  '조건확인',
  '시험에 꼭!',
  '시험에꼭',
  '도전해 얍!',
  '도전해얍',
  '개념 찾아보기',
  '개념찾아보기',
};

/// 고쟁이 목차/트리에서 단원명이 아니라 단계·코너 라벨인 항목들.
///
/// 목차 맨 아래 "WORKBOOK" 두 줄은 단원트리에 넣지 않고 워크북 시작 쪽으로만
/// 담는다. 판독이 이를 중단원으로 올려 보내면 여기서 걸러진다.
const Set<String> kGojaengiCategoryLabels = <String>{
  'Step 1 핵심 유형',
  'Step 2 심화 유형',
  'Step 3 최고난도 유형',
  '핵심 유형',
  '심화 유형',
  '최고난도 유형',
  '창의융합 유형',
  '창의융합',
  'STEP1',
  'STEP2',
  'STEP3',
  'WORKBOOK',
  '워크북',
  '중단원 TEST',
  '중단원TEST',
  '대단원 TEST',
  '대단원TEST',
};

/// 수력충전 중단원 끝의 마무리 행인지.
///
/// 목차에는 "• 단원 마무리 평가" 한 줄로 인쇄된다. 앞의 글머리표나 "평가" 누락
/// 같은 판독 흔들림을 흡수하려고 "단원 마무리" 로만 판정한다.
bool _isSuryeokUnitEndName(String name) =>
    name.replaceAll(RegExp(r'\s+'), '').contains('단원마무리');

/// 수력충전 목차 맨 끝의 "학교 시험 대비 실력 향상 테스트" 묶음인지.
///
/// 대단원마다 한 편씩("Ⅰ단원 실력 향상 테스트") 있고 목차에 소단원 줄이
/// 따로 인쇄되지 않는다. 중단원 이름과 소단원 이름 양쪽에서 판정한다.
String? _suryeokSkillTestRowName(String name) =>
    name.replaceAll(RegExp(r'\s+'), '').contains('실력향상테스트')
        ? '실력 향상 테스트'
        : null;

/// 목차 트리를 만들 때 쓰는 시리즈별 규칙.
@immutable
class TocAutofillSeriesRules {
  const TocAutofillSeriesRules({
    required this.categoryLabels,
    required this.unitEndRowName,
    required this.isUnitEndName,
    this.mergeUnitEndRows = false,
    this.specialExerciseRowName,
    this.trailingMidRowName = '',
  });

  /// 단원명으로 잘못 올라온 문제 카테고리 라벨 — 트리에서 걸러낸다.
  final Set<String> categoryLabels;

  /// 중단원 끝 마무리 행에 붙일 표준 이름.
  final String unitEndRowName;

  /// 목차의 소단원 이름이 마무리 지면인지 판정한다.
  final bool Function(String name) isUnitEndName;

  /// 연달아 나오는 마무리 행을 한 행으로 합칠지 여부. 개념+유형처럼 마무리
  /// 지면이 목차에서 여러 줄로 쪼개져 인쇄되는 교재에 쓴다.
  final bool mergeUnitEndRows;

  /// 소단원 줄 없이 중단원 줄 하나로만 인쇄되는 특수 코너(수력충전
  /// "실력 향상 테스트")의 표준 소단원 이름. 해당 코너가 아니면 null 을
  /// 돌려준다. 마무리 지면이지만 대단원마다 따로 있어서 [unitEndRowName] 으로
  /// 이름을 덮으면 서로 구분되지 않는다.
  final String? Function(String name)? specialExerciseRowName;

  /// 대단원마다 끝에 세울 전용 중단원 행의 이름. 빈 문자열이면 없다.
  ///
  /// 고쟁이 워크북 "대단원 TEST" 는 대단원 하나를 통틀어 다뤄서 어느 중단원에도
  /// 매달 자리가 없다. 목차에는 이 묶음의 시작 쪽만 한 번 인쇄되고 대단원별
  /// 범위는 워크북 지면 머리말을 훑어야 나오므로, 행만 세우고 쪽은 비워 둔다.
  final String trailingMidRowName;
}

TocAutofillSeriesRules tocAutofillRulesFor(String seriesKey) {
  if (seriesKey.trim().toLowerCase() == 'wonri_middle') {
    return TocAutofillSeriesRules(
      categoryLabels: kWonriMiddleCategoryLabels,
      unitEndRowName: '중단원 마무리하기',
      isUnitEndName: (name) {
        final compact = name.replaceAll(RegExp(r'\s+'), '');
        return compact.contains('중단원마무리') || compact.contains('서술형대비');
      },
      mergeUnitEndRows: true,
    );
  }
  if (seriesKey.trim().toLowerCase() == 'gojaengi') {
    return TocAutofillSeriesRules(
      categoryLabels: kGojaengiCategoryLabels,
      unitEndRowName: '',
      isUnitEndName: (_) => false,
      trailingMidRowName: '대단원 TEST',
    );
  }
  if (seriesKey.trim().toLowerCase() == 'suryeok') {
    return TocAutofillSeriesRules(
      categoryLabels: kSuryeokCategoryLabels,
      unitEndRowName: '단원 마무리 평가',
      isUnitEndName: _isSuryeokUnitEndName,
      specialExerciseRowName: _suryeokSkillTestRowName,
    );
  }
  if (seriesKey.trim().toLowerCase() == 'gaeyu') {
    return TocAutofillSeriesRules(
      categoryLabels: kConceptPlusCategoryLabels,
      unitEndRowName: '단원 다지기',
      isUnitEndName: _isConceptPlusUnitEndName,
      mergeUnitEndRows: true,
    );
  }
  return TocAutofillSeriesRules(
    categoryLabels: kWonriCategoryLabels,
    unitEndRowName: '연습문제',
    isUnitEndName: (name) => name == '연습문제',
  );
}

/// 목차에서 읽어온 단원 이름 앞의 번호 표기를 제거한다.
/// 예: "I. 다항식" → "다항식", "Ⅰ. 다항식" → "다항식",
///     "1. 다항식의 연산" → "다항식의 연산", "01 다항식의 덧셈과 뺄셈" → "다항식의 덧셈과 뺄셈"
String stripTocUnitNumbering(String raw) {
  var s = raw.trim();
  // 유니코드 로마숫자 (Ⅰ, Ⅱ, …). 뒤에 구분자나 공백이 있을 때만 번호 표기로
  // 본다. 수력충전 "Ⅰ단원 실력 향상 테스트"처럼 붙여 쓴 것은 번호가 아니라
  // 이름의 일부라, 떼어내면 세 대단원의 이름이 모두 같아진다.
  s = s.replaceFirst(
    RegExp(r'^[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅪⅫⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹ]+(\s*[.)\-·]\s*|\s+)'),
    '',
  );
  // ASCII 로마숫자 (I, II, IV …) — 뒤에 구분자가 있을 때만 (일반 단어 보호).
  s = s.replaceFirst(RegExp(r'^[IVXivx]+\s*[.)\-·]\s*'), '');
  // 쎈 목차처럼 구분자 없이 "IV 통계"로 오는 경우. 뒤가 한글일 때만 제거해
  // 영문 단원명의 첫 단어를 로마숫자로 오인하지 않는다.
  s = s.replaceFirst(RegExp(r'^[IVXivx]+\s+(?=[가-힣])'), '');
  // 개념+유형처럼 소단원 번호 "01"의 0을 알파벳 O 모양으로 디자인한 교재는
  // OCR 결과가 "O1 순서쌍과 좌표"로 올라온다. 뒤가 한글일 때만 제거한다.
  s = s.replaceFirst(RegExp(r'^[OoＯｏ]\s*\d+\s*[.)\-·]?\s+(?=[가-힣])'), '');
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
  /// 마무리 행을 합칠 때 뒤 줄의 페이지로 보완할 수 있어 가변이다.
  int? printedPage;

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
/// [subUnitRows] 가 true(개념서)면 책의 소단원/마무리 행을 midUnits 아래
/// subUnits 로 담고, false(쎈/RPM)면 대/중단원 이름만 담는다.
/// [seriesKey] 는 카테고리 라벨 필터와 마무리 행 처리 규칙을 고른다.
/// [tocPageOffset] = PDF raw 페이지 − 목차에 인쇄된 페이지.
List<TocAutofillBigUnit> buildTocAutofillTree(
  TextbookTocParseResult toc, {
  required bool subUnitRows,
  String seriesKey = '',
  int tocPageOffset = 0,
  int? lastRawPage,
}) {
  final rules = tocAutofillRulesFor(seriesKey);
  final bigs = <TocAutofillBigUnit>[];
  for (final big in toc.bigUnits) {
    final bigOut = TocAutofillBigUnit(name: stripTocUnitNumbering(big.name));
    for (final mid in big.midUnits) {
      final midName = stripTocUnitNumbering(mid.name);
      // 카테고리 라벨이 단원명으로 잘못 올라온 경우 스킵한다.
      if (rules.categoryLabels.contains(midName)) continue;
      final midOut = TocAutofillMidUnit(
        name: midName,
        printedPage: mid.page,
      );
      if (subUnitRows) {
        // 마무리 행(개념원리 연습문제)은 소단원 사이사이에 여러 번 나올 수
        // 있으므로 목차에 인쇄된 순서 그대로 행을 만든다.
        for (final sub in mid.subUnits) {
          final subName = stripTocUnitNumbering(sub.name);
          if (subName.isEmpty) continue;
          final specialSub = rules.specialExerciseRowName?.call(subName);
          if (specialSub != null) {
            midOut.subUnits.add(TocAutofillSubUnit(
              name: specialSub,
              isExercise: true,
              printedPage: sub.page,
            ));
            continue;
          }
          if (sub.isExercise || rules.isUnitEndName(subName)) {
            // 개념+유형은 마무리 지면이 목차에서 두 줄로 쪼개져 인쇄되므로
            // 앞 행에 합치고 페이지는 먼저 인쇄된 값을 유지한다.
            final last = midOut.subUnits.isEmpty ? null : midOut.subUnits.last;
            if (rules.mergeUnitEndRows && last != null && last.isExercise) {
              last.printedPage ??= sub.page;
              continue;
            }
            midOut.subUnits.add(TocAutofillSubUnit(
              name: rules.unitEndRowName,
              isExercise: true,
              printedPage: sub.page,
            ));
            continue;
          }
          if (rules.categoryLabels.contains(subName)) continue;
          midOut.subUnits.add(TocAutofillSubUnit(
            name: subName,
            printedPage: sub.page,
          ));
        }
        if (mid.hasExercise && !midOut.subUnits.any((s) => s.isExercise)) {
          midOut.subUnits.add(
            TocAutofillSubUnit(name: rules.unitEndRowName, isExercise: true),
          );
        }
        // 특수 코너는 목차에 소단원 줄이 없다. 중단원 줄 자체를 소단원 한
        // 행으로 세워야 이후 문항 추출 스코프가 생긴다.
        if (midOut.subUnits.isEmpty) {
          final specialMid = rules.specialExerciseRowName?.call(midName);
          if (specialMid != null) {
            midOut.subUnits.add(TocAutofillSubUnit(
              name: specialMid,
              isExercise: true,
              printedPage: mid.page,
            ));
          }
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

  // 고쟁이 워크북 "대단원 TEST" 전용 중단원 행. 본문 쪽 채움을 모두 끝낸 뒤에
  // 세운다 — 쪽이 비어 있는 행을 미리 끼우면 본문 중단원의 "다음 시작 쪽"
  // 사슬에 끼어들 여지가 생긴다. 이 행의 쪽 범위는 워크북 지면 머리말을 훑는
  // [autofillGojaengiWorkbookRanges] 가 채운다.
  if (rules.trailingMidRowName.isNotEmpty) {
    for (final big in bigs) {
      if (big.midUnits.isEmpty) continue;
      if (big.midUnits.any((m) => m.name == rules.trailingMidRowName)) continue;
      big.midUnits.add(TocAutofillMidUnit(name: rules.trailingMidRowName));
    }
  }
  return bigs;
}

typedef WonriMiddleStructureClassifier
    = Future<List<TextbookWonriMiddleStructurePage>> Function(
  List<int> rawPages,
);

@immutable
class WonriMiddleStructureAutofillReport {
  const WonriMiddleStructureAutofillReport({
    required this.completedMids,
    required this.subUnitCount,
    required this.calculationPageCount,
    required this.incompleteMids,
  });

  final int completedMids;
  final int subUnitCount;
  final int calculationPageCount;
  final List<String> incompleteMids;
}

/// 중등 개념원리의 2단계 목차를 본문 소단원 머리말로 보완한다.
///
/// 목차에 없는 이름은 절대 추측하지 않는다. 실제 머리말이 하나도 판독되지 않은
/// 중단원은 빈 행으로 남겨 사용자가 검토하게 한다. 중단원 말미의 마무리/서술형
/// 지면은 하나의 고정 마무리 행으로 합친다.
Future<WonriMiddleStructureAutofillReport> autofillWonriMiddleSubUnitRanges(
  List<TocAutofillBigUnit> tree, {
  required WonriMiddleStructureClassifier classify,
  void Function(String message)? onProgress,
  int chunkSize = 24,
}) async {
  var completedMids = 0;
  var subUnitCount = 0;
  var calculationPageCount = 0;
  final incomplete = <String>[];
  final mids = <TocAutofillMidUnit>[
    for (final big in tree) ...big.midUnits,
  ];

  for (var midIndex = 0; midIndex < mids.length; midIndex += 1) {
    final mid = mids[midIndex];
    final start = mid.startPage;
    final end = mid.endPage;
    if (start == null || end == null || start <= 0 || end < start) {
      incomplete.add(mid.name);
      continue;
    }
    onProgress?.call(
      '중등 개념원리 소단원 머리말 분석 중... '
      '${midIndex + 1}/${mids.length} · ${mid.name}',
    );
    final pages = <TextbookWonriMiddleStructurePage>[];
    for (var chunkStart = start; chunkStart <= end; chunkStart += chunkSize) {
      final chunkEnd = (chunkStart + chunkSize - 1).clamp(chunkStart, end);
      final rawPages = <int>[
        for (var page = chunkStart; page <= chunkEnd; page += 1) page,
      ];
      pages.addAll(await classify(rawPages));
    }
    pages.sort((a, b) => a.rawPage.compareTo(b.rawPage));
    calculationPageCount +=
        pages.where((page) => page.calculationHeaderVisible).length;

    int? unitEndPage;
    for (final page in pages) {
      if (page.unitEndKind == 'review' || page.unitEndKind == 'descriptive') {
        unitEndPage = unitEndPage == null
            ? page.rawPage
            : unitEndPage < page.rawPage
                ? unitEndPage
                : page.rawPage;
      }
    }

    final starts = <({String name, int page})>[];
    final seen = <String>{};
    for (final page in pages) {
      if (!page.subUnitHeaderVisible || page.subUnitName.trim().isEmpty) {
        continue;
      }
      if (unitEndPage != null && page.rawPage >= unitEndPage) continue;
      final name = stripTocUnitNumbering(page.subUnitName);
      final compact = name.replaceAll(RegExp(r'\s+'), '');
      if (name.isEmpty ||
          kWonriMiddleCategoryLabels.any(
            (label) => label.replaceAll(RegExp(r'\s+'), '') == compact,
          )) {
        continue;
      }
      final key = '$compact@${page.rawPage}';
      if (!seen.add(key)) continue;
      // 펼침면 양쪽에 같은 머리말이 반복돼도 한 행만 둔다.
      if (starts.isNotEmpty &&
          starts.last.name.replaceAll(RegExp(r'\s+'), '') == compact) {
        continue;
      }
      starts.add((name: name, page: page.rawPage));
    }

    mid.subUnits.clear();
    for (final startRow in starts) {
      mid.subUnits.add(TocAutofillSubUnit(
        name: startRow.name,
        printedPage: startRow.page,
      )..startPage = startRow.page);
    }
    if (unitEndPage != null) {
      mid.subUnits.add(TocAutofillSubUnit(
        name: '중단원 마무리하기',
        isExercise: true,
        printedPage: unitEndPage,
      )..startPage = unitEndPage);
    }
    for (var i = 0; i < mid.subUnits.length; i += 1) {
      final row = mid.subUnits[i];
      final nextStart =
          i + 1 < mid.subUnits.length ? mid.subUnits[i + 1].startPage : null;
      row.endPage = nextStart != null ? nextStart - 1 : end;
    }

    if (starts.isEmpty) {
      incomplete.add(mid.name);
      continue;
    }
    completedMids += 1;
    subUnitCount += starts.length;
  }

  return WonriMiddleStructureAutofillReport(
    completedMids: completedMids,
    subUnitCount: subUnitCount,
    calculationPageCount: calculationPageCount,
    incompleteMids: incomplete,
  );
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

/// 시리즈별 파트 순서. 첫 파트는 중단원 시작 지면부터 머리말 없이 열리고,
/// 나머지는 지면 상단 머리말이 보이는 첫 지면에서 시작한다.
/// 게이트웨이 `vlm_rpm_section_client.js` 의 SECTION_SERIES_CONFIG 와 같은
/// 집합이어야 한다 — 한쪽만 바뀌면 경계를 못 찾아 전부 미완료로 떨어진다.
const Map<String, List<List<String>>> kProblemBookSectionParts =
    <String, List<List<String>>>{
  // [슬롯 키, section 코드]
  'ssen': <List<String>>[
    <String>['A', 'basic_drill'],
    <String>['B', 'type_practice'],
    <String>['C', 'mastery'],
  ],
  'rpm': <List<String>>[
    <String>['A', 'basic_drill'],
    <String>['B', 'type_practice'],
    <String>['C', 'mastery'],
  ],
  'gojaengi': <List<String>>[
    <String>['A', 'core_type'],
    <String>['B', 'advanced_type'],
    <String>['C', 'top_type'],
    <String>['D', 'creative_type'],
  ],
};

/// 쎈/RPM/고쟁이 중단원 본문을 경량 분류해 파트별 페이지 입력 범위를 채운다.
///
/// 첫 파트에는 개념 설명 페이지가 함께 포함될 수 있으므로 중단원 시작부터 둘째
/// 파트 머리말 직전까지를 통째로 둔다. 실제 분석 시 문항 없는 개념 페이지는
/// 통과한다.
Future<ProblemBookPartAutofillReport> autofillProblemBookPartRanges(
  List<TocAutofillBigUnit> tree, {
  required ProblemBookSectionClassifier classify,
  String series = 'rpm',
  void Function(String message)? onProgress,
  int batchSize = 12,
}) async {
  final parts = kProblemBookSectionParts[series.trim().toLowerCase()] ??
      kProblemBookSectionParts['rpm']!;
  final mids = <TocAutofillMidUnit>[
    for (final big in tree) ...big.midUnits,
  ];
  final trailingRowName = tocAutofillRulesFor(series).trailingMidRowName;
  var completed = 0;
  final incomplete = <String>[];
  for (var midIndex = 0; midIndex < mids.length; midIndex += 1) {
    final mid = mids[midIndex];
    // 대단원 끝 전용 행(고쟁이 "대단원 TEST")은 본문 단계가 없다. 쪽 범위는
    // 워크북 훑기가 채우므로 여기서 미완료로 세면 안 된다.
    if (trailingRowName.isNotEmpty && mid.name == trailingRowName) continue;
    final start = mid.startPage;
    final end = mid.endPage;
    if (start == null || end == null || end < start) {
      incomplete.add('${mid.name}(본문 범위 없음)');
      continue;
    }
    onProgress?.call(
      '파트 경계 분석 중... (${midIndex + 1}/${mids.length}) ${mid.name}',
    );
    final classified = <TextbookRpmSectionPage>[];
    final allPages = <int>[for (var page = start; page <= end; page += 1) page];
    final safeBatchSize = batchSize.clamp(1, 24);
    for (var offset = 0; offset < allPages.length; offset += safeBatchSize) {
      final hi = (offset + safeBatchSize).clamp(0, allPages.length);
      classified.addAll(await classify(allPages.sublist(offset, hi)));
    }
    classified.sort((a, b) => a.rawPage.compareTo(b.rawPage));

    // 정확한 상단 머리말 플래그를 우선하고, 모델이 머리말 글자를 놓쳤을 때만
    // 단조로운 section 판정을 보조 신호로 사용한다.
    int? boundaryFor(String sectionCode) {
      for (final page in classified) {
        if (page.section == sectionCode && page.headerVisible) {
          return page.rawPage;
        }
      }
      for (final page in classified) {
        if (page.section == sectionCode) return page.rawPage;
      }
      return null;
    }

    // 첫 파트는 중단원 시작에서 열리고, 나머지는 자기 머리말에서 시작한다.
    final starts = <int>[start];
    final missing = <String>[];
    for (final part in parts.skip(1)) {
      final boundary = boundaryFor(part[1]);
      if (boundary == null) {
        missing.add(part[0]);
        continue;
      }
      starts.add(boundary);
    }
    // 경계가 하나라도 빠지거나 순서가 어긋나면 사람이 확인해야 한다.
    var monotonic = starts.length == parts.length && starts.last <= end;
    for (var i = 1; monotonic && i < starts.length; i += 1) {
      if (starts[i] <= starts[i - 1]) monotonic = false;
    }
    if (!monotonic) {
      final label = missing.isEmpty
          ? parts.skip(1).map((p) => p[0]).join('/')
          : missing.join('/');
      incomplete.add('${mid.name}($label 머리말 확인 실패)');
      continue;
    }

    mid.rpmPartRanges.clear();
    for (var i = 0; i < parts.length; i += 1) {
      mid.rpmPartRanges[parts[i][0]] = TocAutofillPageRange(
        startPage: starts[i],
        endPage: i + 1 < parts.length ? starts[i + 1] - 1 : end,
      );
    }
    completed += 1;
  }
  return ProblemBookPartAutofillReport(
    completedMids: completed,
    incompleteMids: incomplete,
  );
}

// ─────────── 고쟁이 워크북 쪽 범위 자동 채움 ───────────

typedef GojaengiWorkbookClassifier = Future<List<TextbookGojaengiWorkbookPage>>
    Function(List<int> rawPages);

class GojaengiWorkbookAutofillReport {
  const GojaengiWorkbookAutofillReport({
    required this.midTestCount,
    required this.bigTestCount,
    required this.unmatched,
  });

  /// 쪽 범위를 채운 중단원 TEST(E) 묶음 수.
  final int midTestCount;

  /// 쪽 범위를 채운 대단원 TEST(F) 묶음 수.
  final int bigTestCount;

  /// 머리말은 읽었지만 단원트리에서 짝을 못 찾은 묶음들.
  final List<String> unmatched;

  bool get isEmpty => midTestCount == 0 && bigTestCount == 0;
}

String _compactUnitName(String raw) =>
    stripTocUnitNumbering(raw).replaceAll(RegExp(r'\s+'), '');

/// 고쟁이 워크북 지면을 훑어 E(중단원 TEST)·F(대단원 TEST) 쪽 범위를 채운다.
///
/// 목차에는 워크북 두 묶음의 **시작 쪽 하나씩**만 인쇄돼 있어서, 어느 중단원의
/// TEST 가 몇 쪽부터 몇 쪽까지인지는 목차만으로 알 수 없다. 대신 워크북 지면은
/// 지면마다 머리에 배지와 단원 이름을 반복 인쇄하므로, 그 머리말을 읽어 같은
/// 묶음이 이어지는 구간을 묶으면 범위가 그대로 나온다.
///
/// [workbookStartPage]~[workbookEndPage] 는 PDF raw 쪽 범위다.
Future<GojaengiWorkbookAutofillReport> autofillGojaengiWorkbookRanges(
  List<TocAutofillBigUnit> tree, {
  required GojaengiWorkbookClassifier classify,
  required int workbookStartPage,
  required int workbookEndPage,
  void Function(String message)? onProgress,
  int batchSize = 12,
}) async {
  if (workbookEndPage < workbookStartPage) {
    return const GojaengiWorkbookAutofillReport(
      midTestCount: 0,
      bigTestCount: 0,
      unmatched: <String>[],
    );
  }
  final allPages = <int>[
    for (var page = workbookStartPage; page <= workbookEndPage; page += 1) page,
  ];
  final safeBatchSize = batchSize.clamp(1, 24);
  final classified = <TextbookGojaengiWorkbookPage>[];
  for (var offset = 0; offset < allPages.length; offset += safeBatchSize) {
    final hi = (offset + safeBatchSize).clamp(0, allPages.length);
    onProgress?.call(
      '워크북 묶음 분석 중... (${offset + 1}~$hi/${allPages.length}쪽)',
    );
    classified.addAll(await classify(allPages.sublist(offset, hi)));
  }
  classified.sort((a, b) => a.rawPage.compareTo(b.rawPage));

  // 워크북은 지면마다 머리말을 다시 인쇄하므로 머리말 없는 지면은 원래 없다.
  // 판독이 놓친 지면만 앞 묶음으로 이어 준다. 다만 **마지막 머리말 뒤쪽**은
  // 이어 주지 않는다 — 워크북이 교재 맨 뒤라 그 뒤로 오는 백지·부록까지
  // 마지막 대단원 TEST 범위로 빨려 들어간다.
  var lastHeaderPage = 0;
  for (final page in classified) {
    if (page.hasHeader) lastHeaderPage = page.rawPage;
  }
  final blocks =
      <({String corner, String name, int? number, int start, int end})>[];
  for (final page in classified) {
    if (page.rawPage > lastHeaderPage) break;
    if (page.hasHeader) {
      final name = _compactUnitName(page.unitName);
      final last = blocks.isEmpty ? null : blocks.last;
      if (last != null &&
          last.corner == page.corner &&
          last.name == name &&
          page.rawPage == last.end + 1) {
        blocks[blocks.length - 1] = (
          corner: last.corner,
          name: last.name,
          number: last.number ?? page.unitNumber,
          start: last.start,
          end: page.rawPage,
        );
        continue;
      }
      blocks.add((
        corner: page.corner,
        name: name,
        number: page.unitNumber,
        start: page.rawPage,
        end: page.rawPage,
      ));
      continue;
    }
    if (blocks.isEmpty) continue;
    final last = blocks.last;
    if (page.rawPage != last.end + 1) continue;
    blocks[blocks.length - 1] = (
      corner: last.corner,
      name: last.name,
      number: last.number,
      start: last.start,
      end: page.rawPage,
    );
  }

  final trailingRowName = tocAutofillRulesFor('gojaengi').trailingMidRowName;
  final realMids = <TocAutofillMidUnit>[
    for (final big in tree)
      for (final mid in big.midUnits)
        if (mid.name != trailingRowName) mid,
  ];
  final unmatched = <String>[];
  var midTestCount = 0;
  var bigTestCount = 0;

  for (final block in blocks) {
    final range = TocAutofillPageRange(
      startPage: block.start,
      endPage: block.end,
    );
    if (block.corner == 'mid_unit_test') {
      // 이름이 첫 단서다. 중등 고쟁이는 소단원 번호가 책 전체에서 1~10 으로
      // 이어지므로, 이름이 어긋날 때만 번호를 차례로 써서 되짚는다.
      TocAutofillMidUnit? target;
      for (final mid in realMids) {
        if (block.name.isNotEmpty && _compactUnitName(mid.name) == block.name) {
          target = mid;
          break;
        }
      }
      if (target == null && block.number != null) {
        final index = block.number! - 1;
        if (index >= 0 && index < realMids.length) target = realMids[index];
      }
      if (target == null) {
        unmatched.add('중단원 TEST ${block.name}(${block.start}~${block.end}쪽)');
        continue;
      }
      target.rpmPartRanges['E'] = range;
      midTestCount += 1;
      continue;
    }
    if (block.corner != 'big_unit_test') continue;
    TocAutofillBigUnit? bigTarget;
    for (final big in tree) {
      if (_compactUnitName(big.name) == block.name) {
        bigTarget = big;
        break;
      }
    }
    if (bigTarget == null && block.number != null) {
      final index = block.number! - 1;
      if (index >= 0 && index < tree.length) bigTarget = tree[index];
    }
    if (bigTarget == null) {
      unmatched.add('대단원 TEST ${block.name}(${block.start}~${block.end}쪽)');
      continue;
    }
    TocAutofillMidUnit? trailing;
    for (final mid in bigTarget.midUnits) {
      if (mid.name == trailingRowName) {
        trailing = mid;
        break;
      }
    }
    if (trailing == null) {
      trailing = TocAutofillMidUnit(name: trailingRowName);
      bigTarget.midUnits.add(trailing);
    }
    trailing
      ..startPage = block.start
      ..endPage = block.end;
    trailing.rpmPartRanges['F'] = range;
    bigTestCount += 1;
  }

  return GojaengiWorkbookAutofillReport(
    midTestCount: midTestCount,
    bigTestCount: bigTestCount,
    unmatched: unmatched,
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
