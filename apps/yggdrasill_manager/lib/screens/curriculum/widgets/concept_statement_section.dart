import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/concept_library_controller.dart';
import '../../../services/concept_library_service.dart';
import '../../../services/concept_service.dart';
import '../../../services/concept_statement_service.dart';
import '../../../services/concept_statement_store.dart';
import '../../../widgets/latex_text_renderer.dart';
import '../../think/think_style.dart';
import 'concept_base_draft.dart';
import 'concept_library_pane.dart';
import 'concept_relation_section.dart';
import 'concept_statement_dialogs.dart';
import 'concept_workspace.dart';

/// 서술 칩·제목에 쓰는 이름. 확정본이 있으면 확정본, 없으면 초안.
String conceptStatementTitle(ConceptStatement s) {
  final t = (s.content ?? s.draft)?.title.trim() ?? '';
  return t.isEmpty ? '(제목 없음)' : t;
}

Widget _math(String text, {double size = 14, Color color = kThinkText}) => LatexTextRenderer(
      text,
      dollarMath: true,
      style: TextStyle(color: color, fontSize: size, height: 1.6),
      crossAxisAlignment: CrossAxisAlignment.start,
      blockVerticalPadding: 4,
    );

Widget _labeled(String label, Widget child) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          child,
        ],
      ),
    );

Widget _subText(String text) =>
    SelectableText(text, style: const TextStyle(color: kThinkSub, fontSize: 13, height: 1.5));

Widget _smallButton(String label, IconData icon, VoidCallback? onTap, {Color color = kThinkAccent, Key? key}) =>
    TextButton.icon(
      key: key,
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: TextButton.styleFrom(foregroundColor: color, visualDensity: VisualDensity.compact),
    );

Color _statusColor(ConceptStatement s) => s.confirmed ? kThinkSuccess : kThinkHint;

/// 개념 상세의 서술 칸(A안): 개념 공통 내용 → 서술 고르기 줄 → 고른 서술만 펼침.
/// 기본 서술은 개념 본문이다. 저장 전 개념에는 쓰지 않는다.
class ConceptStatementSection extends StatelessWidget {
  const ConceptStatementSection({
    super.key,
    required this.controller,
    required this.concept,
    required this.onEditBase,
    this.onBaseChanged,
  });

  final ConceptLibraryController controller;
  final ConceptItem concept;
  final VoidCallback onEditBase;

  /// 기본 서술 수정안을 확정했거나 본문이 그사이 바뀌었을 때 개념을 다시 읽는다.
  final Future<void> Function(String conceptId)? onBaseChanged;

