import 'package:flutter/material.dart';

import '../../../think/think_style.dart';
import 'concept_tree_preview_mock.dart';

/// 개념 라이브러리 트리 Preview. 목업 데이터와 화면 안 상태만 쓴다(실제 저장 없음).
class ConceptTreePreviewScreen extends StatelessWidget {
  const ConceptTreePreviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kThinkBg,
      appBar: AppBar(
        backgroundColor: kThinkBg,
        foregroundColor: kThinkText,
        title: const Text('Preview · 개념 라이브러리 트리'),
      ),
      body: const ConceptTreePreviewBody(),
    );
  }
}

const double _rowPad = 8;
const double _indent = 16;
const double _chevron = 18;

double _lineX(int level) => _rowPad + level * _indent + _chevron / 2;
double _contentLeft(int depth) => _rowPad + depth * _indent + _chevron + 4;

enum _Design { chips, list, cards }

class ConceptTreePreviewBody extends StatefulWidget {
  const ConceptTreePreviewBody({super.key, this.initialDesign = 0, this.initialOrder = MockOrder.math});

  final int initialDesign;
  final MockOrder initialOrder;

  @override
  State<ConceptTreePreviewBody> createState() => _ConceptTreePreviewBodyState();
}

class _ConceptTreePreviewBodyState extends State<ConceptTreePreviewBody> {
  late _Design _design = _Design.values[widget.initialDesign];
  late MockOrder _order = widget.initialOrder;
  final Set<MockConceptType> _filter = {};
  final TextEditingController _search = TextEditingController();
  final Set<String> _expanded = {};
  String? _selectedFolder = 'gcdlcm';
  String? _opened = 'g2';
  final String _picked = 'f2';

