import 'package:flutter/material.dart';

import '../../../services/concept_category_service.dart';
import '../../../services/concept_service.dart';
import '../../../services/concept_topic.dart';
import '../../think/think_style.dart';
import 'concept_type_chip.dart';

/// 개념 라이브러리 트리. 폴더 안 개념은 주제 묶음 → 유형 순서로 늘어놓는다(concept_topic.dart).
/// 디자인: docs/design-system.md (개념 라이브러리 트리)
enum ConceptTreeView { chips, list }

const double _rowPad = 8;
const double _indent = 16;
const double _chevron = 18;
const double _subStep = 24;

double _lineX(int level) => _rowPad + level * _indent + _chevron / 2;
double _contentLeft(int depth) => _rowPad + depth * _indent + _chevron + 4;

class CategoryTree extends StatefulWidget {
  const CategoryTree({
    super.key,
    required this.roots,
    this.meta = ConceptTreeMeta.empty,
    this.forceExpandNodeId,
    this.rootParentId,
    this.onSelect,
    this.onAddChild,
    this.onRename,
    this.onDelete,
    this.onReorderFolder,
    this.onProposeAnchors,
    this.onTapConcept,
    this.onEditConcept,
    this.onDeleteConcept,
    this.onMoveConcept,
    this.onMoveFolder,
    this.selectedConceptId,
    this.onPickConcept,
    this.openedConceptId,
    this.statementCountOf,
    this.reviewOpenOf,
  });

  final List<CategoryNode> roots;
  final ConceptTreeMeta meta;
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

  /// 폴더 메뉴의 "주제 묶음 제안받기".
  final Future<void> Function(CategoryNode node)? onProposeAnchors;
  final void Function(CategoryNode parent, ConceptItem concept)? onTapConcept;
  final Future<void> Function(CategoryNode parent, ConceptItem concept)? onEditConcept;
  final Future<void> Function(CategoryNode parent, ConceptItem concept)? onDeleteConcept;

  /// 다른 폴더로 옮기기만 한다. 폴더 안 순서는 주제 묶음·유형으로 정해진다.
  final Future<void> Function({
    required String conceptId,
    required String fromParentId,
    required String toParentId,
  })? onMoveConcept;
  final Future<void> Function({
    required String folderId,
    required String? newParentId,
    int? newIndex,
  })? onMoveFolder;

  /// Think 대화가 참고하는 개념(테두리와 대화 표시).
  final String? selectedConceptId;
  final void Function(CategoryNode parent, ConceptItem concept)? onPickConcept;

  /// 개념 상세에 열어 둔 개념(진하게 채운다).
  final String? openedConceptId;

  /// 기본 서술을 뺀 서술 수. 개념 상세에서 방금 읽은 값이 있으면 그것을, 없으면 null을 돌려 [meta] 값을 쓴다.
  final int? Function(String conceptId)? statementCountOf;

  /// 같은 개념인지 판단이 남은 "검토 필요" 개념인지.
  final bool Function(String conceptId)? reviewOpenOf;

  @override
  State<CategoryTree> createState() => _CategoryTreeState();
}

class _FolderStats {
  int total = 0;
  final Map<String, int> counts = {};
}

class _CategoryTreeState extends State<CategoryTree> {
  static ConceptTreeView _lastView = ConceptTreeView.chips;

  late ConceptTreeView _view = _lastView;
  final Set<String> _expandedIds = {};
  String? _selectedCategoryId;
  final TextEditingController _search = TextEditingController();
  final Set<String> _filter = {};
  String _query = '';

  List<CategoryNode>? _statsRoots;
  ConceptTreeMeta? _statsMeta;
  Map<String, _FolderStats> _stats = {};
  _FolderStats _all = _FolderStats();

