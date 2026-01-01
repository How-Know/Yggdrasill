import 'package:flutter/material.dart';

/// 시간메뉴(시간표 상단)와 동일한 "필(pill) + 슬라이딩 인디케이터" 탭 셀렉터.
class PillTabSelector extends StatelessWidget {
  final int selectedIndex;
  final List<String> tabs;
  final ValueChanged<int> onTabSelected;
  final double width;

  const PillTabSelector({
    super.key,
    required this.selectedIndex,
    required this.tabs,
    required this.onTabSelected,
    this.width = 288,
  });

  @override
  Widget build(BuildContext context) {
    // 좌/우 컨트롤(추가/검색/필터) 높이 = 48
    const double controlHeight = 48;
    return SizedBox(
      width: width,
      child: Container(
        height: controlHeight,
        decoration: BoxDecoration(
          color: const Color(0xFF151C21),
          borderRadius: BorderRadius.circular(controlHeight / 2),
        ),
        padding: const EdgeInsets.all(4),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final double tabWidth = (constraints.maxWidth - 8) / tabs.length;
            return Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  left: selectedIndex * tabWidth,
                  top: 0,
                  bottom: 0,
                  width: tabWidth,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B6B63),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 51),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  children: tabs.asMap().entries.map((entry) {
                    final index = entry.key;
                    final label = entry.value;
                    final isSelected = selectedIndex == index;
                    return GestureDetector(
                      onTap: () => onTabSelected(index),
                      behavior: HitTestBehavior.translucent,
                      child: SizedBox(
                        width: tabWidth,
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 200),
                            style: TextStyle(
                              color: isSelected ? Colors.white : const Color(0xFF7E8A8A),
                              fontWeight: FontWeight.w600,
                              fontSize: 17,
                            ),
                            child: Text(label),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}


