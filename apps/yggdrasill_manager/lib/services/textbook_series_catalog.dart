// Catalog of textbook "series" known to the manager app.
//
// Each entry drives the 책 추가 wizard and the 단원 편집 dialog:
//   - [key]         is the stable identifier stored in textbook_metadata.payload.
//   - [displayName] is shown in the dropdown (e.g. "쎈").
//   - [subPreset]   is the canonical ordered list of 소단원 slots for a 중단원.
//                   쎈 always produces three slots (A/B/C). Concept-only books
//                   can be added later with a single-entry preset.
//   - [defaultTextbookType] mirrors the legacy "개념서 | 문제집" dropdown so the
//                   wizard can preselect the right value.
//
// Keep this file free of imports beyond `material` so it stays cheap to load
// from both widgets (dropdowns) and background services (payload building).

import 'package:flutter/foundation.dart';

@immutable
class TextbookSubSectionPreset {
  const TextbookSubSectionPreset({
    required this.key,
    required this.displayName,
    this.defaultStartPage,
    this.defaultEndPage,
  });

  /// Canonical short key stored in `textbook_problem_crops.sub_key` and in
  /// `payload.units[].middles[].smalls[].sub_key`.
  final String key;

  /// Full human-readable name. 쎈's "A 기본다잡기" lives here, not in `key`.
  final String displayName;

  final int? defaultStartPage;
  final int? defaultEndPage;

  @override
  String toString() => '$key $displayName';
}

@immutable
class TextbookSeriesCatalogEntry {
  const TextbookSeriesCatalogEntry({
    required this.key,
    required this.displayName,
    required this.subPreset,
    this.defaultTextbookType = '문제집',
    this.notes = '',
    this.hasSubUnitRows = false,
    this.unitEndRowName = '연습문제',
    this.unitEndSlotKeys = const <String>{},
    this.trailingMidRowName = '',
    this.trailingMidSlotKeys = const <String>{},
    this.supportsProblemExtraction = true,
  });

  final String key;
  final String displayName;
  final List<TextbookSubSectionPreset> subPreset;
  final String defaultTextbookType;
  final String notes;

  /// 개념서처럼 중단원 아래에 책의 실제 소단원 행(이름 + 페이지)을 두는지 여부.
  /// true 면 [subPreset] 은 단원이 아니라 문제 카테고리 슬롯이고, 슬롯의 페이지
  /// 범위는 사용자가 입력한 소단원 행에서 자동 유도된다.
  final bool hasSubUnitRows;

  /// 중단원 끝에 붙는 마무리 문제 묶음 행의 이름.
  /// 개념원리는 "연습문제", 개념+유형은 "단원 다지기".
  final String unitEndRowName;

  /// 마무리 행의 페이지 범위에서 유도되는 슬롯 키. 나머지 슬롯은 일반 소단원
  /// 행 전체 범위를 쓴다.
  final Set<String> unitEndSlotKeys;

  /// 대단원 끝에 덧붙는 전용 중단원 행의 이름. 빈 문자열이면 없다.
  ///
  /// 고쟁이 워크북 "대단원 TEST" 처럼 대단원 하나를 통틀어 다루는 코너용이다.
  /// 어느 중단원에도 매달 자리가 없어서 대단원마다 이 이름의 중단원 행을 하나
  /// 만들고, 그 행은 [trailingMidSlotKeys] 슬롯만 갖는다.
  final String trailingMidRowName;

  /// [trailingMidRowName] 행이 갖는 슬롯 키. 나머지 중단원은 이 키들을 뺀
  /// [subPreset] 을 쓴다.
  final Set<String> trailingMidSlotKeys;

  /// 이 중단원 이름이 대단원 끝 전용 행인지.
  bool isTrailingMidRow(String midName) =>
      trailingMidRowName.isNotEmpty && midName.trim() == trailingMidRowName;

  /// 이 중단원이 실제로 가져야 할 슬롯 목록.
  List<TextbookSubSectionPreset> slotsForMid(String midName) {
    if (trailingMidSlotKeys.isEmpty) return subPreset;
    final trailing = isTrailingMidRow(midName);
    return <TextbookSubSectionPreset>[
      for (final preset in subPreset)
        if (trailingMidSlotKeys.contains(preset.key) == trailing) preset,
    ];
  }

  /// 문항 추출(VLM 분석 → 크롭 저장)까지 지원하는지. false 면 목차·단원 구조
  /// 입력까지만 열어 두고 분석 실행을 막는다.
  final bool supportsProblemExtraction;
}

