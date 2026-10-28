part of 'think_action_cards.dart';

// 과정 탐색도·개념 배치·개념 고치기·개념 검토 기록·개념 관계 카드(Think가 낸 제안). 승인은 course_think_action_apply 한 번이다.
// 항목 카드는 항목을 빼거나 단원을 바꿔 고른 것만 승인하고, 결과는 항목별로 남는다.
// 설계: docs/architecture/course-map.md "Think 카드", docs/architecture/concept-library.md "범위별 개념 검토"·"관계 유형"

const Map<String, String> _placementOps = {'place': '넣기', 'move': '옮기기', 'remove': '빼기', 'reorder': '순서'};
const Map<String, String> _libraryOps = {'create': '만들기', 'edit': '고치기', 'statement': '서술 고치기', 'delete': '지우기'};

const Map<String, String> _reviewScopes = {
  'notation': '오탈자·표기',
  'meaning': '수학적 의미',
  'classification': '유형·폴더',
  'unit': '중복·개념 단위',
  'relations': '관계',
  'foundation': '초등 기초 개념',
  'placement': '교육과정 배치',
};

/// "검증됨"에 해당하는 결과는 없다. 문제 못 찾음은 이번에 본 범위에서 못 찾았다는 뜻일 뿐이다.
const Map<String, String> _reviewOutcomes = {
  'no_issue_found': '문제 못 찾음',
  'issue_found': '문제 있음',
  'needs_comparison': '비교 더 필요',
  'unverified': '확인 못 함',
  'merge_needed': '병합 필요(삭제 보류)',
};

const Map<String, String> _relationOps = {'add': '넣기', 'change': '바꾸기', 'remove': '빼기'};

Color _relationOpColor(String op) => switch (op) {
      'add' => kThinkAccent,
      'remove' => kThinkError,
      _ => kThinkLink,
    };

Color _reviewOutcomeColor(String outcome) => switch (outcome) {
      'issue_found' || 'merge_needed' => kThinkError,
      'needs_comparison' => kThinkAccent,
      'unverified' => kThinkHint,
      _ => kThinkSub,
    };

const Map<String, String> _courseItemCodes = {
  'course_placement_exists': '이미 그 단원에 놓여 있음',
  'course_placement_same_unit': '이미 그 단원에 있음',
  'course_placement_not_found': '배치가 없어짐',
  'course_placement_unit_not_found': '단원이 없어짐(보관됐을 수 있음)',
  'course_placement_unit_foreign': '다른 과정의 단원',
  'course_placement_concept_not_found': '개념이 없어짐',
  'course_placement_stale': '그사이 단원의 개념 목록이 바뀜',
  'course_think_bad_overrides': '바꾼 단원이 올바르지 않음',
  'concept_think_concept_not_found': '개념이 없어짐',
  'concept_think_stale': '제안한 뒤 개념이 바뀜',
  'concept_content_draft_pending': '확정 전 수정안이 있음',
  'concept_delete_attached': '붙은 것이 생겨 지울 수 없음',
  'concept_statement_stale': '제안한 뒤 서술이 바뀜',
  'concept_statement_not_found': '서술이 없어짐',
  'concept_review_stale': '제안한 뒤 개념 내용이 바뀜(다시 검토 필요)',
  'concept_review_compared_changed': '비교한 개념이 바뀌었거나 지워짐',
  'concept_review_concept_not_found': '개념이 없어짐',
  'concept_relation_concept_stale': '제안한 뒤 두 개념 중 하나의 글이 바뀜(다시 판단 필요)',
  'concept_relation_concept_not_found': '개념이 없어짐',
  'concept_relation_stale': '제안한 뒤 이 관계를 다른 곳에서 고침',
  'concept_relation_not_found': '관계가 없어짐',
  'concept_relation_reverse_exists': '반대 방향 관계가 이미 있음',
  'concept_relation_exists': '같은 관계가 이미 있음',
  'concept_relation_unchanged': '바뀐 것이 없음',
  'concept_relation_context_required': '맥락이 없음',
};

const Map<String, String> _statementFields = {
  'title': '제목',
  'body': '본문',
  'approach': '접근 방식',
  'conditions': '조건',
  'terms': '용어',
  'basis': '근거',
  'supplement_note': '보완한 점',
  'unverified_note': '확인 안 됨',
  'meaning': '공통 의미',
  'scope': '적용 범위',
};

String _courseItemError(String code) {
  for (final e in _courseItemCodes.entries) {
    if (code.contains(e.key)) return e.value;
  }
  return code.isEmpty ? '반영하지 못함' : code;
}

Color _courseOpColor(String op) => switch (op) {
      'place' || 'create' => kThinkAccent,
      'remove' || 'delete' => kThinkError,
      'reorder' => kThinkSub,
      _ => kThinkLink,
    };

String _fieldText(Object? v) {
  if (v == null) return '(없음)';
  if (v is List) return v.isEmpty ? '(없음)' : v.map((e) => e.toString()).join(', ');
  final s = v.toString().trim();
  if (s == 'organized') return '정리함';
  if (s == 'verbatim') return '원문 그대로';
  return s.isEmpty ? '(없음)' : s;
}

class CourseThinkActionCard extends StatefulWidget {
  const CourseThinkActionCard({super.key, required this.action});

  final ThinkAction action;

