const List<String> kNaesinMiddleSchools = <String>[
  '경신중',
  '능인중',
  '대륜중',
  '동도중',
  '소선여중',
  '오성중',
  '정화중',
  '황금중',
];

const List<String> kNaesinHighSchools = <String>[
  '경북고',
  '경신고',
  '능인고',
  '대구여고',
  '대륜고',
  '오성고',
  '정화여고',
  '혜화여고',
];

/// 표지 등에 쓰는 정식 학교명. 경신중 → 경신중학교, 정화여고 → 정화여자고등학교.
String naesinSchoolDisplayName(String key) {
  final k = key.trim();
  if (k.endsWith('여중')) return '${k.substring(0, k.length - 2)}여자중학교';
  if (k.endsWith('여고')) return '${k.substring(0, k.length - 2)}여자고등학교';
  if (k.endsWith('중')) return '$k학교';
  if (k.endsWith('고')) return '$k등학교';
  return k;
}

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
