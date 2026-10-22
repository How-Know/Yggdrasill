import '../services/homework_store.dart';
import 'homework_card_label.dart';

/// 홈 과제 리스트에서 카드가 빠지는 기준.
/// 완료 플래그(pending_complete)만 켜진 확인 상태는 아직 리스트에 남는다.
bool homeworkLeftHomeList(HomeworkItem item) {
  return item.status == HomeworkStatus.completed;
}

/// 그룹 카드가 홈에서 사라진 시각. 하위 과제가 모두 완료된 뒤, 가장 마지막 완료 시각.
DateTime? homeworkGroupLeftHomeAt(List<HomeworkItem> children) {
  if (children.isEmpty) return null;
  if (!children.every(homeworkLeftHomeList)) return null;
  DateTime? latest;
  for (final child in children) {
    final at = child.completedAt ?? child.updatedAt ?? child.createdAt;
    if (at == null) continue;
    if (latest == null || at.isAfter(latest)) latest = at;
  }
  return latest;
}

bool homeworkCompletionOnDayRange(
  DateTime at, {
  required DateTime start,
  required DateTime end,
}) {
  final day = DateTime(at.year, at.month, at.day);
  final from = DateTime(start.year, start.month, start.day);
  final to = DateTime(end.year, end.month, end.day);
  return !day.isBefore(from) && !day.isAfter(to);
}

/// 과제 현황의 교재 필터 이름.
/// 알림장 카드 문구([homeworkCardFirstLine])는 바꾸지 않고, 문제은행·내신 기출만
/// 교재 목록에서 구분되도록 여기서 이름을 만든다.
String homeworkOverviewBookLabel(
  HomeworkItem item, {
  String? groupTitle,
}) {
  if (_isNaesinHomework(item, groupTitle)) {
    return _naesinBookLabel(item, groupTitle);
  }
  if (isProblemBankAssignmentHomework(item)) {
    final course = problemBankAssignmentCourseLabel(item);
    return course.isEmpty ? '문제은행' : '문제은행 · $course';
  }
  final book = homeworkCardBookName(item);
  if (book.isNotEmpty && book != '-') return book;
  return '교재 없음';
}

String homeworkOverviewGroupBookLabel(
  List<HomeworkItem> children, {
  String? groupTitle,
}) {
  for (final child in children) {
    if (_isNaesinHomework(child, groupTitle)) {
      return _naesinBookLabel(child, groupTitle);
    }
  }
  for (final child in children) {
    if (isProblemBankAssignmentHomework(child)) {
      return homeworkOverviewBookLabel(child, groupTitle: groupTitle);
    }
  }
  for (final child in children) {
    final label = homeworkOverviewBookLabel(child, groupTitle: groupTitle);
    if (label != '교재 없음') return label;
  }
  return '교재 없음';
}

bool _isNaesinHomework(HomeworkItem item, String? groupTitle) {
  if ((item.sourceUnitLevel ?? '').trim() == 'naesin') return true;
  final content = (item.content ?? '').trimLeft();
  if (content.startsWith('내신 기출')) return true;
  return (groupTitle ?? '').contains('내신 기출');
}

String _naesinBookLabel(HomeworkItem item, String? groupTitle) {
  final title = (groupTitle ?? '').trim();
  if (title.contains('내신 기출')) return title;
  String field(String name) {
    final match = RegExp('(?:^|\\n)\\s*$name:\\s*([^\\n]+)')
        .firstMatch(item.content ?? '');
    return match?.group(1)?.trim() ?? '';
  }

  final parts = <String>[
    field('연도'),
    field('학교'),
    field('학년'),
  ].where((part) => part.isNotEmpty);
  if (parts.isEmpty) return '내신 기출';
  return '${parts.join(' ')} 내신 기출';
}
