import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/think/think_clipboard_files.dart';
import '../../services/think/think_code_controller.dart';
import '../../services/think/think_action_models.dart';
import '../../services/think/think_api.dart';
import '../../services/think/think_code_models.dart';
import '../../services/think/think_controller.dart';
import '../../services/think/think_models.dart';
import 'think_action_cards.dart';
import 'think_code_request_dialog.dart';
import 'think_code_requests_dialog.dart';
import 'think_decision_dialog.dart';
import 'think_materials_panel.dart';
import 'think_memory_feedback_dialog.dart';
import 'think_message_tile.dart';
import 'think_organize_panel.dart';
import 'think_role_bar.dart';
import 'think_split_views.dart';
import 'think_status_dialog.dart';
import 'think_style.dart';
import 'think_tree_dialogs.dart';
import 'think_tree_panel.dart';

class ThinkChatTab extends StatefulWidget {
  const ThinkChatTab({super.key});

  @override
  State<ThinkChatTab> createState() => _ThinkChatTabState();
}

class _ThinkChatTabState extends State<ThinkChatTab> {
  static const _suggestions = [
    '우리 교육철학에 맞는 숙제 피드백 방식을 같이 정리해 보자',
    '중2 일차함수 단원을 어떤 순서로 가르치면 좋을지 초안을 짜 줘',
    '지금까지 확정한 결정들 중에 서로 부딪치는 게 있는지 점검해 줘',
  ];

  final ScrollController _scroll = ScrollController();
  final FocusNode _composerFocus = FocusNode();
  bool _stickToBottom = true;
  bool _dragging = false;
  bool _showContext = true;
  bool _contextVisible = false;
  bool _showTechnical = true;
  String? _lastSelected;
  int _lastCount = -1;
  int _lastReveal = 0;
  // 대화에 들어오면 목록이 만들어지는 동안 높이가 계속 늘어나므로,
  // 한 번의 점프로는 맨 위에 남는다. 늘어남이 멈출 때까지 바닥을 따라간다.
  int _pinToBottom = 0;
  final Map<String, GlobalKey> _messageKeys = {};

