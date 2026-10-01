import 'package:flutter/material.dart';

import '../../services/think/think_action_models.dart';
import '../../services/think/think_api.dart';
import '../../services/think/think_code_controller.dart';
import '../../services/think/think_code_models.dart';
import '../../services/think/think_controller.dart';
import 'think_code_request_dialog.dart';
import 'think_code_views.dart';
import 'think_markdown.dart';
import 'think_style.dart';
import 'think_tree_dialogs.dart';

// 채팅 답변 아래에 붙는 작업 카드. AI가 낸 제안(ai_actions)은 여기서 사람이 승인해야 실행된다.
// 설계: docs/architecture/ai-think-actions.md

const Map<String, String> _reviewSkipReasons = {
  'ai_not_configured': '서버에 OpenAI 키가 없습니다',
  'budget_exceeded': '이번 달 AI 사용 한도를 넘었습니다',
};

const String _leaseExpired = 'lease_expired_state_unknown';

mixin _BusyState<T extends StatefulWidget> on State<T> {
  bool busy = false;

  Future<void> run(Future<void> Function() action, {String? done}) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
      if (mounted && done != null) showThinkSnack(context, done);
    } catch (e) {
      if (mounted) showThinkSnack(context, ThinkApi.codeErrorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

class _CardFrame extends StatelessWidget {
  const _CardFrame({
    required this.icon,
    required this.label,
    required this.children,
    this.badge,
    this.trailing,
    this.accent = kThinkAccent,
    this.border = kThinkBorder,
  });

  final IconData icon;
  final String label;
  final List<Widget> children;
  final Widget? badge;
  final Widget? trailing;
  final Color accent;
  final Color border;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: kThinkBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: accent),
                  const SizedBox(width: 8),
                  Text(label, style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
                  if (badge != null) ...[const SizedBox(width: 8), badge!],
                  const Spacer(),
                  if (trailing != null) trailing!,
                ],
              ),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// 끝난 제안(거절·대체·되돌림)은 한 줄로 줄인다.
class _ClosedLine extends StatelessWidget {
  const _ClosedLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: kThinkHint),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kThinkHint, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

Widget _title(String text) => SelectableText(
      text,
      style: const TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800, height: 1.4),
    );

Widget _gap([double h = 12]) => SizedBox(height: h);

Widget _workerLine(ThinkCodeController c) {
  final online = c.onlineWorker;
  final last = c.lastWorker;
  final String text;
  if (online != null) {
    text = '작업자 켜짐 · ${online.workerId}${online.currentRequestId != null ? ' · 작업 중' : ''}';
  } else {
    text = last == null ? '작업자가 아직 연결된 적이 없습니다' : '작업자 꺼짐 · 마지막 신호 ${formatRelative(last.lastSeenAt)}';
  }
  return Tooltip(
    message: '이 PC에서 tools/code_bridge 폴더의 npm start로 켭니다. 켜기 전에 보낸 요청은 대기열에서 기다립니다.',
    child: Row(
      children: [
        Icon(Icons.circle, size: 8, color: online != null ? kThinkSuccess : kThinkHint),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(color: kThinkSub, fontSize: 12))),
        Text('오늘 ${c.submittedToday}/${c.dailyLimit}건', style: const TextStyle(color: kThinkHint, fontSize: 12)),
      ],
    ),
  );
}

// =====================================================================================
// 제안 카드
// =====================================================================================

class ThinkActionCard extends StatefulWidget {
  const ThinkActionCard({super.key, required this.action});

  final ThinkAction action;

  @override
  State<ThinkActionCard> createState() => _ThinkActionCardState();
}

class _ThinkActionCardState extends State<ThinkActionCard> with _BusyState {
  ThinkController get _think => ThinkController.instance;
  ThinkCodeController get _code => ThinkCodeController.instance;

  ThinkAction get a => widget.action;

  @override
  Widget build(BuildContext context) {
    if (a.superseded) {
      return _ClosedLine(icon: Icons.low_priority, text: '${a.kind.label} 제안 · 새 제안으로 대체됨${a.title.isEmpty ? '' : ' · ${a.title}'}');
    }
    if (a.status == ThinkActionStatus.rejected) {
      return _ClosedLine(icon: Icons.block, text: '${a.kind.label} 제안 · 거절함${_subject.isEmpty ? '' : ' · $_subject'}');
    }
    if (a.status == ThinkActionStatus.failed) {
      return _CardFrame(
        icon: Icons.error_outline,
        label: a.kind.label,
        accent: kThinkError,
        badge: ThinkBadge(a.status.label, color: kThinkError),
        children: [ThinkNotice(text: a.error ?? '실행하지 못했습니다.', color: kThinkError, icon: Icons.error_outline)],
      );
    }
    if (a.kind.isCode) {
      if (a.pending) return ListenableBuilder(listenable: _code, builder: (_, __) => _codeProposal());
      return ListenableBuilder(listenable: _code, builder: (_, __) => _codeApplied());
    }
    if (a.kind == ThinkActionKind.placeConversation) return _placement();
    return _delete();
  }

