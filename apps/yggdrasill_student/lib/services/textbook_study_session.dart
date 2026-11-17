import 'dart:async';

import 'package:flutter/widgets.dart';

import 'textbook_api.dart';

/// 앱 전역에서 교재 풀기 탭(자습)의 활성 세션을 관리한다.
///
/// - `바로풀기(solve)`: 실행 중이면 30초마다 박동을 보내고 상단 아일랜드에 `공부중`을 연동한다.
/// - `중단(paused)`: 교재 카드에 `중단` 배지를 띄우고, 재진입 시 묻지 않고 바로 이어 푼다.
/// - `정답입력하기(answer_entry)`: 타이머를 돌리지 않고 닫을 때 조용히 종료한다.
class TextbookStudySession extends ChangeNotifier with WidgetsBindingObserver {
  TextbookStudySession._();
  static final TextbookStudySession instance = TextbookStudySession._();

  static const Duration _beatInterval = Duration(seconds: 30);

  final Map<String, ActiveTextbookSession> _sessionsByBook =
      <String, ActiveTextbookSession>{};
  Timer? _beatTimer;
  bool _beatInFlight = false;
  bool _lifecycleBound = false;
  bool _syncStarted = false;
  bool _refreshInFlight = false;

  static String _bookKey(String bookId, String gradeLabel) =>
      '${bookId.trim()}|${gradeLabel.trim()}';

  ActiveTextbookSession? sessionFor(String bookId, String gradeLabel) =>
      _sessionsByBook[_bookKey(bookId, gradeLabel)];

  ActiveTextbookSession? solveSessionFor(String bookId, String gradeLabel) {
    final s = sessionFor(bookId, gradeLabel);
    if (s == null || !s.isSolve) return null;
    return s;
  }

  /// 현재 타이머가 돌고 있는 `바로풀기` 세션 (최대 1개).
  ActiveTextbookSession? get runningSolveSession {
    for (final s in _sessionsByBook.values) {
      if (s.isSolve && s.isOpen) return s;
    }
    return null;
  }

  bool get hasRunningSolve => runningSolveSession != null;

  Future<void> startSync() async {
    if (!_lifecycleBound) {
      WidgetsBinding.instance.addObserver(this);
      _lifecycleBound = true;
    }
    if (!_syncStarted) {
      _syncStarted = true;
      await refresh();
    } else {
      unawaited(refresh());
    }
  }

  Future<void> stopSync() async {
    _syncStarted = false;
    _beatTimer?.cancel();
    _beatTimer = null;
    if (_lifecycleBound) {
      WidgetsBinding.instance.removeObserver(this);
      _lifecycleBound = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_syncStarted) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(refresh());
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      unawaited(_sendBeat());
    }
  }

  void _syncBeatTimer() {
    final running = runningSolveSession;
    if (running == null) {
      _beatTimer?.cancel();
      _beatTimer = null;
      return;
    }
    if (_beatTimer != null) return;
    _beatTimer = Timer.periodic(_beatInterval, (_) => unawaited(_sendBeat()));
  }

  Future<void> _sendBeat() async {
    final running = runningSolveSession;
    if (running == null || _beatInFlight) return;
    _beatInFlight = true;
    try {
      await TextbookApi.instance.beatTextbookSession(
        sessionId: running.sessionId,
      );
    } catch (_) {
      // 다음 주기에 재시도.
    } finally {
      _beatInFlight = false;
    }
  }

  Future<void> refresh() async {
    if (_refreshInFlight) return;
    _refreshInFlight = true;
    try {
      final rows = await TextbookApi.instance.listActiveTextbookSessions();
      _sessionsByBook.clear();
      for (final row in rows) {
        final key = _bookKey(row.bookId, row.gradeLabel);
        final prev = _sessionsByBook[key];
        // 같은 책에 solve 세션이 있으면 카드 배지·재진입 기준으로 우선 둔다.
        if (prev == null || (row.isSolve && !prev.isSolve)) {
          _sessionsByBook[key] = row;
        }
      }
      _syncBeatTimer();
      notifyListeners();
    } catch (_) {
      // 마이그레이션 미적용 환경 등에서는 조용히 빈 상태 유지.
    } finally {
      _refreshInFlight = false;
    }
  }

  Future<ActiveTextbookSession?> startSession({
    required String bookId,
    required String gradeLabel,
    required TextbookEntryMode entryMode,
  }) async {
    try {
      final session = await TextbookApi.instance.startTextbookSession(
        bookId: bookId,
        gradeLabel: gradeLabel,
        entryMode: entryMode,
      );
      if (session == null) return null;
      if (entryMode == TextbookEntryMode.solve) {
        // 다른 책에서 돌던 바로풀기는 서버와 맞추어 중단 상태로 반영.
        final targetKey = _bookKey(bookId, gradeLabel);
        for (final entry in _sessionsByBook.entries.toList()) {
          if (entry.key != targetKey &&
              entry.value.isSolve &&
              entry.value.isOpen) {
            _sessionsByBook[entry.key] = entry.value.copyWith(status: 'paused');
          }
        }
      }
      _sessionsByBook[_bookKey(bookId, gradeLabel)] = session;
      _syncBeatTimer();
      notifyListeners();
      return session;
    } catch (_) {
      return null;
    }
  }

  Future<void> pauseSession(String sessionId) async {
    final id = sessionId.trim();
    if (id.isEmpty) return;
    try {
      await TextbookApi.instance.pauseTextbookSession(sessionId: id);
    } catch (_) {}
    for (final entry in _sessionsByBook.entries) {
      if (entry.value.sessionId == id) {
        _sessionsByBook[entry.key] = entry.value.copyWith(
          status: 'paused',
          pausedAt: DateTime.now(),
        );
        break;
      }
    }
    _syncBeatTimer();
    notifyListeners();
  }

  Future<void> finishSession(String sessionId) async {
    final id = sessionId.trim();
    if (id.isEmpty) return;
    try {
      await TextbookApi.instance.finishTextbookSession(sessionId: id);
    } catch (_) {}
    _sessionsByBook.removeWhere((_, v) => v.sessionId == id);
    _syncBeatTimer();
    notifyListeners();
  }

  Future<void> finishForBook(String bookId, String gradeLabel) async {
    final s = sessionFor(bookId, gradeLabel);
    if (s == null) return;
    await finishSession(s.sessionId);
  }
}