  @override
  State<CourseThinkActionCard> createState() => _CourseThinkActionCardState();
}

class _CourseThinkActionCardState extends State<CourseThinkActionCard> with _BusyState {
  /// 빼고 승인할 항목 번호. 지울 수 없는 항목은 처음부터 빠져 있다.
  final Set<int> _skip = {};

  /// 항목 번호 → 바꾼 단원.
  final Map<int, String> _units = {};

  ThinkAction get a => widget.action;
  ThinkController get _think => ThinkController.instance;

  String get _reason => _s(a.preview['reason'] ?? a.payload['reason']);
  String get _course => _s(a.preview['course_name']);
  String get _subject => _course.isEmpty ? '' : ' "$_course"';

  @override
  void initState() {
    super.initState();
    for (final m in a.courseItems) {
      if (m['blocked'] == true) _skip.add(_i(m));
    }
  }

  int _i(Map<String, dynamic> m) => (m['i'] as num?)?.toInt() ?? 0;
  String _name(Map<String, dynamic> m) => _s(m['concept_name']).isNotEmpty ? _s(m['concept_name']) : _s(m['name']);

  @override
  Widget build(BuildContext context) {
    switch (a.status) {
      case ThinkActionStatus.applied:
        return _applied();
      case ThinkActionStatus.rejected:
        return _ClosedLine(icon: Icons.block, text: '${a.kind.label} 제안$_subject · 거절함');
      case ThinkActionStatus.undone:
      case ThinkActionStatus.expired:
        return _ClosedLine(icon: Icons.history, text: '${a.kind.label} 제안$_subject · ${a.status.label}');
      case ThinkActionStatus.failed:
      case ThinkActionStatus.proposed:
        break;
    }
    final items = a.courseItems;
    final chosen = items.where((m) => !_skip.contains(_i(m))).length;
    final selectable = items.where((m) => m['blocked'] != true).toList();
    final allChosen = selectable.every((m) => !_skip.contains(_i(m)));
    return _CardFrame(
      icon: switch (a.kind) {
        ThinkActionKind.conceptPlacementChange => Icons.account_tree_outlined,
        ThinkActionKind.conceptLibraryChange => Icons.edit_note,
        ThinkActionKind.conceptReviewRecord => Icons.fact_check_outlined,
        ThinkActionKind.conceptRelationChange => Icons.hub_outlined,
        _ => Icons.timeline,
      },
      label: '${a.kind.label} 제안',
      badge: const ThinkBadge('승인 대기', color: kThinkLink),
      children: [
        _title(_heading(items)),
        ..._summary(items),
        _gap(),
        ...switch (a.kind) {
          ThinkActionKind.conceptPlacementChange => _placementBody(items),
          ThinkActionKind.conceptLibraryChange => _libraryBody(items),
          ThinkActionKind.conceptReviewRecord => _reviewBody(items),
          ThinkActionKind.conceptRelationChange => _relationBody(items),
          ThinkActionKind.courseMapCreate => _createBody(),
          _ => _mapBody(),
        },
        if (_reason.isNotEmpty) ...[
          _gap(8),
          thinkCodeLabel('Think가 제안한 이유'),
          SelectableText(_reason, style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
        ],
        if ((a.error ?? '').isNotEmpty) ...[
          _gap(8),
          ThinkNotice(
            icon: Icons.error_outline,
            color: kThinkError,
            text: '지난 승인에서 반영하지 못했습니다. 카드는 그대로 두었으니 다시 승인할 수 있습니다. ${ThinkApi.codeErrorMessage(a.error!)}',
          ),
        ],
        _gap(),
        ThinkNotice(icon: Icons.info_outline, text: _approveNote()),
        ..._dirtyWarning(),
        _gap(),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ElevatedButton.icon(
              key: ValueKey('course-think-approve-${a.id}'),
              onPressed: busy || (a.kind.hasItems && chosen == 0) ? null : _approve,
              style: thinkPrimaryButton(),
              icon: const Icon(Icons.check, size: 16),
              label: Text(a.kind.hasItems ? '고른 것 승인 ($chosen)' : '승인'),
            ),
            if (a.kind.hasItems && selectable.length > 1)
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                          for (final m in selectable) {
                            allChosen ? _skip.add(_i(m)) : _skip.remove(_i(m));
                          }
                        }),
                child: Text(allChosen ? '모두 빼기' : '모두 고르기', style: const TextStyle(color: kThinkLink)),
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

  String _heading(List<Map<String, dynamic>> items) => switch (a.kind) {
        ThinkActionKind.conceptPlacementChange => '"$_course" 단원에 개념 배치 ${items.length}건',
        ThinkActionKind.conceptLibraryChange => '개념 고치기 ${items.length}건',
        ThinkActionKind.conceptReviewRecord => '개념 검토 기록 ${items.length}건',
        ThinkActionKind.conceptRelationChange => '개념 관계 고치기 ${items.length}건',
        ThinkActionKind.courseMapCreate => '새 과정 "${_s(a.preview['name'])}"',
        _ => '"$_course" · ${a.title.isEmpty ? a.kind.label : a.title}',
      };

  List<Widget> _summary(List<Map<String, dynamic>> items) {
    final counts = _map(a.preview['counts']);
    String countLine(Map<String, String> labels) => [
          for (final e in labels.entries)
            if (((counts[e.key] as num?) ?? 0) > 0) '${e.value} ${counts[e.key]}',
        ].join(' · ');
    switch (a.kind) {
      case ThinkActionKind.conceptPlacementChange:
        final judgment = (a.preview['judgment'] as num?)?.toInt() ?? 0;
        return [
          _gap(4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(countLine(_placementOps), style: const TextStyle(color: kThinkSub, fontSize: 12)),
              if (judgment > 0)
                Tooltip(
                  message: '교재 출처로 정하지 않고 Think가 개념 이름·내용을 보고 판단한 항목입니다.',
                  child: ThinkBadge('출처 없이 판단 $judgment', color: kThinkAccent),
                ),
            ],
          ),
        ];
      case ThinkActionKind.conceptLibraryChange:
        final blocked = (a.preview['blocked'] as num?)?.toInt() ?? 0;
        return [
          _gap(4),
          Text(countLine(_libraryOps), style: const TextStyle(color: kThinkSub, fontSize: 12)),
          if (blocked > 0) ...[
            _gap(8),
            ThinkNotice(
              icon: Icons.block,
              color: kThinkError,
              text: '붙은 것이 있어 지울 수 없는 개념 $blocked개 — 이 항목은 반영하지 않습니다. 먼저 붙은 것을 떼어야 지울 수 있습니다.',
            ),
          ],
        ];
      case ThinkActionKind.conceptReviewRecord:
        return [
          _gap(4),
          Text(countLine(_reviewOutcomes), style: const TextStyle(color: kThinkSub, fontSize: 12)),
        ];
      case ThinkActionKind.conceptRelationChange:
        return [
          _gap(4),
          Text(countLine(_relationOps), style: const TextStyle(color: kThinkSub, fontSize: 12)),
        ];
      case ThinkActionKind.courseMapCreate:
        final c = _strList(a.preview['counts']);
        return [
          _gap(4),
          Text(
            '${_s(a.preview['school_level'])} · ${_s(a.preview['curriculum_label']).isEmpty ? '교육과정 미기록' : _s(a.preview['curriculum_label'])}'
            '${c.length == 3 ? ' · 대 ${c[0]} · 중 ${c[1]} · 소 ${c[2]}' : ''}',
            style: const TextStyle(color: kThinkSub, fontSize: 12),
          ),
        ];
      default:
        return [
          _gap(4),
          Text('판 v${_s(a.preview['base_version'])} 기준', style: const TextStyle(color: kThinkSub, fontSize: 12)),
        ];
    }
  }

  // ------------------------------------------------------------ 항목 상자
  Widget _line(String text, {Color color = kThinkSub}) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(text, style: TextStyle(color: color, fontSize: 12, height: 1.4)),
      );

