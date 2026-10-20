import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../services/concept_service.dart';
import '../../../services/concept_statement_service.dart';
import '../../../services/concept_statement_store.dart';
import '../../../widgets/latex_text_renderer.dart';
import '../../think/think_style.dart';
import 'concept_library_pane.dart';
import 'concept_statement_section.dart';
import 'concept_workspace.dart';

/// 서술 더하기(statement 없음)·고치기. 저장하면 초안, 확정은 따로 누른다.
/// [impact]: 고칠 때 보여 줄 "이것에 붙은 것" 안내.
Future<void> showConceptStatementDialog(
  BuildContext context, {
  required ConceptStatementStore store,
  required ConceptItem concept,
  ConceptStatement? statement,
  String? impact,
}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _StatementDialog(
        store: store,
        concept: concept,
        role: ConceptStatementRole.statement,
        statement: statement,
        impact: impact,
      ),
    );

/// 개념 공통 내용 쓰기·고치기.
Future<void> showConceptCoreDialog(
  BuildContext context, {
  required ConceptStatementStore store,
  required ConceptItem concept,
  ConceptStatement? core,
  String? impact,
}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _StatementDialog(
          store: store, concept: concept, role: ConceptStatementRole.core, statement: core, impact: impact),
    );

class _StatementDialog extends StatefulWidget {
  const _StatementDialog({required this.store, required this.concept, required this.role, this.statement, this.impact});

  final ConceptStatementStore store;
  final ConceptItem concept;
  final ConceptStatementRole role;
  final ConceptStatement? statement;
  final String? impact;

  @override
  State<_StatementDialog> createState() => _StatementDialogState();
}

class _StatementDialogState extends State<_StatementDialog> {
  final _title = TextEditingController();
  final _approach = TextEditingController();
  final _body = TextEditingController();
  final _conditions = TextEditingController();
  final _terms = TextEditingController();
  final _quote = TextEditingController();
  final _supplement = TextEditingController();
  final _unverified = TextEditingController();
  final _meaning = TextEditingController();
  final _scope = TextEditingController();

  ConceptConditionsInSource? _cis;
  ConceptStatementBasis _basis = ConceptStatementBasis.organized;

  /// null이면 아직 서버에 없는 새 서술.
  String? _id;
  ConceptStatementText _base = const ConceptStatementText();
  String? _error;
  String? _notice;
  bool _stale = false;

  bool get _core => widget.role == ConceptStatementRole.core;
  ConceptStatementStore get _store => widget.store;
  ConceptStatement? get _current => _store.byId(widget.concept.id, _id);

  List<TextEditingController> get _all =>
      [_title, _approach, _body, _conditions, _terms, _quote, _supplement, _unverified, _meaning, _scope];

  @override
  void initState() {
    super.initState();
    _id = widget.statement?.id;
    _base = widget.statement?.saved ?? const ConceptStatementText();
    _fill(_base);
    for (final c in _all) {
      c.addListener(_changed);
    }
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(ConceptStatementText t) {
    _title.text = t.title;
    _approach.text = t.approach ?? '';
    _body.text = t.body;
    _conditions.text = t.conditions ?? '';
    _terms.text = t.terms.join(', ');
    _quote.text = t.quote ?? '';
    _supplement.text = t.supplementNote ?? '';
    _unverified.text = t.unverifiedNote ?? '';
    _meaning.text = t.meaning;
    _scope.text = t.scope ?? '';
    _cis = t.conditionsInSource;
    _basis = t.basis;
  }

  ConceptStatementText get _text => ConceptStatementText(
        title: _title.text,
        approach: _approach.text,
        body: _body.text,
        conditions: _conditions.text,
        conditionsInSource: _cis,
        terms: [for (final t in _terms.text.split(',')) t.trim()],
        basis: _basis,
        quote: _quote.text,
        supplementNote: _supplement.text,
        unverifiedNote: _unverified.text,
        meaning: _meaning.text,
        scope: _scope.text,
      );

  String _key(ConceptStatementText t) => jsonEncode(t.toJson(widget.role));
  bool get _dirty => _id == null || _key(_text) != _key(_base);
  bool get _empty => _all.every((c) => c.text.trim().isEmpty);

  Future<void> _save() async {
    final text = _text;
    final current = _current;
    final (row, err) = current == null
        ? await _store.create(widget.concept.id, widget.role, text)
        : await _store.saveDraft(current, text);
    if (!mounted) return;
    setState(() {
      if (row != null) {
        _id = row.id;
        _base = row.saved;
        _error = null;
        _stale = false;
        _notice = row.hasDraft ? '초안을 저장했습니다. 확정해야 이 서술의 확정본이 바뀝니다.' : '확정본과 같아 초안을 지웠습니다.';
        return;
      }
      _notice = null;
      _error = err;
      final latest = _current;
      if (current == null) return;
      if (latest == null) {
        _id = null;
      } else if (latest.version != current.version || latest.draftSavedAtRaw != current.draftSavedAtRaw) {
        _stale = true;
        _base = latest.saved;
      }
    });
  }

  Future<void> _confirm() async {
    final current = _current;
    if (current == null) return;
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _ConfirmNoteDialog(
        next: current.version + 1,
        title: _core ? '개념 공통 내용' : conceptStatementTitle(current),
      ),
    );
    if (note == null || !mounted) return;
    final (row, err) = await _store.confirm(current, note: note.trim().isEmpty ? null : note.trim());
    if (!mounted) return;
    if (row == null) {
      setState(() => _error = err);
      return;
    }
    showThinkSnack(context, '확정했습니다. 이제 v${row.version}이 이 ${_core ? '공통 내용' : '서술'}의 확정본입니다.');
    Navigator.pop(context);
  }

