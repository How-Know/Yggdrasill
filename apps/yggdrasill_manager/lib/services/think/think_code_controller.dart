import 'dart:async';

import 'package:flutter/widgets.dart';

import 'think_api.dart';
import 'think_code_models.dart';
import 'think_models.dart';

/// 코드 작업(조사·수정) 상태. 채팅 카드와 '전체 코드 요청' 창이 함께 쓴다.
/// Think 화면과 같은 이유로 화면 밖에 둔다(메뉴를 옮겨도 목록과 선택이 남는다).
/// 진행 중인 요청이 있거나 화면이 열려 있으면 주기적으로 새로 읽는다. 서버는 알림을 보내지 않는다.
class ThinkCodeController extends ChangeNotifier {
  ThinkCodeController._();
  static final ThinkCodeController instance = ThinkCodeController._();

  final ThinkApi _api = ThinkApi.instance;

  List<ThinkCodeRequest> requests = [];
  List<ThinkCodeWorker> workers = [];
  int dailyLimit = 10;
  bool loading = false;
  String? error;
  String? selectedId;
  final Map<String, List<ThinkCodeRound>> _rounds = {};
  final Set<String> _roundsLoading = {};

  bool _visible = false;
  bool _refreshing = false;
  Timer? _timer;

  static const Duration fastPoll = Duration(seconds: 5);
  static const Duration slowPoll = Duration(seconds: 30);

  ThinkCodeRequest? get selected => byId(selectedId);

  ThinkCodeRequest? byId(String? id) {
    if (id == null) return null;
    for (final r in requests) {
      if (r.id == id) return r;
    }
    return null;
  }

  List<ThinkCodeRound>? roundsOf(String id) => _rounds[id];

  @visibleForTesting
  void setRoundsForTest(String id, List<ThinkCodeRound> rounds) => _rounds[id] = rounds;
  bool roundsLoading(String id) => _roundsLoading.contains(id);

  ThinkCodeWorker? get onlineWorker {
    final now = DateTime.now();
    for (final w in workers) {
      if (w.onlineAt(now)) return w;
    }
    return null;
  }

  ThinkCodeWorker? get lastWorker => workers.isEmpty ? null : workers.first;

  int get submittedToday => thinkCodeSubmittedToday(requests, DateTime.now());

  List<ThinkCodeRequest> requestsFor(String conversationId) =>
      requests.where((r) => r.conversationId == conversationId).toList();

  /// 결과를 기다리거나 Think가 결과를 검토하는 중이면 빨리 읽는다.
  bool get _hasActive =>
      requests.any((r) => r.status.inProgress || r.reviewStatus == ThinkReviewStatus.pending);

  /// 카드가 그려질 때 회차 결과가 없으면 읽는다. build 중에 불러도 되도록 알림은 프레임 뒤로 미룬다.
  void ensureRounds(String id) {
    if (_rounds[id] != null || _roundsLoading.contains(id)) return;
    unawaited(Future.microtask(() => loadRounds(id)));
  }

  /// Think 화면이 보일 때 true. 보이지 않으면 진행 중인 요청이 있을 때만 읽는다.
  void setVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    if (visible) unawaited(refresh());
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (!_visible && !_hasActive) return;
    _timer = Timer(_hasActive ? fastPoll : slowPoll, () => unawaited(refresh(quiet: true)));
  }

  Future<void> refresh({bool quiet = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    if (!quiet) {
      loading = true;
      notifyListeners();
    }
    final before = {for (final r in requests) r.id: r.status};
    try {
      final results = await Future.wait([_api.listCodeRequests(), _api.listCodeWorkers(), _api.settings()]);
      requests = results[0] as List<ThinkCodeRequest>;
      workers = results[1] as List<ThinkCodeWorker>;
      dailyLimit = (results[2] as ThinkSettings).codeRequestDailyLimit;
      error = null;
      if (selectedId != null && byId(selectedId) == null) selectedId = null;
      for (final r in requests) {
        final old = before[r.id];
        if (old != null && old != r.status) _rounds.remove(r.id);
      }
      final sel = selected;
      if (sel != null && (sel.status.inProgress || _rounds[sel.id] == null)) unawaited(loadRounds(sel.id));
    } catch (e) {
      error = '코드 조사 목록을 불러오지 못했습니다: $e';
    } finally {
      loading = false;
      _refreshing = false;
      notifyListeners();
      _schedule();
    }
  }

  void select(String? id) {
    selectedId = id;
    notifyListeners();
    if (id != null && _rounds[id] == null) unawaited(loadRounds(id));
  }

  Future<void> loadRounds(String id) async {
    if (_roundsLoading.contains(id)) return;
    _roundsLoading.add(id);
    notifyListeners();
    try {
      _rounds[id] = await _api.listCodeRounds(id);
    } catch (_) {
      // 목록 새로고침 때 다시 시도한다.
    } finally {
      _roundsLoading.remove(id);
      notifyListeners();
    }
  }

  void _put(ThinkCodeRequest r) {
    final i = requests.indexWhere((x) => x.id == r.id);
    if (i == -1) {
      requests = [r, ...requests];
    } else {
      requests = [...requests]..[i] = r;
    }
    notifyListeners();
    _schedule();
  }

  /// 초안을 만들거나 고친다. [submit]이면 이어서 대기열에 올린다. 보내기가 실패해도 초안은 남는다.
  Future<ThinkCodeRequest> save({
    String? id,
    required String title,
    required ThinkCodeSpec spec,
    String? conversationId,
    List<String> sourceMessageIds = const [],
    bool submit = false,
  }) async {
    var saved = id == null
        ? await _api.createCodeRequest(
            title: title,
            spec: spec,
            conversationId: conversationId,
            sourceMessageIds: sourceMessageIds,
          )
        : await _api.updateCodeDraft(id, title: title, spec: spec);
    _put(saved);
    selectedId = saved.id;
    if (submit) {
      saved = await _api.submitCodeRequest(saved.id);
      _put(saved);
    }
    return saved;
  }

  Future<void> submit(ThinkCodeRequest r) async => _put(await _api.submitCodeRequest(r.id));

  Future<void> cancel(ThinkCodeRequest r) async => _put(await _api.cancelCodeRequest(r.id));

  Future<void> applyChange(ThinkCodeRequest r) async => _put(await _api.applyCodeChange(r.id));

  Future<void> revertChange(ThinkCodeRequest r) async => _put(await _api.revertCodeChange(r.id));

  Future<void> decide(ThinkCodeRequest r, ThinkCodeOutcome? outcome, String? note) async =>
      _put(await _api.decideCodeRequest(r.id, outcome, note));

  Future<void> delete(ThinkCodeRequest r) async {
    await _api.deleteCodeRequest(r.id);
    requests = requests.where((x) => x.id != r.id).toList();
    _rounds.remove(r.id);
    if (selectedId == r.id) selectedId = null;
    notifyListeners();
  }

  /// 실패·취소된 요청을 같은 내용의 새 초안으로 복제한다.
  Future<ThinkCodeRequest> duplicate(ThinkCodeRequest r) async {
    final copy = await _api.createCodeRequest(
      title: r.title,
      spec: r.spec,
      conversationId: r.conversationId,
      sourceMessageIds: r.sourceMessageIds,
    );
    _put(copy);
    selectedId = copy.id;
    notifyListeners();
    return copy;
  }
}