/// Single source of truth for the series dropdown. Extending this list adds
/// a new option everywhere the catalog is used — the wizard, the unit
/// authoring dialog, and the payload validator in the manager app.
const List<TextbookSeriesCatalogEntry> kTextbookSeriesCatalog =
    <TextbookSeriesCatalogEntry>[
  TextbookSeriesCatalogEntry(
    key: 'ssen',
    displayName: '쎈',
    defaultTextbookType: '문제집',
    notes: '한 중단원은 A(기본다잡기) / B(유형뽀개기) / C(만점도전하기)로 고정됩니다. '
        'C 후반부에는 서술형 섹션이 포함될 수 있습니다.',
    subPreset: <TextbookSubSectionPreset>[
      TextbookSubSectionPreset(key: 'A', displayName: 'A 기본다잡기'),
      TextbookSubSectionPreset(key: 'B', displayName: 'B 유형뽀개기'),
      TextbookSubSectionPreset(key: 'C', displayName: 'C 만점도전하기'),
    ],
  ),
  // 쎈과 구조가 거의 동일한 쌍둥이 교재. A/B/C 파트 이름만 다르고
  // 난이도 라벨에 상중/중하/중요가 추가된다. C 마지막 페이지는
  // 왼쪽단 '서술형 주관식'(→서술형) / 오른쪽단 '실력 UP'(→실력) 구성.
  TextbookSeriesCatalogEntry(
    key: 'rpm',
    displayName: 'RPM',
    defaultTextbookType: '문제집',
    notes: '한 중단원은 A(교과서문제 정복하기) / B(유형 익히기) / C(시험에 꼭 나오는 문제)로 고정됩니다. '
        'C 마지막에는 서술형 주관식 / 실력 UP 섹션이 포함될 수 있습니다.',
    subPreset: <TextbookSubSectionPreset>[
      TextbookSubSectionPreset(key: 'A', displayName: 'A 교과서문제 정복하기'),
      TextbookSubSectionPreset(key: 'B', displayName: 'B 유형 익히기'),
      TextbookSubSectionPreset(key: 'C', displayName: 'C 시험에 꼭 나오는 문제'),
    ],
  ),
  // 개념원리 개념서. 트리는 책의 대-중-소단원 3계층을 그대로 따른다 (번호 제거):
  //   대단원 = 책 대단원 (예: "다항식" — "I." 로마숫자 제거)
  //   중단원 = 책 중단원 (예: "다항식의 연산" — "1." 숫자 제거)
  //   소단원 = 책 소단원 (예: "다항식의 덧셈과 뺄셈" — "01" 번호 제거)
  //   "연습문제" 항목은 중단원 끝의 소단원 행으로 들어간다.
  // 페이지는 소단원 행에만 입력하며, 아래 A~D는 단원이 아니라 문제 카테고리
  // 슬롯이다 — 페이지 범위는 소단원 입력에서 자동 유도되고(A/B/C = 일반
  // 소단원 전체 범위, D = 연습문제 행 범위), VLM이 페이지 안에서 카테고리를
  // 분류한다. 문항 번호가 카테고리별 책 전체 연속 번호라 슬롯을 나눠야
  // 번호 충돌 없이 정답/추출 매칭이 된다.
  TextbookSeriesCatalogEntry(
    key: 'wonri',
    displayName: '개념원리',
    defaultTextbookType: '개념서',
    hasSubUnitRows: true,
    unitEndRowName: '연습문제',
    unitEndSlotKeys: <String>{'D'},
    notes: '개념원리는 대단원 - 중단원 - 소단원 구조로 입력합니다 (번호 제외). '
        '페이지는 소단원별로만 입력하며, 개념원리 익히기 / 필수유형 / 확인 체크 / 연습문제 '
        '분류는 VLM이 해당 페이지 안에서 자동으로 나눕니다.',
    subPreset: <TextbookSubSectionPreset>[
      TextbookSubSectionPreset(key: 'A', displayName: '개념원리 익히기'),
      TextbookSubSectionPreset(key: 'B', displayName: '필수유형'),
      TextbookSubSectionPreset(key: 'C', displayName: '확인 체크'),
      TextbookSubSectionPreset(key: 'D', displayName: '연습문제'),
      // 특강(sub_key 'E')은 payload 슬롯이 아니라 크롭 저장 전용 카테고리다.
      // 필수유형과 같은 지면 구성이지만 번호가 01부터 새로 시작해 B와 분리
      // 저장한다. 슬롯으로 넣으면 특강이 없는 중단원까지 미완료로 집계되므로
      // 여기(payload)에는 두지 않는다.
    ],
  ),
  // 중등 개념원리. 고등판과 이름만 같고 지면·번호·해설 구조가 다르므로
  // 반드시 별도 series key 로 보존한다.
  //
  // 인쇄 목차에는 대단원/중단원과 중단원 시작 쪽만 나오며, 실제 소단원은
  // 본문 머리말을 훑어 보완한다. 일반 소단원은 A~C, 중단원 말미 행은 D/E를
  // 사용한다. "계산력 강화하기"(F)는 일부 소단원에만 불규칙하게 나타나므로
  // payload 고정 슬롯으로 만들지 않고 탐지된 크롭에서만 동적으로 노출한다.
  TextbookSeriesCatalogEntry(
    key: 'wonri_middle',
    displayName: '개념원리 중등',
    defaultTextbookType: '개념서',
    hasSubUnitRows: true,
    unitEndRowName: '중단원 마무리하기',
    unitEndSlotKeys: <String>{'D', 'E'},
    notes: '중등 개념원리는 목차의 대단원/중단원을 먼저 읽고 본문 머리말에서 '
        '소단원을 보완합니다. 확인하기 / 핵심문제 / 시험문제 / 중단원 마무리 / '
        '서술형은 VLM이 자동 분류하며, 계산력 강화하기는 실제 등장한 소단원에만 '
        '선택 영역으로 저장합니다. 정답은 별도 빠른 정답 PDF 없이 해설 PDF에서 '
        '풀이 좌표와 함께 추출합니다.',
    subPreset: <TextbookSubSectionPreset>[
      TextbookSubSectionPreset(key: 'A', displayName: '개념원리 확인하기'),
      TextbookSubSectionPreset(key: 'B', displayName: '핵심문제 익히기'),
      TextbookSubSectionPreset(key: 'C', displayName: '이런 문제가 시험에 나온다'),
      TextbookSubSectionPreset(key: 'D', displayName: '중단원 마무리하기'),
      TextbookSubSectionPreset(key: 'E', displayName: '서술형 대비 문제'),
    ],
  ),
  // 개념+유형(개념플러스유형) 개념서. 개념원리와 같은 대-중-소 3계층이지만
  // 지면 구성이 다르다:
  //   - 개념 전용 페이지가 없다. 한 페이지에 개념확인과 필수 문제가 같이 있고,
  //     필수 문제 아래에 "7-1", "7-2" 처럼 번호가 붙는 따름 문제가 이어진다.
  //   - 소단원이 끝나면 반드시 "쏙쏙 개념 익히기"가 나오고, 그 앞에 자기 지면을
  //     가진 "한 번 더 연습"이 불규칙하게 붙을 수 있다. 둘 다 번호가 1부터
  //     시작하므로 한 번 더 연습은 전용 슬롯 'F'에 따로 담는다.
  //   - 중단원 끝에는 탄탄 단원 다지기 → 쓱쓱 서술형 완성하기 → 개념 리뷰 →
  //     마인드맵 순으로 이어진다. 목차에는 이 넷이 "단원 다지기 / 서술형
  //     완성하기", "개념 리뷰 / 마인드맵" 두 줄로 인쇄되는데, 하나의 "단원
  //     다지기" 소단원 행으로 합쳐서 다룬다 (개념 리뷰·마인드맵은 문항 없음).
  TextbookSeriesCatalogEntry(
    key: 'gaeyu',
    displayName: '개념+유형',
    defaultTextbookType: '개념서',
    hasSubUnitRows: true,
    unitEndRowName: '단원 다지기',
    unitEndSlotKeys: <String>{'D', 'E'},
    supportsProblemExtraction: true,
    notes: '개념+유형은 대단원 - 중단원 - 소단원 구조로 입력합니다 (번호 제외). '
        '페이지는 소단원별로만 입력하며, 개념확인 / 필수 문제 / 쏙쏙 개념 익히기 '
        '분류는 VLM이 해당 페이지 안에서 자동으로 나눕니다. 중단원 끝의 '
        '단원 다지기 / 서술형 완성하기 / 개념 리뷰 / 마인드맵은 "단원 다지기" '
        '소단원 한 행으로 합쳐 입력합니다.',
    subPreset: <TextbookSubSectionPreset>[
      TextbookSubSectionPreset(key: 'A', displayName: '개념확인'),
      TextbookSubSectionPreset(key: 'B', displayName: '필수 문제'),
      TextbookSubSectionPreset(key: 'C', displayName: '쏙쏙 개념 익히기'),
      TextbookSubSectionPreset(key: 'D', displayName: '탄탄 단원 다지기'),
      TextbookSubSectionPreset(key: 'E', displayName: '쓱쓱 서술형 완성하기'),
      // 한 번 더 연습(sub_key 'F')은 개념원리 특강과 같은 이유로 payload 슬롯이
      // 아니다. 소단원마다 있는 코너가 아니라서 슬롯으로 두면 한 번 더 연습이
      // 없는 소단원까지 미완료로 집계된다. 크롭 저장 전용 카테고리로만 쓴다.
    ],
  ),
  // 수력충전 문제집. 개념서처럼 대-중-소단원 3계층 트리를 쓰지만 소단원이 아주
  // 잘게 쪼개져 있다 (대수 기준 대단원 하나에 40~50개).
  //   - 소단원 번호("01 거듭제곱과 지수법칙")와 유형 번호("유형 01")는 대단원마다
  //     1로 돌아가고, 그 안에서는 중단원을 넘어 계속 이어진다.
  //   - 중단원 끝의 "단원 마무리 평가"도 소단원 한 행으로 들어간다.
  //   - 문항 번호는 소단원 행마다 01부터 다시 시작한다. 쎈처럼 "[01-05]" 세트
  //     지문이 붙고 2단으로 조판된다.
  //   - 개념 체크(둥근 사각형 배지가 붙은 빈칸 채우기)는 그 소단원 번호열을
  //     그대로 이어받는다. 지면 마지막 문항으로 불규칙하게 나타난다.
  //   - 난이도 표기는 없다. 단원 마무리 평가에는 계산 조심 / 생각 더하기 /
  //     조건 확인 배지가, 마지막 대단원 실력 향상 테스트에는 시험에 꼭! /
  //     도전해 얍! 만 붙는다.
  TextbookSeriesCatalogEntry(
    key: 'suryeok',
    displayName: '수력충전',
    defaultTextbookType: '문제집',
    hasSubUnitRows: true,
    unitEndRowName: '단원 마무리 평가',
    unitEndSlotKeys: <String>{'B'},
    notes: '수력충전은 대단원 - 중단원 - 소단원 구조로 입력합니다 (번호 제외). '
        '페이지는 소단원별로만 입력하며, 중단원 끝의 "단원 마무리 평가"도 소단원 '
        '한 행으로 넣습니다. 유형명과 개념 체크는 VLM이 지면 안에서 자동으로 '
        '가려냅니다.',
    subPreset: <TextbookSubSectionPreset>[
      TextbookSubSectionPreset(key: 'A', displayName: '유형 문제'),
      TextbookSubSectionPreset(key: 'B', displayName: '단원 마무리 평가'),
    ],
  ),
  // 고쟁이 문제집. 쎈처럼 대-중단원 아래에 고정 슬롯을 두는데, 단계가 셋이
  // 아니라 넷이고 워크북이 따로 붙어 여섯 칸을 쓴다.
  //   - 중단원 = 목차의 소단원("02 삼각형의 외심과 내심"). 중등은 번호가 책
  //     전체에서 1~10 으로 이어지고, 고등은 대단원마다 01 로 되돌아간다.
  //   - 중단원 첫 지면은 개념 정리, STEP2 앞 한두 지면은 대표 문항 + 스키마
  //     해설이다. 둘 다 문항이 없는 개념 지면으로만 기록한다.
  //   - 문항 번호는 본문 전체를 관통하는 세 자리 연속 번호다(054 → 634).
  //     워크북은 묶음마다 01 부터 다시 시작한다.
  //   - 별표(*)가 붙은 문항이 그 단계 안에서 더 어렵다 → label "상".
  //   - 대단원 TEST 는 대단원 하나를 통틀어 다루므로 어느 중단원에도 매달 자리가
  //     없다. 대단원마다 끝에 "대단원 TEST" 중단원 행을 하나 만들고 그 행은
  //     F 슬롯만 갖는다.
  TextbookSeriesCatalogEntry(
    key: 'gojaengi',
    displayName: '고쟁이',
    defaultTextbookType: '문제집',
    trailingMidRowName: '대단원 TEST',
    trailingMidSlotKeys: <String>{'F'},
    notes: '한 중단원은 A(STEP1 핵심 유형) / B(STEP2 심화 유형) / C(STEP3 최고난도 유형) / '
        '창의융합 유형 / 중단원 TEST로 고정됩니다. 단계별 쪽 범위는 지면의 '
        'Step 머리말을 읽어 자동으로 나눕니다. 워크북의 대단원 TEST는 대단원 끝에 '
        '"대단원 TEST" 중단원 행을 하나 만들어 담습니다.',
    subPreset: <TextbookSubSectionPreset>[
      TextbookSubSectionPreset(key: 'A', displayName: 'A STEP1 핵심 유형'),
      TextbookSubSectionPreset(key: 'B', displayName: 'B STEP2 심화 유형'),
      TextbookSubSectionPreset(key: 'C', displayName: 'C STEP3 최고난도 유형'),
      // D·E 는 책에 인쇄된 단계 글자가 없는 코너라 슬롯 글자를 붙이지 않는다.
      TextbookSubSectionPreset(key: 'D', displayName: '창의융합 유형'),
      TextbookSubSectionPreset(key: 'E', displayName: '중단원 TEST'),
      TextbookSubSectionPreset(key: 'F', displayName: '대단원 TEST'),
    ],
  ),
];

