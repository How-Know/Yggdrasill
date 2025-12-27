import 'package:flutter/material.dart';

// 학생상세 탭바 스타일로 교체하면서 기존 CustomTabBar는 사용하지 않음.

/// 학생 상세(수강 상세) 상단 탭바와 동일한 "필(pill) + 슬라이딩 인디케이터" 스타일
class _PillTabSelector extends StatelessWidget {
  final int selectedIndex;
  final List<String> tabs;
  final ValueChanged<int> onTabSelected;
  final double width;

  const _PillTabSelector({
    required this.selectedIndex,
    required this.tabs,
    required this.onTabSelected,
    // ✅ 20% 확장(기존 240 → 288)
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
                              // ✅ 20% 확대(기존 14 → 17)
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

class TimetableTopBar extends StatelessWidget {
  final Widget registerControls;
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;
  final Widget actionRow;

  const TimetableTopBar({
    super.key,
    required this.registerControls,
    required this.selectedIndex,
    required this.onTabSelected,
    required this.actionRow,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 1,
          child: Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: registerControls,
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: Center(
            // ✅ 학생상세정보 페이지 탭바 스타일로 변경(필/슬라이딩)
            child: _PillTabSelector(
              selectedIndex: selectedIndex,
              tabs: const ['수업', '일정'],
              onTabSelected: onTabSelected,
            ),
          ),
        ),
        Expanded(
          flex: 1,
          child: Align(
            alignment: Alignment.centerRight,
            child: actionRow,
          ),
        ),
      ],
    );
  }
}

