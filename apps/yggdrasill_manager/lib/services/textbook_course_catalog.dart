class TextbookCourseOption {
  const TextbookCourseOption({
    required this.gradeKey,
    required this.courseKey,
    required this.label,
    required this.levelLabel,
    required this.orderIndex,
  });

  final String gradeKey;
  final String courseKey;
  final String label;
  final String levelLabel;
  final int orderIndex;

  String get displayLabel => '$levelLabel · $label';
}

const List<TextbookCourseOption> kTextbookCourseOptions =
    <TextbookCourseOption>[
  TextbookCourseOption(
    gradeKey: 'M1',
    courseKey: 'M1-1',
    label: '1-1',
    levelLabel: '중1',
    orderIndex: 101,
  ),
  TextbookCourseOption(
    gradeKey: 'M1',
    courseKey: 'M1-2',
    label: '1-2',
    levelLabel: '중1',
    orderIndex: 102,
  ),
  TextbookCourseOption(
    gradeKey: 'M2',
    courseKey: 'M2-1',
    label: '2-1',
    levelLabel: '중2',
    orderIndex: 201,
  ),
  TextbookCourseOption(
    gradeKey: 'M2',
    courseKey: 'M2-2',
    label: '2-2',
    levelLabel: '중2',
    orderIndex: 202,
  ),
  TextbookCourseOption(
    gradeKey: 'M3',
    courseKey: 'M3-1',
    label: '3-1',
    levelLabel: '중3',
    orderIndex: 301,
  ),
  TextbookCourseOption(
    gradeKey: 'M3',
    courseKey: 'M3-2',
    label: '3-2',
    levelLabel: '중3',
    orderIndex: 302,
  ),
  TextbookCourseOption(
    gradeKey: 'H1',
    courseKey: 'H1-c1',
    label: '공통수학1',
    levelLabel: '고1',
    orderIndex: 401,
  ),
  TextbookCourseOption(
    gradeKey: 'H1',
    courseKey: 'H1-c2',
    label: '공통수학2',
    levelLabel: '고1',
    orderIndex: 402,
  ),
  TextbookCourseOption(
    gradeKey: 'H2',
    courseKey: 'H-algebra',
    label: '대수',
    levelLabel: '고2',
    orderIndex: 501,
  ),
  TextbookCourseOption(
    gradeKey: 'H2',
    courseKey: 'H-calc1',
    label: '미적분1',
    levelLabel: '고2',
    orderIndex: 502,
  ),
  TextbookCourseOption(
    gradeKey: 'H2',
    courseKey: 'H-probstats',
    label: '확률과 통계',
    levelLabel: '고2',
    orderIndex: 503,
  ),
  TextbookCourseOption(
    gradeKey: 'H2',
    courseKey: 'H-calc2',
    label: '미적분2',
    levelLabel: '고2',
    orderIndex: 504,
  ),
  TextbookCourseOption(
    gradeKey: 'H2',
    courseKey: 'H-geometry',
    label: '기하',
    levelLabel: '고2',
    orderIndex: 505,
  ),
];

TextbookCourseOption? textbookCourseByKey(String? courseKey) {
  final key = (courseKey ?? '').trim();
  if (key.isEmpty) return null;
  for (final option in kTextbookCourseOptions) {
    if (option.courseKey == key) return option;
  }
  return null;
}

TextbookCourseOption? textbookCourseByLabel(String? rawLabel) {
  final normalized = normalizeTextbookCourseLabel(rawLabel);
  if (normalized.isEmpty) return null;
  for (final option in kTextbookCourseOptions) {
    if (normalizeTextbookCourseLabel(option.label) == normalized ||
        normalizeTextbookCourseLabel(option.displayLabel) == normalized) {
      return option;
    }
  }
  if (normalized == '확률통계' || normalized == '확통') {
    return textbookCourseByKey('H-probstats');
  }
  return null;
}

String normalizeTextbookCourseLabel(String? raw) {
  return (raw ?? '')
      .trim()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('중등', '')
      .replaceAll('고등', '')
      .replaceAll('과정', '')
      .replaceAll('학년', '');
}