// 고쟁이 문항 번호 규칙.
//
//   A~D 본문   책 전체를 관통하는 세 자리 연속 번호("054" … "634"). 단계가
//              바뀌어도 이어지고 중단원이 바뀌어도 이어진다. 번호 하나로
//              정답·해설이 유일하게 짚이므로 접두어를 붙이지 않는다.
//   E 중단원 TEST  묶음마다 01 부터. 본문 번호와 겹치므로 슬롯으로 갈라 둔다.
//   F 대단원 TEST  묶음마다 01 부터.
//
// 정답 파일(빠른 정답)은 중단원 아래 "Step 1 · 본교재 037~039쪽" 처럼 단계별
// 본문 쪽 배지를 달고 번호를 나열하고, 워크북은 "워크북 166~169쪽" 배지를 쓴다.
// 해설 파일은 본문 유형 머리말("핵심 05 …")과 문항별 답 배지를 함께 싣는데
// 본문 쪽 배지가 없으므로, 본문은 세 자리 번호로만 매칭한다.

// 수력충전 문항 번호 규칙.
//
//   A 유형 문제  소단원 행마다 01부터. 개념 체크도 같은 번호열을 이어받으므로
//                번호로는 구분하지 않고 유형명("개념 체크")으로만 갈라 둔다.
//   B 단원 마무리 평가  행마다 01부터.
//
// 정답 파일(빠른 정답)과 해설 파일 모두 소단원 블록("01 거듭제곱과 지수법칙
// ▶p.10~11") 안에 번호별로 나열하는 구조라, 소단원 행 + 인쇄 번호가 그대로
// 매칭 키가 된다. 시리즈 전체에 걸친 연속 번호가 없어 페이지 접두어는 쓰지 않는다.