  Widget _itemBox({required int i, required bool blocked, required List<Widget> head, required List<Widget> body, Widget? action}) {
    final skipped = _skip.contains(i);
    return Container(
      key: ValueKey('course-item-$i'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: blocked ? kThinkError.withValues(alpha: 0.6) : kThinkBorder),
      ),
      child: Opacity(
        opacity: skipped ? 0.5 : 1,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Tooltip(
              message: blocked ? '반영할 수 없는 항목입니다.' : (skipped ? '눌러서 고르기' : '눌러서 빼기'),
              child: InkWell(
                key: ValueKey('course-item-toggle-$i'),
                onTap: busy || blocked ? null : () => setState(() => skipped ? _skip.remove(i) : _skip.add(i)),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    skipped ? Icons.check_box_outline_blank : Icons.check_box,
                    size: 20,
                    color: blocked ? kThinkBorder : (skipped ? kThinkHint : kThinkAccent),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('$i', style: const TextStyle(color: kThinkHint, fontSize: 12, fontWeight: FontWeight.w800)),
                        ...head,
                      ],
                    ),
                  ),
                  ...body,
                  if (action != null) Align(alignment: Alignment.centerLeft, child: action),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nameText(String name) => Text(name.isEmpty ? '(이름 없음)' : name,
      style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700));

  // ------------------------------------------------------------ 개념 배치
  List<Widget> _placementBody(List<Map<String, dynamic>> items) {
    final units = _maps(a.preview['units']);
    return [
      thinkCodeLabel('항목 ${items.length}개 · 체크한 것만 반영'),
      for (final m in items) _placementItem(m, units),
    ];
  }

  String? _unitPath(List<Map<String, dynamic>> units, String id) {
    for (final u in units) {
      if (_s(u['id']) == id) return _s(u['path']);
    }
    return null;
  }

