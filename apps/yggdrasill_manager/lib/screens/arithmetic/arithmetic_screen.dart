import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/arithmetic_primitive_service.dart';
import '../../theme/manager_shell_colors.dart';
import '../think/think_style.dart';

const List<String> kArithmeticCategories = [
  '자연수 덧셈',
  '자연수 뺄셈',
  '자연수 곱셈',
  '자연수 나눗셈',
  '약수·배수·소인수분해',
  '분수 연산',
  '소수 연산',
  '정수·유리수 부호 연산',
  '거듭제곱·제곱근',
  '다항식·전개·인수분해',
  '방정식·부등식 변형',
  '고등 식·복소수·로그·벡터',
];

class ArithmeticScreen extends StatefulWidget {
  const ArithmeticScreen({super.key, this.service, this.embedded = false});

  final ArithmeticPrimitiveService? service;

  /// 개념 탭 오른쪽 절반. 목록을 교육과정 흐름 트리처럼 보이고, 연산 메뉴 화면은 그대로 둔다.
  final bool embedded;

  @override
  State<ArithmeticScreen> createState() => _ArithmeticScreenState();
}

class _ArithmeticScreenState extends State<ArithmeticScreen> {
  late final ArithmeticPrimitiveService _svc = widget.service ?? ArithmeticPrimitiveService();

  bool _loading = true;
  String? _error;
  List<ArithmeticPrimitiveItem> _primitives = const [];
  List<ArithmeticLibraryConcept> _concepts = const [];

  /// 0: 세부 연산 수치 사전, 1: 라이브러리 연산·방법 개념 분리 및 미분할 관리
  int _tab = 0;
  String _selectedCategory = '전체';
  bool _onlyChanged = false;
  String _search = '';

  /// 탭 1에서 선택된 세부 연산 ID (null이고 _creatingNew가 true면 신규 추가)
  String? _selectedId;
  bool _creatingNew = false;

  /// 탭 2 필터 ('연산', '미분할 연산', '방법')
  String _conceptFilter = '연산';
  String _conceptSearch = '';

  /// 트리에서 접은 카테고리·묶음. 없으면 펼친다.
  final Set<String> _closedCategories = {};
  final Set<String> _closedGroups = {};

