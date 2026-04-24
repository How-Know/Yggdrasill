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
];

TextbookSeriesCatalogEntry? textbookSeriesByKey(String key) {
  final trimmed = key.trim().toLowerCase();
  if (trimmed.isEmpty) return null;
  for (final entry in kTextbookSeriesCatalog) {
    if (entry.key.toLowerCase() == trimmed) return entry;
  }
  return null;
}