  ConceptStatementStore get _store => controller.statements;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final id = concept.id;
        final err = _store.errorOf(id);
        if (!_store.loaded(id)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BaseContent(concept: concept),
              const SizedBox(height: 8),
              if (err == null)
                const ConceptHint('서술을 읽는 중입니다.')
              else if (_store.notReady)
                ConceptHint(err)
              else
                Row(
                  children: [
                    Expanded(
                        child: ThinkNotice(text: '서술을 읽지 못했습니다: $err', color: kThinkError, icon: Icons.error_outline)),
                    IconButton(
                      tooltip: '다시 읽기',
                      onPressed: () => unawaited(_store.load(id)),
                      icon: const Icon(Icons.refresh, size: 16),
                      color: kThinkHint,
                    ),
                  ],
                ),
            ],
          );
        }
        final core = _store.coreOf(id);
        final list = _store.statementsOf(id);
        final selectedId = _store.selectedOf(id);
        final selected = _store.byId(id, selectedId);
        final total = list.length + 1;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (core != null) ...[
              _CoreBox(
                store: _store,
                concept: concept,
                core: core,
                impact: () => conceptEditImpact(controller, concept, core: true),
              ),
              const SizedBox(height: 16),
            ],
            ConceptSectionTitle(
              '서술 $total',
              trailing: Wrap(
                spacing: 4,
                children: [
                  if (core == null)
                    _smallButton(
                        '공통 내용 쓰기',
                        Icons.hub_outlined,
                        _store.busy
                            ? null
                            : () => unawaited(showConceptCoreDialog(context, store: _store, concept: concept)),
                        key: const ValueKey('statement-core-add'),
                        color: kThinkSub),
                  _smallButton(
                    '서술 더하기',
                    Icons.add,
                    _store.busy
                        ? null
                        : () => unawaited(showConceptStatementDialog(context, store: _store, concept: concept)),
                    key: const ValueKey('statement-add'),
                  ),
                ],
              ),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ThinkToggleChip(
                  key: const ValueKey('statement-pick-base'),
                  label: '기본(개념 본문)',
                  icon: Icons.notes,
                  selected: selected == null,
                  onChanged: (_) => _store.select(id, null),
                ),
                for (final s in list)
                  ThinkToggleChip(
                    key: ValueKey('statement-pick-${s.id}'),
                    label: conceptStatementTitle(s),
                    icon: Icons.short_text,
                    tooltip: s.statusLabel,
                    selected: s.id == selected?.id,
                    onChanged: (_) => _store.select(id, s.id),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kThinkBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kThinkLink.withValues(alpha: 0.5)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.short_text, size: 16, color: kThinkLink),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          selected == null
                              ? '서술 · 기본(개념 본문)'
                              : '서술 ${list.indexOf(selected) + 2}/$total · ${conceptStatementTitle(selected)}',
                          style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (selected == null) ...[
                    _BaseContent(concept: concept),
                    const SizedBox(height: 8),
                    ConceptBaseDraftBox(store: _store, concept: concept),
                  ] else
                    _StatementBody(key: ValueKey(selected.id), statement: selected),
                  const SizedBox(height: 10),
                  _Appearances(store: _store, concept: concept, statement: selected),
                  const SizedBox(height: 8),
                  _StatementSourcesMark(controller: controller, concept: concept, statementId: selected?.id),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (selected == null) ...[
                        _smallButton(
                          _store.contentDraftOf(id) == null ? '수정안 쓰기' : '수정안 열기',
                          Icons.edit_note,
                          _store.busy || !_store.contentDraftLoaded(id)
                              ? null
                              : () => unawaited(showConceptBaseDraftDialog(
                                    context,
                                    controller: controller,
                                    concept: concept,
                                    impact: conceptEditImpact(controller, concept),
                                    onBaseChanged: onBaseChanged,
                                  )),
                          key: const ValueKey('base-draft-open'),
                        ),
                        _smallButton('개념 본문 수정', Icons.edit_outlined, onEditBase, color: kThinkSub),
                        _smallButton('고친 기록', Icons.history,
                            () => unawaited(showConceptContentHistory(context, store: _store, concept: concept)),
                            color: kThinkSub),
                      ] else ...[
                        _smallButton(
                          '서술 고치기',
                          Icons.edit_outlined,
                          _store.busy
                              ? null
                              : () => unawaited(showConceptStatementDialog(context,
                                  store: _store,
                                  concept: concept,
                                  statement: selected,
                                  impact: conceptEditImpact(controller, concept, statement: selected))),
                          key: const ValueKey('statement-edit'),
                          color: kThinkSub,
                        ),
                        if (selected.confirmed)
                          _smallButton(
                              '확정 기록',
                              Icons.history,
                              () =>
                                  unawaited(showConceptStatementRevisions(context, store: _store, statement: selected)),
                              color: kThinkSub),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (list.isNotEmpty) ...[
              const SizedBox(height: 8),
              const ConceptHint('서술 사이 관계는 기록하지 않습니다(관계는 개념 사이에만 둡니다). 서술마다 조건·용어·원문 여부를 비교해 보세요.'),
            ],
          ],
        );
      },
    );
  }
}

class _BaseContent extends StatelessWidget {
  const _BaseContent({required this.concept});

  final ConceptItem concept;

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: LatexTextRenderer(
        concept.content,
        dollarMath: true,
        style: const TextStyle(color: kThinkSub, fontSize: 14, height: 1.6),
        crossAxisAlignment: CrossAxisAlignment.start,
        blockVerticalPadding: 6,
      ),
    );
  }
}

/// 개념 공통 내용. 모든 서술에 해당한다고 머리에 적는다.
class _CoreBox extends StatelessWidget {
  const _CoreBox({required this.store, required this.concept, required this.core, required this.impact});

  final ConceptStatementStore store;
  final ConceptItem concept;
  final ConceptStatement core;
  final String Function() impact;

