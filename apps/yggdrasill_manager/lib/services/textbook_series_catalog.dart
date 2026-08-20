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
    notes:
        '한 중단원은 A(기본다잡기) / B(유형뽀개기) / C(만점도전하기)로 고정됩니다. '
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
    notes:
        '한 중단원은 A(교과서문제 정복하기) / B(유형 익히기) / C(시험에 꼭 나오는 문제)로 고정됩니다. '
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
    notes:
        '개념원리는 대단원 - 중단원 - 소단원 구조로 입력합니다 (번호 제외). '
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
    notes:
        '개념+유형은 대단원 - 중단원 - 소단원 구조로 입력합니다 (번호 제외). '
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
    notes:
        '수력충전은 대단원 - 중단원 - 소단원 구조로 입력합니다 (번호 제외). '
        '페이지는 소단원별로만 입력하며, 중단원 끝의 "단원 마무리 평가"도 소단원 '
        '한 행으로 넣습니다. 유형명과 개념 체크는 VLM이 지면 안에서 자동으로 '
        '가려냅니다.',
    subPreset: <TextbookSubSectionPreset>[
      TextbookSubSectionPreset(key: 'A', displayName: '유형 문제'),
      TextbookSubSectionPreset(key: 'B', displayName: '단원 마무리 평가'),
    ],
  ),
];

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
