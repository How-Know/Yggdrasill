import 'package:flutter/material.dart';
import '../../widgets/pill_tab_selector.dart';
import '../../widgets/animated_reorderable_grid.dart';
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
  final ScrollController _gridScrollCtrl = ScrollController();

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

  @override
  Widget build(BuildContext context) {
    final orderedCards = _orderedCards();
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
                    width: gridWidth,
                    child: AnimatedReorderableGrid<_CurriculumCard>(
                      items: orderedCards,
                      itemId: (card) => card.id,
                      itemBuilder: (context, card) => _CurriculumCardTile(card: card),
                      feedbackBuilder: (context, card) => _CurriculumCardTile(card: card),
                      cardWidth: gridCardWidth,
                      cardHeight: gridCardHeight,
                      spacing: spacing,
                      columns: cols,
                      scrollController: _gridScrollCtrl,
                      animationDuration: const Duration(milliseconds: 180),
                      animationCurve: Curves.easeOutCubic,
                      onReorder: (card, targetIndex) {
                        setState(() {
                          _commitCardReorder(id: card.id, targetIndex: targetIndex);
                        });
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
