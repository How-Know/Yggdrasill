import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/think/think_action_models.dart';
import '../../services/think/think_api.dart';
import '../../services/think/think_controller.dart';
import '../../services/think/think_models.dart';
import 'think_avatars.dart';
import 'think_code_views.dart';
import 'think_memory_proposal_views.dart';
import 'think_split_views.dart';
import 'think_style.dart';
import 'think_tree_dialogs.dart';

// 정리 제안: 답변 아래 "정리 제안 N건" 줄, 오른쪽 정리 패널(좁으면 바텀시트), 진행 요약·부서 기준 보기와 고치기.
// 패널과 답변 아래 카드는 같은 제안(ai_actions)을 본다. 승인은 서버 ai_action_apply_batch가 항목마다 따로 한다.
// 설계: docs/architecture/ai-think-actions.md §11

String thinkOrganizeFeatureReason(ThinkFeatureStatus f) => switch (f.state) {
      ThinkFeatureState.ready => 'Think가 분류·기억·맥락 제외·중요 표시·진행 요약·부서 기준을 제안하면 정리 패널에서 골라 한 번에 승인합니다. '
          '승인 전에는 아무것도 바뀌지 않습니다.',
      ThinkFeatureState.dbRequired =>
        'DB 반영 필요 — 운영 DB에 마이그레이션 20261012120000_ai_think_auto_organize.sql이 아직 없습니다. 그동안 예전 카드만 씁니다.',
      ThinkFeatureState.appUpdateRequired => '앱 업데이트 필요 — 이 앱이 정리 패널을 처리한다고 알리지 않았습니다.',
      ThinkFeatureState.unknown => '서버가 DB 준비 여부를 확인하지 못했습니다. 확인되기 전에는 쓰지 않습니다.',
      ThinkFeatureState.edgeMissing => 'Edge 배포 필요 — 연결된 ai_think가 자동 정리 기능을 모르는 이전 버전입니다.',
    };

/// 정리 패널을 연다. 대화 화면이 넓으면 오른쪽에 붙이고, 좁으면 바텀시트로 띄운다.
Future<void> openThinkOrganize(BuildContext context, {String? messageId}) async {
  final c = ThinkController.instance;
  if (c.organizeDockable) {
    c.openOrganizePanel(messageId: messageId);
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kThinkPanel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    clipBehavior: Clip.antiAlias,
    builder: (ctx) => FractionallySizedBox(
      heightFactor: 0.88,
      child: ThinkOrganizePanel(focusMessageId: messageId, sheet: true, onClose: () => Navigator.pop(ctx)),
    ),
  );
}

IconData thinkOrganizeIcon(ThinkActionKind kind) => switch (kind) {
      ThinkActionKind.handoverDepartment => Icons.swap_horiz,
      ThinkActionKind.placeConversation => Icons.drive_file_move_outline,
      ThinkActionKind.splitConversation => Icons.call_split,
      ThinkActionKind.saveMemory => Icons.bookmark_add_outlined,
      ThinkActionKind.memoryCardChange => Icons.edit_note,
      ThinkActionKind.excludeContext => Icons.visibility_off_outlined,
      ThinkActionKind.markImportant => Icons.flag_outlined,
      ThinkActionKind.progressSummary => Icons.summarize_outlined,
      ThinkActionKind.departmentCriteriaChange => Icons.rule,
      _ => Icons.task_alt,
    };

// =====================================================================================
// 답변 아래 진입 줄 · 위쪽 대기 수
// =====================================================================================

/// 답변 아래 "정리 제안 N건". 누르면 정리 패널에서 그 답변의 제안을 강조해 보여 준다.
class ThinkOrganizeEntry extends StatelessWidget {
  const ThinkOrganizeEntry({super.key, required this.actions, required this.onOpen, this.failed = 0});

  final List<ThinkAction> actions;
  final VoidCallback onOpen;

  /// 일괄 승인에서 처리하지 못해 남은 항목 수.
  final int failed;

  @override
  Widget build(BuildContext context) {
    final kinds = <String>[];
    for (final a in actions) {
      if (!kinds.contains(a.kind.label)) kinds.add(a.kind.label);
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kThinkBorder),
              ),
              child: Row(
                children: [
                  const Icon(Icons.playlist_add_check, size: 16, color: kThinkLink),
                  const SizedBox(width: 8),
                  Text(
                    '정리 제안 ${actions.length}건',
                    style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      kinds.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kThinkSub, fontSize: 12),
                    ),
                  ),
                  if (failed > 0) ...[
                    const SizedBox(width: 8),
                    Text('처리 못 한 $failed건', style: const TextStyle(color: kThinkError, fontSize: 12, fontWeight: FontWeight.w700)),
                  ],
                  const SizedBox(width: 8),
                  const Text('확인하기', style: TextStyle(color: kThinkLink, fontSize: 12, fontWeight: FontWeight.w700)),
                  const Icon(Icons.chevron_right, size: 16, color: kThinkLink),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 대화 머리의 작은 대기 수. 누르면 정리 패널을 연다.
class ThinkOrganizeCountButton extends StatelessWidget {
  const ThinkOrganizeCountButton({super.key, required this.count, required this.onOpen});

  final int count;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '확인을 기다리는 정리 제안 $count건',
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(8),
        child: ThinkBadge('정리 제안 $count', color: kThinkLink),
      ),
    );
  }
}

// =====================================================================================
// 정리 패널
// =====================================================================================

class ThinkOrganizePanel extends StatefulWidget {
  const ThinkOrganizePanel({super.key, required this.onClose, this.focusMessageId, this.sheet = false});

  final VoidCallback onClose;

  /// 이 답변의 제안을 강조한다.
  final String? focusMessageId;

  /// 좁은 화면의 바텀시트로 띄웠다(패널 테두리 없이 그린다).
  final bool sheet;

  @override
  State<ThinkOrganizePanel> createState() => _ThinkOrganizePanelState();
}

class _ThinkOrganizePanelState extends State<ThinkOrganizePanel> {
  ThinkController get _c => ThinkController.instance;

  /// 고른 항목. 처음에는 아무것도 고르지 않는다(무엇을 승인하는지 하나씩 확인한다).
  final Set<String> _checked = {};

  /// 카드에서 고친 값(서버 ai_action_apply의 p_overrides).
  final Map<String, Map<String, dynamic>> _overrides = {};

  /// 맥락 제외·중요 표시에서 고른 메시지. 없으면 제안한 메시지 전부.
  final Map<String, Set<String>> _picks = {};

  /// 고친 부서 기준(제목까지 보여 주려고 따로 둔다). 서버에는 [_overrides]의 criteria만 간다.
  final Map<String, ThinkCriteriaView> _criteriaEdits = {};

  final Set<String> _rejecting = {};
  bool _busy = false;

  final GlobalKey _focusKey = GlobalKey();
  String? _scrolledFocus;

