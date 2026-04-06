/// Parse and compress homework `page` fields (e.g. `90-91, 92`, `p.10`).

/// Expands [raw] into a set of positive page integers (comma lists, `a-b` ranges, `p.` prefix).
Set<int> parseHomeworkPageNumbers(String raw) {
  final cleaned = raw.trim();
  if (cleaned.isEmpty) return <int>{};
  var normalized = cleaned
      .replaceAll(RegExp(r'p\.', caseSensitive: false), '')
      .replaceAll('페이지', '')
      .replaceAll('쪽', '')
      .replaceAll('~', '-')
      .replaceAll('–', '-')
      .replaceAll('—', '-');
  normalized = normalized.replaceAll(RegExp(r'[^0-9,\-]+'), ',');
  normalized = normalized.replaceAll(RegExp(r',+'), ',');
  normalized = normalized.replaceAll(RegExp(r'^,+|,+$'), '');
  if (normalized.isEmpty) return <int>{};
  final out = <int>{};
  for (final token in normalized.split(',')) {
    final t = token.trim();
    if (t.isEmpty) continue;
    if (t.contains('-')) {
      final parts = t.split('-');
      if (parts.length != 2) continue;
      final start = int.tryParse(parts[0]);
      final end = int.tryParse(parts[1]);
      if (start == null || end == null) continue;
      var a = start;
      var b = end;
      if (a > b) {
        final temp = a;
        a = b;
        b = temp;
      }
      for (int p = a; p <= b; p++) {
        if (p > 0) out.add(p);
      }
      continue;
    }
    final value = int.tryParse(t);
    if (value != null && value > 0) out.add(value);
  }
  return out;
}

/// Compresses sorted unique pages into `90-94` or `10-12, 20` style (no `p.` prefix).
String compressHomeworkPageNumbers(Set<int> pages) {
  if (pages.isEmpty) return '';
  final sorted = pages.toList()..sort();
  final out = <String>[];
  int start = sorted.first;
  int prev = sorted.first;
  for (int i = 1; i < sorted.length; i++) {
    final value = sorted[i];
    if (value == prev + 1) {
      prev = value;
      continue;
    }
    out.add(start == prev ? '$start' : '$start-$prev');
    start = value;
    prev = value;
  }
  out.add(start == prev ? '$start' : '$start-$prev');
  return out.join(',');
}

/// Union of all parsed pages from [raws], then [compressHomeworkPageNumbers].
String mergeHomeworkPageRawStrings(Iterable<String?> raws) {
  final pages = <int>{};
  for (final raw in raws) {
    pages.addAll(parseHomeworkPageNumbers(raw ?? ''));
  }
  return compressHomeworkPageNumbers(pages);
}
