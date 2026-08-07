import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'student_api.dart';
import 'textbook_api.dart';

/// 앱 전역에서 "현재 수행 중 과제"를 공유한다.
///
/// 학습앱 `HomeworkStore`와 같이 Realtime + 짧은 폴백 폴링(1.2s)으로 목록을 맞춘다.
class HomeworkSession extends ChangeNotifier {
  HomeworkSession._();
  static final HomeworkSession instance = HomeworkSession._();

  static const Duration _fallbackPollInterval = Duration(milliseconds: 1200);
  static const Duration _reloadDebounce = Duration(milliseconds: 120);

  HomeworkGroup? _active;
  String? _coverRef;

  /// 실제로 타이머가 돌아가는 그룹 (동시에 최대 1개).
  String? _runningGroupId;

  /// 사용자가 마지막으로 시작/선택한 그룹 (목록 순서보다 우선).
  String? _preferredGroupId;

  /// 아래로 스와이프해 미니바를 숨긴 그룹.
  String? _suppressedMiniBarGroupId;
  bool _busy = false;
  List<HomeworkGroup>? _lastGroups;
  Map<String, String> _lastCovers = const {};

  RealtimeChannel? _rt;
  String? _rtStudentId;
  Timer? _fallbackPollTimer;
  Timer? _reloadDebounceTimer;
  DateTime? _pollCursorUtc;
  bool _pollInFlight = false;
  bool _refreshInFlight = false;
  bool _syncStarted = false;

  HomeworkGroup? get active {
    final a = _active;
    if (a == null) return null;
    if (_suppressedMiniBarGroupId == a.groupId) return null;
    return a;
  }

  String? get coverRef {
    if (active == null) return null;
    return _coverRef;
  }

  String? get runningGroupId => _runningGroupId;
  bool get busy => _busy;
  bool get hasActive => active != null;
  HomeworkListKind? get activeListKind => active?.listKind;
  HomeworkAssignmentOrigin? get activeAssignmentOrigin =>
      active?.assignmentOrigin;
  bool get activeIsHomework => active?.isHomework ?? false;

  /// 마지막 목록 스냅샷 (미니바 pause/play 후에도 과제 화면이 바로 따라가게).
  List<HomeworkGroup>? get lastGroups => _lastGroups;
  Map<String, String> get lastCovers => _lastCovers;

  bool isRunningGroup(String groupId) =>
      _runningGroupId != null && _runningGroupId == groupId;

  void preferGroup(String groupId) {
    final id = groupId.trim();
    if (id.isEmpty) return;
    final changed =
        _preferredGroupId != id || _suppressedMiniBarGroupId != null;
    _preferredGroupId = id;
    _suppressedMiniBarGroupId = null;
    if (changed) notifyListeners();
  }

  /// 미니바 닫기. 수행 중이면 일시정지도 함께 한다.
  Future<void> dismissMiniBar() async {
    final group = _active;
    if (group == null) return;
    final id = group.groupId;
    if (_suppressedMiniBarGroupId == id) return;
    final shouldPause = isRunningGroup(id);
    _suppressedMiniBarGroupId = id;
    notifyListeners();
    if (shouldPause) {
      await pause();
    }
  }

  HomeworkGroup? _pickRunning(List<HomeworkGroup> running) {
    if (running.isEmpty) return null;
    if (_preferredGroupId != null) {
      for (final g in running) {
        if (g.groupId == _preferredGroupId) return g;
      }
    }
    // 목록 순서가 아니라 가장 최근에 시작된 그룹을 고른다.
    HomeworkGroup? best;
    DateTime? bestStart;
    for (final g in running) {
      final start = g.runStart;
      if (start == null) continue;
      if (best == null || bestStart == null || start.isAfter(bestStart)) {
        best = g;
        bestStart = start;
      }
    }
    return best ?? running.first;
  }

