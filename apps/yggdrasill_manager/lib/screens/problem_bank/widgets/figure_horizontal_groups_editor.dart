import 'package:flutter/material.dart';

/// 문항 그림들을 "가로 묶음" 으로 그룹화하는 편집 위젯.
///
/// 기존 UI 는 "두 그림 짝"만 지원해 3개 이상 가로 배치를 표현할 수 없었다.
/// 이 위젯은 N개 멤버 그룹을 자유롭게 만들고 해제할 수 있다.
///
/// UI: 각 그룹을 카드로 표시, 카드 안에는 해당 그룹에 속한 그림 칩과
/// "추가" 드롭다운. 한 그림은 한 그룹에만 속할 수 있다(상호 배타).
///
/// 동작 계약 (중요):
/// - `onChanged(groups)` 는 **편집 중인 전체 상태**(빈 그룹/1명 그룹 포함)를
///   그대로 부모에 알린다. "묶음 추가" 직후 빈 카드 상태도 부모에 반영돼야
///   다음 리빌드에서 카드가 사라지지 않기 때문. 저장 시 유효성(길이 ≥ 2)은
///   호출 측이 판단한다.
/// - 위젯은 외부 `initialGroups` 가 바뀌면 내부 상태를 재동기화한다.
///   즉 controlled 형태로 사용 가능.
class FigureHorizontalGroupsEditor extends StatefulWidget {
  const FigureHorizontalGroupsEditor({
    super.key,
    required this.availableKeys,
    required this.labels,
    required this.initialGroups,
    required this.onChanged,
    this.minGroupSize = 2,
    this.accentColor = const Color(0xFF60A5FA),
    this.textColor = const Color(0xFFE5E7EB),
    this.mutedColor = const Color(0xFF9CA3AF),
    this.borderColor = const Color(0xFF3F3F46),
    this.fieldColor = const Color(0xFF1F1F23),
  });

  final List<String> availableKeys;
  final Map<String, String> labels;
  final List<List<String>> initialGroups;
  final ValueChanged<List<List<String>>> onChanged;
  final int minGroupSize;

  final Color accentColor;
  final Color textColor;
  final Color mutedColor;
  final Color borderColor;
  final Color fieldColor;

  @override
  State<FigureHorizontalGroupsEditor> createState() =>
      _FigureHorizontalGroupsEditorState();
}

