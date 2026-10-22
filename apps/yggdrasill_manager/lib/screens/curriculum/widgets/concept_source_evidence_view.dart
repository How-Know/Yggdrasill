import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/concept_library_service.dart';
import '../../../services/concept_source_evidence.dart';
import '../../../services/concept_statement_store.dart';
import '../../../widgets/latex_text_renderer.dart';
import '../../think/think_style.dart';
import 'concept_statement_section.dart';
import 'concept_workspace.dart';

Color conceptEvidenceColor(ConceptEvidenceScope s) => switch (s) {
      ConceptEvidenceScope.whole => kThinkSuccess,
      ConceptEvidenceScope.part => kThinkLink,
      ConceptEvidenceScope.related => kThinkSub,
      ConceptEvidenceScope.unknown => kThinkHint,
    };

String _when(DateTime? t) {
  if (t == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// 출처 창 위쪽: 서술마다 "AI에게 근거 범위 제안받기"와 제안 요약. 근거 블록이 있는 출처가 있는 서술만 보인다.
class ConceptEvidenceProposeBar extends StatelessWidget {
  const ConceptEvidenceProposeBar({
    super.key,
    required this.evidence,
    required this.statements,
    required this.conceptId,
  });

  final ConceptEvidenceController evidence;
  final ConceptStatementStore statements;
  final String conceptId;

  String _title(String? statementId) {
    if (statementId == null) return '기본 서술';
    final s = statements.byId(conceptId, statementId);
    return s == null ? '다른 서술' : '서술 "${conceptStatementTitle(s)}"';
  }

  @override
  Widget build(BuildContext context) {
    final snap = evidence.snapshot;
    if (evidence.error != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: evidence.notReady
            ? ConceptHint(evidence.error!)
            : ThinkNotice(text: '근거 범위를 읽지 못했습니다: ${evidence.error}', color: kThinkError, icon: Icons.error_outline),
      );
    }
    if (snap == null) {
      return const Padding(padding: EdgeInsets.only(bottom: 10), child: ConceptHint('근거 범위를 읽는 중입니다.'));
    }
    final groups = <String?>[
      for (final b in snap.bases)
        if (snap.sources.values.any((s) => s.statementId == b.statementId && s.blocks.isNotEmpty)) b.statementId,
    ];
    if (groups.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 10),
        child: ConceptHint('근거 블록이 이어진 출처가 없어 AI 범위 제안은 쓸 수 없습니다. 범위는 출처마다 직접 정할 수 있습니다.'),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final g in groups)
                OutlinedButton.icon(
                  key: ValueKey('evidence-propose-${g ?? 'base'}'),
                  onPressed: evidence.proposing.contains(g) ? null : () => unawaited(evidence.propose(g)),
                  style: thinkOutlineButton(),
                  icon: const Icon(Icons.auto_awesome_outlined, size: 16),
                  label: Text(evidence.proposing.contains(g) ? '${_title(g)} · 제안 받는 중…' : '${_title(g)} 근거 범위 제안받기',
                      overflow: TextOverflow.ellipsis),
                ),
            ],
          ),
          for (final g in groups) ...[
            if (evidence.proposeErrors[g] != null) ...[
              const SizedBox(height: 6),
              ThinkNotice(
                  text: '${_title(g)}: ${evidence.proposeErrors[g]}', color: kThinkError, icon: Icons.error_outline),
            ],
            if (evidence.proposalFor(g) != null) ...[
              const SizedBox(height: 6),
              _summary(g, evidence.proposalFor(g)!),
            ],
          ],
        ],
      ),
    );
  }

  Widget _summary(String? g, ConceptEvidenceProposal p) {
    final notes = [
      if (p.noBlocks.isNotEmpty) '근거 블록이 없어 보내지 않은 출처 ${p.noBlocks.length}개',
      if (p.unanswered.isNotEmpty) 'AI가 답하지 않은 출처 ${p.unanswered.length}개',
    ];
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kThinkPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkAccent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${_title(g)} · AI 제안 ${p.items.length}줄 (받아들인 줄만 저장)',
              style: const TextStyle(color: kThinkAccent, fontSize: 12, fontWeight: FontWeight.w800)),
          if (p.summary.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(p.summary, style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.5)),
          ],
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 4),
            ConceptHint(notes.join(' · ')),
          ],
        ],
      ),
    );
  }
}

/// 출처 한 줄 아래: 근거 범위 배지·메모·근거 문장 보기·AI 제안 받아들이기/버리기.
class ConceptSourceEvidenceLine extends StatefulWidget {
  const ConceptSourceEvidenceLine({
    super.key,
    required this.evidence,
    required this.source,
    required this.sourceLabel,
  });

