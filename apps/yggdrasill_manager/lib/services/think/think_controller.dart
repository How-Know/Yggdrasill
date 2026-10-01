import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'think_action_models.dart';
import 'think_api.dart';
import 'think_code_controller.dart';
import 'think_models.dart';
import 'think_tree.dart';

class ThinkTurnInfo {
  const ThinkTurnInfo({this.context, this.usage, this.costUsd, this.model, this.webSearchCalls = 0});

  final Map<String, dynamic>? context;
  final Map<String, dynamic>? usage;
  final double? costUsd;
  final String? model;
  final int webSearchCalls;

  ThinkTurnInfo copyWith({
    Map<String, dynamic>? context,
    Map<String, dynamic>? usage,
    double? costUsd,
    String? model,
    int? webSearchCalls,
  }) =>
      ThinkTurnInfo(
        context: context ?? this.context,
        usage: usage ?? this.usage,
        costUsd: costUsd ?? this.costUsd,
        model: model ?? this.model,
        webSearchCalls: webSearchCalls ?? this.webSearchCalls,
      );
}

class _StreamItem {
  _StreamItem(this.phase);
  String phase;
  final StringBuffer text = StringBuffer();
}

/// Think 화면 상태. 메인 화면이 선택되지 않은 메뉴를 트리에서 빼기 때문에
/// 답변 스트림과 입력 중인 내용이 메뉴 이동 뒤에도 남도록 화면 밖에 둔다.
class ThinkController extends ChangeNotifier {
  ThinkController._();
  static final ThinkController instance = ThinkController._();

  final ThinkApi _api = ThinkApi.instance;
  bool _started = false;

  Future<void> ensureStarted() async {
    if (_started) return;
    _started = true;
    ThinkCodeController.instance.addListener(_onCodeRequestsChanged);
    await Future.wait([refreshStatus(), refreshConversations(), refreshMemories(), refreshTree()]);
  }

  // ------------------------------------------------------------------ 탭 이동
  static const int tabChat = 0;

  int tab = tabChat;
  String? selectedMemoryId;

  void setTab(int value) {
    if (tab == value) return;
    tab = value;
    ThinkCodeController.instance.setVisible(tab == tabChat);
    notifyListeners();
  }

  void selectMemory(String? id) {
    selectedMemoryId = id;
    notifyListeners();
  }

  void openMemory(String id) {
    selectedMemoryId = id;
    setTab(1);
  }

  Future<void> openConversation(String id) async {
    setTab(0);
    if (showArchived && conversationById(id) == null) await setShowArchived(false);
    await select(id);
  }

  // ------------------------------------------------------------------ 상태
  ThinkStatus? status;
  ThinkApiException? statusError;
  bool statusLoading = false;

  bool get forbidden => statusError?.code == 'forbidden';

