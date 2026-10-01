import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/think/think_code_controller.dart';
import '../../services/think/think_code_models.dart';
import '../../services/think/think_controller.dart';
import '../../services/think/think_models.dart';
import 'think_action_cards.dart';
import 'think_code_request_dialog.dart';
import 'think_code_requests_dialog.dart';
import 'think_decision_dialog.dart';
import 'think_message_tile.dart';
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
  String? _lastSelected;
  int _lastCount = -1;
  int _lastReveal = 0;
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
    if (selectedChanged || countChanged) _stickToBottom = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
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

  Future<void> _excerpt(int index) async {
    final id = _c.selectedId;
    if (id == null) return;
    final saved = await ThinkExcerptDialog.create(context, conversationId: id, messages: _c.messages, index: index);
    if (saved && mounted) showThinkSnack(context, '트리에 발췌를 남겼습니다.');
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

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif', 'pdf'],
      withData: false,
    );
    if (result == null) return;
    await _addPaths(result.files.map((f) => f.path ?? '').where((p) => p.isNotEmpty));
  }

  Future<void> _addPaths(Iterable<String> paths) async {
    final problems = await _c.addFiles(paths);
    if (problems.isNotEmpty && mounted) showThinkSnack(context, problems.join('\n'), error: true);
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
                if (wide && _showContext) ...[
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
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) {
        setState(() => _dragging = false);
        _addPaths(detail.files.map((f) => f.path));
      },
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
                        tooltip: _showContext ? '맥락 패널 숨기기' : '맥락 패널 보기',
                        color: kThinkSub,
                        onPressed: () => setState(() => _showContext = !_showContext),
                        icon: Icon(_showContext ? Icons.view_sidebar : Icons.view_sidebar_outlined),
                      ),
                    ],
                  ),
                ),
                const Divider(color: kThinkBorder, height: 1),
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
                      '여기에 놓으면 첨부됩니다 (이미지·PDF, 최대 6개)',
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
              final tile = ThinkMessageTile(
                key: hasId ? _messageKeys.putIfAbsent(id, GlobalKey.new) : null,
                message: m,
                highlighted: hasId && _c.highlightedMessageIds.contains(id),
                onToggleExcluded: turnActions ? () => _toggleExcluded(i) : null,
                onExcerpt: turnActions ? () => _excerpt(i) : null,
                onCodeRequest: turnActions ? () => _codeRequest(i) : null,
              );
              final below = [...?cards[hasId ? id : null], if (i == messages.length - 1) ...?cards['']];
              if (below.isEmpty) return tile;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
    final ids = {for (final m in messages) if ((m.id ?? '').isNotEmpty) m.id!};
    final out = <String, List<Widget>>{};
    void put(String? messageId, Widget w) =>
        out.putIfAbsent(messageId != null && ids.contains(messageId) ? messageId : '', () => []).add(w);

    final actions = _c.actions;
    final linked = {for (final a in actions) if (a.codeRequestId != null) a.codeRequestId!};
    for (final a in actions) {
      put(a.messageId, ThinkActionCard(key: ValueKey('action-${a.id}'), action: a));
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
          ],
          Focus(
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              if (event.logicalKey != LogicalKeyboardKey.enter &&
                  event.logicalKey != LogicalKeyboardKey.numpadEnter) {
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
              decoration: thinkInputDecoration(hint: '메시지 입력 (Enter 보내기 · Shift+Enter 줄바꿈 · 파일은 끌어다 놓기)'),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                tooltip: '이미지·PDF 첨부',
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
                tooltip: webSearchAllowed
                    ? '필요하면 웹을 검색하고 출처를 붙입니다. 검색 1회당 비용이 추가됩니다.'
                    : '사용량 탭에서 웹 검색이 꺼져 있습니다.',
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
                    label: Text(_c.isStreaming ? '다른 대화 답변 중' : '보내기'),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 맥락 패널
  Widget _contextPanel() {
    final info = _c.selectedTurnInfo;
    final ctx = info?.context;
    final usage = info?.usage;
    final relevantIds = (ctx?['relevant'] is List ? ctx!['relevant'] as List : const []).map((e) => e.toString()).toList();
    int n(dynamic v) => v is num ? v.toInt() : 0;
    final excluded = _c.selectedId == null ? 0 : _c.messages.where((m) => m.contextExcluded).length;
    return ThinkPanel(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
            if (relevantIds.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('질문과 관련해 찾은 기억', style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
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
            '왼쪽 트리는 답변 맥락에 들어가지 않습니다. 분류를 부탁하면 폴더 이름·경로와 대화 제목만 읽고 제안합니다.',
            style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 16),
          const Divider(color: kThinkBorder, height: 1),
          const SizedBox(height: 16),
          ListenableBuilder(listenable: ThinkCodeController.instance, builder: (context, _) => _codeWork()),
          const SizedBox(height: 16),
          const Divider(color: kThinkBorder, height: 1),
          const SizedBox(height: 16),
          const Text('마지막 답변', style: TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (usage == null)
            const Text('아직 없습니다.', style: TextStyle(color: kThinkHint, fontSize: 12))
          else ...[
            if (info?.model != null) _kv('모델', info!.model!),
            _kv('입력 토큰', '${formatTokens(n(usage['input_tokens']))} (캐시 ${formatTokens(n(usage['cached_input_tokens']))})'),
            _kv('출력 토큰', '${formatTokens(n(usage['output_tokens']))} (추론 ${formatTokens(n(usage['reasoning_tokens']))})'),
            if ((info?.webSearchCalls ?? 0) > 0) _kv('웹 검색', '${info!.webSearchCalls}회'),
            _kv('비용', formatUsd(info?.costUsd)),
          ],
        ],
      ),
    );
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
