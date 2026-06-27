import 'package:flutter/material.dart';

class ProblemRoadmapScreen extends StatefulWidget {
  const ProblemRoadmapScreen({super.key});

  @override
  State<ProblemRoadmapScreen> createState() => _ProblemRoadmapScreenState();
}

class _ProblemRoadmapScreenState extends State<ProblemRoadmapScreen> {
  static const Color _bg = Color(0xFF1F1F1F);
  static const Color _panel = Color(0xFF18181A);
  static const Color _field = Color(0xFF15171C);
  static const Color _border = Color(0xFF2A2A2A);
  static const Color _accent = Color(0xFF33A373);
  static const Color _text = Color(0xFFEAF2F2);
  static const Color _subText = Color(0xFF9FB3B3);

  final List<String> _courseLabels = const <String>[
    '1-1',
    '1-2',
    '2-1',
    '2-2',
    '3-1',
    '3-2',
    '공통수학1',
    '공통수학2',
    '대수',
    '미적분1',
    '확률과 통계',
    '미적분2',
    '기하',
  ];

  late String _selectedCourseLabel = _courseLabels.first;
  late final Map<String, List<_MajorUnitDraft>> _roadmaps =
      _buildInitialRoadmaps();
  int _selectedMajorIndex = 0;
  int _selectedMiddleIndex = 0;