  @override
  Widget build(BuildContext context) {
    final t = core.content ?? core.draft ?? const ConceptStatementText();
    return Container(
      key: const ValueKey('statement-core'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kThinkBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kThinkAccent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.hub_outlined, size: 16, color: kThinkAccent),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('개념 공통 내용 · 모든 서술에 해당',
                    style: TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w800)),
              ),
              ThinkBadge(core.statusLabel, color: _statusColor(core)),
              IconButton(
                key: const ValueKey('statement-core-edit'),
                tooltip: '공통 내용 고치기',
                onPressed: store.busy
                    ? null
                    : () => unawaited(
                        showConceptCoreDialog(context, store: store, concept: concept, core: core, impact: impact())),
                icon: const Icon(Icons.edit_outlined, size: 16),
                color: kThinkSub,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          if (t.meaning.isNotEmpty) _labeled('공통 의미', _subText(t.meaning)),
          if (t.scope != null) _labeled('적용 범위', _subText(t.scope!)),
          if (t.conditions != null) _labeled('공통 조건', _subText(t.conditions!)),
          if (core.confirmed)
            Align(
              alignment: Alignment.centerLeft,
              child: _smallButton('확정 기록', Icons.history,
                  () => unawaited(showConceptStatementRevisions(context, store: store, statement: core)),
                  color: kThinkSub),
            ),
        ],
      ),
    );
  }
}

/// 고른 서술 하나의 내용(확정본, 확정 전이면 초안).
class _StatementBody extends StatefulWidget {
  const _StatementBody({super.key, required this.statement});

  final ConceptStatement statement;

  @override
  State<_StatementBody> createState() => _StatementBodyState();
}

class _StatementBodyState extends State<_StatementBody> {
  bool _showSource = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.statement;
    final t = s.content ?? s.draft ?? const ConceptStatementText();
    final cis = t.conditionsInSource;
    final hasSource = t.quote != null || t.supplementNote != null || t.unverifiedNote != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ThinkBadge(s.statusLabel, color: _statusColor(s)),
            if ((t.approach ?? '').isNotEmpty) ThinkBadge(t.approach!, color: kThinkSub),
            ThinkBadge(t.basis.label, color: t.basis == ConceptStatementBasis.verbatim ? kThinkLink : kThinkSub),
            if (cis != null)
              ThinkBadge(cis.label, color: cis == ConceptConditionsInSource.checkContext ? kThinkAccent : kThinkSub),
          ],
        ),
        const SizedBox(height: 8),
        SelectionArea(child: _math(t.body)),
        if (t.conditions != null) _labeled('이 서술의 적용 대상·조건', _subText(t.conditions!)),
        if (t.terms.isNotEmpty)
          _labeled(
            '필요한 용어',
            Wrap(spacing: 6, runSpacing: 6, children: [for (final term in t.terms) ThinkBadge(term, color: kThinkSub)]),
          ),
        if (hasSource) ...[
          const SizedBox(height: 4),
          InkWell(
            key: const ValueKey('statement-source-toggle'),
            onTap: () => setState(() => _showSource = !_showSource),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_showSource ? Icons.expand_less : Icons.expand_more, size: 18, color: kThinkLink),
                  const SizedBox(width: 4),
                  const Text('원문과 보완한 점',
                      style: TextStyle(color: kThinkLink, fontSize: 12, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
          if (_showSource) ...[
            if (t.quote != null)
              _labeled(
                '원문(책에 적힌 문장 또는 원문 참조)',
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: kThinkQuote, borderRadius: BorderRadius.circular(8)),
                  child: SelectionArea(child: _math(t.quote!, size: 13)),
                ),
              ),
            if (t.supplementNote != null) _labeled('보완·수정한 부분과 이유', _subText(t.supplementNote!)),
            if (t.unverifiedNote != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ThinkNotice(text: '확인 안 됨: ${t.unverifiedNote!}', color: kThinkAccent, icon: Icons.help_outline),
              ),
          ],
        ],
      ],
    );
  }
}

class _Appearances extends StatelessWidget {
  const _Appearances({required this.store, required this.concept, required this.statement});

  final ConceptStatementStore store;
  final ConceptItem concept;
  final ConceptStatement? statement;

