String canonicalNaesinSchoolName(
  String raw, {
  required Iterable<String> canonicalSchools,
}) {
  final compact = raw.replaceAll(RegExp(r'\s+'), '').trim();
  if (compact.isEmpty) return '';
  final schools = canonicalSchools
      .map((school) => school.replaceAll(RegExp(r'\s+'), '').trim())
      .where((school) => school.isNotEmpty)
      .toList(growable: false);
  for (final school in schools) {
    if (compact == school) return school;
  }
  final rewritten = _rewriteNaesinSchoolSuffix(compact);
  for (final school in schools) {
    if (rewritten == school) return school;
  }
  String? best;
  for (final school in schools) {
    if (compact.startsWith(school) || rewritten.startsWith(school)) {
      if (best == null || school.length > best.length) best = school;
    }
  }
  return best ?? (schools.contains(rewritten) ? rewritten : compact);
}

String _rewriteNaesinSchoolSuffix(String compact) {
  return compact
      .replaceFirst(RegExp(r'여자중학교$'), '여중')
      .replaceFirst(RegExp(r'여자고등학교$'), '여고')
      .replaceFirst(RegExp(r'중학교$'), '중')
      .replaceFirst(RegExp(r'고등학교$'), '고');
}
