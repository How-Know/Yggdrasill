import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../../widgets/pill_tab_selector.dart';
import 'problem_bank_view.dart';

class LearningScreen extends StatefulWidget {
  const LearningScreen({super.key});

  @override
  State<LearningScreen> createState() => _LearningScreenState();
}

class _LearningScreenState extends State<LearningScreen> {
  int _selectedTab = 0; // 0: 커리큘럼, 1: 문제은행

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1112),
      body: Column(
        children: [
          const SizedBox(height: 5),
          Center(
            child: PillTabSelector(
              selectedIndex: _selectedTab,
              tabs: const ['커리큘럼', '문제은행'],
              onTabSelected: (i) {
                setState(() {
                  _selectedTab = i;
                });
              },
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _selectedTab == 0
                ? const _LearningCurriculumView()
                : const ProblemBankView(),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _CurriculumCard {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final int orderIndex;

  const _CurriculumCard({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.orderIndex,
  });

  _CurriculumCard copyWith({int? orderIndex}) {
    return _CurriculumCard(
      id: id,
      title: title,
      subtitle: subtitle,
      icon: icon,
      color: color,
      orderIndex: orderIndex ?? this.orderIndex,
    );
  }
}

class _LearningCurriculumView extends StatefulWidget {
  const _LearningCurriculumView();

  @override
  State<_LearningCurriculumView> createState() => _LearningCurriculumViewState();
}

class _LearningCurriculumViewState extends State<_LearningCurriculumView> {
  final List<_CurriculumCard> _cards = [];
  final GlobalKey _gridViewportKey = GlobalKey();
  final ScrollController _gridScrollCtrl = ScrollController();
  String? _draggingCardId;
  int? _pendingDropIndex;

  @override
  void initState() {
    super.initState();
    _cards.addAll(_seedDummyCards());
  }

  @override
  void dispose() {
    _gridScrollCtrl.dispose();
    super.dispose();
  }

  List<_CurriculumCard> _seedDummyCards() {
    return const [
      _CurriculumCard(id: 'c1', title: '수와 연산', subtitle: '기초 연산 감각', icon: Icons.calculate, color: Color(0xFF1E2A36), orderIndex: 0),
      _CurriculumCard(id: 'c2', title: '도형', subtitle: '도형의 성질', icon: Icons.crop_square, color: Color(0xFF20313B), orderIndex: 1),
      _CurriculumCard(id: 'c3', title: '측정', subtitle: '길이·넓이·부피', icon: Icons.straighten, color: Color(0xFF222C44), orderIndex: 2),
      _CurriculumCard(id: 'c4', title: '문자와 식', subtitle: '식의 이해', icon: Icons.functions, color: Color(0xFF2B2A3B), orderIndex: 3),
      _CurriculumCard(id: 'c5', title: '함수', subtitle: '좌표와 그래프', icon: Icons.show_chart, color: Color(0xFF2C2437), orderIndex: 4),
      _CurriculumCard(id: 'c6', title: '확률과 통계', subtitle: '자료 해석', icon: Icons.analytics, color: Color(0xFF1E3234), orderIndex: 5),
      _CurriculumCard(id: 'c7', title: '기하', subtitle: '공간감각', icon: Icons.grid_on, color: Color(0xFF24312A), orderIndex: 6),
      _CurriculumCard(id: 'c8', title: '미적분', subtitle: '변화율과 극한', icon: Icons.auto_graph, color: Color(0xFF2E2A24), orderIndex: 7),
      _CurriculumCard(id: 'c9', title: '문제풀이', subtitle: '실전 적용', icon: Icons.lightbulb, color: Color(0xFF2A2E3C), orderIndex: 8),
      _CurriculumCard(id: 'c10', title: '심화', subtitle: '확장 문제', icon: Icons.bolt, color: Color(0xFF2F2B35), orderIndex: 9),
    ];
  }

  List<_CurriculumCard> _orderedCards() {
    final list = List<_CurriculumCard>.from(_cards);
    list.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    return list;
  }

  List<_CurriculumCard> _buildPreviewCards(List<_CurriculumCard> ordered) {
    if (_draggingCardId == null) {
      return ordered;
    }
    final dragIndex = ordered.indexWhere((x) => x.id == _draggingCardId);
    if (dragIndex == -1) {
      return ordered;
    }
    final list = List<_CurriculumCard>.from(ordered);
    final moved = list.removeAt(dragIndex);
    final insertAt = (_pendingDropIndex ?? dragIndex).clamp(0, list.length);
    list.insert(insertAt, moved);
    return list;
  }

  void _commitCardReorder({
    required String id,
    required int targetIndex,
  }) {
    final ordered = _orderedCards();
    if (ordered.isEmpty) return;
    final fromIdx = ordered.indexWhere((x) => x.id == id);
    if (fromIdx == -1) return;
    final moved = ordered.removeAt(fromIdx);
    final toIdx = targetIndex.clamp(0, ordered.length);
    ordered.insert(toIdx, moved);
    for (int i = 0; i < ordered.length; i++) {
      final gIdx = _cards.indexWhere((x) => x.id == ordered[i].id);
      if (gIdx != -1 && _cards[gIdx].orderIndex != i) {
        _cards[gIdx] = _cards[gIdx].copyWith(orderIndex: i);
      }
    }
  }

  int _calcDropIndexFromGlobal({
    required Offset globalPosition,
    required int cols,
    required double gridCardWidth,
    required double gridCardHeight,
    required double spacing,
    required double gridWidth,
    required GlobalKey viewportKey,
    required ScrollController scrollCtrl,
    required int itemCount,
  }) {
    final box = viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return math.max(0, itemCount - 1);
    final local = box.globalToLocal(globalPosition);
    final maxX = math.max(0.0, gridWidth - 1);
    final x = local.dx.clamp(0.0, maxX);
    final scrollOffset = scrollCtrl.hasClients ? scrollCtrl.offset : 0.0;
    final y = (local.dy + scrollOffset).clamp(0.0, double.infinity);
    final slotWidth = gridCardWidth + spacing;
    final slotHeight = gridCardHeight + spacing;
    var col = (x / slotWidth).floor();
    final colOffset = x - (col * slotWidth);
    if (colOffset > gridCardWidth) col += 1;
    col = col.clamp(0, cols);
    var row = (y / slotHeight).floor();
    final rowOffset = y - (row * slotHeight);
    if (rowOffset > gridCardHeight) row += 1;
    var targetIndex = row * cols + col;
    targetIndex = targetIndex.clamp(0, math.max(0, itemCount - 1));
    return targetIndex;
  }

  void _handleGridDragUpdate({
    required Offset globalPosition,
    required _CurriculumCard incoming,
    required int cols,
    required double gridCardWidth,
    required double gridCardHeight,
    required double spacing,
    required double gridWidth,
    required GlobalKey viewportKey,
    required ScrollController scrollCtrl,
  }) {
    if (_draggingCardId == null || incoming.id != _draggingCardId) return;
    final box = viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalPosition);
    final maxX = math.max(0.0, gridWidth - 1);
    final x = local.dx.clamp(0.0, maxX);
    final scrollOffset = scrollCtrl.hasClients ? scrollCtrl.offset : 0.0;
    final y = (local.dy + scrollOffset).clamp(0.0, double.infinity);
    final slotWidth = gridCardWidth + spacing;
    final slotHeight = gridCardHeight + spacing;
    var col = (x / slotWidth).floor();
    final colOffset = x - (col * slotWidth);
    if (colOffset > gridCardWidth) col += 1; // 카드 사이 여백이면 다음 칸
    col = col.clamp(0, cols);
    var row = (y / slotHeight).floor();
    final rowOffset = y - (row * slotHeight);
    if (rowOffset > gridCardHeight) row += 1; // 줄 사이 여백이면 다음 줄
    final ordered = _orderedCards();
    if (ordered.isEmpty) return;
    var targetIndex = row * cols + col;
    targetIndex = targetIndex.clamp(0, math.max(0, ordered.length - 1));
    if (_pendingDropIndex == targetIndex) {
      _maybeAutoScroll(local.dy, box.size.height, scrollCtrl);
      return;
    }
    setState(() {
      _pendingDropIndex = targetIndex;
    });
    _maybeAutoScroll(local.dy, box.size.height, scrollCtrl);
  }

  void _maybeAutoScroll(double localDy, double viewportHeight, ScrollController scrollCtrl) {
    if (!scrollCtrl.hasClients) return;
    const edge = 60.0;
    const step = 18.0;
    final offset = scrollCtrl.offset;
    final max = scrollCtrl.position.maxScrollExtent;
    if (localDy < edge && offset > 0) {
      scrollCtrl.jumpTo(math.max(0.0, offset - step));
    } else if (localDy > viewportHeight - edge && offset < max) {
      scrollCtrl.jumpTo(math.min(max, offset + step));
    }
  }

  @override
  Widget build(BuildContext context) {
    final orderedCards = _orderedCards();
    final previewCards = _buildPreviewCards(orderedCards);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const double gridCardWidth = 240.0;
          const double gridCardHeight = 150.0;
          const double spacing = 16.0;
          final cols = (constraints.maxWidth / (gridCardWidth + spacing)).floor().clamp(1, 999);
          final double gridWidth = (cols * gridCardWidth) + ((cols - 1) * spacing);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 2, 2, 14),
                child: Row(
                  children: [
                    const Text(
                      '커리큘럼',
                      style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C2528),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: const Text(
                        '더미 카드 · 드래그 이동 테스트',
                        style: TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    key: _gridViewportKey,
                    width: gridWidth,
                    child: DragTarget<_CurriculumCard>(
                      onWillAccept: (data) => data != null,
                      onMove: (details) {
                        _handleGridDragUpdate(
                          globalPosition: details.offset,
                          incoming: details.data,
                          cols: cols,
                          gridCardWidth: gridCardWidth,
                          gridCardHeight: gridCardHeight,
                          spacing: spacing,
                          gridWidth: gridWidth,
                          viewportKey: _gridViewportKey,
                          scrollCtrl: _gridScrollCtrl,
                        );
                      },
                      onAcceptWithDetails: (details) {
                        final targetIndex = _calcDropIndexFromGlobal(
                          globalPosition: details.offset,
                          cols: cols,
                          gridCardWidth: gridCardWidth,
                          gridCardHeight: gridCardHeight,
                          spacing: spacing,
                          gridWidth: gridWidth,
                          viewportKey: _gridViewportKey,
                          scrollCtrl: _gridScrollCtrl,
                          itemCount: orderedCards.length,
                        );
                        setState(() {
                          _commitCardReorder(id: details.data.id, targetIndex: targetIndex);
                          _draggingCardId = null;
                          _pendingDropIndex = null;
                        });
                      },
                      builder: (context, cand, rej) {
                        final rowCount = (previewCards.length / cols).ceil();
                        final contentHeight = rowCount == 0
                            ? gridCardHeight
                            : (rowCount * gridCardHeight) + ((rowCount - 1) * spacing);

                        Widget buildDraggableCard(_CurriculumCard card, int index) {
                          final isDragging = _draggingCardId == card.id;
                          final base = SizedBox.expand(child: _CurriculumCardTile(card: card));
                          final cell = Opacity(
                            opacity: isDragging ? 0.0 : 1.0,
                            child: base,
                          );
                          return LongPressDraggable<_CurriculumCard>(
                            key: ValueKey('curriculum-drag-${card.id}'),
                            data: card,
                            hapticFeedbackOnStart: true,
                            dragAnchorStrategy: childDragAnchorStrategy,
                            feedback: Material(
                              color: Colors.transparent,
                              child: Opacity(
                                opacity: 0.9,
                                child: SizedBox(
                                  width: gridCardWidth,
                                  height: gridCardHeight,
                                  child: _CurriculumCardTile(card: card),
                                ),
                              ),
                            ),
                            childWhenDragging: cell,
                            onDragStarted: () {
                              setState(() {
                                _draggingCardId = card.id;
                                _pendingDropIndex = index;
                              });
                            },
                            onDragEnd: (_) {
                              setState(() {
                                _draggingCardId = null;
                                _pendingDropIndex = null;
                              });
                            },
                            onDraggableCanceled: (_, __) {
                              setState(() {
                                _draggingCardId = null;
                                _pendingDropIndex = null;
                              });
                            },
                            child: cell,
                          );
                        }

                        return SingleChildScrollView(
                          controller: _gridScrollCtrl,
                          child: SizedBox(
                            width: gridWidth,
                            height: contentHeight,
                            child: Stack(
                              children: [
                                for (int i = 0; i < previewCards.length; i++)
                                  AnimatedPositioned(
                                    key: ValueKey('curriculum-pos-${previewCards[i].id}'),
                                    duration: const Duration(milliseconds: 180),
                                    curve: Curves.easeOutCubic,
                                    left: (i % cols) * (gridCardWidth + spacing),
                                    top: (i ~/ cols) * (gridCardHeight + spacing),
                                    width: gridCardWidth,
                                    height: gridCardHeight,
                                    child: buildDraggableCard(previewCards[i], i),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CurriculumCardTile extends StatelessWidget {
  final _CurriculumCard card;
  const _CurriculumCardTile({required this.card});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {},
            splashColor: Colors.white.withOpacity(0.06),
            highlightColor: Colors.white.withOpacity(0.03),
            child: Container(
              decoration: BoxDecoration(
                color: card.color,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withOpacity(0.06), width: 0.8),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 16, offset: const Offset(0, 10)),
                  BoxShadow(color: Colors.white.withOpacity(0.04), blurRadius: 2, offset: const Offset(0, 1)),
                ],
              ),
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.25),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(card.icon, color: Colors.white70, size: 20),
                      ),
                      const Spacer(),
                      Text(
                        'STEP ${card.orderIndex + 1}',
                        style: const TextStyle(color: Colors.white38, fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    card.title,
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    card.subtitle,
                    style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Row(
                    children: const [
                      Icon(Icons.drag_indicator, color: Colors.white38, size: 16),
                      SizedBox(width: 6),
                      Text('드래그로 이동', style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
