import 'package:flutter/material.dart';

import '../../../services/concept_category_service.dart';
import '../../../services/concept_service.dart';
import '../../../widgets/app_navigation_bar.dart';

const double kTreeIndentStep = 18.0;
const double kTreeConnectorWidth = 12.0;
const double kTreeArrowSize = 16.0;
const double kTreeArrowGap = 6.0;
const double kTreeArrowOffsetX = 0.0;
const double kTreeRowPaddingX = 8.0;
const double kTreeLineWidth = 2.0;
const double kTreeCornerRadius = 10.0;
const Color kTreeLineColor = Color(0xFF2A2A2A);
const Color kTreeAccentColor = kNavAccent;

class CategoryTree extends StatefulWidget {
  const CategoryTree({
    super.key,
    required this.roots,
    this.forceExpandNodeId,
    this.rootParentId,
    this.onSelect,
    this.onAddChild,
    this.onRename,
    this.onDelete,
    this.onReorderFolder,
    this.onTapConcept,
    this.onEditConcept,
    this.onDeleteConcept,
    this.onMoveConcept,
    this.onMoveFolder,
  });

  final List<CategoryNode> roots;
  final String? forceExpandNodeId;
  final String? rootParentId;
  final ValueChanged<CategoryNode>? onSelect;
  final Future<void> Function(CategoryNode node)? onAddChild;
  final Future<void> Function(CategoryNode node)? onRename;
  final Future<void> Function(CategoryNode node)? onDelete;
  final Future<void> Function({
    required CategoryNode node,
    required String? parentId,
    required int direction,
  })? onReorderFolder;
  final void Function(CategoryNode parent, ConceptItem concept)? onTapConcept;
  final Future<void> Function(CategoryNode parent, ConceptItem concept)?
      onEditConcept;
  final Future<void> Function(CategoryNode parent, ConceptItem concept)?
      onDeleteConcept;
  final Future<void> Function({
    required String conceptId,
    required String fromParentId,
    required String toParentId,
    int? toIndex,
  })? onMoveConcept;
  final Future<void> Function({
    required String folderId,
    required String? newParentId,
    int? newIndex,
  })? onMoveFolder;

  @override
  State<CategoryTree> createState() => _CategoryTreeState();
}

class _CategoryTreeState extends State<CategoryTree> {
  final Set<String> _expandedIds = {};
  String? _selectedCategoryId;

  @override
  void initState() {
    super.initState();
    if (widget.forceExpandNodeId != null) {
      _expandTo(widget.forceExpandNodeId!);
    }
  }