  @override
  void initState() {
    super.initState();
    if (_c.autoOrganizeEnabled == null) _c.refreshOrganizeSettings();
  }

  /// 답변 아래 줄에서 열었으면 그 답변의 첫 제안까지 내려 준다.
  void _scrollToFocus(String? focus) {
    if (focus == null || focus == _scrolledFocus) return;
    _scrolledFocus = focus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _focusKey.currentContext;
      if (ctx != null && ctx.mounted) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 200), alignment: 0.1);
    });
  }

  bool get _streamingHere => _c.isStreaming && _c.streamingConversationId == _c.selectedId;

  Set<String> _pickedOf(ThinkAction a) => _picks[a.id] ?? a.organizeMessageIds.toSet();

  Map<String, dynamic> _overridesFor(ThinkAction a) {
    final out = {...?_overrides[a.id]};
    final picked = _picks[a.id];
    if (picked != null && picked.length != a.organizeMessageIds.length) {
      out['message_ids'] = [for (final id in a.organizeMessageIds) if (picked.contains(id)) id];
    }
    return out;
  }

  bool _edited(ThinkAction a) => (_overrides[a.id]?.isNotEmpty ?? false) || _overridesFor(a).containsKey('message_ids');

  void _setOverride(ThinkAction a, String key, Object? value) => setState(() {
        (_overrides[a.id] ??= {})[key] = value;
        _checked.add(a.id);
      });

  void _clearOverride(ThinkAction a, String key) => setState(() {
        _overrides[a.id]?.remove(key);
        if (_overrides[a.id]?.isEmpty ?? false) _overrides.remove(a.id);
      });

  /// 승인을 막는 이유. 서버도 같은 조건을 다시 확인한다.
  String? _blocked(ThinkAction a) {
    if (a.kind == ThinkActionKind.splitConversation) {
      if (a.messageId == null) return '답변 완료 후 나눌 수 있습니다.';
      final answer = _c.messages.where((m) => m.id == a.messageId).firstOrNull;
      if (answer != null && answer.status != ThinkMessageStatus.complete) {
        return '답변이 끝까지 저장되지 않아(중단·오류) 나눌 수 없습니다.';
      }
    }
    return null;
  }

  Future<void> _approve(List<ThinkAction> items) async {
    final conv = _c.selectedId;
    if (conv == null || _busy) return;
    final chosen = [
      for (final a in items)
        if (_checked.contains(a.id) && _blocked(a) == null) (action: a, overrides: _overridesFor(a)),
    ];
    if (chosen.isEmpty) return;
    setState(() => _busy = true);
    final outcome = await _c.applyOrganize(conv, chosen);
    if (!mounted) return;
    setState(() {
      _busy = false;
      for (final a in outcome.applied) {
        _checked.remove(a.id);
        _overrides.remove(a.id);
        _picks.remove(a.id);
        _criteriaEdits.remove(a.id);
      }
    });
  }

  Future<void> _reject(ThinkAction a) async {
    setState(() => _rejecting.add(a.id));
    try {
      await _c.rejectAction(a);
      _checked.remove(a.id);
    } catch (e) {
      if (mounted) showThinkSnack(context, ThinkApi.codeErrorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _rejecting.remove(a.id));
    }
  }

  void _reveal(List<String> messageIds) {
    final conv = _c.selectedId;
    if (conv == null || messageIds.isEmpty) return;
    if (!_c.organizeDockable) widget.onClose();
    _c.revealMessages(conv, messageIds);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final items = _c.pendingOrganize;
        final focus = widget.focusMessageId ?? _c.organizeFocusMessageId;
        final focusId = focus == null ? null : items.where((a) => a.messageId == focus).firstOrNull?.id;
        if (focusId != null) _scrollToFocus(focus);
        final outcome = _c.selectedOrganizeOutcome;
        final selectable = items.where((a) => _blocked(a) == null).toList();
        final chosen = selectable.where((a) => _checked.contains(a.id)).length;
        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(items.length),
            const Divider(color: kThinkBorder, height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (outcome != null) ...[_outcome(outcome), const SizedBox(height: 12)],
                    if (items.isEmpty)
                      _empty()
                    else ...[
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '위에서부터 차례로 처리합니다. 고른 항목만 승인합니다.',
                              style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
                            ),
                          ),
                          TextButton(
                            onPressed: _busy || selectable.isEmpty
                                ? null
                                : () => setState(() {
                                      if (chosen == selectable.length) {
                                        _checked.clear();
                                      } else {
                                        _checked.addAll(selectable.map((a) => a.id));
                                      }
                                    }),
                            child: Text(
                              chosen == selectable.length && chosen > 0 ? '모두 풀기' : '모두 고르기',
                              style: const TextStyle(color: kThinkLink, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      for (final a in items) ...[
                        KeyedSubtree(
                          key: a.id == focusId ? _focusKey : ValueKey(a.id),
                          child: _item(a, items, focused: focus != null && a.messageId == focus),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            const Divider(color: kThinkBorder, height: 1),
            _footer(items, chosen),
          ],
        );
        return widget.sheet ? Material(color: kThinkPanel, child: SafeArea(top: false, child: body)) : ThinkPanel(child: body);
      },
    );
  }

  Widget _header(int count) {
    final enabled = _c.autoOrganizeEnabled;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.playlist_add_check, size: 18, color: kThinkLink),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('이번 대화 정리 제안', style: TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800)),
              ),
              if (count > 0) ThinkBadge('$count건', color: kThinkLink),
              IconButton(
                tooltip: '닫기',
                color: kThinkSub,
                onPressed: widget.onClose,
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
          if (enabled != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                ThinkToggleChip(
                  label: enabled ? '자동 제안 켜짐' : '자동 제안 꺼짐',
                  icon: Icons.auto_awesome,
                  selected: enabled,
                  enabled: !_c.autoOrganizeSaving,
                  tooltip: '끄면 "정리해 줘"처럼 직접 부탁할 때만 Think가 분류·기억·정리를 제안합니다.',
                  onChanged: (v) async {
                    final err = await _c.setAutoOrganize(v);
                    if (err != null && mounted) showThinkSnack(context, err, error: true);
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _empty() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Icon(Icons.task_alt, size: 32, color: kThinkHint),
          SizedBox(height: 12),
          Text('확인을 기다리는 정리 제안이 없습니다.', style: TextStyle(color: kThinkSub, fontSize: 13)),
          SizedBox(height: 8),
          Text(
            'Think가 대화 중에 분류·기억·맥락 제외·중요 표시·진행 요약을 제안하면 여기에 모입니다. '
            '처리한 제안은 답변 아래에 한 줄로 남습니다.',
            textAlign: TextAlign.center,
            style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _outcome(ThinkOrganizeOutcome o) {
    final conv = _c.selectedId;
    final pending = {for (final a in _c.pendingOrganize) a.id};
    final gone = o.failed.where((r) => !pending.contains(r.id)).toList();
    final split = o.splitConversationId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (o.error != null)
          ThinkNotice(
            text: '승인하지 못했습니다. 아무것도 바뀌지 않았습니다. ${o.error}',
            color: kThinkError,
            icon: Icons.error_outline,
            onClose: conv == null ? null : () => _c.clearOrganizeOutcome(conv),
          ),
        if (o.applied.isNotEmpty)
          ThinkNotice(
            text: o.failed.isEmpty
                ? '처리함: ${o.summary}'
                : '처리함: ${o.summary}\n처리하지 못한 ${o.failed.length}건은 그대로 남아 있습니다. 이유를 확인해 주세요.',
            color: o.failed.isEmpty ? kThinkSuccess : kThinkLink,
            icon: o.failed.isEmpty ? Icons.check_circle_outline : Icons.info_outline,
            onClose: conv == null ? null : () => _c.clearOrganizeOutcome(conv),
          ),
        if (o.applied.isEmpty && o.failed.isNotEmpty && o.error == null)
          ThinkNotice(
            text: '고른 ${o.failed.length}건을 처리하지 못했습니다. 아래에서 이유를 확인해 주세요.',
            color: kThinkError,
            icon: Icons.error_outline,
            onClose: conv == null ? null : () => _c.clearOrganizeOutcome(conv),
          ),
        for (final r in gone)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${r.action?.kind.label ?? '제안'}: ${ThinkApi.batchErrorMessage(r)}',
              style: const TextStyle(color: kThinkError, fontSize: 12, height: 1.5),
            ),
          ),
        if (split != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () {
                if (!_c.organizeDockable) widget.onClose();
                _c.openSplitConversation(split);
              },
              icon: const Icon(Icons.open_in_new, size: 16, color: kThinkLink),
              label: const Text('나눈 대화 열기', style: TextStyle(color: kThinkLink)),
            ),
          ),
      ],
    );
  }

  Widget _footer(List<ThinkAction> items, int chosen) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_streamingHere)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('답변이 끝난 뒤 승인할 수 있습니다.', style: TextStyle(color: kThinkHint, fontSize: 12)),
            ),
          Row(
            children: [
              TextButton(
                onPressed: widget.onClose,
                child: const Text('나중에 보기', style: TextStyle(color: kThinkSub)),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: chosen == 0 || _busy || _streamingHere ? null : () => _approve(items),
                style: thinkPrimaryButton(),
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: kThinkText))
                    : const Icon(Icons.check, size: 16),
                label: Text(chosen == 0 ? '선택한 항목 승인' : '선택한 항목 승인 ($chosen)'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 항목
  Widget _item(ThinkAction a, List<ThinkAction> all, {required bool focused}) {
    final blocked = _blocked(a);
    final error = _c.organizeErrors[a.id];
    final checked = _checked.contains(a.id);
    final rejecting = _rejecting.contains(a.id);
    final headline = _headline(a);
    final reason = _reason(a);
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 8, 12, 12),
      decoration: BoxDecoration(
        color: kThinkBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: error != null
              ? kThinkError.withValues(alpha: 0.6)
              : focused
                  ? kThinkLink.withValues(alpha: 0.6)
                  : kThinkBorder,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: checked && blocked == null,
            visualDensity: VisualDensity.compact,
            activeColor: kThinkAccent,
            side: const BorderSide(color: kThinkSub),
            onChanged: blocked != null || _busy
                ? null
                : (v) => setState(() => v == true ? _checked.add(a.id) : _checked.remove(a.id)),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(thinkOrganizeIcon(a.kind), size: 16, color: kThinkAccent),
                    const SizedBox(width: 8),
                    Text(a.kind.label, style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
                    if (_edited(a)) ...[const SizedBox(width: 8), const ThinkBadge('고침', color: kThinkAccent)],
                    const Spacer(),
                    TextButton(
                      onPressed: rejecting || _busy ? null : () => _reject(a),
                      child: Text(rejecting ? '거절 중…' : '이번에는 거절', style: const TextStyle(color: kThinkSub, fontSize: 12)),
                    ),
                  ],
                ),
                if (headline.isNotEmpty)
                  SelectableText(
                    headline,
                    style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700, height: 1.4),
                  ),
                ..._body(a, all),
                if (reason.isNotEmpty) ...[
                  thinkCodeLabel('왜 지금 제안했나'),
                  SelectableText(reason, style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
                ],
                if (a.messageId != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => _reveal([a.messageId!]),
                      icon: const Icon(Icons.forum_outlined, size: 14, color: kThinkLink),
                      label: const Text('제안한 답변 보기', style: TextStyle(color: kThinkLink, fontSize: 12)),
                    ),
                  ),
                if (blocked != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(blocked, style: const TextStyle(color: kThinkLink, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  ThinkNotice(text: error, color: kThinkError, icon: Icons.error_outline),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _headline(ThinkAction a) {
    switch (a.kind) {
      case ThinkActionKind.handoverDepartment:
        return '${(a.handoverFrom ?? ThinkRoleId.lead).label} → ${a.handoverTo?.label ?? '다른'} 부서';
      case ThinkActionKind.placeConversation:
        final folder = _overrides[a.id]?['folder_id'] as String?;
        final tree = _c.tree;
        return folder != null && tree.byId[folder] != null ? tree.folderPath(folder) : (a.preview['path'] ?? '').toString();
      case ThinkActionKind.splitConversation:
        return (_overrides[a.id]?['title'] ?? a.title).toString();
      case ThinkActionKind.saveMemory:
        return '';
      case ThinkActionKind.memoryCardChange:
        final op = kThinkMemoryCardOps[a.memoryCardOp] ?? a.memoryCardOp;
        return '$op · 대기 중인 카드 "${a.memoryTargetTitle.isEmpty ? '(제목 없음)' : a.memoryTargetTitle}"';
      case ThinkActionKind.excludeContext:
        return '메시지 ${_pickedOf(a).length}개를 이후 답변 맥락에서 빼기';
      case ThinkActionKind.markImportant:
        return '메시지 ${_pickedOf(a).length}개에 중요 표시';
      case ThinkActionKind.progressSummary:
        return '';
      case ThinkActionKind.departmentCriteriaChange:
        return '${a.criteriaDepartment?.label ?? ''} 부서 기준';
      default:
        return a.title;
    }
  }

  String _reason(ThinkAction a) => switch (a.kind) {
        ThinkActionKind.handoverDepartment => a.handoverReason,
        ThinkActionKind.placeConversation => (a.preview['reason'] ?? '').toString(),
        ThinkActionKind.splitConversation => a.splitReason,
        ThinkActionKind.saveMemory || ThinkActionKind.memoryCardChange => a.memoryReason,
        _ => a.organizeReason,
      };

  List<Widget> _body(ThinkAction a, List<ThinkAction> all) => switch (a.kind) {
        ThinkActionKind.handoverDepartment => _handover(a),
        ThinkActionKind.placeConversation => _place(a, all),
        ThinkActionKind.splitConversation => _split(a),
        ThinkActionKind.saveMemory => _memory(a),
        ThinkActionKind.memoryCardChange => _memoryChange(a),
        ThinkActionKind.excludeContext || ThinkActionKind.markImportant => _messages(a),
        ThinkActionKind.progressSummary => _summary(a),
        ThinkActionKind.departmentCriteriaChange => _criteria(a),
        _ => const [],
      };

  static Widget _note(String text, {Color color = kThinkSub, IconData? icon}) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon != null) ...[
              Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 14, color: color)),
              const SizedBox(width: 8),
            ],
            Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 12, height: 1.5))),
          ],
        ),
      );

  static Widget _editButton(String label, VoidCallback? onPressed) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.edit_outlined, size: 14, color: kThinkLink),
          label: Text(label, style: const TextStyle(color: kThinkLink, fontSize: 12)),
        ),
      );

  List<Widget> _handover(ThinkAction a) {
    final from = a.handoverFrom ?? ThinkRoleId.lead;
    final to = a.handoverTo;
    final toLabel = to?.label ?? '다른';
    return [
      const SizedBox(height: 8),
      Row(
        children: [
          ThinkRoleAvatar(role: from, size: 24, semanticsLabel: '지금 ${from.label} 부서'),
          const SizedBox(width: 8),
          Text(from.label, style: const TextStyle(color: kThinkText, fontSize: 13)),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Icon(Icons.arrow_forward, size: 16, color: kThinkSub),
          ),
          if (to != null) ...[
            ThinkRoleAvatar(role: to, size: 24, semanticsLabel: '받을 ${to.label} 부서'),
            const SizedBox(width: 8),
            Text(to.label, style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
          ],
        ],
      ),
      _note('승인하면 이 대화의 부서가 $toLabel(으)로 바뀌고 $toLabel 부서의 미분류로 옮겨집니다. '
          '다음 답변부터 $toLabel 관점으로 답합니다. 이미 받은 답변과 기억은 바뀌지 않습니다.'),
    ];
  }

  List<Widget> _place(ThinkAction a, List<ThinkAction> all) {
    final current = (a.preview['current'] ?? '').toString();
    final folder = _overrides[a.id]?['folder_id'] as String?;
    final isNew = a.newFolderTitle != null && folder == null;
    final after = folder == null ? a.placeAfterHandover : null;
    final handover = all.where((x) => x.kind == ThinkActionKind.handoverDepartment && x.handoverTo == after).firstOrNull;
    final handoverChosen = handover != null && _checked.contains(handover.id);
    return [
      _note('지금 위치: ${current.isEmpty ? '정리 안 됨' : current}'),
      if (isNew) _note('승인하면 이 이름으로 새 폴더를 만들고 넣습니다. 승인 전에는 폴더도 만들지 않습니다.'),
      if (after != null)
        _note(
          handoverChosen
              ? '${after.label} 부서로 넘긴 다음에 넣습니다.'
              : '${after.label} 부서로 넘긴 다음에 넣는 분류입니다. 위의 부서 넘기기를 함께 고르지 않으면 처리되지 않습니다.',
          color: handoverChosen ? kThinkSub : kThinkLink,
          icon: Icons.swap_horiz,
        ),
      Wrap(
        spacing: 8,
        children: [
          _editButton('다른 폴더 고르기', _busy ? null : () => _pickFolder(a)),
          if (folder != null)
            TextButton(
              onPressed: () => _clearOverride(a, 'folder_id'),
              child: const Text('제안대로', style: TextStyle(color: kThinkSub, fontSize: 12)),
            ),
        ],
      ),
    ];
  }

  Future<void> _pickFolder(ThinkAction a) async {
    final tree = _c.tree;
    final node = tree.conversationNodes[a.conversationId];
    final picked = await showThinkFolderPicker(
      context,
      tree: tree,
      currentParentId: node?.parentId,
      department: _c.departmentsReady ? _c.roleOfConversation(a.conversationId) : null,
      allowRoot: false,
      title: '어느 폴더에 넣을까요?',
    );
    if (picked == null || picked.startsWith(kThinkRootFolder) || !mounted) return;
    _setOverride(a, 'folder_id', picked);
  }

  List<Widget> _split(ThinkAction a) {
    final o = _overrides[a.id];
    final summary = o?['summary'] != null ? ThinkSplitSummary.fromJson(o!['summary']) : a.splitSummary;
    final folderId = o == null ? a.folderId : o['folder_id'] as String?;
    return [
      if (a.splitStartPreview.isNotEmpty) ...[
        thinkCodeLabel('여기부터 나눕니다'),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: kThinkQuote, borderRadius: BorderRadius.circular(8)),
          child: Text(a.splitStartPreview,
              maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kThinkText, fontSize: 12, height: 1.5)),
        ),
      ],
      _note('들어갈 폴더: ${thinkSplitFolderLabel(_c.tree, folderId, fallbackPath: o == null ? a.splitFolderPath : '')}'),
      _note('이번 질문과 답변만 새 대화에 복사하고, 이 대화는 그대로 남습니다. 승인 뒤 결과에서 새 대화를 열 수 있습니다. '
          '요약은 새 대화의 참고 자료일 뿐 기억으로 저장하지 않습니다.'),
      _note('"이번에는 거절"하면 이 대화에서는 Think가 다시 나누자고 하지 않습니다. 직접 나누자고 하면 다시 제안합니다.',
          color: kThinkHint),
      _Fold(title: '새 대화에 넘길 요약', child: ThinkSplitSummaryView(summary: summary)),
      _editButton(
        '제목·폴더·요약 고치기',
        _busy
            ? null
            : () async {
                final edited = await ThinkSplitEditDialog.show(
                  context,
                  title: (o?['title'] ?? a.title).toString(),
                  folderId: folderId,
                  summary: summary,
                  tree: _c.tree,
                  confirmLabel: '고친 내용 담기',
                );
                if (edited == null || !mounted) return;
                setState(() {
                  _overrides[a.id] = edited.toOverrides();
                  _checked.add(a.id);
                });
              },
      ),
    ];
  }

  ThinkMemoryProposal _memoryOf(ThinkAction a) {
    final raw = _overrides[a.id]?['memory'];
    return raw is Map ? ThinkMemoryProposal.fromJson(Map<String, dynamic>.from(raw)) : a.memoryProposal;
  }

  Future<void> _editMemory(ThinkAction a, {String confirmLabel = '고친 내용 담기'}) async {
    final edited = await ThinkMemoryEditDialog.show(
      context,
      memory: _memoryOf(a),
      showScope: _c.rolesReady,
      confirmLabel: confirmLabel,
    );
    if (edited == null || !mounted) return;
    _setOverride(a, 'memory', edited.toJson());
  }

  List<Widget> _memory(ThinkAction a) {
    return [
      const SizedBox(height: 4),
      ThinkMemoryProposalView(memory: _memoryOf(a)),
      if (a.supersedesTitle.isNotEmpty)
        _note('확정된 기억 "${a.supersedesTitle}"을(를) 대체합니다. 승인하면 앞 기억은 "대체됨"이 되고 Think가 더 쓰지 않습니다.',
            color: kThinkLink, icon: Icons.swap_horiz),
      _note('승인하면 바로 확정 기억으로 저장되고 다음 대화부터 Think가 참고합니다.', icon: Icons.verified_outlined),
      _editButton('내용·범위 고치기', _busy ? null : () => _editMemory(a)),
    ];
  }

  List<Widget> _memoryChange(ThinkAction a) {
    final op = a.memoryCardOp;
    final m = _memoryOf(a);
    return [
      if (op != 'withdraw' && !m.isEmpty) ...[
        thinkCodeLabel(op == 'replace' ? '새 카드 내용' : '고칠 내용'),
        ThinkMemoryProposalView(memory: m),
      ],
      _note(switch (op) {
        'withdraw' => '승인하면 대기 중인 카드를 닫습니다. 이미 저장된 기억은 바뀌지 않습니다.',
        'replace' => '승인하면 대상 카드를 닫고 이 내용으로 새 기억 저장 카드를 올립니다. 저장은 새 카드에서 다시 승인해야 합니다.',
        _ => '승인하면 대상 카드의 내용이 이렇게 바뀝니다. 저장은 그 카드에서 다시 승인해야 합니다.',
      }),
      if (op != 'withdraw') _editButton('내용 고치기', _busy ? null : () => _editMemory(a)),
    ];
  }

  List<Widget> _messages(ThinkAction a) {
    final exclude = a.kind == ThinkActionKind.excludeContext;
    final picked = _pickedOf(a);
    final targets = a.organizeTargets;
    final docs = a.linkedDocuments;
    final mems = a.linkedMemories;
    return [
      const SizedBox(height: 4),
      for (final t in targets)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: picked.contains(t.id),
              visualDensity: VisualDensity.compact,
              activeColor: kThinkAccent,
              side: const BorderSide(color: kThinkSub),
              onChanged: _busy || (picked.contains(t.id) && picked.length == 1)
                  ? null
                  : (v) => setState(() {
                        final next = {...picked};
                        v == true ? next.add(t.id) : next.remove(t.id);
                        _picks[a.id] = next;
                      }),
            ),
            SizedBox(
              width: 44,
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  t.isUser ? '질문' : 'Think',
                  style: TextStyle(color: t.isUser ? kThinkSub : kThinkAccent, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 4),
                child: Text(
                  t.excerpt.isEmpty ? '(빈 메시지)' : t.excerpt,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: picked.contains(t.id) ? kThinkText : kThinkHint, fontSize: 12, height: 1.4),
                ),
              ),
            ),
            IconButton(
              tooltip: '원문 보기',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              color: kThinkLink,
              icon: const Icon(Icons.open_in_new),
              onPressed: () => _reveal([t.id]),
            ),
          ],
        ),
      if (exclude) ...[
        thinkCodeLabel('이후 답변에 미치는 영향'),
        SelectableText(
          a.exclusionImpact.isEmpty ? '(적지 않음)' : a.exclusionImpact,
          style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5),
        ),
        if (docs.isNotEmpty)
          _note('이 메시지로 만든 문서는 그대로 남습니다(따로 판단): ${docs.map((d) => d.title).join(', ')}',
              color: kThinkLink, icon: Icons.description_outlined),
        if (mems.isNotEmpty)
          _note('이 메시지에서 저장한 확정 기억은 그대로 남습니다(따로 판단): ${mems.map((m) => m.title).join(', ')}',
              color: kThinkLink, icon: Icons.bookmark_outline),
        if (a.exclusionHasSummary)
          _note('승인된 진행 요약에 이 내용이 남아 있을 수 있습니다. 필요하면 요약을 새로 받아 주세요.',
              color: kThinkLink, icon: Icons.summarize_outlined),
        _note('메시지는 지우지 않고 화면과 기록에 남습니다. 승인한 뒤에도 답변 아래 줄에서 되돌릴 수 있습니다.'),
      ] else
        _note('화면에서 눈여겨볼 표시일 뿐, Think가 반드시 지켜야 하는 원칙이 되지는 않습니다.'),
    ];
  }

  ThinkProgressSummary _summaryOf(ThinkAction a) {
    final raw = _overrides[a.id]?['summary'];
    return raw is Map ? ThinkProgressSummary.fromJson(raw) : a.progressSummaryProposal;
  }

  List<Widget> _summary(ThinkAction a) {
    final previous = a.previousProgressSummary;
    final detail = _c.details[a.conversationId];
    final changed = detail != null && (detail.progressSummary?.actionId ?? '') != (a.progressSummaryBaseActionId ?? '');
    return [
      const SizedBox(height: 4),
      ThinkProgressSummaryView(summary: _summaryOf(a), proposal: true),
      if (previous != null) _Fold(title: '지금 승인된 요약과 비교', child: ThinkProgressSummaryView(summary: previous)),
      if (changed)
        _note('그사이 이 대화의 진행 요약이 바뀌었습니다. 승인하면 충돌로 멈추니, 새로 요약을 받아 주세요.',
            color: kThinkError, icon: Icons.warning_amber_rounded),
      _note('승인해도 코드 작업·배포·DB 변경은 시작되지 않습니다. 다음 행동은 계획으로만 저장되고 다음 답변부터 참고 자료로 들어갑니다.',
          icon: Icons.info_outline),
      _editButton(
        '요약 고치기',
        _busy
            ? null
            : () async {
                final edited = await ThinkProgressSummaryEditDialog.show(context, summary: _summaryOf(a));
                if (edited == null || !mounted) return;
                _setOverride(a, 'summary', edited.toJson());
              },
      ),
    ];
  }

  ThinkCriteriaView _criteriaOf(ThinkAction a) => _criteriaEdits[a.id] ?? a.criteriaAfter;

  List<Widget> _criteria(ThinkAction a) {
    final dept = a.criteriaDepartment;
    final current = dept == null ? null : _c.departmentCriteria[dept];
    final changed = current != null && current.version != a.criteriaBaseVersion;
    return [
      const SizedBox(height: 4),
      ThinkCriteriaDiffView(before: a.criteriaBefore, after: _criteriaOf(a)),
      if (changed)
        _note('그사이 이 부서 기준이 바뀌었습니다(판 ${a.criteriaBaseVersion} → ${current.version}). 승인하면 충돌로 멈춥니다.',
            color: kThinkError, icon: Icons.warning_amber_rounded),
      _note('볼 수 있는 자료(권한)는 바뀌지 않습니다. 이 부서가 먼저 확인할 질문·위험과 먼저 참고할 확정 기억만 바뀝니다.',
          icon: Icons.info_outline),
      if (dept != null)
        _editButton(
          '기준 고치기',
          _busy
              ? null
              : () async {
                  final edited = await ThinkCriteriaEditDialog.show(
                    context,
                    department: dept,
                    initial: _criteriaOf(a),
                    confirmLabel: '고친 내용 담기',
                  );
                  if (edited == null || !mounted) return;
                  _criteriaEdits[a.id] = edited;
                  _setOverride(a, 'criteria', edited.toCriteriaJson());
                },
        ),
    ];
  }
}

