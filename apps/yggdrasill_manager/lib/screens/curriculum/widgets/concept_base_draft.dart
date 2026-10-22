import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/concept_library_controller.dart';
import '../../../services/concept_service.dart';
import '../../../services/concept_statement_service.dart';
import '../../../services/concept_statement_store.dart';
import '../../../widgets/latex_text_renderer.dart';
import '../../think/think_style.dart';
import 'concept_library_pane.dart';
import 'concept_workspace.dart';

Widget _math(String text, {Color color = kThinkSub}) => LatexTextRenderer(
      text,
      dollarMath: true,
      style: TextStyle(color: color, fontSize: 14, height: 1.6),
      crossAxisAlignment: CrossAxisAlignment.start,
      blockVerticalPadding: 6,
    );

/// 개념 상세의 기본 서술 아래에 보이는 저장된 수정안. 확정 전이라 기본 서술과 섞어 보이지 않는다.
class ConceptBaseDraftBox extends StatelessWidget {
  const ConceptBaseDraftBox({super.key, required this.store, required this.concept});

  final ConceptStatementStore store;
  final ConceptItem concept;

  @override
  Widget build(BuildContext context) {
    final err = store.contentDraftErrorOf(concept.id);
    if (err != null) return ConceptHint(err);
    final d = store.contentDraftOf(concept.id);
    if (d == null) return const SizedBox.shrink();
    final moved = !d.basedOn(concept.content);
    return Container(
      key: const ValueKey('base-draft-box'),
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kThinkPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkAccent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('기본 서술 수정안', style: TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w800)),
              const ThinkBadge('확정 전', color: kThinkHint),
              ThinkBadge(d.originLabel, color: kThinkSub),
              Text(formatDateTime(d.savedAt), style: const TextStyle(color: kThinkHint, fontSize: 12)),
            ],
          ),
          if (moved) ...[
            const SizedBox(height: 8),
            const ThinkNotice(
              key: ValueKey('base-draft-moved'),
              text: '수정안을 쓴 뒤 기본 서술이 바뀌었습니다. 열어서 지금 본문과 비교한 뒤 다시 저장해야 확정할 수 있습니다.',
              color: kThinkAccent,
              icon: Icons.sync_problem,
            ),
          ],
          if ((d.note ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('고치려는 이유: ${d.note!.trim()}', style: const TextStyle(color: kThinkLink, fontSize: 12)),
          ],
          const SizedBox(height: 6),
          SelectionArea(child: _math(d.content)),
        ],
      ),
    );
  }
}

/// 기본 서술 수정안 쓰기·고치기·확정. 왼쪽은 지금 기본 서술(확정본), 오른쪽은 수정안이다.
/// 확정은 저장된 수정안만, 이유를 적어야 한다. [onBaseChanged]는 본문이 바뀌었을 때(확정·다른 곳에서 고침) 개념을 다시 읽는다.
Future<void> showConceptBaseDraftDialog(
  BuildContext context, {
  required ConceptLibraryController controller,
  required ConceptItem concept,
  String? impact,
  Future<void> Function(String conceptId)? onBaseChanged,
}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _BaseDraftDialog(controller: controller, concept: concept, impact: impact, onBaseChanged: onBaseChanged),
    );

class _BaseDraftDialog extends StatefulWidget {
  const _BaseDraftDialog({required this.controller, required this.concept, this.impact, this.onBaseChanged});

  final ConceptLibraryController controller;
  final ConceptItem concept;
  final String? impact;
  final Future<void> Function(String conceptId)? onBaseChanged;

  @override
  State<_BaseDraftDialog> createState() => _BaseDraftDialogState();
}

class _BaseDraftDialogState extends State<_BaseDraftDialog> {
  final _content = TextEditingController();
  final _note = TextEditingController();

  /// 저장된 값(수정안이 없으면 지금 본문과 빈 이유). 입력이 이것과 다르면 저장하지 않은 입력이다.
  String _savedContent = '';
  String _savedNote = '';
  String? _error;
  String? _notice;

  /// 그사이 다른 곳에서 수정안이 바뀌었다. 입력은 그대로 둔다.
  bool _draftMoved = false;

  ConceptLibraryController get _c => widget.controller;
  ConceptStatementStore get _store => _c.statements;
  String get _id => widget.concept.id;