  @override
  void didUpdateWidget(covariant CategoryTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    final forceId = widget.forceExpandNodeId;
    if (forceId != null && forceId != oldWidget.forceExpandNodeId) {
      _expandTo(forceId);
      _selectedCategoryId = forceId;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.roots.isEmpty) {
      return const Center(
        child: Text(
          '표시할 폴더가 없습니다.',
          style: TextStyle(color: Colors.white54, fontSize: 16),
        ),
      );
    }
    final entries = _buildEntries(
      widget.roots,
      depth: 0,
      parentId: widget.rootParentId,
    );
    return Scrollbar(
      child: ListView.builder(
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          if (entry.type == _TreeEntryType.folder) {
            return _buildFolderRow(
              entry.node,
              entry.depth,
              entry.parentId,
              entry.index,
              entry.siblingCount,
              entry.ancestorHasNext,
              entry.hasNextSibling,
            );
          }
          return _buildConceptSection(
            entry.node,
            entry.depth,
            entry.ancestorHasNext,
            entry.hasNextSibling,
          );
        },
      ),
    );
  }

  List<_TreeEntry> _buildEntries(
    List<CategoryNode> nodes, {
    required int depth,
    required String? parentId,
    List<bool> ancestorHasNext = const [],
  }) {
    final out = <_TreeEntry>[];
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      final hasNextSibling = i < nodes.length - 1;
      final nextAncestorHasNext = [...ancestorHasNext, hasNextSibling];
      out.add(
        _TreeEntry.folder(
          node: node,
          depth: depth,
          parentId: parentId,
          index: i,
          siblingCount: nodes.length,
          ancestorHasNext: ancestorHasNext,
          hasNextSibling: hasNextSibling,
        ),
      );
      if (_expandedIds.contains(node.id)) {
        if (node.concepts.isNotEmpty) {
          final conceptHasNext = node.children.isNotEmpty;
          out.add(
            _TreeEntry.concepts(
              node: node,
              depth: depth + 1,
              ancestorHasNext: nextAncestorHasNext,
              hasNextSibling: conceptHasNext,
            ),
          );
        }
        if (node.children.isNotEmpty) {
          out.addAll(
            _buildEntries(
              node.children,
              depth: depth + 1,
              parentId: node.id,
              ancestorHasNext: nextAncestorHasNext,
            ),
          );
        }
      }
    }
    return out;
  }

  Widget _buildFolderRow(
    CategoryNode node,
    int depth,
    String? parentId,
    int index,
    int siblingCount,
    List<bool> ancestorHasNext,
    bool hasNextSibling,
  ) {
    final isExpanded = _expandedIds.contains(node.id);
    final isSelected = _selectedCategoryId == node.id;
    final hasExpandable = node.children.isNotEmpty || node.concepts.isNotEmpty;
    final baseLineX = ((depth > 0 ? depth - 1 : 0) * kTreeIndentStep) +
        (kTreeIndentStep / 2);
    final lineEndX = baseLineX + kTreeConnectorWidth;
    final arrowCenterOffset = kTreeArrowSize / 2;
    final leftInset = depth >= 0
        ? lineEndX -
            kTreeRowPaddingX -
            arrowCenterOffset +
            kTreeArrowOffsetX
        : 0.0;
    final textColor = isSelected ? kTreeAccentColor : Colors.white;
    final iconColor = isSelected ? kTreeAccentColor : Colors.white70;

    return DragTarget<_DragFolderPayload>(
      onWillAccept: (payload) =>
          payload != null &&
          payload.node.id != node.id &&
          !_contains(payload.node, node.id),
      onAccept: (payload) => widget.onMoveFolder?.call(
        folderId: payload.node.id,
        newParentId: node.id,
      ),
      builder: (context, candidate, rejected) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Stack(
            children: [
              if (depth > 0)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _TreeIndentPainter(
                      depth: depth,
                      ancestorHasNext: ancestorHasNext,
                      hasNextSibling: hasNextSibling,
                      indentStep: kTreeIndentStep,
                      connectorWidth: kTreeConnectorWidth,
                      lineColor: kTreeLineColor,
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.only(left: leftInset),
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedCategoryId = node.id;
                      if (hasExpandable) {
                        if (isExpanded) {
                          _expandedIds.remove(node.id);
                        } else {
                          _expandedIds.add(node.id);
                        }
                      }
                    });
                    widget.onSelect?.call(node);
                  },
                  onDoubleTap: () => _expandAll(node),
                  child: LongPressDraggable<_DragFolderPayload>(
                    data: _DragFolderPayload(node),
                    feedback: _DragFolderFeedback(name: node.name),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: kTreeRowPaddingX,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.transparent),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isExpanded
                                ? Icons.keyboard_arrow_down
                                : Icons.keyboard_arrow_right,
                            size: 16,
                            color: iconColor,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              node.name,
                              style: TextStyle(
                                color: textColor,
                                fontSize: 16,
                                fontWeight:
                                    isSelected ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                          ),
                          _buildFolderActions(
                            node,
                            parentId: parentId,
                            index: index,
                            siblingCount: siblingCount,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFolderActions(
    CategoryNode node, {
    required String? parentId,
    required int index,
    required int siblingCount,
  }) {
    final canMoveUp = parentId != null && index > 0;
    final canMoveDown = parentId != null && index < siblingCount - 1;
    final canAddChild = widget.onAddChild != null;
    final canRename = widget.onRename != null;
    final canDelete = widget.onDelete != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(
            Icons.keyboard_arrow_up,
            size: 18,
            color: canMoveUp ? kTreeAccentColor : Colors.white24,
          ),
          tooltip: '위로',
          onPressed: !canMoveUp || widget.onReorderFolder == null
              ? null
              : () => widget.onReorderFolder!(
                    node: node,
                    parentId: parentId,
                    direction: -1,
                  ),
        ),
        IconButton(
          icon: Icon(
            Icons.keyboard_arrow_down,
            size: 18,
            color: canMoveDown ? kTreeAccentColor : Colors.white24,
          ),
          tooltip: '아래로',
          onPressed: !canMoveDown || widget.onReorderFolder == null
              ? null
              : () => widget.onReorderFolder!(
                    node: node,
                    parentId: parentId,
                    direction: 1,
                  ),
        ),
        IconButton(
          icon: Icon(
            Icons.create_new_folder_outlined,
            size: 16,
            color: canAddChild ? kTreeAccentColor : Colors.white24,
          ),
          tooltip: '하위 폴더',
          onPressed: !canAddChild ? null : () => widget.onAddChild!(node),
        ),
        IconButton(
          icon: Icon(
            Icons.edit,
            size: 16,
            color: canRename ? kTreeAccentColor : Colors.white24,
          ),
          tooltip: '이름 변경',
          onPressed: !canRename ? null : () => widget.onRename!(node),
        ),
        IconButton(
          icon: Icon(
            Icons.delete_outline,
            size: 16,
            color: canDelete ? kTreeAccentColor : Colors.white24,
          ),
          tooltip: '삭제',
          onPressed: !canDelete ? null : () => widget.onDelete!(node),
        ),
      ],
    );
  }

  Widget _buildConceptSection(
    CategoryNode node,
    int depth,
    List<bool> ancestorHasNext,
    bool hasNextSibling,
  ) {
    final lineX = depth > 0
        ? ((depth - 1) * kTreeIndentStep) + (kTreeIndentStep / 2)
        : 0.0;
    final baseLineX = ((depth > 0 ? depth - 1 : 0) * kTreeIndentStep) +
        (kTreeIndentStep / 2);
    final lineEndX = baseLineX + kTreeConnectorWidth;
    final leftInset = depth > 0
        ? lineEndX +
            (kTreeArrowSize / 2) +
            kTreeArrowGap +
            kTreeArrowOffsetX
        : 0.0;
    final chips = <Widget>[];

    for (var i = 0; i < node.concepts.length; i++) {
      final concept = node.concepts[i];
      chips.add(
        _ConceptDragTarget(
          parentId: node.id,
          index: i,
          onMoveConcept: widget.onMoveConcept,
          child: _buildConceptChip(node, concept),
        ),
      );
    }

    chips.add(
      _ConceptDragTarget(
        parentId: node.id,
        index: node.concepts.length,
        onMoveConcept: widget.onMoveConcept,
        child: const SizedBox(width: 1, height: 1),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Stack(
        children: [
          if (depth > 0)
            Positioned.fill(
              child: CustomPaint(
                painter: _TreeIndentPainter(
                  depth: depth,
                  ancestorHasNext: ancestorHasNext,
                  hasNextSibling: hasNextSibling,
                  indentStep: kTreeIndentStep,
                  connectorWidth: kTreeConnectorWidth,
                  lineColor: kTreeLineColor,
                ),
              ),
            ),
          Padding(
            padding: EdgeInsets.only(
              left: leftInset,
              top: 8,
              bottom: 8,
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: chips,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConceptChip(CategoryNode parent, ConceptItem concept) {
    final tooltipParts = <String>[];
    if ((concept.versionLabel ?? '').isNotEmpty) {
      tooltipParts.add(concept.versionLabel!);
    }
    if (concept.level != null) {
      tooltipParts.add('레벨 L${concept.level}');
    }
    final tooltipText = tooltipParts.isEmpty
        ? concept.name
        : '${concept.name}\n${tooltipParts.join(' · ')}';

    final color = concept.kind == ConceptKind.definition
        ? const Color(0xFFFF6B6B)
        : const Color(0xFF4A9EFF);

    return LongPressDraggable<_DragConceptPayload>(
      data: _DragConceptPayload(
        conceptId: concept.id,
        fromParentId: parent.id,
        concept: concept,
      ),
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: Border.all(color: color),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            concept.name,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.4,
        child: _ConceptChipBody(
          color: color,
          concept: concept,
          tooltip: tooltipText,
          parent: parent,
          onTapConcept: widget.onTapConcept,
          onEditConcept: widget.onEditConcept,
          onDeleteConcept: widget.onDeleteConcept,
        ),
      ),
      child: _ConceptChipBody(
        color: color,
        concept: concept,
        tooltip: tooltipText,
        parent: parent,
        onTapConcept: widget.onTapConcept,
        onEditConcept: widget.onEditConcept,
        onDeleteConcept: widget.onDeleteConcept,
      ),
    );
  }

  void _expandTo(String id) {
    final path = _findPath(widget.roots, id);
    if (path == null) return;
    setState(() {
      _expandedIds.addAll(path);
    });
  }

  void _expandAll(CategoryNode node) {
    void visit(CategoryNode current) {
      _expandedIds.add(current.id);
      for (final child in current.children) {
        visit(child);
      }
    }

    setState(() {
      visit(node);
    });
  }

  bool _contains(CategoryNode parent, String targetId) {
    if (parent.id == targetId) return true;
    for (final child in parent.children) {
      if (_contains(child, targetId)) return true;
    }
    return false;
  }

  List<String>? _findPath(List<CategoryNode> nodes, String target,
      [List<String> acc = const []]) {
    for (final node in nodes) {
      final newAcc = [...acc, node.id];
      if (node.id == target) {
        return newAcc;
      }
      final childPath = _findPath(node.children, target, newAcc);
      if (childPath != null) {
        return childPath;
      }
    }
    return null;
  }
}

enum _TreeEntryType { folder, concepts }

class _TreeEntry {
  const _TreeEntry._({
    required this.type,
    required this.node,
    required this.depth,
    required this.ancestorHasNext,
    required this.hasNextSibling,
    this.parentId,
    this.index = 0,
    this.siblingCount = 0,
  });

  factory _TreeEntry.folder({
    required CategoryNode node,
    required int depth,
    required String? parentId,
    required int index,
    required int siblingCount,
    required List<bool> ancestorHasNext,
    required bool hasNextSibling,
  }) {
    return _TreeEntry._(
      type: _TreeEntryType.folder,
      node: node,
      depth: depth,
      ancestorHasNext: ancestorHasNext,
      hasNextSibling: hasNextSibling,
      parentId: parentId,
      index: index,
      siblingCount: siblingCount,
    );
  }

  factory _TreeEntry.concepts({
    required CategoryNode node,
    required int depth,
    required List<bool> ancestorHasNext,
    required bool hasNextSibling,
  }) {
    return _TreeEntry._(
      type: _TreeEntryType.concepts,
      node: node,
      depth: depth,
      ancestorHasNext: ancestorHasNext,
      hasNextSibling: hasNextSibling,
    );
  }

  final _TreeEntryType type;
  final CategoryNode node;
  final int depth;
  final List<bool> ancestorHasNext;
  final bool hasNextSibling;
  final String? parentId;
  final int index;
  final int siblingCount;
}

class _ConceptChipBody extends StatelessWidget {
  const _ConceptChipBody({
    required this.color,
    required this.concept,
    required this.tooltip,
    required this.parent,
    this.onTapConcept,
    this.onEditConcept,
    this.onDeleteConcept,
  });

  final Color color;
  final ConceptItem concept;
  final String tooltip;
  final CategoryNode parent;
  final void Function(CategoryNode parent, ConceptItem concept)? onTapConcept;
  final Future<void> Function(CategoryNode parent, ConceptItem concept)?
      onEditConcept;
  final Future<void> Function(CategoryNode parent, ConceptItem concept)?
      onDeleteConcept;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTapConcept == null
              ? null
              : () => onTapConcept!.call(parent, concept),
          onLongPress: onEditConcept == null
              ? null
              : () => onEditConcept!.call(parent, concept),
          onSecondaryTapDown: (details) =>
              _showMenu(context, details.globalPosition),
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withOpacity(0.4), width: 1.5),
            ),
            child: Text(
              concept.name,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showMenu(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final selection = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: const [
        PopupMenuItem(value: 'edit', child: Text('편집')),
        PopupMenuItem(value: 'delete', child: Text('삭제')),
      ],
    );
    if (selection == 'edit' && onEditConcept != null) {
      await onEditConcept!.call(parent, concept);
    } else if (selection == 'delete' && onDeleteConcept != null) {
      await onDeleteConcept!.call(parent, concept);
    }
  }
}

class _ConceptDragTarget extends StatelessWidget {
  const _ConceptDragTarget({
    required this.parentId,
    required this.index,
    required this.onMoveConcept,
    required this.child,
  });

  final String parentId;
  final int index;
  final Future<void> Function({
    required String conceptId,
    required String fromParentId,
    required String toParentId,
    int? toIndex,
  })? onMoveConcept;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DragTarget<_DragConceptPayload>(
      onWillAccept: (payload) => payload != null,
      onAccept: (payload) {
        if (onMoveConcept == null) return;
        onMoveConcept!.call(
          conceptId: payload.conceptId,
          fromParentId: payload.fromParentId,
          toParentId: parentId,
          toIndex: index,
        );
      },
      builder: (context, candidate, rejected) {
        final highlight = candidate.isNotEmpty;
        return Container(
          decoration: highlight
              ? BoxDecoration(
                  border: Border.all(color: kTreeAccentColor),
                  borderRadius: BorderRadius.circular(6),
                )
              : null,
          child: child,
        );
      },
    );
  }
}

class _DragConceptPayload {
  _DragConceptPayload({
    required this.conceptId,
    required this.fromParentId,
    required this.concept,
  });

  final String conceptId;
  final String fromParentId;
  final ConceptItem concept;
}

class _DragFolderPayload {
  const _DragFolderPayload(this.node);
  final CategoryNode node;
}

class _DragFolderFeedback extends StatelessWidget {
  const _DragFolderFeedback({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF2B2B2B),
          border: Border.all(color: kTreeAccentColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder, color: Color(0xFFFFC857), size: 16),
            const SizedBox(width: 8),
            Text(
              name,
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class _TreeIndentPainter extends CustomPainter {
  const _TreeIndentPainter({
    required this.depth,
    required this.ancestorHasNext,
    required this.hasNextSibling,
    required this.indentStep,
    required this.connectorWidth,
    required this.lineColor,
  });

  final int depth;
  final List<bool> ancestorHasNext;
  final bool hasNextSibling;
  final double indentStep;
  final double connectorWidth;
  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (depth <= 0) return;
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = kTreeLineWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final centerY = size.height / 2;

    for (var i = 0; i < depth - 1; i++) {
      if (i >= ancestorHasNext.length || !ancestorHasNext[i]) continue;
      final x = (i * indentStep) + (indentStep / 2);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    // parent column (depth - 1): always connect to parent
    final elbowX = ((depth - 1) * indentStep) + (indentStep / 2);
    final rawRadius =
        kTreeCornerRadius > connectorWidth ? connectorWidth : kTreeCornerRadius;
    final radius = rawRadius > centerY ? centerY : rawRadius;
    final elbowPath = Path()
      ..moveTo(elbowX, 0)
      ..lineTo(elbowX, centerY - radius)
      ..quadraticBezierTo(elbowX, centerY, elbowX + radius, centerY)
      ..lineTo(elbowX + connectorWidth, centerY);
    canvas.drawPath(elbowPath, paint);
    if (hasNextSibling) {
      canvas.drawLine(Offset(elbowX, centerY), Offset(elbowX, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TreeIndentPainter oldDelegate) {
    return oldDelegate.depth != depth ||
        oldDelegate.ancestorHasNext != ancestorHasNext ||
        oldDelegate.hasNextSibling != hasNextSibling ||
        oldDelegate.indentStep != indentStep ||
        oldDelegate.connectorWidth != connectorWidth ||
        oldDelegate.lineColor != lineColor;
  }
}

