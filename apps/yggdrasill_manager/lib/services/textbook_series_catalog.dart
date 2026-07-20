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
  });

  final String key;
  final String displayName;
  final List<TextbookSubSectionPreset> subPreset;
  final String defaultTextbookType;
  final String notes;
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
];

TextbookSeriesCatalogEntry? textbookSeriesByKey(String key) {
  final trimmed = key.trim().toLowerCase();
  if (trimmed.isEmpty) return null;
  for (final entry in kTextbookSeriesCatalog) {
    if (entry.key.toLowerCase() == trimmed) return entry;
  }
  return null;
}
