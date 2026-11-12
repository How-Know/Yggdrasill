import 'dart:math' as math;
import 'package:flutter/material.dart';

typedef AnimatedReorderableGridItemBuilder<T> = Widget Function(
  BuildContext context,
  T item,
);

typedef AnimatedReorderableGridItemHeightBuilder<T> = double Function(T item);

typedef AnimatedReorderableGridRowFooterBuilder<T> = Widget? Function(
  BuildContext context,
  int rowIndex,
  List<T> rowItems,
);

typedef AnimatedReorderableGridRowFooterHeightBuilder<T> = double Function(
  int rowIndex,
  List<T> rowItems,
);

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
    this.itemHeightBuilder,
    this.rowFooterBuilder,
    this.rowFooterHeightBuilder,
    this.scrollController,
    this.feedbackBuilder,
    this.animationDuration = const Duration(milliseconds: 180),
    this.animationCurve = Curves.easeOutCubic,
    this.dragFeedbackOpacity = 0.9,
    this.autoScrollEdge = 60.0,
    this.autoScrollStep = 18.0,
    this.enableReorder = true,
    this.dragAnchorStrategy = childDragAnchorStrategy,
    this.onDragStarted,
    this.onDragEnded,
    this.scrollBottomPadding = 0,
    this.scrollTopPadding = 0,
  });

  /// 스크롤 영역 맨 아래에 비워 둘 높이(오버레이 FAB 등). 뷰포트는 줄이지 않음.
  final double scrollBottomPadding;

  /// 스크롤 영역 맨 위에 비워 둘 높이(플로팅 페이지 타이틀 등). 뷰포트는 줄이지 않음.
  final double scrollTopPadding;

  final List<T> items;
  final String Function(T item) itemId;
  final AnimatedReorderableGridItemBuilder<T> itemBuilder;
  final AnimatedReorderableGridItemBuilder<T>? feedbackBuilder;
  final AnimatedReorderableGridItemHeightBuilder<T>? itemHeightBuilder;
  final AnimatedReorderableGridRowFooterBuilder<T>? rowFooterBuilder;
  final AnimatedReorderableGridRowFooterHeightBuilder<T>? rowFooterHeightBuilder;
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
  final DragAnchorStrategy dragAnchorStrategy;
  final void Function(T item)? onDragStarted;
  final void Function(T item)? onDragEnded;

  @override
  State<AnimatedReorderableGrid<T>> createState() =>
      _AnimatedReorderableGridState<T>();
}

class _RowMetrics<T> {
  const _RowMetrics({
    required this.rowIndex,
    required this.top,
    required this.cardsHeight,
    required this.footerHeight,
    required this.items,
    required this.itemHeights,
  });

  final int rowIndex;
  final double top;
  final double cardsHeight;
  final double footerHeight;
  final List<T> items;
  final List<double> itemHeights;

  double get totalHeight =>
      cardsHeight + (footerHeight > 0 ? footerHeight : 0.0);
}

