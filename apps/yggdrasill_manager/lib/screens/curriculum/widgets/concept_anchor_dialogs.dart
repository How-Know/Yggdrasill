import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/concept_category_service.dart';
import '../../../services/concept_draft_service.dart';
import '../../../services/concept_service.dart';
import '../../../services/concept_topic.dart';
import '../../think/think_style.dart';
import 'concept_type_chip.dart';
import 'concept_workspace.dart';

/// 개념 상세에 보이는 주제 묶음(같은 폴더 안).
class ConceptTopicInfo {
  const ConceptTopicInfo({
    this.anchor,
    this.dependents = const [],
    this.typeOf = const {},
    this.unavailable = false,
    this.canChoose = true,
  });

  final ConceptItem? anchor;
  final List<ConceptItem> dependents;

  /// 개념 id → 유형 이름(칩 색).
  final Map<String, String> typeOf;

  /// 묶음 표를 읽지 못했다(반영 전 등).
  final bool unavailable;
  final bool canChoose;
}

class ConceptAnchorChoice {
  const ConceptAnchorChoice(this.anchorId);

  /// null = 묶지 않음.
  final String? anchorId;
}

/// [id]가 (여러 단계로) [root]에 붙어 있는지. 그러면 [root]를 [id]에 붙일 수 없다(고리).
bool _under(String id, String root, Map<String, String> anchors) {
  var cur = anchors[id];
  for (var steps = 0; cur != null && steps <= anchors.length; steps++) {
    if (cur == root) return true;
    cur = anchors[cur];
  }
  return false;
}

/// 같은 폴더의 다른 개념 중 이 개념을 붙일 개념을 고른다. 이 개념에 붙은 개념은 고를 수 없다(고리).
Future<ConceptAnchorChoice?> showConceptAnchorPicker(
  BuildContext context, {
  required ConceptItem concept,
  required CategoryNode folder,
  required ConceptTreeMeta meta,
}) {
  return showDialog<ConceptAnchorChoice>(
    context: context,
    builder: (_) => _AnchorPicker(concept: concept, folder: folder, meta: meta),
  );
}

class _AnchorPicker extends StatefulWidget {
  const _AnchorPicker({required this.concept, required this.folder, required this.meta});

  final ConceptItem concept;
  final CategoryNode folder;
  final ConceptTreeMeta meta;

  @override
  State<_AnchorPicker> createState() => _AnchorPickerState();
}

class _AnchorPickerState extends State<_AnchorPicker> {
  late String? _picked = _current;

  String? get _current {
    final a = widget.meta.anchorOf[widget.concept.id];
    return a != null && widget.folder.concepts.any((c) => c.id == a) ? a : null;
  }