  /// 화면에 보이는 지금 본문. 다시 읽은 값이 있으면 그것.
  ConceptItem get _concept {
    final s = _c.selectedConcept;
    return s != null && s.id == _id ? s : widget.concept;
  }

  ConceptContentDraft? get _draft => _store.contentDraftOf(_id);

  @override
  void initState() {
    super.initState();
    _fillFromSaved();
    _content.addListener(_changed);
    _note.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _content.dispose();
    _note.dispose();
    super.dispose();
  }

  void _fillFromSaved() {
    final d = _draft;
    _savedContent = d?.content ?? _concept.content;
    _savedNote = d?.note ?? '';
    _content.text = _savedContent;
    _note.text = _savedNote;
  }

  bool get _dirty => _content.text != _savedContent || _note.text.trim() != _savedNote.trim();
  bool get _moved => _draft != null && !_draft!.basedOn(_concept.content);

  Future<void> _save() async {
    final (row, err) = await _store.saveContentDraft(
      _id,
      content: _content.text,
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      base: _concept.content,
    );
    if (!mounted) return;
    if (err != null) {
      final code = _store.lastErrorCode;
      if (code == 'concept_content_stale') await widget.onBaseChanged?.call(_id);
      if (!mounted) return;
      setState(() {
        _notice = null;
        _error = err;
        _draftMoved = code == 'concept_content_draft_stale';
      });
      return;
    }
    setState(() {
      _error = null;
      _draftMoved = false;
      _savedContent = row?.content ?? _concept.content;
      _savedNote = row?.note ?? '';
      _content.text = _savedContent;
      _note.text = _savedNote;
      _notice = row == null ? '지금 기본 서술과 같아 수정안을 지웠습니다.' : '수정안을 저장했습니다. 확정해야 기본 서술이 바뀝니다.';
    });
  }