  @override
  void initState() {
    super.initState();
    void visit(MockFolder f) {
      if (f.children.isNotEmpty || f.concepts.isNotEmpty) _expanded.add(f.id);
      f.children.forEach(visit);
    }

    kMockLibrary.forEach(visit);
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Map<MockConceptType, int> get _counts {
    final out = <MockConceptType, int>{};
    for (final f in kMockLibrary) {
      f.typeCounts.forEach((k, v) => out[k] = (out[k] ?? 0) + v);
    }
    return out;
  }

  bool _dimmed(MockConcept c) {
    final q = _search.text.trim();
    if (q.isNotEmpty && !c.name.contains(q)) return true;
    return _filter.isNotEmpty && !_filter.contains(c.type);
  }

  void _toggle(MockFolder f) => setState(() {
        _selectedFolder = f.id;
        if (!_expanded.remove(f.id)) _expanded.add(f.id);
      });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ThinkPillTabs(
                labels: const ['A 칩 흐름', 'B 목록', 'C 폴더 카드'],
                icons: const [Icons.bubble_chart_outlined, Icons.view_list_outlined, Icons.dashboard_outlined],
                selected: _design.index,
                onSelected: (i) => setState(() => _design = _Design.values[i]),
              ),
              ThinkPillTabs(
                labels: const ['교재 흐름', '수학 순서', '주제 묶음'],
                icons: const [Icons.menu_book_outlined, Icons.functions, Icons.hub_outlined],
                selected: _order.index,
                onSelected: (i) => setState(() => _order = MockOrder.values[i]),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 640, child: _treePanel()),
                const SizedBox(width: 16),
                Expanded(child: _CatalogPanel(order: _order)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _treePanel() {
    final counts = _counts;
    final total = counts.values.fold(0, (s, v) => s + v);
    return ThinkPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                const Icon(Icons.account_tree_outlined, size: 20, color: kThinkAccent),
                const SizedBox(width: 8),
                const Text('개념 라이브러리', style: TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(width: 8),
                Text('$total', style: const TextStyle(color: kThinkHint, fontSize: 13, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                  tooltip: '영역 추가',
                  onPressed: () {},
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  color: kThinkSub,
                ),
              ],
            ),
          ),
          const Divider(color: kThinkBorder, height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 36,
                  child: TextField(
                    controller: _search,
                    style: const TextStyle(color: kThinkText, fontSize: 13),
                    decoration: thinkInputDecoration(
                      hint: '개념 이름 찾기',
                      dense: true,
                      prefixIcon: const Icon(Icons.search_rounded, size: 18, color: kThinkHint),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final t in MockConceptType.values)
                      if ((counts[t] ?? 0) > 0)
                        _TypeFilterChip(
                          type: t,
                          count: counts[t]!,
                          selected: _filter.contains(t),
                          onTap: () => setState(() => _filter.contains(t) ? _filter.remove(t) : _filter.add(t)),
                        ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 4, bottom: 16),
              children: [
                for (var i = 0; i < kMockLibrary.length; i++) ...[
                  if (i > 0) const SizedBox(height: 4),
                  ..._rows(kMockLibrary[i], 0),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _rows(MockFolder f, int depth) {
    final open = _expanded.contains(f.id);
    if (_design == _Design.cards && f.children.isEmpty && f.concepts.isNotEmpty) {
      return [_card(f, depth, open)];
    }
    return [
      _FolderRow(
        folder: f,
        depth: depth,
        expanded: open,
        selected: _selectedFolder == f.id,
        onTap: () => _toggle(f),
      ),
      if (open && f.concepts.isNotEmpty) _conceptBlock(f, depth),
      if (open)
        for (final c in f.children) ..._rows(c, depth + 1),
    ];
  }

  Widget _chip(MockConcept c) => _ConceptChip(
        concept: c,
        opened: _opened == c.id,
        picked: _picked == c.id,
        dimmed: _dimmed(c),
        onTap: () => setState(() => _opened = c.id),
      );

  Widget _conceptBlock(MockFolder f, int depth) {
    final groups = orderConcepts(f.concepts, _order);
    final topic = _order == MockOrder.topic;
    if (_design == _Design.list) {
      return CustomPaint(
        painter: _GuidePainter(depth + 1),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final g in groups) ...[
                if (topic && g.title == '그 밖의 개념') _restLabel(depth + 1),
                for (var i = 0; i < g.concepts.length; i++)
                  _ConceptRow(
                    concept: g.concepts[i],
                    left: _contentLeft(depth + 1),
                    sub: topic && g.title != '그 밖의 개념' && i > 0,
                    lastSub: i == g.concepts.length - 1,
                    opened: _opened == g.concepts[i].id,
                    picked: _picked == g.concepts[i].id,
                    dimmed: _dimmed(g.concepts[i]),
                    onTap: () => setState(() => _opened = g.concepts[i].id),
                  ),
              ],
            ],
          ),
        ),
      );
    }
    return CustomPaint(
      painter: _GuidePainter(depth + 1),
      child: Padding(
        padding: EdgeInsets.fromLTRB(_contentLeft(depth + 1), 4, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < groups.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              if (topic)
                _TopicCluster(title: groups[i].title!, children: [for (final c in groups[i].concepts) _chip(c)])
              else
                Wrap(spacing: 8, runSpacing: 8, children: [for (final c in groups[i].concepts) _chip(c)]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _restLabel(int depth) => Padding(
        padding: EdgeInsets.fromLTRB(_contentLeft(depth), 8, 12, 4),
        child: const Text('그 밖의 개념 · 이 폴더에 묶을 정의가 없음',
            style: TextStyle(color: kThinkHint, fontSize: 11, fontWeight: FontWeight.w700)),
      );

  Widget _card(MockFolder f, int depth, bool open) {
    final groups = orderConcepts(f.concepts, _order);
    final topic = _order == MockOrder.topic;
    final selected = _selectedFolder == f.id;
    return CustomPaint(
      painter: _GuidePainter(depth),
      child: Padding(
        padding: EdgeInsets.fromLTRB(4 + depth * _indent, 4, 8, 8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            color: kThinkBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? kThinkAccent.withValues(alpha: 0.5) : kThinkBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _toggle(f),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 10, 12, 10),
                    child: Row(
                      children: [
                        AnimatedRotation(
                          turns: open ? 0.25 : 0,
                          duration: const Duration(milliseconds: 160),
                          child: const Icon(Icons.chevron_right_rounded, size: _chevron, color: kThinkSub),
                        ),
                        const SizedBox(width: 4),
                        Icon(open ? Icons.folder_open_outlined : Icons.folder_outlined,
                            size: 16, color: selected ? kThinkAccent : kThinkSub),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(f.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(width: 8),
                        Text('${f.total}', style: const TextStyle(color: kThinkHint, fontSize: 12, fontWeight: FontWeight.w700)),
                        const Spacer(),
                        _TypeBar(counts: f.typeCounts, width: 96),
                      ],
                    ),
                  ),
                ),
              ),
              if (open) ...[
                const Divider(color: kThinkBorder, height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < groups.length; i++) ...[
                        if (i > 0) ...[
                          const SizedBox(height: 10),
                          if (topic) const Divider(color: kThinkBorder, height: 1),
                          if (topic) const SizedBox(height: 10),
                        ],
                        if (topic) ...[
                          Text(groups[i].title!,
                              style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                        ],
                        Wrap(spacing: 8, runSpacing: 8, children: [for (final c in groups[i].concepts) _chip(c)]),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
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
    required this.folder,
    required this.depth,
    required this.expanded,
    required this.selected,
    required this.onTap,
  });

  final MockFolder folder;
  final int depth;
  final bool expanded;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<_FolderRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final f = widget.folder;
    final has = f.children.isNotEmpty || f.concepts.isNotEmpty;
    final selected = widget.selected;
    final icon = f.area
        ? Icons.account_tree_outlined
        : (widget.expanded ? Icons.folder_open_outlined : Icons.folder_outlined);
    return SizedBox(
      height: 36,
      child: CustomPaint(
        painter: _GuidePainter(widget.depth),
        child: Padding(
          padding: EdgeInsets.only(left: 4 + widget.depth * _indent, right: 8),
          child: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.only(left: 4, right: 4),
                decoration: BoxDecoration(
                  color: selected
                      ? kThinkAccent.withValues(alpha: 0.12)
                      : (_hover ? Colors.white.withValues(alpha: 0.04) : Colors.transparent),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: widget.expanded ? 0.25 : 0,
                      duration: const Duration(milliseconds: 160),
                      child: Icon(Icons.chevron_right_rounded,
                          size: _chevron, color: has ? kThinkSub : Colors.transparent),
                    ),
                    const SizedBox(width: 4),
                    Icon(icon, size: 16, color: selected || f.area ? kThinkAccent : kThinkSub),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        f.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: f.area || selected ? kThinkText : kThinkText.withValues(alpha: 0.88),
                          fontSize: 14,
                          fontWeight: f.area ? FontWeight.w800 : (selected ? FontWeight.w700 : FontWeight.w600),
                        ),
                      ),
                    ),
                    if (_hover) ...[
                      _RowAction(icon: Icons.add_rounded, tooltip: '하위 폴더'),
                      _RowMenu(),
                    ] else if (f.total > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text('${f.total}',
                            style: const TextStyle(color: kThinkHint, fontSize: 12, fontWeight: FontWeight.w700)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RowAction extends StatelessWidget {
  const _RowAction({required this.icon, required this.tooltip});

  final IconData icon;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () {},
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(width: 28, height: 28, child: Icon(icon, size: 18, color: kThinkSub)),
      ),
    );
  }
}

class _RowMenu extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '폴더 메뉴',
      color: kThinkPanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: kThinkBorder)),
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      itemBuilder: (_) => [
        for (final (icon, label) in const [
          (Icons.edit_outlined, '이름 바꾸기'),
          (Icons.arrow_upward_rounded, '위로'),
          (Icons.arrow_downward_rounded, '아래로'),
        ])
          PopupMenuItem(
            height: 36,
            value: label,
            child: Row(children: [
              Icon(icon, size: 16, color: kThinkSub),
              const SizedBox(width: 10),
              Text(label, style: const TextStyle(color: kThinkText, fontSize: 13)),
            ]),
          ),
        const PopupMenuDivider(height: 8),
        const PopupMenuItem(
          height: 36,
          value: 'delete',
          child: Row(children: [
            Icon(Icons.delete_outline, size: 16, color: kThinkError),
            SizedBox(width: 10),
            Text('삭제', style: TextStyle(color: kThinkError, fontSize: 13)),
          ]),
        ),
      ],
      child: const SizedBox(width: 28, height: 28, child: Icon(Icons.more_horiz_rounded, size: 18, color: kThinkSub)),
    );
  }
}

class _TypeGlyph extends StatelessWidget {
  const _TypeGlyph(this.type);

  final MockConceptType type;

  @override
  Widget build(BuildContext context) {
    const size = 18.0;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: type.color.withValues(alpha: 0.24), shape: BoxShape.circle),
      child: Text(type.glyph,
          style: TextStyle(color: type.color, fontSize: size * 0.56, fontWeight: FontWeight.w800, height: 1)),
    );
  }
}

/// 개념 칩: 유형 글자 + 이름. 유형 색은 옅게 채우고, 열어 둔 개념·Think 참고만 테두리를 그린다.
class _ConceptChip extends StatefulWidget {
  const _ConceptChip({
    required this.concept,
    this.opened = false,
    this.picked = false,
    this.dimmed = false,
    this.onTap,
  });

  final MockConcept concept;
  final bool opened;
  final bool picked;
  final bool dimmed;
  final VoidCallback? onTap;

  @override
  State<_ConceptChip> createState() => _ConceptChipState();
}

class _ConceptChipState extends State<_ConceptChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.concept;
    final color = c.type.color;
    final fg = Color.lerp(color, Colors.white, 0.4)!;
    final ring = widget.opened || widget.picked;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      opacity: widget.dimmed ? 0.28 : 1,
      child: Tooltip(
        message: [
          '${c.type.label} · ${c.name}${c.version == null ? '' : ' (${c.version})'}',
          if (widget.picked) 'Think 대화가 참고하는 개념',
        ].join('\n'),
        waitDuration: const Duration(milliseconds: 400),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              height: 30,
              padding: const EdgeInsets.only(left: 6, right: 12),
              decoration: BoxDecoration(
                color: color.withValues(alpha: widget.opened ? 0.26 : (_hover ? 0.18 : 0.10)),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: ring ? color.withValues(alpha: 0.9) : Colors.transparent),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _TypeGlyph(c.type),
                  const SizedBox(width: 8),
                  Text(c.name, style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w600)),
                  if (c.version != null) ...[
                    const SizedBox(width: 4),
                    Text(c.version!,
                        style: TextStyle(color: fg.withValues(alpha: 0.6), fontSize: 11, fontWeight: FontWeight.w700)),
                  ],
                  if (widget.picked) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.forum_rounded, size: 14, color: color),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// B안 개념 줄: 유형 꼬리표 + 이름. 주제 묶음이면 정의 아래로 한 칸 들여 쓴다.
class _ConceptRow extends StatefulWidget {
  const _ConceptRow({
    required this.concept,
    required this.left,
    this.sub = false,
    this.lastSub = false,
    this.opened = false,
    this.picked = false,
    this.dimmed = false,
    this.onTap,
  });