  final _codeCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _exampleCtrl = TextEditingController();
  final _criteriaCtrl = TextEditingController();
  final _scoreCtrl = TextEditingController();
  final _secCtrl = TextEditingController();
  final _orderCtrl = TextEditingController();
  String _editCategory = kArithmeticCategories.first;
  String? _editConceptId;
  bool _editActive = true;
  bool _saving = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _titleCtrl.dispose();
    _exampleCtrl.dispose();
    _criteriaCtrl.dispose();
    _scoreCtrl.dispose();
    _secCtrl.dispose();
    _orderCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _svc.fetchOverview();
      if (!mounted) return;
      setState(() {
        _primitives = data.primitives;
        _concepts = data.concepts;
        _loading = false;
        if (_selectedId != null) {
          final found = _primitives.where((p) => p.id == _selectedId).firstOrNull;
          if (found != null) {
            _populateForm(found);
          } else {
            _selectedId = null;
          }
        } else if (_primitives.isNotEmpty && !_creatingNew) {
          _selectedId = _primitives.first.id;
          _populateForm(_primitives.first);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '연산 데이터를 불러오지 못했습니다: $e';
      });
    }
  }

  void _populateForm(ArithmeticPrimitiveItem item) {
    _creatingNew = false;
    _selectedId = item.id;
    _codeCtrl.text = item.code;
    _titleCtrl.text = item.title;
    _exampleCtrl.text = item.exampleExpr;
    _criteriaCtrl.text = item.criteria;
    _scoreCtrl.text = item.unitScore.toStringAsFixed(2);
    _secCtrl.text = item.estSeconds.toStringAsFixed(1);
    _orderCtrl.text = '${item.sortOrder}';
    _editCategory = kArithmeticCategories.contains(item.category) ? item.category : kArithmeticCategories.first;
    _editConceptId = item.conceptId;
    _editActive = item.isActive;
  }

  void _startCreate({ArithmeticLibraryConcept? fromConcept}) {
    setState(() {
      _tab = 0;
      _creatingNew = true;
      _selectedId = null;
      _notice = null;
      final cat = _selectedCategory != '전체' ? _selectedCategory : kArithmeticCategories.first;
      _editCategory = cat;
      _codeCtrl.text = 'custom_${DateTime.now().millisecondsSinceEpoch % 100000}';
      _titleCtrl.text = fromConcept != null ? '${fromConcept.name} (세부 단계)' : '';
      _exampleCtrl.text = '';
      _criteriaCtrl.text = fromConcept != null ? '${fromConcept.name}의 세부 연산 단계' : '';
      _scoreCtrl.text = '0.25';
      _secCtrl.text = '3.0';
      _orderCtrl.text = '900';
      _editConceptId = fromConcept?.id;
      _editActive = true;
    });
  }

  Future<void> _nudgeScore(ArithmeticPrimitiveItem item, double delta) async {
    final next = (item.unitScore + delta).clamp(0.05, 100.0);
    try {
      await _svc.savePrimitive(
        id: item.id,
        code: item.code,
        category: item.category,
        title: item.title,
        criteria: item.criteria,
        exampleExpr: item.exampleExpr,
        unitScore: double.parse(next.toStringAsFixed(2)),
        estSeconds: item.estSeconds,
        conceptId: item.conceptId,
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
    final secs = double.tryParse(_secCtrl.text.trim()) ?? 2.0;
    final order = int.tryParse(_orderCtrl.text.trim()) ?? 0;
    if (code.isEmpty || title.isEmpty || score == null) {
      setState(() => _notice = '코드, 세부 연산 이름, 점수(숫자)를 입력해 주세요.');
      return;
    }
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      await _svc.savePrimitive(
        id: _creatingNew ? null : _selectedId,
        code: code,
        category: _editCategory,
        title: title,
        criteria: _criteriaCtrl.text.trim(),
        exampleExpr: _exampleCtrl.text.trim(),
        unitScore: score,
        estSeconds: secs,
        conceptId: _editConceptId,
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
      await _svc.deletePrimitive(id);
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

  Future<void> _syncConcept(String primitiveId) async {
    setState(() => _saving = true);
    try {
      await _svc.syncConceptMd5(primitiveId);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '원본 개념 변경 사항을 확인하여 동기화했습니다.';
      });
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '동기화 실패: $e';
      });
    }
  }

  Future<void> _toggleConceptKind(ArithmeticLibraryConcept c) async {
    final next = c.isArithmetic ? '방법' : '연산';
    try {
      await _svc.setConceptKind(c.id, next);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _notice = '유형 변경 실패: $e');
    }
  }

  List<ArithmeticPrimitiveItem> get _filteredPrimitives {
    final q = _search.trim().toLowerCase();
    return [
      for (final p in _primitives)
        if ((_selectedCategory == '전체' || p.category == _selectedCategory) &&
            (!_onlyChanged || p.conceptChanged || p.conceptMissing) &&
            (q.isEmpty ||
                p.title.toLowerCase().contains(q) ||
                p.code.toLowerCase().contains(q) ||
                p.criteria.toLowerCase().contains(q) ||
                (p.conceptName ?? '').toLowerCase().contains(q)))
          p,
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return _buildEmbedded();
    final changedCount = _primitives.where((p) => p.conceptChanged || p.conceptMissing).length;
    final calcConcepts = _concepts.where((c) => c.isArithmetic).toList();
    final unsplitCount = calcConcepts.where((c) => c.primitiveCount == 0).length;

    return Container(
      color: ManagerShellColors.surfaceBase,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                '연산 복잡도 사전 · 개념 연결',
                style: TextStyle(color: kThinkText, fontSize: 22, fontWeight: FontWeight.w900),
              ),
              const SizedBox(width: 12),
              ThinkBadge('세부 연산 ${_primitives.length}개', color: kThinkAccent),
              const SizedBox(width: 6),
              ThinkBadge('연산 개념 ${calcConcepts.length}개', color: kThinkLink),
              if (changedCount > 0) ...[
                const SizedBox(width: 6),
                ThinkBadge('원본 개념 변경됨 $changedCount개', color: kThinkError),
              ],
              const Spacer(),
              ThinkPillTabs(
                labels: [
                  '세부 연산 수치 사전 (${_primitives.length})',
                  '라이브러리 연산·방법 분류 (미분할 $unsplitCount)',
                ],
                icons: const [Icons.calculate_outlined, Icons.account_tree_outlined],
                selected: _tab,
                onSelected: (i) => setState(() => _tab = i),
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
          const Text(
            '문항 검수 시 AI가 풀이 과정에서 카운트할 초정밀 연산 단위(자릿수 조합·받아올림 횟수·통분 유형)와 인간 체감 난이도 점수를 관리합니다.',
            style: TextStyle(color: kThinkSub, fontSize: 13),
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
                    : _tab == 0
                        ? _buildPrimitivesWorkspace(changedCount)
                        : _buildConceptsWorkspace(),
          ),
        ],
      ),
    );
  }

  Widget _buildPrimitivesWorkspace(int changedCount) {
    final filtered = _filteredPrimitives;
    final selected = _creatingNew ? null : _primitives.where((p) => p.id == _selectedId).firstOrNull;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1) 좌측: 연산 대분류 카테고리
        SizedBox(
          width: 220,
          child: ThinkPanel(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ElevatedButton.icon(
                  onPressed: () => _startCreate(),
                  style: thinkPrimaryButton(),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('세부 연산 단위 추가'),
                ),
                const SizedBox(height: 10),
                if (changedCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ThinkToggleChip(
                      label: '원본 개념 변경됨 ($changedCount)',
                      icon: Icons.warning_amber_rounded,
                      selected: _onlyChanged,
                      onChanged: (v) => setState(() => _onlyChanged = v),
                    ),
                  ),
                const Divider(color: kThinkBorder, height: 1),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(
                    children: [
                      _categoryTile('전체', _primitives.length),
                      for (final cat in kArithmeticCategories)
                        _categoryTile(cat, _primitives.where((p) => p.category == cat).length),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        // 2) 중앙: 세부 연산 단위 목록
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
                            hint: '세부 연산 이름, 코드, 예시 식, 연결 개념 검색...',
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
                          child: Text('조건에 맞는 세부 연산 단위가 없습니다.', style: TextStyle(color: kThinkSub)),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const Divider(color: kThinkBorder, height: 1),
                          itemBuilder: (_, i) => _primitiveRow(filtered[i]),
                        ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        // 3) 우측: 세부 연산 편집 및 원본 개념 동기화 패널
        SizedBox(
          width: 360,
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

  Widget _primitiveRow(ArithmeticPrimitiveItem item) {
    final isSelected = !_creatingNew && _selectedId == item.id;
    return InkWell(
      onTap: () => setState(() => _populateForm(item)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? kThinkField : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
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
                      if (item.conceptChanged)
                        const ThinkBadge('원본 개념 변경됨', color: kThinkError),
                      if (item.conceptMissing)
                        const ThinkBadge('연결 개념 삭제됨', color: kThinkError),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.criteria,
                    style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.35),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (item.exampleExpr.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: kThinkQuote,
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: kThinkBorder),
                          ),
                          child: Text(
                            '예: ${item.exampleExpr}',
                            style: const TextStyle(color: kThinkText, fontSize: 11, fontFamily: 'monospace'),
                          ),
                        ),
                      if (item.conceptName != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: kThinkAccent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            '모체 개념: ${item.conceptName}',
                            style: const TextStyle(color: kThinkAccent, fontSize: 11, fontWeight: FontWeight.w700),
                          ),
                        ),
                      Text(
                        '코드: ${item.code}',
                        style: const TextStyle(color: kThinkHint, fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // 우측 점수 즉시 조절 컨트롤
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '-0.05점',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => unawaited(_nudgeScore(item, -0.05)),
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
                        '${item.unitScore.toStringAsFixed(2)}점',
                        style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w900),
                      ),
                    ),
                    IconButton(
                      tooltip: '+0.05점',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => unawaited(_nudgeScore(item, 0.05)),
                      icon: const Icon(Icons.add_circle_outline, size: 18, color: kThinkSub),
                    ),
                  ],
                ),
                Text(
                  '약 ${item.estSeconds.toStringAsFixed(1)}초',
                  style: const TextStyle(color: kThinkHint, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditPane(ArithmeticPrimitiveItem? selected) {
    if (!_creatingNew && selected == null) {
      return const Center(
        child: Text('목록에서 세부 연산을 선택하거나 새로 추가하세요.', style: TextStyle(color: kThinkSub)),
      );
    }
    final calcConcepts = _concepts.where((c) => c.isArithmetic || c.id == _editConceptId).toList();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _creatingNew ? '새 세부 연산 단위 추가' : '세부 연산 단위 편집',
            style: const TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          if (selected != null && selected.conceptChanged) ...[
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: kThinkError.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kThinkError),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '모체 개념의 본문이 개념 라이브러리에서 수정되었습니다.',
                    style: TextStyle(color: kThinkText, fontSize: 12, fontWeight: FontWeight.w800),
                  ),
                  if (selected.conceptContent != null && selected.conceptContent!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      selected.conceptContent!,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kThinkSub, fontSize: 11),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: _saving ? null : () => unawaited(_syncConcept(selected.id)),
                      style: thinkOutlineButton(),
                      icon: const Icon(Icons.sync, size: 16),
                      label: const Text('변경 확인 완료 (동기화)'),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const Text('대분류 카테고리', style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 4),
          InputDecorator(
            decoration: thinkInputDecoration(dense: true),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _editCategory,
                isDense: true,
                isExpanded: true,
                dropdownColor: kThinkPanel,
                style: const TextStyle(color: kThinkText, fontSize: 13),
                items: [
                  for (final c in kArithmeticCategories)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _editCategory = v);
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text('세부 연산 이름', style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 4),
          TextField(
            controller: _titleCtrl,
            style: const TextStyle(color: kThinkText, fontSize: 13),
            decoration: thinkInputDecoration(hint: '예: 2자리 + 2자리 (받아올림 1회)'),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('연산 점수 (토큰)', style: TextStyle(color: kThinkSub, fontSize: 12)),
                    const SizedBox(height: 4),
                    TextField(
                      controller: _scoreCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(color: kThinkText, fontSize: 13),
                      decoration: thinkInputDecoration(hint: '예: 3.0'),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('예상 시간 (초)', style: TextStyle(color: kThinkSub, fontSize: 12)),
                    const SizedBox(height: 4),
                    TextField(
                      controller: _secCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(color: kThinkText, fontSize: 13),
                      decoration: thinkInputDecoration(hint: '예: 3.0'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text('예시 식', style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 4),
          TextField(
            controller: _exampleCtrl,
            style: const TextStyle(color: kThinkText, fontSize: 13),
            decoration: thinkInputDecoration(hint: '예: 38 + 25 = 63'),
          ),
          const SizedBox(height: 10),
          const Text('AI 카운트 판정 기준', style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 4),
          TextField(
            controller: _criteriaCtrl,
            maxLines: 3,
            style: const TextStyle(color: kThinkText, fontSize: 13),
            decoration: thinkInputDecoration(hint: 'AI가 풀이에서 1회로 세는 구체적인 조건'),
          ),
          const SizedBox(height: 10),
          const Text('연결된 개념 라이브러리 (모체 개념)', style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 4),
          InputDecorator(
            decoration: thinkInputDecoration(dense: true),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                value: calcConcepts.any((c) => c.id == _editConceptId) ? _editConceptId : null,
                isDense: true,
                isExpanded: true,
                dropdownColor: kThinkPanel,
                style: const TextStyle(color: kThinkText, fontSize: 12),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('(연결 안 함)')),
                  for (final c in calcConcepts)
                    DropdownMenuItem<String?>(
                      value: c.id,
                      child: Text('${c.name} (${c.folderPath})', overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _editConceptId = v),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('고유 코드', style: TextStyle(color: kThinkSub, fontSize: 12)),
                    const SizedBox(height: 4),
                    TextField(
                      controller: _codeCtrl,
                      style: const TextStyle(color: kThinkText, fontSize: 12, fontFamily: 'monospace'),
                      decoration: thinkInputDecoration(hint: 'nat_add_2d_2d_c1'),
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
                      style: const TextStyle(color: kThinkText, fontSize: 12),
                      decoration: thinkInputDecoration(hint: '100'),
                    ),
                  ],
                ),
              ),
            ],
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

  Widget _buildConceptsWorkspace() {
    final q = _conceptSearch.trim().toLowerCase();
    final filtered = [
      for (final c in _concepts)
        if ((_conceptFilter == '연산' && c.isArithmetic) ||
            (_conceptFilter == '미분할 연산' && c.isArithmetic && c.primitiveCount == 0) ||
            (_conceptFilter == '방법' && !c.isArithmetic))
          if (q.isEmpty || c.name.toLowerCase().contains(q) || c.folderPath.toLowerCase().contains(q)) c,
    ];

    return ThinkPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (final f in const ['연산', '미분할 연산', '방법']) ...[
                ThinkToggleChip(
                  label: f == '연산'
                      ? '연산 개념 (${_concepts.where((c) => c.isArithmetic).length})'
                      : f == '미분할 연산'
                          ? '미분할 연산 개념 (${_concepts.where((c) => c.isArithmetic && c.primitiveCount == 0).length})'
                          : '방법 개념 — 비연산 풀이법 (${_concepts.where((c) => !c.isArithmetic).length})',
                  icon: f == '방법' ? Icons.lightbulb_outline : Icons.calculate_outlined,
                  selected: _conceptFilter == f,
                  onChanged: (_) => setState(() => _conceptFilter = f),
                ),
                const SizedBox(width: 8),
              ],
              const Spacer(),
              SizedBox(
                width: 280,
                height: 36,
                child: TextField(
                  onChanged: (v) => setState(() => _conceptSearch = v),
                  style: const TextStyle(color: kThinkText, fontSize: 13),
                  decoration: thinkInputDecoration(
                    hint: '개념 이름 또는 폴더 검색...',
                    prefixIcon: const Icon(Icons.search, size: 18, color: kThinkSub),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(color: kThinkBorder, height: 1),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const Divider(color: kThinkBorder, height: 1),
              itemBuilder: (_, i) {
                final c = filtered[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                  child: Row(
                    children: [
                      ThinkBadge(c.typeName, color: c.isArithmetic ? kThinkAccent : kThinkSub),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              c.name,
                              style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800),
                            ),
                            Text(
                              c.folderPath,
                              style: const TextStyle(color: kThinkSub, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      ThinkBadge(
                        '세부 연산 ${c.primitiveCount}개',
                        color: c.primitiveCount > 0 ? kThinkSuccess : kThinkHint,
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () => _startCreate(fromConcept: c),
                        style: thinkOutlineButton(),
                        icon: const Icon(Icons.call_split, size: 16),
                        label: const Text('세부 연산 쪼개기'),
                      ),
                      const SizedBox(width: 6),
                      TextButton(
                        onPressed: () => unawaited(_toggleConceptKind(c)),
                        child: Text(
                          c.isArithmetic ? '방법으로 이동' : '연산으로 이동',
                          style: const TextStyle(color: kThinkLink, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmbedded() {
    final changedCount = _primitives.where((p) => p.conceptChanged || p.conceptMissing).length;
    final unsplitCount = _concepts.where((c) => c.isArithmetic && c.primitiveCount == 0).length;
    return ThinkPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.calculate_outlined, size: 18, color: kThinkAccent),
                const SizedBox(width: 8),
                const Text('연산', style: TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(width: 12),
                Flexible(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: ThinkPillTabs(
                      labels: [
                        '세부 연산 (${_primitives.length})',
                        '연산·방법 (미분할 $unsplitCount)',
                      ],
                      icons: const [Icons.account_tree_outlined, Icons.account_tree_outlined],
                      selected: _tab,
                      onSelected: (i) => setState(() => _tab = i),
                    ),
                  ),
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
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: ThinkNotice(text: _notice!, color: kThinkAccent, icon: Icons.info_outline),
            ),
          Expanded(child: _embeddedBody(changedCount)),
        ],
      ),
    );
  }

  Widget _embeddedBody(int changedCount) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: kThinkAccent));
    if (_error != null) {
      return Center(
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
      );
    }
    if (_tab == 0) return _primitiveTree(changedCount);
    return _conceptTree();
  }

  Widget _primitiveTree(int changedCount) {
    final filtered = _filteredPrimitives;
    final selected = _creatingNew ? null : _primitives.where((p) => p.id == _selectedId).firstOrNull;
    final filtering = _search.trim().isNotEmpty || _onlyChanged;
    final categories = <String>[
      ...kArithmeticCategories,
      for (final p in filtered)
        if (!kArithmeticCategories.contains(p.category) && p.category.isNotEmpty) p.category,
    ];
    final seen = <String>{};
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _startCreate(),
                      style: thinkOutlineButton().copyWith(
                        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('세부 연산 추가'),
                    ),
                    if (changedCount > 0)
                      ThinkToggleChip(
                        label: '원본 개념 변경됨 ($changedCount)',
                        icon: Icons.warning_amber_rounded,
                        selected: _onlyChanged,
                        onChanged: (v) => setState(() => _onlyChanged = v),
                      ),
                    SizedBox(
                      width: 280,
                      height: 36,
                      child: TextField(
                        onChanged: (v) => setState(() => _search = v),
                        style: const TextStyle(color: kThinkText, fontSize: 13),
                        decoration: thinkInputDecoration(
                          hint: '이름, 코드, 예시, 연결 개념',
                          prefixIcon: const Icon(Icons.search, size: 18, color: kThinkSub),
                        ),
                      ),
                    ),
                    Text('표시 ${filtered.length}개',
                        style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 8),
                const Divider(color: kThinkBorder, height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
                    children: [
                      for (final cat in categories)
                        if (seen.add(cat))
                          ..._categoryBlock(
                            cat,
                            [for (final p in filtered) if (p.category == cat) p],
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
          width: 360,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _buildEditPane(selected),
          ),
        ),
      ],
    );
  }

  List<Widget> _categoryBlock(String category, List<ArithmeticPrimitiveItem> items, {required bool hideEmpty}) {
    if (items.isEmpty && hideEmpty) return const [];
    final open = !_closedCategories.contains(category);
    return [
      _outlineRow(
        key: ValueKey('arith-category-$category'),
        height: 36,
        indent: 0,
        selected: false,
        onTap: () => setState(() {
          if (open) {
            _closedCategories.add(category);
          } else {
            _closedCategories.remove(category);
          }
        }),
        child: Row(
          children: [
            Icon(open ? Icons.expand_more : Icons.chevron_right, size: 18, color: kThinkSub),
            const SizedBox(width: 4),
            Expanded(
              child: Text(category,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700)),
            ),
            Text('${items.length}', style: const TextStyle(color: kThinkHint, fontSize: 12, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
      if (open)
        for (final item in items) _primitiveTreeRow(item),
    ];
  }

  Widget _primitiveTreeRow(ArithmeticPrimitiveItem item) {
    final selected = !_creatingNew && _selectedId == item.id;
    return _outlineRow(
      key: ValueKey('arith-primitive-${item.id}'),
      height: 36,
      indent: 28,
      selected: selected,
      onTap: () => setState(() => _populateForm(item)),
      child: Row(
        children: [
          Expanded(
            child: Text(
              item.title.trim().isEmpty ? '(이름 없음)' : item.title.trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          if (item.conceptChanged || item.conceptMissing) ...[
            const SizedBox(width: 6),
            const Icon(Icons.error_outline, size: 14, color: kThinkError),
          ],
          const SizedBox(width: 4),
          _scoreNudge(item),
        ],
      ),
    );
  }

  Widget _scoreNudge(ArithmeticPrimitiveItem item) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _nudgeButton(Icons.remove, '점수 내리기', () => unawaited(_nudgeScore(item, -0.05))),
        Text(item.unitScore.toStringAsFixed(2),
            style: const TextStyle(color: kThinkText, fontSize: 12, fontWeight: FontWeight.w800)),
        _nudgeButton(Icons.add, '점수 올리기', () => unawaited(_nudgeScore(item, 0.05))),
      ],
    );
  }

  Widget _nudgeButton(IconData icon, String tip, VoidCallback onTap) {
    return IconButton(
      tooltip: tip,
      onPressed: onTap,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      icon: Icon(icon, size: 16, color: kThinkSub),
    );
  }

  Widget _conceptTree() {
    final q = _conceptSearch.trim().toLowerCase();
    final groups = <String, List<ArithmeticLibraryConcept>>{
      '연산': [for (final c in _concepts) if (c.isArithmetic) c],
      '미분할 연산': [for (final c in _concepts) if (c.isArithmetic && c.primitiveCount == 0) c],
      '방법': [for (final c in _concepts) if (!c.isArithmetic) c],
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 320,
              height: 36,
              child: TextField(
                onChanged: (v) => setState(() => _conceptSearch = v),
                style: const TextStyle(color: kThinkText, fontSize: 13),
                decoration: thinkInputDecoration(
                  hint: '개념 이름 또는 폴더',
                  prefixIcon: const Icon(Icons.search, size: 18, color: kThinkSub),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Divider(color: kThinkBorder, height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
              children: [
                for (final name in groups.keys) ..._conceptGroup(name, groups[name]!, q),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _conceptGroup(String name, List<ArithmeticLibraryConcept> all, String query) {
    final items = [
      for (final c in all)
        if (query.isEmpty || c.name.toLowerCase().contains(query) || c.folderPath.toLowerCase().contains(query)) c,
    ];
    if (items.isEmpty && query.isNotEmpty) return const [];
    final open = !_closedGroups.contains(name);
    return [
      _outlineRow(
        key: ValueKey('arith-group-$name'),
        height: 36,
        indent: 0,
        selected: false,
        onTap: () => setState(() {
          if (open) {
            _closedGroups.add(name);
          } else {
            _closedGroups.remove(name);
          }
        }),
        child: Row(
          children: [
            Icon(open ? Icons.expand_more : Icons.chevron_right, size: 18, color: kThinkSub),
            const SizedBox(width: 4),
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700)),
            ),
            Text('${items.length}', style: const TextStyle(color: kThinkHint, fontSize: 12, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
      if (open)
        for (final c in items) _conceptTreeRow(c),
    ];
  }

  Widget _conceptTreeRow(ArithmeticLibraryConcept c) {
    return _outlineRow(
      key: ValueKey('arith-concept-${c.id}'),
      height: 36,
      indent: 28,
      selected: false,
      onTap: null,
      child: Row(
        children: [
          ThinkBadge(c.typeName, color: c.isArithmetic ? kThinkAccent : kThinkSub),
          const SizedBox(width: 8),
          Expanded(
            child: Text(c.name.trim().isEmpty ? '(이름 없음)' : c.name.trim(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          Text('세부 ${c.primitiveCount}',
              style: TextStyle(
                  color: c.primitiveCount > 0 ? kThinkSuccess : kThinkHint, fontSize: 12, fontWeight: FontWeight.w700)),
          PopupMenuButton<String>(
            key: ValueKey('arith-concept-menu-${c.id}'),
            tooltip: '쪼개기·옮기기',
            padding: EdgeInsets.zero,
            color: kThinkPanel,
            style: IconButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(24, 24),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            icon: const Icon(Icons.more_horiz, size: 18, color: kThinkSub),
            onSelected: (v) {
              if (v == 'split') {
                _startCreate(fromConcept: c);
              } else {
                unawaited(_toggleConceptKind(c));
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'split', child: Text('세부 연산 쪼개기')),
              PopupMenuItem(value: 'move', child: Text(c.isArithmetic ? '방법으로 이동' : '연산으로 이동')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _outlineRow({
    required Key key,
    required double height,
    required double indent,
    required bool selected,
    required VoidCallback? onTap,
    required Widget child,
  }) {
    return SizedBox(
      height: height,
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
