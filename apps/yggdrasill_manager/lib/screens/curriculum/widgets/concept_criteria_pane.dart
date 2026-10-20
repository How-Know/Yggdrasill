import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/concept_library_controller.dart';
import '../../../services/concept_library_service.dart';
import '../../../services/concept_service.dart';
import '../../think/think_style.dart';
import 'concept_workspace.dart';

/// 기준 상태 표시. 확정본과 저장된 초안, 저장 안 한 입력을 따로 보인다.
List<Widget> criterionBadges(ConceptCriterion? c, {required bool dirty, required bool local}) => [
      if (local) const ThinkBadge('새 항목', color: kThinkLink),
      if (c != null && c.confirmed) ThinkBadge('확정 v${c.version}', color: kThinkSuccess),
      if (c != null && c.hasDraft) ThinkBadge(c.confirmed ? '초안 있음' : '확정 전 초안', color: kThinkAccent),
      if (c != null && c.templateDraft) const ThinkBadge('기본 틀'),
      if (dirty) const ThinkBadge('저장 안 됨', color: kThinkError),
    ];

String criterionStatusLine(ConceptCriterion c) {
  final parts = <String>[
    c.confirmed ? '확정본 v${c.version} · ${formatDateTime(c.confirmedAt)} 확정' : '아직 확정한 적 없음',
    if (c.hasDraft) '${c.templateDraft ? '기본 틀 초안' : '저장된 초안'} · ${formatDateTime(c.draftSavedAt)} 저장',
  ];
  return parts.join('  ·  ');
}

String criterionDisplayTitle(ConceptCriterion c) {
  final t = (c.confirmed ? c.title : c.draftTitle) ?? c.savedTitle;
  return t.trim().isEmpty ? '(제목 없음)' : t.trim();
}

/// 기준 쪽 상세: 목록 + 편집. 확대·축소와 상관없이 입력은 컨트롤러에 남는다.
class CriteriaDetailPane extends StatefulWidget {
  const CriteriaDetailPane({
    super.key,
    required this.controller,
    required this.onOpenConcept,
    this.onChatPicked,
  });

  final ConceptLibraryController controller;

  /// 이은 개념을 눌렀을 때(라이브러리 쪽에서 연다).
  final void Function(String conceptId) onOpenConcept;

  /// 대화 참고로 골랐을 때(대화 패널을 연다).
  final VoidCallback? onChatPicked;

  @override
  State<CriteriaDetailPane> createState() => _CriteriaDetailPaneState();
}

class _CriteriaDetailPaneState extends State<CriteriaDetailPane> {
  final ScrollController _listScroll = ScrollController();

  /// 요약으로 접혀 있어도 이 칸은 좁은 폭으로 다시 배치된다. 목록·편집 칸이 옮겨 가도 상태가 남게 붙잡아 둔다.
  final GlobalKey _listKey = GlobalKey(debugLabel: 'criteriaList');
  final Map<String, GlobalKey> _editorKeys = {};

  ConceptLibraryController get _c => widget.controller;

  @override
  void dispose() {
    _listScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => ThinkPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            const Divider(color: kThinkBorder, height: 1),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final edits = [
      for (final id in _c.itemIds)
        if (_c.peekEdit(id) != null) _c.peekEdit(id)!.listenable,
    ];
    return ConceptPaneHeader(
      icon: Icons.rule_folder_outlined,
      title: '정리 기준',
      badges: [
        if (_c.loaded) ThinkBadge('${_c.criteria.length}개'),
        ListenableBuilder(
          listenable: Listenable.merge(edits),
          builder: (context, _) {
            final n = _c.itemIds.where(_c.isDirty).length;
            return n == 0 ? const SizedBox.shrink() : ThinkBadge('저장 안 됨 $n', color: kThinkError);
          },
        ),
      ],
      actions: [
        IconButton(
          tooltip: '다시 불러오기',
          onPressed: _c.loading ? null : () => unawaited(_c.loadCriteria()),
          icon: const Icon(Icons.refresh, size: 18),
          color: kThinkSub,
        ),
        TextButton.icon(
          onPressed: !_c.loaded || _c.notReady ? null : _c.addCriterion,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('새 기준'),
          style: TextButton.styleFrom(foregroundColor: kThinkAccent),
        ),
      ],
    );
  }