  Widget _placementItem(Map<String, dynamic> m, List<Map<String, dynamic>> units) {
    final i = _i(m);
    final op = _s(m['op']);
    final changed = _units[i];
    final to = changed == null ? _s(m['unit_path']) : (_unitPath(units, changed) ?? _s(m['unit_path']));
    final elsewhere = [for (final e in _maps(m['elsewhere'])) _s(e['path'])];
    final basis = _s(m['basis']);
    final toColor = changed == null ? kThinkText : kThinkLink;
    return _itemBox(
      i: i,
      blocked: false,
      head: [
        ThinkBadge(_placementOps[op] ?? op, color: _courseOpColor(op)),
        if (op != 'reorder') _nameText(_name(m)),
        if (_s(m['type']).isNotEmpty) ThinkBadge(_s(m['type']), color: kThinkSub),
        if (basis == 'judgment')
          const Tooltip(
            message: '교재 출처로 정하지 않고 Think가 개념 이름·내용을 보고 판단했습니다.',
            child: ThinkBadge('출처 없이 판단', color: kThinkAccent),
          ),
        if (basis == 'source') const ThinkBadge('교재 출처', color: kThinkSuccess),
      ],
      body: [
        switch (op) {
          'place' => _line('→ $to', color: toColor),
          'move' => _line('${_s(m['from_path'])} → $to', color: toColor),
          'remove' => _line('${_s(m['from_path'])}에서 빼기'),
          _ => _line('${_s(m['unit_path'])}: ${_strList(m['names']).join(' → ')}', color: kThinkText),
        },
        if (changed != null) _line('단원을 바꿔 승인합니다(Think 제안: ${_s(m['unit_path'])}).', color: kThinkLink),
        if (_s(m['evidence']).isNotEmpty) _line('근거: ${_s(m['evidence'])}'),
        if (op == 'place' && elsewhere.isNotEmpty) _line('이미 놓인 곳: ${elsewhere.join(' · ')}', color: kThinkHint),
      ],
      action: op == 'place' || op == 'move'
          ? Wrap(
              spacing: 4,
              children: [
                TextButton.icon(
                  key: ValueKey('course-item-unit-$i'),
                  onPressed: busy || _skip.contains(i) ? null : () => _pickUnit(i, units, m),
                  icon: const Icon(Icons.edit_location_alt_outlined, size: 16),
                  label: const Text('단원 바꾸기'),
                  style: TextButton.styleFrom(foregroundColor: kThinkLink, visualDensity: VisualDensity.compact),
                ),
                if (changed != null)
                  TextButton(
                    onPressed: busy ? null : () => setState(() => _units.remove(i)),
                    style: TextButton.styleFrom(foregroundColor: kThinkSub, visualDensity: VisualDensity.compact),
                    child: const Text('제안대로'),
                  ),
              ],
            )
          : null,
    );
  }

  Future<void> _pickUnit(int i, List<Map<String, dynamic>> units, Map<String, dynamic> m) async {
    final suggested = _s(m['unit_id']);
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => _CourseUnitPickDialog(
        title: '"${_name(m)}" 단원 고르기',
        units: units,
        current: _units[i] ?? suggested,
        suggested: suggested,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => picked == suggested ? _units.remove(i) : _units[i] = picked);
  }

  // ------------------------------------------------------------ 개념 고치기
  List<Widget> _libraryBody(List<Map<String, dynamic>> items) => [
        thinkCodeLabel('항목 ${items.length}개 · 체크한 것만 반영'),
        for (final m in items) _libraryItem(m),
      ];

  Widget _libraryItem(Map<String, dynamic> m) {
    final op = _s(m['op']);
    final blocked = m['blocked'] == true;
    return _itemBox(
      i: _i(m),
      blocked: blocked,
      head: [
        ThinkBadge(_libraryOps[op] ?? op, color: _courseOpColor(op)),
        _nameText(_name(m)),
        if (op == 'statement')
          ThinkBadge(
            '${_s(m['role']) == 'core' ? '개념 공통 내용' : '서술'} v${_s(m['version'])}',
            color: kThinkSub,
          ),
        if ((op == 'create' || op == 'delete') && _s(m['type']).isNotEmpty) ThinkBadge(_s(m['type']), color: kThinkSub),
        if (blocked) const ThinkBadge('지울 수 없음', color: kThinkError),
      ],
      body: switch (op) {
        'create' => _createLines(m),
        'edit' => _editLines(m),
        'statement' => _statementLines(m),
        _ => _deleteLines(m),
      },
    );
  }

  String _folderText(List<String> path, int? newFrom) {
    if (newFrom == null || newFrom < 1 || newFrom > path.length) return path.join(' › ');
    final fresh = path.length - newFrom + 1;
    return '${path.join(' › ')} (끝 $fresh단계는 새 폴더)';
  }

  List<Widget> _createLines(Map<String, dynamic> m) {
    final place = _map(m['place']);
    final same = _maps(m['same_name']);
    return [
      _line('폴더: ${_folderText(_strList(m['folder']), (m['new_from'] as num?)?.toInt())}'),
      if (place.isNotEmpty) _line('놓을 단원: ${_s(place['path'])}'),
      if (_s(m['evidence']).isNotEmpty) _line('근거: ${_s(m['evidence'])}'),
      if (same.isNotEmpty) ...[
        _gap(8),
        ThinkNotice(
          icon: Icons.content_copy_outlined,
          color: kThinkAccent,
          text: '같은 이름의 개념이 이미 있습니다: '
              '${same.map((x) => '${_s(x['name'])} (${_strList(x['folder']).join(' › ')})').join(', ')}. '
              '이름이 같다고 같은 개념은 아니니 확인한 뒤 승인하세요.',
        ),
      ],
      _CourseFold(label: '본문 보기', child: _latex(_s(m['content']), kThinkText)),
    ];
  }