// 개념+유형 문항 번호 규칙.
//
// 정답 파일(스피드 체크)이 본문 페이지 배지("P. 8")로 블록을 묶고 그 안에
// 카테고리별로 답을 나열하는 구조라, 아래 규칙대로 붙인 번호가 정답·해설
// 추출 단계의 매칭 키가 된다.
//
//   A 개념확인            번호가 없다 → "개념확인8" 처럼 본문 인쇄 페이지를 붙인다
//   B 필수 문제·따름 문제  소단원마다 리셋. "7", "7-1", "7-2"
//   C 쏙쏙 개념 익히기     소단원마다 리셋. "한 번 더 +1" 배지는 같은 번호를 잇는다
//   D 탄탄 단원 다지기     중단원마다 리셋
//   E 쓱쓱 서술형 완성하기 중단원마다 리셋. 예제·유제·연습해 보자가 모두 1번부터
//                          시작하므로 "예제1" / "유제1" / "연습1" 로 접두어를 붙인다
//   F 한 번 더 연습        소단원마다 리셋
//
// 정답 출처는 E의 예제만 본문(개념원리 필수유형과 같은 방식)이고 나머지는 모두
// 정답·해설 파일이다. 개념확인은 정답만 있고 상세 해설이 없다.

TextbookSeriesCatalogEntry? textbookSeriesByKey(String key) {
  final trimmed = key.trim().toLowerCase();
  if (trimmed.isEmpty) return null;
  for (final entry in kTextbookSeriesCatalog) {
    if (entry.key.toLowerCase() == trimmed) return entry;
  }
  return null;
}