  final MockConcept concept;
  final double left;
  final bool sub;
  final bool lastSub;
  final bool opened;
  final bool picked;
  final bool dimmed;
  final VoidCallback? onTap;

  @override
  State<_ConceptRow> createState() => _ConceptRowState();
}

class _ConceptRowState extends State<_ConceptRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.concept;
    final color = c.type.color;
    final left = widget.left + (widget.sub ? 24 : 0);
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      opacity: widget.dimmed ? 0.28 : 1,
      child: SizedBox(
        height: 32,
        child: CustomPaint(
          painter: widget.sub ? _SubLinePainter(x: widget.left + 18, last: widget.lastSub) : null,
          child: Padding(
            padding: EdgeInsets.only(left: left - 4, right: 8),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => setState(() => _hover = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: widget.opened
                        ? color.withValues(alpha: 0.14)
                        : (_hover ? Colors.white.withValues(alpha: 0.04) : Colors.transparent),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 20,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(c.type.label,
                            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800, height: 1)),
                      ),
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
                      if (c.version != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(c.version!,
                              style: const TextStyle(color: kThinkHint, fontSize: 11, fontWeight: FontWeight.w700)),
                        ),
                      if (widget.picked)
                        const Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: Tooltip(
                            message: 'Think 대화가 참고하는 개념',
                            child: Icon(Icons.forum_rounded, size: 14, color: kThinkAccent),
                          ),
                        ),
                    ],
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

class _SubLinePainter extends CustomPainter {
  const _SubLinePainter({required this.x, required this.last});

