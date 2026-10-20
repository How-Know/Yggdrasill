import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../auth_service.dart';
import 'think_action_models.dart';
import 'think_api.dart';
import 'think_code_controller.dart';
import 'think_models.dart';
import 'think_send_lock.dart';
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

/// 답변에 붙은 파일(Think가 파이썬 실행 환경에서 만든 것).
List<ThinkAttachment> _attachmentsOf(Map<String, dynamic> d) => (d['attachments'] is List ? d['attachments'] as List : const [])
    .whereType<Map>()
    .map((a) => ThinkAttachment.fromJson(Map<String, dynamic>.from(a)))
    .where((a) => a.path.isNotEmpty)
    .toList();

class _StreamItem {
  _StreamItem(this.phase);
  String phase;
  final StringBuffer text = StringBuffer();
}

/// Think 화면 상태. 메인 화면이 선택되지 않은 메뉴를 트리에서 빼기 때문에
/// 답변 스트림과 입력 중인 내용이 메뉴 이동 뒤에도 남도록 화면 밖에 둔다.
class ThinkController extends ChangeNotifier {
  ThinkController._() {
    ThinkSendLock.instance.addListener(notifyListeners);
    ThinkSendLock.instance.released.listen(_onSendReleased);
  }
  static final ThinkController instance = ThinkController._();

  final ThinkApi _api = ThinkApi.instance;
  bool _started = false;

