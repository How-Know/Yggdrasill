part of 'think_action_cards.dart';

// 개념 초안 검토 대화에서 Think가 낸 제안 카드(초안 변경·기준 고치기·다시 정리).
// 검토 창 안에서는 검토 창이 승인을 맡는다(저장하지 않은 검토를 먼저 저장하고, 승인 뒤 초안을 다시 읽는다).
// 설계: docs/architecture/concept-library.md "검토 창 대화"

/// 카드가 개념 초안 검토 창 안에 놓였다. [draftId]가 카드의 초안과 같을 때만 승인한다.
class ConceptDraftCardScope extends InheritedWidget {
  const ConceptDraftCardScope({
    super.key,
    required this.draftId,
    required this.draftOpen,
    required this.approve,
    required this.rerun,
    required super.child,
  });

  final String? draftId;
  final bool draftOpen;

  /// 초안 변경·기준 고치기 승인. 오류 안내는 검토 창이 한다.
  final Future<void> Function(ThinkAction action) approve;

  /// 다시 정리 승인(새 초안을 만들고 검토 창이 그 초안으로 옮겨 간다).
  final Future<void> Function(ThinkAction action) rerun;

  static ConceptDraftCardScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ConceptDraftCardScope>();

  @override
  bool updateShouldNotify(ConceptDraftCardScope oldWidget) =>
      draftId != oldWidget.draftId || draftOpen != oldWidget.draftOpen || approve != oldWidget.approve || rerun != oldWidget.rerun;
}

const Map<String, String> _draftMarkLabels = {'keep': '그대로', 'edit': '고쳐서', 'drop': '빼기'};

Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : const {};
List<Map<String, dynamic>> _maps(Object? v) => v is List ? [for (final x in v) if (x is Map) Map<String, dynamic>.from(x)] : const [];
String _s(Object? v) => v == null ? '' : v.toString();
List<String> _strList(Object? v) => v is List ? [for (final x in v) if (x != null && x.toString().isNotEmpty) x.toString()] : const [];

/// 변경 하나를 한 줄로.
String conceptDraftOpLine(Map<String, dynamic> op) {
  final key = _s(op['key']);
  switch (_s(op['op'])) {
    case 'edit':
      final what = [
        if (_s(op['title']).isNotEmpty) '이름',
        if (_s(op['content']).isNotEmpty) '내용',
      ].join('·');
      return '$key ${what.isEmpty ? '고치기' : '$what 고치기'}';
    case 'mark':
      return _s(op['mark']) == 'drop' ? '$key 빼기' : '$key 되살리기';
    case 'type':
      return '$key 종류 → ${_s(op['type'])}';
    case 'folder':
      final path = _strList(op['folder']);
      return '$key 폴더 → ${path.isEmpty ? '(폴더 없음)' : path.join(' > ')}';
    case 'new_type':
      return '새 종류 "${_s(op['name'])}"';
    case 'split':
      return '$key ${_maps(op['parts']).length}개로 나누기';
    case 'merge':
      return '${_strList(op['keys']).join('·')} 합치기 → ${_s(op['into'])}';
  }
  return _s(op['op']);
}

class ConceptDraftActionCard extends StatefulWidget {
  const ConceptDraftActionCard({super.key, required this.action});

  final ThinkAction action;

  @override
  State<ConceptDraftActionCard> createState() => _ConceptDraftActionCardState();
}

class _ConceptDraftActionCardState extends State<ConceptDraftActionCard> with _BusyState {
  ThinkAction get a => widget.action;
  ThinkController get _think => ThinkController.instance;

  String get _draftId => _s(a.payload['draft_id']);
  String get _reason => _s(a.preview['reason'] ?? a.payload['reason']);
  String get _draftLabel => _s(a.preview['draft_label']);

