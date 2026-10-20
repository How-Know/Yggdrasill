import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/concept_library_controller.dart';
import '../../../services/concept_relation_service.dart';
import '../../../services/concept_relation_store.dart';
import '../../../services/concept_service.dart';
import '../../../services/concept_statement_service.dart';
import '../../think/think_style.dart';
import 'concept_library_pane.dart';
import 'concept_workspace.dart';

Widget _smallButton(String label, IconData icon, VoidCallback? onTap, {Color color = kThinkAccent, Key? key}) =>
    TextButton.icon(
      key: key,
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: TextButton.styleFrom(foregroundColor: color, visualDensity: VisualDensity.compact),
    );

String _date(DateTime? d) =>
    d == null ? '' : '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';

/// 개념을 고치기 전에 보여 줄 "이 개념에 붙은 것". 고쳐도 아래 것들은 자동으로 바뀌지 않는다는 안내다.
/// [statement]가 있으면 그 서술, [core]면 공통 내용, 둘 다 없으면 기본 서술(개념 본문)을 고칠 때.
String conceptEditImpact(ConceptLibraryController c, ConceptItem concept,
    {ConceptStatement? statement, bool core = false}) {
  final id = concept.id;
  final st = c.statements;
  final rel = c.relations;
  final parts = <String>[];
  var unknown = false;
  void add(String label, int? n, {String unit = '개'}) {
    if (n == null) {
      unknown = true;
    } else if (n > 0) {
      parts.add('$label $n$unit');
    }
  }

  final sources = c.sourcesOf(id);
  final criteria = c.linkedCriteriaOf(id)?.length;
  final relations = rel.loaded(id) ? rel.relationsOf(id).length : null;
  final reviews = rel.loaded(id) ? rel.openReviewsOf(id).length : null;
  final statements = st.statementCountOf(id);
  if (statement != null) {
    add(
        '이 서술의 출처',
        sources == null || !st.loaded(id)
            ? null
            : sources.where((s) => st.statementOfSource(id, s.id) == statement.id).length);
    add('이 서술의 등장 위치', st.loaded(id) ? st.appearancesOf(id, statement.id).length : null);
  } else if (core) {
    add('공통 내용이 해당하는 서술', statements == null ? null : statements + 1);
  } else {
    add('기본 서술의 출처',
        sources == null || !st.loaded(id) ? null : sources.where((s) => st.statementOfSource(id, s.id) == null).length);
    add('다른 서술', statements);
    add('기본 서술의 등장 위치', st.loaded(id) ? st.appearancesOf(id, null).length : null);
  }
  add('이은 기준', criteria);
  add('다른 개념과의 관계', relations);
  add('검토 필요', reviews, unit: '건');
  final what = statement != null ? '이 서술' : (core ? '공통 내용' : '개념 본문');
  return [
    if (parts.isEmpty) '$what에 붙은 출처·등장 위치·관계·이은 기준이 없습니다.' else '붙은 것: ${parts.join(' · ')}.',
    '$what을(를) 고쳐도 이것들은 자동으로 바뀌거나 옮겨지지 않습니다. 고친 뒤 맞는지 확인하세요.',
    if (unknown) '(아직 읽지 못한 항목은 빼고 셌습니다.)',
  ].join(' ');
}

// ------------------------------------------------------------------ 개념 고르기

/// 이름으로 찾아 개념 하나를 고른다. 닫으면 null.
Future<ConceptPick?> showConceptPickDialog(
  BuildContext context, {
  required Future<List<ConceptPick>> Function(String query) search,
  required String title,
  String? excludeId,
  String initialQuery = '',
  String? hint,
}) =>
    showDialog<ConceptPick>(
      context: context,
      builder: (_) => _ConceptPickDialog(
        search: search,
        title: title,
        excludeId: excludeId,
        initialQuery: initialQuery,
        hint: hint,
      ),
    );

class _ConceptPickDialog extends StatefulWidget {
  const _ConceptPickDialog({
    required this.search,
    required this.title,
    required this.excludeId,
    required this.initialQuery,
    required this.hint,
  });