  Widget _body() {
    if (!_c.loaded) {
      if (_c.loading || _c.loadError == null) {
        return const Center(child: CircularProgressIndicator(color: kThinkAccent));
      }
      return _loadProblem();
    }
    final ids = _c.itemIds;
    if (ids.isEmpty) return _empty();
    final selected = _c.selectedCriterionId ?? ids.first;
    _editorKeys.removeWhere((id, _) => !ids.contains(id));
    final editorKey = _editorKeys.putIfAbsent(selected, () => GlobalKey(debugLabel: 'criterion-$selected'));
    return LayoutBuilder(
      builder: (context, constraints) {
        final editor = KeyedSubtree(
          key: editorKey,
          child: _CriterionEditor(
            key: ValueKey('criterion-editor-$selected'),
            controller: _c,
            id: selected,
            onOpenConcept: widget.onOpenConcept,
            onChatPicked: widget.onChatPicked,
          ),
        );
        final list = KeyedSubtree(key: _listKey, child: _list(ids, selected));
        if (constraints.maxWidth >= 620) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 248, child: list),
              const VerticalDivider(color: kThinkBorder, width: 1),
              Expanded(child: editor),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: 176, child: list),
            const Divider(color: kThinkBorder, height: 1),
            Expanded(child: editor),
          ],
        );
      },
    );
  }

  Widget _loadProblem() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ThinkNotice(
              text: _c.loadError ?? '정리 기준을 불러오지 못했습니다.',
              color: _c.notReady ? kThinkBlue : kThinkError,
              icon: _c.notReady ? Icons.info_outline : Icons.error_outline,
            ),
            if (_c.notReady) ...[
              const SizedBox(height: 8),
              const ConceptHint('DB 반영(마이그레이션)은 별도 승인 뒤에 합니다. 반영 전에는 기준을 저장할 수 없고, '
                  '개념 라이브러리와 Think 대화는 그대로 쓸 수 있습니다.'),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => unawaited(_c.loadCriteria()),
                style: thinkOutlineButton(),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('다시 불러오기'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.rule_folder_outlined, size: 40, color: kThinkAccent),
            const SizedBox(height: 16),
            const Text('아직 정리 기준이 없습니다',
                style: TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const Text(
              '개념을 어떤 기준으로 나누고 묶을지 항목별로 적어 둡니다.\n저장한 초안은 확정해야 현재 기준이 됩니다.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kThinkSub, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _c.templateBusy ? null : _createTemplates,
                  style: thinkPrimaryButton(),
                  icon: const Icon(Icons.post_add, size: 16),
                  label: const Text('기본 틀을 초안으로 넣기'),
                ),
                OutlinedButton.icon(
                  onPressed: _c.addCriterion,
                  style: thinkOutlineButton(),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('새 기준'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const ConceptHint('기본 틀(지식 분류 기준 등)은 초안으로만 들어갑니다. 고쳐서 확정해야 기준이 됩니다.'),
            if (_c.templateError != null) ...[
              const SizedBox(height: 12),
              ThinkNotice(text: _c.templateError!, color: kThinkError, icon: Icons.error_outline),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _createTemplates() async {
    final made = await _c.createTemplates();
    if (!mounted) return;
    if (made > 0) showThinkSnack(context, '기본 틀 $made개를 초안으로 넣었습니다. 아직 확정한 기준이 아닙니다.');
  }

  Widget _list(List<String> ids, String selected) {
    final missing = _c.missingTemplates;
    return ValueListenableBuilder<String?>(
      valueListenable: _c.chat.pickedCriterion,
      builder: (context, picked, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Scrollbar(
              controller: _listScroll,
              child: ListView.separated(
                controller: _listScroll,
                padding: const EdgeInsets.all(8),
                itemCount: ids.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (context, i) => _row(ids[i], ids[i] == selected, ids[i] == picked),
              ),
            ),
          ),
          if (missing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: TextButton.icon(
                onPressed: _c.templateBusy ? null : _createTemplates,
                icon: const Icon(Icons.post_add, size: 16),
                label: Text('기본 틀 ${missing.length}개를 초안으로 넣기'),
                style: TextButton.styleFrom(foregroundColor: kThinkSub),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(String id, bool selected, bool picked) {
    final edit = _c.peekEdit(id);
    Widget build() {
      final c = _c.criterionById(id);
      final local = _c.isLocal(id);
      final typed = edit?.title.text.trim() ?? '';
      final title = c == null ? (typed.isEmpty ? '새 기준' : typed) : criterionDisplayTitle(c);
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _c.selectCriterion(id),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? kThinkAccent.withValues(alpha: 0.16) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: selected ? kThinkAccent.withValues(alpha: 0.6) : kThinkBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700)),
                    ),
                    if (picked)
                      const Tooltip(
                        message: 'Think 대화 참고 중',
                        child: Icon(Icons.forum, size: 14, color: kThinkAccent),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: criterionBadges(c, dirty: _c.isDirty(id), local: local),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (edit == null) return build();
    return ListenableBuilder(listenable: edit.listenable, builder: (_, __) => build());
  }
}

class _CriterionEditor extends StatefulWidget {
  const _CriterionEditor({
    super.key,
    required this.controller,
    required this.id,
    required this.onOpenConcept,
    this.onChatPicked,
  });

  final ConceptLibraryController controller;
  final String id;
  final void Function(String conceptId) onOpenConcept;
  final VoidCallback? onChatPicked;

  @override
  State<_CriterionEditor> createState() => _CriterionEditorState();
}

class _CriterionEditorState extends State<_CriterionEditor> {
  final ScrollController _scroll = ScrollController();
  bool _showConfirmed = false;

  ConceptLibraryController get _c => widget.controller;
  String get _id => widget.id;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final edit = _c.editOf(_id);
    return ListenableBuilder(
      listenable: Listenable.merge([edit.listenable, _c.chat.pickedCriterion, _c.openedConceptId]),
      builder: (context, _) {
        final c = _c.criterionById(_id);
        final local = _c.isLocal(_id);
        final dirty = _c.isDirty(_id);
        final busy = _c.busyId == _id;
        final anyBusy = _c.busyId != null;
        final error = _c.errors[_id];
        return Scrollbar(
          controller: _scroll,
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.all(16),
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ...criterionBadges(c, dirty: dirty, local: local),
                  _chatPick(c, local),
                ],
              ),
              const SizedBox(height: 6),
              ConceptHint(
                c == null ? '아직 저장하지 않은 새 항목입니다. "초안 저장"을 누르면 초안으로 저장됩니다.' : criterionStatusLine(c),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: edit.title,
                enabled: !busy,
                maxLength: 200,
                style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700),
                decoration: thinkInputDecoration(label: '제목'),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: edit.body,
                enabled: !busy,
                minLines: 8,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(color: kThinkText, fontSize: 14, height: 1.6),
                decoration: thinkInputDecoration(
                  label: dirty ? '내용 (저장 안 됨)' : '내용',
                  hint: '이 기준을 개념 정리에 어떻게 적용할지 적습니다.',
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                ThinkNotice(text: error, color: kThinkError, icon: Icons.error_outline),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: dirty && !busy ? () => _c.cancelEdit(_id) : null,
                    style: thinkOutlineButton(),
                    child: Text(local ? '새 항목 빼기' : '편집 취소'),
                  ),
                  ElevatedButton.icon(
                    onPressed: dirty && !anyBusy ? _save : null,
                    style: thinkPrimaryButton(),
                    icon: busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.save_outlined, size: 16),
                    label: const Text('초안 저장'),
                  ),
                  ElevatedButton.icon(
                    onPressed: c != null && c.hasDraft && !dirty && !anyBusy ? () => _confirm(c) : null,
                    style: thinkPrimaryButton(color: kThinkSuccess),
                    icon: const Icon(Icons.verified_outlined, size: 16),
                    label: const Text('확정'),
                  ),
                  if (c != null && c.hasDraft)
                    TextButton(
                      onPressed: anyBusy ? null : () => _discard(c),
                      style: TextButton.styleFrom(foregroundColor: kThinkError),
                      child: Text(c.confirmed ? '초안 버리기' : '항목 지우기'),
                    ),
                ],
              ),
              if (c != null && c.hasDraft && dirty) ...[
                const SizedBox(height: 6),
                const ConceptHint('확정하려면 먼저 초안을 저장하세요. 저장한 내용만 확정됩니다.'),
              ],
              if (c != null && c.confirmed && (c.hasDraft || dirty)) ...[
                const SizedBox(height: 12),
                _confirmedView(c),
              ],
              const SizedBox(height: 16),
              const Divider(color: kThinkBorder, height: 1),
              const SizedBox(height: 12),
              _linkedConcepts(c),
              const SizedBox(height: 16),
              const ThinkNotice(
                text: '기준을 바꿔도 기존 개념이 자동으로 다시 정리되지 않습니다. '
                    '개념마다 이 기준으로 검토했는지는 아직 기록하지 않습니다.',
              ),
              if (c != null && c.confirmed) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => _showRevisions(c),
                    icon: const Icon(Icons.history, size: 16),
                    label: const Text('확정 기록 보기'),
                    style: TextButton.styleFrom(foregroundColor: kThinkSub),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _chatPick(ConceptCriterion? c, bool local) {
    if (c != null && _c.chat.criterionId == c.id) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ThinkBadge('Think 대화 참고 중', color: kThinkAccent),
          IconButton(
            tooltip: '대화 참고에서 빼기',
            onPressed: _c.chat.clearCriterion,
            icon: const Icon(Icons.close, size: 14),
            color: kThinkSub,
            visualDensity: VisualDensity.compact,
          ),
        ],
      );
    }
    return TextButton.icon(
      onPressed: c == null || local ? null : () => _pick(c),
      icon: const Icon(Icons.forum_outlined, size: 16),
      label: const Text('Think 대화 참고로 선택'),
      style: TextButton.styleFrom(foregroundColor: kThinkAccent, visualDensity: VisualDensity.compact),
    );
  }

  void _pick(ConceptCriterion c) {
    final problem = _c.chat.pickCriterion(c);
    if (problem != null) {
      showThinkSnack(context, problem, error: true);
      return;
    }
    widget.onChatPicked?.call();
    showThinkSnack(context, '"${criterionDisplayTitle(c)}"을(를) Think 대화의 참고 기준으로 골랐습니다. 보낼 때마다 서버가 저장본을 다시 읽습니다.');
  }

  Future<void> _save() async {
    final ok = await _c.saveDraft(_id);
    if (ok && mounted) showThinkSnack(context, '초안을 저장했습니다. 확정해야 현재 기준이 됩니다.');
  }

  Future<void> _confirm(ConceptCriterion c) async {
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => _ConfirmCriterionDialog(next: c.version + 1, title: criterionDisplayTitle(c)),
    );
    if (note == null) return;
    final ok = await _c.confirm(_id, note: note.trim().isEmpty ? null : note.trim());
    if (ok && mounted) showThinkSnack(context, '확정했습니다. 이제 v${c.version + 1}이 현재 기준입니다.');
  }

  Future<void> _discard(ConceptCriterion c) async {
    final dirty = _c.isDirty(_id);
    final more = dirty ? '\n저장하지 않은 편집도 함께 사라집니다.' : '';
    final ok = await confirmThink(
      context,
      title: c.confirmed ? '초안 버리기' : '항목 지우기',
      message:
          c.confirmed ? '저장된 초안을 버리고 확정본 v${c.version}으로 돌아갑니다.$more' : '이 항목은 아직 확정한 적이 없어, 초안을 버리면 항목이 지워집니다.$more',
      confirmLabel: c.confirmed ? '초안 버리기' : '지우기',
      destructive: true,
    );
    if (!ok) return;
    await _c.discardDraft(_id);
  }

  Widget _confirmedView(ConceptCriterion c) {
    return Container(
      decoration: BoxDecoration(
        color: kThinkQuote,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _showConfirmed = !_showConfirmed),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(_showConfirmed ? Icons.expand_less : Icons.expand_more, size: 18, color: kThinkSub),
                  const SizedBox(width: 6),
                  Text('지금 확정본 v${c.version} 보기',
                      style: const TextStyle(color: kThinkSub, fontSize: 13, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
          if (_showConfirmed)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.title ?? '', style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text(c.body ?? '', style: const TextStyle(color: kThinkSub, fontSize: 13, height: 1.6)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _linkedConcepts(ConceptCriterion? c) {
    const title = '이 기준과 이은 개념';
    if (c == null) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [ConceptSectionTitle(title), ConceptHint('초안을 저장한 뒤에 개념을 이을 수 있습니다.')],
      );
    }
    final list = _c.linkedConceptsOf(c.id);
    final err = _c.linkedConceptsError(c.id);
    final open = _c.selectedConcept;
    final openSaved = open != null && _c.isSavedConcept(open);
    final openLinked = open != null && (list?.any((x) => x.conceptId == open.id) ?? false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConceptSectionTitle(
          list == null ? title : '$title (${list.length})',
          trailing: IconButton(
            tooltip: '다시 읽기',
            onPressed: () => unawaited(_c.loadCriterionLinks(c.id)),
            icon: const Icon(Icons.refresh, size: 16),
            color: kThinkHint,
            visualDensity: VisualDensity.compact,
          ),
        ),
        if (err != null)
          ThinkNotice(text: '이은 개념을 읽지 못했습니다: $err', color: kThinkError, icon: Icons.error_outline)
        else if (list == null)
          const ConceptHint('이은 개념을 읽는 중입니다.')
        else if (list.isEmpty)
          const Text('연결된 개념 없음', style: TextStyle(color: kThinkSub, fontSize: 13))
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final x in list)
                InputChip(
                  label: Text(x.name.isEmpty ? '(이름 없음)' : x.name),
                  labelStyle: const TextStyle(color: kThinkText, fontSize: 13),
                  backgroundColor: kThinkField,
                  side: const BorderSide(color: kThinkBorder),
                  tooltip: '라이브러리에서 열기',
                  onPressed: () => widget.onOpenConcept(x.conceptId),
                  deleteIcon: const Icon(Icons.link_off, size: 16),
                  deleteButtonTooltipMessage: '연결 끊기',
                  onDeleted: () => _unlink(c, x.conceptId, x.name),
                ),
            ],
          ),
        const SizedBox(height: 8),
        if (open == null)
          const ConceptHint('라이브러리에서 개념을 열면 그 개념을 이 기준에 이을 수 있습니다.')
        else if (!openSaved)
          const ConceptHint('열어 둔 개념은 아직 저장 전이라 이을 수 없습니다.')
        else if (openLinked)
          ConceptHint('열어 둔 개념 "${open.name}"은(는) 이미 이어져 있습니다.')
        else
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: list == null ? null : () => _link(c, open),
              style: thinkOutlineButton(),
              icon: const Icon(Icons.link, size: 16),
              label: Text('열어 둔 개념 "${open.name}" 잇기', overflow: TextOverflow.ellipsis),
            ),
          ),
      ],
    );
  }

  Future<void> _link(ConceptCriterion c, ConceptItem concept) async {
    final problem = await _c.link(c.id, concept);
    if (!mounted) return;
    showThinkSnack(context, problem ?? '"${concept.name}"을(를) 이 기준에 이었습니다.', error: problem != null);
  }

  Future<void> _unlink(ConceptCriterion c, String conceptId, String name) async {
    final ok = await confirmThink(
      context,
      title: '연결 끊기',
      message: '"$name"과(와) 이 기준의 연결을 끊습니다. 개념과 기준은 그대로 남습니다.',
      confirmLabel: '끊기',
      destructive: true,
    );
    if (!ok) return;
    final problem = await _c.unlink(c.id, conceptId);
    if (!mounted) return;
    if (problem != null) showThinkSnack(context, problem, error: true);
  }

  Future<void> _showRevisions(ConceptCriterion c) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kThinkBg,
        shape: thinkDialogShape,
        title: Text('확정 기록 — ${criterionDisplayTitle(c)}',
            style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: 560,
          height: 420,
          child: FutureBuilder<List<ConceptCriterionRevision>>(
            future: _c.revisionsOf(c.id),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator(color: kThinkAccent));
              }
              if (snap.hasError) {
                return ThinkNotice(
                  text: '확정 기록을 읽지 못했습니다: ${ConceptLibraryException.from(snap.error!).message}',
                  color: kThinkError,
                  icon: Icons.error_outline,
                );
              }
              final list = snap.data ?? const <ConceptCriterionRevision>[];
              if (list.isEmpty) return const ConceptHint('확정 기록이 없습니다.');
              return ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(color: kThinkBorder, height: 20),
                itemBuilder: (context, i) {
                  final r = list[i];
                  return SelectionArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('v${r.version} · ${formatDateTime(r.confirmedAt)}',
                            style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
                        if ((r.note ?? '').trim().isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text('메모: ${r.note!.trim()}', style: const TextStyle(color: kThinkLink, fontSize: 12)),
                        ],
                        const SizedBox(height: 6),
                        Text(r.title, style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(r.body, style: const TextStyle(color: kThinkSub, fontSize: 13, height: 1.5)),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기', style: TextStyle(color: kThinkSub)),
          ),
        ],
      ),
    );
  }
}

