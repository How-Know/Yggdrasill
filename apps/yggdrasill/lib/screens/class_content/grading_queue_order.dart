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