  String get _subject => (a.preview['title'] ?? a.preview['path'] ?? '').toString();

  // ------------------------------------------------------------ 코드
  Widget _codeProposal() {
    final change = a.kind == ThinkActionKind.codeChange;
    final mode = change ? ThinkCodeMode.change : ThinkCodeMode.investigate;
    final spec = ThinkCodeSpec.fromJson(a.payload['spec']);
    final basedOn = a.payload['spec'] is Map ? (a.payload['spec'] as Map)['based_on'] : null;
    final basedTitle = basedOn is Map ? (basedOn['title'] ?? '').toString() : '';
    return _CardFrame(
      icon: change ? Icons.build_outlined : Icons.manage_search,
      label: change ? '코드 수정 제안' : '코드 조사 제안',
      badge: const ThinkBadge('승인 대기', color: kThinkLink),
      children: [
        _title(a.title),
        _gap(8),
        ThinkCodeSpecView(spec: spec, mode: mode),
        if (basedTitle.isNotEmpty) ...[
          thinkCodeLabel('근거로 삼은 조사'),
          Text(basedTitle, style: const TextStyle(color: kThinkLink, fontSize: 13)),
        ],
        _gap(),
        ThinkNotice(
          icon: change ? Icons.shield_outlined : Icons.manage_search,
          text: change
              ? '보내면 Cursor가 지금 작업 폴더를 복사한 격리 폴더에서만 코드를 고치고 변경(diff)을 돌려줍니다. '
                  '실제 작업 폴더는 diff를 확인한 뒤 한 번 더 승인해야 바뀝니다. 셸 명령은 쓰지 않습니다.'
              : '보내면 Cursor가 저장소를 읽기만 하고 결과를 돌려줍니다. 결과가 오면 Think가 검토해 이 대화에 답합니다.',
        ),
        _gap(),
        _workerLine(_code),
        _gap(),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ElevatedButton.icon(
              onPressed: busy ? null : () => run(() => _think.applyAction(a), done: '보냈습니다. 진행 상황은 이 카드에 표시됩니다.'),
              style: thinkPrimaryButton(),
              icon: const Icon(Icons.send, size: 16),
              label: const Text('보내기'),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : () => _editAndSend(spec, mode),
              style: thinkOutlineButton(),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('고쳐서 보내기'),
            ),
            TextButton(
              onPressed: busy ? null : () => run(() => _think.rejectAction(a)),
              child: const Text('거절', style: TextStyle(color: kThinkSub)),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _editAndSend(ThinkCodeSpec spec, ThinkCodeMode mode) async {
    final edited = await ThinkCodeProposalDialog.show(context, title: a.title, spec: spec, mode: mode);
    if (edited == null || !mounted) return;
    // 기억 참조(memory_refs)·근거(based_on)처럼 화면에 없는 칸은 원래 제안 그대로 둔다.
    final raw = a.payload['spec'] is Map ? Map<String, dynamic>.from(a.payload['spec'] as Map) : <String, dynamic>{};
    final merged = {...raw, ...edited.spec.toJson()};
    if (mode == ThinkCodeMode.change) {
      merged.remove('background');
      merged['instructions'] = edited.spec.instructions;
    }
    await run(
      () => _think.applyAction(a, overrides: {'title': edited.title, 'spec': merged}),
      done: '고친 내용으로 보냈습니다.',
    );
  }

  Widget _codeApplied() {
    final id = a.codeRequestId;
    final r = _code.byId(id);
    if (r != null) return ThinkCodeRequestCard(request: r);
    final change = a.kind == ThinkActionKind.codeChange;
    return _CardFrame(
      icon: change ? Icons.build_outlined : Icons.manage_search,
      label: change ? '코드 수정' : '코드 조사',
      children: [
        _title(a.title),
        _gap(8),
        Text(
          _code.loading || _code.requests.isEmpty ? '요청 상태를 불러오는 중…' : '요청을 찾지 못했습니다. 삭제되었을 수 있습니다.',
          style: const TextStyle(color: kThinkHint, fontSize: 12),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 대화 분류
  Widget _placement() {
    final tree = _think.tree;
    final isNew = a.newFolderTitle != null;
    final path = (a.preview['path'] ?? '').toString();
    final current = (a.preview['current'] ?? '').toString();
    final reason = (a.preview['reason'] ?? '').toString();
    if (a.status == ThinkActionStatus.undone) {
      return _ClosedLine(icon: Icons.undo, text: '대화 분류 · 되돌림 · $path');
    }
    if (a.status == ThinkActionStatus.applied) {
      final placed = a.placedFolderId;
      final placedPath = placed == null ? path : (tree.byId[placed] == null ? path : tree.folderPath(placed));
      return _CardFrame(
        icon: Icons.drive_file_move_outline,
        label: '대화 분류',
        badge: const ThinkBadge('넣음', color: kThinkSuccess),
        trailing: TextButton.icon(
          onPressed: busy ? null : () => run(() => _think.undoAction(a), done: '분류를 되돌렸습니다.'),
          icon: const Icon(Icons.undo, size: 16, color: kThinkSub),
          label: const Text('되돌리기', style: TextStyle(color: kThinkSub)),
        ),
        children: [
          Text('이 대화를 "$placedPath" 폴더에 넣었습니다.', style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
        ],
      );
    }
    return _CardFrame(
      icon: Icons.drive_file_move_outline,
      label: '대화 분류 제안',
      badge: const ThinkBadge('승인 대기', color: kThinkLink),
      children: [
        Row(
          children: [
            Icon(isNew ? Icons.create_new_folder_outlined : Icons.folder_outlined, size: 18, color: kThinkAccent),
            const SizedBox(width: 8),
            Flexible(child: _title(path)),
            if (isNew) ...[const SizedBox(width: 8), const ThinkBadge('새 폴더', color: kThinkAccent)],
          ],
        ),
        _gap(8),
        Text('지금 위치: ${current.isEmpty ? '정리 안 됨' : current}', style: const TextStyle(color: kThinkSub, fontSize: 12)),
        if (reason.isNotEmpty) ...[
          _gap(8),
          SelectableText(reason, style: const TextStyle(color: kThinkSub, fontSize: 13, height: 1.5)),
        ],
        _gap(),
        Text(
          isNew
              ? '왼쪽 트리에 만들 폴더 자리를 흐리게 표시했습니다. 넣기 전에는 폴더도 만들지 않습니다.'
              : '왼쪽 트리에 제안한 폴더를 강조했습니다. 넣기 전에는 아무것도 바뀌지 않습니다.',
          style: const TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
        ),
        _gap(),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ElevatedButton.icon(
              onPressed: busy ? null : () => run(() => _think.applyAction(a), done: isNew ? '폴더를 만들고 넣었습니다.' : '폴더에 넣었습니다.'),
              style: thinkPrimaryButton(),
              icon: const Icon(Icons.check, size: 16),
              label: Text(isNew ? '폴더 만들고 넣기' : '여기에 넣기'),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : _pickOther,
              style: thinkOutlineButton(),
              icon: const Icon(Icons.folder_open_outlined, size: 16),
              label: const Text('다른 폴더에 넣기'),
            ),
            TextButton(
              onPressed: busy ? null : () => run(() => _think.rejectAction(a)),
              child: const Text('거절', style: TextStyle(color: kThinkSub)),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickOther() async {
    final tree = _think.tree;
    final node = tree.conversationNodes[a.conversationId];
    final picked = await showThinkFolderPicker(
      context,
      tree: tree,
      currentParentId: node?.parentId,
      allowRoot: false,
      title: '어느 폴더에 넣을까요?',
    );
    if (picked == null || picked == kThinkRootFolder || !mounted) return;
    await run(() => _think.applyAction(a, overrides: {'folder_id': picked}), done: '폴더에 넣었습니다.');
  }

  // ------------------------------------------------------------ 삭제
  Widget _delete() {
    final p = a.preview;
    final reason = (p['reason'] ?? '').toString();
    int n(String k) => p[k] is num ? (p[k] as num).toInt() : 0;
    if (a.status == ThinkActionStatus.applied) {
      return _ClosedLine(icon: Icons.delete_outline, text: '${a.kind.label} · 삭제함 · $_subject');
    }
    final List<Widget> what;
    switch (a.kind) {
      case ThinkActionKind.deleteCodeRequest:
        final status = ThinkCodeStatus.parse(p['status']?.toString());
        final mode = ThinkCodeMode.parse(p['mode']?.toString());
        what = [
          _title((p['title'] ?? '').toString()),
          _gap(8),
          Text('${mode.label} 요청 · ${status.label}', style: const TextStyle(color: kThinkSub, fontSize: 12)),
          _gap(8),
          const Text('요청과 조사·수정 결과가 지워집니다. 사용량 기록은 남습니다.', style: TextStyle(color: kThinkSub, fontSize: 13)),
        ];
      case ThinkActionKind.deleteFolder:
        what = [
          Row(
            children: [
              const Icon(Icons.folder_outlined, size: 18, color: kThinkSub),
              const SizedBox(width: 8),
              Flexible(child: _title((p['path'] ?? '').toString())),
            ],
          ),
          _gap(8),
          Text(
            n('children') > 0
                ? '안에 있는 ${n('children')}개 항목은 이 폴더가 있던 자리로 올라갑니다. 대화와 발췌는 지워지지 않습니다.'
                : '빈 폴더입니다.',
            style: const TextStyle(color: kThinkSub, fontSize: 13, height: 1.5),
          ),
        ];
      default:
        what = [
          _title((p['title'] ?? '').toString()),
          _gap(8),
          Text(
            '메시지 ${n('messages')}개와 발췌 ${n('excerpts')}개가 함께 지워집니다.'
            '${n('code_requests') > 0 ? ' 코드 요청 ${n('code_requests')}개는 남고 대화 연결만 끊깁니다.' : ''}',
            style: const TextStyle(color: kThinkSub, fontSize: 13, height: 1.5),
          ),
          if (p['is_current'] == true) ...[
            _gap(8),
            const ThinkNotice(
              text: '지금 보고 있는 이 대화입니다. 지우면 화면이 새 대화로 바뀝니다.',
              color: kThinkError,
              icon: Icons.warning_amber_rounded,
            ),
          ],
        ];
    }
    return _CardFrame(
      icon: Icons.delete_outline,
      label: '${a.kind.label} 제안',
      accent: kThinkError,
      border: kThinkError.withValues(alpha: 0.5),
      badge: const ThinkBadge('승인 대기', color: kThinkLink),
      children: [
        ...what,
        if (reason.isNotEmpty) ...[
          _gap(8),
          SelectableText('이유: $reason', style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.5)),
        ],
        _gap(),
        const Text('삭제는 되돌릴 수 없습니다.', style: TextStyle(color: kThinkError, fontSize: 12, fontWeight: FontWeight.w700)),
        _gap(),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ElevatedButton.icon(
              onPressed: busy ? null : _confirmDelete,
              style: thinkPrimaryButton(color: kThinkError),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('삭제'),
            ),
            TextButton(
              onPressed: busy ? null : () => run(() => _think.rejectAction(a)),
              child: const Text('거절', style: TextStyle(color: kThinkSub)),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _confirmDelete() async {
    final ok = await confirmThink(
      context,
      title: '정말 삭제할까요?',
      message: '"$_subject"을(를) 지웁니다. 되돌릴 수 없습니다.',
      confirmLabel: '삭제',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      setState(() => busy = true);
      await _think.applyAction(a);
      messenger.showSnackBar(const SnackBar(content: Text('삭제했습니다.'), backgroundColor: kThinkSuccess));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(ThinkApi.codeErrorMessage(e)), backgroundColor: kThinkError));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

// =====================================================================================
// 코드 요청 카드 (진행 상태·결과·적용)
// =====================================================================================

/// 코드 요청 하나의 진행 상태와 결과. [inChat]이면 결과를 요약하고 자세한 회차는 접어 둔다.
class ThinkCodeRequestCard extends StatefulWidget {
  const ThinkCodeRequestCard({super.key, required this.request, this.inChat = true});

  final ThinkCodeRequest request;
  final bool inChat;

  @override
  State<ThinkCodeRequestCard> createState() => _ThinkCodeRequestCardState();
}

class _ThinkCodeRequestCardState extends State<ThinkCodeRequestCard> with _BusyState {
  ThinkCodeController get _c => ThinkCodeController.instance;
  ThinkCodeRequest get r => widget.request;
  bool get _change => r.mode == ThinkCodeMode.change;

  ThinkCodeRound? _latest(List<ThinkCodeRound>? rounds) {
    if (rounds == null || rounds.isEmpty) return null;
    for (final x in rounds.reversed) {
      if (x.status != 'running') return x;
    }
    return rounds.last;
  }

  @override
  Widget build(BuildContext context) {
    if (r.status != ThinkCodeStatus.draft) _c.ensureRounds(r.id);
    final rounds = _c.roundsOf(r.id);
    final latest = _latest(rounds);
    final res = latest?.result;
    return _CardFrame(
      icon: _change ? Icons.build_outlined : Icons.manage_search,
      label: _change ? '코드 수정' : '코드 조사',
      badge: ThinkBadge(r.statusLabel, color: thinkCodeStatusColor(r.status)),
      trailing: r.round > 0 && !_change
          ? Text('${r.round}/${r.maxRounds}회차', style: const TextStyle(color: kThinkHint, fontSize: 12))
          : null,
      children: [
        _title(r.title),
        ..._progress(),
        ..._review(),
        if (widget.inChat) ...[
          if (res != null) ...[
            _gap(),
            ThinkMarkdown(res.summary, fontSize: 13),
            if (_change && res.checks.isNotEmpty) ...[thinkCodeLabel('적용 뒤 돌려 볼 검사'), thinkCodeBullets(res.checks, mono: true)],
          ] else if (latest?.resultText != null && latest!.status != 'running') ...[
            _gap(),
            const Text('결과를 정리하지 못했습니다. 아래 "자세히"에서 원문을 확인하세요.', style: TextStyle(color: kThinkSub, fontSize: 13)),
          ],
          if (_change && latest?.diff != null) ...[
            thinkCodeLabel('변경 (적용 전 확인)'),
            ThinkDiffView(diff: latest!.diff!, stats: latest.diffStats),
          ],
          if (rounds != null && rounds.isNotEmpty || r.status == ThinkCodeStatus.draft)
            ThinkCodeExpansion(
              title: '자세히 (요청 내용 · 회차별 결과)',
              children: [
                ThinkCodeSection(title: '요청 내용', child: ThinkCodeSpecView(spec: r.spec, mode: r.mode)),
                for (final round in (rounds ?? const <ThinkCodeRound>[]).reversed) ...[
                  _gap(),
                  ThinkCodeRoundView(round: round, numbered: rounds!.length > 1, mode: r.mode),
                ],
              ],
            ),
        ] else ...[
          _gap(),
          ThinkCodeSection(title: '요청 내용', child: ThinkCodeSpecView(spec: r.spec, mode: r.mode)),
          if (rounds == null && _c.roundsLoading(r.id))
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator(color: kThinkAccent)),
            ),
          for (final round in (rounds ?? const <ThinkCodeRound>[]).reversed) ...[
            _gap(),
            ThinkCodeRoundView(round: round, numbered: rounds!.length > 1, mode: r.mode),
          ],
        ],
        _gap(),
        _buttons(latest),
      ],
    );
  }

  List<Widget> _progress() {
    final worker = _c.onlineWorker != null;
    final beat = formatRelative(r.heartbeatAt ?? r.startedAt);
    final apply = r.lastApply;
    final revert = r.lastRevert;
    final unknown = r.lastError == _leaseExpired;
    ThinkNotice? notice;
    List<String> conflicts = const [];
    String? backup;
    switch (r.status) {
      case ThinkCodeStatus.draft:
        notice = const ThinkNotice(text: '초안입니다. 보내기 전에는 작업자가 가져가지 않습니다.', color: kThinkHint, icon: Icons.edit_note);
      case ThinkCodeStatus.queued:
        notice = ThinkNotice(
          text: worker ? '대기 중입니다. 작업자가 곧 가져갑니다.' : '대기 중입니다. 작업자가 꺼져 있어 켜질 때까지 기다립니다.',
          icon: Icons.hourglass_top,
        );
      case ThinkCodeStatus.followupQueued:
        notice = ThinkNotice(
          text: 'Think가 결과를 보고 더 확인할 질문을 보냈습니다. ${r.round + 1}회차 조사를 기다립니다.'
              '${worker ? '' : ' (작업자 꺼짐)'}',
          icon: Icons.forum_outlined,
        );
      case ThinkCodeStatus.running:
        notice = ThinkNotice(
          text: r.cancelRequested
              ? '취소를 요청했습니다. 작업자가 다음 신호 때 멈춥니다.'
              : _change
                  ? 'Cursor가 격리된 작업 폴더에서 코드를 고치고 있습니다. 마지막 신호 $beat.'
                  : 'Cursor가 저장소를 읽고 있습니다. 마지막 신호 $beat.',
          icon: _change ? Icons.build_outlined : Icons.manage_search,
          color: kThinkAccent,
        );
      case ThinkCodeStatus.needsReview:
        notice = const ThinkNotice(text: '답변이 정해진 형식이 아니라 정리하지 못했습니다. 원문을 직접 확인하세요.', icon: Icons.rule, color: kThinkLink);
      case ThinkCodeStatus.failed:
        notice = ThinkNotice(text: '실패했습니다. ${r.lastError ?? ''}'.trim(), icon: Icons.error_outline, color: kThinkError);
      case ThinkCodeStatus.cancelled:
        notice = const ThinkNotice(text: '취소했습니다.', icon: Icons.block, color: kThinkHint);
      case ThinkCodeStatus.ready:
        if (_change) {
          notice = const ThinkNotice(
            text: '변경을 만들었습니다. 아래 diff를 확인하고 적용하세요. 적용 전에는 작업 폴더가 바뀌지 않습니다.',
            icon: Icons.fact_check_outlined,
            color: kThinkSuccess,
          );
        }
      case ThinkCodeStatus.applyQueued:
        notice = ThinkNotice(
          text: '적용 대기 중입니다. 작업자가 먼저 git apply --check로 충돌을 확인합니다.${worker ? '' : ' (작업자 꺼짐)'}',
          icon: Icons.hourglass_top,
        );
      case ThinkCodeStatus.applying:
        notice = const ThinkNotice(text: '작업 폴더에 적용하는 중입니다.', icon: Icons.sync, color: kThinkAccent);
      case ThinkCodeStatus.applied:
        notice = ThinkNotice(
          text: '작업 폴더에 적용했습니다${apply != null && apply.files > 0 ? ' (파일 ${apply.files}개)' : ''}. 커밋이나 스테이징은 하지 않았습니다.',
          icon: Icons.check_circle_outline,
          color: kThinkSuccess,
        );
        backup = apply?.backupRef;
      case ThinkCodeStatus.applyFailed:
        notice = ThinkNotice(
          text: unknown
              ? '적용 중에 작업자가 멈춰 작업 폴더 상태를 알 수 없습니다. git status로 확인하세요.'
              : '적용하지 못했습니다. 작업 폴더는 바뀌지 않았습니다. ${apply?.error ?? r.lastError ?? ''}'.trim(),
          icon: Icons.error_outline,
          color: kThinkError,
        );
        conflicts = apply?.conflicts ?? const [];
        backup = apply?.backupRef;
      case ThinkCodeStatus.revertQueued:
        notice = ThinkNotice(text: '되돌리기 대기 중입니다.${worker ? '' : ' (작업자 꺼짐)'}', icon: Icons.hourglass_top);
      case ThinkCodeStatus.reverting:
        notice = const ThinkNotice(text: '적용한 변경을 되돌리는 중입니다.', icon: Icons.sync, color: kThinkAccent);
      case ThinkCodeStatus.reverted:
        notice = const ThinkNotice(text: '적용한 변경을 되돌렸습니다.', icon: Icons.undo, color: kThinkHint);
        backup = revert?.backupRef;
      case ThinkCodeStatus.revertFailed:
        notice = ThinkNotice(
          text: unknown
              ? '되돌리는 중에 작업자가 멈춰 작업 폴더 상태를 알 수 없습니다. git status로 확인하세요.'
              : '되돌리지 못했습니다. 적용 뒤 같은 파일을 더 고쳤을 수 있습니다. ${revert?.error ?? r.lastError ?? ''}'.trim(),
          icon: Icons.error_outline,
          color: kThinkError,
        );
        conflicts = revert?.conflicts ?? const [];
        backup = revert?.backupRef ?? apply?.backupRef;
    }
    return [
      if (notice != null) ...[_gap(), notice],
      if (conflicts.isNotEmpty) ...[thinkCodeLabel('충돌한 파일'), thinkCodeBullets(conflicts, color: kThinkError, mono: true)],
      if (backup != null) ...[
        _gap(8),
        SelectableText('직전 상태 백업: $backup', style: const TextStyle(color: kThinkHint, fontSize: 12, fontFamily: 'monospace')),
      ],
    ];
  }

  List<Widget> _review() {
    if (r.conversationId == null) return const [];
    final Widget? line = switch (r.reviewStatus) {
      ThinkReviewStatus.pending => const Row(
          children: [
            SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: kThinkAccent)),
            SizedBox(width: 8),
            Text('Think가 결과를 검토하고 있습니다…', style: TextStyle(color: kThinkSub, fontSize: 12)),
          ],
        ),
      ThinkReviewStatus.done => const Row(
          children: [
            Icon(Icons.auto_awesome, size: 14, color: kThinkAccent),
            SizedBox(width: 8),
            Expanded(child: Text('Think가 결과를 검토해 이 대화에 답했습니다.', style: TextStyle(color: kThinkSub, fontSize: 12))),
          ],
        ),
      ThinkReviewStatus.skipped => Text(
          'Think 자동 검토를 건너뛰었습니다: ${_reviewSkipReasons[r.reviewError] ?? r.reviewError ?? '이유 없음'}',
          style: const TextStyle(color: kThinkHint, fontSize: 12),
        ),
      ThinkReviewStatus.error => Text(
          'Think가 결과를 검토하지 못했습니다: ${r.reviewError ?? '알 수 없는 오류'}',
          style: const TextStyle(color: kThinkError, fontSize: 12),
        ),
      null => null,
    };
    return line == null ? const [] : [_gap(8), line];
  }

  Widget _buttons(ThinkCodeRound? latest) {
    final think = ThinkController.instance;
    final hasDiff = latest?.diff != null;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (r.status == ThinkCodeStatus.draft) ...[
          ElevatedButton.icon(
            onPressed: busy ? null : () => run(() => _c.submit(r), done: '보냈습니다. 작업자가 켜져 있으면 곧 시작합니다.'),
            style: thinkPrimaryButton(),
            icon: const Icon(Icons.send, size: 16),
            label: const Text('보내기'),
          ),
          OutlinedButton.icon(
            onPressed: busy ? null : () => ThinkCodeRequestDialog.edit(context, r),
            style: thinkOutlineButton(),
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('편집'),
          ),
        ],
        if (_change && r.status.appliable && hasDiff)
          ElevatedButton.icon(
            onPressed: busy ? null : () => _confirmApply(latest!),
            style: thinkPrimaryButton(),
            icon: const Icon(Icons.download_done, size: 16),
            label: Text(r.status == ThinkCodeStatus.applyFailed ? '다시 적용' : '작업 폴더에 적용'),
          ),
        if (_change && r.status.revertable)
          OutlinedButton.icon(
            onPressed: busy ? null : _confirmRevert,
            style: thinkOutlineButton(),
            icon: const Icon(Icons.undo, size: 16),
            label: Text(r.status == ThinkCodeStatus.revertFailed ? '다시 되돌리기' : '되돌리기'),
          ),
        if (r.cancellable)
          OutlinedButton.icon(
            onPressed: busy ? null : _confirmCancel,
            style: thinkOutlineButton(),
            icon: const Icon(Icons.stop_circle_outlined, size: 16),
            label: const Text('취소'),
          ),
        if (!widget.inChat && r.status.decidable)
          OutlinedButton.icon(
            onPressed: busy ? null : _decide,
            style: thinkOutlineButton(),
            icon: const Icon(Icons.gavel, size: 16),
            label: Text(r.outcome == null ? '판단 남기기' : '판단 고치기'),
          ),
        if (!widget.inChat && r.status.finished)
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () => run(() async {
                      await _c.duplicate(r);
                    }, done: '같은 내용으로 새 초안을 만들었습니다. 고친 뒤 보내세요.'),
            style: thinkOutlineButton(),
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('다시 요청'),
          ),
        if (!widget.inChat && r.conversationId != null)
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).maybePop();
              think.openConversation(r.conversationId!);
            },
            style: thinkOutlineButton(),
            icon: const Icon(Icons.forum_outlined, size: 16),
            label: const Text('대화로 가기'),
          ),
        if (r.status.deletable)
          TextButton.icon(
            onPressed: busy ? null : _confirmDelete,
            icon: const Icon(Icons.delete_outline, size: 16, color: kThinkError),
            label: const Text('삭제', style: TextStyle(color: kThinkError)),
          ),
      ],
    );
  }

  Future<void> _confirmApply(ThinkCodeRound round) async {
    final files = parseThinkDiff(round.diff!);
    final stats = round.diffStats;
    final names = files.take(20).map((f) => '· ${f.path}').join('\n');
    final more = files.length > 20 ? '\n· 외 ${files.length - 20}개' : '';
    final ok = await confirmThink(
      context,
      title: '작업 폴더에 적용할까요?',
      message: '파일 ${stats?.files ?? files.length}개 (+${stats?.additions ?? 0} -${stats?.deletions ?? 0})를 '
          '이 PC의 저장소 작업 폴더에 적용합니다.\n\n$names$more\n\n'
          '· 작업자가 먼저 git apply --check로 확인하고, 통과할 때만 적용합니다.\n'
          '· 적용 직전 상태를 백업(git ref)해 두고, 이 카드의 되돌리기로 되돌릴 수 있습니다.\n'
          '· 커밋이나 스테이징은 하지 않습니다.',
      confirmLabel: '적용',
    );
    if (ok) await run(() => _c.applyChange(r), done: '적용을 맡겼습니다. 결과는 이 카드에 표시됩니다.');
  }

  Future<void> _confirmRevert() async {
    final ok = await confirmThink(
      context,
      title: '적용한 변경을 되돌릴까요?',
      message: '같은 diff를 거꾸로 적용합니다(git apply -R). 적용 뒤 같은 부분을 더 고쳤다면 검사에서 멈추고 아무것도 바꾸지 않습니다. '
          '되돌리기 직전 상태도 백업합니다.',
      confirmLabel: '되돌리기',
    );
    if (ok) await run(() => _c.revertChange(r), done: '되돌리기를 맡겼습니다.');
  }

  Future<void> _confirmCancel() async {
    final ok = await confirmThink(
      context,
      title: '취소할까요?',
      message: switch (r.status) {
        ThinkCodeStatus.running => '진행 중인 Cursor 실행을 멈춥니다. 그때까지 쓴 토큰은 사용량에 남습니다.',
        ThinkCodeStatus.applyQueued => '적용을 취소합니다. 작업 폴더는 바뀌지 않습니다.',
        ThinkCodeStatus.revertQueued => '되돌리기를 취소합니다. 적용한 상태가 유지됩니다.',
        _ => '대기열에서 뺍니다.',
      },
      confirmLabel: '취소하기',
      destructive: true,
    );
    if (ok) await run(() => _c.cancel(r));
  }

  Future<void> _confirmDelete() async {
    final ok = await confirmThink(
      context,
      title: '요청을 삭제할까요?',
      message: '요청과 결과가 모두 지워집니다. 사용량 기록은 남습니다. 되돌릴 수 없습니다.',
      confirmLabel: '삭제',
      destructive: true,
    );
    if (ok) await run(() => _c.delete(r));
  }

  Future<void> _decide() async {
    final result = await showDialog<({ThinkCodeOutcome? outcome, String note})>(
      context: context,
      builder: (_) => _DecideDialog(initial: r.outcome, note: r.outcomeNote ?? ''),
    );
    if (result == null) return;
    await run(() => _c.decide(r, result.outcome, result.note.trim().isEmpty ? null : result.note.trim()), done: '판단을 남겼습니다.');
  }
}

// =====================================================================================
// 대화
// =====================================================================================

/// 코드 제안을 고쳐서 보낸다. 저장하지 않고 고친 값만 돌려준다.
class ThinkCodeProposalDialog extends StatefulWidget {
  const ThinkCodeProposalDialog._({required this.title, required this.spec, required this.mode});

  final String title;
  final ThinkCodeSpec spec;
  final ThinkCodeMode mode;

  static Future<({String title, ThinkCodeSpec spec})?> show(
    BuildContext context, {
    required String title,
    required ThinkCodeSpec spec,
    required ThinkCodeMode mode,
  }) =>
      showDialog<({String title, ThinkCodeSpec spec})>(
        context: context,
        builder: (_) => ThinkCodeProposalDialog._(title: title, spec: spec, mode: mode),
      );

  @override
  State<ThinkCodeProposalDialog> createState() => _ThinkCodeProposalDialogState();
}

class _ThinkCodeProposalDialogState extends State<ThinkCodeProposalDialog> {
  late final TextEditingController _title = TextEditingController(text: widget.title);
  late final TextEditingController _goal = TextEditingController(text: widget.spec.goal);
  late final TextEditingController _list = TextEditingController(
    text: (_change ? widget.spec.instructions : widget.spec.questions).join('\n'),
  );
  late final TextEditingController _paths = TextEditingController(text: widget.spec.focusPaths.join('\n'));
  late final TextEditingController _constraints = TextEditingController(text: widget.spec.constraints.join('\n'));
  late final TextEditingController _doNot = TextEditingController(text: widget.spec.doNot.join('\n'));
  late final TextEditingController _background = TextEditingController(text: widget.spec.background);
  String? _error;

  bool get _change => widget.mode == ThinkCodeMode.change;

  @override
  void dispose() {
    for (final t in [_title, _goal, _list, _paths, _constraints, _doNot, _background]) {
      t.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final title = _title.text.trim();
    final list = ThinkCodeSpec.lines(_list.text);
    if (title.isEmpty || title.length > 200) return setState(() => _error = '제목을 1~200자로 입력하세요.');
    if (_goal.text.trim().isEmpty) return setState(() => _error = '목표를 입력하세요.');
    if (_change && list.isEmpty) return setState(() => _error = '할 일을 한 줄 이상 입력하세요.');
    Navigator.pop(context, (
      title: title,
      spec: ThinkCodeSpec(
        goal: _goal.text.trim(),
        background: _change ? '' : _background.text.trim(),
        questions: _change ? widget.spec.questions : list,
        instructions: _change ? list : const [],
        focusPaths: ThinkCodeSpec.lines(_paths.text),
        constraints: ThinkCodeSpec.lines(_constraints.text),
        doNot: ThinkCodeSpec.lines(_doNot.text),
      ),
    ));
  }

  Widget _field(TextEditingController c, String label, {String? hint, int minLines = 1, int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        minLines: minLines,
        maxLines: maxLines,
        style: const TextStyle(color: kThinkText, fontSize: 14, height: 1.5),
        decoration: thinkInputDecoration(label: label, hint: hint),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text(_change ? '코드 수정 제안 고치기' : '코드 조사 제안 고치기', style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _field(_title, '제목'),
              _field(_goal, '목표', minLines: 2, maxLines: 6),
              _field(_list, _change ? '할 일 (한 줄에 하나)' : '확인할 질문 (한 줄에 하나, 선택)', minLines: 2, maxLines: 8),
              _field(_paths, _change ? '고칠 범위 (한 줄에 하나, 비우면 저장소 전체)' : '우선 볼 폴더 (한 줄에 하나, 비우면 저장소 전체)', maxLines: 4),
              _field(_constraints, '지켜야 할 제약 (한 줄에 하나, 선택)', maxLines: 4),
              _field(_doNot, _change ? '하지 말 것 (한 줄에 하나, 선택)' : '제안하지 말 것 (한 줄에 하나, 선택)', maxLines: 4),
              if (!_change) _field(_background, '배경 (선택)', minLines: 2, maxLines: 8),
              if (_error != null) ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
        ElevatedButton(onPressed: _submit, style: thinkPrimaryButton(), child: const Text('보내기')),
      ],
    );
  }
}

class _DecideDialog extends StatefulWidget {
  const _DecideDialog({this.initial, required this.note});

  final ThinkCodeOutcome? initial;
  final String note;

  @override
  State<_DecideDialog> createState() => _DecideDialogState();
}

class _DecideDialogState extends State<_DecideDialog> {
  late ThinkCodeOutcome? _outcome = widget.initial ?? ThinkCodeOutcome.adopted;
  late final TextEditingController _note = TextEditingController(text: widget.note);

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: const Text('조사 결과 판단', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final o in ThinkCodeOutcome.values)
                  ThinkToggleChip(
                    label: o.label,
                    icon: _outcome == o ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    selected: _outcome == o,
                    onChanged: (_) => setState(() => _outcome = o),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              minLines: 2,
              maxLines: 6,
              style: const TextStyle(color: kThinkText, fontSize: 14, height: 1.5),
              decoration: thinkInputDecoration(label: '메모 (선택)', hint: '왜 그렇게 정했는지'),
            ),
            const SizedBox(height: 12),
            const Text(
              '여기서 남긴 판단은 기록일 뿐 코드나 결정 기억을 바꾸지 않습니다. 결정으로 남기려면 Think 대화에서 결정 초안을 만드세요.',
              style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.4),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, (outcome: _outcome, note: _note.text)),
          style: thinkPrimaryButton(),
          child: const Text('저장'),
        ),
      ],
    );
  }
}