  Future<void> refreshStatus() async {
    statusLoading = true;
    notifyListeners();
    try {
      status = await _api.status();
      statusError = null;
    } on ThinkApiException catch (e) {
      statusError = e;
    } catch (e) {
      statusError = ThinkApiException('status_failed', '상태를 불러오지 못했습니다: $e');
    } finally {
      statusLoading = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ 대화 목록
  List<ThinkConversation> conversations = [];
  bool showArchived = false;
  bool conversationsLoading = false;
  String? conversationsError;

  Future<void> refreshConversations() async {
    conversationsLoading = true;
    notifyListeners();
    try {
      conversations = await _api.listConversations(archived: showArchived);
      conversationsError = null;
    } catch (e) {
      conversationsError = '대화 목록을 불러오지 못했습니다: $e';
    } finally {
      conversationsLoading = false;
      notifyListeners();
    }
  }

  Future<void> setShowArchived(bool value) async {
    if (showArchived == value) return;
    showArchived = value;
    conversations = [];
    await refreshConversations();
  }

  ThinkConversation? conversationById(String? id) {
    if (id == null) return null;
    for (final c in conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> renameConversation(String id, String title) async {
    final t = title.trim();
    if (t.isEmpty) return;
    await _api.renameConversation(id, t);
    _replaceConversation(id, (c) => c.copyWith(title: t));
  }

  Future<void> setArchived(String id, bool archived) async {
    await _api.setConversationArchived(id, archived);
    conversations = conversations.where((c) => c.id != id).toList();
    if (selectedId == id) selectedId = null;
    notifyListeners();
  }

  Future<void> deleteConversation(String id) async {
    await _api.deleteConversation(id);
    _forgetConversation(id);
  }

  void _forgetConversation(String id) {
    conversations = conversations.where((c) => c.id != id).toList();
    treeNodes = treeNodes.where((n) => n.conversationId != id).toList();
    _messages.remove(id);
    _actions.remove(id);
    turnInfo.remove(id);
    costs.remove(id);
    if (selectedId == id) selectedId = null;
    notifyListeners();
  }

  void _replaceConversation(String id, ThinkConversation Function(ThinkConversation) update) {
    conversations = [for (final c in conversations) c.id == id ? update(c) : c];
    notifyListeners();
  }

  // ------------------------------------------------------------------ 정리 트리
  // 트리는 사람이 보는 정리용이다. AI 답변 맥락에는 넣지 않고, 분류를 제안할 때만
  // 도구로 폴더 이름·경로와 대화 제목을 읽는다(발췌 내용은 읽지 않음).
  List<ThinkTreeNode> treeNodes = [];
  bool treeLoading = false;
  String? treeError;
  final Set<String> collapsedFolders = {};
  bool unfiledCollapsed = false;

  /// null이면 화면 너비로 정한다.
  bool? treePanelOpen;

  List<ThinkTreeNode>? _treeNodesBuilt;
  List<ThinkConversation>? _treeConversationsBuilt;
  ThinkTree? _tree;

  ThinkTree get tree {
    if (_tree == null || !identical(_treeNodesBuilt, treeNodes) || !identical(_treeConversationsBuilt, conversations)) {
      _tree = ThinkTree.build(treeNodes, conversations);
      _treeNodesBuilt = treeNodes;
      _treeConversationsBuilt = conversations;
    }
    return _tree!;
  }

  Future<void> refreshTree() async {
    treeLoading = true;
    notifyListeners();
    try {
      treeNodes = await _api.listTreeNodes();
      treeError = null;
    } catch (e) {
      treeError = '정리 트리를 불러오지 못했습니다: $e';
    } finally {
      treeLoading = false;
      notifyListeners();
    }
  }

  void setTreePanelOpen(bool open) {
    treePanelOpen = open;
    notifyListeners();
  }

  void toggleFolder(String id) {
    if (!collapsedFolders.remove(id)) collapsedFolders.add(id);
    notifyListeners();
  }

  void toggleUnfiled() {
    unfiledCollapsed = !unfiledCollapsed;
    notifyListeners();
  }

  /// 트리를 바꾼 뒤에는 서버 순서를 그대로 다시 읽는다. 실패하면 예외를 그대로 올린다.
  Future<void> _mutateTree(Future<void> Function() action) async {
    try {
      await action();
    } finally {
      await refreshTree();
    }
  }

  Future<void> createFolder(String title, {String? parentId}) async {
    final t = title.trim();
    if (t.isEmpty) return;
    await _mutateTree(() async {
      await _api.createFolder(title: t, parentId: parentId, sortOrder: tree.allChildren(parentId).length);
      if (parentId != null) collapsedFolders.remove(parentId);
    });
  }

  Future<void> renameNode(ThinkTreeNode node, String title) async {
    final t = title.trim();
    if (t.isEmpty) return;
    if (node.kind == ThinkTreeKind.conversation) {
      await renameConversation(node.conversationId!, t);
      return;
    }
    await _mutateTree(() => _api.updateTreeNode(node.id, {'title': t}));
  }

  Future<void> updateExcerpt(ThinkTreeNode node, {required String title, required String summary}) async {
    final t = title.trim();
    if (t.isEmpty) return;
    final s = summary.trim();
    await _mutateTree(() => _api.updateTreeNode(node.id, {'title': t, 'summary': s.isEmpty ? null : s}));
  }

  /// 폴더를 지워도 안의 대화·발췌는 폴더가 있던 자리로 올라간다.
  Future<void> deleteFolder(ThinkTreeNode node) async {
    await _mutateTree(() => _api.deleteFolder(node.id));
    collapsedFolders.remove(node.id);
  }

  /// 발췌를 지우거나 대화를 '정리 안 됨'으로 돌린다. 원본 메시지는 그대로다.
  Future<void> removeNode(ThinkTreeNode node) async {
    if (node.isFolder) return deleteFolder(node);
    await _mutateTree(() => _api.deleteTreeNode(node.id));
  }

  Future<void> applyDrop(ThinkDropPlan plan) async {
    await _mutateTree(() async {
      if (plan.unfile) {
        await _api.deleteTreeNode(plan.nodeId!);
      } else if (plan.nodeId != null) {
        await _api.moveTreeNode(plan.nodeId!, plan.parentId, plan.index);
      } else {
        await _api.placeConversation(plan.conversationId!, plan.parentId, plan.index);
      }
      if (plan.parentId != null) collapsedFolders.remove(plan.parentId);
    });
  }

  Future<void> createExcerpt({
    required String conversationId,
    required String? parentId,
    required String title,
    required String summary,
    required List<String> messageIds,
  }) async {
    await _mutateTree(() async {
      await _api.createExcerpt(
        conversationId: conversationId,
        parentId: parentId,
        title: title,
        summary: summary.trim().isEmpty ? null : summary.trim(),
        messageIds: messageIds,
      );
      if (parentId != null) collapsedFolders.remove(parentId);
    });
  }

  // ------------------------------------------------------------------ 작업 제안
  // AI는 도구로 제안(ai_actions)만 남긴다. 실행은 여기서 사람이 승인할 때 서버 RPC가 한다.
  final Map<String, List<ThinkAction>> _actions = {};

  List<ThinkAction> get actions => selectedId == null ? const [] : (_actions[selectedId] ?? const []);

  List<ThinkAction> actionsOf(String conversationId) => _actions[conversationId] ?? const [];

  /// 트리에 강조할 대기 중 분류 제안. 승인 전에는 아무것도 저장하지 않는다.
  ThinkAction? get pendingPlacement {
    for (final a in actions.reversed) {
      if (a.kind == ThinkActionKind.placeConversation && a.pending) return a;
    }
    return null;
  }

  Future<void> loadActions(String conversationId) async {
    try {
      final loaded = await _api.listActions(conversationId);
      final ids = {for (final a in loaded) a.id};
      final local = (_actions[conversationId] ?? const <ThinkAction>[]).where((a) => !ids.contains(a.id));
      _actions[conversationId] = [...loaded, ...local];
      for (final a in loaded.reversed) {
        if (a.pending && a.kind == ThinkActionKind.placeConversation) {
          _revealPlacement(a);
          break;
        }
      }
      notifyListeners();
    } catch (_) {
      // 제안 카드는 다음에 대화를 열 때 다시 읽는다.
    }
  }

  @visibleForTesting
  void putActionForTest(ThinkAction a) => _putAction(a);

  void _putAction(ThinkAction a) {
    final list = [...(_actions[a.conversationId] ?? const <ThinkAction>[])];
    final i = list.indexWhere((x) => x.id == a.id);
    if (i >= 0) {
      list[i] = a;
    } else {
      // 서버와 같이, 같은 종류의 대기 중 제안은 새 제안으로 대체된다.
      if (a.pending) {
        for (var j = 0; j < list.length; j++) {
          final o = list[j];
          if (o.pending && o.kind == a.kind) list[j] = o.copyWith(status: ThinkActionStatus.rejected, superseded: true);
        }
      }
      list.add(a);
    }
    _actions[a.conversationId] = list;
    if (a.pending && a.kind == ThinkActionKind.placeConversation) _revealPlacement(a);
    notifyListeners();
  }

  /// 제안된 폴더가 보이도록 조상 폴더를 편다. 새 폴더면 만들 자리(상위 폴더)까지 편다.
  void _revealPlacement(ThinkAction a) {
    final byId = tree.byId;
    var cur = a.folderId != null ? byId[a.folderId]?.parentId : a.newFolderParentId;
    var guard = 0;
    while (cur != null && guard++ < 64) {
      collapsedFolders.remove(cur);
      cur = byId[cur]?.parentId;
    }
  }

  Future<ThinkAction> applyAction(ThinkAction a, {Map<String, dynamic> overrides = const {}}) async {
    final saved = await _api.applyAction(a.id, overrides: overrides);
    await _afterAction(saved);
    return saved;
  }

  Future<void> rejectAction(ThinkAction a) async => _putAction(await _api.rejectAction(a.id));

  Future<void> undoAction(ThinkAction a) async {
    final saved = await _api.undoAction(a.id);
    _putAction(saved);
    await refreshTree();
  }

  Future<void> _afterAction(ThinkAction a) async {
    final deleted = a.result?['deleted_id']?.toString();
    if (a.kind == ThinkActionKind.deleteConversation && deleted != null) _forgetConversation(deleted);
    if (!a.deletedSelf) _putAction(a);
    final code = ThinkCodeController.instance;
    switch (a.kind) {
      case ThinkActionKind.codeRequest:
      case ThinkActionKind.codeChange:
      case ThinkActionKind.deleteCodeRequest:
        await code.refresh(quiet: true);
      case ThinkActionKind.placeConversation:
      case ThinkActionKind.deleteFolder:
      case ThinkActionKind.deleteConversation:
        await refreshTree();
    }
  }

  /// Think가 코드 결과를 검토해 답을 남기면(review_message_id) 열린 대화를 다시 읽는다.
  final Set<String> _reviewReloads = {};

  void _onCodeRequestsChanged() {
    final id = selectedId;
    if (id == null || (isStreaming && streamingConversationId == id)) return;
    final list = _messages[id];
    if (list == null) return;
    final have = {for (final m in list) m.id};
    for (final r in ThinkCodeController.instance.requestsFor(id)) {
      final mid = r.reviewMessageId;
      if (mid == null || have.contains(mid) || !_reviewReloads.add(mid)) continue;
      unawaited(_reloadIfIdle(id));
      unawaited(_refreshConversationsQuietly());
      return;
    }
  }

  // ------------------------------------------------------------------ 답변에서 제외
  /// [index] 메시지가 속한 문답(질문+답변)을 함께 제외하거나 되돌린다.
  Future<void> setTurnExcluded(int index, bool excluded) async {
    final list = messages;
    final turn = thinkTurnIndices(list, index).map((i) => list[i]).toList();
    final ids = [for (final m in turn) if (m.id != null && m.id!.isNotEmpty) m.id!];
    if (ids.isEmpty) return;
    await _api.setMessagesExcluded(ids, excluded);
    for (final m in turn) {
      if (m.id != null) m.contextExcluded = excluded;
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ 원문으로 이동
  Set<String> highlightedMessageIds = {};
  String? revealMessageId;
  int revealSerial = 0;
  Timer? _highlightTimer;

  /// 대화를 열고 [messageIds] 중 가장 앞의 메시지로 스크롤한 뒤 잠깐 강조한다.
  Future<void> revealMessages(String conversationId, List<String> messageIds) async {
    await openConversation(conversationId);
    final list = _messages[conversationId] ?? const <ThinkMessage>[];
    final wanted = messageIds.toSet();
    final first = list.where((m) => wanted.contains(m.id)).firstOrNull;
    _highlightTimer?.cancel();
    highlightedMessageIds = wanted;
    revealMessageId = first?.id;
    revealSerial += 1;
    notifyListeners();
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      highlightedMessageIds = {};
      notifyListeners();
    });
  }

  // ------------------------------------------------------------------ 선택된 대화
  String? selectedId;
  final Map<String, List<ThinkMessage>> _messages = {};
  List<ThinkMessage> _draft = [];
  bool messagesLoading = false;
  String? messagesError;
  final Map<String, ThinkTurnInfo> turnInfo = {};
  final Map<String, double?> costs = {};

  List<ThinkMessage> get messages => selectedId == null ? _draft : (_messages[selectedId] ?? const []);
  ThinkConversation? get selected => conversationById(selectedId);
  ThinkTurnInfo? get selectedTurnInfo => selectedId == null ? null : turnInfo[selectedId];

  void startNew() {
    selectedId = null;
    if (!(isStreaming && _streamingDraft && streamingConversationId == null)) _draft = [];
    messagesError = null;
    notifyListeners();
  }

  Future<void> select(String id) async {
    selectedId = id;
    messagesError = null;
    notifyListeners();
    unawaited(refreshCost(id));
    unawaited(loadActions(id));
    if (isStreaming && streamingConversationId == id) return;
    messagesLoading = !_messages.containsKey(id);
    notifyListeners();
    try {
      final loaded = await _api.listMessages(id);
      if (!(isStreaming && streamingConversationId == id)) _messages[id] = loaded;
    } catch (e) {
      if (selectedId == id) messagesError = '메시지를 불러오지 못했습니다: $e';
    } finally {
      messagesLoading = false;
      notifyListeners();
    }
  }

  Future<void> refreshCost(String id) async {
    try {
      costs[id] = await _api.conversationCost(id);
      notifyListeners();
    } catch (_) {}
  }

  // ------------------------------------------------------------------ 입력창
  final TextEditingController composer = TextEditingController();
  final List<ThinkAttachment> pendingAttachments = [];
  int uploadingCount = 0;
  bool deep = false;
  bool webSearch = false;
  String? sendError;

  void setDeep(bool v) {
    deep = v;
    notifyListeners();
  }

  void setWebSearch(bool v) {
    webSearch = v;
    notifyListeners();
  }

  void clearSendError() {
    if (sendError == null) return;
    sendError = null;
    notifyListeners();
  }

  /// 반환값: 첨부하지 못한 파일에 대한 안내 문구들.
  Future<List<String>> addFiles(Iterable<String> paths) async {
    final problems = <String>[];
    final room = 6 - pendingAttachments.length - uploadingCount;
    var accepted = 0;
    final uploads = <Future<void>>[];
    for (final path in paths) {
      final name = path.split(RegExp(r'[\\/]')).last;
      if (ThinkApi.mimeForPath(path) == null) {
        problems.add('$name: 이미지(PNG·JPG·WEBP·GIF)와 PDF만 첨부할 수 있습니다.');
        continue;
      }
      if (accepted >= room) {
        problems.add('$name: 한 번에 6개까지 첨부할 수 있습니다.');
        continue;
      }
      accepted += 1;
      uploadingCount += 1;
      uploads.add(() async {
        try {
          final a = await _api.uploadAttachment(File(path));
          pendingAttachments.add(a);
        } catch (e) {
          problems.add('$name: ${e is ThinkApiException ? e.message : '업로드 실패 ($e)'}');
        } finally {
          uploadingCount -= 1;
          notifyListeners();
        }
      }());
    }
    notifyListeners();
    await Future.wait(uploads);
    return problems;
  }

  Future<void> removePending(ThinkAttachment a) async {
    pendingAttachments.remove(a);
    notifyListeners();
    await _api.removeAttachment(a.path);
  }

  bool get canSend =>
      !isStreaming && uploadingCount == 0 && composer.text.trim().isNotEmpty && !forbidden;

  // ------------------------------------------------------------------ 스트리밍
  ThinkChatStream? _stream;
  String? streamingConversationId;
  bool _streamingDraft = false;
  bool _stopRequested = false;
  String? notice;
  Timer? _notifyTimer;

  bool get isStreaming => _stream != null || _opening;
  bool _opening = false;

  bool get streamingHere =>
      isStreaming &&
      (selectedId == null ? _streamingDraft && streamingConversationId == null : streamingConversationId == selectedId);

  void _notifySoon() {
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(const Duration(milliseconds: 50), notifyListeners);
  }

  void stop() {
    if (!isStreaming) return;
    _stopRequested = true;
    _stream?.cancel();
  }

  Future<void> send() async {
    if (!canSend) return;
    final text = composer.text.trim();
    final attachments = [...pendingAttachments];
    final convId = selectedId;

    final user = ThinkMessage(
      role: 'user',
      content: text,
      status: ThinkMessageStatus.complete,
      attachments: attachments,
      createdAt: DateTime.now(),
    );
    final assistant = ThinkMessage(
      role: 'assistant',
      content: '',
      status: ThinkMessageStatus.streaming,
      createdAt: DateTime.now(),
    );
    final List<ThinkMessage> list;
    if (convId == null) {
      _draft = [];
      list = _draft;
    } else {
      list = _messages.putIfAbsent(convId, () => []);
    }
    list
      ..add(user)
      ..add(assistant);
    composer.clear();
    pendingAttachments.clear();
    sendError = null;
    notice = null;
    streamingConversationId = convId;
    _streamingDraft = convId == null;
    _stopRequested = false;
    _opening = true;
    notifyListeners();

    final ThinkChatStream stream;
    try {
      stream = await _api.openChat(
        conversationId: convId,
        message: text,
        attachments: attachments,
        deep: deep,
        webSearch: webSearch,
      );
    } catch (e) {
      list
        ..remove(user)
        ..remove(assistant);
      composer.text = text;
      pendingAttachments.addAll(attachments);
      sendError = e is ThinkApiException ? e.message : '보내지 못했습니다: $e';
      if (e is ThinkApiException && e.code == 'forbidden') statusError = e;
      _opening = false;
      streamingConversationId = null;
      _streamingDraft = false;
      notifyListeners();
      return;
    }
    _stream = stream;
    _opening = false;
    notifyListeners();

    String? conversationId = convId;
    var finished = false;
    final items = <String, _StreamItem>{};

    void rebuildText() {
      String join(bool commentary) => items.values
          .where((i) => (i.phase == 'commentary') == commentary)
          .map((i) => i.text.toString().trim())
          .where((t) => t.isNotEmpty)
          .join('\n\n');
      assistant.content = join(false);
      final c = join(true);
      assistant.commentary = c.isEmpty ? null : c;
    }

    try {
      await for (final ev in stream.events) {
        final d = ev.data;
        switch (ev.event) {
          case 'notice':
            notice = switch (d['code']) {
              'budget_warning' => '이번 달 사용 한도를 넘었습니다(경고 모드). 사용량 탭을 확인하세요.',
              'web_search_disabled' => '웹 검색이 꺼져 있어 검색 없이 답합니다. 사용량 탭에서 켤 수 있습니다.',
              _ => d['message']?.toString(),
            };
            notifyListeners();
          case 'conversation':
            final id = d['conversation_id']?.toString();
            if (id == null) break;
            conversationId = id;
            user.id = d['user_message_id']?.toString();
            final ctx = d['context'] is Map ? Map<String, dynamic>.from(d['context'] as Map) : null;
            turnInfo[id] = ThinkTurnInfo(context: ctx, model: d['model']?.toString());
            if (_streamingDraft) {
              _messages[id] = list;
              streamingConversationId = id;
              if (selectedId == null) {
                selectedId = id;
                _draft = [];
              }
              if (conversationById(id) == null && !showArchived) {
                final now = DateTime.now();
                conversations = [
                  ThinkConversation(
                    id: id,
                    title: d['title']?.toString() ?? '새 대화',
                    status: 'active',
                    messageCount: 1,
                    lastMessageAt: now,
                    createdAt: now,
                  ),
                  ...conversations,
                ];
              }
            }
            notifyListeners();
          case 'message_start':
            final itemId = d['item_id']?.toString() ?? 'item_${items.length}';
            items[itemId] = _StreamItem(d['phase']?.toString() ?? 'final');
          case 'delta':
            final itemId = d['item_id']?.toString() ?? 'item_${items.length}';
            items.putIfAbsent(itemId, () => _StreamItem('final')).text.write(d['text']?.toString() ?? '');
            rebuildText();
            _notifySoon();
          case 'message_done':
            final item = items[d['item_id']?.toString()];
            if (item != null) {
              item.phase = d['phase']?.toString() ?? item.phase;
              rebuildText();
              _notifySoon();
            }
          case 'tool':
            final trace = ThinkToolTrace.fromJson(d);
            final tools = [...assistant.toolCalls];
            final idx = tools.indexWhere((t) => t.callId != null && t.callId == trace.callId);
            if (idx >= 0) {
              tools[idx] = trace;
            } else {
              tools.add(trace);
            }
            assistant.toolCalls = tools;
            notifyListeners();
          case 'action':
            final raw = d['action'];
            final action = raw is Map ? ThinkAction.fromRow(Map<String, dynamic>.from(raw)) : null;
            if (action != null) _putAction(action);
          case 'title':
            final id = d['conversation_id']?.toString();
            final title = d['title']?.toString();
            if (id != null && title != null && title.isNotEmpty) {
              _replaceConversation(id, (c) => c.copyWith(title: title));
            }
          case 'done':
            finished = true;
            assistant.id = d['assistant_message_id']?.toString();
            assistant.status =
                d['status'] == 'stopped' ? ThinkMessageStatus.stopped : ThinkMessageStatus.complete;
            assistant.model = d['model']?.toString();
            assistant.sources = (d['sources'] is List ? d['sources'] as List : const [])
                .whereType<Map>()
                .map((s) => ThinkSource.fromJson(Map<String, dynamic>.from(s)))
                .toList();
            assistant.toolCalls = [for (final t in assistant.toolCalls) if (!t.running) t];
            final id = conversationId;
            if (id != null) {
              turnInfo[id] = (turnInfo[id] ?? const ThinkTurnInfo()).copyWith(
                usage: d['usage'] is Map ? Map<String, dynamic>.from(d['usage'] as Map) : null,
                costUsd: (d['cost_usd'] as num?)?.toDouble(),
                model: d['model']?.toString(),
                webSearchCalls: (d['web_search_calls'] as num?)?.toInt() ?? 0,
              );
              _attachActions(id, d['action_ids'], assistant.id);
            }
            notifyListeners();
          case 'error':
            finished = true;
            assistant.id = d['assistant_message_id']?.toString();
            assistant.status = ThinkMessageStatus.error;
            assistant.errorText = d['message']?.toString() ?? '답변을 만들지 못했습니다.';
            assistant.toolCalls = [for (final t in assistant.toolCalls) if (!t.running) t];
            if (conversationId != null) _attachActions(conversationId, d['action_ids'], assistant.id);
            notifyListeners();
        }
      }
    } catch (e) {
      if (!finished && !_stopRequested) {
        assistant.errorText = '연결이 끊겼습니다: $e';
      }
    } finally {
      _notifyTimer?.cancel();
      if (!finished) {
        assistant.status = _stopRequested ? ThinkMessageStatus.stopped : ThinkMessageStatus.error;
        if (!_stopRequested) assistant.errorText ??= '답변이 끝나기 전에 연결이 끊겼습니다.';
        assistant.toolCalls = [for (final t in assistant.toolCalls) if (!t.running) t];
      }
      stream.cancel();
      _stream = null;
      streamingConversationId = null;
      _streamingDraft = false;
      notifyListeners();
    }

    final id = conversationId;
    if (id != null) {
      unawaited(refreshCost(id));
      if (!finished) {
        // 서버는 연결이 끊긴 뒤에 부분 답변을 저장하므로 조금 기다렸다가 다시 읽는다.
        unawaited(Future<void>.delayed(const Duration(seconds: 2), () => _reloadIfIdle(id)));
      }
    }
    unawaited(_refreshConversationsQuietly());
  }

  /// 서버가 답변을 저장하며 붙인 message_id를 화면의 제안에도 붙인다.
  void _attachActions(String conversationId, dynamic ids, String? messageId) {
    if (messageId == null || messageId.isEmpty || ids is! List || ids.isEmpty) return;
    final wanted = ids.map((e) => e.toString()).toSet();
    final list = _actions[conversationId];
    if (list == null) return;
    _actions[conversationId] = [
      for (final a in list) wanted.contains(a.id) && a.messageId == null ? a.copyWith(messageId: messageId) : a,
    ];
  }

  Future<void> _reloadIfIdle(String id) async {
    if (isStreaming && streamingConversationId == id) return;
    try {
      final loaded = await _api.listMessages(id);
      if (isStreaming && streamingConversationId == id) return;
      _messages[id] = loaded;
      notifyListeners();
    } catch (_) {}
    await loadActions(id);
  }

  Future<void> _refreshConversationsQuietly() async {
    try {
      conversations = await _api.listConversations(archived: showArchived);
      notifyListeners();
    } catch (_) {}
  }

  // ------------------------------------------------------------------ 기억
  List<ThinkMemory> memories = [];
  bool memoriesLoading = false;
  String? memoriesError;

  Future<void> refreshMemories() async {
    memoriesLoading = true;
    notifyListeners();
    try {
      memories = await _api.listMemories();
      memoriesError = null;
    } catch (e) {
      memoriesError = '기억을 불러오지 못했습니다: $e';
    } finally {
      memoriesLoading = false;
      notifyListeners();
    }
  }

  ThinkMemory? memoryById(String? id) {
    if (id == null) return null;
    for (final m in memories) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 확정(active)된 기억이 다른 기억을 대체하면(supersedes_id) 대체된 쪽을 '대체됨'으로 바꾼다.
  Future<ThinkMemory> saveMemory(ThinkMemoryDraft draft, {ThinkMemory? existing}) async {
    final saved = existing == null
        ? await _api.createMemory(draft)
        : await _api.updateMemory(existing.id, existing.version, draft.toRow());
    _putMemory(saved);
    await _supersedeFor(saved);
    return saved;
  }

  Future<ThinkMemory> setMemoryStatus(ThinkMemory m, ThinkMemoryStatus s) async {
    final saved = await _api.updateMemory(m.id, m.version, {'status': s.db});
    _putMemory(saved);
    await _supersedeFor(saved);
    return saved;
  }

  Future<void> _supersedeFor(ThinkMemory saved) async {
    if (saved.status != ThinkMemoryStatus.active) return;
    final target = memoryById(saved.supersedesId);
    if (target == null || target.id == saved.id || target.status != ThinkMemoryStatus.active) return;
    try {
      _putMemory(await _api.updateMemory(target.id, target.version, {'status': ThinkMemoryStatus.superseded.db}));
    } catch (_) {
      await refreshMemories();
    }
  }

  Future<ThinkMemory> markSpecExported(ThinkMemory m, String path) async {
    final saved = await _api.updateMemory(m.id, m.version, {
      'spec_path': path,
      'spec_exported_at': DateTime.now().toUtc().toIso8601String(),
    });
    _putMemory(saved);
    return saved;
  }

  Future<void> deleteMemory(ThinkMemory m) async {
    await _api.deleteMemory(m.id);
    memories = memories.where((e) => e.id != m.id).toList();
    if (selectedMemoryId == m.id) selectedMemoryId = null;
    notifyListeners();
  }

  Future<ThinkMemory> restoreRevision(ThinkMemory m, ThinkMemoryRevision r) async {
    final s = r.snapshot;
    final saved = await _api.updateMemory(m.id, m.version, {
      'title': s['title'] ?? m.title,
      'content': s['content'] ?? m.content,
      'decision_context': s['decision_context'],
      'decision_reason': s['decision_reason'],
      'alternatives': s['alternatives'] ?? const <String>[],
      'tags': s['tags'] ?? const <String>[],
    });
    _putMemory(saved);
    return saved;
  }

  void _putMemory(ThinkMemory saved) {
    final idx = memories.indexWhere((e) => e.id == saved.id);
    memories = idx >= 0
        ? [for (final e in memories) e.id == saved.id ? saved : e]
        : [saved, ...memories];
    notifyListeners();
  }
}