  List<_MajorUnitDraft> get _units =>
      _roadmaps[_selectedCourseLabel] ?? const <_MajorUnitDraft>[];
  bool get _hasDraft => _units.isNotEmpty;
  _MajorUnitDraft get _selectedMajor => _units[_selectedMajorIndex];
  _MiddleUnitDraft get _selectedMiddle =>
      _selectedMajor.children[_selectedMiddleIndex];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 16),
            _buildCourseSelector(),
            const SizedBox(height: 16),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 420,
                    child: _buildOutlinePanel(),
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: _buildEditorPanel()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        const Icon(Icons.account_tree_outlined, color: _accent, size: 30),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '문항 로드맵',
                style: TextStyle(
                  color: _text,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: 4),
              Text(
                '문항 검색/필터를 위한 공통 개념 지도입니다. 중등 과정 초안을 화면에서 바로 편집할 수 있습니다.',
                style: TextStyle(color: _subText, fontSize: 14),
              ),
            ],
          ),
        ),
        OutlinedButton.icon(
          onPressed: _resetSelectedRoadmap,
          icon: const Icon(Icons.restart_alt),
          label: const Text('현재 과정 초안 복원'),
        ),
      ],
    );
  }

  Widget _buildCourseSelector() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final label in _courseLabels) ...[
            _RoadmapChip(
              label: label,
              selected: label == _selectedCourseLabel,
              onTap: () {
                setState(() {
                  _selectedCourseLabel = label;
                  _ensureSelectionInRange();
                });
              },
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildOutlinePanel() {
    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '로드맵 구조',
                    style: TextStyle(
                      color: _text,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _addMajorUnit,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('대단원'),
                ),
              ],
            ),
          ),
          const Divider(color: _border, height: 1),
          Expanded(
            child: _hasDraft
                ? ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _units.length,
                    itemBuilder: (context, majorIndex) {
                      final major = _units[majorIndex];
                      return _MajorUnitTile(
                        major: major,
                        majorIndex: majorIndex,
                        selectedMajorIndex: _selectedMajorIndex,
                        selectedMiddleIndex: _selectedMiddleIndex,
                        onMajorTap: () => _selectMajor(majorIndex),
                        onMiddleTap: (middleIndex) =>
                            _selectMiddle(majorIndex, middleIndex),
                        onAddMiddle: () => _addMiddleUnit(majorIndex),
                      );
                    },
                  )
                : const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '아직 이 과정의 로드맵 초안은 없습니다.\n좌측 상단의 대단원 추가로 직접 만들 수 있습니다.',
                        style: TextStyle(color: _subText, fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditorPanel() {
    if (!_hasDraft) {
      return _EmptyEditorPanel(courseLabel: _selectedCourseLabel);
    }

    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '선택 단원 편집',
                        style: TextStyle(
                          color: _text,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_selectedMajor.roman}. ${_selectedMajor.title} > ${_selectedMiddle.number}. ${_selectedMiddle.title}',
                        style: const TextStyle(color: _subText, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: _deleteSelectedMiddle,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('중단원 삭제'),
                ),
              ],
            ),
          ),
          const Divider(color: _border, height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildMajorEditor(),
                  const SizedBox(height: 16),
                  _buildMiddleEditor(),
                  const SizedBox(height: 16),
                  _buildSubUnitEditor(),
                  const SizedBox(height: 16),
                  _buildMappingNote(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMajorEditor() {
    return _EditorSection(
      title: '대단원',
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: _RoadmapTextField(
              label: '로마자',
              value: _selectedMajor.roman,
              onChanged: (value) {
                setState(() => _selectedMajor.roman = value);
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _RoadmapTextField(
              label: '대단원명',
              value: _selectedMajor.title,
              onChanged: (value) {
                setState(() => _selectedMajor.title = value);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMiddleEditor() {
    return _EditorSection(
      title: '중단원',
      trailing: TextButton.icon(
        onPressed: () => _addMiddleUnit(_selectedMajorIndex),
        icon: const Icon(Icons.add, size: 18),
        label: const Text('중단원 추가'),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: _RoadmapTextField(
              label: '번호',
              value: _selectedMiddle.number,
              onChanged: (value) {
                setState(() => _selectedMiddle.number = value);
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _RoadmapTextField(
              label: '중단원명',
              value: _selectedMiddle.title,
              onChanged: (value) {
                setState(() => _selectedMiddle.title = value);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubUnitEditor() {
    return _EditorSection(
      title: '소단원',
      trailing: TextButton.icon(
        onPressed: _addSubUnit,
        icon: const Icon(Icons.add, size: 18),
        label: const Text('소단원 추가'),
      ),
      child: Column(
        children: [
          for (var i = 0; i < _selectedMiddle.children.length; i++) ...[
            _SubUnitEditorRow(
              subUnit: _selectedMiddle.children[i],
              onCodeChanged: (value) {
                setState(() => _selectedMiddle.children[i].code = value);
              },
              onTitleChanged: (value) {
                setState(() => _selectedMiddle.children[i].title = value);
              },
              onDelete: () => _deleteSubUnit(i),
            ),
            if (i != _selectedMiddle.children.length - 1)
              const SizedBox(height: 10),
          ],
          if (_selectedMiddle.children.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '소단원이 없습니다. 우측 상단의 소단원 추가를 눌러주세요.',
                style: TextStyle(color: _subText),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMappingNote() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _field,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '다음 연결 단계',
            style: TextStyle(
              color: _text,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: 8),
          Text(
            '이 로드맵 노드를 교재별 대단원/중단원/소단원과 매핑하고, 이후 문항에는 primary / secondary / prerequisite 역할로 연결하면 됩니다.',
            style: TextStyle(color: _subText, height: 1.4),
          ),
        ],
      ),
    );
  }

  void _selectMajor(int majorIndex) {
    setState(() {
      _selectedMajorIndex = majorIndex;
      _selectedMiddleIndex = 0;
    });
  }

  void _selectMiddle(int majorIndex, int middleIndex) {
    setState(() {
      _selectedMajorIndex = majorIndex;
      _selectedMiddleIndex = middleIndex;
    });
  }

  void _addMajorUnit() {
    setState(() {
      final units = _roadmaps.putIfAbsent(
          _selectedCourseLabel, () => <_MajorUnitDraft>[]);
      final next = units.length + 1;
      units.add(_MajorUnitDraft(
        roman: _romanOf(next),
        title: '새 대단원',
        children: <_MiddleUnitDraft>[
          _MiddleUnitDraft(
            number: '$next',
            title: '새 중단원',
            children: <_SubUnitDraft>[
              _SubUnitDraft(code: '01', title: '새 소단원'),
            ],
          ),
        ],
      ));
      _selectedMajorIndex = units.length - 1;
      _selectedMiddleIndex = 0;
    });
  }

  void _addMiddleUnit(int majorIndex) {
    setState(() {
      final major = _units[majorIndex];
      final next = major.children.length + 1;
      major.children.add(_MiddleUnitDraft(
        number: '$next',
        title: '새 중단원',
        children: <_SubUnitDraft>[
          _SubUnitDraft(code: '01', title: '새 소단원'),
        ],
      ));
      _selectedMajorIndex = majorIndex;
      _selectedMiddleIndex = major.children.length - 1;
    });
  }

  void _addSubUnit() {
    setState(() {
      final next = _selectedMiddle.children.length + 1;
      _selectedMiddle.children.add(_SubUnitDraft(
        code: next.toString().padLeft(2, '0'),
        title: '새 소단원',
      ));
    });
  }

  void _deleteSelectedMiddle() {
    setState(() {
      final middleUnits = _selectedMajor.children;
      if (middleUnits.length <= 1) return;
      middleUnits.removeAt(_selectedMiddleIndex);
      _selectedMiddleIndex =
          _selectedMiddleIndex.clamp(0, middleUnits.length - 1).toInt();
    });
  }

  void _deleteSubUnit(int index) {
    setState(() {
      _selectedMiddle.children.removeAt(index);
    });
  }

  void _resetSelectedRoadmap() {
    setState(() {
      final initial = _buildInitialRoadmapForCourse(_selectedCourseLabel);
      if (initial == null) {
        _roadmaps.remove(_selectedCourseLabel);
      } else {
        _roadmaps[_selectedCourseLabel] = initial;
      }
      _selectedMajorIndex = 0;
      _selectedMiddleIndex = 0;
    });
  }

  void _ensureSelectionInRange() {
    if (!_hasDraft) {
      _selectedMajorIndex = 0;
      _selectedMiddleIndex = 0;
      return;
    }
    _selectedMajorIndex =
        _selectedMajorIndex.clamp(0, _units.length - 1).toInt();
    _selectedMiddleIndex = _selectedMiddleIndex
        .clamp(0, _units[_selectedMajorIndex].children.length - 1)
        .toInt();
  }

  static String _romanOf(int value) {
    const romans = <String>['I', 'II', 'III', 'IV', 'V', 'VI'];
    if (value >= 1 && value <= romans.length) return romans[value - 1];
    return '$value';
  }
}

class _MajorUnitTile extends StatelessWidget {
  const _MajorUnitTile({
    required this.major,
    required this.majorIndex,
    required this.selectedMajorIndex,
    required this.selectedMiddleIndex,
    required this.onMajorTap,
    required this.onMiddleTap,
    required this.onAddMiddle,
  });

  final _MajorUnitDraft major;
  final int majorIndex;
  final int selectedMajorIndex;
  final int selectedMiddleIndex;
  final VoidCallback onMajorTap;
  final ValueChanged<int> onMiddleTap;
  final VoidCallback onAddMiddle;

  @override
  Widget build(BuildContext context) {
    final majorSelected = majorIndex == selectedMajorIndex;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: majorSelected
            ? _ProblemRoadmapColors.accent.withValues(alpha: 0.10)
            : _ProblemRoadmapColors.field,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: majorSelected
              ? _ProblemRoadmapColors.accent.withValues(alpha: 0.28)
              : _ProblemRoadmapColors.border,
        ),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onMajorTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color:
                          _ProblemRoadmapColors.accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      major.roman,
                      style: const TextStyle(
                        color: _ProblemRoadmapColors.accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      major.title,
                      style: const TextStyle(
                        color: _ProblemRoadmapColors.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onAddMiddle,
                    tooltip: '중단원 추가',
                    icon: const Icon(Icons.add, size: 20),
                  ),
                ],
              ),
            ),
          ),
          for (var i = 0; i < major.children.length; i++)
            _MiddleUnitListRow(
              middle: major.children[i],
              selected:
                  majorIndex == selectedMajorIndex && i == selectedMiddleIndex,
              onTap: () => onMiddleTap(i),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _MiddleUnitListRow extends StatelessWidget {
  const _MiddleUnitListRow({
    required this.middle,
    required this.selected,
    required this.onTap,
  });

  final _MiddleUnitDraft middle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? _ProblemRoadmapColors.accent.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Text(
                middle.number,
                style: TextStyle(
                  color: selected
                      ? _ProblemRoadmapColors.accent
                      : _ProblemRoadmapColors.subText,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  middle.title,
                  style: TextStyle(
                    color: selected
                        ? _ProblemRoadmapColors.text
                        : _ProblemRoadmapColors.subText,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              Text(
                '${middle.children.length}개',
                style: const TextStyle(
                  color: _ProblemRoadmapColors.subText,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditorSection extends StatelessWidget {
  const _EditorSection({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _ProblemRoadmapColors.field,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _ProblemRoadmapColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: _ProblemRoadmapColors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _SubUnitEditorRow extends StatelessWidget {
  const _SubUnitEditorRow({
    required this.subUnit,
    required this.onCodeChanged,
    required this.onTitleChanged,
    required this.onDelete,
  });

  final _SubUnitDraft subUnit;
  final ValueChanged<String> onCodeChanged;
  final ValueChanged<String> onTitleChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 96,
          child: _RoadmapTextField(
            label: '번호',
            value: subUnit.code,
            onChanged: onCodeChanged,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _RoadmapTextField(
            label: '소단원명',
            value: subUnit.title,
            onChanged: onTitleChanged,
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          onPressed: onDelete,
          tooltip: '소단원 삭제',
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }
}

class _RoadmapTextField extends StatefulWidget {
  const _RoadmapTextField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_RoadmapTextField> createState() => _RoadmapTextFieldState();
}

class _RoadmapTextFieldState extends State<_RoadmapTextField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(covariant _RoadmapTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && _controller.text != widget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      onChanged: widget.onChanged,
      style: const TextStyle(color: _ProblemRoadmapColors.text),
      decoration: InputDecoration(
        labelText: widget.label,
        labelStyle: const TextStyle(color: _ProblemRoadmapColors.subText),
        filled: true,
        fillColor: _ProblemRoadmapColors.panel,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _ProblemRoadmapColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _ProblemRoadmapColors.accent),
        ),
      ),
    );
  }
}

class _RoadmapChip extends StatelessWidget {
  const _RoadmapChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? _ProblemRoadmapColors.accent.withValues(alpha: 0.16)
              : _ProblemRoadmapColors.border,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected
                ? _ProblemRoadmapColors.accent.withValues(alpha: 0.32)
                : _ProblemRoadmapColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? _ProblemRoadmapColors.accent
                : _ProblemRoadmapColors.text,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _EmptyEditorPanel extends StatelessWidget {
  const _EmptyEditorPanel({required this.courseLabel});

  final String courseLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _ProblemRoadmapColors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _ProblemRoadmapColors.border),
      ),
      child: Center(
        child: Text(
          '$courseLabel 로드맵은 아직 준비 중입니다.',
          style: const TextStyle(color: _ProblemRoadmapColors.subText),
        ),
      ),
    );
  }
}

class _MajorUnitDraft {
  _MajorUnitDraft({
    required this.roman,
    required this.title,
    required this.children,
  });

  String roman;
  String title;
  final List<_MiddleUnitDraft> children;
}

class _MiddleUnitDraft {
  _MiddleUnitDraft({
    required this.number,
    required this.title,
    required this.children,
  });

  String number;
  String title;
  final List<_SubUnitDraft> children;
}

class _SubUnitDraft {
  _SubUnitDraft({
    required this.code,
    required this.title,
  });

  String code;
  String title;
}

class _ProblemRoadmapColors {
  static const Color panel = Color(0xFF18181A);
  static const Color field = Color(0xFF15171C);
  static const Color border = Color(0xFF2A2A2A);
  static const Color accent = Color(0xFF33A373);
  static const Color text = Color(0xFFEAF2F2);
  static const Color subText = Color(0xFF9FB3B3);
}

Map<String, List<_MajorUnitDraft>> _buildInitialRoadmaps() {
  final labels = <String>[
    '1-1',
    '1-2',
    '2-1',
    '2-2',
    '3-1',
    '3-2',
    '공통수학1',
    '공통수학2',
    '대수',
    '미적분1',
    '미적분2',
    '확률과 통계',
    '기하',
  ];
  return <String, List<_MajorUnitDraft>>{
    for (final label in labels) label: _buildInitialRoadmapForCourse(label)!,
  };
}

List<_MajorUnitDraft>? _buildInitialRoadmapForCourse(String label) {
  switch (label) {
    case '1-1':
      return _buildMiddleOneOneUnits();
    case '1-2':
      return _buildMiddleOneTwoUnits();
    case '2-1':
      return _buildMiddleTwoOneUnits();
    case '2-2':
      return _buildMiddleTwoTwoUnits();
    case '3-1':
      return _buildMiddleThreeOneUnits();
    case '3-2':
      return _buildMiddleThreeTwoUnits();
    case '공통수학1':
      return _buildCommonMathOneUnits();
    case '공통수학2':
      return _buildCommonMathTwoUnits();
    case '대수':
      return _buildAlgebraUnits();
    case '미적분1':
      return _buildCalculusOneUnits();
    case '미적분2':
      return _buildCalculusTwoUnits();
    case '확률과 통계':
      return _buildProbabilityStatisticsUnits();
    case '기하':
      return _buildGeometryUnits();
  }
  return null;
}

_MajorUnitDraft _major(
  String roman,
  String title,
  List<_MiddleUnitDraft> children,
) {
  return _MajorUnitDraft(roman: roman, title: title, children: children);
}

_MiddleUnitDraft _middle(
  int number,
  String title,
  List<String> subUnitTitles,
) {
  return _MiddleUnitDraft(
    number: '$number',
    title: title,
    children: <_SubUnitDraft>[
      for (var i = 0; i < subUnitTitles.length; i++)
        _SubUnitDraft(
          code: (i + 1).toString().padLeft(2, '0'),
          title: subUnitTitles[i],
        ),
    ],
  );
}

List<_MajorUnitDraft> _buildMiddleOneOneUnits() {
  return <_MajorUnitDraft>[
    _major('I', '수와 연산', <_MiddleUnitDraft>[
      _middle(1, '소인수분해', <String>[
        '소인수분해',
        '최대공약수와 최소공배수',
      ]),
      _middle(2, '정수와 유리수', <String>[
        '정수와 유리수',
        '정수와 유리수의 덧셈과 뺄셈',
        '정수와 유리수의 곱셈과 나눗셈',
      ]),
    ]),
    _major('II', '문자와 식', <_MiddleUnitDraft>[
      _middle(3, '문자의 사용과 식', <String>[
        '문자의 사용',
        '식의 값',
        '일차식과 그 계산',
      ]),
      _middle(4, '일차방정식', <String>[
        '방정식과 그 해',
        '일차방정식의 풀이',
        '일차방정식의 활용',
      ]),
    ]),
    _major('III', '좌표평면과 그래프', <_MiddleUnitDraft>[
      _middle(5, '좌표와 그래프', <String>[
        '순서쌍과 좌표',
        '그래프와 그 해석',
      ]),
      _middle(6, '정비례와 반비례', <String>[
        '정비례',
        '반비례',
      ]),
    ]),
  ];
}

List<_MajorUnitDraft> _buildMiddleOneTwoUnits() {
  return <_MajorUnitDraft>[
    _major('I', '기본 도형', <_MiddleUnitDraft>[
      _middle(1, '기본 도형', <String>[
        '점, 선, 면, 각',
        '점, 직선, 평면의 위치 관계',
        '동위각과 엇각',
      ]),
      _middle(2, '작도와 합동', <String>[
        '삼각형의 작도',
        '삼각형의 합동',
      ]),
    ]),
    _major('II', '평면도형', <_MiddleUnitDraft>[
      _middle(3, '다각형', <String>[
        '다각형',
        '다각형의 내각과 외각의 크기의 합',
      ]),
      _middle(4, '원과 부채꼴', <String>[
        '원과 부채꼴',
        '부채꼴의 호의 길이와 넓이',
      ]),
    ]),
    _major('III', '입체도형', <_MiddleUnitDraft>[
      _middle(5, '다면체와 회전체', <String>[
        '다면체',
        '정다면체',
        '회전체',
      ]),
      _middle(6, '입체도형의 겉넓이와 부피', <String>[
        '기둥의 겉넓이와 부피',
        '뿔의 겉넓이와 부피',
        '구의 겉넓이와 부피',
      ]),
    ]),
    _major('IV', '통계', <_MiddleUnitDraft>[
      _middle(7, '자료의 정리와 해석', <String>[
        '대표값',
        '줄기와 잎 그림, 도수분포표',
        '히스토그램과 도수분포다각형',
        '상대도수와 그 그래프',
      ]),
    ]),
  ];
}

List<_MajorUnitDraft> _buildMiddleTwoOneUnits() {
  return <_MajorUnitDraft>[
    _major('I', '유리수의 표현과 식의 계산', <_MiddleUnitDraft>[
      _middle(1, '유리수와 순환소수', <String>[
        '유리수와 순환소수',
      ]),
      _middle(2, '식의 계산', <String>[
        '지수법칙',
        '단항식의 계산',
        '다항식의 계산',
      ]),
    ]),
    _major('II', '부등식과 연립방정식', <_MiddleUnitDraft>[
      _middle(3, '일차부등식', <String>[
        '부등식의 해와 그 성질',
        '일차부등식의 풀이',
        '일차부등식의 활용',
      ]),
      _middle(4, '연립일차방정식', <String>[
        '미지수가 2개인 연립일차방정식',
        '연립방정식의 풀이',
        '연립방정식의 활용',
      ]),
    ]),
    _major('III', '일차함수', <_MiddleUnitDraft>[
      _middle(5, '일차함수와 그 그래프', <String>[
        '함수',
        '일차함수와 그 그래프',
        '일차함수의 그래프의 성질과 식',
        '일차함수의 활용',
      ]),
      _middle(6, '일차함수와 일차방정식의 관계', <String>[
        '일차함수와 일차방정식',
        '일차함수의 그래프와 연립일차방정식',
      ]),
    ]),
  ];
}

List<_MajorUnitDraft> _buildMiddleTwoTwoUnits() {
  return <_MajorUnitDraft>[
    _major('I', '삼각형과 사각형의 성질', <_MiddleUnitDraft>[
      _middle(1, '삼각형의 성질', <String>[
        '이등변삼각형의 성질',
        '직각삼각형의 합동 조건',
        '삼각형의 외심과 내심',
      ]),
      _middle(2, '사각형의 성질', <String>[
        '평행사변형',
        '여러 가지 사각형',
        '평행선과 넓이',
      ]),
    ]),
    _major('II', '도형의 닮음과 피타고라스 정리', <_MiddleUnitDraft>[
      _middle(3, '도형의 닮음', <String>[
        '닮은 도형',
        '삼각형의 닮음 조건',
      ]),
      _middle(4, '평행선 사이의 선분의 길이의 비', <String>[
        '삼각형과 평행선',
        '삼각형의 두 변의 중점을 이은 선분의 성질',
        '평행선 사이의 선분의 길이의 비',
        '삼각형의 무게중심',
      ]),
      _middle(5, '피타고라스 정리', <String>[
        '피타고라스 정리',
        '피타고라스 정리의 활용',
      ]),
    ]),
    _major('III', '확률', <_MiddleUnitDraft>[
      _middle(6, '경우의 수', <String>[
        '경우의 수',
        '여러 가지 경우의 수',
      ]),
      _middle(7, '확률', <String>[
        '확률의 뜻과 성질',
        '확률의 계산',
      ]),
    ]),
  ];
}

List<_MajorUnitDraft> _buildMiddleThreeOneUnits() {
  return <_MajorUnitDraft>[
    _major('I', '실수와 그 계산', <_MiddleUnitDraft>[
      _middle(1, '제곱근과 실수', <String>[
        '제곱근의 뜻과 성질',
        '무리수와 실수',
      ]),
      _middle(2, '근호를 포함한 식의 계산', <String>[
        '근호를 포함한 식의 곱셈과 나눗셈',
        '근호를 포함한 식의 덧셈과 뺄셈',
      ]),
    ]),
    _major('II', '인수분해와 이차방정식', <_MiddleUnitDraft>[
      _middle(3, '다항식의 곱셈', <String>[
        '곱셈 공식',
        '곱셈 공식의 활용',
      ]),
      _middle(4, '인수분해', <String>[
        '인수분해 공식',
        '인수분해 공식의 응용',
      ]),
      _middle(5, '이차방정식', <String>[
        '이차방정식과 그 해',
        '이차방정식의 풀이',
        '이차방정식의 활용',
      ]),
    ]),
    _major('III', '이차함수', <_MiddleUnitDraft>[
      _middle(6, '이차함수와 그 그래프', <String>[
        '이차함수의 뜻',
        '이차함수 y=ax^2의 그래프',
        '이차함수 y=a(x-p)^2+q의 그래프',
      ]),
      _middle(7, '이차함수 y=ax^2+bx+c의 그래프', <String>[
        '이차함수 y=ax^2+bx+c의 그래프',
        '이차함수의 식 구하기',
        '이차함수의 최댓값과 최솟값',
      ]),
    ]),
  ];
}

List<_MajorUnitDraft> _buildMiddleThreeTwoUnits() {
  return <_MajorUnitDraft>[
    _major('I', '삼각비', <_MiddleUnitDraft>[
      _middle(1, '삼각비', <String>[
        '삼각비',
        '삼각비의 값',
      ]),
      _middle(2, '삼각비의 활용', <String>[
        '길이 구하기',
        '넓이 구하기',
      ]),
    ]),
    _major('II', '원의 성질', <_MiddleUnitDraft>[
      _middle(3, '원과 직선', <String>[
        '원의 현',
        '원의 접선',
      ]),
      _middle(4, '원주각', <String>[
        '원주각',
        '원에 내접하는 사각형',
        '원의 접선과 현이 이루는 각',
      ]),
    ]),
    _major('III', '통계', <_MiddleUnitDraft>[
      _middle(5, '산포도', <String>[
        '산포도',
      ]),
      _middle(6, '상자그림과 산점도', <String>[
        '상자그림',
        '산점도와 상관관계',
      ]),
    ]),
  ];
}

List<_MajorUnitDraft> _buildCommonMathOneUnits() {
  return <_MajorUnitDraft>[
    _major('I', '다항식', <_MiddleUnitDraft>[
      _middle(1, '다항식의 연산', <String>[
        '다항식의 덧셈과 뺄셈',
        '다항식의 곱셈',
        '곱셈 공식',
        '곱셈 공식의 변형',
        '다항식의 나눗셈',
      ]),
      _middle(2, '항등식과 나머지정리', <String>[
        '항등식',
        '나머지정리와 인수정리',
      ]),
      _middle(3, '인수분해', <String>[
        '인수분해',
        '복잡한 식의 인수분해',
      ]),
    ]),
    _major('II', '방정식과 부등식', <_MiddleUnitDraft>[
      _middle(1, '복소수', <String>[
        '복소수',
        '복소수의 연산',
        'i의 거듭제곱, 음수의 제곱근',
      ]),
      _middle(2, '이차방정식', <String>[
        '이차방정식',
        '이차방정식의 판별식',
        '이차방정식의 근과 계수의 관계',
      ]),
      _middle(3, '이차방정식과 이차함수', <String>[
        '이차방정식과 이차함수의 관계',
        '이차함수의 최대·최소',
      ]),
      _middle(4, '여러 가지 방정식', <String>[
        '삼차방정식과 사차방정식',
        '삼차방정식의 근과 계수의 관계',
        '방정식 x^n=1의 허근',
        '미지수가 2개인 연립이차방정식',
      ]),
      _middle(5, '여러 가지 부등식', <String>[
        '일차부등식',
        '연립일차부등식',
        '절댓값 기호를 포함한 일차부등식',
        '이차부등식',
        '이차부등식의 해의 조건',
        '연립이차부등식',
        '이차방정식의 실근의 조건',
      ]),
    ]),
    _major('III', '경우의 수', <_MiddleUnitDraft>[
      _middle(1, '경우의 수와 순열', <String>[
        '경우의 수',
        '순열',
      ]),
      _middle(2, '조합', <String>[
        '조합',
      ]),
    ]),
    _major('IV', '행렬', <_MiddleUnitDraft>[
      _middle(1, '행렬', <String>[
        '행렬',
        '행렬의 덧셈, 뺄셈과 실수배',
        '행렬의 곱셈',
        '행렬의 곱셈의 성질',
      ]),
    ]),
  ];
}

List<_MajorUnitDraft> _buildCommonMathTwoUnits() {
  return <_MajorUnitDraft>[
    _major('I', '도형의 방정식', <_MiddleUnitDraft>[
      _middle(1, '평면좌표', <String>[
        '두 점 사이의 거리',
        '선분의 내분점',
        '삼각형의 무게중심',
      ]),
      _middle(2, '직선의 방정식', <String>[
        '직선의 방정식',
        '직선의 위치 관계',
        '점과 직선 사이의 거리',
      ]),
      _middle(3, '원의 방정식', <String>[
        '원의 방정식',
        '원과 직선의 위치 관계',
        '원의 접선의 방정식',
        '두 원의 교점을 지나는 직선과 원의 방정식',
      ]),
      _middle(4, '도형의 이동', <String>[
        '평행이동',
        '대칭이동',
        '점과 직선에 대한 대칭이동',
      ]),
    ]),
    _major('II', '집합과 명제', <_MiddleUnitDraft>[
      _middle(1, '집합의 뜻과 포함 관계', <String>[
        '집합의 뜻과 표현',
        '집합 사이의 포함 관계',
      ]),
      _middle(2, '집합의 연산', <String>[
        '집합의 연산',
        '집합의 연산 법칙',
        '유한집합의 원소의 개수',
      ]),
      _middle(3, '명제', <String>[
        '명제와 조건',
        '명제 p → q',
        '‘모든’이나 ‘어떤’을 포함한 명제',
        '명제의 역과 대우',
        '충분조건과 필요조건',
        '명제의 증명',
        '절대부등식',
      ]),
    ]),
    _major('III', '함수', <_MiddleUnitDraft>[
      _middle(1, '함수', <String>[
        '함수',
        '여러 가지 함수',
        '합성함수',
        '역함수',
      ]),
      _middle(2, '유리함수', <String>[
        '유리식',
        '유리함수',
      ]),
      _middle(3, '무리함수', <String>[
        '무리식',
        '무리함수',
      ]),
    ]),
  ];
}

List<_MajorUnitDraft> _buildAlgebraUnits() {
  return <_MajorUnitDraft>[
    _major('I', '지수함수와 로그함수', <_MiddleUnitDraft>[
      _middle(1, '지수', <String>[
        '거듭제곱과 거듭제곱근',
        '지수의 확장',
      ]),
      _middle(2, '로그', <String>[
        '로그',
        '로그의 성질',
        '상용로그',
      ]),
      _middle(3, '지수함수', <String>[
        '지수함수의 뜻과 그래프',
        '지수함수의 최대·최소',
        '지수함수의 활용: 방정식',
        '지수함수의 활용: 부등식',
      ]),
      _middle(4, '로그함수', <String>[
        '로그함수의 뜻과 그래프',
        '로그함수의 최대·최소',
        '로그함수의 활용: 방정식',
        '로그함수의 활용: 부등식',
      ]),
    ]),
    _major('II', '삼각함수', <_MiddleUnitDraft>[
      _middle(1, '삼각함수', <String>[
        '일반각',
        '호도법',
        '삼각함수',
      ]),
      _middle(2, '삼각함수의 그래프', <String>[
        '삼각함수의 그래프',
        '일반각에 대한 삼각함수의 성질',
        '삼각함수를 포함한 식의 최대·최소',
        '삼각함수가 포함된 방정식과 부등식',
      ]),
      _middle(3, '삼각함수의 활용', <String>[
        '사인법칙',
        '코사인법칙',
        '삼각형의 넓이',
      ]),
    ]),
    _major('III', '수열', <_MiddleUnitDraft>[
      _middle(1, '등차수열과 등비수열', <String>[
        '등차수열',
        '등차수열의 합',
        '등비수열',
        '등비수열의 합',
      ]),
      _middle(2, '수열의 합', <String>[
        'Σ의 뜻과 그 성질',
        '자연수의 거듭제곱의 합',
        '여러 가지 수열의 합',
      ]),
      _middle(3, '수학적 귀납법', <String>[
        '수열의 귀납적 정의',
        '수학적 귀납법',
      ]),
    ]),
  ];
}

List<_MajorUnitDraft> _buildCalculusOneUnits() {
  return <_MajorUnitDraft>[
    _major('I', '함수의 극한과 연속', <_MiddleUnitDraft>[
      _middle(1, '함수의 극한', <String>[
        '함수의 극한',
        '우극한과 좌극한',
        '함수의 극한에 대한 성질',
        '함수의 극한의 응용',
      ]),
      _middle(2, '함수의 연속', <String>[
        '함수의 연속',
        '연속함수의 성질',
      ]),
    ]),
    _major('II', '미분', <_MiddleUnitDraft>[
      _middle(1, '미분계수와 도함수', <String>[
        '미분계수',
        '미분가능성과 연속성',
        '도함수',
      ]),
      _middle(2, '도함수의 활용', <String>[
        '접선의 방정식',
        '평균값 정리',
        '함수의 증가와 감소',
        '함수의 극대와 극소',
        '함수의 그래프',
        '함수의 최댓값과 최솟값',
        '방정식과 부등식에의 활용',
        '속도와 가속도',
      ]),
    ]),
    _major('III', '적분', <_MiddleUnitDraft>[
      _middle(1, '부정적분', <String>[
        '부정적분',
        '부정적분의 계산',
      ]),
      _middle(2, '정적분', <String>[
        '정적분',
        '여러 가지 정적분',
        '정적분으로 정의된 함수',
      ]),
      _middle(3, '정적분의 활용', <String>[
        '정적분과 넓이',
        '정적분과 넓이의 활용',
        '속도와 거리',
      ]),
    ]),
  ];
}

List<_MajorUnitDraft> _buildCalculusTwoUnits() {
  return <_MajorUnitDraft>[
    _major('I', '수열의 극한', <_MiddleUnitDraft>[
      _middle(1, '수열의 극한', <String>[
        '수열의 수렴과 발산',
        '수열의 극한값의 계산',
        '수열의 극한의 대소 관계',
        '등비수열의 극한',
      ]),
      _middle(2, '급수', <String>[
        '급수의 수렴과 발산',
        '등비급수',
        '등비급수의 활용',
      ]),
    ]),
    _major('II', '미분법', <_MiddleUnitDraft>[
      _middle(1, '지수함수와 로그함수의 미분', <String>[
        '지수함수와 로그함수의 극한',
        '무리수 e와 자연로그',
        '지수함수와 로그함수의 도함수',
      ]),
      _middle(2, '삼각함수의 미분', <String>[
        '삼각함수의 뜻',
        '삼각함수의 덧셈정리',
        '삼각함수의 극한',
        '삼각함수의 도함수',
      ]),
      _middle(3, '여러 가지 미분법', <String>[
        '함수의 몫의 미분법',
        '합성함수의 미분법',
        '매개변수로 나타낸 함수의 미분법',
        '음함수와 역함수의 미분법',
      ]),
      _middle(4, '도함수의 활용', <String>[
        '접선의 방정식',
        '함수의 극대와 극소',
        '곡선의 볼록과 변곡점',
        '함수의 그래프',
        '함수의 최댓값과 최솟값',
        '방정식과 부등식에의 활용',
        '속도와 가속도',
      ]),
    ]),
    _major('III', '적분법', <_MiddleUnitDraft>[
      _middle(1, '여러 가지 함수의 적분', <String>[
        '여러 가지 함수의 부정적분',
        '여러 가지 함수의 정적분',
      ]),
      _middle(2, '치환적분법과 부분적분법', <String>[
        '치환적분법',
        '부분적분법',
        '정적분으로 정의된 함수',
      ]),
      _middle(3, '정적분의 활용', <String>[
        '구분구적법',
        '정적분과 급수',
        '도형의 넓이',
        '입체도형의 부피',
        '속도와 거리',
      ]),
    ]),
  ];
}

List<_MajorUnitDraft> _buildProbabilityStatisticsUnits() {
  return <_MajorUnitDraft>[
    _major('I', '경우의 수', <_MiddleUnitDraft>[
      _middle(1, '순열과 조합', <String>[
        '중복순열',
        '같은 것이 있는 순열',
        '중복조합',
      ]),
      _middle(2, '이항정리', <String>[
        '이항정리',
        '이항정리의 활용',
      ]),
    ]),
    _major('II', '확률', <_MiddleUnitDraft>[
      _middle(1, '확률의 뜻과 활용', <String>[
        '시행과 사건',
        '확률의 뜻',
        '확률의 덧셈정리',
      ]),
      _middle(2, '조건부확률', <String>[
        '조건부확률',
        '사건의 독립과 종속',
        '독립시행의 확률',
      ]),
    ]),
    _major('III', '통계', <_MiddleUnitDraft>[
      _middle(1, '확률분포', <String>[
        '확률변수와 확률분포',
        '이산확률변수의 기댓값과 표준편차',
        '이항분포',
        '연속확률변수의 확률분포',
        '정규분포',
        '이항분포와 정규분포의 관계',
      ]),
      _middle(2, '통계적 추정', <String>[
        '모집단과 표본',
        '모평균과 표본평균',
        '모비율과 표본비율',
        '모평균의 추정',
        '모비율의 추정',
      ]),
    ]),
  ];
}

List<_MajorUnitDraft> _buildGeometryUnits() {
  return <_MajorUnitDraft>[
    _major('I', '이차곡선', <_MiddleUnitDraft>[
      _middle(1, '이차곡선', <String>[
        '포물선의 방정식',
        '타원의 방정식',
        '쌍곡선의 방정식',
        '이차곡선',
      ]),
      _middle(2, '이차곡선의 접선', <String>[
        '포물선의 접선의 방정식',
        '타원의 접선의 방정식',
        '쌍곡선의 접선의 방정식',
      ]),
    ]),
    _major('II', '공간도형과 공간좌표', <_MiddleUnitDraft>[
      _middle(1, '공간도형', <String>[
        '직선과 평면의 위치 관계',
        '직선과 평면의 평행',
        '직선과 평면의 수직',
        '삼수선 정리',
        '이면각',
        '정사영',
      ]),
      _middle(2, '공간좌표', <String>[
        '공간좌표',
        '두 점 사이의 거리',
        '선분의 내분점',
        '구의 방정식',
      ]),
    ]),
    _major('III', '벡터', <_MiddleUnitDraft>[
      _middle(1, '벡터의 연산', <String>[
        '벡터의 뜻',
        '벡터의 덧셈과 뺄셈',
        '벡터의 실수배',
      ]),
      _middle(2, '벡터의 성분과 내적', <String>[
        '위치벡터',
        '평면벡터의 성분',
        '공간벡터의 성분',
        '벡터의 내적',
        '벡터의 내적과 두 벡터가 이루는 각',
      ]),
      _middle(3, '도형의 방정식', <String>[
        '직선의 방정식',
        '두 직선이 이루는 각',
        '평면의 방정식',
        '두 평면이 이루는 각',
        '점과 평면 사이의 거리',
        '벡터를 이용한 구의 방정식',
      ]),
    ]),
  ];
}
