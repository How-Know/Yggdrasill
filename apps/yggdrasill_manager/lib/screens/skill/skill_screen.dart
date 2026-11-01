import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/thinking_primitive_service.dart';
import '../../theme/manager_shell_colors.dart';
import '../think/think_style.dart';

const List<String> kThinkingFrameCategories = [
  '구조·분해',
  '연역·전개',
  '번역·시각화',
  '탐색·추론',
  '조건·방어',
];

const List<String> kThinkingAlgorithmCategories = [
  '다항식·방정식·부등식',
  '함수·그래프·변환',
  '미분·적분(극한·극값·넓이)',
  '수열·규칙·점화식',
  '도형·삼각함수·벡터',
  '경우의 수·확률·통계',
];

class SkillScreen extends StatefulWidget {
  const SkillScreen({super.key, this.service});

  final ThinkingPrimitiveService? service;

  @override
  State<SkillScreen> createState() => _SkillScreenState();
}

class _SkillScreenState extends State<SkillScreen> {
  late final ThinkingPrimitiveService _svc = widget.service ?? ThinkingPrimitiveService();

  bool _loading = true;
  String? _error;
  List<ThinkingPrimitiveItem> _items = const [];

  /// 0: 범용 사고틀(frame, B안), 1: 실전 알고리즘(algorithm, A안)
  int _tab = 0;
  String _selectedCategory = '전체';
  String _search = '';

  String? _selectedId;
  bool _creatingNew = false;

  final _codeCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _criteriaCtrl = TextEditingController();
  final _triggerCtrl = TextEditingController();
  final _actionCtrl = TextEditingController();
  final _trapCtrl = TextEditingController();
  final _exampleCtrl = TextEditingController();
  final _scoreCtrl = TextEditingController();
  final _orderCtrl = TextEditingController();
  String _editCategory = kThinkingFrameCategories.first;
  bool _editActive = true;
  bool _saving = false;
  String? _notice;

  String get _currentKind => _tab == 0 ? 'frame' : 'algorithm';

