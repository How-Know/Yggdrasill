import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/concept_service.dart';
import '../../../services/think/think_action_models.dart';
import '../../../services/think/think_clipboard_files.dart';
import '../../../services/think/think_code_controller.dart';
import '../../../services/think/think_concept_chat_controller.dart';
import '../../../services/think/think_controller.dart';
import '../../../services/think/think_models.dart';
import '../../think/think_action_cards.dart';
import '../../think/think_avatars.dart';
import '../../think/think_message_tile.dart';
import '../../think/think_organize_panel.dart';
import '../../think/think_style.dart';

/// 개념 화면 오른쪽의 Think 대화. 사용자가 고른 기존 대화를 잇고, 고른 개념은 보낼 때마다 서버가 저장본을 다시 읽는다.
/// 검토 창([ConceptChatController.draftReview])에서는 '개념 초안 검토' 대화를 잇고, 보낼 때마다 서버가 저장된 초안을 다시 읽는다.
/// 설계: docs/architecture/ai-think.md "개념 탭 대화", docs/architecture/concept-library.md "검토 창 대화"
class ConceptChatPanel extends StatefulWidget {
  const ConceptChatPanel({super.key, required this.onClose, this.controller, this.beforeSend});

  final VoidCallback onClose;

  /// 없으면 [ConceptChatController.instance].
  final ConceptChatController? controller;

  /// 보내기 직전에 부른다(검토 창: 저장하지 않은 검토를 먼저 저장). false면 보내지 않는다.
  final Future<bool> Function()? beforeSend;

  @override
  State<ConceptChatPanel> createState() => _ConceptChatPanelState();
}

class _ConceptChatPanelState extends State<ConceptChatPanel> {
  final ScrollController _scroll = ScrollController();
  final FocusNode _composerFocus = FocusNode();
  bool _dragging = false;
  bool _stickToBottom = true;
  String? _lastConversation;
  int _lastCount = -1;
  int _pinToBottom = 0;
  bool _preparing = false;

