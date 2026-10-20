import 'package:flutter/material.dart';

import '../../services/think/think_action_models.dart';
import '../../services/think/think_api.dart';
import '../../services/think/think_code_controller.dart';
import '../../services/think/think_code_models.dart';
import '../../services/think/think_controller.dart';
import '../../services/think/think_models.dart';
import '../../services/think/think_send_lock.dart';
import '../../widgets/latex_text_renderer.dart';
import 'think_avatars.dart';
import 'think_code_request_dialog.dart';
import 'think_code_views.dart';
import 'think_markdown.dart';
import 'think_memory_proposal_views.dart';
import 'think_memory_scope_picker.dart';
import 'think_organize_panel.dart';
import 'think_split_views.dart';
import 'think_status_dialog.dart';
import 'think_style.dart';
import 'think_tree_dialogs.dart';

part 'think_concept_draft_cards.dart';

// 채팅 답변 아래에 붙는 작업 카드. AI가 낸 제안(ai_actions)은 여기서 사람이 승인해야 실행된다.
// 설계: docs/architecture/ai-think-actions.md

const Map<String, String> _reviewSkipReasons = {
  'ai_not_configured': '서버에 OpenAI 키가 없습니다',
  'budget_exceeded': '이번 달 AI 사용 한도를 넘었습니다',
};

const String _leaseExpired = 'lease_expired_state_unknown';

/// 카드가 Think 채팅 밖(개념 탭)에 놓였다. 없으면 Think 화면 안으로 본다.
/// 밖에서는 Think 화면의 선택을 몰래 바꾸지 않고, 대화를 열 때 Think 화면으로 옮겨 간다.
class ThinkCardScope extends InheritedWidget {
  const ThinkCardScope({super.key, required this.messagesOf, required this.openConversation, required super.child});

  /// 카드가 놓인 화면이 보여 주는 그 대화의 메시지.
  final List<ThinkMessage> Function(String conversationId) messagesOf;

  /// Think 화면으로 가서 그 대화를 연다.
  final void Function(String conversationId) openConversation;

  static ThinkCardScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ThinkCardScope>();

  @override
  bool updateShouldNotify(ThinkCardScope oldWidget) =>
      messagesOf != oldWidget.messagesOf || openConversation != oldWidget.openConversation;
}

/// 이 대화로 답변을 받는 중(Think 화면이든 개념 탭이든).
bool _answering(String conversationId) {
  final think = ThinkController.instance;
  return ThinkSendLock.instance.busy(conversationId) || (think.isStreaming && think.streamingConversationId == conversationId);
}

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
  const _ClosedLine({required this.icon, required this.text, this.trailing});

  final IconData icon;
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: kThinkHint),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kThinkHint, fontSize: 12)),
          ),
          if (trailing != null) trailing!,
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

Widget _workerLine(ThinkCodeController c) => Tooltip(
      message: '이 PC에서 tools/code_bridge 폴더의 npm start로 켭니다. 켜기 전에 보낸 요청은 대기열에서 기다립니다.',
      child: thinkCodeWorkerLine(c),
    );

/// 코드 수정 diff에 migrations가 있을 때 운영 DB 반영은 읽기 전용 안내만 한다(적용·push 없음).
class ThinkDbProductionReflectionPanel extends StatelessWidget {
  const ThinkDbProductionReflectionPanel({super.key, required this.round});

  final ThinkCodeRound round;