/// 접어 두는 칸(요약 비교 등).
class _Fold extends StatefulWidget {
  const _Fold({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  State<_Fold> createState() => _FoldState();
}

class _FoldState extends State<_Fold> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          child: InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(_open ? Icons.expand_less : Icons.expand_more, size: 16, color: kThinkSub),
                  const SizedBox(width: 4),
                  Text(widget.title, style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
        ),
        if (_open)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(color: kThinkQuote, borderRadius: BorderRadius.circular(8)),
            child: widget.child,
          ),
      ],
    );
  }
}

// =====================================================================================
// 진행 요약
// =====================================================================================

/// 진행 요약 다섯 칸. [proposal]이면 "Think 제안 · 승인 전"으로, 아니면 승인된 요약으로 보인다.
class ThinkProgressSummaryView extends StatelessWidget {
  const ThinkProgressSummaryView({super.key, required this.summary, this.proposal = false, this.compact = false});

  final ThinkProgressSummary summary;
  final bool proposal;

  /// 맥락 패널처럼 좁은 곳(글자 12).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 12.0 : 13.0;
    Widget empty() => Text('없음', style: TextStyle(color: kThinkHint, fontSize: size));
    Widget text(String v) =>
        v.isEmpty ? empty() : SelectableText(v, style: TextStyle(color: kThinkText, fontSize: size, height: 1.5));
    Widget list(List<String> v) => v.isEmpty ? empty() : thinkCodeBullets(v);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (proposal) ...[
          const SizedBox(height: 4),
          const Align(alignment: Alignment.centerLeft, child: ThinkBadge('Think 제안 · 승인 전', color: kThinkLink)),
        ],
        thinkCodeLabel('목적'),
        text(summary.purpose),
        thinkCodeLabel('확정 사항 (사용자가 정한 것)'),
        list(summary.decided),
        thinkCodeLabel('미결 사항'),
        list(summary.open),
        thinkCodeLabel('지금 상태'),
        text(summary.status),
        thinkCodeLabel('다음 행동 (계획 · 실행 지시 아님)'),
        if (summary.next.isEmpty)
          empty()
        else
          for (final n in summary.next) _nextLine(n, size),
      ],
    );
  }

  Widget _nextLine(ThinkNextAction n, double size) {
    final meta = [
      if (n.owner.isNotEmpty) '담당: ${n.owner}',
      if (n.prerequisite.isNotEmpty) '먼저: ${n.prerequisite}',
      if (n.doneWhen.isNotEmpty) '완료 기준: ${n.doneWhen}',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText('· ${n.what}', style: TextStyle(color: kThinkText, fontSize: size, height: 1.5)),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text(
              meta.isEmpty ? '담당·완료 기준 정하지 않음' : meta.join(' · '),
              style: TextStyle(color: meta.isEmpty ? kThinkHint : kThinkSub, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// 진행 요약 고치기. 담당·기한·우선순위는 사용자가 정한 것만 적게 한다.
class ThinkProgressSummaryEditDialog extends StatefulWidget {
  const ThinkProgressSummaryEditDialog({super.key, required this.summary});

  final ThinkProgressSummary summary;

  static Future<ThinkProgressSummary?> show(BuildContext context, {required ThinkProgressSummary summary}) =>
      showDialog<ThinkProgressSummary>(context: context, builder: (_) => ThinkProgressSummaryEditDialog(summary: summary));

  @override
  State<ThinkProgressSummaryEditDialog> createState() => _ThinkProgressSummaryEditDialogState();
}

class _NextFields {
  _NextFields(ThinkNextAction n)
      : what = TextEditingController(text: n.what),
        owner = TextEditingController(text: n.owner),
        prerequisite = TextEditingController(text: n.prerequisite),
        doneWhen = TextEditingController(text: n.doneWhen);

  final TextEditingController what;
  final TextEditingController owner;
  final TextEditingController prerequisite;
  final TextEditingController doneWhen;

  void dispose() {
    for (final c in [what, owner, prerequisite, doneWhen]) {
      c.dispose();
    }
  }

  ThinkNextAction get value => ThinkNextAction(
        what: what.text.trim(),
        owner: owner.text.trim(),
        prerequisite: prerequisite.text.trim(),
        doneWhen: doneWhen.text.trim(),
      );
}

List<String> _lines(TextEditingController c) => [
      for (final raw in c.text.split('\n'))
        if (raw.trim().replaceFirst(RegExp(r'^[·•\-*]\s*'), '').isNotEmpty) raw.trim().replaceFirst(RegExp(r'^[·•\-*]\s*'), ''),
    ];

Widget _dialogField(TextEditingController c, String label, {int minLines = 1, int maxLines = 4, int? maxLength, bool dense = false}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        minLines: minLines,
        maxLines: maxLines,
        inputFormatters: maxLength == null ? null : [LengthLimitingTextInputFormatter(maxLength)],
        style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5),
        decoration: thinkInputDecoration(label: label, dense: dense),
      ),
    );

class _ThinkProgressSummaryEditDialogState extends State<ThinkProgressSummaryEditDialog> {
  late final TextEditingController _purpose = TextEditingController(text: widget.summary.purpose);
  late final TextEditingController _decided = TextEditingController(text: widget.summary.decided.join('\n'));
  late final TextEditingController _open = TextEditingController(text: widget.summary.open.join('\n'));
  late final TextEditingController _status = TextEditingController(text: widget.summary.status);
  late final List<_NextFields> _next = widget.summary.next.map(_NextFields.new).toList();

  @override
  void dispose() {
    for (final c in [_purpose, _decided, _open, _status]) {
      c.dispose();
    }
    for (final n in _next) {
      n.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (_purpose.text.trim().isEmpty) return;
    Navigator.pop(
      context,
      ThinkProgressSummary(
        purpose: _purpose.text.trim(),
        decided: _lines(_decided),
        open: _lines(_open),
        status: _status.text.trim(),
        next: [for (final n in _next) if (n.value.what.isNotEmpty) n.value],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: const Text('진행 요약 고치기', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _dialogField(_purpose, '목적 (필수)', maxLines: 3, maxLength: 1000),
              _dialogField(_decided, '확정 사항 — 사용자가 실제로 정한 것만 (한 줄에 하나, 12줄까지)', minLines: 2, maxLines: 6),
              _dialogField(_open, '미결 사항 (한 줄에 하나, 12줄까지)', minLines: 2, maxLines: 6),
              _dialogField(_status, '지금 상태', minLines: 1, maxLines: 4, maxLength: 1000),
              const Text('다음 행동', style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              for (var i = 0; i < _next.length; i++) _nextRow(i),
              if (_next.length < 10)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _next.add(_NextFields(const ThinkNextAction(what: '')))),
                    icon: const Icon(Icons.add, size: 16, color: kThinkLink),
                    label: const Text('다음 행동 추가', style: TextStyle(color: kThinkLink)),
                  ),
                ),
              const SizedBox(height: 8),
              const Text(
                '담당·전제·완료 기준은 실제로 정한 것만 적어 주세요. 비워 두면 정하지 않은 것으로 남습니다. '
                '요약을 승인해도 코드 작업·배포·DB 변경은 시작되지 않습니다.',
                style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소', style: TextStyle(color: kThinkSub))),
        ListenableBuilder(
          listenable: _purpose,
          builder: (context, _) => ElevatedButton.icon(
            onPressed: _purpose.text.trim().isEmpty ? null : _submit,
            style: thinkPrimaryButton(),
            icon: const Icon(Icons.check, size: 16),
            label: const Text('고친 내용 담기'),
          ),
        ),
      ],
    );
  }

  Widget _nextRow(int i) {
    final n = _next[i];
    return Container(
      key: ObjectKey(n),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 0),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: kThinkBorder)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _dialogField(n.what, '할 일', maxLines: 2, maxLength: 300, dense: true),
                Row(
                  children: [
                    Expanded(child: _dialogField(n.owner, '담당 (정했으면)', maxLines: 1, maxLength: 60, dense: true)),
                    const SizedBox(width: 8),
                    Expanded(child: _dialogField(n.prerequisite, '먼저 필요한 것', maxLines: 2, maxLength: 300, dense: true)),
                  ],
                ),
                _dialogField(n.doneWhen, '완료 기준', maxLines: 2, maxLength: 300, dense: true),
              ],
            ),
          ),
          IconButton(
            tooltip: '이 행동 빼기',
            color: kThinkSub,
            iconSize: 18,
            onPressed: () {
              final removed = _next[i];
              setState(() => _next.removeAt(i));
              WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
            },
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}

// =====================================================================================
// 부서 기준
// =====================================================================================

/// 부서 기준의 전·후. 바뀐 줄만 강조한다.
class ThinkCriteriaDiffView extends StatelessWidget {
  const ThinkCriteriaDiffView({super.key, required this.before, required this.after});

  final ThinkCriteriaView before;
  final ThinkCriteriaView after;

  @override
  Widget build(BuildContext context) {
    Widget section(String label, List<String> b, List<String> a) {
      final removed = b.where((x) => !a.contains(x)).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          thinkCodeLabel(label),
          if (a.isEmpty && removed.isEmpty) const Text('없음', style: TextStyle(color: kThinkHint, fontSize: 13)),
          for (final x in a)
            Text(
              b.contains(x) ? '· $x' : '+ $x',
              style: TextStyle(
                color: b.contains(x) ? kThinkText : kThinkAccent,
                fontSize: 13,
                height: 1.5,
                fontWeight: b.contains(x) ? FontWeight.w400 : FontWeight.w700,
              ),
            ),
          for (final x in removed)
            Text(
              '− $x',
              style: const TextStyle(color: kThinkHint, fontSize: 13, height: 1.5, decoration: TextDecoration.lineThrough),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        section('먼저 확인할 질문', before.questions, after.questions),
        section('놓치면 안 되는 위험', before.risks, after.risks),
        section(
          '먼저 참고할 확정 기억',
          before.priorityMemories.map((m) => m.title).toList(),
          after.priorityMemories.map((m) => m.title).toList(),
        ),
      ],
    );
  }
}

/// 부서 기준 고치기. 우선 기억은 그 부서가 볼 수 있는 확정 기억에서만 고른다(서버도 다시 확인한다).
class ThinkCriteriaEditDialog extends StatefulWidget {
  const ThinkCriteriaEditDialog({super.key, required this.department, required this.initial, required this.confirmLabel});

  final ThinkRoleId department;
  final ThinkCriteriaView initial;
  final String confirmLabel;

  static Future<ThinkCriteriaView?> show(
    BuildContext context, {
    required ThinkRoleId department,
    required ThinkCriteriaView initial,
    String confirmLabel = '저장',
  }) =>
      showDialog<ThinkCriteriaView>(
        context: context,
        builder: (_) => ThinkCriteriaEditDialog(department: department, initial: initial, confirmLabel: confirmLabel),
      );

  @override
  State<ThinkCriteriaEditDialog> createState() => _ThinkCriteriaEditDialogState();
}

class _ThinkCriteriaEditDialogState extends State<ThinkCriteriaEditDialog> {
  static const int _maxItems = 8;

  late final TextEditingController _questions = TextEditingController(text: widget.initial.questions.join('\n'));
  late final TextEditingController _risks = TextEditingController(text: widget.initial.risks.join('\n'));
  late final List<ThinkCriteriaMemoryRef> _memories = [...widget.initial.priorityMemories];

  @override
  void initState() {
    super.initState();
    final c = ThinkController.instance;
    if (c.memories.isEmpty && !c.memoriesLoading) c.refreshMemories();
  }

  @override
  void dispose() {
    _questions.dispose();
    _risks.dispose();
    super.dispose();
  }

  bool _visible(ThinkMemory m) =>
      m.status == ThinkMemoryStatus.active &&
      (m.kind == ThinkMemoryKind.identity ||
          m.memoryScope != ThinkMemoryScope.department ||
          widget.department == ThinkRoleId.lead ||
          m.scopeDepartment?.db == widget.department.db);

  Future<void> _addMemory() async {
    final taken = {for (final m in _memories) m.id};
    final options = ThinkController.instance.memories.where((m) => _visible(m) && !taken.contains(m.id)).toList();
    final picked = await showDialog<ThinkMemory>(
      context: context,
      builder: (ctx) => _MemoryPickDialog(options: options),
    );
    if (picked == null || !mounted) return;
    setState(() => _memories.add(ThinkCriteriaMemoryRef(id: picked.id, title: picked.title)));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text('${widget.department.label} 부서 기준', style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _dialogField(_questions, '먼저 확인할 질문 (한 줄에 하나, 8줄까지)', minLines: 2, maxLines: 8),
              _dialogField(_risks, '놓치면 안 되는 위험 (한 줄에 하나, 8줄까지)', minLines: 2, maxLines: 8),
              const Text('먼저 참고할 확정 기억', style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              if (_memories.isEmpty)
                const Text('없음', style: TextStyle(color: kThinkHint, fontSize: 13))
              else
                for (var i = 0; i < _memories.length; i++)
                  Row(
                    children: [
                      const Icon(Icons.bookmark_outline, size: 14, color: kThinkAccent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _memories[i].title.isEmpty ? '(제목 없음)' : _memories[i].title,
                          style: const TextStyle(color: kThinkText, fontSize: 13),
                        ),
                      ),
                      IconButton(
                        tooltip: '빼기',
                        color: kThinkSub,
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setState(() => _memories.removeAt(i)),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
              if (_memories.length < _maxItems)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _addMemory,
                    icon: const Icon(Icons.add, size: 16, color: kThinkLink),
                    label: const Text('기억 고르기', style: TextStyle(color: kThinkLink)),
                  ),
                ),
              const SizedBox(height: 8),
              const Text(
                '볼 수 있는 자료(권한)는 바뀌지 않습니다. 이 부서가 답할 때 먼저 확인할 것만 정합니다. '
                '우선 기억도 그 부서가 볼 수 있는 확정 기억만 넣을 수 있습니다.',
                style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소', style: TextStyle(color: kThinkSub))),
        ElevatedButton.icon(
          onPressed: () => Navigator.pop(
            context,
            ThinkCriteriaView(
              questions: _lines(_questions).take(_maxItems).toList(),
              risks: _lines(_risks).take(_maxItems).toList(),
              priorityMemories: [..._memories],
            ),
          ),
          style: thinkPrimaryButton(),
          icon: const Icon(Icons.check, size: 16),
          label: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _MemoryPickDialog extends StatefulWidget {
  const _MemoryPickDialog({required this.options});

  final List<ThinkMemory> options;

  @override
  State<_MemoryPickDialog> createState() => _MemoryPickDialogState();
}

class _MemoryPickDialogState extends State<_MemoryPickDialog> {
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
      title: const Text('먼저 참고할 기억 고르기', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              style: const TextStyle(color: kThinkText, fontSize: 13),
              decoration: thinkInputDecoration(hint: '제목으로 찾기', prefixIcon: const Icon(Icons.search, size: 18, color: kThinkSub), dense: true),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Builder(
                builder: (context) {
                  final q = _query.text.trim().toLowerCase();
                  final list = widget.options.where((m) => q.isEmpty || m.title.toLowerCase().contains(q)).toList();
                  if (list.isEmpty) {
                    return const Center(
                      child: Text('고를 수 있는 확정 기억이 없습니다.', style: TextStyle(color: kThinkHint, fontSize: 13)),
                    );
                  }
                  return ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final m = list[i];
                      return InkWell(
                        onTap: () => Navigator.pop(context, m),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                          child: Row(
                            children: [
                              ThinkBadge(m.kind.label, color: kThinkAccent),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(m.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: kThinkText, fontSize: 13)),
                              ),
                              const SizedBox(width: 8),
                              Text(m.scopeLabel, style: const TextStyle(color: kThinkHint, fontSize: 12)),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('닫기', style: TextStyle(color: kThinkSub))),
      ],
    );
  }
}

/// 부서 기준 보기와 직접 고치기. 승인된 제안과 운영자 수정이 같은 판 번호로 이어진다.
Future<void> showThinkDepartmentCriteriaDialog(BuildContext context, {ThinkRoleId department = ThinkRoleId.lead}) =>
    showDialog<void>(context: context, builder: (_) => _CriteriaDialog(initial: department));

class _CriteriaDialog extends StatefulWidget {
  const _CriteriaDialog({required this.initial});

  final ThinkRoleId initial;

  @override
  State<_CriteriaDialog> createState() => _CriteriaDialogState();
}

class _CriteriaDialogState extends State<_CriteriaDialog> {
  ThinkController get _c => ThinkController.instance;
  late ThinkRoleId _dept = widget.initial;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _c.refreshDepartmentCriteria();
    if (_c.memories.isEmpty && !_c.memoriesLoading) _c.refreshMemories();
  }

  ThinkCriteriaView _viewOf(ThinkDepartmentCriteria c) => ThinkCriteriaView(
        questions: c.questions,
        risks: c.risks,
        priorityMemories: [
          for (final id in c.priorityMemoryIds) ThinkCriteriaMemoryRef(id: id, title: _c.memoryById(id)?.title ?? '(목록에 없는 기억)'),
        ],
      );

  Future<void> _edit(ThinkDepartmentCriteria c) async {
    final edited = await ThinkCriteriaEditDialog.show(context, department: c.department, initial: _viewOf(c));
    if (edited == null || !mounted) return;
    setState(() => _saving = true);
    final err = await _c.saveDepartmentCriteria(
      c,
      questions: edited.questions,
      risks: edited.risks,
      priorityMemoryIds: [for (final m in edited.priorityMemories) m.id],
    );
    if (!mounted) return;
    setState(() => _saving = false);
    showThinkSnack(context, err ?? '${c.department.label} 부서 기준을 저장했습니다. 다음 답변부터 반영됩니다.', error: err != null);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final c = _c.departmentCriteria[_dept];
        return AlertDialog(
          backgroundColor: kThinkBg,
          shape: thinkDialogShape,
          title: const Text('부서 기준', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final d in ThinkRoleId.values)
                        ThinkToggleChip(
                          label: d.label,
                          icon: Icons.rule,
                          selected: d == _dept,
                          onChanged: (_) => setState(() => _dept = d),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_c.criteriaError != null)
                    ThinkNotice(text: _c.criteriaError!, color: kThinkError, icon: Icons.error_outline)
                  else if (c == null)
                    Text(
                      _c.criteriaLoading ? '불러오는 중…' : '이 부서 기준이 없습니다. DB 반영이 필요할 수 있습니다.',
                      style: const TextStyle(color: kThinkHint, fontSize: 13),
                    )
                  else ...[
                    Text(
                      '판 ${c.version}'
                      '${c.updatedAt == null ? '' : ' · ${formatDateTime(c.updatedAt)}'}'
                      '${c.updatedVia == null ? '' : c.updatedVia == 'owner' ? ' · 직접 고침' : ' · 제안 승인'}',
                      style: const TextStyle(color: kThinkHint, fontSize: 12),
                    ),
                    ThinkCriteriaDiffView(before: _viewOf(c), after: _viewOf(c)),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                    '부서가 답할 때 먼저 확인할 질문·위험과 먼저 참고할 확정 기억입니다. 볼 수 있는 자료(권한)와는 별개입니다. '
                    'Think가 바꾸자고 하면 정리 패널에서 승인해야 바뀝니다.',
                    style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('닫기', style: TextStyle(color: kThinkSub))),
            ElevatedButton.icon(
              onPressed: c == null || _saving ? null : () => _edit(c),
              style: thinkPrimaryButton(),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('고치기'),
            ),
          ],
        );
      },
    );
  }
}