  final double x;
  final bool last;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = kThinkBorder
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final mid = size.height / 2;
    final path = Path()
      ..moveTo(x, 0)
      ..lineTo(x, mid - 6)
      ..quadraticBezierTo(x, mid, x + 6, mid)
      ..lineTo(x + 12, mid);
    canvas.drawPath(path, paint);
    if (!last) canvas.drawLine(Offset(x, mid - 6), Offset(x, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant _SubLinePainter old) => old.x != x || old.last != last;
}

/// A안 주제 묶음: 정의 하나와 그것을 쓰는 개념들을 옅은 상자로 묶는다.
class _TopicCluster extends StatelessWidget {
  const _TopicCluster({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rest = title == '그 밖의 개념';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kThinkBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rest)
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 8),
              child: Text('그 밖의 개념 · 이 폴더에 묶을 정의가 없음',
                  style: TextStyle(color: kThinkHint, fontSize: 11, fontWeight: FontWeight.w700)),
            ),
          Wrap(spacing: 8, runSpacing: 8, children: children),
        ],
      ),
    );
  }
}

/// 폴더 안 유형 비율 막대(수학 순서대로).
class _TypeBar extends StatelessWidget {
  const _TypeBar({required this.counts, required this.width});

  final Map<MockConceptType, int> counts;
  final double width;