  /// HomeworkScreen 새로고침 결과로 동기화.
  void syncFromGroups(
    List<HomeworkGroup> groups, {
    Map<String, String> covers = const {},
  }) {
    _lastGroups = List<HomeworkGroup>.unmodifiable(groups);
    if (covers.isNotEmpty) {
      _lastCovers = Map<String, String>.unmodifiable(covers);
    }
    final coverMap = covers.isNotEmpty ? covers : _lastCovers;

    final running = groups.where((g) => g.running).toList(growable: false);
    final pickedRunning = _pickRunning(running);
    final runningId = pickedRunning?.groupId;

    HomeworkGroup? next = pickedRunning;
    if (next == null && _preferredGroupId != null) {
      for (final g in groups) {
        if (g.groupId == _preferredGroupId && g.phase == 2) {
          next = g;
          break;
        }
      }
    }
    // 일시정지 후에도 같은 과제를 미니바에 남겨 바로 재개할 수 있게 한다.
    // 완료 예약 후 대기(1)로 내려가는 순간은 미니바에 다시 올리지 않는다.
    if (next == null && _preferredGroupId != null) {
      for (final g in groups) {
        if (g.groupId != _preferredGroupId) continue;
        if (g.phase == 2 || (g.phase == 1 && !g.pendingComplete)) {
          next = g;
          break;
        }
      }
    }
    if (next == null) {
      for (final g in groups) {
        if (g.phase == 2) {
          next = g;
          break;
        }
      }
    }

    String? cover;
    if (next != null && !next.isPrintSource && next.bookId.isNotEmpty) {
      cover = coverMap['${next.bookId}|${next.gradeLabel}'] ??
          coverMap[next.bookId];
    }

    if (next != null &&
        _suppressedMiniBarGroupId != null &&
        next.groupId != _suppressedMiniBarGroupId) {
      _suppressedMiniBarGroupId = null;
    }
    _active = next;
    _coverRef = cover;
    _runningGroupId = runningId;
    // 목록 스냅샷은 항상 알린다 (과제 화면 stale phase 방지).
    notifyListeners();
  }

  /// 로그인 후 셸에서 한 번 호출 — Realtime + 1.2s 폴백 시작.
  Future<void> startSync() async {
    if (_syncStarted) return;
    _syncStarted = true;
    await refresh(fetchCovers: true);
    await _subscribeRealtime();
    _startFallbackPoll();
  }

  /// 로그아웃/셸 dispose 시 구독·폴링 정리.
  Future<void> stopSync() async {
    _syncStarted = false;
    _fallbackPollTimer?.cancel();
    _fallbackPollTimer = null;
    _reloadDebounceTimer?.cancel();
    _reloadDebounceTimer = null;
    _pollCursorUtc = null;
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
    _pollCursorUtc =
        DateTime.now().toUtc().subtract(const Duration(seconds: 2));
    _fallbackPollTimer = Timer.periodic(_fallbackPollInterval, (_) {
      unawaited(_pollRecentUpdates());
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
          'student:homework:$studentId:${DateTime.now().millisecondsSinceEpoch}';
      final channel = Supabase.instance.client.channel(channelName);

      void onChange(PostgresChangePayload _) => _scheduleReload();

      channel
        ..onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'homework_items',
          filter: filter,
          callback: onChange,
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'homework_groups',
          filter: filter,
          callback: onChange,
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'homework_group_items',
          filter: filter,
          callback: onChange,
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'homework_group_runtime',
          filter: filter,
          callback: onChange,
        );
      channel.subscribe();
      _rt = channel;
      _rtStudentId = studentId;
      debugPrint('[HW][rt] student subscribed: $channelName');
    } catch (e, st) {
      debugPrint('[HW][rt] student subscribe failed: $e\n$st');
    }
  }

