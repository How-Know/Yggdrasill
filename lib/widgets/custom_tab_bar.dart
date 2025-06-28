import 'package:flutter/material.dart';

class CustomTabBar extends StatefulWidget {
  final int selectedIndex;
  final List<String> tabs;
  final ValueChanged<int> onTabSelected;
  const CustomTabBar({
    required this.selectedIndex,
    required this.tabs,
    required this.onTabSelected,
    super.key,
  });

  @override
  State<CustomTabBar> createState() => _CustomTabBarState();
}

class _CustomTabBarState extends State<CustomTabBar> {
  final Set<int> _hoveredTabs = {};

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(widget.tabs.length, (i) {
            final isSelected = i == widget.selectedIndex;
            final isHovered = _hoveredTabs.contains(i);
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hoveredTabs.add(i)),
              onExit: (_) => setState(() => _hoveredTabs.remove(i)),
              child: GestureDetector(
                onTap: () {
                  widget.onTabSelected(i);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: const EdgeInsets.symmetric(horizontal: 23, vertical: 8),
                  decoration: BoxDecoration(
                    color: isHovered && !isSelected
                        ? Colors.white.withOpacity(0.07)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: [
                      Text(
                        widget.tabs[i],
                        style: TextStyle(
                          color: isSelected ? Color(0xFF1976D2) : Colors.white70,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        height: 6,
                        width: 60,
                        decoration: BoxDecoration(
                          color: isSelected ? Color(0xFF1976D2) : Colors.transparent,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
} 