  List<Widget> _editLines(Map<String, dynamic> m) {
    final before = _map(m['before']);
    final after = _map(m['after']);
    return [
      if (after.containsKey('name')) _line('이름: ${_s(before['name'])} → ${_s(after['name'])}', color: kThinkText),
      if (after.containsKey('type'))
        _line('유형: ${_fieldText(before['type'])} → ${_fieldText(after['type'])}', color: kThinkText),
      if (after.containsKey('folder'))
        _line('폴더: ${_strList(before['folder']).join(' › ')} → ${_strList(after['folder']).join(' › ')}',
            color: kThinkText),
      if (after.containsKey('content'))
        _CourseFold(label: '본문 전·후 보기', child: _beforeAfter(_s(before['content']), _s(after['content']))),
    ];
  }

  List<Widget> _statementLines(Map<String, dynamic> m) {
    final before = _map(m['before']);
    final after = _map(m['after']);
    final keys = {...before.keys, ...after.keys}.where((k) => _fieldText(before[k]) != _fieldText(after[k])).toList()
      ..sort((x, y) => _statementOrder(x).compareTo(_statementOrder(y)));
    return [
      for (final k in keys)
        if (_fieldText(before[k]).length + _fieldText(after[k]).length <= 80)
          _line('${_statementFields[k] ?? k}: ${_fieldText(before[k])} → ${_fieldText(after[k])}', color: kThinkText)
        else
          _CourseFold(
            label: '${_statementFields[k] ?? k} 전·후 보기',
            child: _beforeAfter(_fieldText(before[k]), _fieldText(after[k])),
          ),
    ];
  }

  int _statementOrder(String k) {
    final i = _statementFields.keys.toList().indexOf(k);
    return i < 0 ? 99 : i;
  }

  List<Widget> _deleteLines(Map<String, dynamic> m) {
    final parts = conceptAttachedText(_map(m['attached']));
    return [
      _line('폴더: ${_strList(m['folder']).join(' › ')}'),
      if (_s(m['excerpt']).isNotEmpty) _line(_s(m['excerpt']), color: kThinkHint),
      if (m['blocked'] == true) ...[
        _gap(8),
        ThinkNotice(
          icon: Icons.block,
          color: kThinkError,
          text: '${parts.isEmpty ? '붙은 것이 있습니다' : '붙은 것: $parts'}. 붙은 것이 하나도 없는 개념만 지울 수 있어 '
              '이 항목은 반영하지 않습니다(삭제 보류).',
        ),
      ],
    ];
  }

  // ------------------------------------------------------------ 개념 검토 기록
  List<Widget> _reviewBody(List<Map<String, dynamic>> items) => [
        thinkCodeLabel('항목 ${items.length}개 · 체크한 것만 기록'),
        for (final m in items) _reviewItem(m),
      ];

  Widget _reviewItem(Map<String, dynamic> m) {
    final scope = _s(m['scope']);
    final outcome = _s(m['outcome']);
    final previous = _map(m['previous']);
    final compared = [for (final c in _maps(m['compared'])) _s(c['name'])];
    final toCompare = [for (final c in _maps(m['to_compare'])) _s(c['name'])];
    final pending = (m['pending_elsewhere'] as num?)?.toInt() ?? 0;
    final fixes = _maps(m['fixes']);
    final type = _s(m['type']);
    return _itemBox(
      i: _i(m),
      blocked: false,
      head: [
        ThinkBadge(_reviewScopes[scope] ?? scope, color: kThinkLink),
        _nameText(_name(m)),
        ThinkBadge(_reviewOutcomes[outcome] ?? outcome, color: _reviewOutcomeColor(outcome)),
      ],
      body: [
        _line('${type.isEmpty ? '유형 없음' : type} · ${_strList(m['folder']).join(' › ')}', color: kThinkHint),
        ..._reviewText('확인한 것', _s(m['checked'])),
        ..._reviewText('찾은 것', _s(m['findings'])),
        ..._reviewText('근거', _s(m['basis'])),
        ..._reviewText('확인 못 한 것', _s(m['unverified']), color: kThinkAccent),
        ..._reviewText('더 할 일', _s(m['follow_up'])),
        if (compared.isNotEmpty) _line('비교한 개념: ${compared.join(', ')}'),
        if (toCompare.isNotEmpty) _line('더 비교할 개념: ${toCompare.join(', ')}', color: kThinkAccent),
        if (outcome == 'merge_needed')
          _line('기록일 뿐 합치거나 지우지 않습니다. 병합을 정할 때까지 삭제를 보류합니다.', color: kThinkError),
        if (previous.isNotEmpty)
          _line(
            '앞선 기록: ${_reviewOutcomes[_s(previous['outcome'])] ?? _s(previous['outcome'])}'
            ' (${_day(previous['reviewed_at'])}${previous['stale'] == true ? ', 그 뒤 내용이 바뀜' : ''})',
            color: kThinkHint,
          ),
        if (pending > 0) _line('같은 개념·범위의 다른 검토 카드 $pending장이 승인 대기 중입니다.', color: kThinkHint),
        if (fixes.isNotEmpty)
          _line(
            '고치기 제안: 함께 낸 ${fixes.map((f) => _s(f['kind']) == 'concept_placement_change' ? '과정 배치' : '개념 고치기').toSet().join('·')}'
            ' 카드 ${fixes.length}장. 그 카드를 승인해야 반영되고, 반영 뒤 이 범위를 다시 확인해야 완료입니다.',
            color: kThinkAccent,
          ),
      ],
    );
  }