  @override
  void initState() {
    super.initState();
    if (widget.forceExpandNodeId != null) _expandTo(widget.forceExpandNodeId!);
    _search.addListener(_onSearch);
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
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _onSearch() {
    final q = _search.text.trim().toLowerCase();
    if (q == _query) return;
    setState(() {
      _query = q;
      if (q.isNotEmpty) _expandMatches(widget.roots);
    });
  }

  bool _matches(ConceptItem c) => c.name.toLowerCase().contains(_query);

  bool _expandMatches(List<CategoryNode> nodes) {
    var any = false;
    for (final n in nodes) {
      final inChildren = _expandMatches(n.children);
      if (inChildren || n.concepts.any(_matches)) {
        _expandedIds.add(n.id);
        any = true;
      }
    }
    return any;
  }

  ConceptTypeStyle _styleOf(ConceptItem c) => conceptTypeStyle(widget.meta.typeOf[c.id]);

  /// 기본 서술을 포함한 서술 수. 1이면 표시하지 않는다.
  int _statementsOf(ConceptItem c) =>
      1 + (widget.statementCountOf?.call(c.id) ?? widget.meta.statementCount[c.id] ?? 0);

  bool _reviewOf(ConceptItem c) => widget.reviewOpenOf?.call(c.id) ?? false;

  void _ensureStats() {
    if (identical(_statsRoots, widget.roots) && identical(_statsMeta, widget.meta)) return;
    _statsRoots = widget.roots;
    _statsMeta = widget.meta;
    final stats = <String, _FolderStats>{};
    final all = _FolderStats();
    _FolderStats visit(CategoryNode n) {
      final s = _FolderStats();
      for (final c in n.concepts) {
        final label = _styleOf(c).label;
        s.counts[label] = (s.counts[label] ?? 0) + 1;
        all.counts[label] = (all.counts[label] ?? 0) + 1;
      }
      s.total = n.concepts.length;
      for (final child in n.children) {
        final cs = visit(child);
        s.total += cs.total;
        cs.counts.forEach((k, v) => s.counts[k] = (s.counts[k] ?? 0) + v);
      }
      stats[n.id] = s;
      return s;
    }

    for (final r in widget.roots) {
      all.total += visit(r).total;
    }
    _stats = stats;
    _all = all;
  }

  /// 유형 순서(목록 순서 → 목록에 없는 유형 → 유형 없음).
  List<String> _orderedLabels(Iterable<String> labels) {
    final rank = widget.meta.typeRank;
    final list = labels.toSet().toList();
    int key(String l) => l == kConceptNoType.label ? 1 << 20 : (rank[l] ?? (1 << 19));
    list.sort((a, b) {
      final r = key(a).compareTo(key(b));
      return r != 0 ? r : a.compareTo(b);
    });
    return list;
  }

  List<(ConceptTypeStyle, int)> _barOf(_FolderStats s) => [
        for (final l in _orderedLabels(s.counts.keys))
          (l == kConceptNoType.label ? kConceptNoType : conceptTypeStyle(l), s.counts[l]!),
      ];

  bool _dimmed(ConceptItem c) {
    if (_query.isNotEmpty && !_matches(c)) return true;
    return _filter.isNotEmpty && !_filter.contains(_styleOf(c).label);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.roots.isEmpty) {
      return const Center(
        child: Text('표시할 폴더가 없습니다.', style: TextStyle(color: kThinkSub, fontSize: 14)),
      );
    }
    _ensureStats();
    final entries = <_Entry>[];
    void add(List<CategoryNode> nodes, int depth, String? parentId) {
      for (var i = 0; i < nodes.length; i++) {
        final n = nodes[i];
        entries.add(_Entry(n, depth, parentId, i, nodes.length, false));
        if (!_expandedIds.contains(n.id)) continue;
        if (n.concepts.isNotEmpty) entries.add(_Entry(n, depth, parentId, i, nodes.length, true));
        add(n.children, depth + 1, n.id);
      }
    }

    add(widget.roots, 0, widget.rootParentId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(),
        const SizedBox(height: 8),
        Expanded(
          child: Scrollbar(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 16),
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final e = entries[i];
                return e.block ? _conceptBlock(e.node, e.depth) : _folderRow(e);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _toolbar() {
    final labels = _orderedLabels(_all.counts.keys);
    final filtering = _query.isNotEmpty || _filter.isNotEmpty;
    final shown = filtering ? _countShown(widget.roots) : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 36,
                child: TextField(
                  key: const ValueKey('concept-tree-search'),
                  controller: _search,
                  style: const TextStyle(color: kThinkText, fontSize: 13),
                  decoration: thinkInputDecoration(
                    hint: '개념 이름 찾기',
                    dense: true,
                    prefixIcon: const Icon(Icons.search_rounded, size: 18, color: kThinkHint),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '지우기',
                            onPressed: _search.clear,
                            icon: const Icon(Icons.close_rounded, size: 16, color: kThinkHint),
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _ViewToggle(
              value: _view,
              onChanged: (v) => setState(() => _view = _lastView = v),
            ),
          ],
        ),
        if (labels.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final l in labels)
                ConceptTypeFilterChip(
                  key: ValueKey('concept-type-filter-$l'),
                  style: l == kConceptNoType.label ? kConceptNoType : conceptTypeStyle(l),
                  count: _all.counts[l] ?? 0,
                  selected: _filter.contains(l),
                  onTap: () => setState(() => _filter.contains(l) ? _filter.remove(l) : _filter.add(l)),
                ),
              if (filtering)
                Text('맞는 개념 $shown개',
                    style: const TextStyle(color: kThinkHint, fontSize: 12, fontWeight: FontWeight.w700)),
            ],
          ),
        ],
      ],
    );
  }

  int _countShown(List<CategoryNode> nodes) {
    var n = 0;
    for (final f in nodes) {
      n += f.concepts.where((c) => !_dimmed(c)).length + _countShown(f.children);
    }
    return n;
  }

  Widget _folderRow(_Entry e) {
    final node = e.node;
    final stats = _stats[node.id] ?? _FolderStats();
    final open = _expandedIds.contains(node.id);
    final parentId = e.parentId;
    return _FolderRow(
      key: ValueKey('folder-${node.id}'),
      node: node,
      depth: e.depth,
      expanded: open,
      selected: _selectedCategoryId == node.id,
      hasContent: node.children.isNotEmpty || node.concepts.isNotEmpty,
      total: stats.total,
      bar: _barOf(stats),
      onTap: () {
        setState(() {
          _selectedCategoryId = node.id;
          if (!_expandedIds.remove(node.id)) _expandedIds.add(node.id);
        });
        widget.onSelect?.call(node);
      },
      onDoubleTap: () => _expandAll(node),
      onAddChild: widget.onAddChild == null ? null : () => widget.onAddChild!(node),
      onRename: widget.onRename == null ? null : () => widget.onRename!(node),
      onDelete: widget.onDelete == null ? null : () => widget.onDelete!(node),
      onUp: widget.onReorderFolder == null || parentId == null || e.index == 0
          ? null
          : () => widget.onReorderFolder!(node: node, parentId: parentId, direction: -1),
      onDown: widget.onReorderFolder == null || parentId == null || e.index >= e.siblingCount - 1
          ? null
          : () => widget.onReorderFolder!(node: node, parentId: parentId, direction: 1),
      onProposeAnchors:
          widget.onProposeAnchors == null || node.concepts.length < 2 ? null : () => widget.onProposeAnchors!(node),
      acceptsFolder: (p) => p.node.id != node.id && !_contains(p.node, node.id),
      onDropFolder: (p) => widget.onMoveFolder?.call(folderId: p.node.id, newParentId: node.id),
      onDropConcept: widget.onMoveConcept == null
          ? null
          : (p) => widget.onMoveConcept!(conceptId: p.concept.id, fromParentId: p.fromParentId, toParentId: node.id),
    );
  }

  String _tooltipOf(CategoryNode parent, ConceptItem c, ConceptTypeStyle style) {
    final version = (c.versionLabel ?? '').trim();
    final anchorId = widget.meta.anchorOf[c.id];
    final anchor = anchorId == null ? null : parent.concepts.where((x) => x.id == anchorId).firstOrNull;
    return [
      '${style.label} · ${c.name}${version.isEmpty ? '' : ' ($version)'}',
      if (widget.meta.typeOf[c.id] == null) '기존 구분: ${c.kind == ConceptKind.definition ? '정의' : '정리'}',
      if (c.level != null) '레벨 L${c.level}',
      if (_statementsOf(c) > 1) '서술 ${_statementsOf(c)}개',
      if (_reviewOf(c)) '검토 필요: 같은 개념인지 판단이 남아 있음',
      if (anchor != null) '묶음: ${anchor.name}에 붙음',
      if (c.id == widget.selectedConceptId) 'Think 대화가 참고하는 개념',
    ].join('\n');
  }

  Widget _draggable(CategoryNode parent, ConceptItem c, ConceptTypeStyle style, Widget child) {
    return LongPressDraggable<_DragConceptPayload>(
      data: _DragConceptPayload(parent.id, c),
      feedback: Material(color: Colors.transparent, child: ConceptTypeChip(name: c.name, style: style, opened: true)),
      childWhenDragging: Opacity(opacity: 0.4, child: child),
      child: child,
    );
  }

  Widget _chip(CategoryNode parent, ConceptItem c) {
    final style = _styleOf(c);
    return _draggable(
      parent,
      c,
      style,
      ConceptTypeChip(
        key: ValueKey('concept-chip-${c.id}'),
        name: c.name,
        style: style,
        version: c.versionLabel,
        statements: _statementsOf(c),
        review: _reviewOf(c),
        tooltip: _tooltipOf(parent, c, style),
        opened: c.id == widget.openedConceptId,
        picked: c.id == widget.selectedConceptId,
        dimmed: _dimmed(c),
        onTap: widget.onTapConcept == null ? null : () => widget.onTapConcept!(parent, c),
        onSecondaryTapDown: (d) => _conceptMenu(parent, c, d.globalPosition),
      ),
    );
  }

  List<Widget> _clusterItems(CategoryNode parent, ConceptTopicNode n) => [
        _chip(parent, n.concept),
        for (final child in n.children)
          if (child.children.isEmpty)
            _chip(parent, child.concept)
          else
            _TopicCluster(children: _clusterItems(parent, child)),
      ];

  Widget _conceptBlock(CategoryNode node, int depth) {
    final forest = conceptTopicForest(node.concepts, widget.meta);
    if (_view == ConceptTreeView.list) {
      final base = _contentLeft(depth + 1);
      return CustomPaint(
        key: ValueKey('concepts-${node.id}'),
        painter: _GuidePainter(depth + 1),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final line in flattenTopicForest(forest))
                _draggable(
                  node,
                  line.node.concept,
                  _styleOf(line.node.concept),
                  _ConceptRow(
                    key: ValueKey('concept-row-${line.node.concept.id}'),
                    concept: line.node.concept,
                    style: _styleOf(line.node.concept),
                    base: base,
                    line: line,
                    statements: _statementsOf(line.node.concept),
                    review: _reviewOf(line.node.concept),
                    tooltip: _tooltipOf(node, line.node.concept, _styleOf(line.node.concept)),
                    opened: line.node.concept.id == widget.openedConceptId,
                    picked: line.node.concept.id == widget.selectedConceptId,
                    dimmed: _dimmed(line.node.concept),
                    onTap: widget.onTapConcept == null ? null : () => widget.onTapConcept!(node, line.node.concept),
                    onSecondaryTapDown: (d) => _conceptMenu(node, line.node.concept, d.globalPosition),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    final parts = <Widget>[];
    final loose = <Widget>[];
    void flush() {
      if (loose.isEmpty) return;
      parts.add(Wrap(spacing: 8, runSpacing: 8, children: [...loose]));
      loose.clear();
    }

    for (final root in forest) {
      if (root.children.isEmpty) {
        loose.add(_chip(node, root.concept));
        continue;
      }
      flush();
      parts.add(_TopicCluster(fill: true, children: _clusterItems(node, root)));
    }
    flush();
    return CustomPaint(
      key: ValueKey('concepts-${node.id}'),
      painter: _GuidePainter(depth + 1),
      child: Padding(
        padding: EdgeInsets.fromLTRB(_contentLeft(depth + 1), 4, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < parts.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              parts[i],
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _conceptMenu(CategoryNode parent, ConceptItem concept, Offset position) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final picked = concept.id == widget.selectedConceptId;
    PopupMenuItem<String> item(String value, IconData icon, String label, {Color color = kThinkText}) => PopupMenuItem(
          height: 36,
          value: value,
          child: Row(children: [
            Icon(icon, size: 16, color: color == kThinkText ? kThinkSub : color),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(color: color, fontSize: 13)),
          ]),
        );
    final selection = await showMenu<String>(
      context: context,
      color: kThinkPanel,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: kThinkBorder)),
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, overlay.size.width - position.dx, overlay.size.height - position.dy),
      items: [
        if (widget.onPickConcept != null && !picked) item('pick', Icons.forum_outlined, 'Think 대화 참고로 선택'),
        if (widget.onEditConcept != null) item('edit', Icons.edit_outlined, '편집'),
        if (widget.onDeleteConcept != null) ...[
          const PopupMenuDivider(height: 8),
          item('delete', Icons.delete_outline, '삭제', color: kThinkError),
        ],
      ],
    );
    if (selection == 'pick') {
      widget.onPickConcept?.call(parent, concept);
    } else if (selection == 'edit') {
      await widget.onEditConcept?.call(parent, concept);
    } else if (selection == 'delete') {
      await widget.onDeleteConcept?.call(parent, concept);
    }
  }

  void _expandTo(String id) {
    final path = _findPath(widget.roots, id);
    if (path == null) return;
    setState(() => _expandedIds.addAll(path));
  }

  void _expandAll(CategoryNode node) {
    void visit(CategoryNode current) {
      _expandedIds.add(current.id);
      current.children.forEach(visit);
    }

    setState(() => visit(node));
  }

  bool _contains(CategoryNode parent, String targetId) {
    if (parent.id == targetId) return true;
    return parent.children.any((c) => _contains(c, targetId));
  }

  List<String>? _findPath(List<CategoryNode> nodes, String target, [List<String> acc = const []]) {
    for (final node in nodes) {
      final next = [...acc, node.id];
      if (node.id == target) return next;
      final child = _findPath(node.children, target, next);
      if (child != null) return child;
    }
    return null;
  }
}

class _Entry {
  const _Entry(this.node, this.depth, this.parentId, this.index, this.siblingCount, this.block);

  final CategoryNode node;
  final int depth;
  final String? parentId;
  final int index;
  final int siblingCount;

  /// 폴더 줄이 아니라 그 폴더의 개념 묶음.
  final bool block;
}

class _DragConceptPayload {
  const _DragConceptPayload(this.fromParentId, this.concept);

  final String fromParentId;
  final ConceptItem concept;
}

class _DragFolderPayload {
  const _DragFolderPayload(this.node);

  final CategoryNode node;
}

class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.value, required this.onChanged});

  final ConceptTreeView value;
  final ValueChanged<ConceptTreeView> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget button(ConceptTreeView v, IconData icon, String tip) {
      final on = v == value;
      return Tooltip(
        message: tip,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('concept-tree-view-${v.name}'),
            onTap: () => onChanged(v),
            borderRadius: BorderRadius.circular(6),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 32,
              height: 28,
              decoration: BoxDecoration(
                color: on ? kThinkAccent.withValues(alpha: 0.16) : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, size: 18, color: on ? kThinkAccent : kThinkSub),
            ),
          ),
        ),
      );
    }

    return Container(
      height: 36,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: kThinkPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(ConceptTreeView.chips, Icons.bubble_chart_outlined, '칩으로 보기'),
          const SizedBox(width: 4),
          button(ConceptTreeView.list, Icons.view_list_outlined, '목록으로 보기'),
        ],
      ),
    );
  }
}

