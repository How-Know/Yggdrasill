import 'package:flutter/material.dart';

/// 드래그로 셀을 세로로 다중 선택할 수 있게 해주는 위젯
/// - 드래그 시작/종료 blockIdx, dayIdx 관리
/// - 드래그 영역 하이라이트
/// - 드래그 완료 시 선택된 셀의 blockIdx 리스트 콜백
class TimetableDragSelector extends StatefulWidget {
  final int dayIdx;
  final int blockCount;
  final Widget Function(BuildContext, Set<int> highlightedBlocks, void Function(int) onCellTap) builder;
  final void Function(List<int> selectedBlockIdxs) onDragSelectComplete;
  final bool enabled;

  const TimetableDragSelector({
    Key? key,
    required this.dayIdx,
    required this.blockCount,
    required this.builder,
    required this.onDragSelectComplete,
    this.enabled = true,
  }) : super(key: key);

  @override
  State<TimetableDragSelector> createState() => _TimetableDragSelectorState();
}

class _TimetableDragSelectorState extends State<TimetableDragSelector> {
  int? dragStartIdx;
  int? dragEndIdx;
  bool isDragging = false;

  Set<int> get highlightedBlocks {
    if (dragStartIdx == null || dragEndIdx == null) return {};
    final start = dragStartIdx!;
    final end = dragEndIdx!;
    if (start <= end) {
      return {for (int i = start; i <= end; i++) i};
    } else {
      return {for (int i = end; i <= start; i++) i};
    }
  }

  void _onCellTap(int blockIdx) {
    if (!widget.enabled) return;
    setState(() {
      dragStartIdx = blockIdx;
      dragEndIdx = blockIdx;
      isDragging = true;
    });
  }

  void _onCellDragUpdate(int blockIdx) {
    if (!widget.enabled || !isDragging) return;
    setState(() {
      dragEndIdx = blockIdx;
    });
  }

  void _onCellDragEnd() {
    if (!widget.enabled || !isDragging) return;
    setState(() {
      isDragging = false;
    });
    if (dragStartIdx != null && dragEndIdx != null) {
      final start = dragStartIdx!;
      final end = dragEndIdx!;
      final selected = <int>[];
      if (start <= end) {
        for (int i = start; i <= end; i++) selected.add(i);
      } else {
        for (int i = end; i <= start; i++) selected.add(i);
      }
      widget.onDragSelectComplete(selected);
    }
    dragStartIdx = null;
    dragEndIdx = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerUp: (_) => _onCellDragEnd(),
      child: widget.builder(context, highlightedBlocks, (blockIdx) {
        if (!isDragging) {
          _onCellTap(blockIdx);
        } else {
          _onCellDragUpdate(blockIdx);
        }
      }),
    );
  }
} 