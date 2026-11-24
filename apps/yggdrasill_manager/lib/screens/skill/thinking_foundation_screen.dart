import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/thinking_foundation_service.dart';
import '../../widgets/latex_text_renderer.dart';
import '../think/think_style.dart';

/// 개념 메뉴 오른쪽 시트로 열리는 '수학적 사고의 토대(C)' 관리 화면.
/// C1 사고의 규범(4) · C2 판단의 규범(4) · C3 탐구의 태도(4)를 관리한다.
class ThinkingFoundationScreen extends StatefulWidget {
  const ThinkingFoundationScreen({super.key, this.service});

  final ThinkingFoundationService? service;

  @override
  State<ThinkingFoundationScreen> createState() => _ThinkingFoundationScreenState();
}

class _ExampleDraft {
  _ExampleDraft({
    this.id = '',
    String initialText = '',
    this.relatedConceptIds = const [],
    this.relatedQuestionIds = const [],
  }) : controller = TextEditingController(text: initialText);

  final String id;
  final TextEditingController controller;
  final List<String> relatedConceptIds;
  final List<String> relatedQuestionIds;

  void dispose() => controller.dispose();
}

class _ThinkingFoundationScreenState extends State<ThinkingFoundationScreen> {
  late final ThinkingFoundationService _svc = widget.service ?? ThinkingFoundationService();

  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _notice;
  bool _showSystemGuide = false;

  List<ThinkingFoundationItem> _items = const [];

  /// 0: 전체, 1: C1, 2: C2, 3: C3
  int _tab = 0;
  String _search = '';
  final Set<String> _closedGroups = <String>{};

  String? _selectedId;
  bool _editing = false;
  bool _creatingNew = false;