  Future<void> _confirm() async {
    final d = _draft;
    if (d == null) return;
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _ReasonDialog(initial: d.note ?? ''),
    );
    if (note == null || !mounted) return;
    final (content, err) = await _store.confirmContentDraft(d, note: note);
    if (!mounted) return;
    if (content == null) {
      setState(() {
        _notice = null;
        _error = err;
      });
      return;
    }
    _c.syncSelectedConcept([_concept.copyWith(content: content)]);
    unawaited(widget.onBaseChanged?.call(_id));
    showThinkSnack(context, '확정했습니다. 고치기 전 본문과 이유는 고친 기록에 남았습니다.');
    Navigator.pop(context);
  }

  Future<void> _discard() async {
    final d = _draft;
    if (d == null) return;
    final ok = await confirmThink(
      context,
      title: '수정안 버리기',
      message: '저장된 수정안을 버립니다. 기본 서술은 그대로이고, 입력 중인 내용도 사라집니다.',
      confirmLabel: '버리기',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final err = await _store.discardContentDraft(d);
    if (!mounted) return;
    setState(() {
      if (err != null) {
        _error = err;
        return;
      }
      _fillFromSaved();
      _error = null;
      _draftMoved = false;
      _notice = '수정안을 버렸습니다.';
    });
  }

  void _reloadLatest() => setState(() {
        _fillFromSaved();
        _draftMoved = false;
        _error = null;
      });

  Future<void> _close() async {
    if (_dirty) {
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

  Widget _pane(String title, Widget child, {Color border = kThinkBorder}) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConceptSectionTitle(title),
          Container(
            constraints: const BoxConstraints(minHeight: 260, maxHeight: 360),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: kThinkPanel,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: border),
            ),
            child: child,
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_store, _c]),
      builder: (context, _) {
        final busy = _store.busy;
        final d = _draft;
        final dirty = _dirty;
        final moved = _moved;
        final canSave = !busy && (dirty || moved) && _content.text.trim().isNotEmpty;
        final canConfirm = !busy && d != null && !dirty && !moved;
        return AlertDialog(
          backgroundColor: kThinkBg,
          shape: thinkDialogShape,
          title: Row(
            children: [
              const Icon(Icons.edit_note, size: 20, color: kThinkAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text('기본 서술 수정안 · ${conceptDisplayName(_concept)}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              ThinkBadge(d == null ? '수정안 없음' : '수정안 · 확정 전', color: kThinkHint),
            ],
          ),
          content: SizedBox(
            width: 920,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const ConceptHint('저장하면 수정안으로 남고 기본 서술은 그대로입니다. 확정할 때 고치는 이유를 적고, '
                      '고치기 전 본문은 고친 기록에 남습니다. 다른 서술·출처·등장 위치·관계는 바뀌지 않습니다.'),
                  const SizedBox(height: 12),
                  if (widget.impact != null) ...[
                    ThinkNotice(
                      key: const ValueKey('base-draft-impact'),
                      text: widget.impact!,
                      color: kThinkLink,
                      icon: Icons.account_tree_outlined,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (moved) ...[
                    const ThinkNotice(
                      text: '수정안을 쓴 뒤 기본 서술이 바뀌었습니다. 왼쪽 지금 본문과 비교한 뒤 다시 저장하면 확정할 수 있습니다.',
                      color: kThinkAccent,
                      icon: Icons.sync_problem,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_draftMoved) ...[
                    const ThinkNotice(
                      text: '그사이 다른 곳에서 수정안이 바뀌었습니다. 지금 입력은 그대로 두었고, 다시 저장하면 이 입력이 수정안이 됩니다.',
                      color: kThinkAccent,
                      icon: Icons.sync_problem,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: busy ? null : _reloadLatest,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('최신 수정안 불러오기(내 입력 버림)'),
                        style: TextButton.styleFrom(foregroundColor: kThinkAccent),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_error != null && !_draftMoved) ...[
                    ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline),
                    const SizedBox(height: 12),
                  ],
                  if (_notice != null && _error == null) ...[
                    ThinkNotice(text: _notice!, color: kThinkSuccess, icon: Icons.check_circle_outline),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _pane(
                          '지금 기본 서술(확정본)',
                          SingleChildScrollView(
                            key: const ValueKey('base-draft-current'),
                            child: SelectionArea(child: _math(_concept.content)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _pane(
                          r'수정안($…$ 수식)',
                          TextField(
                            key: const ValueKey('base-draft-field'),
                            controller: _content,
                            minLines: 10,
                            maxLines: 14,
                            style: const TextStyle(color: kThinkText, fontSize: 14, height: 1.5),
                            decoration: const InputDecoration.collapsed(hintText: '고친 기본 서술'),
                          ),
                          border: kThinkAccent.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('base-draft-note'),
                    controller: _note,
                    minLines: 1,
                    maxLines: 3,
                    style: const TextStyle(color: kThinkText, fontSize: 14),
                    decoration: thinkInputDecoration(
                      label: '고치려는 이유(선택, 확정할 때 꼭 적습니다)',
                      hint: '예: 다른 교재에 적힌 조건을 보완함',
                      dense: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : _close,
              child: const Text('닫기', style: TextStyle(color: kThinkSub)),
            ),
            if (d != null)
              TextButton(
                key: const ValueKey('base-draft-discard'),
                onPressed: busy ? null : _discard,
                child: const Text('수정안 버리기', style: TextStyle(color: kThinkError)),
              ),
            OutlinedButton(
              key: const ValueKey('base-draft-save'),
              onPressed: canSave ? _save : null,
              style: thinkOutlineButton(),
              child: const Text('수정안 저장'),
            ),
            Tooltip(
              message: dirty
                  ? '먼저 수정안을 저장하세요.'
                  : moved
                      ? '지금 본문과 비교해 다시 저장하세요.'
                      : (d == null ? '확정할 수정안이 없습니다.' : ''),
              child: ElevatedButton(
                key: const ValueKey('base-draft-confirm'),
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

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({required this.initial});

  final String initial;

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  late final TextEditingController _note = TextEditingController(text: widget.initial)..addListener(_changed);

  void _changed() => setState(() {});

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ok = _note.text.trim().isNotEmpty;
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: const Text('수정안 확정', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '저장된 수정안을 기본 서술로 올립니다. 고치기 전 본문과 이유는 고친 기록에 남고, '
              '다른 서술·출처·등장 위치·관계는 바뀌지 않습니다.',
              style: TextStyle(color: kThinkSub, height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('base-draft-reason'),
              controller: _note,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              style: const TextStyle(color: kThinkText),
              decoration: thinkInputDecoration(label: '고친 이유(필수)', hint: '왜 이렇게 고쳤는지 적어 두면 고친 기록에 남습니다.'),
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
          key: const ValueKey('base-draft-reason-ok'),
          onPressed: ok ? () => Navigator.pop(context, _note.text.trim()) : null,
          style: thinkPrimaryButton(color: kThinkSuccess),
          child: const Text('확정'),
        ),
      ],
    );
  }
}
