// Shared value object for the student-app "tap-to-identify" flow.
//
// We load `textbook_problem_crops` rows as plain maps from Supabase and
// normalise them into a small typed record that:
//   • carries the normalised 0..1000 item rect for rendering + hit-test,
//   • remembers whether it's a set-style header (48~52: "다음 물음에..."),
//   • knows its page and problem label, so tapping it can render a
//     `p23 · 47번` badge without any follow-up queries.
//
// Keeping this tiny + framework-agnostic so both the meta dialog and the
// PDF viewer can share it without dragging in widget dependencies.

import 'package:flutter/foundation.dart';

@immutable
class TextbookProblemRegion {
  const TextbookProblemRegion({
    required this.rawPage,
    this.displayPage,
    required this.problemNumber,
    this.label = '',
    this.section,
    this.isSetHeader = false,
    this.setFrom,
    this.setTo,
    this.columnIndex,
    required this.itemRegion1k,
    this.bbox1k,
    this.bigOrder,
    this.midOrder,
    this.subKey,
    this.bigName,
    this.midName,
  });

  final int rawPage;
  final int? displayPage;
  final String problemNumber;
  final String label;
  final String? section;
  final bool isSetHeader;
  final int? setFrom;
  final int? setTo;
  final int? columnIndex;

  /// [ymin, xmin, ymax, xmax] normalised to the 0..1000 range of the
  /// source page image (same convention the VLM produces).
  final List<int> itemRegion1k;

  /// The VLM's original problem-number bbox, useful if we later want to
  /// highlight just the number rather than the whole region.
  final List<int>? bbox1k;

  final int? bigOrder;
  final int? midOrder;
  final String? subKey;
  final String? bigName;
  final String? midName;

  double get xminFraction => (itemRegion1k[1] / 1000.0).clamp(0.0, 1.0);
  double get yminFraction => (itemRegion1k[0] / 1000.0).clamp(0.0, 1.0);
  double get xmaxFraction => (itemRegion1k[3] / 1000.0).clamp(0.0, 1.0);
  double get ymaxFraction => (itemRegion1k[2] / 1000.0).clamp(0.0, 1.0);

  /// Human-readable badge, e.g. `p23 · 47번` or `p23 · 48~52 세트`.
  String badgeLabel({bool preferDisplayPage = true}) {
    final page = preferDisplayPage && displayPage != null && displayPage! > 0
        ? displayPage!
        : rawPage;
    final num = isSetHeader && setFrom != null && setTo != null
        ? '$setFrom~$setTo 세트'
        : '$problemNumber번';
    return 'p$page · $num';
  }

  static TextbookProblemRegion? fromRow(Map<String, dynamic> row) {
    final rawPage = _asInt(row['raw_page']);
    final number = (row['problem_number'] ?? '').toString().trim();
    final region = _asIntList(row['item_region_1k']);
    if (rawPage == null || rawPage <= 0 || number.isEmpty) return null;
    if (region == null || region.length != 4) return null;
    return TextbookProblemRegion(
      rawPage: rawPage,
      displayPage: _asInt(row['display_page']),
      problemNumber: number,
      label: (row['label'] ?? '').toString(),
      section: (row['section'] as String?)?.trim().isEmpty == true
          ? null
          : (row['section'] as String?)?.trim(),
      isSetHeader: row['is_set_header'] == true,
      setFrom: _asInt(row['set_from']),
      setTo: _asInt(row['set_to']),
      columnIndex: _asInt(row['column_index']),
      itemRegion1k: region,
      bbox1k: _asIntList(row['bbox_1k']),
      bigOrder: _asInt(row['big_order']),
      midOrder: _asInt(row['mid_order']),
      subKey: (row['sub_key'] as String?)?.trim().toUpperCase(),
      bigName: (row['big_name'] as String?)?.trim(),
      midName: (row['mid_name'] as String?)?.trim(),
    );
  }
}

int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

List<int>? _asIntList(dynamic v) {
  if (v is! List) return null;
  final out = <int>[];
  for (final e in v) {
    final n = _asInt(e);
    if (n == null) return null;
    out.add(n);
  }
  return out;
}
