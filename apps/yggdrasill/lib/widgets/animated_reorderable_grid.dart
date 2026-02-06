import 'dart:math' as math;
import 'package:flutter/material.dart';

typedef AnimatedReorderableGridItemBuilder<T> = Widget Function(BuildContext context, T item);

class AnimatedReorderableGrid<T extends Object> extends StatefulWidget {
  const AnimatedReorderableGrid({
    super.key,
    required this.items,
    required this.itemId,
    required this.itemBuilder,
    required this.onReorder,
    required this.cardWidth,
    required this.cardHeight,
    required this.spacing,
    required this.columns,
    this.scrollController,
    this.feedbackBuilder,
    this.animationDuration = const Duration(milliseconds: 180),
    this.animationCurve = Curves.easeOutCubic,
    this.dragFeedbackOpacity = 0.9,
    this.autoScrollEdge = 60.0,
    this.autoScrollStep = 18.0,
    this.enableReorder = true,
  });

  final List<T> items;
  final String Function(T item) itemId;
  final AnimatedReorderableGridItemBuilder<T> itemBuilder;
  final AnimatedReorderableGridItemBuilder<T>? feedbackBuilder;
  final void Function(T item, int toIndex) onReorder;
  final double cardWidth;
  final double cardHeight;
  final double spacing;
  final int columns;
  final ScrollController? scrollController;
  final Duration animationDuration;
  final Curve animationCurve;
  final double dragFeedbackOpacity;
  final double autoScrollEdge;
  final double autoScrollStep;
  final bool enableReorder;

  @override
  State<AnimatedReorderableGrid<T>> createState() => _AnimatedReorderableGridState<T>();
}

class _AnimatedReorderableGridState<T extends Object> extends State<AnimatedReorderableGrid<T>> {
  final GlobalKey _viewportKey = GlobalKey();
  ScrollController? _ownedScrollCtrl;
  String? _draggingId;
  int? _pendingDropIndex;

  ScrollController get _scrollCtrl => widget.scrollController ?? _ownedScrollCtrl!;

  @override
  void initState() {
    super.initState();
    if (widget.scrollController == null) {
      _ownedScrollCtrl = ScrollController();
    }
  }