  ConceptChatController get _c => widget.controller ?? ConceptChatController.instance;
  bool get _draft => _c.draftMode;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      _stickToBottom = pos.maxScrollExtent - pos.pixels < 120;
    });
    // 다른 메뉴에 있는 동안 대화가 지워졌거나 서버가 바뀌었을 수 있다.
    if (_c.conversationId != null && !_c.isStreaming) unawaited(_c.refreshLink());
    if (_c.status == null && !_c.statusLoading && (_c.conversationId != null || _draft)) unawaited(_c.refreshStatus());
    unawaited(_c.ensureStarted());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  void _followBottom() {
    final changed = _lastConversation != _c.conversationId || _lastCount != _c.messages.length;
    _lastConversation = _c.conversationId;
    _lastCount = _c.messages.length;
    if (changed) {
      _stickToBottom = true;
      _pinToBottom = 8;
    }
    if (_pinToBottom > 0 || (_c.isStreaming && _stickToBottom)) {
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
    if (gap > 1 || _pinToBottom > 4) WidgetsBinding.instance.addPostFrameCallback((_) => _pinBottomStep());
  }

  bool get _canType =>
      !_c.forbidden &&
      (_c.link == ConceptChatLink.ready || (_draft && _c.link == ConceptChatLink.none && _c.draftId != null));

  Future<void> _newConversation() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kThinkBg,
        shape: thinkDialogShape,
        title: const Text('새 검토 대화로 바꿀까요?', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
        content: const Text(
          '지금 대화는 Think 화면에 그대로 남습니다. 다음 질문부터 새 \'개념 초안 검토\' 대화에 쌓입니다.',
          style: TextStyle(color: kThinkSub, fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('취소', style: TextStyle(color: kThinkSub))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true), style: thinkPrimaryButton(), child: const Text('새 대화')),
        ],
      ),
    );
    if (ok == true) await _c.startNewConversation();
  }

  Future<void> _pickConversation() async {
    final picked = await showDialog<ThinkConversation>(
      context: context,
      builder: (_) => _ConversationPicker(controller: _c, currentId: _c.conversationId),
    );
    if (picked == null || !mounted) return;
    await _c.linkConversation(picked);
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

  /// Ctrl+V: 클립보드에 글자가 없을 때만 이미지·복사한 파일을 첨부한다.
  Future<void> _pasteFiles() async {
    if (!_canType || await Clipboard.hasStrings()) return;
    final clip = await ThinkClipboardFiles.read();
    if (clip.paths.isEmpty) return;
    try {
      await _addPaths(clip.paths);
    } finally {
      await clip.dispose();
    }
  }

  Future<void> _send() async {
    if (_preparing || !_c.canSend) return;
    final prepare = widget.beforeSend;
    if (prepare != null) {
      setState(() => _preparing = true);
      final ok = await prepare().catchError((Object _) => false);
      if (!mounted) return;
      setState(() => _preparing = false);
      if (!ok || !_c.canSend) return;
    }
    await _c.send();
    if (mounted) _composerFocus.requestFocus();
  }

  List<ThinkMessage> _messagesOf(String conversationId) =>
      conversationId == _c.conversationId ? _c.messages : const <ThinkMessage>[];

  void _openConversationInThink(String conversationId) => unawaited(_c.openConversationInThink(conversationId));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_c, ThinkController.instance, ThinkCodeController.instance]),
      builder: (context, _) {
        _followBottom();
        return DropTarget(
          enable: _canType,
          onDragEntered: (_) => setState(() => _dragging = true),
          onDragExited: (_) => setState(() => _dragging = false),
          onDragDone: _dropped,
          child: ThinkPanel(
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(),
                    const Divider(color: kThinkBorder, height: 1),
                    _linkSection(),
                    const Divider(color: kThinkBorder, height: 1),
                    Expanded(child: _messageList()),
                    for (final n in _notices()) Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: n),
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
                        padding: const EdgeInsets.all(24),
                        child: const Text(
                          '여기에 놓으면 첨부됩니다 (이미지·PDF·엑셀 파일, 최대 6개)',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          const Icon(Icons.forum_outlined, size: 18, color: kThinkAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _draft ? 'Think와 초안 검토' : 'Think와 개념 정리',
              style: const TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800),
            ),
          ),
          if (_draft)
            IconButton(
              tooltip: '새 검토 대화',
              color: kThinkSub,
              iconSize: 18,
              onPressed: _c.conversationId == null || _c.isStreaming || _preparing ? null : _newConversation,
              icon: const Icon(Icons.add_comment_outlined),
            ),
          IconButton(
            tooltip: 'Think 화면에서 이 대화 열기',
            color: kThinkSub,
            iconSize: 18,
            onPressed: _c.conversationId == null ? null : () => unawaited(_c.openInThink()),
            icon: const Icon(Icons.open_in_new),
          ),
          IconButton(
            tooltip: '패널 닫기',
            color: kThinkSub,
            iconSize: 18,
            onPressed: widget.onClose,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _draftLinkSection() {
    final id = _c.conversationId;
    final conv = _c.conversation;
    final role = id == null ? null : (ThinkController.instance.conversationById(id)?.thinkRoleId ?? conv?.thinkRoleId);
    final convLabel = id == null
        ? '첫 질문에서 새 검토 대화를 만듭니다'
        : conv?.title ?? (_c.link == ConceptChatLink.checking ? '확인하는 중…' : '확인하지 못한 대화');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _infoRow(
            leading: role != null
                ? ThinkRoleAvatar(role: role, size: 20)
                : const Icon(Icons.forum_outlined, size: 16, color: kThinkSub),
            label: '대화',
            value: convLabel,
            dim: id == null,
            badges: [if (conv?.archived ?? false) const ThinkBadge('보관됨')],
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Text(
              '보내기 전에 검토 내용을 먼저 저장하고, 서버가 저장된 초안(항목·종류·폴더·출처 블록·기준)을 다시 읽어 답합니다. '
              '바꾸자는 내용은 카드로 오고, 승인해야 초안에 반영됩니다.',
              style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _linkSection() {
    if (_draft) return _draftLinkSection();
    final id = _c.conversationId;
    final conv = _c.conversation;
    final role = id == null ? null : (ThinkController.instance.conversationById(id)?.thinkRoleId ?? conv?.thinkRoleId);
    final convLabel =
        id == null ? '연결한 대화 없음' : conv?.title ?? (_c.link == ConceptChatLink.checking ? '확인하는 중…' : '확인하지 못한 대화');
    final conceptLabel = _c.conceptId == null
        ? '고른 개념 없음'
        : ((_c.conceptName ?? '').isNotEmpty ? _c.conceptName! : (_c.conceptMissing ? '찾을 수 없는 개념' : '이름을 읽는 중…'));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _infoRow(
            leading: role != null
                ? ThinkRoleAvatar(role: role, size: 20)
                : const Icon(Icons.link, size: 16, color: kThinkSub),
            label: '대화',
            value: convLabel,
            dim: id == null,
            badges: [
              if (conv?.archived ?? false) const ThinkBadge('보관됨'),
              if (conv?.fromCursor ?? false) const ThinkBadge('커서 문의', color: kThinkLink),
            ],
            action: TextButton(
              onPressed: _c.isStreaming || _c.forbidden ? null : _pickConversation,
              child: Text(id == null ? '고르기' : '바꾸기', style: const TextStyle(color: kThinkLink, fontSize: 12)),
            ),
          ),
          const SizedBox(height: 4),
          _infoRow(
            leading: const Icon(Icons.menu_book_outlined, size: 16, color: kThinkSub),
            label: '참고 개념',
            value: conceptLabel,
            dim: _c.conceptId == null,
            badges: [
              if (_c.conceptId != null && _c.conceptKind != null)
                ThinkBadge(_c.conceptKind == ConceptKind.definition ? '정의' : '정리', color: kThinkAccent),
              if (_c.conceptId != null)
                Tooltip(
                  message: '${_c.statementLabel ?? '기본 서술(개념 본문)'}\n'
                      '개념 상세에서 고른 서술을 함께 읽습니다. 다른 서술은 제목·상태만 읽습니다.',
                  child: ThinkBadge(
                    key: const ValueKey('concept-chat-statement'),
                    _shortLabel(_c.statementLabel ?? '기본 서술'),
                    color: kThinkLink,
                  ),
                ),
            ],
            action: _c.conceptId == null
                ? null
                : IconButton(
                    tooltip: '개념 참고 해제',
                    iconSize: 16,
                    color: kThinkSub,
                    visualDensity: VisualDensity.compact,
                    onPressed: _c.clearConcept,
                    icon: const Icon(Icons.close),
                  ),
          ),
          const SizedBox(height: 4),
          _infoRow(
            leading: const Icon(Icons.rule_folder_outlined, size: 16, color: kThinkSub),
            label: '참고 기준',
            value: _criterionLabel(),
            dim: _c.criterionId == null,
            badges: [
              if (_c.criterionId != null && !_c.criterionMissing)
                ThinkBadge(
                  _c.criterionVersion > 0 ? '확정 v${_c.criterionVersion}' : '확정 전 초안',
                  color: _c.criterionVersion > 0 ? kThinkSuccess : kThinkAccent,
                ),
              if (_c.criterionId != null && _c.criterionVersion > 0 && _c.criterionHasDraft)
                const ThinkBadge('초안 있음', color: kThinkAccent),
            ],
            action: _c.criterionId == null
                ? null
                : IconButton(
                    tooltip: '기준 참고 해제',
                    iconSize: 16,
                    color: kThinkSub,
                    visualDensity: VisualDensity.compact,
                    onPressed: _c.clearCriterion,
                    icon: const Icon(Icons.close),
                  ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              _c.conceptId == null
                  ? '개념을 오른쪽 클릭하거나 개념 창에서 "Think 대화 참고로 선택"을 누르면, 보낼 때마다 서버가 그 개념의 저장본을 다시 읽어 함께 줍니다.'
                  : '보낼 때마다 서버가 이 개념 하나의 저장본(이름·본문·분류 경로)과 개념 상세에서 고른 서술의 확정본·저장된 초안을 '
                      '다시 읽습니다. 저장하지 않은 편집은 읽지 않습니다.',
              style: const TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
            ),
          ),
          if (_c.criterionId != null) ...[
            const SizedBox(height: 4),
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Text(
                '기준도 보낼 때마다 서버가 확정본과 저장된 초안을 나눠 다시 읽습니다. 저장하지 않은 기준 편집은 보내지 않습니다.',
                style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _criterionLabel() {
    if (_c.criterionId == null) return '고른 기준 없음';
    final t = (_c.criterionTitle ?? '').trim();
    if (t.isNotEmpty) return t;
    return _c.criterionMissing ? '찾을 수 없는 기준' : '제목을 읽는 중…';
  }

  static String _shortLabel(String s) => s.characters.length <= 16 ? s : '${s.characters.take(15)}…';

  Widget _infoRow({
    required Widget leading,
    required String label,
    required String value,
    bool dim = false,
    List<Widget> badges = const [],
    Widget? action,
  }) {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          SizedBox(width: 24, child: Center(child: leading)),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: dim ? kThinkHint : kThinkText, fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
          for (final b in badges) ...[const SizedBox(width: 8), b],
          if (action != null) ...[const SizedBox(width: 4), action],
        ],
      ),
    );
  }

  List<Widget> _notices() {
    final out = <Widget>[];
    if (_c.conceptMissing && _c.conceptId != null) {
      out.add(const ThinkNotice(
        text: '고른 개념을 찾을 수 없습니다(지워졌거나 볼 수 없음). 다른 개념을 고르거나 해제하세요.',
        color: kThinkError,
        icon: Icons.error_outline,
      ));
    }
    if (_c.criterionMissing && _c.criterionId != null) {
      out.add(const ThinkNotice(
        text: '고른 기준을 찾을 수 없습니다(지워졌거나 볼 수 없음). 다른 기준을 고르거나 해제하세요.',
        color: kThinkError,
        icon: Icons.error_outline,
      ));
    }
    final blocked = _c.conversationId == null && !_draft ? null : _c.blockedReason;
    if (blocked != null && !_c.isStreaming) {
      out.add(ThinkNotice(text: blocked, color: kThinkLink, icon: Icons.info_outline));
      final serverStale = _draft
          ? !_c.draftServerReady
          : (_c.conceptId != null && !_c.serverReady) ||
              (_c.statementId != null && !_c.statementServerReady) ||
              (_c.criterionId != null && !_c.criterionServerReady);
      final retry = switch (_c.link) {
        ConceptChatLink.failed => ('다시 확인', _c.refreshLink),
        ConceptChatLink.missing => _draft ? ('새 대화로 시작', _c.startNewConversation) : ('다른 대화 고르기', _pickConversation),
        _ => serverStale && !_c.statusLoading ? ('서버 다시 확인', _c.refreshStatus) : null,
      };
      if (retry != null) {
        out.add(Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => unawaited(retry.$2()),
            child: Text(retry.$1, style: const TextStyle(color: kThinkLink, fontSize: 12)),
          ),
        ));
      }
    }
    final read = _readNotice(_c.lastRead);
    if (read != null) out.add(read);
    final criterionRead = _criterionReadNotice(_c.lastCriterionRead);
    if (criterionRead != null) out.add(criterionRead);
    final draftRead = _draftReadNotice(_c.lastDraftRead);
    if (draftRead != null) out.add(draftRead);
    if (_c.notice != null) out.add(ThinkNotice(text: _c.notice!, onClose: _c.clearNotice));
    if (_c.sendError != null) {
      out.add(
          ThinkNotice(text: _c.sendError!, color: kThinkError, icon: Icons.error_outline, onClose: _c.clearSendError));
    }
    return out;
  }

  /// 서버가 이번 답변에서 고른 개념을 어떻게 읽었는지. 실시간 감시가 아니라 보낸 순간 한 번 읽은 결과다.
  Widget? _readNotice(ConceptReadInfo? r) {
    if (r == null) return null;
    final at = r.updatedAt == null ? '' : ' (${formatDateTime(r.updatedAt)}에 저장된 내용)';
    final path = r.pathComplete == false ? ' 분류 경로는 끝까지 읽지 못했습니다.' : '';
    final links = _linksLine(r);
    final statement = _statementLine(r);
    final partial = path.isNotEmpty ||
        links.contains('읽지 못함') ||
        const {'truncated', 'not_found', 'unread'}.contains(r.statementStatus);
    return switch (r.status) {
      'ok' => ThinkNotice(
          text: '이번 답변은 고른 개념의 저장본$at을 다시 읽고 답했습니다.$path$links$statement',
          color: partial ? kThinkAccent : kThinkSuccess,
          icon: partial ? Icons.warning_amber_outlined : Icons.check_circle_outline,
        ),
      'truncated' => ThinkNotice(
          text: '본문이 길어 앞 ${r.deliveredChars ?? 12000}자만 읽었습니다(전체 ${r.contentChars ?? '-'}자)$at.$path$links$statement',
          color: kThinkAccent,
          icon: Icons.warning_amber_outlined,
        ),
      'not_found' => const ThinkNotice(
          text: '고른 개념을 찾지 못해(지워졌거나 볼 수 없음) 저장본 없이 답했습니다.',
          color: kThinkError,
          icon: Icons.error_outline,
        ),
      'error' => const ThinkNotice(
          text: '고른 개념을 읽다가 오류가 나서 저장본 없이 답했습니다. 다시 보내 보세요.',
          color: kThinkError,
          icon: Icons.error_outline,
        ),
      'skipped' => const ThinkNotice(
          text: '서버가 이번 질문에서는 고른 개념을 읽지 않았습니다.',
          color: kThinkAccent,
          icon: Icons.warning_amber_outlined,
        ),
      _ => const ThinkNotice(
          text: '서버가 개념 참고를 모르는 버전이라 이번 답변은 고른 개념을 읽지 않았습니다.',
          color: kThinkError,
          icon: Icons.error_outline,
        ),
    };
  }

  /// 이은 기준·출처를 함께 읽었는지(서버가 알려 준 경우만).
  String _linksLine(ConceptReadInfo r) {
    if (!r.linksReported) return '';
    final criteria = r.linkedCriteria == null ? '이은 기준 읽지 못함' : '이은 기준 ${r.linkedCriteria}개';
    final sources = r.sources == null ? '출처 읽지 못함' : '출처 ${r.sources}개';
    return ' ($criteria · $sources)';
  }

  /// 고른 서술을 어떻게 읽었는지(서버가 알려 준 경우만).
  String _statementLine(ConceptReadInfo r) {
    final more = r.statements == null ? '다른 서술 목록 읽지 못함' : '다른 서술 ${r.statements}개는 제목만';
    final where = r.appearances == null ? '등장 위치 읽지 못함' : '등장 위치 ${r.appearances}개';
    final tail = ' ($more · $where)';
    switch (r.statementStatus) {
      case null:
        return '';
      case 'base':
        return ' 고른 서술: 기본 서술(개념 본문)$tail.';
      case 'not_found':
        return ' 고른 서술을 찾지 못해(지워졌거나 다른 개념의 서술) 서술 없이 답했습니다$tail.';
      case 'unread':
        return ' 고른 서술을 읽지 못해 서술 없이 답했습니다. 다시 보내 보세요$tail.';
    }
    final parts = <String>[
      (r.statementVersion ?? 0) > 0 ? '확정 v${r.statementVersion}' : '아직 확정본 없음',
      if (r.statementHasDraft == true)
        '저장된 초안${r.statementDraftSavedAt == null ? '' : '(${formatDateTime(r.statementDraftSavedAt)})'}',
    ];
    final cut = r.statementStatus == 'truncated' ? ', 본문이 길어 앞부분만' : '';
    return ' 고른 서술: ${parts.join(' · ')}$cut$tail.';
  }

  /// 서버가 이번 답변에서 고른 기준을 어떻게 읽었는지. 보낸 순간 한 번 읽은 결과다.
  Widget? _criterionReadNotice(CriterionReadInfo? r) {
    if (r == null) return null;
    final parts = <String>[
      if (r.version != null && r.version! > 0)
        '확정 v${r.version}${r.confirmedAt == null ? '' : '(${formatDateTime(r.confirmedAt)})'}',
      if (r.version == 0) '아직 확정본 없음',
      if (r.hasDraft == true) '저장된 초안${r.draftSavedAt == null ? '' : '(${formatDateTime(r.draftSavedAt)})'}',
      r.linkedConcepts == null ? '이은 개념 읽지 못함' : '이은 개념 ${r.linkedConcepts}개',
    ];
    final what = parts.join(' · ');
    return switch (r.status) {
      'ok' => ThinkNotice(
          text: '이번 답변은 고른 기준의 저장본을 다시 읽고 답했습니다: $what',
          color: r.linkedConcepts == null ? kThinkAccent : kThinkSuccess,
          icon: r.linkedConcepts == null ? Icons.warning_amber_outlined : Icons.check_circle_outline,
        ),
      'truncated' => ThinkNotice(
          text: '기준 내용이 길어 앞부분만 읽었습니다: $what',
          color: kThinkAccent,
          icon: Icons.warning_amber_outlined,
        ),
      'not_found' => const ThinkNotice(
          text: '고른 기준을 찾지 못해(지워졌거나 볼 수 없음) 기준 없이 답했습니다.',
          color: kThinkError,
          icon: Icons.error_outline,
        ),
      'error' => const ThinkNotice(
          text: '고른 기준을 읽다가 오류가 나서 기준 없이 답했습니다. 다시 보내 보세요.',
          color: kThinkError,
          icon: Icons.error_outline,
        ),
      'skipped' => const ThinkNotice(
          text: '서버가 이번 질문에서는 고른 기준을 읽지 않았습니다.',
          color: kThinkAccent,
          icon: Icons.warning_amber_outlined,
        ),
      _ => const ThinkNotice(
          text: '서버가 정리 기준 참고를 모르는 버전이라 이번 답변은 고른 기준을 읽지 않았습니다.',
          color: kThinkError,
          icon: Icons.error_outline,
        ),
    };
  }

  /// 서버가 이번 답변에서 초안을 어떻게 읽었는지. 보낸 순간 한 번 읽은 결과다.
  Widget? _draftReadNotice(DraftReadInfo? r) {
    if (r == null) return null;
    final saved = r.reviewSavedAt == null ? '저장된 검토 없음(AI 결과 그대로)' : '${formatDateTime(r.reviewSavedAt)}에 저장된 검토';
    final what = '$saved · 항목 ${r.items ?? '-'}개';
    final closed = r.draftStatus != null && r.draftStatus != 'open';
    return switch (r.status) {
      'ok' when !closed => ThinkNotice(
          text: '이번 답변은 초안을 다시 읽고 답했습니다: $what',
          color: kThinkSuccess,
          icon: Icons.check_circle_outline,
        ),
      'truncated' when !closed => ThinkNotice(
          text: '초안이 길어 출처 블록 일부만 읽고 답했습니다: $what',
          color: kThinkAccent,
          icon: Icons.warning_amber_outlined,
        ),
      'ok' || 'truncated' => const ThinkNotice(
          text: '닫힌 초안이라 읽기만 하고 바꾸자는 카드는 만들지 않았습니다.',
          color: kThinkAccent,
          icon: Icons.warning_amber_outlined,
        ),
      'not_found' => const ThinkNotice(
          text: '초안을 찾지 못해(지워졌거나 볼 수 없음) 초안 없이 답했습니다.',
          color: kThinkError,
          icon: Icons.error_outline,
        ),
      'error' => const ThinkNotice(
          text: '초안을 읽다가 오류가 나서 초안 없이 답했습니다. 다시 보내 보세요.',
          color: kThinkError,
          icon: Icons.error_outline,
        ),
      'skipped' => const ThinkNotice(
          text: '서버가 이번 질문에서는 초안을 읽지 않았습니다.',
          color: kThinkAccent,
          icon: Icons.warning_amber_outlined,
        ),
      _ => const ThinkNotice(
          text: '서버가 초안 참고를 모르는 버전이라 이번 답변은 초안을 읽지 않았습니다.',
          color: kThinkError,
          icon: Icons.error_outline,
        ),
    };
  }

  Widget _messageList() {
    final id = _c.conversationId;
    if (id == null && _draft && _c.messages.isNotEmpty) return _messages('', _c.messages);
    if (id == null) return _draft ? _emptyDraft() : _emptyLink();
    if (_c.messagesLoading) return const Center(child: CircularProgressIndicator(color: kThinkAccent));
    if (_c.messagesError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ThinkNotice(text: _c.messagesError!, color: kThinkError, icon: Icons.error_outline),
        ),
      );
    }
    final messages = _c.messages;
    if (messages.isEmpty) {
      if (_draft) return _emptyDraft();
      return const Center(child: Text('아직 메시지가 없습니다.', style: TextStyle(color: kThinkHint, fontSize: 13)));
    }
    return _messages(id, messages);
  }

  /// [id]가 비면(첫 질문으로 대화를 만드는 중) 카드 없이 메시지만 보인다.
  Widget _messages(String id, List<ThinkMessage> messages) {
    final cards = id.isEmpty ? const <String, List<Widget>>{} : _cardsByMessage(id, messages);
    return ThinkCardScope(
      messagesOf: _messagesOf,
      openConversation: _openConversationInThink,
      child: SelectionArea(
        child: ListView.separated(
          controller: _scroll,
          padding: const EdgeInsets.all(16),
          itemCount: messages.length,
          separatorBuilder: (_, __) => const SizedBox(height: 16),
          itemBuilder: (_, i) {
            final m = messages[i];
            final mid = m.id;
            final hasId = mid != null && mid.isNotEmpty;
            final tile = ThinkMessageTile(message: m);
            final below = [...?cards[hasId ? mid : null], if (i == messages.length - 1) ...?cards['']];
            if (below.isEmpty) return tile;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                tile,
                for (final card in below) ...[const SizedBox(height: 12), card],
              ],
            );
          },
        ),
      ),
    );
  }

  /// Think 채팅과 같은 규칙으로 답변 아래에 카드를 붙인다. 정리 제안은 한 줄로 모으고 Think 화면에서 확인한다.
  Map<String, List<Widget>> _cardsByMessage(String convId, List<ThinkMessage> messages) {
    final think = ThinkController.instance;
    final ids = {
      for (final m in messages)
        if ((m.id ?? '').isNotEmpty) m.id!
    };
    final out = <String, List<Widget>>{};
    void put(String? messageId, Widget w) =>
        out.putIfAbsent(messageId != null && ids.contains(messageId) ? messageId : '', () => []).add(w);

    final actions = think.actionsOf(convId);
    final linked = {
      for (final a in actions)
        if (a.codeRequestId != null) a.codeRequestId!
    };
    final organize = <String, List<ThinkAction>>{};
    for (final a in actions) {
      if (think.inOrganizePanel(a)) {
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
              failed: e.value.where((a) => think.organizeErrors.containsKey(a.id)).length,
              onOpen: () => unawaited(_c.openInThink(organize: true, messageId: e.key.isEmpty ? null : e.key)),
            ),
          );
    }
    final own = ThinkCodeController.instance.requestsFor(convId).where((r) => !linked.contains(r.id)).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final r in own) {
      final source = r.sourceMessageIds.lastWhere(ids.contains, orElse: () => '');
      put(source, ThinkCodeRequestCard(key: ValueKey('code-${r.id}'), request: r));
    }
    return out;
  }

  Widget _emptyDraft() {
    return const Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.fact_check_outlined, size: 40, color: kThinkAccent),
            SizedBox(height: 16),
            Text(
              '이 초안에 대해 Think에게 물어보세요',
              textAlign: TextAlign.center,
              style: TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800),
            ),
            SizedBox(height: 8),
            Text(
              '예: "3번과 4번은 같은 개념 아니야?", "공식 유형을 따로 만들자", "이 기준으로 다시 정리해 줘"\n'
              '고치자는 내용은 카드로 오고, 승인해야 초안에 반영됩니다. 대화는 다음 초안에서도 이어집니다.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kThinkSub, fontSize: 13, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyLink() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.forum_outlined, size: 40, color: kThinkAccent),
            const SizedBox(height: 16),
            const Text(
              '개념을 같이 정리할 Think 대화를 고르세요',
              textAlign: TextAlign.center,
              style: TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              'Think 화면의 기존 대화를 이어 갑니다. 그 대화에서 정한 기준과 기억을 그대로 씁니다.\n'
              '새 대화는 만들지 않고, 대화의 부서·폴더도 바꾸지 않습니다.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kThinkSub, fontSize: 13, height: 1.6),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _c.forbidden ? null : _pickConversation,
              style: thinkPrimaryButton(),
              icon: const Icon(Icons.add_link, size: 16),
              label: const Text('대화 고르기'),
            ),
            if (_c.forbidden) ...[
              const SizedBox(height: 12),
              const Text('Think는 최고 관리자만 쓸 수 있습니다.', style: TextStyle(color: kThinkHint, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _composer() {
    final webSearchAllowed = _c.status?.webSearchEnabled ?? true;
    final enabled = _canType;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
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
              enabled: enabled,
              minLines: 1,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(color: kThinkText, fontSize: 14, height: 1.5),
              decoration: thinkInputDecoration(
                hint: !enabled
                    ? (_draft ? '초안을 연 뒤 입력할 수 있습니다' : '대화를 연결하면 입력할 수 있습니다')
                    : _draft
                        ? '초안에 대해 묻기 (Enter 보내기 · Shift+Enter 줄바꿈)'
                        : '개념에 대해 묻기 (Enter 보내기 · Shift+Enter 줄바꿈 · 파일은 끌어다 놓기)',
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                tooltip: '이미지·PDF·엑셀 첨부',
                color: kThinkSub,
                onPressed: enabled ? _pickFiles : null,
                icon: const Icon(Icons.attach_file),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ThinkToggleChip(
                      label: '웹 검색',
                      icon: Icons.travel_explore,
                      selected: _c.webSearch && webSearchAllowed,
                      enabled: webSearchAllowed,
                      tooltip: webSearchAllowed ? '필요하면 웹을 검색하고 출처를 붙입니다. 검색 1회당 비용이 추가됩니다.' : '사용량 탭에서 웹 검색이 꺼져 있습니다.',
                      onChanged: _c.setWebSearch,
                    ),
                    ThinkToggleChip(
                      label: '깊게 생각',
                      icon: Icons.psychology_alt_outlined,
                      selected: _c.deep,
                      tooltip: '더 큰 모델로 오래 생각합니다. 비용과 시간이 더 듭니다.',
                      onChanged: _c.setDeep,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ListenableBuilder(
                listenable: _c.composer,
                builder: (context, _) {
                  if (_c.isStreaming) {
                    return ElevatedButton.icon(
                      onPressed: _c.stop,
                      style: thinkPrimaryButton(color: kThinkError),
                      icon: const Icon(Icons.stop_rounded, size: 18),
                      label: const Text('중지'),
                    );
                  }
                  // 막힌 이유는 입력창 위 안내에 나온다. 좁은 폭에서 토글 칩 자리를 지키려고 라벨은 짧게 둔다.
                  return ElevatedButton.icon(
                    onPressed: _c.canSend && !_preparing ? _send : null,
                    style: thinkPrimaryButton(),
                    icon: _preparing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 1.5, color: kThinkText),
                          )
                        : const Icon(Icons.send_rounded, size: 18),
                    label: Text(_preparing ? '저장 중' : '보내기'),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 이어 갈 기존 대화 고르기. 대화를 만들거나 부서·폴더를 바꾸지 않는다.
class _ConversationPicker extends StatefulWidget {
  const _ConversationPicker({required this.controller, this.currentId});

  final ConceptChatController controller;
  final String? currentId;

  @override
  State<_ConversationPicker> createState() => _ConversationPickerState();
}

class _ConversationPickerState extends State<_ConversationPicker> {
  late final Future<List<ThinkConversation>> _load = widget.controller.loadPickable();
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: const Text('이어 갈 Think 대화 고르기', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 480,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '기존 대화만 고를 수 있습니다. 새 대화는 Think 화면에서 만드세요. 이어 가도 대화의 부서·폴더는 바뀌지 않습니다.',
              style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _query,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(color: kThinkText),
              decoration: thinkInputDecoration(
                hint: '제목으로 찾기',
                dense: true,
                prefixIcon: const Icon(Icons.search, size: 18, color: kThinkSub),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: FutureBuilder<List<ThinkConversation>>(
                future: _load,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator(color: kThinkAccent));
                  }
                  if (snap.hasError) {
                    return Center(
                      child: ThinkNotice(
                        text: '대화 목록을 불러오지 못했습니다: ${snap.error}',
                        color: kThinkError,
                        icon: Icons.error_outline,
                      ),
                    );
                  }
                  final q = _query.text.trim().toLowerCase();
                  final list = (snap.data ?? const <ThinkConversation>[])
                      .where((c) => q.isEmpty || c.title.toLowerCase().contains(q))
                      .toList();
                  if (list.isEmpty) {
                    return const Center(
                      child: Text('고를 수 있는 대화가 없습니다.', style: TextStyle(color: kThinkHint, fontSize: 13)),
                    );
                  }
                  return ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 4),
                    itemBuilder: (_, i) => _row(list[i]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
      ],
    );
  }

  Widget _row(ThinkConversation c) {
    final current = c.id == widget.currentId;
    final meta = [
      'Think(${c.thinkRoleId.label})',
      if (c.sortTime != null) formatRelative(c.sortTime),
      '메시지 ${c.messageCount}개',
    ].join(' · ');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.pop(context, c),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: current ? kThinkAccent.withValues(alpha: 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: current ? kThinkAccent.withValues(alpha: 0.5) : kThinkBorder),
          ),
          child: Row(
            children: [
              ThinkRoleAvatar(role: c.thinkRoleId, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kThinkSub, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (c.fromCursor) ...[const SizedBox(width: 8), const ThinkBadge('커서 문의', color: kThinkLink)],
              if (current) ...[const SizedBox(width: 8), const ThinkBadge('연결됨', color: kThinkAccent)],
            ],
          ),
        ),
      ),
    );
  }
}