/// 조상 폴더마다 세로 안내선 한 줄(1px).
class _GuidePainter extends CustomPainter {
  const _GuidePainter(this.levels);

  final int levels;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = kThinkBorder
      ..strokeWidth = 1;
    for (var i = 0; i < levels; i++) {
      final x = _lineX(i);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GuidePainter old) => old.levels != levels;
}

class _FolderRow extends StatefulWidget {
  const _FolderRow({
    super.key,
    required this.node,
    required this.depth,
    required this.expanded,
    required this.selected,
    required this.hasContent,
    required this.total,
    required this.bar,
    required this.onTap,
    required this.onDoubleTap,
    required this.acceptsFolder,
    required this.onDropFolder,
    this.onAddChild,
    this.onRename,
    this.onDelete,
    this.onUp,
    this.onDown,
    this.onProposeAnchors,
    this.onDropConcept,
  });

  final CategoryNode node;
  final int depth;
  final bool expanded;
  final bool selected;
  final bool hasContent;
  final int total;
  final List<(ConceptTypeStyle, int)> bar;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final bool Function(_DragFolderPayload p) acceptsFolder;
  final void Function(_DragFolderPayload p) onDropFolder;
  final VoidCallback? onAddChild;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final VoidCallback? onProposeAnchors;
  final void Function(_DragConceptPayload p)? onDropConcept;

