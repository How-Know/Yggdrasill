import 'dart:async';

import 'package:flutter/foundation.dart';

import 'data_manager.dart';
import 'homework_assignment_store.dart';
import 'homework_store.dart';

/// 홈의 오늘 출석과 현재 등원 학생 과제만 서버 상태로 수렴시킨다.
///
/// 여러 lifecycle 신호가 연달아 와도 한 작업으로 합치고, 잦은 창 전환이 전체
/// 스냅샷 요청 폭주로 이어지지 않도록 짧은 성공 후 cooldown을 둔다.
class HomeRealtimeSyncCoordinator {
  HomeRealtimeSyncCoordinator._();

  static final HomeRealtimeSyncCoordinator instance =
      HomeRealtimeSyncCoordinator._();

  static const Duration _minInterval = Duration(seconds: 15);
  static const Duration _healthyWindowFocusInterval = Duration(minutes: 2);

  Future<void>? _inFlight;
  DateTime? _lastCompletedAt;

  Future<void> resync({
    String reason = 'manual',
    bool force = false,
  }) async {
    final running = _inFlight;
    if (running != null) {
      await running;
      return;
    }

    final now = DateTime.now();
    final last = _lastCompletedAt;
    if (!force &&
        reason == 'window_focus' &&
        HomeworkStore.instance.isRealtimeHealthy &&
        last != null &&
        now.difference(last) < _healthyWindowFocusInterval) {
      return;
    }
    if (!force && last != null && now.difference(last) < _minInterval) {
      return;
    }

    final future = _run(reason);
    _inFlight = future;
    try {
      await future;
      _lastCompletedAt = DateTime.now();
    } finally {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    }
  }

  Future<void> _run(String reason) async {
    final stopwatch = Stopwatch()..start();
    debugPrint('[HOME_SYNC] start reason=$reason');
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    await DataManager.instance.refreshAttendanceRecordsForDate(today);

    final attendedStudentIds = DataManager.instance.attendanceRecords
        .where((record) {
          final classDate = record.classDateTime;
          final isToday = classDate.year == today.year &&
              classDate.month == today.month &&
              classDate.day == today.day;
          return isToday &&
              (record.isPresent || record.arrivalTime != null) &&
              record.departureTime == null;
        })
        .map((record) => record.studentId.trim())
        .where((studentId) => studentId.isNotEmpty)
        .toSet();

    await HomeworkStore.instance.reloadStudentsForHome(attendedStudentIds);
    // 학생별 N+1 대신 한 요청으로 활성 assignment 캐시를 갱신한다.
    await HomeworkAssignmentStore.instance
        .loadActiveAssignmentsForStudents(attendedStudentIds);
    debugPrint(
      '[HOME_SYNC] done reason=$reason attended=${attendedStudentIds.length} '
      'elapsedMs=${stopwatch.elapsedMilliseconds}',
    );
  }
}
