import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'student_api.dart';

/// 누적 포인트를 앱 전역으로 공유한다.
///
/// 내 정보 카드는 탭이 IndexedStack 에 남아 한 번만 로드되므로,
/// Realtime(잔액·원장) + 짧은 폴백으로 과제 완료 직후 숫자가 바뀌게 한다.
class StudentPointSession extends ChangeNotifier {
  StudentPointSession._();
  static final StudentPointSession instance = StudentPointSession._();

  static const Duration _fallbackPollInterval = Duration(seconds: 4);
  static const Duration _reloadDebounce = Duration(milliseconds: 150);
  static const Duration _grantDedupe = Duration(seconds: 2);

  PointSummaryInfo? _summary;
  bool _loading = true;
  String? _error;
  bool _syncStarted = false;
  bool _refreshInFlight = false;

  RealtimeChannel? _rt;
  String? _rtStudentId;
  Timer? _fallbackPollTimer;
  Timer? _reloadDebounceTimer;

  DateTime? _suppressRealtimeGrantUntil;
  int _pendingRealtimeGrant = 0;
  Timer? _realtimeGrantFlush;

  /// 과제 완료로 포인트를 받았을 때 증가. UI 스낵바용.
  final ValueNotifier<int> homeworkGrantTick = ValueNotifier<int>(0);

  /// 가장 최근 과제 완료 지급액. [homeworkGrantTick]과 함께 읽는다.
  int lastHomeworkGrant = 0;

  PointSummaryInfo? get summary => _summary;
  bool get loading => _loading;
  String? get error => _error;

  Future<void> startSync() async {
    if (_syncStarted) return;
    _syncStarted = true;
    await refresh();
    await _subscribeRealtime();
    _startFallbackPoll();
  }

  Future<void> stopSync() async {
    _syncStarted = false;
    _fallbackPollTimer?.cancel();
    _fallbackPollTimer = null;
    _reloadDebounceTimer?.cancel();
    _reloadDebounceTimer = null;
    _realtimeGrantFlush?.cancel();
    _realtimeGrantFlush = null;
    _pendingRealtimeGrant = 0;
    final channel = _rt;
    _rt = null;
    _rtStudentId = null;
    if (channel != null) {
      try {
        await channel.unsubscribe();
      } catch (_) {}
    }
  }

  /// 과제 완료 RPC가 돌려준 지급액.
  /// [announce]가 false면 숫지만 갱신하고 스낵바는 호출부가 직접 띄운다.
  void noteHomeworkGrant(int delta, {bool announce = true}) {
    if (delta <= 0) return;
    final now = DateTime.now();
    if (_suppressRealtimeGrantUntil != null &&
        now.isBefore(_suppressRealtimeGrantUntil!)) {
      unawaited(refresh());
      return;
    }
    _suppressRealtimeGrantUntil = now.add(_grantDedupe);
    _pendingRealtimeGrant = 0;
    _realtimeGrantFlush?.cancel();
    unawaited(refresh());
    if (!announce) return;
    lastHomeworkGrant = delta;
    homeworkGrantTick.value = homeworkGrantTick.value + 1;
  }

  void _queueRealtimeHomeworkGrant(int delta) {
    if (delta <= 0) return;
    final suppressUntil = _suppressRealtimeGrantUntil;
    if (suppressUntil != null && DateTime.now().isBefore(suppressUntil)) {
      _scheduleReload();
      return;
    }
    _pendingRealtimeGrant += delta;
    _realtimeGrantFlush?.cancel();
    _realtimeGrantFlush = Timer(const Duration(milliseconds: 400), () {
      final total = _pendingRealtimeGrant;
      _pendingRealtimeGrant = 0;
      if (total <= 0) return;
      final now = DateTime.now();
      if (_suppressRealtimeGrantUntil != null &&
          now.isBefore(_suppressRealtimeGrantUntil!)) {
        unawaited(refresh());
        return;
      }
      _suppressRealtimeGrantUntil = now.add(_grantDedupe);
      lastHomeworkGrant = total;
      homeworkGrantTick.value = homeworkGrantTick.value + 1;
      unawaited(refresh());
    });
  }

  Future<void> refresh() async {
    if (_refreshInFlight) return;
    _refreshInFlight = true;
    try {
      final next = await StudentApi.instance.getPointSummary();
      if (!_syncStarted && _summary == null && next == null) {
        _loading = false;
        _error = '포인트를 불러오지 못했어요.';
        notifyListeners();
        return;
      }
      _summary = next;
      _loading = false;
      _error = next == null ? '포인트를 불러오지 못했어요.' : null;
      notifyListeners();
    } catch (_) {
      _loading = false;
      _error = _summary == null ? '포인트를 불러오지 못했어요.' : _error;
      notifyListeners();
    } finally {
      _refreshInFlight = false;
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
      unawaited(refresh());
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
          'student:points:$studentId:${DateTime.now().millisecondsSinceEpoch}';
      final channel = Supabase.instance.client.channel(channelName)
        ..onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'student_point_balances',
          filter: filter,
          callback: (_) => _scheduleReload(),
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'student_point_ledger',
          filter: filter,
          callback: (payload) {
            final rec = payload.newRecord;
            final kind = '${rec['kind'] ?? ''}';
            final delta = (rec['delta'] as num?)?.toInt() ?? 0;
            if (kind == 'earn_homework' && delta > 0) {
              _queueRealtimeHomeworkGrant(delta);
            } else {
              _scheduleReload();
            }
          },
        );
      channel.subscribe();
      _rt = channel;
      _rtStudentId = studentId;
    } catch (_) {
      // Realtime 실패 시 폴백 폴링만으로 동작한다.
    }
  }
}