class _ConfirmCriterionDialog extends StatefulWidget {
  const _ConfirmCriterionDialog({required this.next, required this.title});

  final int next;
  final String title;

  @override
  State<_ConfirmCriterionDialog> createState() => _ConfirmCriterionDialogState();
}

class _ConfirmCriterionDialogState extends State<_ConfirmCriterionDialog> {
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
              'Think는 확정본을 현재 기준으로 읽습니다.\n기존 개념은 자동으로 다시 정리되지 않습니다.',
              style: const TextStyle(color: kThinkSub, height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
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
          onPressed: () => Navigator.pop(context, _note.text),
          style: thinkPrimaryButton(color: kThinkSuccess),
          child: const Text('확정'),
        ),
      ],
    );
  }
}

/// 기준 쪽 요약(라이브러리를 크게 볼 때). 열어 둔 개념에 실제로 이은 기준과 핵심 설명, 확인할 수 있는 근거만 보인다.
class CriteriaSummaryPane extends StatefulWidget {
  const CriteriaSummaryPane({super.key, required this.controller});

  final ConceptLibraryController controller;

  @override
  State<CriteriaSummaryPane> createState() => _CriteriaSummaryPaneState();
}

class _CriteriaSummaryPaneState extends State<CriteriaSummaryPane> {
  final ScrollController _scroll = ScrollController();