  @override
  Widget build(BuildContext context) {
    final scope = ConceptDraftCardScope.maybeOf(context);
    switch (a.status) {
      case ThinkActionStatus.applied:
        return _ClosedLine(icon: Icons.check_circle_outline, text: _appliedText());
      case ThinkActionStatus.rejected:
        return _ClosedLine(icon: Icons.block, text: '${a.kind.label} 제안 · 거절함${a.title.isEmpty ? '' : ' · ${a.title}'}');
      case ThinkActionStatus.undone:
      case ThinkActionStatus.expired:
        return _ClosedLine(icon: Icons.history, text: '${a.kind.label} 제안 · ${a.status.label}');
      case ThinkActionStatus.failed:
      case ThinkActionStatus.proposed:
        break;
    }
    final blocked = _blockedReason(scope);
    return _CardFrame(
      icon: switch (a.kind) {
        ThinkActionKind.conceptCriterionChange => Icons.rule_folder_outlined,
        ThinkActionKind.conceptDraftRerun => Icons.refresh,
        _ => Icons.fact_check_outlined,
      },
      label: '${a.kind.label} 제안',
      badge: const ThinkBadge('승인 대기', color: kThinkLink),
      children: [
        _title(a.title.isEmpty ? a.kind.label : a.title),
        if (_draftLabel.isNotEmpty) ...[
          _gap(4),
          Text('초안: $_draftLabel', style: const TextStyle(color: kThinkSub, fontSize: 12)),
        ],
        _gap(),
        ...switch (a.kind) {
          ThinkActionKind.conceptCriterionChange => _criterionBody(),
          ThinkActionKind.conceptDraftRerun => _rerunBody(),
          _ => _changeBody(),
        },
        if (_reason.isNotEmpty) ...[
          thinkCodeLabel('Think가 제안한 이유'),
          SelectableText(_reason, style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
        ],
        _gap(),
        ThinkNotice(icon: Icons.info_outline, text: _approveNote()),
        if (blocked != null) ...[
          _gap(8),
          ThinkNotice(icon: Icons.lock_outline, color: kThinkAccent, text: blocked),
        ],
        _gap(),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ElevatedButton.icon(
              onPressed: busy || blocked != null ? null : () => _approve(scope),
              style: thinkPrimaryButton(),
              icon: const Icon(Icons.check, size: 16),
              label: Text(a.kind == ThinkActionKind.conceptDraftRerun ? '승인하고 다시 정리' : '승인'),
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

  String _appliedText() {
    return switch (a.kind) {
      ThinkActionKind.conceptCriterionChange =>
        '정리 기준 고치기 · 기준 초안으로 저장함(확정은 정리 기준 화면에서)${a.title.isEmpty ? '' : ' · ${a.title}'}',
      ThinkActionKind.conceptDraftRerun => '다시 정리 · 같은 쪽으로 새 초안을 만들고 앞 초안은 "다시 정리함"으로 닫음',
      _ => '개념 초안 변경 · 승인해 검토에 반영함${a.title.isEmpty ? '' : ' · ${a.title}'}',
    };
  }

  String? _blockedReason(ConceptDraftCardScope? scope) {
    if (scope != null) {
      if (scope.draftId != _draftId) return '다른 초안에 대한 카드입니다. 그 초안을 열었을 때 승인할 수 있습니다.';
      if (!scope.draftOpen) return '닫힌 초안이라 승인할 수 없습니다.';
      return null;
    }
    if (a.kind == ThinkActionKind.conceptDraftRerun) return '다시 정리는 개념 초안 검토 창에서 승인합니다.';
    return null;
  }

  String _approveNote() {
    return switch (a.kind) {
      ThinkActionKind.conceptCriterionChange =>
        '승인하면 이 기준의 초안으로만 저장합니다. 확정본은 그대로이고, 확정은 정리 기준 화면에서 합니다. 다시 정리하면 확정본과 이 초안을 함께 씁니다.',
      ThinkActionKind.conceptDraftRerun =>
        '승인하면 같은 쪽으로 새 초안을 만듭니다(AI 비용 약 \$0.09). 지금 초안은 "다시 정리함"으로 닫히고 목록에서 다시 열어 볼 수 있습니다.',
      _ => '승인하면 저장된 검토에 반영합니다. 제안한 뒤 그 항목을 고쳤다면 승인이 막히니 Think에게 다시 물어보세요. 확정은 검토 창의 확정 버튼으로 따로 합니다.',
    };
  }

  Future<void> _approve(ConceptDraftCardScope? scope) async {
    if (scope != null) {
      if (busy) return;
      setState(() => busy = true);
      try {
        if (a.kind == ThinkActionKind.conceptDraftRerun) {
          await scope.rerun(a);
        } else {
          await scope.approve(a);
        }
      } finally {
        if (mounted) setState(() => busy = false);
      }
      return;
    }
    await run(
      () => _think.applyConceptDraftAction(a),
      done: a.kind == ThinkActionKind.conceptCriterionChange ? '기준 초안으로 저장했습니다.' : '초안 검토에 반영했습니다.',
    );
  }

  // ------------------------------------------------------------ 초안 변경
  List<Widget> _changeBody() {
    final ops = _maps(a.payload['ops']);
    final before = _map(a.preview['before']);
    final after = _maps(a.preview['after']);
    final newTypes = _maps(a.preview['new_types']);
    return [
      thinkCodeLabel('바꿀 것 ${ops.length}건'),
      for (final op in ops)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('· ${conceptDraftOpLine(op)}', style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
        ),
      if (newTypes.isNotEmpty) ...[
        _gap(8),
        thinkCodeLabel('새 종류(확정할 때 받아들일지 고릅니다)'),
        for (final t in newTypes)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '· ${_s(t['name'])}${_s(t['description']).isEmpty ? '' : ' — ${_s(t['description'])}'}',
              style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5),
            ),
          ),
      ],
      if (after.isNotEmpty || before.isNotEmpty) ...[
        _gap(8),
        thinkCodeLabel('바뀐 뒤 항목'),
        for (final item in after) _DraftItemDiff(after: item, before: _map(before[_s(item['key'])])),
        for (final key in before.keys.where((k) => !after.any((x) => _s(x['key']) == k)))
          _DraftItemDiff(after: const {}, before: _map(before[key]), removedKey: key),
      ],
    ];
  }

  // ------------------------------------------------------------ 기준 고치기
  List<Widget> _criterionBody() {
    final before = _map(a.preview['before']);
    final after = _map(a.preview['after']);
    final state = _s(before['state']) == 'draft' ? '저장된 초안' : '확정 v${_s(before['version'])}';
    return [
      thinkCodeLabel('지금($state)'),
      _textBox(_s(before['title']), _s(before['body'])),
      _gap(8),
      thinkCodeLabel('바꿀 내용(기준 초안으로 저장)'),
      _textBox(_s(after['title']), _s(after['body'])),
    ];
  }

  // ------------------------------------------------------------ 다시 정리
  List<Widget> _rerunBody() {
    final criteria = _maps(a.preview['criteria']);
    return [
      thinkCodeLabel(criteria.isEmpty ? '정리 기준 없이 다시 정리' : '쓸 정리 기준 ${criteria.length}개'),
      for (final c in criteria)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            '· ${_s(c['title'])} (${(c['version'] as num? ?? 0) > 0 ? '확정 v${c['version']}' : '확정 전'}'
            '${c['has_draft'] == true ? ' + 저장된 초안' : ''})',
            style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5),
          ),
        ),
    ];
  }

  Widget _textBox(String title, String body) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: kThinkBorder)),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(title, style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
            _gap(4),
            SelectableText(body, style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.5)),
          ],
        ),
      ),
    );
  }
}