  @override
  void didUpdateWidget(covariant AnimatedReorderableGrid<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      if (oldWidget.scrollController == null) {
        _ownedScrollCtrl?.dispose();
      }
      _ownedScrollCtrl = widget.scrollController == null ? ScrollController() : null;
    }
    if (_draggingId != null && widget.items.indexWhere((e) => widget.itemId(e) == _draggingId) == -1) {
      _draggingId = null;
      _pendingDropIndex = null;
    }
  }

  @override
  void dispose() {
    _ownedScrollCtrl?.dispose();
    super.dispose();
  }

  List<T> _buildPreviewItems() {
    if (_draggingId == null) return widget.items;
    final dragIndex = widget.items.indexWhere((e) => widget.itemId(e) == _draggingId);
    if (dragIndex == -1) return widget.items;
    final list = List<T>.from(widget.items);
    final moved = list.removeAt(dragIndex);
    final insertAt = (_pendingDropIndex ?? dragIndex).clamp(0, list.length);
    list.insert(insertAt, moved);
    return list;
  }

  void _handleDragMove(Offset globalPosition, T incoming) {
    if (!widget.enableReorder) return;
    final id = widget.itemId(incoming);
    if (_draggingId == null || id != _draggingId) return;
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final gridWidth = (widget.columns * widget.cardWidth) + ((widget.columns - 1) * widget.spacing);
    final local = box.globalToLocal(globalPosition);
    final maxX = math.max(0.0, gridWidth - 1);
    final x = local.dx.clamp(0.0, maxX);
    final scrollOffset = _scrollCtrl.hasClients ? _scrollCtrl.offset : 0.0;
    final y = (local.dy + scrollOffset).clamp(0.0, double.infinity);
    final slotWidth = widget.cardWidth + widget.spacing;
    final slotHeight = widget.cardHeight + widget.spacing;
    var col = (x / slotWidth).floor();
    final colOffset = x - (col * slotWidth);
    if (colOffset > widget.cardWidth) col += 1;
    col = col.clamp(0, widget.columns);
    var row = (y / slotHeight).floor();
    final rowOffset = y - (row * slotHeight);
    if (rowOffset > widget.cardHeight) row += 1;
    var targetIndex = row * widget.columns + col;
    final maxIndex = math.max(0, widget.items.length - 1);
    targetIndex = targetIndex.clamp(0, maxIndex);
    if (_pendingDropIndex != targetIndex) {
      setState(() => _pendingDropIndex = targetIndex);
    }
    _maybeAutoScroll(local.dy, box.size.height);
  }

  int _calcDropIndexFromGlobal(Offset globalPosition) {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return math.max(0, widget.items.length - 1);
    final gridWidth = (widget.columns * widget.cardWidth) + ((widget.columns - 1) * widget.spacing);
    final local = box.globalToLocal(globalPosition);
    final maxX = math.max(0.0, gridWidth - 1);
    final x = local.dx.clamp(0.0, maxX);
    final scrollOffset = _scrollCtrl.hasClients ? _scrollCtrl.offset : 0.0;
    final y = (local.dy + scrollOffset).clamp(0.0, double.infinity);
    final slotWidth = widget.cardWidth + widget.spacing;
    final slotHeight = widget.cardHeight + widget.spacing;
    var col = (x / slotWidth).floor();
    final colOffset = x - (col * slotWidth);
    if (colOffset > widget.cardWidth) col += 1;
    col = col.clamp(0, widget.columns);
    var row = (y / slotHeight).floor();
    final rowOffset = y - (row * slotHeight);
    if (rowOffset > widget.cardHeight) row += 1;
    var targetIndex = row * widget.columns + col;
    final maxIndex = math.max(0, widget.items.length - 1);
    targetIndex = targetIndex.clamp(0, maxIndex);
    return targetIndex;
  }

  void _maybeAutoScroll(double localDy, double viewportHeight) {
    if (!_scrollCtrl.hasClients) return;
    final edge = widget.autoScrollEdge;
    final step = widget.autoScrollStep;
    final offset = _scrollCtrl.offset;
    final max = _scrollCtrl.position.maxScrollExtent;
    if (localDy < edge && offset > 0) {
      _scrollCtrl.jumpTo(math.max(0.0, offset - step));
    } else if (localDy > viewportHeight - edge && offset < max) {
      _scrollCtrl.jumpTo(math.min(max, offset + step));
    }
  }

  void _clearDragState() {
    if (!mounted) return;
    if (_draggingId == null && _pendingDropIndex == null) return;
    setState(() {
      _draggingId = null;
      _pendingDropIndex = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final previewItems = _buildPreviewItems();
    final rowCount = (previewItems.length / widget.columns).ceil();
    final contentHeight = rowCount == 0
        ? widget.cardHeight
        : (rowCount * widget.cardHeight) + ((rowCount - 1) * widget.spacing);
    final gridWidth = (widget.columns * widget.cardWidth) + ((widget.columns - 1) * widget.spacing);

    Widget buildDraggableItem(T item, int index) {
      final isDragging = _draggingId == widget.itemId(item);
      final cell = Opacity(
        opacity: isDragging ? 0.0 : 1.0,
        child: SizedBox.expand(child: widget.itemBuilder(context, item)),
      );
      final feedback = widget.feedbackBuilder ?? widget.itemBuilder;
      return LongPressDraggable<T>(
        key: ValueKey('reorder-drag-${widget.itemId(item)}'),
        data: item,
        hapticFeedbackOnStart: true,
        dragAnchorStrategy: childDragAnchorStrategy,
        feedback: Material(
          color: Colors.transparent,
          child: Opacity(
            opacity: widget.dragFeedbackOpacity,
            child: SizedBox(
              width: widget.cardWidth,
              height: widget.cardHeight,
              child: feedback(context, item),
            ),
          ),
        ),
        childWhenDragging: cell,
        onDragStarted: () {
          setState(() {
            _draggingId = widget.itemId(item);
            _pendingDropIndex = index;
          });
        },
        onDragEnd: (_) => _clearDragState(),
        onDraggableCanceled: (_, __) => _clearDragState(),
        child: cell,
      );
    }

    return DragTarget<T>(
      onWillAccept: (data) => widget.enableReorder && data != null,
      onMove: (details) => _handleDragMove(details.offset, details.data),
      onAcceptWithDetails: (details) {
        if (!widget.enableReorder) return;
        final targetIndex = _calcDropIndexFromGlobal(details.offset);
        widget.onReorder(details.data, targetIndex);
        _clearDragState();
      },
      builder: (context, cand, rej) {
        return SizedBox(
          key: _viewportKey,
          width: gridWidth,
          child: SingleChildScrollView(
            controller: _scrollCtrl,
            child: SizedBox(
              width: gridWidth,
              height: contentHeight,
              child: Stack(
                children: [
                  for (int i = 0; i < previewItems.length; i++)
                    AnimatedPositioned(
                      key: ValueKey('reorder-pos-${widget.itemId(previewItems[i])}'),
                      duration: widget.animationDuration,
                      curve: widget.animationCurve,
                      left: (i % widget.columns) * (widget.cardWidth + widget.spacing),
                      top: (i ~/ widget.columns) * (widget.cardHeight + widget.spacing),
                      width: widget.cardWidth,
                      height: widget.cardHeight,
                      child: buildDraggableItem(previewItems[i], i),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