  @override
  Widget build(BuildContext context) {
    final list = store.appearancesOf(concept.id, statement?.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConceptSectionTitle(
          '등장 위치',
          trailing: _smallButton(
            '등장 위치 더하기',
            Icons.add,
            store.busy
                ? null
                : () => unawaited(
                    showConceptAppearanceDialog(context, store: store, concept: concept, statement: statement)),
            key: const ValueKey('appearance-add'),
          ),
        ),
        if (list.isEmpty)
          const ConceptHint('넣은 등장 위치가 없습니다. 확인한 교육과정·학년·단원만 넣습니다.')
        else
          for (final a in list)
            Row(
              children: [
                const Icon(Icons.school_outlined, size: 14, color: kThinkHint),
                const SizedBox(width: 6),
                Expanded(
                  child: Tooltip(
                    message: a.note ?? a.label,
                    child: Text(a.label, style: const TextStyle(color: kThinkSub, fontSize: 12)),
                  ),
                ),
                IconButton(
                  tooltip: '등장 위치 빼기',
                  onPressed: store.busy ? null : () => unawaited(_remove(context, a)),
                  icon: const Icon(Icons.close, size: 14),
                  color: kThinkHint,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
      ],
    );
  }

  Future<void> _remove(BuildContext context, ConceptAppearance a) async {
    final ok = await confirmThink(
      context,
      title: '등장 위치 빼기',
      message: '"${a.label}"을(를) 뺍니다. 개념과 서술, 다른 등장 위치는 그대로 남습니다.',
      confirmLabel: '빼기',
      destructive: true,
    );
    if (!ok) return;
    final err = await store.removeAppearance(a);
    if (err != null && context.mounted) showThinkSnack(context, err, error: true);
  }
}

/// 고른 서술에 붙은 출처 수. 누르면 출처 창(서술 바꾸기 포함)이 열린다.
class _StatementSourcesMark extends StatelessWidget {
  const _StatementSourcesMark({required this.controller, required this.concept, required this.statementId});

  final ConceptLibraryController controller;
  final ConceptItem concept;
  final String? statementId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final all = controller.sourcesOf(concept.id);
        if (all == null) return const SizedBox.shrink();
        final mine = [
          for (final s in all)
            if (controller.statements.statementOfSource(concept.id, s.id) == statementId) s
        ];
        final color = mine.isEmpty ? kThinkHint : kThinkLink;
        final lines = [
          for (final s in mine.take(5)) conceptSourceLabel(s),
          if (mine.length > 5) '외 ${mine.length - 5}개'
        ];
        return Align(
          alignment: Alignment.centerLeft,
          child: Tooltip(
            message: [
              if (lines.isEmpty) '이 서술에 붙은 출처가 없습니다.' else ...lines,
              '누르면 출처마다 어느 서술의 출처인지 고를 수 있습니다.',
            ].join('\n'),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: const ValueKey('statement-sources'),
                onTap: all.isEmpty
                    ? null
                    : () => showConceptSourcesDialog(context, controller: controller, concept: concept),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: color.withValues(alpha: 0.6)),
                    color: color.withValues(alpha: 0.10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.menu_book_outlined, size: 14, color: color),
                      const SizedBox(width: 6),
                      Text(mine.isEmpty ? '이 서술의 출처 없음' : '이 서술의 출처 ${mine.length}개',
                          style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 출처 창 안의 "어느 서술의 출처" 고르기. 서술이 기본 서술뿐이면 보이지 않는다.
class ConceptSourceStatementPicker extends StatelessWidget {
  const ConceptSourceStatementPicker({super.key, required this.store, required this.source});

  final ConceptStatementStore store;
  final ConceptSourceRef source;

  @override
  Widget build(BuildContext context) {
    final list = store.statementsOf(source.conceptId);
    if (!store.loaded(source.conceptId) || list.isEmpty) return const SizedBox.shrink();
    final current = store.statementOfSource(source.conceptId, source.id);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SizedBox(
        width: 300,
        child: InputDecorator(
          decoration: thinkInputDecoration(label: '어느 서술의 출처', dense: true),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              key: ValueKey('source-statement-${source.id}'),
              value: list.any((s) => s.id == current) ? current : null,
              isExpanded: true,
              isDense: true,
              dropdownColor: kThinkPanel,
              style: const TextStyle(color: kThinkText, fontSize: 13),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('기본(개념 본문)')),
                for (final s in list)
                  DropdownMenuItem<String?>(
                    value: s.id,
                    child: Text(conceptStatementTitle(s), overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: store.busy
                  ? null
                  : (v) async {
                      if (v == current) return;
                      final err = await store.setSourceStatement(source.conceptId, source.id, v);
                      if (err != null && context.mounted) showThinkSnack(context, err, error: true);
                    },
            ),
          ),
        ),
      ),
    );
  }
}