  final Future<List<ConceptPick>> Function(String query) search;
  final String title;
  final String? excludeId;
  final String initialQuery;
  final String? hint;

  @override
  State<_ConceptPickDialog> createState() => _ConceptPickDialogState();
}

class _ConceptPickDialogState extends State<_ConceptPickDialog> {
  late final TextEditingController _q = TextEditingController(text: widget.initialQuery);
  Timer? _debounce;
  int _seq = 0;
  bool _loading = false;
  String? _error;
  List<ConceptPick> _results = const [];

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.trim().isNotEmpty) unawaited(_run());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => unawaited(_run()));
  }

  Future<void> _run() async {
    final seq = ++_seq;
    final q = _q.text.trim();
    if (q.isEmpty) {
      setState(() {
        _results = const [];
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final list = await widget.search(q);
      if (!mounted || seq != _seq) return;
      setState(() {
        _results = [
          for (final p in list)
            if (p.id != widget.excludeId) p
        ];
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = '찾지 못했습니다: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text(widget.title, style: const TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 520,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('concept-pick-query'),
              controller: _q,
              autofocus: true,
              onChanged: _changed,
              onSubmitted: (_) => unawaited(_run()),
              style: const TextStyle(color: kThinkText, fontSize: 14),
              decoration: thinkInputDecoration(
                hint: '개념 이름으로 찾기',
                dense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 18, color: kThinkHint),
              ),
            ),
            if (widget.hint != null) ...[const SizedBox(height: 8), ConceptHint(widget.hint!)],
            const SizedBox(height: 8),
            if (_loading)
              const LinearProgressIndicator(minHeight: 2, color: kThinkAccent, backgroundColor: kThinkBorder),
            if (_error != null) ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline),
            Expanded(
              child: _results.isEmpty
                  ? Center(
                      child: ConceptHint(_q.text.trim().isEmpty ? '이름을 넣으면 라이브러리에서 찾습니다.' : '맞는 개념이 없습니다.'),
                    )
                  : ListView.separated(
                      itemCount: _results.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, i) {
                        final p = _results[i];
                        return Material(
                          color: kThinkPanel,
                          borderRadius: BorderRadius.circular(8),
                          child: InkWell(
                            key: ValueKey('concept-pick-${p.id}'),
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => Navigator.pop(context, p),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(p.label,
                                      style: const TextStyle(
                                          color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700)),
                                  const SizedBox(height: 2),
                                  Text(p.folderLabel, style: const TextStyle(color: kThinkSub, fontSize: 12)),
                                ],
                              ),
                            ),
                          ),
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
          child: const Text('닫기', style: TextStyle(color: kThinkSub)),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ 판단 창

class ConceptDecision {
  const ConceptDecision({required this.resolution, required this.reverse, this.other, this.note});

  final ConceptReviewResolution resolution;

  /// 확장·특수한 경우를 "B → A"로 읽는다.
  final bool reverse;

  /// 상대가 정해지지 않았던 표시에서 고른 개념.
  final ConceptPick? other;
  final String? note;
}

/// 두 개념이 같은 개념인지, 확장·특수한 경우인지, 서로 다른 개념인지 고른다.
/// [bName]이 null이면 상대를 먼저 고른다([search]). 합치거나 옮기지 않는다.
Future<ConceptDecision?> showConceptDecisionDialog(
  BuildContext context, {
  required String aName,
  String? bName,
  Future<List<ConceptPick>> Function(String query)? search,
  String? excludeId,
  String? about,
}) =>
    showDialog<ConceptDecision>(
      context: context,
      builder: (_) => _DecisionDialog(aName: aName, bName: bName, search: search, excludeId: excludeId, about: about),
    );

class _DecisionDialog extends StatefulWidget {
  const _DecisionDialog({required this.aName, this.bName, this.search, this.excludeId, this.about});

  final String aName;
  final String? bName;
  final Future<List<ConceptPick>> Function(String query)? search;
  final String? excludeId;
  final String? about;

  @override
  State<_DecisionDialog> createState() => _DecisionDialogState();
}

class _DecisionDialogState extends State<_DecisionDialog> {
  ConceptReviewResolution? _choice;
  bool _reverse = false;
  ConceptPick? _other;
  final TextEditingController _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  String? get _b => widget.bName ?? _other?.label;

  Future<void> _pickOther() async {
    final search = widget.search;
    if (search == null) return;
    final p = await showConceptPickDialog(
      context,
      search: search,
      title: '비교할 개념 고르기',
      excludeId: widget.excludeId,
      initialQuery: widget.aName,
    );
    if (p != null && mounted) setState(() => _other = p);
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    final directional = _choice == ConceptReviewResolution.extendsOf || _choice == ConceptReviewResolution.specialCase;
    final ready = _choice != null && (b != null || !_choice!.needsOther) && (!_reverse || b != null);
    final sentence = _choice == null
        ? null
        : (b == null ? null : (_reverse ? _choice!.sentence(b, widget.aName) : _choice!.sentence(widget.aName, b)));
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: const Text('같은 개념인지 판단', style: TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.about != null) ...[ConceptHint(widget.about!), const SizedBox(height: 8)],
              Text('"${widget.aName}"',
                  style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Text('비교할 개념: ', style: TextStyle(color: kThinkSub, fontSize: 13)),
                  Expanded(
                    child: Text(b == null ? '아직 고르지 않음' : '"$b"',
                        style: TextStyle(
                            color: b == null ? kThinkHint : kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
                  ),
                  if (widget.bName == null && widget.search != null)
                    _smallButton(_other == null ? '고르기' : '바꾸기', Icons.search_rounded, () => unawaited(_pickOther()),
                        key: const ValueKey('decision-pick-other'), color: kThinkLink),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in ConceptReviewResolution.values)
                    ThinkToggleChip(
                      key: ValueKey('decision-${r.db}'),
                      label: r.label,
                      icon: switch (r) {
                        ConceptReviewResolution.different => Icons.call_split,
                        ConceptReviewResolution.same => Icons.drag_handle,
                        ConceptReviewResolution.extendsOf => Icons.open_in_full,
                        ConceptReviewResolution.specialCase => Icons.filter_center_focus,
                      },
                      selected: _choice == r,
                      onChanged: (_) => setState(() => _choice = r),
                    ),
                ],
              ),
              if (directional && b != null) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ThinkToggleChip(
                      key: const ValueKey('decision-forward'),
                      label: _choice!.sentence(widget.aName, b),
                      icon: Icons.east,
                      selected: !_reverse,
                      onChanged: (_) => setState(() => _reverse = false),
                    ),
                    ThinkToggleChip(
                      key: const ValueKey('decision-reverse'),
                      label: _choice!.sentence(b, widget.aName),
                      icon: Icons.west,
                      selected: _reverse,
                      onChanged: (_) => setState(() => _reverse = true),
                    ),
                  ],
                ),
              ],
              if (sentence != null) ...[
                const SizedBox(height: 10),
                ThinkNotice(text: '기록할 판단: $sentence', color: kThinkLink, icon: Icons.fact_check_outlined),
              ],
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('decision-note'),
                controller: _note,
                maxLength: 500,
                minLines: 1,
                maxLines: 4,
                style: const TextStyle(color: kThinkText, fontSize: 13),
                decoration: thinkInputDecoration(label: '판단 이유(선택)', hint: '예: 중1은 자연수 범위, 고1은 정수 범위', dense: true),
              ),
              const ConceptHint('두 개념은 합치거나 옮기지 않고 판단만 기록합니다. 이름·학년·문장이 비슷한 것만으로 정하지 마세요.'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
        ElevatedButton(
          key: const ValueKey('decision-save'),
          onPressed: ready
              ? () => Navigator.pop(
                    context,
                    ConceptDecision(
                      resolution: _choice!,
                      reverse: directional && _reverse,
                      other: _other,
                      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
                    ),
                  )
              : null,
          style: thinkPrimaryButton(),
          child: const Text('판단 기록'),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ 상세 칸

/// 개념 상세의 "다른 개념과의 관계" 칸: 검토 필요 표시, 운영자가 고른 관계, 지난 판단.
class ConceptRelationSection extends StatelessWidget {
  const ConceptRelationSection({super.key, required this.controller, required this.concept, this.onOpenConcept});

  final ConceptLibraryController controller;
  final ConceptItem concept;
  final ValueChanged<String>? onOpenConcept;

  ConceptRelationStore get _store => controller.relations;

  String _name(String id) => id == concept.id ? conceptDisplayName(concept) : (_store.pickOf(id)?.label ?? '(이름 모름)');

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
              const ConceptSectionTitle('다른 개념과의 관계'),
              if (err == null)
                const ConceptHint('관계를 읽는 중입니다.')
              else if (_store.notReady)
                ConceptHint(err)
              else
                Row(
                  children: [
                    Expanded(
                        child: ThinkNotice(text: '관계를 읽지 못했습니다: $err', color: kThinkError, icon: Icons.error_outline)),
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
        final relations = _store.relationsOf(id);
        final open = _store.openReviewsOf(id);
        final closed = _store.closedReviewsOf(id);
        final busy = _store.busy;
        return Column(
          key: const ValueKey('concept-relations'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConceptSectionTitle(
              relations.isEmpty ? '다른 개념과의 관계' : '다른 개념과의 관계 ${relations.length}',
              trailing: Wrap(
                spacing: 4,
                children: [
                  _smallButton('검토 필요로 표시', Icons.flag_outlined, busy ? null : () => unawaited(_flag(context)),
                      key: const ValueKey('relation-flag'), color: kThinkSub),
                  _smallButton('관계 더하기', Icons.add, busy ? null : () => unawaited(_add(context)),
                      key: const ValueKey('relation-add')),
                ],
              ),
            ),
            for (final v in open) ...[_openReview(context, v), const SizedBox(height: 6)],
            if (relations.isEmpty && open.isEmpty)
              const ConceptHint('이은 관계가 없습니다. 운영자가 고른 관계만 기록하고, 이름·학년·문장이 비슷하다고 자동으로 잇지 않습니다.'),
            for (final r in relations) _relationLine(context, r),
            if (closed.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('지난 판단 ${closed.length}건',
                  style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
              for (final v in closed.reversed.take(5))
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Tooltip(
                    message: v.resolutionNote ?? v.reasonLabel,
                    child: Text(
                      '· ${v.resolution == null ? '판단함' : (v.otherId == null ? v.resolution!.label : v.resolution!.sentence(_name(v.conceptId), _name(v.otherId!)))}'
                      '${v.resolvedAt == null ? '' : ' · ${_date(v.resolvedAt)}'}',
                      style: const TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }

  Widget _openReview(BuildContext context, ConceptReview v) {
    final mine = v.conceptId == concept.id;
    final otherId = mine ? v.otherId : v.conceptId;
    final otherName = otherId == null ? null : _name(otherId);
    return Container(
      key: ValueKey('concept-review-${v.id}'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kThinkAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkAccent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.flag_outlined, size: 16, color: kThinkAccent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  mine ? '검토 필요 · ${v.reasonLabel}' : '다른 개념의 검토 상대 · ${v.reasonLabel}',
                  style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(otherName == null ? '비교할 개념: 아직 정하지 않음' : '비교할 개념: "$otherName"',
              style: const TextStyle(color: kThinkSub, fontSize: 12)),
          if ((v.note ?? '').isNotEmpty) Text(v.note!, style: const TextStyle(color: kThinkSub, fontSize: 12)),
          Wrap(
            spacing: 4,
            children: [
              _smallButton(
                  '판단하기', Icons.fact_check_outlined, _store.busy ? null : () => unawaited(_resolve(context, v)),
                  key: ValueKey('review-resolve-${v.id}')),
              if (otherId != null && onOpenConcept != null)
                _smallButton('비교할 개념 열기', Icons.open_in_new, () => onOpenConcept!(otherId), color: kThinkLink),
            ],
          ),
        ],
      ),
    );
  }

  Widget _relationLine(BuildContext context, ConceptRelation r) {
    final other = r.otherOf(concept.id);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        key: ValueKey('concept-relation-${r.id}'),
        children: [
          Icon(r.kind == ConceptRelationKind.extendsOf ? Icons.open_in_full : Icons.filter_center_focus,
              size: 14, color: kThinkLink),
          const SizedBox(width: 6),
          Expanded(
            child: Tooltip(
              message: [
                r.originLabel,
                if ((r.note ?? '').isNotEmpty) r.note!,
                if (r.createdAt != null) _date(r.createdAt)
              ].join('\n'),
              child: InkWell(
                onTap: onOpenConcept == null ? null : () => onOpenConcept!(other),
                child: Text(r.kind.sentence(_name(r.conceptId), _name(r.relatedId)),
                    style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.5)),
              ),
            ),
          ),
          IconButton(
            tooltip: '관계 빼기',
            onPressed: _store.busy ? null : () => unawaited(_remove(context, r)),
            icon: const Icon(Icons.close, size: 14),
            color: kThinkHint,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Future<void> _add(BuildContext context) async {
    final p = await showConceptPickDialog(
      context,
      search: _store.backend.search,
      title: '관계를 이을 개념 고르기',
      excludeId: concept.id,
      initialQuery: concept.name,
      hint: '고른 뒤 확장·특수한 경우와 방향을 정합니다.',
    );
    if (p == null || !context.mounted) return;
    _store.rememberPick(p);
    final d = await showConceptDecisionDialog(context, aName: conceptDisplayName(concept), bName: p.label);
    if (d == null || !context.mounted) return;
    String? err;
    switch (d.resolution) {
      case ConceptReviewResolution.extendsOf:
      case ConceptReviewResolution.specialCase:
        final kind = d.resolution == ConceptReviewResolution.extendsOf
            ? ConceptRelationKind.extendsOf
            : ConceptRelationKind.specialCase;
        err = await _store.setRelation(
          conceptId: d.reverse ? p.id : concept.id,
          relatedId: d.reverse ? concept.id : p.id,
          kind: kind,
          note: d.note,
        );
      case ConceptReviewResolution.different:
      case ConceptReviewResolution.same:
        err = await _store.decidePair(conceptId: concept.id, otherId: p.id, resolution: d.resolution, note: d.note);
    }
    if (context.mounted) showThinkSnack(context, err ?? '판단을 기록했습니다.', error: err != null);
  }

  Future<void> _flag(BuildContext context) async {
    final p = await showConceptPickDialog(
      context,
      search: _store.backend.search,
      title: '검토 필요로 표시 · 비교할 개념',
      excludeId: concept.id,
      initialQuery: concept.name,
      hint: '같은 개념인지 나중에 판단할 상대를 고릅니다. 상대 없이 표시하려면 이 창을 닫으세요.',
    );
    if (!context.mounted) return;
    if (p == null) {
      final ok = await confirmThink(
        context,
        title: '상대 없이 검토 필요로 표시할까요?',
        message: '"${conceptDisplayName(concept)}"을(를) 검토 필요로 표시합니다. 비교할 개념은 판단할 때 고릅니다.',
        confirmLabel: '상대 없이 표시',
      );
      if (!ok || !context.mounted) return;
    } else {
      _store.rememberPick(p);
    }
    final err = await _store.openReview(conceptId: concept.id, otherId: p?.id);
    if (context.mounted) showThinkSnack(context, err ?? '검토 필요로 표시했습니다.', error: err != null);
  }

  Future<void> _resolve(BuildContext context, ConceptReview v) async {
    final aName = _name(v.conceptId);
    final d = await showConceptDecisionDialog(
      context,
      aName: aName,
      bName: v.otherId == null ? null : _name(v.otherId!),
      search: _store.backend.search,
      excludeId: v.conceptId,
      about: '${v.reasonLabel}${(v.note ?? '').isEmpty ? '' : ' · ${v.note}'}',
    );
    if (d == null || !context.mounted) return;
    if (d.other != null) _store.rememberPick(d.other!);
    final err = await _store.resolveReview(v, d.resolution, otherId: d.other?.id, note: d.note, reverse: d.reverse);
    if (context.mounted) showThinkSnack(context, err ?? '판단을 기록했습니다.', error: err != null);
  }

  Future<void> _remove(BuildContext context, ConceptRelation r) async {
    final ok = await confirmThink(
      context,
      title: '관계 빼기',
      message: '${r.kind.sentence(_name(r.conceptId), _name(r.relatedId))}(이)라는 관계를 뺍니다. 두 개념과 다른 관계는 그대로 남습니다.',
      confirmLabel: '빼기',
      destructive: true,
    );
    if (!ok) return;
    final err = await _store.removeRelation(r);
    if (err != null && context.mounted) showThinkSnack(context, err, error: true);
  }
}

// ------------------------------------------------------------------ 같은 이름 검토 창

/// 이름이 같은 개념끼리 한 쌍씩 판단한다. 자동으로 합치거나 옮기지 않는다.
Future<void> showSameNameReviewDialog(
  BuildContext context, {
  required ConceptRelationStore store,
  ValueChanged<String>? onOpenConcept,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _SameNameDialog(store: store, onOpenConcept: onOpenConcept),
    );

class _SameNameDialog extends StatefulWidget {
  const _SameNameDialog({required this.store, this.onOpenConcept});

  final ConceptRelationStore store;
  final ValueChanged<String>? onOpenConcept;

  @override
  State<_SameNameDialog> createState() => _SameNameDialogState();
}

class _SameNameDialogState extends State<_SameNameDialog> {
  List<List<ConceptPick>>? _groups;
  List<ConceptReview> _reviews = const [];
  String? _error;
  bool _onlyUndecided = true;

  ConceptRelationStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final groups = await _store.backend.sameNameGroups();
      final ids = [
        for (final g in groups)
          for (final p in g) p.id
      ];
      final reviews = ids.isEmpty ? const <ConceptReview>[] : await _store.backend.reviewsAmong(ids);
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _reviews = reviews;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ConceptRelationException.from(e).message);
    }
  }

  /// 두 개념의 가장 최근 검토(열린 것 먼저).
  ConceptReview? _latest(String a, String b) {
    ConceptReview? best;
    for (final v in _reviews) {
      final pair = (v.conceptId == a && v.otherId == b) || (v.conceptId == b && v.otherId == a);
      if (!pair) continue;
      if (best == null ||
          (v.open && !best.open) ||
          (v.open == best.open &&
              (v.resolvedAt ?? v.createdAt ?? DateTime(0)).isAfter(best.resolvedAt ?? best.createdAt ?? DateTime(0)))) {
        best = v;
      }
    }
    return best;
  }

  Future<void> _decide(ConceptPick a, ConceptPick b) async {
    final d = await showConceptDecisionDialog(context, aName: a.label, bName: b.label);
    if (d == null || !mounted) return;
    final err = await _store.decidePair(
      conceptId: d.reverse ? b.id : a.id,
      otherId: d.reverse ? a.id : b.id,
      resolution: d.resolution,
      note: d.note,
    );
    if (!mounted) return;
    showThinkSnack(context, err ?? '판단을 기록했습니다.', error: err != null);
    if (err == null) await _load();
  }

  String _pairStatus(ConceptReview? v, Map<String, ConceptPick> byId) {
    if (v == null) return '판단 전';
    if (v.open) return '검토 필요(판단 전) · ${v.reasonLabel}';
    final a = byId[v.conceptId]?.label ?? '?';
    final b = v.otherId == null ? '?' : (byId[v.otherId]?.label ?? '?');
    return v.resolution == null ? '판단함' : v.resolution!.sentence(a, b);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final groups = _groups;
    Widget body;
    if (_error != null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline),
          _smallButton('다시 읽기', Icons.refresh, () => unawaited(_load()), color: kThinkLink),
        ],
      );
    } else if (groups == null) {
      body = const Center(child: CircularProgressIndicator(color: kThinkAccent));
    } else if (groups.isEmpty) {
      body = const Center(child: ConceptHint('이름이 같은 개념이 없습니다.'));
    } else {
      final byId = {
        for (final g in groups)
          for (final p in g) p.id: p
      };
      final shown = <Widget>[];
      var undecided = 0;
      for (final g in groups) {
        final pairs = <(ConceptPick, ConceptPick, ConceptReview?)>[];
        for (var i = 0; i < g.length; i++) {
          for (var j = i + 1; j < g.length; j++) {
            final v = _latest(g[i].id, g[j].id);
            if (v == null || v.open) undecided += 1;
            if (_onlyUndecided && v != null && !v.open) continue;
            pairs.add((g[i], g[j], v));
          }
        }
        if (pairs.isEmpty) continue;
        shown.add(Container(
          key: ValueKey('same-name-${conceptNameKey(g.first.name)}'),
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: kThinkPanel,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kThinkBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${g.first.name.trim()} · ${g.length}개',
                  style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              for (final p in g)
                Row(
                  children: [
                    const Icon(Icons.circle, size: 6, color: kThinkHint),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                          '${p.label} · ${p.folderLabel}${p.createdAt == null ? '' : ' · ${_date(p.createdAt)}'}',
                          style: const TextStyle(color: kThinkSub, fontSize: 12)),
                    ),
                    if (widget.onOpenConcept != null)
                      IconButton(
                        tooltip: '이 개념 열기',
                        onPressed: () => widget.onOpenConcept!(p.id),
                        icon: const Icon(Icons.open_in_new, size: 14),
                        color: kThinkLink,
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              const Divider(color: kThinkBorder, height: 16),
              for (final (a, b, v) in pairs)
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${a.label} ↔ ${b.label}',
                              style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
                          Text(_pairStatus(v, byId),
                              style: TextStyle(
                                  color: v == null ? kThinkHint : (v.open ? kThinkAccent : kThinkSuccess),
                                  fontSize: 12)),
                        ],
                      ),
                    ),
                    _smallButton(v != null && !v.open ? '다시 판단' : '판단하기', Icons.fact_check_outlined,
                        _store.busy ? null : () => unawaited(_decide(a, b)),
                        key: ValueKey('same-name-decide-${a.id}-${b.id}')),
                  ],
                ),
            ],
          ),
        ));
      }
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('이름이 같은 개념 ${groups.length}묶음 · 판단 전 쌍 $undecided개',
                    style: const TextStyle(color: kThinkSub, fontSize: 13, fontWeight: FontWeight.w700)),
              ),
              ThinkToggleChip(
                key: const ValueKey('same-name-only-undecided'),
                label: '판단 전만',
                icon: Icons.filter_alt_outlined,
                selected: _onlyUndecided,
                onChanged: (v) => setState(() => _onlyUndecided = v),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: shown.isEmpty ? const Center(child: ConceptHint('판단 전인 쌍이 없습니다.')) : ListView(children: shown),
          ),
        ],
      );
    }
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: const Row(
        children: [
          Icon(Icons.join_inner, size: 20, color: kThinkAccent),
          SizedBox(width: 8),
          Expanded(
            child: Text('같은 이름 검토', style: TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
      content: SizedBox(
        width: 720,
        height: math.max(320, math.min(680, size.height - 200)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ConceptHint('이름이 같다는 것만으로 같은 개념이라고 정하지 않습니다. 한 쌍씩 고르면 판단만 기록하고, 개념을 합치거나 옮기지 않습니다.'),
            const SizedBox(height: 8),
            Expanded(child: body),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('닫기', style: TextStyle(color: kThinkSub)),
        ),
      ],
    );
  }
}