/// 항목 하나의 바뀌기 전·뒤. 내용은 펼쳐서 본다.
class _DraftItemDiff extends StatefulWidget {
  const _DraftItemDiff({required this.after, required this.before, this.removedKey});

  final Map<String, dynamic> after;
  final Map<String, dynamic> before;

  /// 바뀐 뒤 목록에서 사라진 항목(합치거나 나눈 원래 항목).
  final String? removedKey;

  @override
  State<_DraftItemDiff> createState() => _DraftItemDiffState();
}

class _DraftItemDiffState extends State<_DraftItemDiff> {
  bool _open = false;

  String _line(Map<String, dynamic> m) {
    final folder = _strList(m['folder']);
    return [
      _s(m['type']),
      _draftMarkLabels[_s(m['mark'])] ?? _s(m['mark']),
      if (folder.isNotEmpty) folder.join(' > '),
      if (_s(m['merged_into']).isNotEmpty) '${_s(m['merged_into'])}에 합침',
    ].where((x) => x.isNotEmpty).join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final after = widget.after;
    final before = widget.before;
    final removed = widget.removedKey != null;
    final key = removed ? widget.removedKey! : _s(after['key']);
    final isNew = before.isEmpty && !removed;
    final contentChanged = !removed && _s(after['content']) != _s(before['content']);
    final titleChanged = !removed && !isNew && _s(after['title']) != _s(before['title']);
    final main = removed ? before : after;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: kThinkBorder)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ThinkBadge(key, color: kThinkSub),
              if (isNew) ...[const SizedBox(width: 8), const ThinkBadge('새 항목', color: kThinkAccent)],
              if (removed) ...[const SizedBox(width: 8), const ThinkBadge('목록에서 빠짐', color: kThinkError)],
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _s(main['title']),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: removed ? kThinkHint : kThinkText,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    decoration: removed ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
            ],
          ),
          if (titleChanged)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('전: ${_s(before['title'])}', style: const TextStyle(color: kThinkHint, fontSize: 12)),
            ),
          const SizedBox(height: 4),
          Text(
            before.isEmpty || removed || _line(before) == _line(after) ? _line(main) : '${_line(before)} → ${_line(after)}',
            style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.4),
          ),
          if (contentChanged || isNew)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _open = !_open),
                child: Text(_open ? '내용 접기' : (isNew ? '내용 보기' : '내용 전·후 보기'),
                    style: const TextStyle(color: kThinkLink, fontSize: 12)),
              ),
            ),
          if (_open) ...[
            if (!isNew) ...[
              const Text('전', style: TextStyle(color: kThinkHint, fontSize: 12, fontWeight: FontWeight.w700)),
              _content(_s(before['content']), kThinkHint),
              const SizedBox(height: 8),
              const Text('후', style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
            ],
            _content(_s(after['content']), kThinkText),
          ],
        ],
      ),
    );
  }

  Widget _content(String text, Color color) => SelectionArea(
        child: LatexTextRenderer(
          text,
          dollarMath: true,
          style: TextStyle(color: color, fontSize: 12, height: 1.5),
          crossAxisAlignment: CrossAxisAlignment.start,
        ),
      );
}
