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

int? _positiveIntFromDynamic(dynamic value) {
  if (value == null) return null;
  if (value is int) return value > 0 ? value : null;
  if (value is num) {
    final n = value.toInt();
    return n > 0 ? n : null;
  }
  final parsed = int.tryParse('$value'.trim());
  if (parsed == null || parsed <= 0) return null;
  return parsed;
}

/// 과제 표시 페이지 집합.
///
/// [page] 텍스트가 비어 있어도 `unitMappings.pageCounts` / 문항 crop /
/// start~end 로 페이지를 복원한다. (개념원리처럼 하위과제 page 를 비운 경우)
Set<int> homeworkItemDisplayPages({
  String? page,
  List<Map<String, dynamic>>? unitMappings,
}) {
  final out = <int>{...parseHomeworkPageNumbers(page ?? '')};
  if (unitMappings == null || unitMappings.isEmpty) return out;

  void addPage(dynamic raw) {
    final pageNum = _positiveIntFromDynamic(raw);
    if (pageNum != null) out.add(pageNum);
  }

  for (final raw in unitMappings) {
    final mapping = Map<String, dynamic>.from(raw);
    final pageCounts = mapping['pageCounts'] ?? mapping['page_counts'];
    if (pageCounts is Map) {
      for (final key in pageCounts.keys) {
        addPage(key);
      }
    }
    final start = _positiveIntFromDynamic(
      mapping['startPage'] ?? mapping['start_page'],
    );
    final end = _positiveIntFromDynamic(
      mapping['endPage'] ?? mapping['end_page'],
    );
    if (start != null && end != null) {
      final lo = start <= end ? start : end;
      final hi = start <= end ? end : start;
      for (var p = lo; p <= hi; p++) {
        out.add(p);
      }
    }
    final crops = mapping['problemCrops'] ?? mapping['problem_crops'];
    if (crops is! List) continue;
    for (final crop in crops) {
      if (crop is! Map) continue;
      addPage(
        crop['displayPage'] ??
            crop['display_page'] ??
            crop['rawPage'] ??
            crop['raw_page'],
      );
    }
  }
  return out;
}

/// 단일 과제의 압축 페이지 문자열 (`90-94` / `10-12,20`).
String homeworkItemPageRangeText({
  String? page,
  List<Map<String, dynamic>>? unitMappings,
}) {
  return compressHomeworkPageNumbers(
    homeworkItemDisplayPages(page: page, unitMappings: unitMappings),
  );
}

/// 여러 과제(그룹 하위)의 페이지 합집합을 압축한다.
String mergeHomeworkItemPageRanges(
  Iterable<({String? page, List<Map<String, dynamic>>? unitMappings})> items,
) {
  final pages = <int>{};
  for (final item in items) {
    pages.addAll(
      homeworkItemDisplayPages(
        page: item.page,
        unitMappings: item.unitMappings,
      ),
    );
  }
  return compressHomeworkPageNumbers(pages);
}

/// 과제 문항수.
///
/// `homework_items.count`가 비어 있어도 `unitMappings.pageCounts` /
/// `problemCrops`로부터 복원한다. (개념원리·프리셋 과제 등)
int homeworkItemProblemCount({
  int? count,
  List<Map<String, dynamic>>? unitMappings,
}) {
  if (count != null && count > 0) return count;
  if (unitMappings == null || unitMappings.isEmpty) return 0;

  var fromPageCounts = 0;
  var fromCrops = 0;
  for (final raw in unitMappings) {
    final mapping = Map<String, dynamic>.from(raw);
    final pageCounts = mapping['pageCounts'] ?? mapping['page_counts'];
    if (pageCounts is Map) {
      for (final value in pageCounts.values) {
        final n = _positiveIntFromDynamic(value) ?? 0;
        fromPageCounts += n;
      }
    }
    final crops = mapping['problemCrops'] ?? mapping['problem_crops'];
    if (crops is List) {
      fromCrops += crops.length;
    }
  }
  if (fromPageCounts > 0) return fromPageCounts;
  return fromCrops;
}