  // ------------------------------------------------------------ 개념 관계 고치기
  List<Widget> _relationBody(List<Map<String, dynamic>> items) => [
        thinkCodeLabel('항목 ${items.length}개 · 체크한 것만 반영 · 관계는 "A(출발) → B(기준)"으로 읽음'),
        for (final m in items) _relationItem(m),
      ];

  String _relationSentence(Map<String, dynamic> state, String a, String b) {
    final kind = ConceptRelationKindX.fromDb(_s(state['kind']));
    final context = _s(state['context']);
    if (kind == null) return '"$a" → "$b" (${_s(state['kind'])})';
    return kind.sentence(a, b, context.isEmpty ? null : context);
  }

  String _relationKindLabel(Map<String, dynamic> state) {
    final kind = ConceptRelationKindX.fromDb(_s(state['kind']));
    return kind?.label ?? _s(state['kind']);
  }

  String _relationEnds(Map<String, dynamic> m) =>
      '"${_s(_map(m['from'])['name'])}" → "${_s(_map(m['to'])['name'])}"';

  Widget _relationItem(Map<String, dynamic> m) {
    final op = _s(m['op']);
    final from = _map(m['from']);
    final to = _map(m['to']);
    final a = _s(from['name']);
    final b = _s(to['name']);
    final before = _map(m['before']);
    final after = _map(m['after']);
    final pending = (m['pending_elsewhere'] as num?)?.toInt() ?? 0;
    final basis = _s((op == 'remove' ? before : after)['basis']);
    String end(String label, Map<String, dynamic> c) {
      final folder = _strList(c['folder']);
      return '$label: ${_s(c['name'])}${folder.isEmpty ? '' : ' · ${folder.join(' › ')}'} · ${_s(c['id'])}';
    }

    return _itemBox(
      i: _i(m),
      blocked: false,
      head: [
        ThinkBadge(_relationOps[op] ?? op, color: _relationOpColor(op)),
        ThinkBadge(_relationKindLabel(op == 'remove' ? before : after), color: kThinkSub),
        _nameText(_relationEnds(m)),
      ],
      body: [
        _line(end('A(출발)', from), color: kThinkHint),
        _line(end('B(기준)', to), color: kThinkHint),
        if (op == 'change') ...[
          _line('지금: ${_relationSentence(before, a, b)}'),
          _line('바꾼 뒤: ${_relationSentence(after, a, b)}', color: kThinkText),
          if (_s(before['note']) != _s(after['note']))
            _line('메모: ${_fieldText(before['note'])} → ${_fieldText(after['note'])}', color: kThinkText),
        ] else if (op == 'remove') ...[
          _line('뺄 관계: ${_relationSentence(before, a, b)}', color: kThinkText),
          _line('관계만 빼고 두 개념은 그대로 둡니다. 뺀 일은 관계 이력에 남습니다.', color: kThinkHint),
        ] else
          _line('넣을 관계: ${_relationSentence(after, a, b)}', color: kThinkText),
        if (op != 'add' && before.isNotEmpty && before['decided'] != true)
          _line('지금 관계는 결정 기록이 없습니다(이 기능 전에 생긴 관계).', color: kThinkHint),
        ..._reviewText('근거', basis),
        ..._reviewText('불확실한 점', _s(m['uncertainty']), color: kThinkAccent),
        ..._reviewText('이유', _s(m['reason'])),
        if (m['open_same_concept_review'] == true) ...[
          _gap(8),
          const ThinkNotice(
            icon: Icons.flag_outlined,
            color: kThinkAccent,
            text: '두 개념에 "같은 개념인지 검토 필요" 표시가 열려 있습니다. 같은 개념인지 먼저 판단하세요. '
                '이 관계를 승인해도 그 표시는 닫히지 않습니다.',
          ),
        ],
        if (pending > 0) _line('같은 관계나 두 개념을 다룬 다른 관계 카드 항목 $pending개가 승인 대기 중입니다.', color: kThinkHint),
      ],
    );
  }

  String _day(Object? v) {
    final s = _s(v);
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  List<Widget> _reviewText(String label, String text, {Color color = kThinkText}) {
    if (text.isEmpty) return const [];
    final runes = text.runes;
    if (runes.length <= 160) return [_line('$label: $text', color: color)];
    return [
      _line('$label: ${String.fromCharCodes(runes.take(120))}…', color: color),
      _CourseFold(label: '$label 전체 보기', child: _latex(text, color)),
    ];
  }

  Widget _latex(String text, Color color) => SelectionArea(
        child: LatexTextRenderer(
          text,
          dollarMath: true,
          style: TextStyle(color: color, fontSize: 12, height: 1.5),
          crossAxisAlignment: CrossAxisAlignment.start,
        ),
      );

  Widget _beforeAfter(String before, String after) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('전', style: TextStyle(color: kThinkHint, fontSize: 12, fontWeight: FontWeight.w700)),
          _latex(before, kThinkHint),
          _gap(8),
          const Text('후', style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
          _latex(after, kThinkText),
        ],
      );