  final ConceptEvidenceController evidence;
  final ConceptSourceRef source;
  final String sourceLabel;

  @override
  State<ConceptSourceEvidenceLine> createState() => _ConceptSourceEvidenceLineState();
}

class _ConceptSourceEvidenceLineState extends State<ConceptSourceEvidenceLine> {
  bool _open = false;

  ConceptEvidenceController get _ev => widget.evidence;

  @override
  Widget build(BuildContext context) {
    final e = _ev.of(widget.source.id);
    if (e == null) return const SizedBox.shrink();
    final busy = _ev.busy.contains(e.sourceId);
    final color = conceptEvidenceColor(e.scope);
    final when = _when(e.setAt);
    final tip = [
      e.scope.hint,
      if (e.origin != null) '${e.originLabel}${when.isEmpty ? '' : ' · $when'}',
    ].join('\n');
    final item = _ev.proposalItem(e.sourceId);
    final id = e.sourceId;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Tooltip(
                message: tip,
                child: ThinkBadge('근거 범위: ${e.scope.label}', key: ValueKey('evidence-scope-$id'), color: color),
              ),
              if (e.origin == 'ai') const ThinkBadge('AI 제안 승인', color: kThinkSub),
              if (e.basisChanged)
                const Tooltip(
                  message: '범위를 정한 뒤 이 서술 글이 바뀌었습니다. 다시 확인해 주세요. 범위는 자동으로 바꾸지 않습니다.',
                  child: ThinkBadge('정한 뒤 서술 바뀜', color: kThinkAccent),
                ),
              TextButton(
                key: ValueKey('evidence-edit-$id'),
                onPressed: busy ? null : () => unawaited(_edit(e)),
                style: TextButton.styleFrom(foregroundColor: kThinkLink, visualDensity: VisualDensity.compact),
                child: Text(busy ? '저장 중…' : '범위 정하기'),
              ),
              if (e.blocks.isNotEmpty)
                TextButton(
                  key: ValueKey('evidence-blocks-$id'),
                  onPressed: () => setState(() => _open = !_open),
                  style: TextButton.styleFrom(foregroundColor: kThinkLink, visualDensity: VisualDensity.compact),
                  child: Text(_open ? '근거 문장 접기' : '근거 문장 ${e.blocks.length}개 보기'),
                ),
            ],
          ),
          if ((e.note ?? '').trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('범위 메모: ${e.note!.trim()}', style: const TextStyle(color: kThinkSub, fontSize: 12)),
            ),
          if (e.blocks.isEmpty)
            ConceptHint(e.linked && !e.draftFound
                ? '근거를 적어 둔 초안 기록이 지워져 근거 문장을 볼 수 없습니다.'
                : '이어진 근거 블록이 없습니다(직접 이은 출처이거나 초안 기록에서 정확히 찾지 못함).'),
          if (_open && e.blocks.isNotEmpty) _blocks(e),
          if (item != null) _proposal(e, item),
        ],
      ),
    );
  }

  Widget _blocks(ConceptSourceEvidence e) {
    return Container(
      key: ValueKey('evidence-block-list-${e.sourceId}'),
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: kThinkBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: kThinkBorder)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ConceptHint('교재 쪽을 읽은 글(초안 기록)입니다. 정리한 서술이 아닙니다.'),
          for (final b in e.blocks) ...[
            const SizedBox(height: 6),
            Text(
              [b.kind, if (b.uncertain) '읽기 불확실'].where((s) => s.trim().isNotEmpty).join(' · '),
              style:
                  TextStyle(color: b.uncertain ? kThinkAccent : kThinkHint, fontSize: 11, fontWeight: FontWeight.w700),
            ),
            LatexTextRenderer(
              [b.title, b.text, if (b.figureDescription.trim().isNotEmpty) '(그림: ${b.figureDescription.trim()})']
                  .where((s) => s.trim().isNotEmpty)
                  .join('\n'),
              dollarMath: true,
              style: const TextStyle(color: kThinkText, fontSize: 12, height: 1.5),
              crossAxisAlignment: CrossAxisAlignment.start,
            ),
          ],
        ],
      ),
    );
  }

  Widget _proposal(ConceptSourceEvidence e, ConceptEvidenceProposalItem item) {
    final p = _ev.proposalFor(e.statementId);
    final busy = _ev.busy.contains(e.sourceId);
    return Container(
      key: ValueKey('evidence-proposal-${e.sourceId}'),
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kThinkPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkAccent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'AI 제안: ${item.scope.label}${item.scope == e.scope ? ' (지금과 같음)' : ' (지금 ${e.scope.label})'}',
            style: TextStyle(color: conceptEvidenceColor(item.scope), fontSize: 12, fontWeight: FontWeight.w800),
          ),
          if (item.reason.isNotEmpty)
            Text(item.reason, style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.5)),
          if (item.covered.isNotEmpty) ConceptHint('근거에 있는 부분: ${item.covered}'),
          if (item.missing.isNotEmpty) ConceptHint('근거에 없는 부분: ${item.missing}'),
          const SizedBox(height: 4),
          Row(
            children: [
              TextButton(
                key: ValueKey('evidence-accept-${e.sourceId}'),
                onPressed: busy || p == null ? null : () => unawaited(_accept(p, item)),
                style: TextButton.styleFrom(foregroundColor: kThinkSuccess, visualDensity: VisualDensity.compact),
                child: const Text('받아들이기'),
              ),
              TextButton(
                key: ValueKey('evidence-reject-${e.sourceId}'),
                onPressed: busy || p == null ? null : () => _ev.reject(p, item),
                style: TextButton.styleFrom(foregroundColor: kThinkSub, visualDensity: VisualDensity.compact),
                child: const Text('버리기'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _accept(ConceptEvidenceProposal p, ConceptEvidenceProposalItem item) async {
    final err = await _ev.accept(p, item);
    if (err != null && mounted) showThinkSnack(context, err, error: true);
  }

  Future<void> _edit(ConceptSourceEvidence e) async {
    final picked = await showDialog<({ConceptEvidenceScope scope, String note})>(
      context: context,
      builder: (_) => _EvidenceScopeDialog(current: e, label: widget.sourceLabel),
    );
    if (picked == null || !mounted) return;
    final err = await _ev.setScope(e, picked.scope, picked.note.trim().isEmpty ? null : picked.note.trim());
    if (err != null && mounted) showThinkSnack(context, err, error: true);
  }
}

class _EvidenceScopeDialog extends StatefulWidget {
  const _EvidenceScopeDialog({required this.current, required this.label});

  final ConceptSourceEvidence current;
  final String label;

  @override
  State<_EvidenceScopeDialog> createState() => _EvidenceScopeDialogState();
}

class _EvidenceScopeDialogState extends State<_EvidenceScopeDialog> {
  late ConceptEvidenceScope _scope = widget.current.scope;
  late final TextEditingController _note = TextEditingController(text: widget.current.note ?? '');

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
      title: const Text('근거 범위 정하기', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.label, style: const TextStyle(color: kThinkSub, fontSize: 13)),
            const SizedBox(height: 10),
            const ConceptHint('이 쪽이 서술을 얼마나 뒷받침하는지 고릅니다. 출처가 하나 이어졌다고 서술 전체가 그 교재에 적혀 있다는 뜻은 아닙니다.'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in ConceptEvidenceScope.values)
                  ThinkToggleChip(
                    key: ValueKey('evidence-pick-${s.db}'),
                    label: s.label,
                    icon: Icons.fact_check_outlined,
                    tooltip: s.hint,
                    selected: _scope == s,
                    onChanged: (_) => setState(() => _scope = s),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            ConceptHint(_scope.hint),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('evidence-note'),
              controller: _note,
              maxLength: 500,
              maxLines: 3,
              minLines: 1,
              style: const TextStyle(color: kThinkText, fontSize: 13),
              decoration: thinkInputDecoration(label: '범위 메모(선택)', hint: '예: 정의만 있고 적용 조건은 없음'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
        FilledButton(
          key: const ValueKey('evidence-scope-save'),
          onPressed: () => Navigator.pop(context, (scope: _scope, note: _note.text)),
          style: FilledButton.styleFrom(backgroundColor: kThinkAccent),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

/// 출처 목록과 근거 상태가 어긋났는지(출처를 더하거나 빼거나 다른 서술로 옮김). 어긋나면 다시 읽는다.
/// [statementOf]가 null이면(서술을 아직 못 읽음) 출처 id만 본다.
bool conceptEvidenceOutOfDate(
  ConceptEvidenceSnapshot? snap,
  List<ConceptSourceRef> sources,
  String? Function(ConceptSourceRef)? statementOf,
) {
  if (snap == null) return false;
  if (snap.sources.length != sources.length) return true;
  for (final s in sources) {
    final e = snap.sources[s.id];
    if (e == null) return true;
    if (statementOf != null && e.statementId != statementOf(s)) return true;
  }
  return false;
}
