class TextbookProblemSourceOrderKey {
  const TextbookProblemSourceOrderKey({
    this.bigOrder = 0,
    this.midOrder = 0,
    this.subIndex = 0,
    this.subKey = '',
    this.page = 0,
    this.problemNumber = '',
    this.columnIndex = 0,
    this.ymin = double.infinity,
    this.xmin = double.infinity,
    this.stableId = '',
  });

  final int bigOrder;
  final int midOrder;
  final int subIndex;
  final String subKey;
  final int page;
  final String problemNumber;
  final int columnIndex;
  final double ymin;
  final double xmin;
  final String stableId;
}

int compareTextbookProblemSourceOrder(
  TextbookProblemSourceOrderKey a,
  TextbookProblemSourceOrderKey b,
) {
  var compared = a.bigOrder.compareTo(b.bigOrder);
  if (compared != 0) return compared;
  compared = a.midOrder.compareTo(b.midOrder);
  if (compared != 0) return compared;
  compared = _compareSubKey(a.subKey, b.subKey);
  if (compared != 0) return compared;
  compared = a.subIndex.compareTo(b.subIndex);
  if (compared != 0) return compared;
  compared = a.page.compareTo(b.page);
  if (compared != 0) return compared;
  compared = compareTextbookProblemNumbers(
    a.problemNumber,
    b.problemNumber,
  );
  if (compared != 0) return compared;
  compared = a.columnIndex.compareTo(b.columnIndex);
  if (compared != 0) return compared;
  compared = a.ymin.compareTo(b.ymin);
  if (compared != 0) return compared;
  compared = a.xmin.compareTo(b.xmin);
  if (compared != 0) return compared;
  return a.stableId.compareTo(b.stableId);
}

int compareTextbookProblemNumbers(String a, String b) {
  final aParts = _naturalParts(a);
  final bParts = _naturalParts(b);
  final length = aParts.length < bParts.length ? aParts.length : bParts.length;
  for (var i = 0; i < length; i++) {
    final left = aParts[i];
    final right = bParts[i];
    final leftNumber = int.tryParse(left);
    final rightNumber = int.tryParse(right);
    int compared;
    if (leftNumber != null && rightNumber != null) {
      compared = leftNumber.compareTo(rightNumber);
    } else {
      compared = left.toLowerCase().compareTo(right.toLowerCase());
    }
    if (compared != 0) return compared;
  }
  return aParts.length.compareTo(bParts.length);
}

int _compareSubKey(String a, String b) {
  int rank(String value) {
    final normalized = value.trim().toUpperCase();
    if (normalized.length == 1) {
      final code = normalized.codeUnitAt(0);
      if (code >= 65 && code <= 90) return code - 65;
    }
    return 1000;
  }

  final compared = rank(a).compareTo(rank(b));
  if (compared != 0) return compared;
  return a.trim().compareTo(b.trim());
}

List<String> _naturalParts(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return const <String>[''];
  return RegExp(r'\d+|\D+')
      .allMatches(normalized)
      .map((match) => match.group(0)!)
      .toList(growable: false);
}