  Future<void> _pollRecentUpdates() async {
    if (!_syncStarted || _pollInFlight || _busy) return;
    _pollInFlight = true;
    try {
      final id = await StudentApi.instance.identity();
      if (id == null) return;
      final since = _pollCursorUtc ??
          DateTime.now().toUtc().subtract(const Duration(seconds: 2));
      final sinceIso = since.toIso8601String();
      final client = Supabase.instance.client;

      // 학습앱 폴백과 동일: updated_at 윈도우만 보고 변경 시에만 전체 refresh.
      final results = await Future.wait([
        client
            .from('homework_items')
            .select('updated_at')
            .eq('student_id', id.studentId)
            .gt('updated_at', sinceIso)
            .order('updated_at', ascending: true)
            .limit(20),
        client
            .from('homework_group_runtime')
            .select('updated_at')
            .eq('student_id', id.studentId)
            .gt('updated_at', sinceIso)
            .order('updated_at', ascending: true)
            .limit(20),
        client
            .from('homework_groups')
            .select('updated_at')
            .eq('student_id', id.studentId)
            .gt('updated_at', sinceIso)
            .order('updated_at', ascending: true)
            .limit(20),
      ]);

      DateTime maxUpdated = since;
      var changed = false;
      for (final raw in results) {
        final rows = (raw as List<dynamic>).cast<Map<String, dynamic>>();
        if (rows.isEmpty) continue;
        changed = true;
        for (final row in rows) {
          final ts = DateTime.tryParse('${row['updated_at'] ?? ''}');
          if (ts == null) continue;
          final utc = ts.toUtc();
          if (utc.isAfter(maxUpdated)) maxUpdated = utc;
        }
      }
      if (!changed) return;
      _pollCursorUtc = maxUpdated.add(const Duration(milliseconds: 1));
      _scheduleReload();
    } catch (e) {
      // SELECT RLS 미적용 등이면 전체 refresh로 폴백.
      debugPrint('[HW][poll] fallback full refresh: $e');
      _scheduleReload();
    } finally {
      _pollInFlight = false;
    }
  }

  /// 셸/화면에서 호출 — 과제 탭이 아니어도 미니바·목록을 갱신.
  Future<void> refresh({bool fetchCovers = false}) async {
    if (_refreshInFlight) return;
    _refreshInFlight = true;
    try {
      final groups = await StudentApi.instance.listHomeworkGroups();
      var covers = _lastCovers;
      if (fetchCovers || covers.isEmpty) {
        final books = await TextbookApi.instance.listTextbooks().then(
              (value) => value,
              onError: (_, __) => const <StudentTextbook>[],
            );
        final next = <String, String>{};
        for (final book in books) {
          final ref = book.coverRef.trim();
          if (ref.isEmpty) continue;
          next['${book.bookId}|${book.gradeLabel}'] = ref;
          next.putIfAbsent(book.bookId, () => ref);
        }
        covers = next;
      }
      syncFromGroups(groups, covers: covers);
      _pollCursorUtc = DateTime.now().toUtc();
    } catch (_) {
      // best-effort
    } finally {
      _refreshInFlight = false;
    }
  }

  Future<Map<String, dynamic>> play([String? groupId]) async {
    final targetId = (groupId ?? _preferredGroupId ?? _active?.groupId)?.trim();
    if (targetId == null || targetId.isEmpty || _busy) {
      return const {'ok': false};
    }
    _preferredGroupId = targetId;
    _suppressedMiniBarGroupId = null;
    _busy = true;
    notifyListeners();
    try {
      final result = await StudentApi.instance.groupTransition(
        groupId: targetId,
        fromPhase: 1,
      );
      await refresh();
      return result;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> pause() async {
    if (_busy) return;
    _busy = true;
    _runningGroupId = null;
    notifyListeners();
    try {
      await StudentApi.instance.pauseAll();
      await refresh();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> submit() async {
    final group = _active;
    if (group == null || _busy) return const {'ok': false};
    _busy = true;
    notifyListeners();
    try {
      final result = await StudentApi.instance.groupTransition(
        groupId: group.groupId,
        fromPhase: 99,
      );
      if (result['ok'] == true) {
        _preferredGroupId = null;
      }
      await refresh();
      return result;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