  ThinkController get _c => ThinkController.instance;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      _stickToBottom = pos.maxScrollExtent - pos.pixels < 120;
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  void _followBottom() {
    final selectedChanged = _lastSelected != _c.selectedId;
    final countChanged = _lastCount != _c.messages.length;
    _lastSelected = _c.selectedId;
    _lastCount = _c.messages.length;
    if (!(selectedChanged || countChanged || (_c.streamingHere && _stickToBottom))) return;
    if (selectedChanged || countChanged) {
      _stickToBottom = true;
      _pinToBottom = 12;
    }
    if (_pinToBottom > 0 || _c.streamingHere) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pinBottomStep());
    }
  }

  void _pinBottomStep() {
    if (!mounted || !_stickToBottom || !_scroll.hasClients) return;
    final pos = _scroll.position;
    final gap = pos.maxScrollExtent - pos.pixels;
    if (gap > 1) _scroll.jumpTo(pos.maxScrollExtent);
    if (_pinToBottom <= 0) return;
    _pinToBottom -= 1;
    // 목록이 아직 만들어지는 중이면 높이가 늘어난다. 바닥이 안정될 때까지 다시 맞춘다.
    if (gap > 1 || _pinToBottom > 4) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pinBottomStep());
    }
  }

  void _followReveal() {
    if (_lastReveal == _c.revealSerial) return;
    _lastReveal = _c.revealSerial;
    final id = _c.revealMessageId;
    if (id == null) return;
    _stickToBottom = false;
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealTo(id));
  }

  /// 목록은 화면에 보이는 메시지만 만들기 때문에, 대략 위치로 옮긴 뒤 만들어지면 정확히 맞춘다.
  void _revealTo(String id, [int attempt = 0]) {
    if (!mounted) return;
    final ctx = _messageKeys[id]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, alignment: 0.1, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
      return;
    }
    if (attempt >= 6 || !_scroll.hasClients) return;
    final list = _c.messages;
    final idx = list.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    final pos = _scroll.position;
    _scroll.jumpTo(pos.maxScrollExtent * idx / math.max(1, list.length - 1));
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealTo(id, attempt + 1));
  }

  void _newConversation() {
    _c.startNew();
    _composerFocus.requestFocus();
  }

  Future<void> _toggleExcluded(int index) async {
    final m = _c.messages[index];
    try {
      await _c.setTurnExcluded(index, !m.contextExcluded);
    } catch (e) {
      if (mounted) showThinkSnack(context, '바꾸지 못했습니다: $e', error: true);
    }
  }

  Future<void> _toggleImportant(ThinkMessage m) async {
    try {
      await _c.setMessageImportant(m, !m.markedImportant);
    } catch (e) {
      if (mounted) showThinkSnack(context, '바꾸지 못했습니다: $e', error: true);
    }
  }

  Future<void> _setAutoOrganize(bool enabled) async {
    final err = await _c.setAutoOrganize(enabled);
    if (err != null && mounted) showThinkSnack(context, err, error: true);
  }

  Future<void> _excerpt(int index) async {
    final id = _c.selectedId;
    if (id == null) return;
    final saved = await ThinkExcerptDialog.create(context, conversationId: id, messages: _c.messages, index: index);
    if (saved && mounted) showThinkSnack(context, '트리에 발췌를 남겼습니다.');
  }

  Future<void> _document(int index) async {
    final id = _c.selectedId;
    if (id == null) return;
    final saved = await ThinkDocumentDialog.create(context, conversationId: id, messages: _c.messages, index: index);
    if (saved && mounted) showThinkSnack(context, '폴더에 종합 문서를 저장했습니다.');
  }

  Future<void> _codeRequest(int index) async {
    final saved = await ThinkCodeRequestDialog.fromTurn(
      context,
      conversationId: _c.selectedId,
      messages: _c.messages,
      index: index,
    );
    if (saved == null || !mounted) return;
    showThinkSnack(
      context,
      saved.status == ThinkCodeStatus.draft
          ? '초안으로 저장했습니다. 답변 아래 카드에서 보낼 수 있습니다.'
          : '코드 조사 요청을 보냈습니다. 진행 상황은 답변 아래 카드에 표시됩니다.',
    );
  }

  Future<void> _memoryFeedback(int index) async {
    final convId = _c.selectedId;
    if (convId == null) return;
    final messages = _c.messages;
    final m = messages[index];
    final assistantId = m.id;
    if (assistantId == null || assistantId.isEmpty) return;
    final userIds = [
      for (final ti in thinkTurnIndices(messages, index))
        if (messages[ti].isUser) messages[ti].id,
    ].whereType<String>().where((id) => id.isNotEmpty).toList();
    await ThinkMemoryFeedbackDialog.show(
      context,
      conversationId: convId,
      assistantMessageId: assistantId,
      userMessageIds: userIds,
    );
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif', 'pdf', 'xlsx'],
      withData: false,
    );
    if (result == null) return;
    await _addPaths(result.files.map((f) => f.path ?? '').where((p) => p.isNotEmpty));
  }

  Future<void> _addPaths(Iterable<String> paths) async {
    final problems = await _c.addFiles(paths);
    if (problems.isNotEmpty && mounted) showThinkSnack(context, problems.join('\n'), error: true);
  }

  void _dropped(DropDoneDetails detail) {
    setState(() => _dragging = false);
    final paths = detail.files.map((f) => f.path).where((p) => p.isNotEmpty).toList();
    if (paths.isEmpty) {
      showThinkSnack(context, thinkDropNoFilesMessage, error: true);
      return;
    }
    _addPaths(paths);
  }

  /// Ctrl+V: 클립보드에 글자가 없을 때만 이미지·복사한 파일을 첨부한다(글자는 입력창이 그대로 붙여 넣는다).
  Future<void> _pasteFiles() async {
    if (_c.forbidden || await Clipboard.hasStrings()) return;
    final clip = await ThinkClipboardFiles.read();
    if (clip.paths.isEmpty) return;
    try {
      await _addPaths(clip.paths);
    } finally {
      await clip.dispose();
    }
  }

  Future<void> _send() async {
    await _c.send();
    _composerFocus.requestFocus();
  }

  Future<void> _openDecision() async {
    final id = _c.selectedId;
    if (id == null) return;
    final saved = await ThinkDecisionDialog.show(context, conversationId: id);
    if (saved != null && mounted) {
      showThinkSnack(
        context,
        saved.status == ThinkMemoryStatus.active ? '결정을 확정했습니다: ${saved.title}' : '초안으로 저장했습니다: ${saved.title}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        _followBottom();
        _followReveal();
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1180;
            // 넓으면 정리 패널을 맥락 패널 자리에 붙이고, 좁으면 바텀시트로 연다.
            _c.organizeDockable = wide;
            final organizeDocked = wide && _c.organizePanelOpen;
            _contextVisible = wide && _showContext && !organizeDocked;
            // 좁은 화면에서는 트리를 접어 대화 영역을 먼저 확보한다.
            final treeOpen = _c.treePanelOpen ?? constraints.maxWidth >= 960;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (treeOpen)
                  SizedBox(
                    width: wide ? 280 : 240,
                    child: ThinkTreePanel(
                      onNewConversation: _newConversation,
                      onCollapse: () => _c.setTreePanelOpen(false),
                    ),
                  )
                else
                  _collapsedTree(),
                const SizedBox(width: 16),
                Expanded(child: _chatPanel()),
                if (organizeDocked) ...[
                  const SizedBox(width: 16),
                  SizedBox(width: 340, child: ThinkOrganizePanel(onClose: _c.closeOrganizePanel)),
                ] else if (_contextVisible) ...[
                  const SizedBox(width: 16),
                  SizedBox(width: 280, child: _contextPanel()),
                ],
              ],
            );
          },
        );
      },
    );
  }

  // ------------------------------------------------------------ 접힌 목록
  Widget _collapsedTree() {
    return SizedBox(
      width: 56,
      child: ThinkPanel(
        child: Column(
          children: [
            const SizedBox(height: 8),
            IconButton(
              tooltip: '대화 목록 펼치기',
              color: kThinkSub,
              onPressed: () => _c.setTreePanelOpen(true),
              icon: const Icon(Icons.keyboard_double_arrow_right),
            ),
            const SizedBox(height: 4),
            IconButton(
              tooltip: '새 대화',
              color: kThinkAccent,
              onPressed: _c.forbidden ? null : _newConversation,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 대화창
  Widget _chatPanel() {
    final conv = _c.selected;
    final cost = conv == null ? null : _c.costs[conv.id];
    final detail = _c.selectedDetail;
    final originId = detail?.splitFromConversationId;
    return DropTarget(
      // 기억·사용량 탭에 있을 때(IndexedStack에 남아 있음)는 받지 않는다.
      enable: _c.tab == ThinkController.tabChat && !_c.forbidden,
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _dropped,
      child: ThinkPanel(
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          conv?.title ?? '새 대화',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800),
                        ),
                      ),
                      if (cost != null) ...[
                        Tooltip(
                          message: '이 대화에서 쓴 AI 비용 (제목 생성 포함)',
                          child: ThinkBadge('이 대화 ${formatUsd(cost)}'),
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (_c.pendingOrganize.isNotEmpty) ...[
                        ThinkOrganizeCountButton(
                          count: _c.pendingOrganize.length,
                          onOpen: () => openThinkOrganize(context),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Tooltip(
                        message: '대화 내용을 결정 초안으로 정리합니다. 저장은 직접 확인한 뒤에 합니다.',
                        child: OutlinedButton.icon(
                          onPressed: conv != null && !_c.streamingHere && _c.messages.isNotEmpty && !_c.forbidden
                              ? _openDecision
                              : null,
                          style: thinkOutlineButton(),
                          icon: const Icon(Icons.fact_check_outlined, size: 16),
                          label: const Text('결정으로 정리'),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: _contextVisible ? '맥락 패널 숨기기' : '맥락 패널 보기',
                        color: kThinkSub,
                        onPressed: () {
                          // 정리 패널이 그 자리에 있으면 닫고 맥락 패널을 보인다.
                          if (_c.organizeDockable && _c.organizePanelOpen) {
                            _c.closeOrganizePanel();
                            setState(() => _showContext = true);
                            return;
                          }
                          setState(() => _showContext = !_showContext);
                        },
                        icon: Icon(_contextVisible ? Icons.view_sidebar : Icons.view_sidebar_outlined),
                      ),
                    ],
                  ),
                ),
                const Divider(color: kThinkBorder, height: 1),
                if (_c.rolesReady)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 12, 24, 0),
                    child: ThinkRoleBar(),
                  ),
                if (detail != null && detail.isSplit)
                  ThinkSplitBanner(
                    detail: detail,
                    justSplit: _c.justSplitConversationId == detail.id,
                    onOpenOriginal: originId == null ? null : () => _c.openConversation(originId),
                  ),
                Expanded(child: _messageList()),
                if (_c.notice != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                    child: ThinkNotice(
                      text: _c.notice!,
                      onClose: () => setState(() => _c.notice = null),
                    ),
                  ),
                if (_c.sendError != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                    child: ThinkNotice(
                      text: _c.sendError!,
                      color: kThinkError,
                      icon: Icons.error_outline,
                      onClose: _c.clearSendError,
                    ),
                  ),
                _composer(),
              ],
            ),
            if (_dragging)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      color: kThinkAccent.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: kThinkAccent, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      '여기에 놓으면 첨부됩니다 (이미지·PDF·엑셀 파일, 최대 6개)',
                      style: TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _messageList() {
    if (_c.messagesLoading) return const Center(child: CircularProgressIndicator(color: kThinkAccent));
    if (_c.messagesError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ThinkNotice(text: _c.messagesError!, color: kThinkError, icon: Icons.error_outline),
        ),
      );
    }
    final messages = _c.messages;
    if (messages.isEmpty) return _emptyState();
    final canAct = _c.selectedId != null && !_c.streamingHere && !_c.forbidden;
    return ListenableBuilder(
      listenable: ThinkCodeController.instance,
      builder: (context, _) {
        final cards = _cardsByMessage(messages);
        return SelectionArea(
          child: ListView.separated(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            itemCount: messages.length,
            separatorBuilder: (_, __) => const SizedBox(height: 24),
            itemBuilder: (_, i) {
              final m = messages[i];
              final id = m.id;
              final hasId = id != null && id.isNotEmpty;
              final turnActions = canAct && hasId && !m.isUser && m.status != ThinkMessageStatus.streaming;
              final canMark = canAct && hasId && _c.organizeReady && m.status != ThinkMessageStatus.streaming;
              final snap = hasId && !m.isUser ? _c.messageSnapshots[id] : null;
              final canShowMaterials = _c.rolesReady && !m.isUser && hasId && m.status != ThinkMessageStatus.streaming;
              final tile = ThinkMessageTile(
                key: hasId ? _messageKeys.putIfAbsent(id, GlobalKey.new) : null,
                message: m,
                roleSnapshot: snap,
                roleRecordMissing: _c.roleRecordMissing(m),
                materialsSelected: hasId && _c.selectedAssistantMessageId == id,
                highlighted: hasId && _c.highlightedMessageIds.contains(id),
                onSelect: canShowMaterials ? () => _showMaterials(id) : null,
                onToggleExcluded: turnActions ? () => _toggleExcluded(i) : null,
                onToggleImportant: canMark ? () => _toggleImportant(m) : null,
                onExcerpt: turnActions ? () => _excerpt(i) : null,
                onDocument: turnActions ? () => _document(i) : null,
                onCodeRequest: turnActions ? () => _codeRequest(i) : null,
                onMemoryFeedback: turnActions ? () => _memoryFeedback(i) : null,
              );
              final below = [...?cards[hasId ? id : null], if (i == messages.length - 1) ...?cards['']];
              final source = m.sourceMessageId;
              if (below.isEmpty && source == null) return tile;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (source != null) ...[_copiedLabel(m, source), const SizedBox(height: 8)],
                  tile,
                  for (final c in below) ...[const SizedBox(height: 12), c],
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// 답변 아래에 붙일 작업 카드. 키 ''는 아직 답변에 붙지 않은 것(스트리밍 중 제안 등)으로 맨 아래에 둔다.
  /// AI 제안으로 만든 코드 요청은 제안 카드가 그리고, 직접 만든 요청(조사 버튼)은 출처 답변 아래에 따로 그린다.
  Map<String, List<Widget>> _cardsByMessage(List<ThinkMessage> messages) {
    final ids = {
      for (final m in messages)
        if ((m.id ?? '').isNotEmpty) m.id!
    };
    final out = <String, List<Widget>>{};
    void put(String? messageId, Widget w) =>
        out.putIfAbsent(messageId != null && ids.contains(messageId) ? messageId : '', () => []).add(w);

    final actions = _c.actions;
    final linked = {
      for (final a in actions)
        if (a.codeRequestId != null) a.codeRequestId!
    };
    // 대기 중인 정리 제안은 카드 대신 답변마다 "정리 제안 N건" 한 줄로 모은다(내용·승인은 정리 패널).
    final organize = <String, List<ThinkAction>>{};
    for (final a in actions) {
      if (_c.inOrganizePanel(a)) {
        final key = a.messageId != null && ids.contains(a.messageId) ? a.messageId! : '';
        organize.putIfAbsent(key, () => []).add(a);
        continue;
      }
      put(a.messageId, ThinkActionCard(key: ValueKey('action-${a.id}'), action: a));
    }
    for (final e in organize.entries) {
      out.putIfAbsent(e.key, () => []).insert(
            0,
            ThinkOrganizeEntry(
              key: ValueKey('organize-${e.key}'),
              actions: e.value,
              failed: e.value.where((a) => _c.organizeErrors.containsKey(a.id)).length,
              onOpen: () => openThinkOrganize(context, messageId: e.key.isEmpty ? null : e.key),
            ),
          );
    }
    final convId = _c.selectedId;
    if (convId != null) {
      final own = ThinkCodeController.instance.requestsFor(convId).where((r) => !linked.contains(r.id)).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      for (final r in own) {
        final source = r.sourceMessageIds.lastWhere(ids.contains, orElse: () => '');
        put(source, ThinkCodeRequestCard(key: ValueKey('code-${r.id}'), request: r));
      }
    }
    return out;
  }

  /// 나눌 때 원본에서 복사한 메시지. 원본의 작업 카드는 따라오지 않고, 원본 메시지로 가는 길만 남긴다.
  Widget _copiedLabel(ThinkMessage m, String sourceId) {
    final originId = _c.selectedDetail?.splitFromConversationId;
    return Align(
      alignment: m.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.content_copy_outlined, size: 14, color: kThinkHint),
          const SizedBox(width: 8),
          const Text('원본 대화에서 복사한 메시지', style: TextStyle(color: kThinkHint, fontSize: 12)),
          if (originId != null) ...[
            const SizedBox(width: 8),
            InkWell(
              onTap: () => _c.revealMessages(originId, [sourceId]),
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text('원본에서 보기', style: TextStyle(color: kThinkLink, fontSize: 12)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.forum_outlined, size: 40, color: kThinkAccent),
              const SizedBox(height: 16),
              const Text(
                '무엇이든 같이 생각해 봐요',
                style: TextStyle(color: kThinkText, fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                'Think는 교육철학과 확정한 결정을 기억한 채로 답합니다.\n'
                '중요한 결론이 나면 "결정으로 정리"로 남겨 두세요. 다음 대화부터 반영됩니다.\n'
                '코드 조사·수정이나 대화 분류도 여기서 부탁하세요. 실행 전에 카드로 보여 주고 승인을 받습니다.',
                textAlign: TextAlign.center,
                style: TextStyle(color: kThinkSub, fontSize: 13, height: 1.6),
              ),
              const SizedBox(height: 24),
              for (final s in _suggestions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InkWell(
                    onTap: () {
                      _c.composer.text = s;
                      _c.composer.selection = TextSelection.collapsed(offset: s.length);
                      _composerFocus.requestFocus();
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: kThinkBorder),
                      ),
                      child: Text(s, style: const TextStyle(color: kThinkSub, fontSize: 13)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _composer() {
    final status = _c.status;
    final webSearchAllowed = status?.webSearchEnabled ?? true;
    final model = status == null ? null : (_c.deep ? status.models['deep'] : status.models['primary']);
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_c.pendingAttachments.isNotEmpty || _c.uploadingCount > 0) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final a in _c.pendingAttachments)
                  ThinkAttachmentChip(attachment: a, onRemove: () => _c.removePending(a)),
                if (_c.uploadingCount > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: kThinkBorder),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: kThinkAccent),
                        ),
                        const SizedBox(width: 8),
                        Text('업로드 중 ${_c.uploadingCount}개', style: const TextStyle(color: kThinkSub, fontSize: 12)),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_c.pendingAttachments.any((a) => a.isSpreadsheet)) ...[
              const ThinkNotice(
                text: '엑셀은 Think가 파이썬으로 열어 분석합니다. 이름·연락처·주소처럼 질문에 필요 없는 개인정보 열은 지우고 올려 주세요.',
                icon: Icons.privacy_tip_outlined,
              ),
              const SizedBox(height: 8),
            ],
          ],
          Focus(
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              if (isThinkPasteKey(event.logicalKey, HardwareKeyboard.instance)) {
                _pasteFiles();
                return KeyEventResult.ignored;
              }
              if (event.logicalKey != LogicalKeyboardKey.enter && event.logicalKey != LogicalKeyboardKey.numpadEnter) {
                return KeyEventResult.ignored;
              }
              if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
              final composing = _c.composer.value.composing;
              if (composing.isValid && !composing.isCollapsed) return KeyEventResult.ignored;
              if (_c.canSend) _send();
              return KeyEventResult.handled;
            },
            child: TextField(
              controller: _c.composer,
              focusNode: _composerFocus,
              enabled: !_c.forbidden,
              minLines: 1,
              maxLines: 8,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(color: kThinkText, fontSize: 14, height: 1.5),
              decoration: thinkInputDecoration(hint: '메시지 입력 (Enter 보내기 · Shift+Enter 줄바꿈 · 파일은 끌어다 놓기 · 이미지는 Ctrl+V)'),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                tooltip: '이미지·PDF·엑셀 첨부',
                color: kThinkSub,
                onPressed: _c.forbidden ? null : _pickFiles,
                icon: const Icon(Icons.attach_file),
              ),
              const SizedBox(width: 4),
              ThinkToggleChip(
                label: '웹 검색',
                icon: Icons.travel_explore,
                selected: _c.webSearch && webSearchAllowed,
                enabled: webSearchAllowed,
                tooltip: webSearchAllowed ? '필요하면 웹을 검색하고 출처를 붙입니다. 검색 1회당 비용이 추가됩니다.' : '사용량 탭에서 웹 검색이 꺼져 있습니다.',
                onChanged: _c.setWebSearch,
              ),
              const SizedBox(width: 8),
              ThinkToggleChip(
                label: '깊게 생각',
                icon: Icons.psychology_alt_outlined,
                selected: _c.deep,
                tooltip: '더 큰 모델로 오래 생각합니다. 비용과 시간이 더 듭니다.',
                onChanged: _c.setDeep,
              ),
              const Spacer(),
              if (model != null) ...[
                Text(model, style: const TextStyle(color: kThinkHint, fontSize: 12)),
                const SizedBox(width: 12),
              ],
              ListenableBuilder(
                listenable: _c.composer,
                builder: (context, _) {
                  if (_c.streamingHere) {
                    return ElevatedButton.icon(
                      onPressed: _c.stop,
                      style: thinkPrimaryButton(color: kThinkError),
                      icon: const Icon(Icons.stop_rounded, size: 18),
                      label: const Text('중지'),
                    );
                  }
                  return ElevatedButton.icon(
                    onPressed: _c.canSend ? _send : null,
                    style: thinkPrimaryButton(),
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: Text(_c.isStreaming
                        ? '다른 대화 답변 중'
                        : _c.sendLockedElsewhere
                            ? '개념 탭에서 답변 중'
                            : '보내기'),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 답변의 '자료' 버튼. 맥락 패널이 보이면 패널에, 좁은 화면이면 창으로 보여 준다.
  void _showMaterials(String messageId) {
    _c.selectAssistantMessage(messageId);
    if (_contextVisible) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kThinkBg,
        shape: thinkDialogShape,
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: ListenableBuilder(listenable: _c, builder: (context, _) => const ThinkMaterialsPanel()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기', style: TextStyle(color: kThinkSub))),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 맥락 패널
  Widget _contextPanel() {
    final info = _c.selectedTurnInfo;
    final ctx = info?.context;
    final usage = info?.usage;
    final relevantIds =
        (ctx?['relevant'] is List ? ctx!['relevant'] as List : const []).map((e) => e.toString()).toList();
    int n(dynamic v) => v is num ? v.toInt() : 0;
    final excluded = _c.selectedId == null ? 0 : _c.messages.where((m) => m.contextExcluded).length;
    final summary = _c.selectedDetail?.progressSummary;
    return ThinkPanel(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_c.rolesReady) ...[
            const ThinkMaterialsPanel(),
            const SizedBox(height: 16),
            const Divider(color: kThinkBorder, height: 1),
            const SizedBox(height: 16),
          ] else if (_c.status != null) ...[
            ThinkFeatureStatusView(feature: _c.status!.thinkRoles, label: '역할·자료 범위', reason: thinkRolesFeatureReason),
            const SizedBox(height: 16),
          ],
          if (summary != null) ...[
            _progressSummarySection(summary),
            const SizedBox(height: 16),
            const Divider(color: kThinkBorder, height: 1),
            const SizedBox(height: 16),
          ],
          const Text('이번 답변에 쓴 맥락', style: TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (ctx == null)
            const Text(
              '메시지를 보내면 AI가 참고한 기억과 대화 범위가 여기에 표시됩니다.',
              style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
            )
          else ...[
            _kv('교육철학·정체성', '${n(ctx['identity'])}개'),
            _kv('원칙', '${n(ctx['principles'])}개'),
            _kv('최근 결정', '${n(ctx['decisions'])}개'),
            _kv(
              '대화 기록',
              n(ctx['history_dropped']) > 0
                  ? '${n(ctx['history_used'])}개 (오래된 ${n(ctx['history_dropped'])}개 생략)'
                  : '${n(ctx['history_used'])}개',
            ),
            if (ctx['split_summary'] == true) _kv('나눠 온 요약', '참고 자료로 넣음'),
            if (ctx['progress_summary'] == true) _kv('진행 요약', '승인된 요약을 참고 자료로 넣음'),
            if (ctx['criteria_version'] is num) _kv('부서 기준', '판 ${n(ctx['criteria_version'])}을 먼저 살핌'),
            if (relevantIds.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('질문과 관련해 찾은 기억',
                  style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              for (final id in relevantIds) _memoryLink(id),
            ],
          ],
          if (excluded > 0) ...[
            const SizedBox(height: 8),
            _kv('답변에서 제외', '메시지 $excluded개 (다음 답변부터 안 읽음)'),
          ],
          const SizedBox(height: 12),
          const Text(
            '왼쪽 트리는 답변 맥락에 들어가지 않습니다. 분류를 제안할 때만 폴더 이름·경로와 대화 제목을 읽습니다.',
            style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 16),
          const Divider(color: kThinkBorder, height: 1),
          const SizedBox(height: 16),
          _restoredContextSection(),
          const SizedBox(height: 16),
          const Divider(color: kThinkBorder, height: 1),
          const SizedBox(height: 16),
          _splitSection(),
          const SizedBox(height: 16),
          const Divider(color: kThinkBorder, height: 1),
          const SizedBox(height: 16),
          _organizeSection(),
          const SizedBox(height: 16),
          const Divider(color: kThinkBorder, height: 1),
          const SizedBox(height: 16),
          ListenableBuilder(listenable: ThinkCodeController.instance, builder: (context, _) => _codeWork()),
          const SizedBox(height: 16),
          const Divider(color: kThinkBorder, height: 1),
          const SizedBox(height: 16),
          Semantics(
            button: true,
            expanded: _showTechnical,
            child: InkWell(
              onTap: () => setState(() => _showTechnical = !_showTechnical),
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('마지막 답변 (모델·토큰·비용)',
                        style: TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800)),
                  ),
                  Icon(_showTechnical ? Icons.expand_less : Icons.expand_more, size: 18, color: kThinkSub),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (!_showTechnical)
            const SizedBox.shrink()
          else if (usage == null)
            const Text('아직 없습니다.', style: TextStyle(color: kThinkHint, fontSize: 12))
          else ...[
            if (info?.model != null) _kv('모델', info!.model!),
            _kv('입력 토큰',
                '${formatTokens(n(usage['input_tokens']))} (캐시 ${formatTokens(n(usage['cached_input_tokens']))})'),
            _kv('출력 토큰',
                '${formatTokens(n(usage['output_tokens']))} (추론 ${formatTokens(n(usage['reasoning_tokens']))})'),
            if ((info?.webSearchCalls ?? 0) > 0) _kv('웹 검색', '${info!.webSearchCalls}회'),
            _kv('비용', formatUsd(info?.costUsd)),
          ],
        ],
      ),
    );
  }

  Widget _restoredContextSection() {
    final detail = _c.selectedDetail;
    final sourceId = detail?.contextFromConversationId;
    ThinkConversation? source;
    for (final c in _c.conversations) {
      if (c.id == sourceId) source = c;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('다른 대화의 작업', style: TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(
          sourceId == null
              ? '이전 자료를 자동으로 넣지 않습니다. 고른 대화의 승인 요약과 작업 상태만 다음 답변의 참고로 읽습니다.'
              : '다음 답변은 "${source?.title ?? '고른 대화'}"의 승인 요약과 작업 상태를 참고로 읽습니다. 이 대화의 진행 요약으로 복사하지 않습니다. 대기 카드는 확정 지침이 아닙니다.',
          style: const TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _c.selectedId == null ? null : _pickRestoredContext,
              style: thinkOutlineButton(),
              icon: const Icon(Icons.history, size: 16),
              label: const Text('대화 골라 보기'),
            ),
            if (sourceId != null)
              TextButton(
                onPressed: _clearRestoredContext,
                child: const Text('빼기', style: TextStyle(color: kThinkSub)),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickRestoredContext() async {
    final current = _c.selectedId;
    if (current == null) return;
    final parent = _c.selectedDetail?.splitFromConversationId;
    final choices = [
      for (final c in _c.conversations)
        if (c.id != current) c,
    ]..sort((a, b) {
        if (a.id == parent) return -1;
        if (b.id == parent) return 1;
        return (b.lastMessageAt ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(a.lastMessageAt ?? DateTime.fromMillisecondsSinceEpoch(0));
      });
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _RestoreContextDialog(
        choices: choices,
        parentId: parent,
        onLookup: _c.lookupContext,
        onUse: (id) => _c.setContextSource(current, id),
      ),
    );
  }

  Future<void> _clearRestoredContext() async {
    final id = _c.selectedId;
    if (id == null) return;
    try {
      await _c.setContextSource(id, null);
      if (mounted) showThinkSnack(context, '다음 답변에는 다른 대화의 작업을 넣지 않습니다.');
    } catch (e) {
      if (mounted) showThinkSnack(context, e is ThinkApiException ? e.message : '빼지 못했습니다.', error: true);
    }
  }

  Widget _splitSection() {
    final status = _c.status;
    final detail = _c.selectedDetail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('대화 나누기', style: TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        if (status == null)
          const Text('기능 상태를 아직 받지 못했습니다.', style: TextStyle(color: kThinkHint, fontSize: 12))
        else
          ThinkFeatureStatusView(feature: status.conversationSplit),
        if (detail != null && detail.splitColumns && status?.conversationSplit.ready == true) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: ThinkToggleChip(
              label: '이 대화에서 나누기 제안 받기',
              icon: Icons.call_split,
              selected: detail.autoSplitSuggestions,
              onChanged: (v) => _setSplitSuggestions(detail.id, v),
            ),
          ),
          if (!detail.autoSplitSuggestions) ...[
            const SizedBox(height: 4),
            const Text(
              '거절해서 꺼져 있습니다. 다시 켜거나, 직접 나누자고 하면 제안합니다.',
              style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
            ),
          ],
        ],
        const SizedBox(height: 8),
        const Text(
          '주제가 바뀐 것 같으면 Think가 새 대화로 나누자고 카드로 묻습니다. AI의 판단이라 놓치거나 잘못 물을 수 있습니다.',
          style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => showThinkStatusDialog(context),
          style: thinkOutlineButton(),
          icon: const Icon(Icons.link, size: 16),
          label: const Text('연결·기능 상태 보기'),
        ),
      ],
    );
  }

  Widget _progressSummarySection(ThinkProgressSummary summary) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('진행 요약', style: TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(
          '승인됨 · ${formatDateTime(summary.approvedAt)}${summary.edited ? ' · 고쳐서 승인' : ''}',
          style: const TextStyle(color: kThinkHint, fontSize: 12),
        ),
        ThinkProgressSummaryView(summary: summary, compact: true),
        const SizedBox(height: 8),
        const Text(
          '다음 답변부터 참고 자료로 넣습니다. 다음 행동은 계획일 뿐 실행되지 않습니다. 새로 정리하려면 Think에게 진행 요약을 부탁하세요.',
          style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
        ),
      ],
    );
  }

  Widget _organizeSection() {
    final status = _c.status;
    final enabled = _c.autoOrganizeEnabled;
    final pending = _c.pendingOrganize.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('정리 제안', style: TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        if (status == null)
          const Text('기능 상태를 아직 받지 못했습니다.', style: TextStyle(color: kThinkHint, fontSize: 12))
        else if (!_c.organizeReady)
          ThinkFeatureStatusView(feature: status.autoOrganize, label: '자동 정리 제안', reason: thinkOrganizeFeatureReason)
        else ...[
          if (enabled != null)
            Align(
              alignment: Alignment.centerLeft,
              child: ThinkToggleChip(
                label: '자동 정리 제안 받기',
                icon: Icons.auto_awesome,
                selected: enabled,
                enabled: !_c.autoOrganizeSaving,
                tooltip: '끄면 "정리해 줘"처럼 직접 부탁할 때만 제안합니다. 모든 대화에 적용됩니다.',
                onChanged: _setAutoOrganize,
              ),
            ),
          _kv('기다리는 제안', pending == 0 ? '없음' : '$pending건'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => openThinkOrganize(context),
                style: thinkOutlineButton(),
                icon: const Icon(Icons.playlist_add_check, size: 16),
                label: const Text('정리 패널'),
              ),
              OutlinedButton.icon(
                onPressed: () => showThinkDepartmentCriteriaDialog(context, department: _c.roleOfConversation(_c.selectedId)),
                style: thinkOutlineButton(),
                icon: const Icon(Icons.rule, size: 16),
                label: const Text('부서 기준'),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        const Text(
          'Think가 분류·기억·맥락 제외·중요 표시·진행 요약을 제안하면 답변 아래 "정리 제안 N건"으로 모입니다. 승인 전에는 아무것도 바뀌지 않습니다.',
          style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
        ),
      ],
    );
  }

  Future<void> _setSplitSuggestions(String conversationId, bool enabled) async {
    try {
      await _c.setSplitSuggestions(conversationId, enabled);
    } catch (e) {
      if (mounted) showThinkSnack(context, '바꾸지 못했습니다: $e', error: true);
    }
  }

  Widget _codeWork() {
    final code = ThinkCodeController.instance;
    final online = code.onlineWorker;
    final last = code.lastWorker;
    final active = code.requests.where((r) => r.status.inProgress).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('코드 작업 (Cursor)', style: TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Tooltip(
          message: '이 PC에서 tools/code_bridge 폴더의 npm start로 켭니다. 켜기 전에 보낸 요청은 대기열에서 기다립니다.',
          child: Row(
            children: [
              Icon(Icons.circle, size: 8, color: online != null ? kThinkSuccess : kThinkHint),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  online != null
                      ? '작업자 켜짐 · ${online.workerId}'
                      : last == null
                          ? '작업자가 연결된 적 없음'
                          : '작업자 꺼짐 · ${formatRelative(last.lastSeenAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kThinkSub, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        _kv('오늘 보낸 요청', '${code.submittedToday}/${code.dailyLimit}건'),
        if (active > 0) _kv('진행 중', '$active건'),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => showThinkCodeRequests(context),
          style: thinkOutlineButton(),
          icon: const Icon(Icons.list_alt, size: 16),
          label: const Text('전체 코드 요청'),
        ),
        const SizedBox(height: 8),
        const Text(
          '코드 조사·수정, 대화 분류, 삭제는 채팅으로 부탁하면 Think가 카드로 제안합니다. 실행은 카드에서 승인할 때만 합니다.',
          style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
        ),
      ],
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 104, child: Text(k, style: const TextStyle(color: kThinkSub, fontSize: 12))),
          Expanded(child: Text(v, style: const TextStyle(color: kThinkText, fontSize: 12))),
        ],
      ),
    );
  }

  Widget _memoryLink(String id) {
    final m = _c.memoryById(id);
    return InkWell(
      onTap: m == null ? null : () => _c.openMemory(id),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(Icons.bookmark_outline, size: 14, color: m == null ? kThinkHint : kThinkAccent),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                m == null ? '(목록에 없는 기억)' : '[${m.kind.label}] ${m.title}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: m == null ? kThinkHint : kThinkLink, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RestoreContextDialog extends StatefulWidget {
  const _RestoreContextDialog({
    required this.choices,
    required this.parentId,
    required this.onLookup,
    required this.onUse,
  });

  final List<ThinkConversation> choices;
  final String? parentId;
  final Future<ThinkContextLookup> Function(String id) onLookup;
  final Future<void> Function(String id) onUse;

  @override
  State<_RestoreContextDialog> createState() => _RestoreContextDialogState();
}

class _RestoreContextDialogState extends State<_RestoreContextDialog> {
  String? _picked;
  ThinkContextLookup? _lookup;
  bool _busy = false;
  String? _error;

  Future<void> _read(String id) async {
    setState(() {
      _picked = id;
      _busy = true;
      _error = null;
      _lookup = null;
    });
    final found = await widget.onLookup(id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _lookup = found;
    });
  }

  Future<void> _use() async {
    final id = _picked;
    final found = _lookup;
    if (id == null || found == null || !found.ok) return;
    setState(() => _busy = true);
    try {
      await widget.onUse(id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is ThinkApiException ? e.message : '다음 답변의 참고로 두지 못했습니다.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final found = _lookup;
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: const Text('다른 대화의 작업', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800, fontSize: 18)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '고른 대화만 읽습니다. 승인 대기 카드는 확정 지침이 아니고, 이 대화의 진행 요약으로 복사하지 않습니다.',
              style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 12),
            if (widget.choices.isEmpty)
              const Text('고를 대화가 없습니다.', style: TextStyle(color: kThinkHint, fontSize: 13))
            else
              SizedBox(
                height: 220,
                child: ListView(
                  children: [
                    for (final c in widget.choices)
                      ListTile(
                        dense: true,
                        selected: _picked == c.id,
                        title: Text(
                          c.title.isEmpty ? '제목 없음' : c.title,
                          style: const TextStyle(color: kThinkText, fontSize: 13),
                        ),
                        subtitle: c.id == widget.parentId
                            ? const Text('나눠 온 대화', style: TextStyle(color: kThinkLink, fontSize: 11))
                            : null,
                        onTap: _busy ? null : () => _read(c.id),
                      ),
                  ],
                ),
              ),
            if (_busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(color: kThinkAccent),
            ],
            if (found != null) ...[
              const SizedBox(height: 12),
              Text(found.message, style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
              if (found.summary != null) ...[
                const SizedBox(height: 6),
                Text('목적: ${found.summary!.purpose}', style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.45)),
              ],
              if (found.ok)
                Text(
                  '작업 ${found.actionCount}건 · 승인 대기 ${found.pendingCount}건 · 코드 요청 ${found.codeCount}건',
                  style: const TextStyle(color: kThinkSub, fontSize: 12),
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: kThinkError, fontSize: 12, height: 1.45)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('닫기', style: TextStyle(color: kThinkSub)),
        ),
        ElevatedButton(
          onPressed: _busy || found == null || !found.ok ? null : _use,
          style: thinkPrimaryButton(),
          child: const Text('다음 답변에 참고로 두기'),
        ),
      ],
    );
  }
}