  @override
  Widget build(BuildContext context) {
    final paths = migrationPathsFromDiff(round.diff);
    final v = round.verification;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kThinkBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkLink.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('운영 DB 반영 제안 (읽기 전용)',
              style: TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text(
            '작업 폴더에 파일만 놓인 상태입니다. 운영 DB에 실제로 적용됐는지·백업·대상 프로젝트·권한 영향은 '
            '이 화면만으로 확인되지 않습니다. db push나 배포는 운영자가 별도로 승인·실행합니다.',
            style: TextStyle(color: kThinkSub, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 8),
          _roLine('대상 Supabase 프로젝트', '앱에 설정된 프로젝트가 맞는지 운영자가 확인 필요'),
          _roLine('백업·복구', '미확인 — 반영 전 백업 여부를 운영자가 확인'),
          if (paths.isEmpty)
            _roLine('마이그레이션 파일', 'diff에서 경로를 찾지 못함 (부분 확인)')
          else ...[
            _roLine('적용 순서(파일명)', paths.join('\n')),
            _roLine('삭제·권한 영향', 'SQL 내용·운영 데이터 영향은 diff와 검토로 확인 (자동 판정 없음)'),
          ],
          if (v != null) ...[
            const SizedBox(height: 8),
            Text('자동 검사 요약: ${thinkVerificationSummary(v)} (위·아래 카드의 항목별 통과/실패/미실행 참고)',
                style: const TextStyle(color: kThinkText, fontSize: 12, height: 1.4)),
          ] else
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('자동 검사: 기록 없음 (미실행)', style: TextStyle(color: kThinkHint, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _roLine(String label, String value) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 140, child: Text(label, style: const TextStyle(color: kThinkSub, fontSize: 12))),
            Expanded(
              child: SelectableText(value, style: const TextStyle(color: kThinkText, fontSize: 12, height: 1.4)),
            ),
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

  /// 운영자가 카드에서 고른 작업 강도. null이면 Think가 고른 값.
  String? _effort;

  ThinkAction get a => widget.action;

  @override
  Widget build(BuildContext context) {
    final answered = a.result?['answers'];
    if (a.superseded && a.result?['revision_request_id'] != null && answered is List) {
      return _ClosedLine(
        icon: Icons.question_answer_outlined,
        text: '조율본 · 고른 답 ${answered.length}개로 다시 조율함${a.title.isEmpty ? '' : ' · ${a.title}'}',
      );
    }
    if (a.superseded) {
      return _ClosedLine(
          icon: Icons.low_priority, text: '${a.kind.label} 제안 · 새 제안으로 대체됨${a.title.isEmpty ? '' : ' · ${a.title}'}');
    }
    if (a.kind == ThinkActionKind.splitConversation && a.status != ThinkActionStatus.failed) return _split();
    if (a.kind == ThinkActionKind.saveMemory && a.status != ThinkActionStatus.failed) return _saveMemory();
    if (a.kind == ThinkActionKind.memoryCardChange && a.status != ThinkActionStatus.failed) return _memoryChange();
    if (a.kind == ThinkActionKind.handoverDepartment && a.status != ThinkActionStatus.failed) {
      return ListenableBuilder(listenable: _think, builder: (_, __) => _handover());
    }
    if (a.kind.isOrganizeOnly && a.status != ThinkActionStatus.failed) return _organizeOnly();
    if (a.kind.isConceptDraft && a.status != ThinkActionStatus.failed) return ConceptDraftActionCard(action: a);
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

  // ------------------------------------------------------------ 기억 저장 제안
  /// 카드에서 고른 범위. null이면 Think가 제안한 범위 그대로.
  ThinkMemoryScope? _memScope;
  ThinkDepartmentId? _memDept;

  ThinkMemoryProposal get _memoryWithScope {
    final m = a.memoryProposal;
    final scope = _memScope;
    if (scope == null) return m;
    final dept = scope == ThinkMemoryScope.department;
    return m.copyWith(
      memoryScope: dept ? 'department' : 'common',
      scopeDepartment: dept ? _memDept?.db : null,
      clearDepartment: !dept,
    );
  }

  Future<void> _approveMemory(ThinkMemoryProposal? edited) => run(
        () => _think.applyAction(a, overrides: edited == null ? const {} : {'memory': edited.toJson()}),
        done: '기억으로 저장했습니다. 다음 대화부터 Think가 참고합니다.',
      );

  Future<void> _editMemory() async {
    final edited = await ThinkMemoryEditDialog.show(context, memory: _memoryWithScope, showScope: _think.rolesReady);
    if (edited == null || !mounted) return;
    await _approveMemory(edited);
  }

  Widget _saveMemory() {
    final m = a.memoryProposal;
    final title = m.title.isEmpty ? a.title : m.title;
    if (a.status == ThinkActionStatus.applied) {
      return _ClosedLine(
        icon: Icons.bookmark_added_outlined,
        text: '기억 저장 · ${a.memoryEdited ? '고쳐서 ' : ''}확정 기억으로 저장함 · $title',
      );
    }
    if (a.status == ThinkActionStatus.rejected) {
      return _ClosedLine(
        icon: Icons.block,
        text: '기억 저장 제안 · ${a.memoryWithdrawn ? '삭제 제안 승인으로 닫힘' : '거절함'} · $title',
      );
    }
    final scope = _memScope ?? (m.memoryScope == 'department' ? ThinkMemoryScope.department : ThinkMemoryScope.common);
    final dept = _memScope == null ? ThinkDepartmentId.parse(m.scopeDepartment) : _memDept;
    final scopeMissing = scope == ThinkMemoryScope.department && dept == null;
    return _CardFrame(
      icon: Icons.bookmark_add_outlined,
      label: '기억 저장 제안',
      badge: ThinkBadge(a.memoryRevised ? '고쳐진 카드 · 승인 대기' : '승인 대기', color: kThinkLink),
      children: [
        ThinkMemoryProposalView(memory: m, showScope: !_think.rolesReady),
        if (a.memoryReason.isNotEmpty) ...[
          thinkCodeLabel('Think가 지금 제안한 이유'),
          SelectableText(a.memoryReason, style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
        ],
        if (a.supersedesTitle.isNotEmpty) ...[
          _gap(),
          ThinkNotice(
            icon: Icons.swap_horiz,
            text: '확정된 기억 "${a.supersedesTitle}"을(를) 대체합니다. 승인하면 앞 기억은 "대체됨"으로 바뀌고 Think가 더 쓰지 않습니다.',
          ),
        ],
        if (_think.rolesReady) ...[
          _gap(),
          ThinkMemoryScopePicker(
            scope: scope,
            department: dept,
            enabled: !busy,
            onChanged: (s, d) => setState(() {
              _memScope = s;
              _memDept = d;
            }),
          ),
          if (_memScope == null)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Think가 제안한 범위입니다. 바꾸려면 다른 범위를 고르세요.', style: TextStyle(color: kThinkHint, fontSize: 12)),
            ),
        ],
        _gap(),
        const ThinkNotice(
          icon: Icons.verified_outlined,
          text: '승인하면 바로 확정 기억으로 저장되고 다음 대화부터 Think가 참고합니다. 거절하면 아무것도 저장하지 않습니다.',
        ),
        _gap(),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ElevatedButton.icon(
              onPressed: busy || scopeMissing ? null : () => _approveMemory(_memScope == null ? null : _memoryWithScope),
              style: thinkPrimaryButton(),
              icon: const Icon(Icons.check, size: 16),
              label: const Text('승인하고 저장'),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : _editMemory,
              style: thinkOutlineButton(),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('고쳐서 승인'),
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

  Future<void> _approveMemoryChange(ThinkMemoryProposal? edited) => run(
        () => _think.applyAction(a, overrides: edited == null ? const {} : {'memory': edited.toJson()}),
        done: switch (a.memoryCardOp) {
          'withdraw' => '대기 중이던 기억 저장 카드를 닫았습니다.',
          'replace' => '앞 카드를 닫고 새 기억 저장 카드를 올렸습니다. 새 카드에서 승인해야 저장됩니다.',
          _ => '기억 저장 카드를 고쳤습니다. 카드에서 승인해야 저장됩니다.',
        },
      );

  Widget _memoryChange() {
    final op = a.memoryCardOp;
    final opLabel = kThinkMemoryCardOps[op] ?? op;
    final target = a.memoryTargetTitle.isEmpty ? '(제목 없음)' : a.memoryTargetTitle;
    if (a.status == ThinkActionStatus.applied) {
      return _ClosedLine(icon: Icons.edit_note, text: '기억 카드 변경 · $opLabel 승인함 · $target');
    }
    if (a.status == ThinkActionStatus.rejected) {
      return _ClosedLine(icon: Icons.block, text: '기억 카드 변경 제안 · 거절함 · $opLabel · $target');
    }
    final withdraw = op == 'withdraw';
    final m = a.memoryProposal;
    return _CardFrame(
      icon: Icons.edit_note,
      label: '기억 카드 변경 제안',
      badge: ThinkBadge('$opLabel · 승인 대기', color: kThinkLink),
      children: [
        Text('대상: 대기 중인 기억 저장 카드 "$target"', style: const TextStyle(color: kThinkSub, fontSize: 12)),
        if (!withdraw && !m.isEmpty) ...[
          _gap(8),
          thinkCodeLabel(op == 'replace' ? '새 카드 내용' : '고칠 내용'),
          ThinkMemoryProposalView(memory: m),
        ],
        if (a.memoryReason.isNotEmpty) ...[
          thinkCodeLabel('Think가 제안한 이유'),
          SelectableText(a.memoryReason, style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
        ],
        _gap(),
        ThinkNotice(
          icon: Icons.info_outline,
          text: switch (op) {
            'withdraw' => '승인하면 대기 중인 카드를 닫습니다. 이미 저장된 기억은 바뀌지 않습니다.',
            'replace' => '승인하면 대상 카드를 닫고 이 내용으로 새 기억 저장 카드를 올립니다. 저장은 새 카드에서 다시 승인해야 합니다.',
            _ => '승인하면 대상 카드의 내용이 이렇게 바뀝니다. 저장은 그 카드에서 다시 승인해야 합니다.',
          },
        ),
        _gap(),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ElevatedButton.icon(
              onPressed: busy ? null : () => _approveMemoryChange(null),
              style: thinkPrimaryButton(),
              icon: const Icon(Icons.check, size: 16),
              label: Text('$opLabel 승인'),
            ),
            if (!withdraw)
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        final edited = await ThinkMemoryEditDialog.show(
                          context,
                          memory: m,
                          showScope: _think.rolesReady,
                          confirmLabel: '고친 내용으로 $opLabel',
                        );
                        if (edited == null || !mounted) return;
                        await _approveMemoryChange(edited);
                      },
                style: thinkOutlineButton(),
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('고쳐서 승인'),
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

  // ------------------------------------------------------------ 코드
  Widget _codeProposal() {
    final change = a.kind == ThinkActionKind.codeChange;
    final mode = change ? ThinkCodeMode.change : ThinkCodeMode.investigate;
    final spec = ThinkCodeSpec.fromJson(a.payload['spec']);
    if (change && (a.payload['plan_request_id'] ?? '').toString().isNotEmpty) return _planProposal(spec);
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
        _effortPicker(spec),
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
              onPressed: busy ? null : () => _approve(spec, '보냈습니다. 진행 상황은 이 카드에 표시됩니다.'),
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

  /// Think와 Cursor가 주고받아 만든 조율본. 승인하면 그대로 수정 요청이 된다.
  Widget _planProposal(ThinkCodeSpec spec) {
    final raw =
        a.payload['spec'] is Map ? Map<String, dynamic>.from(a.payload['spec'] as Map) : const <String, dynamic>{};
    final plan = raw['based_on_plan'] is Map
        ? Map<String, dynamic>.from(raw['based_on_plan'] as Map)
        : const <String, dynamic>{};
    final rounds = plan['rounds'] is num ? (plan['rounds'] as num).toInt() : 0;
    final disagreements = [
      for (final d in raw['disagreements'] is List ? raw['disagreements'] as List : const [])
        if (d is Map && (d['point'] ?? '').toString().trim().isNotEmpty) Map<String, dynamic>.from(d),
    ];
    final ownerQuestions = [
      for (final q in raw['owner_questions'] is List ? raw['owner_questions'] as List : const [])
        if (q.toString().trim().isNotEmpty) q.toString().trim(),
    ];
    final decisions = ThinkPlanDecision.listFrom(raw['decisions']).where((d) => d.options.isNotEmpty).toList();
    final answeredBefore = raw['owner_answers'] is List ? (raw['owner_answers'] as List).length : 0;
    return _CardFrame(
      icon: Icons.handshake_outlined,
      label: '조율본',
      badge: ThinkBadge(decisions.isEmpty ? '승인 대기' : '답변 대기', color: kThinkLink),
      children: [
        _title(a.title),
        _gap(8),
        Text(
          [
            rounds > 0 ? 'Think와 Cursor가 $rounds회 주고받아 맞춘 계획입니다.' : 'Think와 Cursor가 맞춘 계획입니다.',
            if (answeredBefore > 0) '앞서 고르신 답 $answeredBefore개가 반영되어 있습니다.',
          ].join(' '),
          style: const TextStyle(color: kThinkSub, fontSize: 12),
        ),
        _gap(8),
        ThinkCodeSpecView(spec: spec, mode: ThinkCodeMode.change),
        if (decisions.isNotEmpty) ...[
          _gap(),
          ThinkPlanDecisionsForm(
            decisions: decisions,
            busy: busy,
            onSubmit: (answers) => run(
              () => _think.revisePlan(a, answers),
              done: '고른 답으로 다시 조율합니다. Cursor가 확인한 뒤 Think가 새 조율본을 올립니다.',
            ),
            onReject: () => run(() => _think.rejectAction(a)),
          ),
        ] else ...[
          if (disagreements.isNotEmpty) ...[
            thinkCodeLabel('끝까지 의견이 갈린 점'),
            for (final d in disagreements)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: kThinkQuote, borderRadius: BorderRadius.circular(8)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      d['point'].toString(),
                      style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                    if ((d['think'] ?? '').toString().isNotEmpty) ...[
                      _gap(4),
                      SelectableText('Think: ${d['think']}',
                          style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
                    ],
                    if ((d['cursor'] ?? '').toString().isNotEmpty) ...[
                      _gap(4),
                      SelectableText('Cursor: ${d['cursor']}',
                          style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
                    ],
                  ],
                ),
              ),
          ],
          if (ownerQuestions.isNotEmpty) ...[
            thinkCodeLabel('정해 주셔야 할 것'),
            thinkCodeBullets(ownerQuestions),
          ],
          _effortPicker(spec),
          _gap(),
          ThinkNotice(
            icon: Icons.shield_outlined,
            text: ownerQuestions.isEmpty && disagreements.isEmpty
                ? '승인하면 Cursor가 격리 폴더에서 이 계획대로 코드를 고치고 변경(diff)을 돌려줍니다. '
                    '실제 작업 폴더는 diff를 확인한 뒤 한 번 더 승인해야 바뀝니다.'
                : '갈린 점이나 정할 것이 있으면 "고쳐서 구현"에서 할 일에 결정을 적어 주세요. '
                    '승인해도 실제 작업 폴더는 diff를 확인한 뒤 한 번 더 승인해야 바뀝니다.',
          ),
          _gap(),
          _workerLine(_code),
          _gap(),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: busy ? null : () => _approve(spec, '조율본대로 구현을 시작합니다. 진행 상황은 이 카드에 표시됩니다.'),
                style: thinkPrimaryButton(),
                icon: const Icon(Icons.check, size: 16),
                label: const Text('이대로 구현'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : () => _editAndSend(spec, ThinkCodeMode.change),
                style: thinkOutlineButton(),
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('고쳐서 구현'),
              ),
              TextButton(
                onPressed: busy ? null : () => run(() => _think.rejectAction(a)),
                child: const Text('거절', style: TextStyle(color: kThinkSub)),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Map<String, dynamic> get _rawSpec =>
      a.payload['spec'] is Map ? Map<String, dynamic>.from(a.payload['spec'] as Map) : <String, dynamic>{};

  String? get _thinkEffort {
    final v = _rawSpec['effort'];
    return ThinkCodeSpec.efforts.contains(v) ? v as String : null;
  }

  String _effortOf(ThinkCodeSpec spec) => _effort ?? spec.effort;

  Widget _effortPicker(ThinkCodeSpec spec) => ThinkEffortPicker(
        selected: _effortOf(spec),
        thinkChoice: _thinkEffort,
        reason: spec.effortReason,
        enabled: !busy,
        onChanged: (e) => setState(() => _effort = e),
      );

  /// 그대로 승인. 강도만 바꿨으면 원래 spec에 강도만 바꿔 보낸다.
  Future<void> _approve(ThinkCodeSpec spec, String done) => run(
      () => _think.applyAction(a, overrides: ThinkCodeSpec.effortOverrides(_rawSpec, _effortOf(spec))),
      done: done);

  Future<void> _editAndSend(ThinkCodeSpec spec, ThinkCodeMode mode) async {
    final edited =
        await ThinkCodeProposalDialog.show(context, title: a.title, spec: spec.withEffort(_effortOf(spec)), mode: mode);
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
    final plan = a.kind == ThinkActionKind.codePlan;
    return _CardFrame(
      icon: plan ? Icons.handshake_outlined : (change ? Icons.build_outlined : Icons.manage_search),
      label: plan ? 'Cursor와 조율' : (change ? '코드 수정' : '코드 조사'),
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

  // ------------------------------------------------------------ 부서 넘기기
  Widget _handover() {
    final to = a.handoverTo;
    final from = a.handoverFrom ?? ThinkRoleId.lead;
    final toLabel = to?.label ?? '다른';
    if (a.status == ThinkActionStatus.applied) {
      return _ClosedLine(icon: Icons.swap_horiz, text: '부서 넘기기 · ${from.label} → $toLabel 부서로 옮김');
    }
    if (a.status == ThinkActionStatus.rejected) {
      return _ClosedLine(icon: Icons.block, text: '부서 넘기기 제안 · 여기서 계속하기로 함 · ${from.label} → $toLabel');
    }
    if (!a.pending) {
      return _ClosedLine(icon: Icons.swap_horiz, text: '부서 넘기기 제안 · ${a.status.label} · ${from.label} → $toLabel');
    }
    final streaming = _answering(a.conversationId);
    Widget side(ThinkRoleId role, String caption) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ThinkRoleAvatar(role: role, size: 40, semanticsLabel: '$caption ${role.label} 부서'),
            const SizedBox(height: 4),
            Text(role.label, style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
            Text(caption, style: const TextStyle(color: kThinkHint, fontSize: 12)),
          ],
        );
    return _CardFrame(
      icon: Icons.swap_horiz,
      label: '부서 넘기기 제안',
      badge: const ThinkBadge('승인 대기', color: kThinkLink),
      children: [
        Row(
          children: [
            side(from, '지금'),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Icon(Icons.arrow_forward, size: 20, color: kThinkSub),
            ),
            if (to != null) side(to, '받을 부서'),
          ],
        ),
        if (a.handoverReason.isNotEmpty) ...[
          thinkCodeLabel('Think가 넘기자고 한 이유'),
          SelectableText(a.handoverReason, style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
        ],
        _gap(),
        ThinkNotice(
          icon: Icons.info_outline,
          text: '승인하면 이 대화의 부서가 $toLabel(으)로 바뀌고 $toLabel 부서의 미분류로 옮겨집니다. '
              '다음 답변부터 $toLabel 관점으로 답합니다. 이미 받은 답변과 기억은 바뀌지 않습니다.',
        ),
        if (streaming) ...[
          _gap(8),
          const Text('답변이 끝난 뒤 넘길 수 있습니다.', style: TextStyle(color: kThinkHint, fontSize: 12)),
        ],
        _gap(),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ElevatedButton.icon(
              onPressed: busy || streaming || to == null
                  ? null
                  : () => run(() => _think.applyAction(a), done: '$toLabel 부서로 넘겼습니다. 다음 답변부터 $toLabel 관점으로 답합니다.'),
              style: thinkPrimaryButton(),
              icon: const Icon(Icons.check, size: 16),
              label: Text('$toLabel 부서로 넘기기'),
            ),
            TextButton(
              onPressed: busy ? null : () => run(() => _think.rejectAction(a)),
              child: const Text('여기서 계속', style: TextStyle(color: kThinkSub)),
            ),
          ],
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 맥락 제외·중요 표시·진행 요약·부서 기준
  /// 대기 중이면 정리 패널에서 처리하고(답변 아래에는 "정리 제안 N건"만 보인다), 끝나면 결과 한 줄로 남긴다.
  Widget _organizeOnly() {
    if (a.pending) {
      return _CardFrame(
        icon: thinkOrganizeIcon(a.kind),
        label: '${a.kind.label} 제안',
        badge: const ThinkBadge('승인 대기', color: kThinkLink),
        children: [
          const Text('정리 패널에서 내용을 확인하고 승인합니다.', style: TextStyle(color: kThinkSub, fontSize: 13)),
          _gap(),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => openThinkOrganize(context, messageId: a.messageId),
              style: thinkOutlineButton(),
              icon: const Icon(Icons.playlist_add_check, size: 16),
              label: const Text('정리 패널 열기'),
            ),
          ),
        ],
      );
    }
    final icon = thinkOrganizeIcon(a.kind);
    final applied = a.status == ThinkActionStatus.applied;
    Widget undo(String done) => TextButton(
          onPressed: busy ? null : () => run(() => _think.undoAction(a), done: done),
          child: const Text('되돌리기', style: TextStyle(color: kThinkSub, fontSize: 12)),
        );
    switch (a.kind) {
      case ThinkActionKind.excludeContext:
        final n = a.excludedIds.length;
        if (applied) {
          return n == 0
              ? _ClosedLine(icon: icon, text: '맥락 제외 · 이미 빠져 있던 메시지라 바뀐 것 없음')
              : _ClosedLine(
                  icon: icon,
                  text: '맥락 제외 · 메시지 $n개를 이후 답변 맥락에서 뺌 (메시지는 남아 있음)',
                  trailing: undo('메시지를 다시 맥락에 넣었습니다.'),
                );
        }
        if (a.status == ThinkActionStatus.undone) return _ClosedLine(icon: Icons.undo, text: '맥락 제외 · 되돌림 · 메시지를 다시 맥락에 넣음');
      case ThinkActionKind.markImportant:
        final n = a.markedIds.length;
        if (applied) {
          return n == 0
              ? _ClosedLine(icon: icon, text: '중요 표시 · 이미 표시된 메시지라 바뀐 것 없음')
              : _ClosedLine(icon: icon, text: '중요 표시 · 메시지 $n개에 표시함', trailing: undo('중요 표시를 지웠습니다.'));
        }
        if (a.status == ThinkActionStatus.undone) return _ClosedLine(icon: Icons.undo, text: '중요 표시 · 되돌림');
      case ThinkActionKind.progressSummary:
        final approved = _think.details[a.conversationId]?.progressSummary;
        final purpose = approved != null && approved.actionId == a.id ? approved.purpose : a.progressSummaryProposal.purpose;
        if (applied) {
          return _ClosedLine(
            icon: icon,
            text: '진행 요약 · ${a.result?['edited'] == true ? '고쳐서 ' : ''}승인함${purpose.isEmpty ? '' : ' · $purpose'}',
          );
        }
        if (a.status == ThinkActionStatus.rejected) {
          return _ClosedLine(icon: Icons.block, text: '진행 요약 제안 · 거절함${purpose.isEmpty ? '' : ' · $purpose'}');
        }
      case ThinkActionKind.departmentCriteriaChange:
        final dept = a.criteriaDepartment?.label ?? '';
        if (applied) {
          final version = a.result?['version'];
          return _ClosedLine(
            icon: icon,
            text: '부서 기준 · $dept 부서 기준을 ${a.result?['edited'] == true ? '고쳐서 ' : ''}바꿈${version == null ? '' : ' (판 $version)'}',
          );
        }
      default:
        break;
    }
    if (a.status == ThinkActionStatus.rejected) {
      return _ClosedLine(icon: Icons.block, text: '${a.kind.label} 제안 · 거절함');
    }
    return _ClosedLine(icon: icon, text: '${a.kind.label} 제안 · ${a.status.label}');
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
        if (a.placeAfterHandover case final after?) ...[
          _gap(8),
          Text(
            '${after.label} 부서로 넘긴 다음에 넣는 분류입니다. 부서 넘기기를 먼저 승인해 주세요.',
            style: const TextStyle(color: kThinkLink, fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
        if (reason.isNotEmpty) ...[
          _gap(8),
          SelectableText(reason, style: const TextStyle(color: kThinkSub, fontSize: 13, height: 1.5)),
        ],
        _gap(),
        Text(
          isNew ? '왼쪽 트리에 만들 폴더 자리를 흐리게 표시했습니다. 넣기 전에는 폴더도 만들지 않습니다.' : '왼쪽 트리에 제안한 폴더를 강조했습니다. 넣기 전에는 아무것도 바뀌지 않습니다.',
          style: const TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
        ),
        _gap(),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ElevatedButton.icon(
              onPressed:
                  busy ? null : () => run(() => _think.applyAction(a), done: isNew ? '폴더를 만들고 넣었습니다.' : '폴더에 넣었습니다.'),
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
      department: _think.departmentsReady ? _think.roleOfConversation(a.conversationId) : null,
      allowRoot: false,
      title: '어느 폴더에 넣을까요?',
    );
    if (picked == null || picked == kThinkRootFolder || !mounted) return;
    await run(() => _think.applyAction(a, overrides: {'folder_id': picked}), done: '폴더에 넣었습니다.');
  }

  // ------------------------------------------------------------ 대화 나누기
  Widget _split() {
    final title = a.title;
    if (a.status == ThinkActionStatus.rejected) {
      return _ClosedLine(icon: Icons.block, text: '대화 나누기 제안 · 여기서 계속하기로 함${title.isEmpty ? '' : ' · $title'}');
    }
    if (a.status == ThinkActionStatus.expired) {
      return _ClosedLine(
        icon: Icons.timer_off_outlined,
        text: '대화 나누기 제안 · 대화가 이어져 이 제안은 만료됐습니다${title.isEmpty ? '' : ' · $title'}',
      );
    }
    if (a.status == ThinkActionStatus.applied) return _splitApplied();
    final blocked = _splitBlockedReason();
    final folderId = a.folderId;
    final inThink = ThinkCardScope.maybeOf(context) == null;
    return _CardFrame(
      icon: Icons.call_split,
      label: '대화 나누기 제안',
      badge: const ThinkBadge('승인 대기', color: kThinkLink),
      children: [
        _title(title),
        if (a.splitReason.isNotEmpty) ...[
          _gap(8),
          SelectableText(a.splitReason, style: const TextStyle(color: kThinkSub, fontSize: 13, height: 1.5)),
        ],
        if (a.splitStartPreview.isNotEmpty) ...[
          thinkCodeLabel('여기부터 나눕니다'),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: kThinkQuote, borderRadius: BorderRadius.circular(8)),
            child: SelectableText(
              a.splitStartPreview,
              style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5),
            ),
          ),
        ],
        thinkCodeLabel('들어갈 폴더'),
        Row(
          children: [
            Icon(folderId == null ? Icons.inbox_outlined : Icons.folder_outlined, size: 16, color: kThinkSub),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                thinkSplitFolderLabel(_think.tree, folderId, fallbackPath: a.splitFolderPath),
                style: const TextStyle(color: kThinkText, fontSize: 13),
              ),
            ),
          ],
        ),
        ThinkSplitSummaryView(summary: a.splitSummary),
        _gap(),
        ThinkNotice(
          icon: Icons.content_copy_outlined,
          text: inThink
              ? '나누면 이번 질문과 답변만 새 대화에 복사하고 새 대화로 넘어갑니다. 이 대화는 그대로 남습니다. '
                  '요약은 새 대화에서 참고 자료로만 쓰고 기억으로 저장하지 않습니다.'
              : '나누면 이번 질문과 답변만 새 대화에 복사합니다. 이 탭은 지금 대화에 그대로 연결되고, 새 대화는 Think 화면에서 엽니다. '
                  '요약은 새 대화에서 참고 자료로만 쓰고 기억으로 저장하지 않습니다.',
        ),
        if (blocked != null) ...[
          _gap(8),
          Text(blocked, style: const TextStyle(color: kThinkLink, fontSize: 12, fontWeight: FontWeight.w700)),
        ],
        _gap(),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ElevatedButton.icon(
              onPressed: busy || blocked != null
                  ? null
                  : () => run(() => _think.applySplit(a, open: inThink), done: inThink ? null : _splitDoneOutside),
              style: thinkPrimaryButton(),
              icon: const Icon(Icons.call_split, size: 16),
              label: const Text('나눠서 이어가기'),
            ),
            OutlinedButton.icon(
              onPressed: busy || blocked != null ? null : _editAndSplit,
              style: thinkOutlineButton(),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('고쳐서 나누기'),
            ),
            TextButton(
              onPressed: busy ? null : () => run(() => _think.rejectAction(a)),
              child: const Text('여기서 계속하기', style: TextStyle(color: kThinkSub)),
            ),
          ],
        ),
        _gap(8),
        const Text(
          '"여기서 계속하기"를 고르면 이 대화에서는 Think가 다시 나누자고 하지 않습니다. 직접 나누자고 하면 다시 제안합니다.',
          style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
        ),
      ],
    );
  }

  /// 승인을 막는 이유. 서버도 같은 조건(답변 저장·완료, 새 질문 없음)을 다시 확인한다.
  String? _splitBlockedReason() {
    if (_answering(a.conversationId) || a.messageId == null) return '답변 완료 후 나눌 수 있습니다.';
    final scope = ThinkCardScope.maybeOf(context);
    final shown = scope != null
        ? scope.messagesOf(a.conversationId)
        : (_think.selectedId == a.conversationId ? _think.messages : const <ThinkMessage>[]);
    final answer = shown.where((m) => m.id == a.messageId).firstOrNull;
    if (answer != null && answer.status != ThinkMessageStatus.complete) {
      return '답변이 끝까지 저장되지 않아(중단·오류) 나눌 수 없습니다. 다시 질문한 뒤 나눠 주세요.';
    }
    return null;
  }

  Future<void> _editAndSplit() async {
    final edited = await ThinkSplitEditDialog.show(
      context,
      title: a.title,
      folderId: a.folderId,
      summary: a.splitSummary,
      tree: _think.tree,
    );
    if (edited == null || !mounted) return;
    final inThink = ThinkCardScope.maybeOf(context) == null;
    await run(() => _think.applySplit(a, overrides: edited.toOverrides(), open: inThink), done: inThink ? null : _splitDoneOutside);
  }

  static const String _splitDoneOutside = '새 대화로 나눴습니다. 이 탭은 지금 대화에 그대로 연결되어 있습니다.';

  Widget _splitApplied() {
    final newId = a.splitConversationId;
    final title = (a.result?['title'] ?? a.title).toString();
    final left = a.splitNotCopied;
    String part(String key, String label) => (left[key] ?? 0) > 0 ? '$label ${left[key]}개' : '';
    final remained = [
      part('actions', '작업 카드'),
      part('code_requests', '코드 요청'),
      part('tree_nodes', '트리 발췌·문서'),
      part('other_messages', '복사하지 않은 메시지'),
    ].where((s) => s.isNotEmpty).toList();
    return _CardFrame(
      icon: Icons.call_split,
      label: '대화 나누기',
      badge: const ThinkBadge('나눔', color: kThinkSuccess),
      trailing: newId == null
          ? null
          : TextButton.icon(
              onPressed: () {
                final scope = ThinkCardScope.maybeOf(context);
                if (scope != null) {
                  scope.openConversation(newId);
                } else {
                  _think.openConversation(newId);
                }
              },
              icon: const Icon(Icons.open_in_new, size: 16, color: kThinkLink),
              label: const Text('새 대화로 가기', style: TextStyle(color: kThinkLink)),
            ),
      children: [
        Text(
          '"$title" 새 대화로 나눴습니다. 이 대화는 그대로 남아 있습니다.',
          style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5),
        ),
        _gap(8),
        Text(
          '새 대화에는 이번 질문과 답변만 복사했습니다.'
          '${remained.isEmpty ? '' : ' 이 대화에만 남은 것: ${remained.join(', ')}.'}',
          style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.5),
        ),
      ],
    );
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
            n('children') > 0 ? '안에 있는 ${n('children')}개 항목은 이 폴더가 있던 자리로 올라갑니다. 대화와 발췌는 지워지지 않습니다.' : '빈 폴더입니다.',
            style: const TextStyle(color: kThinkSub, fontSize: 13, height: 1.5),
          ),
        ];
      default:
        what = [
          _title((p['title'] ?? '').toString()),
          _gap(8),
          Text(
            '메시지 ${n('messages')}개, 발췌 ${n('excerpts')}개'
            '${n('documents') > 0 ? ', 종합 문서 ${n('documents')}개' : ''}가 함께 지워집니다.'
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
  bool get _plan => r.mode == ThinkCodeMode.plan;

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
    final fix = _change ? _c.fixFor(r.id) : null;
    final superseded = fix != null && !_fixEnded.contains(fix.status);
    final fromPartial = rounds?.any((x) => x.continued?.partial == true) ?? false;
    return _CardFrame(
      icon: _plan ? Icons.handshake_outlined : (_change ? Icons.build_outlined : Icons.manage_search),
      label: _plan ? 'Cursor와 조율' : (_change ? '코드 수정' : '코드 조사'),
      badge: ThinkBadge(r.statusLabel, color: thinkCodeStatusColor(r.status)),
      trailing: r.round > 0 && !_change
          ? Text('${r.round}/${r.maxRounds}회차', style: const TextStyle(color: kThinkHint, fontSize: 12))
          : _change && r.fixAttempt > 0
              ? Text('검사 실패로 다시 고침 ${r.fixAttempt}회째', style: const TextStyle(color: kThinkHint, fontSize: 12))
              : null,
      children: [
        _title(r.title),
        if (fromPartial) ...[
          _gap(8),
          const ThinkNotice(
              text: ThinkContinued.partialNotice, color: kThinkAccent, icon: Icons.warning_amber_outlined),
        ],
        ..._progress(latest, superseded ? fix : null),
        ..._review(),
        if (_change && latest != null && latest.status != 'running' && fix == null) ...[
          _gap(),
          ThinkChangeStateView(request: r, round: latest),
        ],
        if (widget.inChat) ...[
          if (res != null) ...[
            _gap(),
            ThinkMarkdown(res.summary, fontSize: 13),
            if (_change && res.checks.isNotEmpty) ...[
              thinkCodeLabel('사람이 확인할 점'),
              thinkCodeBullets(res.checks),
            ],
          ] else if (latest?.resultText != null && latest!.status != 'running') ...[
            _gap(),
            const Text('결과를 정리하지 못했습니다. 아래 "자세히"에서 원문을 확인하세요.', style: TextStyle(color: kThinkSub, fontSize: 13)),
          ],
          if (_change && latest?.verification != null) ...[
            thinkCodeLabel('자동 검사'),
            ThinkVerificationView(verification: latest!.verification!),
          ],
          if (_change && latest?.touchesMigrations == true) ...[
            _gap(),
            ThinkDbProductionReflectionPanel(round: latest!),
          ],
          if (_change && latest?.diff != null) ...[
            thinkCodeLabel('변경 (적용 전 확인)'),
            ThinkDiffView(diff: latest!.diff!, stats: latest.diffStats),
          ],
          if (rounds != null && rounds.isNotEmpty || r.status == ThinkCodeStatus.draft)
            ThinkCodeExpansion(
              title: _plan ? '주고받은 내용 (계획 초안 · 회차별 검토)' : '자세히 (요청 내용 · 회차별 결과)',
              children: [
                ThinkCodeSection(
                    title: '요청 내용', child: ThinkCodeSpecView(spec: r.spec, mode: r.mode, showEffort: true)),
                for (final round in (rounds ?? const <ThinkCodeRound>[]).reversed) ...[
                  _gap(),
                  ThinkCodeRoundView(round: round, numbered: rounds!.length > 1, mode: r.mode),
                ],
              ],
            ),
        ] else ...[
          _gap(),
          ThinkCodeSection(
              title: '요청 내용', child: ThinkCodeSpecView(spec: r.spec, mode: r.mode, showEffort: true)),
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
        _buttons(latest, superseded),
      ],
    );
  }

  /// 다시 고치는 요청이 이렇게 끝나면 앞 요청의 변경을 다시 쓸 수 있다.
  static const _fixEnded = {ThinkCodeStatus.failed, ThinkCodeStatus.cancelled, ThinkCodeStatus.needsReview};

  ThinkNotice _readyNotice(ThinkCodeRound? latest, ThinkCodeRequest? fix) {
    final v = latest?.verification;
    final db = latest?.touchesMigrations == true ? ' DB 함수 파일은 적용해도 운영 DB에 반영되지 않습니다. 반영은 따로 승인합니다.' : '';
    if (fix != null) {
      return ThinkNotice(
        text: '자동 검사에 실패해 Think가 Cursor에게 다시 고치게 했습니다(${fix.fixAttempt}회째). 이 카드 대신 새 카드의 결과를 보세요.',
        icon: Icons.replay,
        color: kThinkLink,
      );
    }
    if (v == null || v.items.isEmpty) {
      return ThinkNotice(
        text: '변경을 만들었지만 ${v == null ? '자동 검사 기록이 없습니다' : '자동 검사한 항목이 없습니다'}'
            '${v?.note != null ? ' (${v!.note})' : ''}. '
            '적용 전에 Think의 검토를 확인하세요. 적용 전에는 작업 폴더가 바뀌지 않습니다.$db',
        icon: Icons.help_outline,
        color: kThinkLink,
      );
    }
    if (v.verdict == ThinkCheckVerdict.failed) {
      return ThinkNotice(
        text: '필수 검사 ${v.requiredFailed}개가 실패했습니다. 이대로 적용하지 않는 것이 좋습니다. 이어서 고칠지 Think에게 말해 주세요.$db',
        icon: Icons.error_outline,
        color: kThinkError,
      );
    }
    if (v.verdict == ThinkCheckVerdict.notRun) {
      final env = v.envProblems;
      return ThinkNotice(
        text: '변경을 만들었지만 필수 검사 ${v.requiredSkipped}개를 실행하지 못했습니다(통과가 아닙니다). '
            '${env.isEmpty ? '' : '환경 조치가 필요합니다: ${env.map((i) => i.reason ?? i.label).join('; ')}. '}'
            '적용 여부는 위험을 보고 정하세요.$db',
        icon: Icons.rule,
        color: kThinkLink,
      );
    }
    if (v.verdict == ThinkCheckVerdict.none) {
      return ThinkNotice(
        text: '변경을 만들었습니다. 이번 변경에는 돌릴 필수 검사가 없었습니다(문서·규칙 등). 내용을 확인한 뒤 적용하세요.$db',
        icon: Icons.rule,
        color: kThinkLink,
      );
    }
    if (!v.clean) {
      return ThinkNotice(
        text: '변경을 만들었습니다. 자동 검사: ${thinkVerificationSummary(v)}. '
            '원래도 실패하던 항목은 이번 변경이 확인되지 않은 부분입니다.$db',
        icon: Icons.rule,
        color: kThinkLink,
      );
    }
    final follow = v.followups.isEmpty ? '' : ' 실제 데이터가 필요한 후속 확인 ${v.followups.length}개는 따로 확인하세요.';
    return ThinkNotice(
      text: '변경을 만들고 필수 검사 ${v.required.length}개를 모두 통과했습니다.$follow 확인한 뒤 작업 폴더에 적용하세요. 적용 전에는 작업 폴더가 바뀌지 않습니다.$db',
      icon: Icons.fact_check_outlined,
      color: kThinkSuccess,
    );
  }

  List<Widget> _progress(ThinkCodeRound? latest, ThinkCodeRequest? fix) {
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
          text: (_plan
                  ? 'Think가 Cursor의 검토를 보고 질문·반론을 보냈습니다. ${r.round + 1}회차 검토를 기다립니다.'
                  : 'Think가 결과를 보고 더 확인할 질문을 보냈습니다. ${r.round + 1}회차 조사를 기다립니다.') +
              (worker ? '' : ' (작업자 꺼짐)'),
          icon: Icons.forum_outlined,
        );
      case ThinkCodeStatus.running:
        notice = ThinkNotice(
          text: r.cancelRequested
              ? '취소를 요청했습니다. 작업자가 다음 신호 때 멈춥니다.'
              : _change
                  ? 'Cursor가 격리된 작업 폴더에서 코드를 고치고 있습니다. 다 고치면 작업자가 자동 검사까지 돌립니다. 마지막 신호 $beat.'
                  : _plan
                      ? 'Cursor가 Think의 계획을 코드에 비춰 검토하고 있습니다(읽기만 함). 마지막 신호 $beat.'
                      : 'Cursor가 저장소를 읽고 있습니다. 마지막 신호 $beat.',
          icon: _plan ? Icons.handshake_outlined : (_change ? Icons.build_outlined : Icons.manage_search),
          color: kThinkAccent,
        );
      case ThinkCodeStatus.needsReview:
        notice = ThinkNotice(
          text: _change
              ? '시간 안에 끝나지 않았거나 답변 형식이 달라 정리하지 못했습니다. 그때까지 만든 변경(diff)과 원문은 남겨 두었지만 '
                  '이 상태로는 적용할 수 없습니다. 이어서 고치려면 Think에게 말해 주세요.'
              : '답변이 정해진 형식이 아니라 정리하지 못했습니다. 원문을 직접 확인하세요.',
          icon: Icons.rule,
          color: kThinkLink,
        );
      case ThinkCodeStatus.failed:
        notice =
            ThinkNotice(text: '실패했습니다. ${r.lastError ?? ''}'.trim(), icon: Icons.error_outline, color: kThinkError);
      case ThinkCodeStatus.cancelled:
        notice = const ThinkNotice(text: '취소했습니다.', icon: Icons.block, color: kThinkHint);
      case ThinkCodeStatus.ready:
        if (_change) notice = _readyNotice(latest, fix);
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
      if (conflicts.isNotEmpty) ...[
        thinkCodeLabel('충돌한 파일'),
        thinkCodeBullets(conflicts, color: kThinkError, mono: true)
      ],
      if (backup != null) ...[
        _gap(8),
        SelectableText('직전 상태 백업: $backup',
            style: const TextStyle(color: kThinkHint, fontSize: 12, fontFamily: 'monospace')),
      ],
    ];
  }

  List<Widget> _review() {
    if (r.conversationId == null) return const [];
    final Widget? line = switch (r.reviewStatus) {
      ThinkReviewStatus.pending => Row(
          children: [
            const SizedBox(
                width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: kThinkAccent)),
            const SizedBox(width: 8),
            Text(
              _plan ? 'Think가 Cursor의 검토를 읽고 조율하고 있습니다…' : 'Think가 결과를 검토하고 있습니다…',
              style: const TextStyle(color: kThinkSub, fontSize: 12),
            ),
          ],
        ),
      ThinkReviewStatus.done => Row(
          children: [
            const Icon(Icons.auto_awesome, size: 14, color: kThinkAccent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _plan
                    ? 'Think가 조율을 마치고 이 대화에 정리했습니다. 정해 주실 것이 없으면 바로 수정을 맡기고, 있으면 아래 카드에서 묻습니다.'
                    : 'Think가 결과를 검토해 이 대화에 답했습니다.',
                style: const TextStyle(color: kThinkSub, fontSize: 12),
              ),
            ),
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

  Widget _buttons(ThinkCodeRound? latest, bool superseded) {
    final think = ThinkController.instance;
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
        if (_change && !superseded && r.status.appliable && latest != null && latest.patchAppliable)
          ElevatedButton.icon(
            onPressed: busy ? null : () => _confirmApply(latest),
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
        if (_change && _retryable.contains(r.status))
          OutlinedButton.icon(
            onPressed: busy ? null : _confirmRetry,
            style: thinkOutlineButton(),
            icon: const Icon(Icons.replay, size: 16),
            label: const Text('같은 내용으로 다시 수정'),
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
    final v = round.verification;
    final warnings = [
      if (v == null || v.items.isEmpty) '· ${v == null ? '자동 검사 기록이 없습니다' : '자동 검사한 항목이 없습니다'}. 이 변경은 검사로 확인되지 않았습니다.',
      if (v != null && v.requiredFailed > 0) '· 필수 검사 ${v.requiredFailed}개가 실패했습니다. 이대로 적용하면 앱이나 서버가 깨질 수 있습니다.',
      if (v != null && v.requiredSkipped > 0) '· 실행하지 못한 필수 검사 ${v.requiredSkipped}개는 확인되지 않았습니다(통과가 아닙니다).',
      if (v != null && v.preexisting > 0) '· 원래도 실패하던 검사 ${v.preexisting}개는 이번 변경을 확인하지 못했습니다.',
      if (v != null && v.followups.isNotEmpty) '· 실제 데이터가 필요한 후속 확인 ${v.followups.length}개는 이번 검사에 들어 있지 않습니다.',
      if (v != null && v.stopped) '· 자동 검사가 중간에 멈췄습니다.',
      if (round.touchesMigrations) '· DB 함수 파일(supabase/migrations)은 파일만 놓이고 운영 DB에는 반영되지 않습니다. 반영은 따로 승인합니다.',
    ];
    final failed = v != null && v.requiredFailed > 0;
    final ok = await confirmThink(
      context,
      title: failed ? '검사에 실패한 변경입니다. 그래도 적용할까요?' : '작업 폴더에 적용할까요?',
      message: '${warnings.isEmpty ? '' : '${warnings.join('\n')}\n\n'}'
          '파일 ${stats?.files ?? files.length}개 (+${stats?.additions ?? 0} -${stats?.deletions ?? 0})를 '
          '이 PC의 저장소 작업 폴더에 적용합니다.\n\n$names$more\n\n'
          '· 작업자가 먼저 git apply --check로 확인하고, 통과할 때만 적용합니다.\n'
          '· 적용 직전 상태를 백업(git ref)해 두고, 이 카드의 되돌리기로 되돌릴 수 있습니다.\n'
          '· 커밋이나 스테이징은 하지 않습니다.',
      confirmLabel: failed ? '그래도 적용' : '적용',
      destructive: failed,
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

  static const _retryable = {ThinkCodeStatus.needsReview, ThinkCodeStatus.failed, ThinkCodeStatus.cancelled};

  Future<void> _confirmRetry() async {
    final ok = await confirmThink(
      context,
      title: '같은 내용으로 다시 수정할까요?',
      message: '이 요청과 같은 지시로 새 수정 요청을 보냅니다. 하루 요청 1건을 씁니다.\n\n'
          '· 새 복사본에서 처음부터 다시 고칩니다. 이 카드의 diff는 그대로 남습니다.\n'
          '· 결과는 새 카드로 올라오고, 적용은 그 카드에서 승인합니다.',
      confirmLabel: '다시 수정',
    );
    if (ok) await run(() => _c.retryChange(r), done: '다시 보냈습니다. 작업자가 켜져 있으면 곧 시작합니다.');
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
    await run(() => _c.decide(r, result.outcome, result.note.trim().isEmpty ? null : result.note.trim()),
        done: '판단을 남겼습니다.');
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
        effort: widget.spec.effort,
        effortReason: widget.spec.effortReason,
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
      title: Text(_change ? '코드 수정 제안 고치기' : '코드 조사 제안 고치기',
          style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
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