  // ------------------------------------------------------------ 과정 탐색도 고치기·새 과정
  List<Widget> _mapBody() {
    final lines = _maps(a.preview['lines']);
    final kept = (a.preview['archived_placements'] as num?)?.toInt() ?? 0;
    final action = _s(a.payload['course_action']);
    return [
      if (action == 'archive')
        const ThinkNotice(
          icon: Icons.archive_outlined,
          color: kThinkAccent,
          text: '과정을 목록에서 뺍니다(지우지 않음). "보관한 과정"에서 되살릴 수 있습니다.',
        )
      else if (action == 'restore')
        const ThinkNotice(icon: Icons.unarchive_outlined, color: kThinkLink, text: '보관한 과정을 목록으로 되돌립니다.')
      else ...[
        thinkCodeLabel('바꿀 것 ${lines.length}건'),
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('· ${_s(l['text'])}', style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
          ),
      ],
      if (kept > 0) ...[
        _gap(8),
        ThinkNotice(
          icon: Icons.menu_book_outlined,
          color: kThinkAccent,
          text: '보관하는 단원에 놓인 개념 자리 $kept곳이 목록에서 빠집니다. 지우지 않고, 단원을 되살리면 돌아옵니다.',
        ),
      ],
    ];
  }

  List<Widget> _createBody() {
    final units = _maps(a.preview['units']);
    return [
      thinkCodeLabel(units.isEmpty ? '단원 없이 만듦' : '단원 ${units.length}개'),
      if (units.isNotEmpty)
        Container(
          constraints: const BoxConstraints(maxHeight: 260),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: kThinkBorder)),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final u in units)
                  Padding(
                    padding: EdgeInsets.only(left: (((u['depth'] as num?)?.toInt() ?? 1) - 1) * 16.0, bottom: 4),
                    child: Text(
                      _s(u['name']),
                      style: TextStyle(
                        color: (u['depth'] as num?) == 3 ? kThinkSub : kThinkText,
                        fontSize: 13,
                        fontWeight: (u['depth'] as num?) == 1 ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
    ];
  }

  List<Widget> _dirtyWarning() {
    final id = a.courseId;
    if (a.kind != ThinkActionKind.courseMapChange || id == null || !CourseMapController.instance.isDirty(id)) {
      return const [];
    }
    return [
      _gap(8),
      const ThinkNotice(
        icon: Icons.edit_note,
        color: kThinkAccent,
        text: '교육과정 흐름에 이 과정의 저장하지 않은 편집이 있습니다. 승인하면 그 편집은 저장할 때 막히고, 최신 저장본을 불러와야 합니다.',
      ),
    ];
  }

  String _approveNote() => switch (a.kind) {
        ThinkActionKind.conceptPlacementChange =>
          '체크한 항목만 반영합니다. 막힌 항목이 있어도 나머지는 반영되고, 결과가 항목별로 남습니다. 개념 본문·출처는 바뀌지 않습니다.',
        ThinkActionKind.conceptLibraryChange =>
          '체크한 항목은 승인하면 바로 확정됩니다(고친 기록에 "Think 카드 승인: 이유"가 남습니다). 출처·원문 인용은 바꾸지 않고, 지우기는 붙은 것이 없는 개념만 됩니다.',
        ThinkActionKind.conceptReviewRecord =>
          '체크한 항목만 검토 기록으로 남습니다. 개념 본문·폴더·관계는 바뀌지 않고, "문제 못 찾음"은 검증됐다는 뜻이 아닙니다. '
              '제안한 뒤 그 개념이나 비교한 개념이 바뀐 항목은 남지 않습니다. 검토 기록이 붙은 개념은 지울 수 없게 됩니다.',
        ThinkActionKind.conceptRelationChange =>
          '체크한 항목만 반영합니다. 빼기는 관계만 지우고 개념은 그대로 둡니다. 제안한 뒤 두 개념 중 하나의 글이 바뀌었거나 '
              '그 관계를 다른 곳에서 고쳤으면 그 항목은 반영하지 않습니다. 반영한 관계에는 "Think 카드 승인" 결정이 남습니다.',
        ThinkActionKind.courseMapCreate => '승인하면 과정을 만들고 단원을 저장합니다. 과정 목록 맨 끝에 들어갑니다.',
        _ => '승인하면 과정 탐색도에 바로 저장합니다. 제안한 뒤 다른 곳에서 이 과정을 저장했으면 승인이 막힙니다.',
      };

  Future<void> _approve() async {
    final overrides = <String, dynamic>{
      if (a.kind.hasItems && _skip.isNotEmpty) 'skip': (_skip.toList()..sort()),
      if (a.kind == ThinkActionKind.conceptPlacementChange && _units.isNotEmpty)
        'units': {for (final e in _units.entries) '${e.key}': e.value},
    };
    await run(() async {
      final saved = await _think.applyCourseThinkAction(a, overrides: overrides);
      if (!mounted) return;
      if (saved.status == ThinkActionStatus.proposed && (saved.error ?? '').isNotEmpty) {
        showThinkSnack(
          context,
          '지난 승인에서 반영하지 못했습니다. 카드는 그대로 두었으니 다시 승인할 수 있습니다. ${ThinkApi.codeErrorMessage(saved.error!)}',
          error: true,
        );
        return;
      }
      final failed = saved.courseResultCount('failed');
      showThinkSnack(context, _doneText(saved), error: failed > 0);
    });
  }

  String _doneText(ThinkAction saved) {
    if (saved.kind.hasItems) {
      final failed = saved.courseResultCount('failed');
      return '반영 ${saved.courseResultCount('applied')}개${failed > 0 ? ', 반영 못 함 $failed개(카드에 이유)' : ''}';
    }
    if (saved.kind == ThinkActionKind.courseMapCreate) return '"${_s(saved.preview['name'])}" 과정을 만들었습니다.';
    if (saved.result?['archived'] == true) return '과정을 보관했습니다.';
    if (saved.result?['restored'] == true) return '과정을 되살렸습니다.';
    return '과정 탐색도를 저장했습니다(v${_s(saved.result?['version'])}).';
  }

  Widget _applied() {
    final String text;
    if (a.kind.hasItems) {
      final failed = a.courseResultCount('failed');
      final skipped = a.courseResultCount('skipped');
      text = '${a.kind.label}$_subject · 반영 ${a.courseResultCount('applied')}개'
          '${failed > 0 ? ' · 못 함 $failed개' : ''}${skipped > 0 ? ' · 뺌 $skipped개' : ''}';
    } else if (a.kind == ThinkActionKind.courseMapCreate) {
      text = '새 과정 "${_s(a.preview['name'])}" · 만듦(단원 ${_s(a.result?['units'])}개)';
    } else if (a.result?['archived'] == true) {
      text = '과정 보관$_subject · 보관함';
    } else if (a.result?['restored'] == true) {
      text = '과정 되살리기$_subject · 되살림';
    } else {
      text = '${a.kind.label}$_subject · 저장함 v${_s(a.result?['version'])}';
    }
    final results = a.courseItemResults;
    final failed = [
      for (final m in a.courseItems)
        if (_s(results[_i(m)]?['status']) == 'failed') m,
    ];
    if (failed.isEmpty) return _ClosedLine(icon: Icons.check_circle_outline, text: text);
    String what(Map<String, dynamic> m) => switch (a.kind) {
          ThinkActionKind.conceptPlacementChange => _placementOps[_s(m['op'])] ?? _s(m['op']),
          ThinkActionKind.conceptReviewRecord => _reviewScopes[_s(m['scope'])] ?? _s(m['scope']),
          ThinkActionKind.conceptRelationChange => '${_relationOps[_s(m['op'])] ?? _s(m['op'])} ${_relationEnds(m)}',
          _ => _libraryOps[_s(m['op'])] ?? _s(m['op']),
        };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ClosedLine(icon: Icons.check_circle_outline, text: text),
        for (final m in failed)
          Padding(
            padding: const EdgeInsets.only(left: 22, bottom: 2),
            child: Text(
              '${_i(m)}. ${what(m)}${_name(m).isEmpty ? '' : ' ${_name(m)}'}: '
              '${_courseItemError(_s(results[_i(m)]?['code']))}',
              style: const TextStyle(color: kThinkError, fontSize: 12),
            ),
          ),
      ],
    );
  }
}

