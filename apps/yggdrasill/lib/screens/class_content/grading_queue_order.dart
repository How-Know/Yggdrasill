String gradingQueueEntryIdentity({
  required String studentId,
  required String summaryId,
  String? groupId,
}) {
  final normalizedGroupId = (groupId ?? '').trim();
  final entryId = normalizedGroupId.isNotEmpty
      ? 'group:$normalizedGroupId'
      : 'item:${summaryId.trim()}';
  return '${studentId.trim()}|$entryId';
}

/// 채점 모드에 처음 나타난 카드의 대기열 시각을 세션 동안 고정한다.
///
/// 숙제 카드가 검사 후 제출 카드로 바뀌거나 서버 데이터가 새로고침돼도
/// 같은 카드라면 최초 위치를 유지한다.
DateTime retainGradingQueueTime(
  Map<String, DateTime> retainedTimes, {
  required String entryIdentity,
  required DateTime candidate,
}) {
  return retainedTimes.putIfAbsent(entryIdentity, () => candidate);
}

class GradingHomeworkSchedule {
  final DateTime assignedAt;
  final DateTime? dueForCheckAt;
  final DateTime? originalDueDate;
  final DateTime? dueDate;

  const GradingHomeworkSchedule({
    required this.assignedAt,
    this.dueForCheckAt,
    this.originalDueDate,
    this.dueDate,
  });

  DateTime? get effectiveCheckAt => dueForCheckAt ?? originalDueDate ?? dueDate;
}

/// 미제출 숙제를 채점 모드에 노출할지 결정한다.
///
/// 검사 예정일이 오늘 또는 과거면 노출한다. 반복·예약 숙제는 검사 당일 자정에
/// 새 배정 행이 생길 수 있으므로 `assignedAt`은 검사일이 없을 때만 보조 기준으로
/// 사용한다. 제출 카드는 이 필터를 거치지 않는다.
bool shouldShowUnsubmittedHomeworkInGradingMode({
  required Iterable<GradingHomeworkSchedule> schedules,
  required DateTime now,
}) {
  final localNow = now.toLocal();
  final today = DateTime(localNow.year, localNow.month, localNow.day);
  return schedules.any((schedule) {
    final effectiveCheckAt = schedule.effectiveCheckAt;
    if (effectiveCheckAt != null) {
      final local = effectiveCheckAt.toLocal();
      final checkDate = DateTime(local.year, local.month, local.day);
      return !checkDate.isAfter(today);
    }
    final assigned = schedule.assignedAt.toLocal();
    final assignedDate = DateTime(
      assigned.year,
      assigned.month,
      assigned.day,
    );
    return assignedDate.isBefore(today);
  });
}