  String _formGroupCode = 'C1';
  final _codeCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _definitionCtrl = TextEditingController();
  final _goalsCtrl = TextEditingController();
  final _principleCtrl = TextEditingController();
  final _observationCtrl = TextEditingController();
  final _keywordsCtrl = TextEditingController();
  final _sortOrderCtrl = TextEditingController(text: '1');
  bool _formActive = true;
  final List<_ExampleDraft> _exampleDrafts = <_ExampleDraft>[];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _titleCtrl.dispose();
    _definitionCtrl.dispose();
    _goalsCtrl.dispose();
    _principleCtrl.dispose();
    _observationCtrl.dispose();
    _keywordsCtrl.dispose();
    _sortOrderCtrl.dispose();
    for (final d in _exampleDrafts) {
      d.dispose();
    }
    super.dispose();
  }

  String? get _activeGroupFilter => switch (_tab) {
        1 => 'C1',
        2 => 'C2',
        3 => 'C3',
        _ => null,
      };

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _svc.fetchAll();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _ensureSelection();
      });
    } catch (e) {
      if (!mounted) return;
      final raw = '$e';
      final missingMigration = raw.contains('thinking_foundation_overview') || raw.contains('PGRST202');
      setState(() {
        _loading = false;
        _error = missingMigration
            ? '사고의 토대 DB 마이그레이션(20261123220000_thinking_foundations.sql)이 아직 서버에 반영되지 않았습니다.'
            : '사고의 토대 데이터를 불러오지 못했습니다: $e';
      });
    }
  }

  List<ThinkingFoundationItem> get _filteredItems {
    final groupFilter = _activeGroupFilter;
    return [
      for (final item in _items)
        if ((groupFilter == null || item.groupCode == groupFilter) && item.matchesQuery(_search)) item,
    ];
  }

  void _ensureSelection() {
    if (_creatingNew) return;
    final filtered = _filteredItems;
    if (_selectedId != null && _items.any((x) => x.id == _selectedId)) {
      if (_editing) {
        final hit = _items.where((x) => x.id == _selectedId).firstOrNull;
        if (hit != null) _populateForm(hit);
      }
      return;
    }
    if (filtered.isNotEmpty) {
      _selectedId = filtered.first.id;
    } else if (_items.isNotEmpty) {
      _selectedId = _items.first.id;
    } else {
      _selectedId = null;
    }
  }

  void _resetExampleDrafts(List<ThinkingFoundationExample> examples) {
    for (final d in _exampleDrafts) {
      d.dispose();
    }
    _exampleDrafts.clear();
    if (examples.isEmpty) {
      for (var i = 0; i < 3; i++) {
        _exampleDrafts.add(_ExampleDraft());
      }
      return;
    }
    for (final ex in examples) {
      _exampleDrafts.add(
        _ExampleDraft(
          id: ex.id,
          initialText: ex.content,
          relatedConceptIds: ex.relatedConceptIds,
          relatedQuestionIds: ex.relatedQuestionIds,
        ),
      );
    }
  }

  void _populateForm(ThinkingFoundationItem item) {
    _formGroupCode = item.groupCode;
    _codeCtrl.text = item.code;
    _titleCtrl.text = item.title;
    _definitionCtrl.text = item.definition;
    _goalsCtrl.text = item.learningGoals.join('\n');
    _principleCtrl.text = item.teachingPrinciple;
    _observationCtrl.text = item.observationCriteria;
    _keywordsCtrl.text = item.keywords.join(', ');
    _sortOrderCtrl.text = '${item.sortOrder}';
    _formActive = item.isActive;
    _resetExampleDrafts(item.examples);
  }

  void _startCreate() {
    final defaultGroup = _activeGroupFilter ?? 'C1';
    final nextOrder = _items.isEmpty
        ? 1
        : (_items.map((x) => x.sortOrder).reduce((a, b) => a > b ? a : b) + 1);
    setState(() {
      _creatingNew = true;
      _editing = true;
      _notice = null;
      _formGroupCode = defaultGroup;
      _codeCtrl.text = '$defaultGroup-${nextOrder.toString().padLeft(2, '0')}';
      _titleCtrl.clear();
      _definitionCtrl.clear();
      _goalsCtrl.clear();
      _principleCtrl.clear();
      _observationCtrl.clear();
      _keywordsCtrl.clear();
      _sortOrderCtrl.text = '$nextOrder';
      _formActive = true;
      _resetExampleDrafts(const []);
    });
  }

  void _startEdit(ThinkingFoundationItem item) {
    setState(() {
      _creatingNew = false;
      _editing = true;
      _selectedId = item.id;
      _notice = null;
      _populateForm(item);
    });
  }

  void _cancelEdit() {
    setState(() {
      _creatingNew = false;
      _editing = false;
      _notice = null;
      _ensureSelection();
    });
  }

  Future<void> _saveCurrent() async {
    final code = _codeCtrl.text.trim();
    final title = _titleCtrl.text.trim();
    if (code.isEmpty || title.isEmpty) {
      setState(() => _notice = '고유 코드와 역량 이름을 입력해 주세요.');
      return;
    }
    final examples = <ThinkingFoundationExample>[];
    for (var i = 0; i < _exampleDrafts.length; i++) {
      final d = _exampleDrafts[i];
      final text = d.controller.text.trim();
      if (text.isEmpty) continue;
      examples.add(
        ThinkingFoundationExample(
          id: d.id,
          exampleOrder: examples.length + 1,
          content: text,
          relatedConceptIds: d.relatedConceptIds,
          relatedQuestionIds: d.relatedQuestionIds,
        ),
      );
    }
    if (examples.isEmpty) {
      setState(() => _notice = '수학적 예시를 최소 1개 이상 입력해 주세요 (권장 3개).');
      return;
    }
    final goals = [
      for (final line in _goalsCtrl.text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    final keywords = [
      for (final token in _keywordsCtrl.text.split(','))
        if (token.trim().isNotEmpty) token.trim(),
    ];
    final sortOrder = int.tryParse(_sortOrderCtrl.text.trim()) ?? 0;

    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      await _svc.save(
        id: _creatingNew ? null : _selectedId,
        code: code,
        groupCode: _formGroupCode,
        title: title,
        definition: _definitionCtrl.text.trim(),
        learningGoals: goals,
        teachingPrinciple: _principleCtrl.text.trim(),
        observationCriteria: _observationCtrl.text.trim(),
        keywords: keywords,
        examples: examples,
        sortOrder: sortOrder,
        isActive: _formActive,
      );
      final wasCreate = _creatingNew;
      final savedCode = code;
      final refreshed = await _svc.fetchAll();
      if (!mounted) return;
      final matched = refreshed.where((x) => x.code == savedCode).firstOrNull;
      setState(() {
        _items = refreshed;
        _saving = false;
        _creatingNew = false;
        _editing = false;
        if (matched != null) _selectedId = matched.id;
        _notice = wasCreate ? '새 사고의 토대 역량을 등록했습니다.' : '변경 사항을 저장했습니다.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '저장 실패: $e';
      });
    }
  }

  Future<void> _deleteCurrent(ThinkingFoundationItem item) async {
    final ok = await confirmThink(
      context,
      title: '역량 삭제',
      message: '[${item.code}] ${item.title} 항목과 연결된 예시를 삭제할까요?\n기존 문항 연결이 있으면 함께 해제됩니다.',
      confirmLabel: '삭제',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      await _svc.delete(item.id);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _editing = false;
        _creatingNew = false;
        _selectedId = null;
        _notice = '삭제했습니다.';
      });
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '삭제 실패: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c1Count = _items.where((x) => x.groupCode == 'C1').length;
    final c2Count = _items.where((x) => x.groupCode == 'C2').length;
    final c3Count = _items.where((x) => x.groupCode == 'C3').length;

    return ThinkPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.compass_calibration_outlined, size: 18, color: kThinkAccent),
                const SizedBox(width: 8),
                const Text(
                  '사고의 토대',
                  style: TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: ThinkPillTabs(
                      labels: [
                        '전체 (${_items.length})',
                        'C1 규범 ($c1Count)',
                        'C2 판단 ($c2Count)',
                        'C3 태도 ($c3Count)',
                      ],
                      icons: const [
                        Icons.layers_outlined,
                        Icons.rule_outlined,
                        Icons.fact_check_outlined,
                        Icons.explore_outlined,
                      ],
                      selected: _tab,
                      onSelected: (i) => setState(() {
                        _tab = i;
                        _creatingNew = false;
                        _editing = false;
                        _ensureSelection();
                      }),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                ThinkToggleChip(
                  label: 'A·B·C 체계',
                  icon: Icons.info_outline,
                  selected: _showSystemGuide,
                  tooltip: '전체 수학 교육 체계(A 지식 · B 사고 · C 사고의 토대) 설명 보기',
                  onChanged: (v) => setState(() => _showSystemGuide = v),
                ),
                IconButton(
                  tooltip: '새로고침',
                  onPressed: _loading ? null : () => unawaited(_load()),
                  icon: const Icon(Icons.refresh, color: kThinkSub, size: 20),
                ),
              ],
            ),
          ),
          const Divider(color: kThinkBorder, height: 1),
          if (_showSystemGuide) _buildSystemGuideBanner(),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: ThinkNotice(
                text: _notice!,
                color: _notice!.startsWith('저장 실패') || _notice!.startsWith('삭제 실패')
                    ? kThinkError
                    : kThinkAccent,
                icon: Icons.info_outline,
                onClose: () => setState(() => _notice = null),
              ),
            ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildSystemGuideBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kThinkQuote,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kThinkBorder),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '전체 수학 교육 체계 (실용적 관찰·지도 분류)',
            style: TextStyle(color: kThinkText, fontSize: 12.5, fontWeight: FontWeight.w800),
          ),
          SizedBox(height: 6),
          Text(
            '• A. 지식 (무엇을 알아야 하는가): A1 개념 지식(정의·정리·공식·관계) · A2 절차 지식(계산·식 변형·표준 절차)\n'
            '• B. 사고 (어떻게 해결하는가): B1 범용 사고틀 · B2 실전 알고리즘 · B3 사고 조절(전략 선택·효율성 점검·전환·검토)\n'
            '• C. 사고의 토대 (어떤 원칙과 태도로 생각하는가): C1 사고의 규범 · C2 판단의 규범 · C3 탐구의 태도 (난이도 점수 비부여)',
            style: TextStyle(color: kThinkSub, fontSize: 12, height: 1.45),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: kThinkAccent));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: kThinkError, fontSize: 13.5, height: 1.4),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () => unawaited(_load()),
                style: thinkPrimaryButton(),
                child: const Text('다시 시도'),
              ),
            ],
          ),
        ),
      );
    }

    final filtered = _filteredItems;
    final filtering = _search.trim().isNotEmpty;
    final selected = _creatingNew ? null : _items.where((x) => x.id == _selectedId).firstOrNull;
    final groupFilter = _activeGroupFilter;
    final visibleGroups = [
      for (final g in kThinkingFoundationGroups)
        if (groupFilter == null || g.code == groupFilter) g,
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _startCreate,
                      style: thinkOutlineButton().copyWith(
                        padding: const WidgetStatePropertyAll(
                          EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('토대 역량 추가'),
                    ),
                    SizedBox(
                      width: 260,
                      height: 36,
                      child: TextField(
                        onChanged: (v) => setState(() => _search = v),
                        style: const TextStyle(color: kThinkText, fontSize: 13),
                        decoration: thinkInputDecoration(
                          hint: '이름, 정의, 키워드, 예시 검색...',
                          dense: true,
                          prefixIcon: const Icon(Icons.search, size: 18, color: kThinkSub),
                        ),
                      ),
                    ),
                    Text(
                      '표시 ${filtered.length}개',
                      style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Divider(color: kThinkBorder, height: 1),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(
                          child: Text(
                            '조건에 맞는 사고의 토대 항목이 없습니다.',
                            style: TextStyle(color: kThinkSub, fontSize: 13),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
                          children: [
                            for (final g in visibleGroups)
                              ..._buildGroupSection(
                                g,
                                [for (final x in filtered) if (x.groupCode == g.code) x],
                                hideEmpty: filtering,
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
        const VerticalDivider(color: kThinkBorder, width: 1),
        SizedBox(
          width: 390,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _editing || _creatingNew ? _buildEditPane(selected) : _buildDetailPane(selected),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildGroupSection(
    ThinkingFoundationGroupInfo group,
    List<ThinkingFoundationItem> items, {
    required bool hideEmpty,
  }) {
    if (items.isEmpty && hideEmpty) return const [];
    final open = !_closedGroups.contains(group.code);
    return [
      _treeRow(
        key: ValueKey('foundation-group-${group.code}'),
        indent: 0,
        selected: false,
        onTap: () => setState(() {
          if (open) {
            _closedGroups.add(group.code);
          } else {
            _closedGroups.remove(group.code);
          }
        }),
        child: Row(
          children: [
            Icon(open ? Icons.expand_more : Icons.chevron_right, size: 18, color: kThinkSub),
            const SizedBox(width: 4),
            Expanded(
              child: Tooltip(
                message: group.subtitle,
                child: Text(
                  '${group.code}. ${group.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            Text(
              '${items.length}',
              style: const TextStyle(color: kThinkHint, fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
      if (open)
        for (final item in items) _buildItemRow(item),
    ];
  }

  Widget _buildItemRow(ThinkingFoundationItem item) {
    final selected = !_creatingNew && _selectedId == item.id;
    return _treeRow(
      key: ValueKey('foundation-item-${item.code}'),
      indent: 28,
      selected: selected,
      onTap: () => setState(() {
        _creatingNew = false;
        _editing = false;
        _selectedId = item.id;
      }),
      child: Row(
        children: [
          Text(
            item.code,
            style: TextStyle(
              color: selected ? kThinkAccent : kThinkHint,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: item.isActive ? kThinkText : kThinkHint,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (!item.isActive) const ThinkBadge('비활성', color: kThinkHint),
        ],
      ),
    );
  }

  Widget _buildDetailPane(ThinkingFoundationItem? item) {
    if (item == null) {
      return const Center(
        child: Text(
          '목록에서 사고의 토대 역량을 선택하거나 새로 추가하세요.',
          textAlign: TextAlign.center,
          style: TextStyle(color: kThinkSub, fontSize: 13),
        ),
      );
    }

    return ThinkingFoundationDetailBody(
      item: item,
      trailingAction: OutlinedButton.icon(
        onPressed: () => _startEdit(item),
        style: thinkOutlineButton().copyWith(
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10, vertical: 6)),
          visualDensity: VisualDensity.compact,
        ),
        icon: const Icon(Icons.edit_outlined, size: 15),
        label: const Text('편집', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      ),
    );
  }

  Widget _buildEditPane(ThinkingFoundationItem? selected) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _creatingNew ? '새 사고의 토대 역량 추가' : '${selected?.code ?? ''} 편집',
                  style: const TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
              TextButton(
                onPressed: _saving ? null : _cancelEdit,
                child: const Text('취소', style: TextStyle(color: kThinkSub, fontSize: 12.5)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('분류 그룹', style: TextStyle(color: kThinkSub, fontSize: 12)),
                    const SizedBox(height: 4),
                    DropdownButtonFormField<String>(
                      initialValue: _formGroupCode,
                      dropdownColor: kThinkPanel,
                      style: const TextStyle(color: kThinkText, fontSize: 13),
                      decoration: thinkInputDecoration(dense: true),
                      items: [
                        for (final g in kThinkingFoundationGroups)
                          DropdownMenuItem(
                            value: g.code,
                            child: Text('${g.code}. ${g.title}'),
                          ),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _formGroupCode = v);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('고유 ID', style: TextStyle(color: kThinkSub, fontSize: 12)),
                    const SizedBox(height: 4),
                    TextField(
                      controller: _codeCtrl,
                      style: const TextStyle(color: kThinkText, fontSize: 12.5, fontFamily: 'monospace'),
                      decoration: thinkInputDecoration(hint: 'C1-01', dense: true),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('순서', style: TextStyle(color: kThinkSub, fontSize: 12)),
                    const SizedBox(height: 4),
                    TextField(
                      controller: _sortOrderCtrl,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: kThinkText, fontSize: 12.5),
                      decoration: thinkInputDecoration(hint: '1', dense: true),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text('역량 이름', style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 4),
          TextField(
            controller: _titleCtrl,
            style: const TextStyle(color: kThinkText, fontSize: 13),
            decoration: thinkInputDecoration(hint: '예: 의미의 명확성', dense: true),
          ),
          const SizedBox(height: 10),
          const Text('정의', style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 4),
          TextField(
            controller: _definitionCtrl,
            minLines: 2,
            maxLines: 4,
            style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.4),
            decoration: thinkInputDecoration(hint: '역량의 핵심 의미를 서술합니다.'),
          ),
          const SizedBox(height: 10),
          const Text('교육 목표 (줄바꿈으로 구분)', style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 4),
          TextField(
            controller: _goalsCtrl,
            minLines: 3,
            maxLines: 5,
            style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.4),
            decoration: thinkInputDecoration(hint: '한 줄에 하나씩 교육 목표를 입력합니다.'),
          ),
          const SizedBox(height: 10),
          const Text('지도 원칙 (핵심 발문)', style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 4),
          TextField(
            controller: _principleCtrl,
            minLines: 1,
            maxLines: 3,
            style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.4),
            decoration: thinkInputDecoration(hint: '예: 지금 사용한 말이나 기호가 정확히 무엇을 의미하지?'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Expanded(
                child: Text(
                  '개별 수학적 예시 (LaTeX \\(...\\) 지원)',
                  style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                onPressed: _exampleDrafts.length >= 10
                    ? null
                    : () => setState(() => _exampleDrafts.add(_ExampleDraft())),
                style: TextButton.styleFrom(
                  foregroundColor: kThinkAccent,
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.add, size: 15),
                label: const Text('예시 추가', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          for (var i = 0; i < _exampleDrafts.length; i++) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 10, right: 6),
                  child: Text(
                    '${i + 1}.',
                    style: const TextStyle(color: kThinkAccent, fontSize: 12.5, fontWeight: FontWeight.w800),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _exampleDrafts[i].controller,
                    minLines: 2,
                    maxLines: 4,
                    style: const TextStyle(color: kThinkText, fontSize: 12.5, height: 1.4),
                    decoration: thinkInputDecoration(hint: '예시 ${i + 1} 내용을 입력하세요.', dense: true),
                  ),
                ),
                if (_exampleDrafts.length > 1)
                  IconButton(
                    tooltip: '이 예시 제거',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() {
                      final removed = _exampleDrafts.removeAt(i);
                      removed.dispose();
                    }),
                    icon: const Icon(Icons.close, size: 16, color: kThinkSub),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          const Text('학생 관찰 기준', style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 4),
          TextField(
            controller: _observationCtrl,
            minLines: 2,
            maxLines: 4,
            style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.4),
            decoration: thinkInputDecoration(hint: '실제 풀이·발화·수정 행동에서 무엇을 관찰할지 적습니다.'),
          ),
          const SizedBox(height: 10),
          const Text('관련 키워드 (쉼표 구분)', style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 4),
          TextField(
            controller: _keywordsCtrl,
            style: const TextStyle(color: kThinkText, fontSize: 12.5),
            decoration: thinkInputDecoration(hint: '예: 정의역, 분모 0, 성립 조건', dense: true),
          ),
          const SizedBox(height: 10),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            activeThumbColor: kThinkAccent,
            title: const Text('활성화 상태', style: TextStyle(color: kThinkText, fontSize: 13)),
            value: _formActive,
            onChanged: (v) => setState(() => _formActive = v),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (!_creatingNew && selected != null)
                TextButton.icon(
                  onPressed: _saving ? null : () => unawaited(_deleteCurrent(selected)),
                  icon: const Icon(Icons.delete_outline, size: 18, color: kThinkError),
                  label: const Text('삭제', style: TextStyle(color: kThinkError)),
                ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _saving ? null : () => unawaited(_saveCurrent()),
                style: thinkPrimaryButton(),
                icon: const Icon(Icons.save_outlined, size: 18),
                label: Text(_creatingNew ? '추가 저장' : '변경 저장'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _treeRow({
    required Key key,
    required double indent,
    required bool selected,
    required VoidCallback? onTap,
    required Widget child,
  }) {
    return SizedBox(
      height: 36,
      child: Padding(
        padding: EdgeInsets.only(left: indent, right: 4),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: key,
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: selected ? kThinkAccent.withValues(alpha: 0.16) : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: selected ? kThinkAccent.withValues(alpha: 0.6) : Colors.transparent),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 사고의 토대 상세 열람 본문. 오른쪽 시트와 문항 분석 조회 다이얼로그가 함께 재사용한다.
class ThinkingFoundationDetailBody extends StatelessWidget {
  const ThinkingFoundationDetailBody({
    super.key,
    required this.item,
    this.trailingAction,
  });

  final ThinkingFoundationItem item;
  final Widget? trailingAction;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ThinkBadge(item.code, color: kThinkAccent),
              ThinkBadge(item.groupDisplayLabel, color: kThinkLink),
              if (!item.isActive) const ThinkBadge('비활성', color: kThinkHint),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  item.title,
                  style: const TextStyle(color: kThinkText, fontSize: 17, fontWeight: FontWeight.w800),
                ),
              ),
              if (trailingAction != null) trailingAction!,
            ],
          ),
          if (item.isAttitudeGroup) ...[
            const SizedBox(height: 10),
            const ThinkNotice(
              text: 'C3(탐구의 태도)는 정적 문항 내용만으로 측정하기 어려우므로, 학생의 실제 풀이 과정·발화·수정 행동을 통해 관찰합니다.',
              color: kThinkLink,
              icon: Icons.visibility_outlined,
            ),
          ],
          const SizedBox(height: 14),
          _sectionTitle('정의'),
          const SizedBox(height: 4),
          LatexTextRenderer(
            item.definition,
            dollarMath: true,
            style: const TextStyle(color: kThinkText, fontSize: 13.5, height: 1.5),
          ),
          if (item.teachingPrinciple.trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            _sectionTitle('지도 원칙'),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: kThinkQuote,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kThinkAccent.withValues(alpha: 0.45)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.format_quote_rounded, size: 18, color: kThinkAccent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: LatexTextRenderer(
                      '"${item.teachingPrinciple}"',
                      dollarMath: true,
                      style: const TextStyle(
                        color: kThinkText,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (item.learningGoals.isNotEmpty) ...[
            const SizedBox(height: 14),
            _sectionTitle('교육 목표'),
            const SizedBox(height: 6),
            for (final goal in item.learningGoals)
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 6, right: 8),
                      child: Icon(Icons.circle, size: 5, color: kThinkAccent),
                    ),
                    Expanded(
                      child: LatexTextRenderer(
                        goal,
                        dollarMath: true,
                        style: const TextStyle(color: kThinkSub, fontSize: 13, height: 1.45),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 14),
          _sectionTitle('수학적 예시 (${item.examples.length})'),
          const SizedBox(height: 6),
          for (var i = 0; i < item.examples.length; i++)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: kThinkBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kThinkBorder),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${i + 1}.',
                    style: const TextStyle(
                      color: kThinkAccent,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: LatexTextRenderer(
                      item.examples[i].content,
                      dollarMath: true,
                      style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
          if (item.observationCriteria.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            _sectionTitle('학생 관찰 기준'),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: kThinkBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kThinkBorder),
              ),
              child: LatexTextRenderer(
                item.observationCriteria,
                dollarMath: true,
                style: const TextStyle(color: kThinkSub, fontSize: 13, height: 1.45),
              ),
            ),
          ],
          if (item.keywords.isNotEmpty) ...[
            const SizedBox(height: 14),
            _sectionTitle('관련 키워드'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final kw in item.keywords) ThinkBadge('#$kw', color: kThinkSub),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w800),
    );
  }
}

Future<void> showThinkingFoundationDetailDialog(
  BuildContext context,
  ThinkingFoundationItem item,
) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kThinkPanel,
      shape: thinkDialogShape,
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      title: Row(
        children: [
          const Icon(Icons.compass_calibration_outlined, size: 18, color: kThinkAccent),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '사고의 토대 상세',
              style: TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800),
            ),
          ),
          IconButton(
            tooltip: '닫기',
            onPressed: () => Navigator.pop(ctx),
            icon: const Icon(Icons.close, size: 18, color: kThinkSub),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: ThinkingFoundationDetailBody(item: item),
      ),
    ),
  );
}
