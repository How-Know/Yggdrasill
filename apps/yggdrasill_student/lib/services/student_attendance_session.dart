import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'student_api.dart';

/// 오늘 등원/하원 상태를 앱 전역으로 공유.
///
/// 과제 세션과 같이 Realtime + 짧은 폴백 폴링으로 키오스크 등원을 바로 반영한다.
/// 학습앱 「계획 저장」도 attendance_records 스냅샷 컬럼으로 감지한다.
class StudentAttendanceSession extends ChangeNotifier {
  StudentAttendanceSession._();
  static final StudentAttendanceSession instance = StudentAttendanceSession._();

  static const Duration _fallbackPollInterval = Duration(seconds: 3);
  static const Duration _reloadDebounce = Duration(milliseconds: 150);

  TodayAttendance _today = const TodayAttendance();
  StudentNextClass? _nextClass;
  DateTime? _planSnapshotAt;
  int? _planSnapshotMinutes;
  bool _hydrated = false;
  bool _syncStarted = false;
  bool _refreshInFlight = false;
  bool _pollInFlight = false;

  RealtimeChannel? _rt;
  String? _rtStudentId;
  Timer? _fallbackPollTimer;
  Timer? _reloadDebounceTimer;

  /// 학습앱이 목표를 새로 제시할 때마다 증가. UI는 스낵바·목록 갱신에 사용.
  final ValueNotifier<int> planGoalPresentedTick = ValueNotifier<int>(0);

  TodayAttendance get today => _today;
  DateTime? get arrival => _today.arrival;
  DateTime? get departure => _today.departure;
  DateTime? get classEndTime => _today.classEndTime;
  DateTime? get plannedDepartureAt => _today.plannedDepartureAt;
  String? get earlyLeaveReason => _today.earlyLeaveReason;
  StudentNextClass? get nextClass => _nextClass;
  DateTime? get planSnapshotAt => _planSnapshotAt;
  int? get planSnapshotMinutes => _planSnapshotMinutes;
  bool get hasPlanGoalSnapshot => _planSnapshotAt != null;

  /// 지금 학원에 있는가. 등원했고 아직 하원하지 않은 상태.
  /// 서버 `_student_location_kind`와 같은 규칙이다.
  bool get isAtAcademy => _today.arrival != null && _today.departure == null;

  /// 로그인 후 셸에서 한 번 호출.
  Future<void> startSync() async {
    if (_syncStarted) return;
    _syncStarted = true;
    await refresh(includeNextClass: true);
    await _subscribeRealtime();
    _startFallbackPoll();
  }

  Future<void> stopSync() async {
    _syncStarted = false;
    _fallbackPollTimer?.cancel();
    _fallbackPollTimer = null;
    _reloadDebounceTimer?.cancel();
    _reloadDebounceTimer = null;
    final channel = _rt;
    _rt = null;
    _rtStudentId = null;
    if (channel != null) {
      try {
        await channel.unsubscribe();
      } catch (_) {}
    }
  }

  void _scheduleReload() {
    _reloadDebounceTimer?.cancel();
    _reloadDebounceTimer = Timer(_reloadDebounce, () {
      _reloadDebounceTimer = null;
      unawaited(refresh());
    });
  }

  void _startFallbackPoll() {
    _fallbackPollTimer?.cancel();
    _fallbackPollTimer = Timer.periodic(_fallbackPollInterval, (_) {
      unawaited(_pollOrRefresh());
    });
  }

