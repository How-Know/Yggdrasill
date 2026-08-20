import 'dart:async';

import 'package:flutter/foundation.dart';

import 'data_manager.dart';
import 'homework_assignment_store.dart';
import 'homework_store.dart';

/// 홈의 출석·과제 데이터를 앱 복귀/Windows 포커스 시 서버 상태로 수렴시킨다.
///
/// 여러 lifecycle 신호가 연달아 와도 한 작업으로 합치고, 잦은 창 전환이 전체
/// 스냅샷 요청 폭주로 이어지지 않도록 짧은 성공 후 cooldown을 둔다.
class HomeRealtimeSyncCoordinator {
  HomeRealtimeSyncCoordinator._();

  static final HomeRealtimeSyncCoordinator instance =
      HomeRealtimeSyncCoordinator._();

  static const Duration _minInterval = Duration(seconds: 15);

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
    await Future.wait<void>([
      DataManager.instance.loadAttendanceRecords(),
      HomeworkStore.instance.loadAll(forceRefresh: true),
    ]);
    // 활성 assignment는 학생별 UI가 revision을 보고 다시 읽는다. 기존 성공
    // 캐시는 새 응답이 올 때까지 유지되어 네트워크 지연 중 카드가 사라지지 않는다.
    HomeworkAssignmentStore.instance.invalidateActiveAssignments();
    debugPrint(
      '[HOME_SYNC] done reason=$reason elapsedMs=${stopwatch.elapsedMilliseconds}',
    );
  }
}
