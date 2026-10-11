import '../services/homework_store.dart';

// 학습앱 과제 카드 1행 문구. 알림장 숙제 리스트도 이 문구를 그대로 쓴다.
// 카드와 알림장이 어긋나지 않도록 규칙은 여기 한 곳에만 둔다.

String _stripHomeworkUnitPrefix(String raw) {
  return raw.replaceFirst(RegExp(r'^\s*\d+\.\d+\.\(\d+\)\s+'), '').trim();
}

String homeworkCardBookName(HomeworkItem hw) {
  final contentRaw = (hw.content ?? '').trim();
  final match = RegExp(r'(?:^|\n)\s*교재:\s*([^\n]+)').firstMatch(contentRaw);
  final fromContent = match?.group(1)?.trim() ?? '';
  if (fromContent.isNotEmpty) return fromContent;

  final hasLinkedTextbook = (hw.bookId ?? '').trim().isNotEmpty &&
      (hw.gradeLabel ?? '').trim().isNotEmpty;
  if (hasLinkedTextbook) {
    final stripped = _stripHomeworkUnitPrefix(hw.title.trim());
    if (stripped.isNotEmpty) {
      final idx = stripped.indexOf('·');
      if (idx == -1) return stripped;
      final candidate = stripped.substring(0, idx).trim();
      if (candidate.isNotEmpty) return candidate;
    }
  }

  final typeLabel = (hw.type ?? '').trim();
  if (typeLabel.isNotEmpty) return typeLabel;
  return '-';
}

String homeworkCardCourseName(HomeworkItem hw) {
  final contentRaw = (hw.content ?? '').trim();
  final match = RegExp(r'(?:^|\n)\s*과정:\s*([^\n]+)').firstMatch(contentRaw);
  return match?.group(1)?.trim() ?? '';
}

/// 문제은행으로 만든 과제(선생님이 내준 프린트).
bool isProblemBankAssignmentHomework(HomeworkItem hw) {
  return (hw.sourceUnitLevel ?? '').trim() == 'problem_bank_assignment';
}

String problemBankAssignmentCourseLabel(HomeworkItem hw) {
  final explicit = homeworkCardCourseName(hw);
  if (explicit.isNotEmpty) return explicit;

  final book = (hw.sourceUnitPath ?? '').trim();
  final parts = (hw.content ?? '')
      .split(RegExp(r'\s*·\s*|\n'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .where((part) => !part.startsWith('교재:') && !part.startsWith('과정:'))
      .where((part) => !part.startsWith('p.'))
      .where((part) => !RegExp(r'^\d+문항$').hasMatch(part))
      .where((part) => book.isEmpty || part != book)
      .toList(growable: false);
  if (parts.isEmpty) return '';
  if (parts.length >= 2) return parts.last;

  final only = parts.first;
  final looksLikeGrade =
      RegExp(r'^(중|고)\s*\d').hasMatch(only) || only.contains('학년');
  return looksLikeGrade ? '' : only;
}

String problemBankAssignmentPrintLine(HomeworkItem hw) {
  final course = problemBankAssignmentCourseLabel(hw);
  if (course.isEmpty) return '프린트';
  return '프린트 · $course';
}

/// '교재 · 과정' (프린트 분기 없음).
String homeworkBookCourseLabel(HomeworkItem hw) {
  final bookName = homeworkCardBookName(hw);
  final courseName = homeworkCardCourseName(hw);
  return (bookName == '-' || bookName.isEmpty)
      ? (courseName.isEmpty ? '-' : courseName)
      : (courseName.isEmpty ? bookName : '$bookName · $courseName');
}

/// 과제 카드 1행: 프린트 과제는 '프린트 · 과정', 그 외는 '교재 · 과정'.
String homeworkCardFirstLine(HomeworkItem hw) {
  return isProblemBankAssignmentHomework(hw)
      ? problemBankAssignmentPrintLine(hw)
      : homeworkBookCourseLabel(hw);
}