class _AnimatedReorderableGridState<T extends Object>
    extends State<AnimatedReorderableGrid<T>> {
  final GlobalKey _viewportKey = GlobalKey();
  ScrollController? _ownedScrollCtrl;
  String? _draggingId;
  int? _pendingDropIndex;

  ScrollController get _scrollCtrl =>
      widget.scrollController ?? _ownedScrollCtrl!;

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
      _ownedScrollCtrl =
          widget.scrollController == null ? ScrollController() : null;
    }
    if (_draggingId != null &&
        widget.items.indexWhere((e) => widget.itemId(e) == _draggingId) == -1) {
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
    final dragIndex =
        widget.items.indexWhere((e) => widget.itemId(e) == _draggingId);
    if (dragIndex == -1) return widget.items;
    final list = List<T>.from(widget.items);
    final moved = list.removeAt(dragIndex);
    final insertAt = (_pendingDropIndex ?? dragIndex).clamp(0, list.length);
    list.insert(insertAt, moved);
    return list;
  }

  double _itemHeight(T item) {
    final custom = widget.itemHeightBuilder?.call(item);
    if (custom == null || !custom.isFinite || custom <= 0) {
      return widget.cardHeight;
    }
    return math.max(widget.cardHeight, custom);
  }

  List<_RowMetrics<T>> _computeRowMetrics(List<T> items) {
    if (items.isEmpty) return const [];
    final rowCount = (items.length / widget.columns).ceil();
    final out = <_RowMetrics<T>>[];
    var y = 0.0;
    for (var r = 0; r < rowCount; r++) {
      final start = r * widget.columns;
      final end = math.min(start + widget.columns, items.length);
      final rowItems = items.sublist(start, end);
      final itemHeights = <double>[
        for (final it in rowItems) _itemHeight(it),
      ];
      var cardsHeight = widget.cardHeight;
      for (final h in itemHeights) {
        if (h > cardsHeight) cardsHeight = h;
      }
      final rawFooterHeight =
          widget.rowFooterHeightBuilder?.call(r, rowItems) ?? 0.0;
      final footerHeight = rawFooterHeight > 0
          ? rawFooterHeight + widget.spacing
          : 0.0;
      out.add(
        _RowMetrics<T>(
          rowIndex: r,
          top: y,
          cardsHeight: cardsHeight,
          footerHeight: footerHeight,
          items: rowItems,
          itemHeights: itemHeights,
        ),
      );
      y += cardsHeight + footerHeight + widget.spacing;
    }
    return out;
  }

  int _rowForOffsetY(double y, List<_RowMetrics<T>> rows) {
    if (rows.isEmpty) return 0;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final rowBottom = row.top + row.totalHeight;
      if (y <= rowBottom) return i;
    }
    return rows.length - 1;
  }

  void _handleDragMove(Offset globalPosition, T incoming) {
    if (!widget.enableReorder) return;
    final id = widget.itemId(incoming);
    if (_draggingId == null || id != _draggingId) return;
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final gridWidth = (widget.columns * widget.cardWidth) +
        ((widget.columns - 1) * widget.spacing);
    final local = box.globalToLocal(globalPosition);
    final maxX = math.max(0.0, gridWidth - 1);
    final x = local.dx.clamp(0.0, maxX);
    final scrollOffset = _scrollCtrl.hasClients ? _scrollCtrl.offset : 0.0;
    final y = (local.dy + scrollOffset - widget.scrollTopPadding)
        .clamp(0.0, double.infinity);
    final slotWidth = widget.cardWidth + widget.spacing;
    var col = (x / slotWidth).floor();
    final colOffset = x - (col * slotWidth);
    if (colOffset > widget.cardWidth) col += 1;
    col = col.clamp(0, widget.columns);
    final rows = _computeRowMetrics(_buildPreviewItems());
    final row = _rowForOffsetY(y, rows);
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
    final gridWidth = (widget.columns * widget.cardWidth) +
        ((widget.columns - 1) * widget.spacing);
    final local = box.globalToLocal(globalPosition);
    final maxX = math.max(0.0, gridWidth - 1);
    final x = local.dx.clamp(0.0, maxX);
    final scrollOffset = _scrollCtrl.hasClients ? _scrollCtrl.offset : 0.0;
    final y = (local.dy + scrollOffset - widget.scrollTopPadding)
        .clamp(0.0, double.infinity);
    final slotWidth = widget.cardWidth + widget.spacing;
    var col = (x / slotWidth).floor();
    final colOffset = x - (col * slotWidth);
    if (colOffset > widget.cardWidth) col += 1;
    col = col.clamp(0, widget.columns);
    final rows = _computeRowMetrics(_buildPreviewItems());
    final row = _rowForOffsetY(y, rows);
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
    final rows = _computeRowMetrics(previewItems);
    final baseContentHeight = rows.isEmpty
        ? widget.cardHeight
        : rows.last.top + rows.last.totalHeight;
    final contentHeight =
        baseContentHeight + widget.scrollBottomPadding + widget.scrollTopPadding;
    final gridWidth = (widget.columns * widget.cardWidth) +
        ((widget.columns - 1) * widget.spacing);

    Widget buildDraggableItem(T item, int index, double itemHeight) {
      final isDragging = _draggingId == widget.itemId(item);
      final cell = Opacity(
        opacity: isDragging ? 0.0 : 1.0,
        child: SizedBox.expand(child: widget.itemBuilder(context, item)),
      );
      if (!widget.enableReorder) return cell;
      final feedback = widget.feedbackBuilder ?? widget.itemBuilder;
      return LongPressDraggable<T>(
        key: ValueKey('reorder-drag-${widget.itemId(item)}'),
        data: item,
        hapticFeedbackOnStart: true,
        dragAnchorStrategy: widget.dragAnchorStrategy,
        feedback: Material(
          color: Colors.transparent,
          child: Opacity(
            opacity: widget.dragFeedbackOpacity,
            child: SizedBox(
              width: widget.cardWidth,
              height: itemHeight,
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
          widget.onDragStarted?.call(item);
        },
        onDragEnd: (_) {
          widget.onDragEnded?.call(item);
          _clearDragState();
        },
        onDraggableCanceled: (_, __) {
          widget.onDragEnded?.call(item);
          _clearDragState();
        },
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
            clipBehavior: Clip.none,
            controller: _scrollCtrl,
            child: SizedBox(
              width: gridWidth,
              height: contentHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final row in rows) ...[
                    for (var c = 0; c < row.items.length; c++)
                      Builder(
                        builder: (context) {
                          final item = row.items[c];
                          final itemHeight = row.itemHeights[c];
                          final globalIndex =
                              row.rowIndex * widget.columns + c;
                          return AnimatedPositioned(
                            key: ValueKey(
                              'reorder-pos-${widget.itemId(item)}',
                            ),
                            duration: widget.animationDuration,
                            curve: widget.animationCurve,
                            left: c * (widget.cardWidth + widget.spacing),
                            top: widget.scrollTopPadding + row.top,
                            width: widget.cardWidth,
                            height: itemHeight,
                            child: buildDraggableItem(
                              item,
                              globalIndex,
                              itemHeight,
                            ),
                          );
                        },
                      ),
                    if (row.footerHeight > 0 && widget.rowFooterBuilder != null)
                      Builder(
                        builder: (context) {
                          final footer = widget.rowFooterBuilder!(
                            context,
                            row.rowIndex,
                            row.items,
                          );
                          if (footer == null) return const SizedBox.shrink();
                          return AnimatedPositioned(
                            key: ValueKey('reorder-row-footer-${row.rowIndex}'),
                            duration: widget.animationDuration,
                            curve: widget.animationCurve,
                            left: 0,
                            top: widget.scrollTopPadding +
                                row.top +
                                row.cardsHeight +
                                widget.spacing,
                            width: gridWidth,
                            height: row.footerHeight - widget.spacing,
                            child: footer,
                          );
                        },
                      ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
