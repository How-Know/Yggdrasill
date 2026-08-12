DateTime? earliestHomeworkCreatedAt(Iterable<DateTime?> values) {
  DateTime? earliest;
  for (final value in values) {
    if (value != null && (earliest == null || value.isBefore(earliest))) {
      earliest = value;
    }
  }
  return earliest;
}

String homeworkCreatedDateLabel(DateTime? createdAt) {
  if (createdAt == null) return '-';
  final month = createdAt.month.toString().padLeft(2, '0');
  final day = createdAt.day.toString().padLeft(2, '0');
  return '$month.$day';
}