/// 누르면 펼쳐 보는 칸.
class _CourseFold extends StatefulWidget {
  const _CourseFold({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  State<_CourseFold> createState() => _CourseFoldState();
}

class _CourseFoldState extends State<_CourseFold> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => _open = !_open),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: Text(_open ? '접기' : widget.label, style: const TextStyle(color: kThinkLink, fontSize: 12)),
          ),
        ),
        if (_open) widget.child,
      ],
    );
  }
}

/// 배치 카드의 단원 바꾸기. 제안 때 서버가 준 단원 목록(살아 있는 단원)에서 고른다.
class _CourseUnitPickDialog extends StatefulWidget {
  const _CourseUnitPickDialog({required this.title, required this.units, required this.current, required this.suggested});

  final String title;
  final List<Map<String, dynamic>> units;
  final String current;
  final String suggested;

  @override
  State<_CourseUnitPickDialog> createState() => _CourseUnitPickDialogState();
}

class _CourseUnitPickDialogState extends State<_CourseUnitPickDialog> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.text.trim();
    final list = q.isEmpty ? widget.units : widget.units.where((u) => _s(u['path']).contains(q)).toList();
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text(widget.title, style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 520,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              style: const TextStyle(color: kThinkText, fontSize: 14),
              decoration: thinkInputDecoration(label: '단원 찾기', dense: true),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: list.isEmpty
                  ? const Text('맞는 단원이 없습니다.', style: TextStyle(color: kThinkHint, fontSize: 12))
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final u = list[i];
                        final id = _s(u['id']);
                        final path = _s(u['path']);
                        final depth = (u['depth'] as num?)?.toInt() ?? 1;
                        final name = path.split(' › ').last;
                        return InkWell(
                          onTap: () => Navigator.pop(context, id),
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(8 + (q.isEmpty ? (depth - 1) * 16.0 : 0), 8, 8, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Tooltip(
                                    message: path,
                                    child: Text(q.isEmpty ? name : path,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            color: kThinkText, fontSize: 13, fontWeight: FontWeight.w600)),
                                  ),
                                ),
                                if (id == widget.suggested) ...[
                                  const SizedBox(width: 8),
                                  const ThinkBadge('Think 제안', color: kThinkSub),
                                ],
                                if (id == widget.current) ...[
                                  const SizedBox(width: 8),
                                  const ThinkBadge('고름', color: kThinkLink),
                                ],
                              ],
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
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
      ],
    );
  }
}