  List<String> get _currentCategories =>
      _tab == 0 ? kThinkingFrameCategories : kThinkingAlgorithmCategories;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _titleCtrl.dispose();
    _criteriaCtrl.dispose();
    _triggerCtrl.dispose();
    _actionCtrl.dispose();
    _trapCtrl.dispose();
    _exampleCtrl.dispose();
    _scoreCtrl.dispose();
    _orderCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _svc.fetchAll();
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
        _selectDefaultForTab();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '사고 데이터를 불러오지 못했습니다: $e';
      });
    }
  }

  void _selectDefaultForTab() {
    final kindItems = _items.where((x) => x.kind == _currentKind).toList();
    if (_selectedId != null) {
      final hit = kindItems.where((x) => x.id == _selectedId).firstOrNull;
      if (hit != null) {
        _populateForm(hit);
        return;
      }
    }
    if (kindItems.isNotEmpty && !_creatingNew) {
      _selectedId = kindItems.first.id;
      _populateForm(kindItems.first);
    } else {
      _selectedId = null;
    }
  }

  void _populateForm(ThinkingPrimitiveItem item) {
    _creatingNew = false;
    _selectedId = item.id;
    _codeCtrl.text = item.code;
    _titleCtrl.text = item.title;
    _criteriaCtrl.text = item.criteria;
    _triggerCtrl.text = item.triggerCond;
    _actionCtrl.text = item.actionSteps;
    _trapCtrl.text = item.trapNote;
    _exampleCtrl.text = item.exampleExpr;
    _scoreCtrl.text = item.unitScore.toStringAsFixed(1);
    _orderCtrl.text = '${item.sortOrder}';
    final cats = item.isFrame ? kThinkingFrameCategories : kThinkingAlgorithmCategories;
    _editCategory = cats.contains(item.category) ? item.category : cats.first;
    _editActive = item.isActive;
  }

  void _startCreate() {
    setState(() {
      _creatingNew = true;
      _selectedId = null;
      _notice = null;
      final cats = _currentCategories;
      _editCategory = _selectedCategory != '전체' && cats.contains(_selectedCategory) ? _selectedCategory : cats.first;
      final prefix = _tab == 0 ? 'frame' : 'algo';
      _codeCtrl.text = '${prefix}_${DateTime.now().millisecondsSinceEpoch % 100000}';
      _titleCtrl.text = '';
      _criteriaCtrl.text = '';
      _triggerCtrl.text = '';
      _actionCtrl.text = '';
      _trapCtrl.text = '';
      _exampleCtrl.text = '';
      _scoreCtrl.text = _tab == 0 ? '5.5' : '7.0';
      _orderCtrl.text = '900';
      _editActive = true;
    });
  }

  Future<void> _nudgeScore(ThinkingPrimitiveItem item, double delta) async {
    final next = (item.unitScore + delta).clamp(0.5, 50.0);
    try {
      await _svc.save(
        id: item.id,
        code: item.code,
        kind: item.kind,
        category: item.category,
        title: item.title,
        criteria: item.criteria,
        triggerCond: item.triggerCond,
        actionSteps: item.actionSteps,
        trapNote: item.trapNote,
        exampleExpr: item.exampleExpr,
        unitScore: double.parse(next.toStringAsFixed(1)),
        sortOrder: item.sortOrder,
        isActive: item.isActive,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _notice = '점수 변경 실패: $e');
    }
  }

  Future<void> _saveCurrent() async {
    final code = _codeCtrl.text.trim();
    final title = _titleCtrl.text.trim();
    final score = double.tryParse(_scoreCtrl.text.trim());
    final order = int.tryParse(_orderCtrl.text.trim()) ?? 0;
    if (code.isEmpty || title.isEmpty || score == null) {
      setState(() => _notice = '코드, 사고 이름, 점수(숫자)를 입력해 주세요.');
      return;
    }
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      await _svc.save(
        id: _creatingNew ? null : _selectedId,
        code: code,
        kind: _currentKind,
        category: _editCategory,
        title: title,
        criteria: _criteriaCtrl.text.trim(),
        triggerCond: _triggerCtrl.text.trim(),
        actionSteps: _actionCtrl.text.trim(),
        trapNote: _trapCtrl.text.trim(),
        exampleExpr: _exampleCtrl.text.trim(),
        unitScore: score,
        sortOrder: order,
        isActive: _editActive,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _creatingNew = false;
        _notice = '저장했습니다.';
      });
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '저장 실패: $e';
      });
    }
  }

  Future<void> _deleteCurrent() async {
    final id = _selectedId;
    if (id == null) return;
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      await _svc.delete(id);
      if (!mounted) return;
      setState(() {
        _saving = false;
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

  List<ThinkingPrimitiveItem> get _filteredItems {
    final q = _search.trim().toLowerCase();
    return [
      for (final x in _items)
        if (x.kind == _currentKind &&
            (_selectedCategory == '전체' || x.category == _selectedCategory) &&
            (q.isEmpty ||
                x.title.toLowerCase().contains(q) ||
                x.code.toLowerCase().contains(q) ||
                x.criteria.toLowerCase().contains(q) ||
                x.triggerCond.toLowerCase().contains(q) ||
                x.actionSteps.toLowerCase().contains(q) ||
                x.trapNote.toLowerCase().contains(q) ||
                x.exampleExpr.toLowerCase().contains(q)))
          x,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final frameCount = _items.where((x) => x.isFrame).length;
    final algoCount = _items.where((x) => x.isAlgorithm).length;

    return Container(
      color: ManagerShellColors.surfaceBase,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                '사고 사전 · 실전 알고리즘',
                style: TextStyle(color: kThinkText, fontSize: 22, fontWeight: FontWeight.w900),
              ),
              const SizedBox(width: 12),
              ThinkBadge('범용 사고틀 $frameCount개', color: kThinkAccent),
              const SizedBox(width: 6),
              ThinkBadge('실전 알고리즘 $algoCount개', color: kThinkLink),
              const Spacer(),
              ThinkPillTabs(
                labels: [
                  '범용 사고틀 ($frameCount)',
                  '실전 알고리즘 ($algoCount)',
                ],
                icons: const [Icons.hub_outlined, Icons.alt_route_rounded],
                selected: _tab,
                onSelected: (i) {
                  setState(() {
                    _tab = i;
                    _selectedCategory = '전체';
                    _creatingNew = false;
                    _selectedId = null;
                    _selectDefaultForTab();
                  });
                },
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '새로고침',
                onPressed: _loading ? null : () => unawaited(_load()),
                icon: const Icon(Icons.refresh, color: kThinkSub, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _tab == 0
                ? '단원에 무관하게 문제를 쪼개고 추론·번역·검산하는 순수 사고 원리(범용 사고틀, B안 간결형 · 개당 3.5~7.5점)를 관리합니다.'
                : '범용 사고틀과 개념을 결합해 특정 조건에서 꺼내 쓰는 의사결정 트리와 절차(실전 알고리즘, A안 3단 구조 · 개당 5.0~9.5점)를 관리합니다.',
            style: const TextStyle(color: kThinkSub, fontSize: 13),
          ),
          if (_notice != null) ...[
            const SizedBox(height: 8),
            ThinkNotice(text: _notice!, color: kThinkAccent, icon: Icons.info_outline),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: kThinkAccent))
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!, style: const TextStyle(color: kThinkError, fontSize: 14)),
                            const SizedBox(height: 12),
                            ElevatedButton(
                              onPressed: () => unawaited(_load()),
                              style: thinkPrimaryButton(),
                              child: const Text('다시 시도'),
                            ),
                          ],
                        ),
                      )
                    : _buildWorkspace(),
          ),
        ],
      ),
    );
  }

  Widget _buildWorkspace() {
    final kindAll = _items.where((x) => x.kind == _currentKind).toList();
    final filtered = _filteredItems;
    final selected = _creatingNew ? null : kindAll.where((x) => x.id == _selectedId).firstOrNull;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1) 좌측 카테고리
        SizedBox(
          width: 220,
          child: ThinkPanel(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ElevatedButton.icon(
                  onPressed: _startCreate,
                  style: thinkPrimaryButton(),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(_tab == 0 ? '범용 사고틀 추가' : '실전 알고리즘 추가'),
                ),
                const SizedBox(height: 10),
                const Divider(color: kThinkBorder, height: 1),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(
                    children: [
                      _categoryTile('전체', kindAll.length),
                      for (final cat in _currentCategories)
                        _categoryTile(cat, kindAll.where((x) => x.category == cat).length),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        // 2) 중앙 목록
        Expanded(
          flex: 6,
          child: ThinkPanel(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 36,
                        child: TextField(
                          onChanged: (v) => setState(() => _search = v),
                          style: const TextStyle(color: kThinkText, fontSize: 13),
                          decoration: thinkInputDecoration(
                            hint: _tab == 0
                                ? '범용 사고틀 이름, 판정 기준, 예시 검색...'
                                : '실전 알고리즘 이름, 조건 단서(Trigger), 절차(Action), 함정 검색...',
                            prefixIcon: const Icon(Icons.search, size: 18, color: kThinkSub),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '표시 ${filtered.length}개',
                      style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Divider(color: kThinkBorder, height: 1),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(
                          child: Text('조건에 맞는 사고 항목이 없습니다.', style: TextStyle(color: kThinkSub)),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const Divider(color: kThinkBorder, height: 1),
                          itemBuilder: (_, i) => _itemRow(filtered[i]),
                        ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        // 3) 우측 편집 패널
        SizedBox(
          width: 390,
          child: ThinkPanel(
            padding: const EdgeInsets.all(16),
            child: _buildEditPane(selected),
          ),
        ),
      ],
    );
  }

  Widget _categoryTile(String category, int count) {
    final selected = _selectedCategory == category;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _selectedCategory = category),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color: selected ? kThinkAccent.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? kThinkAccent : Colors.transparent),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                category,
                style: TextStyle(
                  color: selected ? kThinkText : kThinkSub,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ),
            Text(
              '$count',
              style: TextStyle(
                color: selected ? kThinkAccent : kThinkHint,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _itemRow(ThinkingPrimitiveItem item) {
    final isSelected = !_creatingNew && _selectedId == item.id;
    return InkWell(
      onTap: () => setState(() => _populateForm(item)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? kThinkField : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: item.isFrame ? _buildFrameBody(item) : _buildAlgorithmBody(item),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '-0.5점',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => unawaited(_nudgeScore(item, -0.5)),
                      icon: const Icon(Icons.remove_circle_outline, size: 18, color: kThinkSub),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: kThinkAccent.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: kThinkAccent),
                      ),
                      child: Text(
                        '${item.unitScore.toStringAsFixed(1)}점',
                        style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w900),
                      ),
                    ),
                    IconButton(
                      tooltip: '+0.5점',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => unawaited(_nudgeScore(item, 0.5)),
                      icon: const Icon(Icons.add_circle_outline, size: 18, color: kThinkSub),
                    ),
                  ],
                ),
                Text(
                  item.code,
                  style: const TextStyle(color: kThinkHint, fontSize: 10, fontFamily: 'monospace'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// B안: 범용 사고틀(간결형 — 이름 + 판정 기준 + 예시)
  Widget _buildFrameBody(ThinkingPrimitiveItem item) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ThinkBadge(item.category, color: kThinkAccent),
            Text(
              item.title,
              style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          item.criteria,
          style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.4),
        ),
        if (item.exampleExpr.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: kThinkQuote,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: kThinkBorder),
            ),
            child: Text(
              '예: ${item.exampleExpr}',
              style: const TextStyle(color: kThinkText, fontSize: 11),
            ),
          ),
        ],
      ],
    );
  }

  /// A안: 실전 알고리즘(3단 구조 — ① 조건 단서 Trigger + ② 의사결정·절차 Action + ③ 함정 방어 Trap)
  Widget _buildAlgorithmBody(ThinkingPrimitiveItem item) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ThinkBadge(item.category, color: kThinkLink),
            Text(
              item.title,
              style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (item.triggerCond.isNotEmpty)
          _algoStepChip('① 언제 떠올리는가 (단서)', item.triggerCond, kThinkAccent),
        if (item.actionSteps.isNotEmpty) ...[
          const SizedBox(height: 4),
          _algoStepChip('② 의사결정 · 진행 절차', item.actionSteps, kThinkLink),
        ],
        if (item.trapNote.isNotEmpty) ...[
          const SizedBox(height: 4),
          _algoStepChip('③ 놓치기 쉬운 함정 · 방어', item.trapNote, kThinkError),
        ],
        if (item.exampleExpr.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: kThinkQuote,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: kThinkBorder),
            ),
            child: Text(
              '적용 예: ${item.exampleExpr}',
              style: const TextStyle(color: kThinkText, fontSize: 11),
            ),
          ),
        ],
      ],
    );
  }

  Widget _algoStepChip(String label, String body, Color accent) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            body,
            style: const TextStyle(color: kThinkText, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildEditPane(ThinkingPrimitiveItem? selected) {
    if (!_creatingNew && selected == null) {
      return const Center(
        child: Text('목록에서 사고 항목을 선택하거나 새로 추가하세요.', style: TextStyle(color: kThinkSub)),
      );
    }
    final isFrame = _tab == 0;
    final cats = _currentCategories;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _creatingNew
                ? (isFrame ? '새 범용 사고틀 추가' : '새 실전 알고리즘 추가')
                : (isFrame ? '범용 사고틀 편집 (B안)' : '실전 알고리즘 편집 (A안 3단 구조)'),
            style: const TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          const Text('대분류 카테고리', style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 4),
          InputDecorator(
            decoration: thinkInputDecoration(dense: true),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: cats.contains(_editCategory) ? _editCategory : cats.first,
                isDense: true,
                isExpanded: true,
                dropdownColor: kThinkPanel,
                style: const TextStyle(color: kThinkText, fontSize: 13),
                items: [
                  for (final c in cats) DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _editCategory = v);
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text('사고 이름', style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 4),
          TextField(
            controller: _titleCtrl,
            style: const TextStyle(color: kThinkText, fontSize: 13),
            decoration: thinkInputDecoration(
              hint: isFrame ? '예: 숨겨진 직렬 결합 (A → B)' : '예: 이차방정식의 두 근 조건 의사결정 트리',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('사고 점수 (3.0 ~ 10.0)', style: TextStyle(color: kThinkSub, fontSize: 12)),
                    const SizedBox(height: 4),
                    TextField(
                      controller: _scoreCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(color: kThinkText, fontSize: 13),
                      decoration: thinkInputDecoration(hint: '예: 6.5'),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('정렬 순서', style: TextStyle(color: kThinkSub, fontSize: 12)),
                    const SizedBox(height: 4),
                    TextField(
                      controller: _orderCtrl,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: kThinkText, fontSize: 13),
                      decoration: thinkInputDecoration(hint: '100'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (isFrame) ...[
            const Text('판정 기준 (B안 한 줄 설명)', style: TextStyle(color: kThinkSub, fontSize: 12)),
            const SizedBox(height: 4),
            TextField(
              controller: _criteriaCtrl,
              maxLines: 3,
              style: const TextStyle(color: kThinkText, fontSize: 13),
              decoration: thinkInputDecoration(hint: '문제 풀이에서 이 사고틀이 쓰였다고 판정하는 기준'),
            ),
          ] else ...[
            const Text('① 언제 떠올리는가 (조건 단서 Trigger)', style: TextStyle(color: kThinkAccent, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            TextField(
              controller: _triggerCtrl,
              maxLines: 2,
              style: const TextStyle(color: kThinkText, fontSize: 13),
              decoration: thinkInputDecoration(hint: '문제에 어떤 조건·표현이 나왔을 때 이 알고리즘을 켜는지'),
            ),
            const SizedBox(height: 10),
            const Text('② 어떻게 진행하는가 (의사결정·절차 Action)', style: TextStyle(color: kThinkLink, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            TextField(
              controller: _actionCtrl,
              maxLines: 5,
              style: const TextStyle(color: kThinkText, fontSize: 13),
              decoration: thinkInputDecoration(hint: '① 1순위 시도 → ② 2순위 시도 → ③ 식 변형 및 결론 도출 절차'),
            ),
            const SizedBox(height: 10),
            const Text('③ 놓치기 쉬운 함정 · 제한 조건 (Trap)', style: TextStyle(color: kThinkError, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            TextField(
              controller: _trapCtrl,
              maxLines: 2,
              style: const TextStyle(color: kThinkText, fontSize: 13),
              decoration: thinkInputDecoration(hint: '등호 포함 여부, 치환 범위, 최고차항 계수 등 주의할 함정'),
            ),
          ],
          const SizedBox(height: 10),
          const Text('적용 예시', style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 4),
          TextField(
            controller: _exampleCtrl,
            maxLines: 2,
            style: const TextStyle(color: kThinkText, fontSize: 13),
            decoration: thinkInputDecoration(hint: '구체적인 수식 또는 문항 적용 예시'),
          ),
          const SizedBox(height: 10),
          const Text('고유 코드', style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 4),
          TextField(
            controller: _codeCtrl,
            style: const TextStyle(color: kThinkText, fontSize: 12, fontFamily: 'monospace'),
            decoration: thinkInputDecoration(hint: isFrame ? 'frame_struct_serial_hidden' : 'algo_quad_roots_tree'),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (!_creatingNew && selected != null)
                TextButton.icon(
                  onPressed: _saving ? null : () => unawaited(_deleteCurrent()),
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
}