  Future<void> _subscribeRealtime() async {
    try {
      final id = await StudentApi.instance.identity();
      if (id == null) return;
      if (_rt != null && _rtStudentId == id.studentId) return;

      final prev = _rt;
      _rt = null;
      _rtStudentId = null;
      if (prev != null) {
        try {
          await prev.unsubscribe();
        } catch (_) {}
      }

      final studentId = id.studentId;
      final filter = PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'student_id',
        value: studentId,
      );
      final channelName =
          'student:attendance:$studentId:${DateTime.now().millisecondsSinceEpoch}';
      final channel = Supabase.instance.client.channel(channelName)
        ..onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'attendance_records',
          filter: filter,
          callback: (_) => _scheduleReload(),
        );
      channel.subscribe();
      _rt = channel;
      _rtStudentId = studentId;
      debugPrint('[ATT][rt] student subscribed: $channelName');
    } catch (e, st) {
      debugPrint('[ATT][rt] student subscribe failed: $e\n$st');
    }
  }

  /// Realtime 누락 대비: updated_at 윈도우 또는 RPC 폴백.
  Future<void> _pollOrRefresh() async {
    if (!_syncStarted || _pollInFlight || _refreshInFlight) return;
    _pollInFlight = true;
    try {
      final id = await StudentApi.instance.identity();
      if (id == null) return;

      // 등원 전이면 RPC를 바로 쳐서 키오스크 등원을 빠르게 잡는다.
      if (_today.arrival == null) {
        await refresh();
        return;
      }

      final since = DateTime.now()
          .toUtc()
          .subtract(const Duration(seconds: 8))
          .toIso8601String();
      final rows = await Supabase.instance.client
          .from('attendance_records')
          .select(
            'updated_at, arrival_time, departure_time,'
            'homework_plan_snapshot_at,homework_plan_snapshot_minutes',
          )
          .eq('student_id', id.studentId)
          .gt('updated_at', since)
          .order('updated_at', ascending: false)
          .limit(5);
      if ((rows as List).isNotEmpty) {
        _scheduleReload();
      }
    } catch (e) {
      // SELECT RLS 미적용 등이면 RPC로 폴백.
      debugPrint('[ATT][poll] fallback rpc refresh: $e');
      await refresh();
    } finally {
      _pollInFlight = false;
    }
  }

  static bool _sameInstant(DateTime? a, DateTime? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return a == b;
    return a.toUtc().millisecondsSinceEpoch == b.toUtc().millisecondsSinceEpoch;
  }

  Future<void> refresh({bool includeNextClass = false}) async {
    if (_refreshInFlight) return;
    _refreshInFlight = true;
    try {
      final futures = <Future<dynamic>>[
        StudentApi.instance.todayAttendance(),
        StudentApi.instance.openPlanGoalSnapshot(),
      ];
      if (includeNextClass || _nextClass == null) {
        futures.add(StudentApi.instance.nextClass());
      }
      final results = await Future.wait(futures);
      final next = results[0] as TodayAttendance;
      final snap = results[1] as StudentPlanGoalSnapshot?;
      StudentNextClass? nextClass = _nextClass;
      if (results.length > 2) {
        nextClass = results[2] as StudentNextClass?;
      }

      final nextSnapAt = snap?.presentedAt;
      final nextSnapMinutes = snap?.planMinutes;
      final snapshotChanged = !_sameInstant(nextSnapAt, _planSnapshotAt) ||
          nextSnapMinutes != _planSnapshotMinutes;
      final newlyPresented = _hydrated &&
          nextSnapAt != null &&
          (_planSnapshotAt == null ||
              nextSnapAt.toUtc().isAfter(_planSnapshotAt!.toUtc()));

      final changed = !_sameInstant(next.arrival, _today.arrival) ||
          !_sameInstant(next.departure, _today.departure) ||
          !_sameInstant(next.classDateTime, _today.classDateTime) ||
          !_sameInstant(next.classEndTime, _today.classEndTime) ||
          !_sameInstant(next.plannedDepartureAt, _today.plannedDepartureAt) ||
          next.earlyLeaveReason != _today.earlyLeaveReason ||
          !_sameInstant(nextClass?.classDateTime, _nextClass?.classDateTime) ||
          snapshotChanged;
      _today = next;
      _nextClass = nextClass;
      _planSnapshotAt = nextSnapAt;
      _planSnapshotMinutes = nextSnapMinutes;
      _hydrated = true;
      if (changed) notifyListeners();
      if (newlyPresented) {
        planGoalPresentedTick.value = planGoalPresentedTick.value + 1;
        debugPrint(
          '[ATT][plan-goal] presented at=$nextSnapAt minutes=$nextSnapMinutes',
        );
      }
    } catch (_) {
      // best-effort
    } finally {
      _refreshInFlight = false;
    }
  }
}