  ConceptLibraryController get _c => widget.controller;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => ThinkPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConceptPaneHeader(
              icon: Icons.rule_folder_outlined,
              title: '정리 기준',
              badges: [if (_c.loaded) ThinkBadge('${_c.criteria.length}개')],
              onExpand: () => _c.setFocus(ConceptWorkspaceFocus.criteria),
            ),
            const Divider(color: kThinkBorder, height: 1),
            Expanded(
              child: Scrollbar(
                controller: _scroll,
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(14),
                  children: [
                    ..._forConcept(),
                    const SizedBox(height: 18),
                    ..._all(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _forConcept() {
    final concept = _c.selectedConcept;
    final out = <Widget>[const ConceptSectionTitle('열어 둔 개념에 이은 기준')];
    if (concept == null) {
      out.add(const ConceptHint('라이브러리에서 개념을 열면 그 개념에 이은 기준이 여기에 보입니다.'));
      return out;
    }
    out.add(Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text('현재 선택한 개념: ${concept.name.isEmpty ? '(이름 없음)' : concept.name}',
          style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
    ));
    if (!_c.isSavedConcept(concept)) {
      out.add(const ConceptHint('저장 전 개념이라 이은 기준이 없습니다.'));
      return out;
    }
    final err = _c.linkedCriteriaError(concept.id);
    final ids = _c.linkedCriteriaOf(concept.id);
    if (err != null) {
      out.add(ThinkNotice(text: '이은 기준을 읽지 못했습니다: $err', color: kThinkError, icon: Icons.error_outline));
      return out;
    }
    if (ids == null) {
      out.add(const ConceptHint('이은 기준을 읽는 중입니다.'));
      return out;
    }
    if (ids.isEmpty) {
      out.add(const Text('연결된 기준 없음', style: TextStyle(color: kThinkSub, fontSize: 13)));
      out.add(const SizedBox(height: 4));
      out.add(const ConceptHint('기준 쪽을 크게 열고 "열어 둔 개념 잇기"로 이을 수 있습니다.'));
      return out;
    }
    for (final id in ids) {
      final c = _c.criterionById(id);
      out.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: c == null ? const ConceptHint('(목록에 없는 기준 — 다시 불러오면 보입니다)') : _linkedCard(c),
      ));
    }
    return out;
  }

  Widget _linkedCard(ConceptCriterion c) {
    final text = (c.confirmed ? c.body : c.draftBody) ?? '';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _c.openCriterion(c.id),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kThinkBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(criterionDisplayTitle(c),
                  style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                text.trim().isEmpty ? '(내용 없음)' : text.trim(),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 6),
              ConceptHint(c.confirmed
                  ? '근거: 사용자가 직접 이음 · 확정 v${c.version} (${formatDateTime(c.confirmedAt)})'
                  : '근거: 사용자가 직접 이음 · 아직 확정 전 초안 (${formatDateTime(c.draftSavedAt)} 저장)'),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _all() {
    final out = <Widget>[ConceptSectionTitle(_c.loaded ? '기준 목록 (${_c.criteria.length})' : '기준 목록')];
    if (!_c.loaded) {
      out.add(ConceptHint(_c.loadError ?? '기준을 읽는 중입니다.'));
      return out;
    }
    final ids = _c.itemIds;
    if (ids.isEmpty) {
      out.add(const ConceptHint('아직 정리 기준이 없습니다. 크게 보기에서 추가할 수 있습니다.'));
      return out;
    }
    for (final id in ids) {
      final c = _c.criterionById(id);
      final edit = _c.peekEdit(id);
      Widget row() {
        final typed = edit?.title.text.trim() ?? '';
        return InkWell(
          onTap: () => _c.openCriterion(id),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c == null ? (typed.isEmpty ? '새 기준' : typed) : criterionDisplayTitle(c),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: id == _c.selectedCriterionId ? kThinkAccent : kThinkText,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    )),
                const SizedBox(height: 4),
                Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: criterionBadges(c, dirty: _c.isDirty(id), local: _c.isLocal(id))),
              ],
            ),
          ),
        );
      }

      out.add(edit == null ? row() : ListenableBuilder(listenable: edit.listenable, builder: (_, __) => row()));
    }
    return out;
  }
}