  Future<void> _discard() async {
    final current = _current;
    if (current == null) return;
    final what = _core ? '공통 내용' : '서술';
    final ok = await confirmThink(
      context,
      title: current.confirmed ? '초안 버리기' : '$what 지우기',
      message: current.confirmed
          ? '저장된 초안을 버리고 확정본 v${current.version}으로 돌아갑니다. 입력 중인 내용도 사라집니다.'
          : '이 $what은(는) 확정한 적이 없어, 초안을 버리면 $what이(가) 지워집니다. 출처·등장 위치가 붙어 있으면 지우지 않습니다.',
      confirmLabel: current.confirmed ? '초안 버리기' : '지우기',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final (row, err) = await _store.discardDraft(current);
    if (!mounted) return;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    if (row == null) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _base = row.saved;
      _fill(_base);
      _error = null;
      _notice = '초안을 버렸습니다.';
    });
  }

  Future<void> _close() async {
    if (_dirty && !(_id == null && _empty)) {
      final ok = await confirmThink(
        context,
        title: '저장하지 않은 입력',
        message: '저장하지 않은 입력이 있습니다. 닫으면 사라집니다.',
        confirmLabel: '버리고 닫기',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    Navigator.pop(context);
  }

  void _reloadLatest() {
    final latest = _current;
    setState(() {
      _base = latest?.saved ?? const ConceptStatementText();
      _fill(_base);
      _stale = false;
      _error = null;
    });
  }

  Widget _field(String label, TextEditingController c, {int lines = 1, String? hint, Key? key}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          key: key,
          controller: c,
          minLines: lines,
          maxLines: lines == 1 ? 1 : lines + 4,
          style: const TextStyle(color: kThinkText, fontSize: 14),
          decoration: thinkInputDecoration(label: label, hint: hint, dense: true),
        ),
      );

  List<Widget> _statementFields() => [
        _field('제목', _title, key: const ValueKey('statement-field-title')),
        _field('서술 방식(예: 경우의 수, 집합과 기호, 직관적 설명)', _approach),
        _field(r'본문 ($…$ 수식)', _body, lines: 4, key: const ValueKey('statement-field-body')),
        _field('이 서술의 적용 대상·조건', _conditions, lines: 2),
        const ConceptSectionTitle('원문에 조건이 적혀 있나요'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final v in [...ConceptConditionsInSource.values, null])
              ThinkToggleChip(
                label: v?.label ?? '모름',
                icon: Icons.rule,
                selected: _cis == v,
                onChanged: (_) => setState(() => _cis = v),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _field('필요한 용어(쉼표로 나눔)', _terms),
        const ConceptSectionTitle('글의 바탕'),
        Wrap(
          spacing: 6,
          children: [
            for (final b in ConceptStatementBasis.values)
              ThinkToggleChip(
                label: b.label,
                icon: b == ConceptStatementBasis.verbatim ? Icons.format_quote : Icons.edit_note,
                selected: _basis == b,
                onChanged: (_) => setState(() => _basis = b),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _field('원문(책에 적힌 문장 또는 원문 참조)', _quote, lines: 2),
        _field('보완·수정한 부분과 이유', _supplement, lines: 2),
        _field('확인되지 않은 사항', _unverified, lines: 2),
        const ConceptHint('우리가 보완한 문장은 원문 칸에 쓰지 않습니다. 책 이름·쪽은 출처에서 잇고 여기서 추정해 쓰지 않습니다.'),
      ];

  List<Widget> _coreFields() => [
        _field('공통 의미', _meaning, lines: 2, key: const ValueKey('core-field-meaning')),
        _field('적용 범위', _scope, lines: 2),
        _field('공통 조건', _conditions, lines: 2),
        const ConceptHint('공통 조건은 그 조건을 정말 함께 쓰는 서술 범위에서만 둡니다. 상위 개념 전체의 조건으로 올리지 않습니다.'),
      ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final current = _current;
        final busy = _store.busy;
        final dirty = _dirty;
        final canConfirm = current != null && current.hasDraft && !dirty && !busy;
        final heading = _core
            ? (current == null ? '개념 공통 내용 쓰기' : '개념 공통 내용 고치기')
            : (current == null ? '서술 더하기' : '서술 고치기 · ${conceptStatementTitle(current)}');
        return AlertDialog(
          backgroundColor: kThinkBg,
          shape: thinkDialogShape,
          title: Row(
            children: [
              Icon(_core ? Icons.hub_outlined : Icons.short_text, size: 20, color: _core ? kThinkAccent : kThinkLink),
              const SizedBox(width: 8),
              Expanded(
                child: Text(heading,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              ThinkBadge(current?.statusLabel ?? '저장 전',
                  color: current?.confirmed ?? false ? kThinkSuccess : kThinkHint),
            ],
          ),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ConceptHint('${conceptDisplayName(widget.concept)} · '
                      '${_core ? '모든 서술에 해당하는 내용만 씁니다. ' : '개념 본문과 다른 서술은 바뀌지 않습니다. '}'
                      '저장하면 초안으로 남고 확정본은 그대로입니다. 확정은 저장한 뒤 따로 누릅니다.'),
                  const SizedBox(height: 12),
                  if (widget.impact != null) ...[
                    ThinkNotice(
                      key: const ValueKey('statement-impact'),
                      text: widget.impact!,
                      color: kThinkLink,
                      icon: Icons.account_tree_outlined,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_stale) ...[
                    ThinkNotice(
                      text: '그사이 다른 곳에서 바뀌었습니다. 지금 입력은 그대로 두었고, 다시 저장하면 이 입력이 초안이 됩니다.',
                      color: kThinkAccent,
                      icon: Icons.sync_problem,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: busy ? null : _reloadLatest,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('최신 저장본 불러오기(내 입력 버림)'),
                        style: TextButton.styleFrom(foregroundColor: kThinkAccent),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_error != null && !_stale) ...[
                    ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline),
                    const SizedBox(height: 12),
                  ],
                  if (_notice != null && _error == null) ...[
                    ThinkNotice(text: _notice!, color: kThinkSuccess, icon: Icons.check_circle_outline),
                    const SizedBox(height: 12),
                  ],
                  ...(_core ? _coreFields() : _statementFields()),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : _close,
              child: const Text('닫기', style: TextStyle(color: kThinkSub)),
            ),
            if (current != null && current.hasDraft)
              TextButton(
                onPressed: busy ? null : _discard,
                child: Text(current.confirmed ? '초안 버리기' : '지우기', style: const TextStyle(color: kThinkError)),
              ),
            OutlinedButton(
              key: const ValueKey('statement-save'),
              onPressed: busy || !dirty ? null : _save,
              style: thinkOutlineButton(),
              child: const Text('초안 저장'),
            ),
            Tooltip(
              message: dirty ? '먼저 초안을 저장하세요.' : (current?.hasDraft ?? false ? '' : '확정할 초안이 없습니다.'),
              child: ElevatedButton(
                key: const ValueKey('statement-confirm'),
                onPressed: canConfirm ? _confirm : null,
                style: thinkPrimaryButton(color: kThinkSuccess),
                child: const Text('확정'),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ConfirmNoteDialog extends StatefulWidget {
  const _ConfirmNoteDialog({required this.next, required this.title});

  final int next;
  final String title;

  @override
  State<_ConfirmNoteDialog> createState() => _ConfirmNoteDialogState();
}

class _ConfirmNoteDialogState extends State<_ConfirmNoteDialog> {
  final TextEditingController _note = TextEditingController();

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
      title: Text('초안 확정 — v${widget.next}', style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '"${widget.title}"의 저장된 초안을 v${widget.next} 확정본으로 올립니다. '
              '이전 확정본은 확정 기록에 남고, 다른 서술과 개념 본문은 바뀌지 않습니다.',
              style: const TextStyle(color: kThinkSub, height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('statement-confirm-note'),
              controller: _note,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              style: const TextStyle(color: kThinkText),
              decoration: thinkInputDecoration(label: '확정 메모 (선택)', hint: '왜 이렇게 정했는지 적어 두면 확정 기록에 남습니다.'),
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
          key: const ValueKey('statement-confirm-ok'),
          onPressed: () => Navigator.pop(context, _note.text),
          style: thinkPrimaryButton(color: kThinkSuccess),
          child: const Text('확정'),
        ),
      ],
    );
  }
}

/// 등장 위치 더하기. statement가 없으면 기본 서술(개념 본문)의 등장 위치다.
Future<void> showConceptAppearanceDialog(
  BuildContext context, {
  required ConceptStatementStore store,
  required ConceptItem concept,
  ConceptStatement? statement,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _AppearanceDialog(store: store, concept: concept, statement: statement),
    );

class _AppearanceDialog extends StatefulWidget {
  const _AppearanceDialog({required this.store, required this.concept, this.statement});

  final ConceptStatementStore store;
  final ConceptItem concept;
  final ConceptStatement? statement;

  @override
  State<_AppearanceDialog> createState() => _AppearanceDialogState();
}

class _AppearanceDialogState extends State<_AppearanceDialog> {
  final _course = TextEditingController();
  final _unit = TextEditingController();
  final _note = TextEditingController();
  String? _curriculum;
  String? _level;
  String? _error;

  @override
  void dispose() {
    _course.dispose();
    _unit.dispose();
    _note.dispose();
    super.dispose();
  }

  List<String> get _unitPath => [
        for (final u in _unit.text.split('>'))
          if (u.trim().isNotEmpty) u.trim()
      ];

  String? _check() {
    if (_level == null) return '학교급(초·중·고)을 고르세요.';
    final course = _course.text.trim();
    if (course.isEmpty) return '학년·과목을 입력하세요.';
    if (course.length > 40) return '학년·과목은 40자까지입니다.';
    if (_unitPath.length > 3) return '단원은 3단계까지입니다.';
    if (_note.text.trim().length > 500) return '메모는 500자까지입니다.';
    return null;
  }

  Future<void> _add() async {
    final problem = _check();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final err = await widget.store.addAppearance(
      conceptId: widget.concept.id,
      statementId: widget.statement?.id,
      curriculumCode: _curriculum,
      schoolLevel: _level!,
      courseLabel: _course.text.trim(),
      unitPath: _unitPath,
      note: _note.text,
    );
    if (!mounted) return;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.statement == null ? '기본(개념 본문)' : conceptStatementTitle(widget.statement!);
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) => AlertDialog(
        backgroundColor: kThinkBg,
        shape: thinkDialogShape,
        title: Text('등장 위치 더하기 · $target',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null) ...[
                  ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline),
                  const SizedBox(height: 12),
                ],
                InputDecorator(
                  decoration: thinkInputDecoration(label: '교육과정 판', dense: true),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      key: const ValueKey('appearance-curriculum'),
                      value: _curriculum,
                      isExpanded: true,
                      isDense: true,
                      dropdownColor: kThinkPanel,
                      style: const TextStyle(color: kThinkText, fontSize: 14),
                      items: [
                        const DropdownMenuItem<String?>(value: null, child: Text('모름(미기록)')),
                        for (final e in kConceptCurriculumLabels.entries)
                          DropdownMenuItem<String?>(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: (v) => setState(() => _curriculum = v),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final l in const ['초', '중', '고'])
                      ThinkToggleChip(
                        key: ValueKey('appearance-level-$l'),
                        label: l,
                        icon: Icons.school_outlined,
                        selected: _level == l,
                        onChanged: (_) => setState(() => _level = l),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('appearance-course'),
                  controller: _course,
                  style: const TextStyle(color: kThinkText, fontSize: 14),
                  decoration: thinkInputDecoration(label: '학년·과목(예: 2-2, 확률과 통계)', dense: true),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _unit,
                  style: const TextStyle(color: kThinkText, fontSize: 14),
                  decoration: thinkInputDecoration(label: '단원(> 로 나눔, 3단계까지)', dense: true),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _note,
                  maxLines: 3,
                  minLines: 1,
                  style: const TextStyle(color: kThinkText, fontSize: 14),
                  decoration: thinkInputDecoration(label: '메모(선택)', dense: true),
                ),
                const SizedBox(height: 10),
                const ConceptHint('교육과정 판은 확인한 것만 고릅니다. 교재 이름·과목으로 추정하지 않습니다. '
                    '새 판을 더해도 이전 등장 위치는 남습니다.'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('닫기', style: TextStyle(color: kThinkSub)),
          ),
          ElevatedButton(
            key: const ValueKey('appearance-save'),
            onPressed: widget.store.busy ? null : _add,
            style: thinkPrimaryButton(),
            child: const Text('더하기'),
          ),
        ],
      ),
    );
  }
}

Widget _historyFrame(BuildContext context, String title, Widget body) => AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text(title,
          overflow: TextOverflow.ellipsis, style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(width: 600, height: 440, child: body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('닫기', style: TextStyle(color: kThinkSub)),
        ),
      ],
    );

Widget _futureList<T>(Future<List<T>> future, String empty, Widget Function(T item) row) => FutureBuilder<List<T>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(color: kThinkAccent));
        }
        if (snap.hasError) {
          return ThinkNotice(
            text: '기록을 읽지 못했습니다: ${ConceptStatementException.from(snap.error!).message}',
            color: kThinkError,
            icon: Icons.error_outline,
          );
        }
        final list = snap.data ?? <T>[];
        if (list.isEmpty) return ConceptHint(empty);
        return ListView.separated(
          itemCount: list.length,
          separatorBuilder: (_, __) => const Divider(color: kThinkBorder, height: 20),
          itemBuilder: (context, i) => SelectionArea(child: row(list[i])),
        );
      },
    );

Widget _math(String text) => LatexTextRenderer(
      text,
      dollarMath: true,
      style: const TextStyle(color: kThinkSub, fontSize: 13, height: 1.5),
      crossAxisAlignment: CrossAxisAlignment.start,
      blockVerticalPadding: 4,
    );

Future<void> showConceptStatementRevisions(
  BuildContext context, {
  required ConceptStatementStore store,
  required ConceptStatement statement,
}) {
  final core = statement.role == ConceptStatementRole.core;
  final future = store.revisions(statement.id);
  return showDialog<void>(
    context: context,
    builder: (ctx) => _historyFrame(
      ctx,
      '확정 기록 — ${core ? '개념 공통 내용' : conceptStatementTitle(statement)}',
      _futureList<ConceptStatementRevision>(
        future,
        '확정 기록이 없습니다.',
        (r) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('v${r.version} · ${formatDateTime(r.confirmedAt)}',
                style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
            if ((r.note ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('메모: ${r.note!.trim()}', style: const TextStyle(color: kThinkLink, fontSize: 12)),
            ],
            const SizedBox(height: 6),
            if (core) ...[
              _math(r.content.meaning),
              if (r.content.scope != null) Text('적용 범위: ${r.content.scope}', style: const TextStyle(color: kThinkSub)),
              if (r.content.conditions != null)
                Text('공통 조건: ${r.content.conditions}', style: const TextStyle(color: kThinkSub)),
            ] else ...[
              Text(r.content.title, style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              _math(r.content.body),
            ],
          ],
        ),
      ),
    ),
  );
}

/// 개념 본문(기본 서술)을 고치기 전 값. 기록은 2026-10-20 반영 뒤부터 쌓인다.
Future<void> showConceptContentHistory(
  BuildContext context, {
  required ConceptStatementStore store,
  required ConceptItem concept,
}) {
  final future = store.contentRevisions(concept.id);
  return showDialog<void>(
    context: context,
    builder: (ctx) => _historyFrame(
      ctx,
      '고친 기록 — ${conceptDisplayName(concept)}',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ConceptHint('개념 이름·본문을 고칠 때마다 고치기 전 값을 남깁니다. 2026-10-20 전에 고친 내용은 남아 있지 않습니다.'),
          const SizedBox(height: 12),
          Expanded(
            child: _futureList<ConceptContentRevision>(
              future,
              '고친 기록이 없습니다.',
              (r) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${formatDateTime(r.changedAt)}에 고치기 전',
                      style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(r.name, style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  _math(r.content),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
