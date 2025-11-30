import 'package:flutter/material.dart';

import '../../../services/concept_category_service.dart';
import '../../../services/concept_service.dart';

class CategoryTree extends StatefulWidget {
  const CategoryTree({
    super.key,
    required this.roots,
    this.forceExpandNodeId,
    this.onSelect,
    this.onAddChild,
    this.onRename,
    this.onDelete,
    this.onTapConcept,
    this.onEditConcept,
    this.onDeleteConcept,
    this.onMoveConcept,
    this.onMoveFolder,
  });

  final List<CategoryNode> roots;
  final String? forceExpandNodeId;
  final ValueChanged<CategoryNode>? onSelect;
  final Future<void> Function(CategoryNode node)? onAddChild;
  final Future<void> Function(CategoryNode node)? onRename;
  final Future<void> Function(CategoryNode node)? onDelete;
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
          style: TextStyle(color: Colors.white54),
        ),
      );
    }
    final children =
        widget.roots.map((node) => _buildNode(node, 0)).toList(growable: false);
    return Scrollbar(
      child: ListView(
        children: children,
      ),
    );
  }

  Widget _buildNode(CategoryNode node, int depth) {
    final widgets = <Widget>[
      _buildFolderRow(node, depth),
    ];

    final isExpanded = _expandedIds.contains(node.id);
    if (isExpanded) {
      if (node.concepts.isNotEmpty) {
        widgets.add(_buildConceptSection(node, depth + 1));
      }
      for (final child in node.children) {
        widgets.add(_buildNode(child, depth + 1));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  Widget _buildFolderRow(CategoryNode node, int depth) {
    final isExpanded = _expandedIds.contains(node.id);
    final isSelected = _selectedCategoryId == node.id;
    final indent = depth * 18.0;

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
          padding: EdgeInsets.only(left: indent, right: 8, top: 4, bottom: 4),
          child: GestureDetector(
            onTap: () {
              setState(() => _selectedCategoryId = node.id);
              widget.onSelect?.call(node);
            },
            onDoubleTap: () => _expandAll(node),
            child: LongPressDraggable<_DragFolderPayload>(
              data: _DragFolderPayload(node),
              feedback: _DragFolderFeedback(name: node.name),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFF3A3A3A)
                      : const Color(0xFF2B2B2B),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected
                        ? const Color(0xFF4A9EFF)
                        : const Color(0xFF3A3A3A),
                  ),
                ),
                child: Row(
                  children: [
                    InkWell(
                      onTap: () {
                        setState(() {
                          if (isExpanded) {
                            _expandedIds.remove(node.id);
                          } else {
                            _expandedIds.add(node.id);
                          }
                        });
                      },
                      child: Icon(
                        isExpanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_right,
                        size: 16,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      isExpanded ? Icons.folder_open : Icons.folder,
                      size: 16,
                      color: const Color(0xFFFFC857),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        node.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    _buildFolderActions(node),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFolderActions(CategoryNode node) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.create_new_folder_outlined, size: 16),
          tooltip: '하위 폴더',
          onPressed: widget.onAddChild == null
              ? null
              : () => widget.onAddChild!(node),
        ),
        IconButton(
          icon: const Icon(Icons.edit, size: 16),
          tooltip: '이름 변경',
          onPressed:
              widget.onRename == null ? null : () => widget.onRename!(node),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 16),
          tooltip: '삭제',
          onPressed:
              widget.onDelete == null ? null : () => widget.onDelete!(node),
        ),
      ],
    );
  }

  Widget _buildConceptSection(CategoryNode node, int depth) {
    final indent = depth * 18.0;
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
      padding: EdgeInsets.only(left: indent + 12, right: 8, top: 6, bottom: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: chips,
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
            color: color.withOpacity(0.1),
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
              color: color.withOpacity(0.15),
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
                  border: Border.all(color: const Color(0xFF4A9EFF)),
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
          border: Border.all(color: const Color(0xFF4A9EFF)),
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