  @override
  State<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<_FolderRow> {
  bool _hover = false;
  bool _menuOpen = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final top = w.depth == 0;
    final showActions = _hover || _menuOpen;
    return DragTarget<_DragConceptPayload>(
      onWillAcceptWithDetails: (d) => w.onDropConcept != null && d.data.fromParentId != w.node.id,
      onAcceptWithDetails: (d) => w.onDropConcept?.call(d.data),
      builder: (context, conceptCandidates, _) => DragTarget<_DragFolderPayload>(
        onWillAcceptWithDetails: (d) => w.acceptsFolder(d.data),
        onAcceptWithDetails: (d) => w.onDropFolder(d.data),
        builder: (context, folderCandidates, _) {
          final dropping = conceptCandidates.isNotEmpty || folderCandidates.isNotEmpty;
          return SizedBox(
            height: 36,
            child: CustomPaint(
              painter: _GuidePainter(w.depth),
              child: Padding(
                padding: EdgeInsets.only(left: 4 + w.depth * _indent, right: 8),
                child: MouseRegion(
                  onEnter: (_) => setState(() => _hover = true),
                  onExit: (_) => setState(() => _hover = false),
                  child: LongPressDraggable<_DragFolderPayload>(
                    data: _DragFolderPayload(w.node),
                    feedback: _FolderFeedback(name: w.node.name),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: w.selected || dropping
                            ? kThinkAccent.withValues(alpha: 0.12)
                            : (_hover ? Colors.white.withValues(alpha: 0.04) : Colors.transparent),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: dropping ? kThinkAccent.withValues(alpha: 0.7) : Colors.transparent),
                      ),
                      child: Row(
                        children: [
                          // 두 번 누르기(모두 펼치기)는 이름 쪽에만 둔다. 줄 전체에 두면 버튼 누름이 그만큼 늦게 먹는다.
                          Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: w.onTap,
                              onDoubleTap: w.onDoubleTap,
                              child: SizedBox(
                                height: 36,
                                child: Row(
                                  children: [
                                    AnimatedRotation(
                                      turns: w.expanded ? 0.25 : 0,
                                      duration: const Duration(milliseconds: 160),
                                      child: Icon(Icons.chevron_right_rounded,
                                          size: _chevron, color: w.hasContent ? kThinkSub : Colors.transparent),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(w.expanded ? Icons.folder_open_outlined : Icons.folder_outlined,
                                        size: 16, color: w.selected ? kThinkAccent : kThinkSub),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        w.node.name,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: top || w.selected ? kThinkText : kThinkText.withValues(alpha: 0.88),
                                          fontSize: 14,
                                          fontWeight: top || w.selected ? FontWeight.w700 : FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (showActions) ...[
                            if (w.onAddChild != null)
                              _RowAction(icon: Icons.add_rounded, tooltip: '하위 폴더', onTap: w.onAddChild!),
                            _menu(),
                          ] else if (w.total > 0) ...[
                            ConceptTypeBar(counts: w.bar, width: 40),
                            const SizedBox(width: 8),
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Text('${w.total}',
                                  style: const TextStyle(color: kThinkHint, fontSize: 12, fontWeight: FontWeight.w700)),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _menu() {
    final w = widget;
    PopupMenuItem<String> item(String value, IconData icon, String label, VoidCallback? on,
            {Color color = kThinkText}) =>
        PopupMenuItem(
          height: 36,
          value: value,
          enabled: on != null,
          child: Row(children: [
            Icon(icon, size: 16, color: on == null ? kThinkHint : (color == kThinkText ? kThinkSub : color)),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(color: on == null ? kThinkHint : color, fontSize: 13)),
          ]),
        );
    final actions = <String, VoidCallback?>{
      'rename': w.onRename,
      'up': w.onUp,
      'down': w.onDown,
      'anchors': w.onProposeAnchors,
      'delete': w.onDelete,
    };
    return PopupMenuButton<String>(
      key: ValueKey('folder-menu-${w.node.id}'),
      tooltip: '폴더 메뉴',
      color: kThinkPanel,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: kThinkBorder)),
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      onOpened: () => setState(() => _menuOpen = true),
      onCanceled: () => setState(() => _menuOpen = false),
      onSelected: (v) {
        setState(() => _menuOpen = false);
        actions[v]?.call();
      },
      itemBuilder: (_) => [
        item('rename', Icons.edit_outlined, '이름 바꾸기', w.onRename),
        item('up', Icons.arrow_upward_rounded, '위로', w.onUp),
        item('down', Icons.arrow_downward_rounded, '아래로', w.onDown),
        if (w.onProposeAnchors != null) ...[
          const PopupMenuDivider(height: 8),
          item('anchors', Icons.hub_outlined, '주제 묶음 제안받기', w.onProposeAnchors),
        ],
        const PopupMenuDivider(height: 8),
        item('delete', Icons.delete_outline, '삭제', w.onDelete, color: kThinkError),
      ],
      child: const SizedBox(width: 28, height: 28, child: Icon(Icons.more_horiz_rounded, size: 18, color: kThinkSub)),
    );
  }
}

class _RowAction extends StatelessWidget {
  const _RowAction({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(width: 28, height: 28, child: Icon(icon, size: 18, color: kThinkSub)),
      ),
    );
  }
}

class _FolderFeedback extends StatelessWidget {
  const _FolderFeedback({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: kThinkPanel,
          border: Border.all(color: kThinkAccent.withValues(alpha: 0.7)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_outlined, color: kThinkAccent, size: 16),
            const SizedBox(width: 8),
            Text(name, style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// 칩 보기 주제 묶음: 앞 개념 하나와 그것을 쓰는 개념들을 옅은 상자로 묶는다. 안쪽 묶음은 내용만큼만 넓다.
class _TopicCluster extends StatelessWidget {
  const _TopicCluster({required this.children, this.fill = false});

  final List<Widget> children;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: fill ? double.infinity : null,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kThinkBorder),
      ),
      child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: children),
    );
  }
}

/// 목록 보기 개념 줄: 유형 꼬리표 + 이름. 묶음 깊이만큼 들여 쓰고 꺾은 선으로 앞 개념에 잇는다.
class _ConceptRow extends StatefulWidget {
  const _ConceptRow({
    super.key,
    required this.concept,
    required this.style,
    required this.base,
    required this.line,
    required this.tooltip,
    this.statements = 1,
    this.review = false,
    this.opened = false,
    this.picked = false,
    this.dimmed = false,
    this.onTap,
    this.onSecondaryTapDown,
  });

  final ConceptItem concept;
  final ConceptTypeStyle style;
  final double base;
  final ConceptTopicLine line;
  final String tooltip;
  final int statements;
  final bool review;
  final bool opened;
  final bool picked;
  final bool dimmed;
  final VoidCallback? onTap;
  final GestureTapDownCallback? onSecondaryTapDown;

  @override
  State<_ConceptRow> createState() => _ConceptRowState();
}

class _ConceptRowState extends State<_ConceptRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.concept;
    final s = widget.style;
    final left = widget.base + widget.line.depth * _subStep;
    final version = (c.versionLabel ?? '').trim();
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      opacity: widget.dimmed ? 0.28 : 1,
      child: SizedBox(
        height: 32,
        child: CustomPaint(
          painter: widget.line.depth == 0 ? null : _TopicLinePainter(base: widget.base, line: widget.line),
          child: Padding(
            padding: EdgeInsets.only(left: left - 4, right: 8),
            child: Tooltip(
              message: widget.tooltip,
              waitDuration: const Duration(milliseconds: 400),
              child: MouseRegion(
                cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
                onEnter: (_) => setState(() => _hover = true),
                onExit: (_) => setState(() => _hover = false),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onTap,
                  onSecondaryTapDown: widget.onSecondaryTapDown,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: widget.opened
                          ? s.color.withValues(alpha: 0.14)
                          : (_hover ? Colors.white.withValues(alpha: 0.04) : Colors.transparent),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        ConceptTypeTag(s),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            c.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: widget.opened ? kThinkText : kThinkText.withValues(alpha: 0.88),
                              fontSize: 13,
                              fontWeight: widget.opened ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (version.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(version,
                                style: const TextStyle(color: kThinkHint, fontSize: 11, fontWeight: FontWeight.w700)),
                          ),
                        if (widget.statements > 1)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: ConceptStatementCountMark(widget.statements, color: kThinkHint),
                          ),
                        if (widget.review)
                          const Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: ConceptReviewMark(),
                          ),
                        if (widget.picked)
                          const Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: Icon(Icons.forum_rounded, size: 14, color: kThinkAccent),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 목록 보기 묶음 선. 깊이 d 줄은 앞 개념 꼬리표 아래(x = base + (d-1)·24 + 12)에서 꺾여 들어온다.
class _TopicLinePainter extends CustomPainter {
  const _TopicLinePainter({required this.base, required this.line});

  final double base;
  final ConceptTopicLine line;

  double _x(int depth) => base + (depth - 1) * _subStep + 12;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = kThinkBorder
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (var d = 1; d < line.depth; d++) {
      if (d < line.ancestorsHaveNext.length && line.ancestorsHaveNext[d]) {
        canvas.drawLine(Offset(_x(d), 0), Offset(_x(d), size.height), paint);
      }
    }
    final x = _x(line.depth);
    final mid = size.height / 2;
    final end = base + line.depth * _subStep - 2;
    canvas.drawPath(
      Path()
        ..moveTo(x, 0)
        ..lineTo(x, mid - 6)
        ..quadraticBezierTo(x, mid, x + 6, mid)
        ..lineTo(end, mid),
      paint,
    );
    if (!line.last) canvas.drawLine(Offset(x, mid - 6), Offset(x, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant _TopicLinePainter old) => old.base != base || old.line != line;
}