  @override
  Widget build(BuildContext context) {
    final inFolder = {
      for (final e in widget.meta.anchorOf.entries)
        if (widget.folder.concepts.any((c) => c.id == e.key)) e.key: e.value,
    };
    final blocked = {
      for (final c in widget.folder.concepts)
        if (_under(c.id, widget.concept.id, inFolder)) c.id
    };
    final lines = flattenTopicForest(conceptTopicForest(widget.folder.concepts, widget.meta));
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text('주제 묶음 — ${widget.concept.name}',
          style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800, fontSize: 16)),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ConceptHint('이 개념을 이해하려면 바로 앞에 알아야 하는 개념을 고릅니다. 트리에서는 그 개념 뒤에 묶여 보입니다.'),
            const SizedBox(height: 12),
            _option(null, '묶지 않음', '이 폴더에서 묶음의 첫 개념으로 둡니다.', null),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final l in lines)
                      if (l.node.concept.id != widget.concept.id)
                        Padding(
                          padding: EdgeInsets.only(left: l.depth * 16.0),
                          child: _option(
                            l.node.concept.id,
                            l.node.concept.name,
                            blocked.contains(l.node.concept.id) ? '이 개념에 붙은 개념이라 고를 수 없습니다(고리).' : null,
                            conceptTypeStyle(widget.meta.typeOf[l.node.concept.id]),
                            enabled: !blocked.contains(l.node.concept.id),
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('취소', style: TextStyle(color: kThinkSub))),
        ElevatedButton(
          onPressed: _picked == _current ? null : () => Navigator.pop(context, ConceptAnchorChoice(_picked)),
          style: thinkPrimaryButton(),
          child: const Text('저장'),
        ),
      ],
    );
  }

  Widget _option(String? id, String name, String? note, ConceptTypeStyle? style, {bool enabled = true}) {
    final on = _picked == id;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: InkWell(
        key: ValueKey('anchor-option-${id ?? 'none'}'),
        onTap: enabled ? () => setState(() => _picked = id) : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: on ? kThinkAccent.withValues(alpha: 0.12) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(on ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 18, color: on ? kThinkAccent : kThinkHint),
              const SizedBox(width: 8),
              if (style != null) ...[ConceptTypeTag(style), const SizedBox(width: 8)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w600)),
                    if (note != null) Text(note, style: const TextStyle(color: kThinkHint, fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 폴더 메뉴 "주제 묶음 제안받기": AI 제안을 줄마다 보고 고른 줄만 저장한다. 돌려주는 값: 저장했는지.
Future<bool?> showConceptAnchorProposalDialog(
  BuildContext context, {
  required CategoryNode folder,
  required ConceptTreeMeta meta,
  required ConceptDraftService service,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ConceptAnchorProposalDialog(
        folder: folder, meta: meta, propose: service.proposeAnchors, save: service.setAnchors),
  );
}

typedef ConceptAnchorProposer = Future<ConceptAnchorProposal> Function(String folderId);
typedef ConceptAnchorSaver = Future<void> Function(Map<String, String?> links, {required String origin});

class ConceptAnchorProposalDialog extends StatefulWidget {
  const ConceptAnchorProposalDialog({
    super.key,
    required this.folder,
    required this.meta,
    required this.propose,
    required this.save,
  });

  final CategoryNode folder;
  final ConceptTreeMeta meta;
  final ConceptAnchorProposer propose;
  final ConceptAnchorSaver save;

  @override
  State<ConceptAnchorProposalDialog> createState() => _ConceptAnchorProposalDialogState();
}

class _ConceptAnchorProposalDialogState extends State<ConceptAnchorProposalDialog> {
  ConceptAnchorProposal? _proposal;
  String? _error;
  bool _saving = false;
  final Map<String, String?> _choice = {};
  final Set<String> _apply = {};

  Map<String, ConceptItem> get _byId => {for (final c in widget.folder.concepts) c.id: c};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _proposal = null;
      _error = null;
    });
    try {
      final p = await widget.propose(widget.folder.id);
      if (!mounted) return;
      setState(() {
        _proposal = p;
        _choice.clear();
        _apply.clear();
        for (final i in p.items) {
          _choice[i.conceptId] = i.anchorId;
          if (i.changed) _apply.add(i.conceptId);
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e is ConceptDraftException ? e.message : '$e');
    }
  }

  ConceptAnchorProposalItem? _item(String id) => _proposal?.items.where((i) => i.conceptId == id).firstOrNull;

  Map<String, String?> get _changes => {
        for (final id in _apply)
          if (_choice[id] != _item(id)?.currentAnchorId) id: _choice[id],
      };

  List<String> get _cycle {
    final next = <String, String>{
      for (final i in _proposal?.items ?? const <ConceptAnchorProposalItem>[])
        if (i.currentAnchorId != null) i.conceptId: i.currentAnchorId!,
    };
    _changes.forEach((id, a) => a == null ? next.remove(id) : next[id] = a);
    return anchorCycleMembers(next);
  }

  Future<void> _save() async {
    final changes = _changes;
    if (changes.isEmpty || _cycle.isNotEmpty) return;
    setState(() => _saving = true);
    try {
      await widget.save(changes, origin: 'proposal');
      if (!mounted) return;
      showThinkSnack(context, '묶음 ${changes.length}개를 저장했습니다.');
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showThinkSnack(context, e is ConceptDraftException ? e.message : '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _proposal;
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Row(
        children: [
          const Icon(Icons.hub_outlined, size: 20, color: kThinkAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text('주제 묶음 제안 — ${widget.folder.name}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800, fontSize: 16)),
          ),
        ],
      ),
      content: SizedBox(width: 760, child: p == null ? _waiting() : _body(p)),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('닫기', style: TextStyle(color: kThinkSub)),
        ),
        if (_error != null)
          OutlinedButton.icon(
            onPressed: _load,
            style: thinkOutlineButton(),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('다시 제안받기'),
          ),
        if (p != null)
          ElevatedButton.icon(
            key: const ValueKey('anchor-proposal-save'),
            onPressed: _saving || _changes.isEmpty || _cycle.isNotEmpty ? null : _save,
            style: thinkPrimaryButton(),
            icon: const Icon(Icons.check_rounded, size: 16),
            label: Text('고른 줄 저장 (${_changes.length})'),
          ),
      ],
    );
  }

  Widget _waiting() {
    if (_error != null) {
      return ThinkNotice(text: '제안을 받지 못했습니다: $_error', color: kThinkError, icon: Icons.error_outline);
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: kThinkAccent)),
          SizedBox(height: 12),
          Text('Think가 이 폴더의 개념을 읽고 묶음을 고르는 중입니다. 1분 남짓 걸릴 수 있습니다.', style: TextStyle(color: kThinkSub, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _body(ConceptAnchorProposal p) {
    final byId = _byId;
    final cycle = _cycle;
    final lines = flattenTopicForest(conceptTopicForest(widget.folder.concepts, widget.meta));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (p.summary.isNotEmpty) ...[
          ThinkNotice(text: p.summary, color: kThinkAccent, icon: Icons.auto_awesome_outlined),
          const SizedBox(height: 8),
        ],
        if (p.unanswered.isNotEmpty || p.broken.isNotEmpty) ...[
          ConceptHint([
            if (p.unanswered.isNotEmpty) 'AI가 답하지 않은 개념 ${p.unanswered.length}개는 지금 묶음을 그대로 두었습니다.',
            if (p.broken.isNotEmpty) '서로 가리키게 되는 ${p.broken.length}개는 묶지 않음으로 바꿨습니다.',
          ].join(' ')),
          const SizedBox(height: 8),
        ],
        if (cycle.isNotEmpty) ...[
          ThinkNotice(
            text: '고른 대로 저장하면 서로 가리키는 묶음이 생깁니다: ${cycle.map((id) => byId[id]?.name ?? id).join(', ')}',
            color: kThinkError,
            icon: Icons.error_outline,
          ),
          const SizedBox(height: 8),
        ],
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 440),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final l in lines)
                  if (_item(l.node.concept.id) != null) _row(l.node.concept, _item(l.node.concept.id)!, byId),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        ConceptHint('AI 제안입니다. 체크한 줄만 저장되고, 개념 이름·본문·폴더는 바뀌지 않습니다.'
            '${p.costUsd == null ? '' : ' 이번 제안 비용 약 \$${p.costUsd!.toStringAsFixed(3)}.'}'),
      ],
    );
  }

  Widget _row(ConceptItem c, ConceptAnchorProposalItem item, Map<String, ConceptItem> byId) {
    final choice = _choice[c.id];
    final changed = choice != item.currentAnchorId;
    final checked = _apply.contains(c.id) && changed;
    final current = item.currentAnchorId == null ? '묶지 않음' : (byId[item.currentAnchorId]?.name ?? '(다른 폴더)');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: checked ? kThinkAccent.withValues(alpha: 0.06) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: checked ? kThinkAccent.withValues(alpha: 0.4) : kThinkBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            key: ValueKey('anchor-apply-${c.id}'),
            value: checked,
            onChanged: changed ? (v) => setState(() => v == true ? _apply.add(c.id) : _apply.remove(c.id)) : null,
            activeColor: kThinkAccent,
            side: const BorderSide(color: kThinkHint),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ConceptTypeChip(name: c.name, style: conceptTypeStyle(widget.meta.typeOf[c.id])),
                    const Icon(Icons.arrow_forward_rounded, size: 16, color: kThinkHint),
                    _anchorDropdown(c, choice, byId),
                    if (!changed) const ThinkBadge('그대로'),
                  ],
                ),
                const SizedBox(height: 8),
                Text('지금: $current${item.reason.isEmpty ? '' : ' · ${item.reason}'}',
                    style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _anchorDropdown(ConceptItem c, String? choice, Map<String, ConceptItem> byId) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: kThinkField,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkBorder),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: ValueKey('anchor-choice-${c.id}'),
          value: choice ?? '',
          dropdownColor: kThinkPanel,
          isDense: true,
          style: const TextStyle(color: kThinkText, fontSize: 13),
          icon: const Icon(Icons.expand_more_rounded, size: 18, color: kThinkSub),
          items: [
            const DropdownMenuItem(value: '', child: Text('묶지 않음')),
            for (final o in widget.folder.concepts)
              if (o.id != c.id) DropdownMenuItem(value: o.id, child: Text(o.name, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() {
            _choice[c.id] = (v ?? '').isEmpty ? null : v;
            _apply.add(c.id);
          }),
        ),
      ),
    );
  }
}