  @override
  Widget build(BuildContext context) {
    final types = [for (final t in MockConceptType.values) if ((counts[t] ?? 0) > 0) t];
    return Tooltip(
      message: [for (final t in types) '${t.label} ${counts[t]}'].join(' · '),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: SizedBox(
          width: width,
          height: 4,
          child: Row(
            children: [
              for (final t in types) Expanded(flex: counts[t]!, child: ColoredBox(color: t.color)),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypeFilterChip extends StatelessWidget {
  const _TypeFilterChip({required this.type, required this.count, required this.selected, required this.onTap});

  final MockConceptType type;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 30,
          padding: const EdgeInsets.only(left: 6, right: 12),
          decoration: BoxDecoration(
            color: selected ? type.color.withValues(alpha: 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: selected ? type.color.withValues(alpha: 0.6) : kThinkBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TypeGlyph(type),
              const SizedBox(width: 8),
              Text(type.label,
                  style: TextStyle(
                      color: selected ? kThinkText : kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(width: 4),
              Text('$count', style: const TextStyle(color: kThinkHint, fontSize: 12, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}

class _CatalogPanel extends StatelessWidget {
  const _CatalogPanel({required this.order});

  final MockOrder order;

  static const _samples = {
    MockConceptType.definition: MockConcept('s1', '소수', MockConceptType.definition),
    MockConceptType.notation: MockConcept('s2', '거듭제곱의 밑', MockConceptType.notation),
    MockConceptType.caution: MockConcept('s3', '1은 소수도 합성수도 아니다', MockConceptType.caution),
    MockConceptType.property: MockConcept('s4', '소인수분해 결과의 유일성', MockConceptType.property),
    MockConceptType.method: MockConcept('s5', '에라토스테네스의 체', MockConceptType.method),
    MockConceptType.none: MockConcept('s6', '예전에 만든 개념', MockConceptType.none),
  };

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(t, style: const TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800)),
      );

  Widget _state(String caption, Widget chip) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          chip,
          const SizedBox(height: 4),
          Text(caption, style: const TextStyle(color: kThinkHint, fontSize: 11, fontWeight: FontWeight.w700)),
        ],
      );

  Widget _rule(MockOrder o, String title, String body) {
    final on = o == order;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: on ? kThinkAccent.withValues(alpha: 0.08) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: on ? kThinkAccent.withValues(alpha: 0.5) : kThinkBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(color: on ? kThinkText : kThinkSub, fontSize: 13, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(body, style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.5)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const g = MockConcept('s7', '최대공약수', MockConceptType.definition, version: '기본-2');
    return ThinkPanel(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _title('개념 유형 칩'),
          const Text('칩 앞 글자와 색으로 유형을 구분합니다. 번호는 수학 순서입니다.',
              style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 12),
          for (final t in MockConceptType.values)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    child: Text(t == MockConceptType.none ? '–' : '${t.rank + 1}',
                        style: const TextStyle(color: kThinkHint, fontSize: 13, fontWeight: FontWeight.w800)),
                  ),
                  SizedBox(
                    width: 260,
                    child: Align(alignment: Alignment.centerLeft, child: _ConceptChip(concept: _samples[t]!)),
                  ),
                  Expanded(
                    child: Text('${t.label} — ${t.description}',
                        style: const TextStyle(color: kThinkSub, fontSize: 12)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          _title('칩 상태'),
          Wrap(
            spacing: 16,
            runSpacing: 12,
            children: [
              _state('기본', _ConceptChip(concept: _samples[MockConceptType.property]!)),
              _state('열어 둠', _ConceptChip(concept: _samples[MockConceptType.property]!, opened: true)),
              _state('Think 참고', _ConceptChip(concept: _samples[MockConceptType.method]!, picked: true)),
              _state('다른 판', const _ConceptChip(concept: g)),
              _state('걸러져 흐림', _ConceptChip(concept: _samples[MockConceptType.definition]!, dimmed: true)),
            ],
          ),
          const SizedBox(height: 24),
          _title('칩 순서'),
          _rule(MockOrder.flow, '교재 흐름',
              '확정한 순서(교재에 나온 순서) 그대로. 지금 라이브러리와 같습니다.'),
          _rule(MockOrder.math, '수학 순서',
              '정의 → 표현 → 주의 → 성질 → 방법. 같은 유형 안은 교재 흐름. 뜻을 먼저 알고, 나타내는 법과 헷갈리는 점을 본 뒤, '
                  '늘 성립하는 사실과 그 사실로 구하는 법을 보는 순서입니다. 지금 데이터만으로 됩니다.'),
          _rule(MockOrder.topic, '주제 묶음 (제안)',
              '정의마다 묶고, 그 정의를 쓰는 표현·주의·성질·방법을 바로 뒤에 둡니다. 묶음 안은 수학 순서. '
                  '어느 정의에 붙는지는 지금 DB에 없어서, 실제로는 Think가 묶음을 제안하고 승인해야 합니다(이 화면은 손으로 붙인 예시).'),
          const SizedBox(height: 16),
          _title('확인 부탁'),
          const ThinkNotice(
            text: '표현의 보라(#B39DDB)는 앱에 없던 새 색입니다. 정의·주의·성질·방법 색은 앱에서 이미 쓰는 색입니다.',
            color: kThinkAccent,
            icon: Icons.palette_outlined,
          ),
          const SizedBox(height: 8),
          const ThinkNotice(
            text: '폴더 버튼(하위 폴더·이름 바꾸기·위아래·삭제)은 늘 보이던 다섯 개 대신, 마우스를 올리면 더하기와 더보기 메뉴 두 개로 나옵니다.',
            icon: Icons.mouse_outlined,
          ),
          const SizedBox(height: 8),
          const ThinkNotice(
            text: '위쪽 찾기·유형 거르기는 새로 더하는 기능입니다. 맞지 않는 칩은 숨기지 않고 흐리게 둡니다.',
            icon: Icons.filter_alt_outlined,
          ),
        ],
      ),
    );
  }
}