  Future<void> ensureStarted() async {
    if (_started) return;
    _started = true;
    ThinkCodeController.instance.addListener(_onCodeRequestsChanged);
    await Future.wait([refreshStatus(), refreshConversations(), refreshMemories(), refreshTree()]);
    unawaited(refreshDocumentProbe());
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
  ThinkDocumentProbe? documentProbe;
  Object? documentProbeError;
  bool documentProbeLoading = false;

  String? get supabaseProjectRef => ThinkApi.supabaseProjectRef(AuthService.supabaseUrl);

  bool get forbidden => statusError?.code == 'forbidden';

  Future<void> refreshStatus() async {
    statusLoading = true;
    notifyListeners();
    try {
      final wasReady = rolesReady;
      final wasOrganizeReady = organizeReady;
      status = await _api.status();
      statusError = null;
      final id = selectedId;
      if (!wasReady && rolesReady && id != null) _loadRoleExtras(id);
      if (!wasOrganizeReady && organizeReady) {
        unawaited(refreshOrganizeSettings());
        unawaited(refreshDepartmentCriteria());
      }
    } on ThinkApiException catch (e) {
      statusError = e;
    } catch (e) {
      statusError = ThinkApiException('status_failed', '상태를 불러오지 못했습니다: $e');
    } finally {
      statusLoading = false;
      notifyListeners();
    }
  }

  Future<void> refreshDocumentProbe() async {
    if (forbidden) return;
    documentProbeLoading = true;
    notifyListeners();
    try {
      documentProbe = await _api.probeDocumentCapabilities(conversationIdForCreate: selectedId);
      documentProbeError = null;
    } catch (e) {
      documentProbe = null;
      documentProbeError = e;
    } finally {
      documentProbeLoading = false;
      notifyListeners();
    }
  }

  /// Edge status·문서 probe·코드 작업자 목록을 함께 갱신한다.
  Future<void> refreshConnectionDetails() async {
    await Future.wait([
      refreshStatus(),
      refreshDocumentProbe(),
      ThinkCodeController.instance.refresh(quiet: true),
    ]);
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
    details.remove(id);
    turnInfo.remove(id);
    costs.remove(id);
    organizeOutcomes.remove(id);
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
  bool? _treeDepartmentsBuilt;
  ThinkTree? _tree;

  /// 서버(Edge·DB)와 이 앱이 모두 부서 기능을 지원할 때만 트리를 부서 칸으로 나눈다.
  bool get departmentsReady => rolesReady && status?.departmentWork.ready == true;

  ThinkTree get tree {
    final departments = departmentsReady;
    if (_tree == null ||
        !identical(_treeNodesBuilt, treeNodes) ||
        !identical(_treeConversationsBuilt, conversations) ||
        _treeDepartmentsBuilt != departments) {
      _tree = ThinkTree.build(treeNodes, conversations, departments: departments);
      _treeNodesBuilt = treeNodes;
      _treeConversationsBuilt = conversations;
      _treeDepartmentsBuilt = departments;
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
    unawaited(refreshPendingCounts());
  }

  // ------------------------------------------------------------------ 부서 상태
  // 트리의 부서 캐릭터가 보여 줄 상태. 서버에 따로 저장하지 않고 이 화면이 아는 것으로만 정한다.
  Map<String, int> _pendingCounts = {};
  final Set<ThinkRoleId> collapsedDepartments = {};
  final Set<ThinkRoleId> collapsedDepartmentUnfiled = {};

  /// 지금 진행 중인 부서 협의(call_id → 묻는 부서·질문 받은 부서).
  final Map<String, ({ThinkRoleId from, ThinkRoleId to})> _consults = {};

  Future<void> refreshPendingCounts() async {
    try {
      _pendingCounts = await _api.pendingActionCounts();
      notifyListeners();
    } catch (_) {
      // 다음 트리 갱신 때 다시 읽는다.
    }
  }

  /// 대화의 대기 중 제안 수. 열어 본 대화는 화면이 가진 제안 목록을, 아니면 서버 집계를 쓴다.
  int pendingCountOf(String conversationId) {
    final local = _actions[conversationId];
    if (local != null) return local.where((a) => a.pending).length;
    return _pendingCounts[conversationId] ?? 0;
  }

  ThinkRoleId roleOfConversation(String? id) {
    if (id == null) return conversationRole;
    if (id == selectedId) return conversationRole;
    return conversationById(id)?.thinkRoleId ?? ThinkRoleId.lead;
  }

  /// 대화 한 개의 진행 상태. 답하는 중 > Cursor 작업 > 승인 대기 > 쉬는 중.
  ThinkActivity conversationActivity(String conversationId) {
    if (isStreaming && streamingConversationId == conversationId) return ThinkActivity.answering;
    if (ThinkSendLock.instance.busy(conversationId)) return ThinkActivity.answering;
    if (ThinkCodeController.instance.requestsFor(conversationId).any((r) => r.status.inProgress)) return ThinkActivity.coding;
    if (pendingCountOf(conversationId) > 0) return ThinkActivity.waiting;
    return ThinkActivity.idle;
  }

  /// 부서 캐릭터의 상태. 협의 중 > 답하는 중 > Cursor 작업 > 승인 대기 > 쉬는 중.
  ThinkDepartmentActivity departmentActivity(ThinkRoleId dept) {
    for (final c in _consults.values) {
      if (c.from == dept) return ThinkDepartmentActivity(ThinkActivity.consulting, consultWith: c.to);
      if (c.to == dept) return ThinkDepartmentActivity(ThinkActivity.consulting, consultWith: c.from);
    }
    if (isStreaming && roleOfConversation(streamingConversationId) == dept) {
      return const ThinkDepartmentActivity(ThinkActivity.answering);
    }
    if (ThinkSendLock.instance.busyConversations.any((id) => roleOfConversation(id) == dept)) {
      return const ThinkDepartmentActivity(ThinkActivity.answering);
    }
    final coding = ThinkCodeController.instance.requests
        .where((r) => r.status.inProgress && r.conversationId != null && roleOfConversation(r.conversationId) == dept)
        .length;
    if (coding > 0) return ThinkDepartmentActivity(ThinkActivity.coding, count: coding);
    var pending = 0;
    final ids = {..._pendingCounts.keys, ..._actions.keys};
    for (final id in ids) {
      if (roleOfConversation(id) == dept) pending += pendingCountOf(id);
    }
    if (pending > 0) return ThinkDepartmentActivity(ThinkActivity.waiting, count: pending);
    return const ThinkDepartmentActivity(ThinkActivity.idle);
  }

  void toggleDepartment(ThinkRoleId dept) {
    if (!collapsedDepartments.remove(dept)) collapsedDepartments.add(dept);
    notifyListeners();
  }

  void toggleDepartmentUnfiled(ThinkRoleId dept) {
    if (!collapsedDepartmentUnfiled.remove(dept)) collapsedDepartmentUnfiled.add(dept);
    notifyListeners();
  }

  void _setConversationRoleLocal(String id, ThinkRoleId role) {
    if (conversationById(id)?.thinkRoleId == role) return;
    _replaceConversation(id, (c) => c.copyWith(thinkRoleId: role));
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

  /// [department]는 부서 칸을 쓸 때 최상위 폴더의 부서. 하위 폴더는 상위 폴더 부서를 따른다.
  Future<void> createFolder(String title, {String? parentId, ThinkRoleId? department}) async {
    final t = title.trim();
    if (t.isEmpty) return;
    await _mutateTree(() async {
      await _api.createFolder(
        title: t,
        parentId: parentId,
        sortOrder: tree.allChildren(parentId).length,
        department: departmentsReady ? department : null,
      );
      if (parentId != null) collapsedFolders.remove(parentId);
      if (department != null) collapsedDepartments.remove(department);
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

  /// 부서 칸으로 옮기는 계획이면 옮긴 대화의 역할도 서버가 바꾼다(화면이 먼저 확인 창을 띄운다).
  Future<void> applyDrop(ThinkDropPlan plan) async {
    final dept = plan.department;
    var rolesMayChange = false;
    await _mutateTree(() async {
      if (dept != null && plan.unfile) {
        final convId = plan.conversationId ?? tree.byId[plan.nodeId]?.conversationId;
        if (convId == null) return;
        await _api.moveConversationDepartment(convId, dept);
        rolesMayChange = true;
      } else if (dept != null) {
        await _api.moveTreeNodeDepartment(
          nodeId: plan.nodeId,
          conversationId: plan.nodeId == null ? plan.conversationId : null,
          parentId: plan.parentId,
          index: plan.index,
          department: dept,
        );
        rolesMayChange = true;
      } else if (plan.unfile) {
        await _api.deleteTreeNode(plan.nodeId!);
      } else if (plan.nodeId != null) {
        await _api.moveTreeNode(plan.nodeId!, plan.parentId, plan.index);
      } else {
        await _api.placeConversation(plan.conversationId!, plan.parentId, plan.index);
      }
      if (plan.parentId != null) collapsedFolders.remove(plan.parentId);
      if (dept != null) collapsedDepartments.remove(dept);
    });
    if (rolesMayChange) await _afterRolesChanged();
  }

  /// 서버가 대화 역할을 바꿨을 수 있다(부서 간 옮기기·넘기기 승인). 목록과 열린 대화의 역할을 다시 읽는다.
  Future<void> _afterRolesChanged() async {
    await _refreshConversationsQuietly();
    final id = selectedId;
    if (id != null) await _loadRoleSettings(id);
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

  Future<String> createDocument({
    required String conversationId,
    required String? parentId,
    required String title,
    required String body,
    required List<String> messageIds,
  }) async {
    late String id;
    await _mutateTree(() async {
      id = await _api.createDocument(
        conversationId: conversationId,
        parentId: parentId,
        title: title,
        body: body,
        messageIds: messageIds,
      );
      if (parentId != null) collapsedFolders.remove(parentId);
    });
    return id;
  }

  Future<ThinkDocumentDetail> loadDocument(String nodeId) => _api.getDocument(nodeId);

  Future<void> updateDocument(ThinkDocumentDetail doc, {required String title, required String body}) async {
    await _mutateTree(() async {
      await _api.updateDocument(nodeId: doc.id, expectedVersion: doc.version, title: title, body: body);
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

  @visibleForTesting
  void setMessagesForTest(String conversationId, List<ThinkMessage> messages) {
    _messages[conversationId] = messages;
  }

  void _putAction(ThinkAction a) {
    final list = [...(_actions[a.conversationId] ?? const <ThinkAction>[])];
    final i = list.indexWhere((x) => x.id == a.id);
    if (i >= 0) {
      list[i] = a;
    } else {
      // 서버와 같이, 같은 종류의 대기 중 제안은 새 제안으로 대체된다. 기억 카드는 서로 대체하지 않는다.
      if (a.pending && !a.kind.isMemory) {
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

  /// 개념 초안 변경·기준 고치기 카드 승인(concept_draft_action_apply). 다시 정리는 검토 창이 Edge로 한다.
  Future<ThinkAction> applyConceptDraftAction(ThinkAction a) async {
    final saved = await _api.applyConceptDraftAction(a.id);
    await _afterAction(saved);
    return saved;
  }

  Future<void> rejectAction(ThinkAction a) async {
    _putAction(await _api.rejectAction(a.id));
    organizeErrors.remove(a.id);
    // 나누기 제안을 거절하면 서버가 이 대화의 나누기 제안을 끈다.
    if (a.kind == ThinkActionKind.splitConversation) _setSplitSuggestionsLocal(a.conversationId, false);
  }

  /// 조율본 질문에 답하면 서버가 이전 조율본을 닫고 다시 조율을 시작한다.
  Future<void> revisePlan(ThinkAction a, List<Map<String, String>> answers) async {
    _putAction(await _api.revisePlan(a.id, answers));
    await loadActions(a.conversationId);
    await ThinkCodeController.instance.refresh(quiet: true);
  }

  Future<void> undoAction(ThinkAction a) async {
    final saved = await _api.undoAction(a.id);
    _putAction(saved);
    switch (saved.kind) {
      case ThinkActionKind.excludeContext:
        _setMessageFlags(saved.conversationId, saved.excludedIds, excluded: false);
      case ThinkActionKind.markImportant:
        _setMessageFlags(saved.conversationId, saved.markedIds, important: false);
      default:
        await refreshTree();
    }
  }

  Future<void> _afterAction(ThinkAction a) => _afterActions([a]);

  /// 승인된 제안을 화면에 반영한다. 일괄 승인이면 같은 갱신(트리·기억 등)을 한 번만 한다.
  Future<void> _afterActions(List<ThinkAction> applied) async {
    var code = false, tree = false, conversations = false, memories = false, roles = false, criteria = false;
    final reloadActions = <String>{};
    final reloadDetails = <String>{};
    for (final a in applied) {
      final deleted = a.result?['deleted_id']?.toString();
      if (a.kind == ThinkActionKind.deleteConversation && deleted != null) _forgetConversation(deleted);
      if (!a.deletedSelf) _putAction(a);
      organizeErrors.remove(a.id);
      switch (a.kind) {
        case ThinkActionKind.codeRequest:
        case ThinkActionKind.codeChange:
        case ThinkActionKind.codePlan:
        case ThinkActionKind.deleteCodeRequest:
          code = true;
        case ThinkActionKind.placeConversation:
        case ThinkActionKind.deleteFolder:
        case ThinkActionKind.deleteConversation:
          tree = true;
        case ThinkActionKind.splitConversation:
          tree = true;
          conversations = true;
        case ThinkActionKind.saveMemory:
          memories = true;
        case ThinkActionKind.memoryCardChange:
          // 대상 카드(수정·닫힘)와 대체로 생긴 새 카드는 서버가 바꿨다. 대상이 다른 대화에 있을 수 있다.
          final target = a.memoryTargetConversationId;
          reloadActions.add(a.conversationId);
          if (target != null) reloadActions.add(target);
        case ThinkActionKind.handoverDepartment:
          final to = a.handoverTo;
          if (to != null) _setConversationRoleLocal(a.conversationId, to);
          if (to != null && selectedId == a.conversationId) {
            conversationRole = to;
            extraRefDepartments = extraRefDepartments.where((d) => d != to.department).toList();
          }
          if (to != null) collapsedDepartments.remove(to);
          tree = true;
          roles = true;
        case ThinkActionKind.excludeContext:
          _setMessageFlags(a.conversationId, a.excludedIds, excluded: true);
        case ThinkActionKind.markImportant:
          _setMessageFlags(a.conversationId, a.markedIds, important: true);
        case ThinkActionKind.progressSummary:
          reloadDetails.add(a.conversationId);
        case ThinkActionKind.departmentCriteriaChange:
          criteria = true;
        case ThinkActionKind.conceptDraftChange:
        case ThinkActionKind.conceptCriterionChange:
        case ThinkActionKind.conceptDraftRerun:
          // 초안·기준은 검토 창이 다시 읽는다.
          break;
      }
    }
    await Future.wait([
      if (code) ThinkCodeController.instance.refresh(quiet: true),
      if (tree) refreshTree(),
      if (conversations) _refreshConversationsQuietly(),
      if (memories) refreshMemories(),
      if (roles) _afterRolesChanged(),
      if (criteria) refreshDepartmentCriteria(),
      for (final id in reloadActions) loadActions(id),
      for (final id in reloadDetails) loadDetail(id),
    ]);
  }

  void _setMessageFlags(String conversationId, Iterable<String> ids, {bool? excluded, bool? important}) {
    final wanted = ids.toSet();
    if (wanted.isEmpty) return;
    for (final m in _messages[conversationId] ?? const <ThinkMessage>[]) {
      if (!wanted.contains(m.id)) continue;
      if (excluded != null) m.contextExcluded = excluded;
      if (important != null) m.markedImportant = important;
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ 정리 제안
  // Think가 분류·나누기·기억·부서 넘기기·맥락 제외·중요 표시·진행 요약·부서 기준을 제안하면, 답변 아래에는
  // "정리 제안 N건" 한 줄만 두고 오른쪽 정리 패널에서 골라 한 번에 승인한다. 코드·삭제 제안은 카드 그대로.

  /// 서버(Edge·DB)와 이 앱이 모두 자동 정리 제안을 지원한다. 아니면 예전처럼 카드가 답변 아래에 펼쳐진다.
  bool get organizeReady => status?.autoOrganize.ready == true;

  /// 자동 정리 제안 설정. null이면 아직 읽지 못했다(서버는 읽지 못하면 꺼진 것으로 본다).
  bool? autoOrganizeEnabled;
  bool autoOrganizeSaving = false;

  /// 정리 패널을 열었다. [organizeFocusMessageId]가 있으면 그 답변의 제안을 강조한다.
  bool organizePanelOpen = false;
  String? organizeFocusMessageId;

  /// 대화 화면이 오른쪽에 정리 패널을 붙일 만큼 넓다. 대화 화면이 그릴 때 맞추고, 좁으면 바텀시트로 연다.
  bool organizeDockable = false;

  /// 처리하지 못한 항목의 안내(action id → 문구). 다시 승인하거나 거절하면 지운다.
  final Map<String, String> organizeErrors = {};

  /// 대화별 마지막 일괄 승인 결과.
  final Map<String, ThinkOrganizeOutcome> organizeOutcomes = {};

  ThinkOrganizeOutcome? get selectedOrganizeOutcome => selectedId == null ? null : organizeOutcomes[selectedId];

  /// 답변 아래 카드 대신 정리 패널에서 처리하는 제안. 새 종류 네 개는 늘 패널로 가고(그 서버만 만든다),
  /// 분류·나누기·기억·넘기기는 일괄 승인을 쓸 수 있을 때만 패널로 모은다.
  bool inOrganizePanel(ThinkAction a) => a.pending && a.kind.isOrganize && (organizeReady || a.kind.isOrganizeOnly);

  /// 패널에 모이는 대기 중 제안(선택된 대화, 승인 순서대로).
  List<ThinkAction> get pendingOrganize => _sortOrganize(actions.where(inOrganizePanel));

  /// 답변 하나에 붙은 대기 중 정리 제안.
  List<ThinkAction> pendingOrganizeFor(String? messageId) =>
      messageId == null ? const [] : _sortOrganize(actions.where((a) => a.messageId == messageId && inOrganizePanel(a)));

  static List<ThinkAction> _sortOrganize(Iterable<ThinkAction> list) {
    final out = list.toList();
    int rank(ThinkAction a) {
      final i = kThinkOrganizeOrder.indexOf(a.kind);
      return i < 0 ? kThinkOrganizeOrder.length : i;
    }

    out.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.createdAt.compareTo(b.createdAt);
    });
    return out;
  }

  void openOrganizePanel({String? messageId}) {
    organizePanelOpen = true;
    organizeFocusMessageId = messageId;
    if (autoOrganizeEnabled == null) unawaited(refreshOrganizeSettings());
    notifyListeners();
  }

  void closeOrganizePanel() {
    if (!organizePanelOpen) return;
    organizePanelOpen = false;
    organizeFocusMessageId = null;
    notifyListeners();
  }

  void clearOrganizeOutcome(String conversationId) {
    if (organizeOutcomes.remove(conversationId) != null) notifyListeners();
  }

  /// 고른 제안을 한 번에 승인한다. 서버가 항목마다 따로 실행하므로 일부가 실패해도 나머지는 그대로 반영된다.
  /// 실패한 항목은 대기 상태로 남고 [organizeErrors]에 이유가 붙는다.
  Future<ThinkOrganizeOutcome> applyOrganize(
    String conversationId,
    List<({ThinkAction action, Map<String, dynamic> overrides})> items,
  ) async {
    if (items.isEmpty) return const ThinkOrganizeOutcome();
    ThinkOrganizeOutcome outcome;
    try {
      final results = await _api.applyActionsBatch([
        for (final it in items) {'id': it.action.id, 'overrides': it.overrides},
      ]);
      final applied = <ThinkAction>[];
      final failed = <ThinkBatchItemResult>[];
      final answered = <String>{};
      for (final r in results) {
        answered.add(r.id);
        final action = r.action;
        if (r.ok && action != null) {
          applied.add(action);
        } else {
          failed.add(r);
          organizeErrors[r.id] = ThinkApi.batchErrorMessage(r);
          if (action != null) _putAction(action);
        }
      }
      for (final it in items) {
        if (answered.contains(it.action.id)) continue;
        final missing = ThinkBatchItemResult(id: it.action.id, ok: false, code: 'action_not_found');
        failed.add(missing);
        organizeErrors[it.action.id] = ThinkApi.batchErrorMessage(missing);
      }
      outcome = ThinkOrganizeOutcome(applied: applied, failed: failed);
      organizeOutcomes[conversationId] = outcome;
      notifyListeners();
      await _afterActions(applied);
    } catch (e) {
      outcome = ThinkOrganizeOutcome(error: ThinkApi.codeErrorMessage(e));
      organizeOutcomes[conversationId] = outcome;
      notifyListeners();
    }
    return outcome;
  }

  Future<void> refreshOrganizeSettings() async {
    try {
      final s = await _api.settings();
      autoOrganizeEnabled = s.autoOrganizeColumn ? s.autoOrganizeEnabled : null;
      notifyListeners();
    } catch (_) {
      // 상태 창·패널을 다시 열 때 읽는다.
    }
  }

  /// 실패하면 이유를 돌려준다.
  Future<String?> setAutoOrganize(bool enabled) async {
    autoOrganizeSaving = true;
    notifyListeners();
    try {
      final s = await _api.setAutoOrganize(enabled);
      autoOrganizeEnabled = s.autoOrganizeEnabled;
      return null;
    } catch (e) {
      return '설정을 바꾸지 못했습니다: ${ThinkApi.codeErrorMessage(e)}';
    } finally {
      autoOrganizeSaving = false;
      notifyListeners();
    }
  }

  /// 화면용 중요 표시를 직접 켜고 끈다. AI 맥락에는 영향이 없다.
  Future<void> setMessageImportant(ThinkMessage m, bool important) async {
    final id = m.id;
    final conv = selectedId;
    if (id == null || id.isEmpty || conv == null) return;
    await _api.setMessagesImportant([id], important);
    _setMessageFlags(conv, [id], important: important);
  }

  // ------------------------------------------------------------------ 부서 기준
  Map<ThinkRoleId, ThinkDepartmentCriteria> departmentCriteria = {};
  bool criteriaLoading = false;
  String? criteriaError;

  Future<void> refreshDepartmentCriteria() async {
    criteriaLoading = true;
    notifyListeners();
    try {
      final rows = await _api.listDepartmentCriteria();
      departmentCriteria = {for (final c in rows) c.department: c};
      criteriaError = null;
    } catch (e) {
      criteriaError = '부서 기준을 불러오지 못했습니다: ${ThinkApi.codeErrorMessage(e)}';
    } finally {
      criteriaLoading = false;
      notifyListeners();
    }
  }

  /// 운영자가 직접 고친다. 그사이 다른 곳(제안 승인 등)에서 바뀌었으면 충돌로 막히고, 최신 기준을 다시 읽는다.
  Future<String?> saveDepartmentCriteria(
    ThinkDepartmentCriteria base, {
    required List<String> questions,
    required List<String> risks,
    required List<String> priorityMemoryIds,
  }) async {
    try {
      final saved = await _api.saveDepartmentCriteria(
        base.department,
        questions: questions,
        risks: risks,
        priorityMemoryIds: priorityMemoryIds,
        baseVersion: base.version,
      );
      departmentCriteria = {...departmentCriteria, saved.department: saved};
      notifyListeners();
      return null;
    } catch (e) {
      final message = ThinkApi.codeErrorMessage(e);
      unawaited(refreshDepartmentCriteria());
      return message;
    }
  }

  /// 서버(Edge·DB)와 이 앱이 모두 기억 저장 제안을 지원하는지. 상태 창 표시에만 쓴다(카드는 서버가 만든 것만 보인다).
  bool get memoryProposalsReady => status?.memoryProposals.ready == true;

  // ------------------------------------------------------------------ 역할·자료 스냅샷
  ThinkRoleId conversationRole = ThinkRoleId.lead;
  List<ThinkDepartmentId> extraRefDepartments = [];
  List<String> linkedMemoryIds = [];
  List<String> linkedDocumentNodeIds = [];
  final Map<String, ThinkMessageContextSnapshot> messageSnapshots = {};
  String? selectedAssistantMessageId;

  /// 역할을 저장하는 중(칩을 잠근다).
  bool roleSaving = false;
  final Set<String> _snapshotsLoaded = {};

  /// 서버(Edge·DB)와 이 앱이 모두 역할 기능을 지원할 때만 역할·범위 UI를 켠다.
  bool get rolesReady => status?.thinkRoles.ready == true;

  /// 역할을 바꿀 수 없는 이유. null이면 바꿀 수 있다.
  String? get roleLockReason {
    if (!rolesReady) return '역할 기능 준비가 필요합니다.';
    if (isStreaming) return '답변이 끝난 뒤 바꿀 수 있습니다.';
    if (roleSaving) return '저장 중입니다.';
    return null;
  }

  ThinkMessageContextSnapshot? get selectedMessageSnapshot {
    final id = selectedAssistantMessageId;
    if (id == null) return null;
    return messageSnapshots[id];
  }

  /// 이 답변의 스냅샷을 확인했는데 없다(역할 기능 전 답변). 확인 전이면 false.
  bool roleRecordMissing(ThinkMessage m) {
    final id = m.id;
    final conv = selectedId;
    if (!rolesReady || id == null || id.isEmpty || conv == null || m.isUser) return false;
    if (m.status == ThinkMessageStatus.streaming || !_snapshotsLoaded.contains(conv)) return false;
    return !messageSnapshots.containsKey(id);
  }

  /// 새 대화면 첫 메시지와 함께 서버가 저장한다. 실패하면 저장된 값으로 되돌리고 이유를 돌려준다.
  Future<String?> setConversationRole(ThinkRoleId role) =>
      _saveRole(role, role == ThinkRoleId.lead ? const [] : extraRefDepartments.where((d) => d != role.department).toList());

  Future<String?> toggleExtraRefDepartment(ThinkDepartmentId dept) {
    final next = [...extraRefDepartments];
    next.contains(dept) ? next.remove(dept) : next.add(dept);
    return _saveRole(conversationRole, next);
  }

  Future<String?> _saveRole(ThinkRoleId role, List<ThinkDepartmentId> refs) async {
    final lock = roleLockReason;
    if (lock != null) return lock;
    final id = selectedId;
    final prevRole = conversationRole;
    final prevRefs = extraRefDepartments;
    conversationRole = role;
    extraRefDepartments = refs;
    if (id == null) {
      notifyListeners();
      return null;
    }
    roleSaving = true;
    notifyListeners();
    try {
      await _api.setConversationThinkRole(conversationId: id, role: role, extraRefs: refs);
      _setConversationRoleLocal(id, role);
      // 폴더 부서와 달라지면 서버가 그 대화를 새 부서의 미분류로 뺐다.
      if (departmentsReady && role != prevRole) unawaited(refreshTree());
      return null;
    } catch (e) {
      if (selectedId == id) {
        conversationRole = prevRole;
        extraRefDepartments = prevRefs;
      }
      unawaited(_loadRoleSettings(id));
      return '역할을 저장하지 못했습니다: ${_errText(e)}';
    } finally {
      roleSaving = false;
      notifyListeners();
    }
  }

  Future<String?> linkMemoryToConversation(String memoryId) =>
      _changeLink((id) => _api.linkConversationMemory(id, memoryId), '기억을 연결하지 못했습니다');

  Future<String?> unlinkMemoryFromConversation(String memoryId) =>
      _changeLink((id) => _api.unlinkConversationMemory(id, memoryId), '연결을 끊지 못했습니다');

  Future<String?> linkDocumentToConversation(String documentNodeId) =>
      _changeLink((id) => _api.linkConversationDocument(id, documentNodeId), '문서를 연결하지 못했습니다');

  Future<String?> unlinkDocumentFromConversation(String documentNodeId) =>
      _changeLink((id) => _api.unlinkConversationDocument(id, documentNodeId), '연결을 끊지 못했습니다');

  Future<String?> _changeLink(Future<void> Function(String conversationId) run, String failText) async {
    final id = selectedId;
    if (id == null) return '대화를 시작한 뒤 연결할 수 있습니다.';
    final lock = roleLockReason;
    if (lock != null) return lock;
    try {
      await run(id);
      return null;
    } catch (e) {
      return '$failText: ${_errText(e)}';
    } finally {
      await _loadConversationLinks(id);
    }
  }

  static String _errText(Object e) {
    if (e is ThinkApiException) return e.message;
    final s = e.toString();
    for (final code in ['memory_not_linkable', 'document_not_found', 'conversation_not_found', 'forbidden']) {
      if (s.contains(code)) {
        return switch (code) {
          'memory_not_linkable' => '승인된 기억만 연결할 수 있습니다.',
          'document_not_found' => '문서를 찾을 수 없습니다.',
          'conversation_not_found' => '대화를 찾을 수 없습니다.',
          _ => '권한이 없습니다.',
        };
      }
    }
    return s;
  }

  Future<void> _loadConversationLinks(String id) async {
    if (!rolesReady) {
      linkedMemoryIds = [];
      linkedDocumentNodeIds = [];
      return;
    }
    try {
      final results = await Future.wait([
        _api.listConversationMemoryLinks(id),
        _api.listConversationDocumentLinks(id),
      ]);
      if (selectedId != id) return;
      linkedMemoryIds = results[0];
      linkedDocumentNodeIds = results[1];
      notifyListeners();
    } catch (_) {}
  }

  void selectAssistantMessage(String? messageId) {
    selectedAssistantMessageId = messageId;
    notifyListeners();
  }

  Future<void> _loadRoleSettings(String id) async {
    if (!rolesReady) return;
    try {
      final s = await _api.getConversationRoleSettings(id);
      if (s == null || selectedId != id) return;
      conversationRole = s.thinkRoleId;
      extraRefDepartments = [...s.extraRefDepartments];
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _refreshSnapshots(String convId) async {
    if (!rolesReady) return;
    final msgs = _messages[convId] ?? [];
    final ids = msgs.where((m) => !m.isUser && (m.id ?? '').isNotEmpty).map((m) => m.id!).toList();
    try {
      if (ids.isNotEmpty) messageSnapshots.addAll(await _api.listMessageSnapshots(ids));
      _snapshotsLoaded.add(convId);
      notifyListeners();
    } catch (_) {}
  }

  /// 대화를 고르거나 상태를 다시 읽은 뒤: 저장된 역할·연결·답변 스냅샷을 읽는다.
  void _loadRoleExtras(String id) {
    unawaited(_loadRoleSettings(id));
    unawaited(_loadConversationLinks(id));
    unawaited(_refreshSnapshots(id));
  }

  void _resetRoleState() {
    conversationRole = ThinkRoleId.lead;
    extraRefDepartments = [];
    linkedMemoryIds = [];
    linkedDocumentNodeIds = [];
    selectedAssistantMessageId = null;
  }

  // ------------------------------------------------------------------ 대화 나누기
  final Map<String, ThinkConversationDetail> details = {};

  /// 방금 나누기를 승인해 넘어온 새 대화. 그 대화 위쪽 안내를 펼쳐 보여 준다.
  String? justSplitConversationId;

  ThinkConversationDetail? get selectedDetail => selectedId == null ? null : details[selectedId];

  Future<void> loadDetail(String id) async {
    try {
      final d = await _api.getConversationDetail(id);
      if (d == null) return;
      details[id] = d;
      notifyListeners();
    } catch (_) {
      // 나누기 정보는 다음에 대화를 열 때 다시 읽는다.
    }
  }

  /// 승인하면 서버가 한 트랜잭션으로 새 대화를 만들고 이번 질문·답변을 복사한다. 그 뒤 새 대화로 넘어간다.
  /// [open]이 false면(개념 탭 카드) Think 화면의 선택을 바꾸지 않는다.
  Future<ThinkAction> applySplit(ThinkAction a, {Map<String, dynamic> overrides = const {}, bool open = true}) async {
    final saved = await applyAction(a, overrides: overrides);
    final id = saved.splitConversationId;
    if (id != null && open) await openSplitConversation(id);
    return saved;
  }

  /// 나눠서 생긴 새 대화로 넘어간다. 그 대화 위쪽 안내를 펼쳐 보여 준다.
  Future<void> openSplitConversation(String id) async {
    justSplitConversationId = id;
    await openConversation(id);
  }

  Future<void> setSplitSuggestions(String conversationId, bool enabled) async {
    await _api.setSplitSuggestions(conversationId, enabled);
    _setSplitSuggestionsLocal(conversationId, enabled);
  }

  void _setSplitSuggestionsLocal(String conversationId, bool enabled) {
    final d = details[conversationId];
    if (d == null || d.autoSplitSuggestions == enabled) return;
    details[conversationId] = d.copyWith(autoSplitSuggestions: enabled);
    notifyListeners();
  }

  /// 새 질문이 저장되면 서버(메시지 저장 트리거)가 앞의 나누기 제안을 만료시킨다. 화면도 같이 맞춘다.
  void _expirePendingSplits(String conversationId) {
    final list = _actions[conversationId];
    if (list == null || !list.any((a) => a.pending && a.kind == ThinkActionKind.splitConversation)) return;
    _actions[conversationId] = [
      for (final a in list)
        a.pending && a.kind == ThinkActionKind.splitConversation ? a.copyWith(status: ThinkActionStatus.expired) : a,
    ];
  }

  @visibleForTesting
  void expirePendingSplitsForTest(String conversationId) => _expirePendingSplits(conversationId);

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
    final ids = [
      for (final m in turn)
        if (m.id != null && m.id!.isNotEmpty) m.id!
    ];
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
    justSplitConversationId = null;
    _resetRoleState();
    if (!(isStreaming && _streamingDraft && streamingConversationId == null)) _draft = [];
    messagesError = null;
    notifyListeners();
  }

  Future<void> select(String id) async {
    if (selectedId != id) {
      _resetRoleState();
      organizeFocusMessageId = null;
    }
    selectedId = id;
    if (justSplitConversationId != id) justSplitConversationId = null;
    messagesError = null;
    notifyListeners();
    unawaited(refreshCost(id));
    unawaited(loadActions(id));
    unawaited(loadDetail(id));
    unawaited(_loadRoleSettings(id));
    unawaited(_loadConversationLinks(id));
    if (isStreaming && streamingConversationId == id) return;
    messagesLoading = !_messages.containsKey(id);
    notifyListeners();
    try {
      final loaded = await _api.listMessages(id);
      if (!(isStreaming && streamingConversationId == id)) _messages[id] = loaded;
      if (selectedId == id) unawaited(_refreshSnapshots(id));
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
  bool webSearch = true;
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
        problems.add('$name: ${ThinkApi.attachmentTypesHint}');
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
      !isStreaming && uploadingCount == 0 && composer.text.trim().isNotEmpty && !forbidden && !sendLockedElsewhere;

  /// 개념 탭이 고른 대화로 답변을 받는 중이다. 끝날 때까지 여기서는 보내지 않는다.
  bool get sendLockedElsewhere => ThinkSendLock.instance.busyElsewhere(selectedId, ThinkSendLock.thinkScreen);

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
    const owner = ThinkSendLock.thinkScreen;
    var lockedId = convId;
    if (convId != null && !ThinkSendLock.instance.acquire(convId, owner)) return;

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
        webSearch: webSearch && (status?.webSearchEnabled ?? true),
        newConversationRole: convId == null && rolesReady ? conversationRole : null,
        newConversationRefs: convId == null && rolesReady ? extraRefDepartments : const [],
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
      if (lockedId != null) ThinkSendLock.instance.release(lockedId, owner);
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
            notice = noticeText(d);
            notifyListeners();
          case 'conversation':
            final id = d['conversation_id']?.toString();
            if (id == null) break;
            conversationId = id;
            if (lockedId == null && ThinkSendLock.instance.acquire(id, owner)) lockedId = id;
            user.id = d['user_message_id']?.toString();
            final ctx = d['context'] is Map ? Map<String, dynamic>.from(d['context'] as Map) : null;
            turnInfo[id] = ThinkTurnInfo(context: ctx, model: d['model']?.toString());
            _expirePendingSplits(id);
            final features = parseThinkFeatures(d['features']);
            if (features.isNotEmpty) status = status?.withFeatures(features);
            if (d['split_suggestions'] is bool) _setSplitSuggestionsLocal(id, d['split_suggestions'] as bool);
            final organize = d['auto_organize'];
            if (organize is Map && organize['enabled'] is bool) autoOrganizeEnabled = organize['enabled'] as bool;
            final role = d['think_role'] is Map ? Map<String, dynamic>.from(d['think_role'] as Map) : null;
            if (role != null && (selectedId == id || (selectedId == null && _streamingDraft))) {
              final saved = ThinkConversationRoleSettings.fromRow({
                'think_role_id': role['id'],
                'extra_ref_departments': role['extra_ref_departments'],
              });
              conversationRole = saved.thinkRoleId;
              extraRefDepartments = [...saved.extraRefDepartments];
            }
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
                    thinkRoleId: conversationRole,
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
            if (action != null) {
              _putAction(action);
              if (action.kind == ThinkActionKind.codePlan) unawaited(ThinkCodeController.instance.refresh(quiet: true));
            }
          case 'consult':
            final callId = d['call_id']?.toString();
            if (callId == null) break;
            if (d['status'] == 'running') {
              _consults[callId] = (
                from: ThinkRoleId.parse(d['from']?.toString()),
                to: ThinkRoleId.parse(d['to']?.toString()),
              );
            } else {
              _consults.remove(callId);
            }
            notifyListeners();
          case 'title':
            final id = d['conversation_id']?.toString();
            final title = d['title']?.toString();
            if (id != null && title != null && title.isNotEmpty) {
              _replaceConversation(id, (c) => c.copyWith(title: title));
            }
          case 'done':
            finished = true;
            assistant.id = d['assistant_message_id']?.toString();
            assistant.status = d['status'] == 'stopped' ? ThinkMessageStatus.stopped : ThinkMessageStatus.complete;
            assistant.model = d['model']?.toString();
            assistant.sources = (d['sources'] is List ? d['sources'] as List : const [])
                .whereType<Map>()
                .map((s) => ThinkSource.fromJson(Map<String, dynamic>.from(s)))
                .toList();
            assistant.attachments = _attachmentsOf(d);
            assistant.toolCalls = [
              for (final t in assistant.toolCalls)
                if (!t.running) t
            ];
            final id = conversationId;
            if (id != null) {
              turnInfo[id] = (turnInfo[id] ?? const ThinkTurnInfo()).copyWith(
                usage: d['usage'] is Map ? Map<String, dynamic>.from(d['usage'] as Map) : null,
                costUsd: (d['cost_usd'] as num?)?.toDouble(),
                model: d['model']?.toString(),
                webSearchCalls: (d['web_search_calls'] as num?)?.toInt() ?? 0,
              );
              _attachActions(id, d['action_ids'], assistant.id);
              unawaited(_refreshSnapshots(id));
              if (assistant.id != null && selectedId == id) selectedAssistantMessageId = assistant.id;
            }
            notifyListeners();
          case 'error':
            finished = true;
            assistant.id = d['assistant_message_id']?.toString();
            assistant.status = ThinkMessageStatus.error;
            assistant.errorText = d['message']?.toString() ?? '답변을 만들지 못했습니다.';
            assistant.attachments = _attachmentsOf(d);
            assistant.toolCalls = [
              for (final t in assistant.toolCalls)
                if (!t.running) t
            ];
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
        assistant.toolCalls = [
          for (final t in assistant.toolCalls)
            if (!t.running) t
        ];
      }
      stream.cancel();
      _stream = null;
      streamingConversationId = null;
      _streamingDraft = false;
      _consults.clear();
      final locked = lockedId;
      if (locked != null) ThinkSendLock.instance.release(locked, owner);
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

  static String? noticeText(Map<String, dynamic> d) => switch (d['code']) {
        'budget_warning' => '이번 달 사용 한도를 넘었습니다(경고 모드). 사용량 탭을 확인하세요.',
        'web_search_disabled' => '웹 검색이 꺼져 있어 검색 없이 답합니다. 사용량 탭에서 켤 수 있습니다.',
        'role_not_applied' => '고른 역할을 저장하지 못해 총괄로 답합니다.',
        'spreadsheet_unavailable' => '엑셀을 열 실행 환경을 준비하지 못해 엑셀 없이 답합니다. 잠시 뒤 다시 보내 주세요.',
        'answer_files_failed' => 'Think가 만든 파일을 옮기지 못했습니다. 필요하면 다시 요청해 주세요.',
        _ => d['message']?.toString(),
      };

  // ------------------------------------------------------------------ 다른 화면(개념 탭)의 답변
  // 제안 카드는 대화별로 여기 한 곳에 모은다. 개념 탭이 받은 제안도 Think 화면과 같은 카드·승인 흐름을 쓴다.

  /// 다른 화면이 같은 대화에 새 질문을 보냈다. 서버처럼 앞의 나누기 제안을 만료시킨다.
  void beginExternalTurn(String conversationId) => _expirePendingSplits(conversationId);

  void putStreamedAction(ThinkAction a) {
    _putAction(a);
    if (a.kind == ThinkActionKind.codePlan) unawaited(ThinkCodeController.instance.refresh(quiet: true));
  }

  void attachStreamedActions(String conversationId, dynamic ids, String? messageId) {
    _attachActions(conversationId, ids, messageId);
    notifyListeners();
  }

  /// 다른 화면이 받은 답변을 Think 화면에도 반영한다. 읽어 둔 대화만 다시 읽는다.
  void _onSendReleased(ThinkSendRelease r) {
    if (r.owner == ThinkSendLock.thinkScreen) return;
    final id = r.conversationId;
    if (_messages.containsKey(id)) {
      unawaited(() async {
        await _reloadIfIdle(id);
        if (selectedId == id) await _refreshSnapshots(id);
      }());
    } else {
      unawaited(loadActions(id));
    }
    if (costs.containsKey(id)) unawaited(refreshCost(id));
    if (_started) unawaited(_refreshConversationsQuietly());
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
    final withScope = rolesReady;
    final scopeError = withScope ? draft.scopeError : null;
    if (scopeError != null) throw ThinkApiException('scope_department_required', scopeError);
    final saved = existing == null
        ? await _api.createMemory(draft, withScope: withScope)
        : await _api.updateMemory(existing.id, existing.version, draft.toRow(withScope: withScope));
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
    memories = idx >= 0 ? [for (final e in memories) e.id == saved.id ? saved : e] : [saved, ...memories];
    notifyListeners();
  }
}