class _FigureHorizontalGroupsEditorState
    extends State<FigureHorizontalGroupsEditor> {
  // 편집 중인 그룹 상태. 멤버 순서는 사용자가 추가한 순서대로 유지하되
  // 한 그림은 여러 그룹에 존재할 수 없다.
  late List<List<String>> _groups;

  @override
  void initState() {
    super.initState();
    _groups = _sanitizeGroups(widget.initialGroups, keepEmpty: true);
  }

  @override
  void didUpdateWidget(covariant FigureHorizontalGroupsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 이 위젯은 controlled 형태로 동작해야 한다:
    //  1) 부모가 `initialGroups` 를 바꾸면 그 값을 "권위 있는 상태" 로 받아들인다.
    //  2) 단, 부모가 준 값과 내부 상태가 이미 같으면 setState 생략(무한 리빌드 방지).
    //  3) availableKeys 변경 시 존재하지 않는 키는 정리한다.
    final externalNext = _sanitizeGroups(widget.initialGroups, keepEmpty: true);
    final externalChanged = !_sameGroups(externalNext, oldWidget.initialGroups);
    final internalNeedsCleanup = !_sameGroups(
      _sanitizeGroups(_groups, keepEmpty: true),
      _groups,
    );
    if (externalChanged && !_sameGroups(externalNext, _groups)) {
      setState(() {
        _groups = externalNext;
      });
      return;
    }
    if (internalNeedsCleanup) {
      setState(() {
        _groups = _sanitizeGroups(_groups, keepEmpty: true);
      });
    }
  }

  /// 빈 그룹/유효하지 않은 키를 정리한다.
  /// `keepEmpty` 가 true 이면 "멤버가 모두 제거된 그룹" 도 구조는 유지 (사용자가
  /// 방금 만든 빈 카드가 리빌드 때문에 사라지지 않게 하기 위함).
  List<List<String>> _sanitizeGroups(
    List<List<String>> raw, {
    bool keepEmpty = false,
  }) {
    final allowed = widget.availableKeys.toSet();
    final seen = <String>{};
    final out = <List<String>>[];
    for (final group in raw) {
      final cleaned = <String>[];
      for (final k in group) {
        final key = k.trim();
        if (key.isEmpty) continue;
        if (!allowed.contains(key)) continue;
        if (!seen.add(key)) continue;
        cleaned.add(key);
      }
      if (cleaned.isNotEmpty || keepEmpty) out.add(cleaned);
    }
    return out;
  }

  bool _sameGroups(List<List<String>> a, List<List<String>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      final ai = a[i];
      final bi = b[i];
      if (ai.length != bi.length) return false;
      for (var j = 0; j < ai.length; j += 1) {
        if (ai[j] != bi[j]) return false;
      }
    }
    return true;
  }

  /// 편집 중인 "전체 상태" 를 그대로 부모에 전달한다. 빈/1명 그룹도 포함 —
  /// 부모가 이 값을 setState 로 다시 widget.initialGroups 에 반영해도
  /// 현재 UI 상태가 유지되도록 하기 위함.
  void _emitChanged() {
    widget.onChanged(<List<String>>[
      for (final g in _groups) List<String>.from(g),
    ]);
  }

  Set<String> _assignedKeys() {
    final out = <String>{};
    for (final g in _groups) {
      out.addAll(g);
    }
    return out;
  }

  void _addGroup() {
    setState(() {
      _groups = <List<String>>[..._groups, <String>[]];
    });
    _emitChanged();
  }

  void _removeGroup(int index) {
    setState(() {
      final next = <List<String>>[..._groups];
      next.removeAt(index);
      _groups = next;
    });
    _emitChanged();
  }

  void _addKeyToGroup(int index, String key) {
    if (key.isEmpty) return;
    setState(() {
      final next = <List<String>>[
        for (final g in _groups) <String>[...g]..remove(key),
      ];
      if (index < 0 || index >= next.length) {
        next.add(<String>[key]);
      } else {
        next[index] = <String>[...next[index], key];
      }
      _groups = next;
    });
    _emitChanged();
  }

  void _removeKeyFromGroup(int groupIdx, String key) {
    setState(() {
      if (groupIdx < 0 || groupIdx >= _groups.length) return;
      final next = <List<String>>[
        for (var i = 0; i < _groups.length; i += 1)
          i == groupIdx
              ? (<String>[..._groups[i]]..remove(key))
              : <String>[..._groups[i]],
      ];
      // 그룹이 비면 구조는 유지(사용자가 다시 그림을 추가할 수 있게). 완전히 없애려면
      // 카드 우측 "묶음 제거" 버튼을 사용.
      _groups = next;
    });
    _emitChanged();
  }

  String _labelFor(String key) => widget.labels[key] ?? key;

  @override
  Widget build(BuildContext context) {
    if (widget.availableKeys.length < 2) {
      return const SizedBox.shrink();
    }
    final assigned = _assignedKeys();
    final hasAnyGroup = _groups.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.view_week, size: 14, color: widget.mutedColor),
            const SizedBox(width: 6),
            Text(
              '가로 묶음 (한 줄에 여러 그림 배치)',
              style: TextStyle(
                color: widget.mutedColor,
                fontSize: 11.6,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _addGroup,
              icon: Icon(Icons.add, size: 14, color: widget.accentColor),
              label: Text(
                '묶음 추가',
                style: TextStyle(
                  fontSize: 11.2,
                  color: widget.accentColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                minimumSize: const Size(0, 24),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        if (!hasAnyGroup)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              '아직 묶음 없음. 같은 줄에 배치할 그림들을 묶으려면 "묶음 추가" 를 누르세요.',
              style: TextStyle(
                color: widget.mutedColor,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        for (var i = 0; i < _groups.length; i += 1)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _buildGroupCard(i, assigned),
          ),
      ],
    );
  }

  Widget _buildGroupCard(int groupIndex, Set<String> assigned) {
    final group = _groups[groupIndex];
    final availableToAdd = widget.availableKeys
        .where((k) => !assigned.contains(k) || group.contains(k))
        .where((k) => !group.contains(k))
        .toList(growable: false);
    final isValid = group.length >= widget.minGroupSize;

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: widget.fieldColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isValid
              ? widget.accentColor.withValues(alpha: 0.55)
              : widget.borderColor,
          width: isValid ? 1.1 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '묶음 ${groupIndex + 1}',
                style: TextStyle(
                  color: widget.textColor,
                  fontSize: 11.6,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 6),
              if (!isValid)
                Text(
                  '(2개 이상이어야 적용됨)',
                  style: TextStyle(
                    color: widget.mutedColor,
                    fontSize: 10.6,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              const Spacer(),
              IconButton(
                tooltip: '묶음 제거',
                onPressed: () => _removeGroup(groupIndex),
                icon: Icon(Icons.delete_outline,
                    size: 16, color: widget.mutedColor),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final key in group)
                InputChip(
                  label: Text(
                    _labelFor(key),
                    style: const TextStyle(fontSize: 11.2),
                  ),
                  onDeleted: () => _removeKeyFromGroup(groupIndex, key),
                  deleteIconColor: widget.mutedColor,
                  backgroundColor:
                      widget.accentColor.withValues(alpha: 0.14),
                  labelStyle: TextStyle(
                    color: widget.textColor,
                    fontWeight: FontWeight.w700,
                  ),
                  side: BorderSide(
                    color: widget.accentColor.withValues(alpha: 0.55),
                  ),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              if (availableToAdd.isNotEmpty)
                _buildAddButton(groupIndex, availableToAdd),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAddButton(int groupIndex, List<String> candidates) {
    return PopupMenuButton<String>(
      tooltip: '그림 추가',
      onSelected: (k) => _addKeyToGroup(groupIndex, k),
      itemBuilder: (_) => [
        for (final k in candidates)
          PopupMenuItem<String>(
            value: k,
            child: Text(_labelFor(k)),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: widget.accentColor.withValues(alpha: 0.45),
            style: BorderStyle.solid,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 13, color: widget.accentColor),
            const SizedBox(width: 3),
            Text(
              '그림 추가',
              style: TextStyle(
                color: widget.accentColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
