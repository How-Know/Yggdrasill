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
  @override
  Widget build(BuildContext context) {
    const tabWidth = 120.0;
    final tabCount = widget.tabs.length;
    const tabGap = 21.0;
    final totalWidth = tabWidth * tabCount + tabGap * (tabCount - 1);
    return SizedBox(
      height: 48,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final leftPadding = (constraints.maxWidth - totalWidth) / 2;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeOutBack,
                left: leftPadding + (widget.selectedIndex * (tabWidth + tabGap)),
                bottom: 0,
                child: Container(
                  width: tabWidth,
                  height: 6,
                  decoration: BoxDecoration(
                    color: Colors.blue,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(tabCount, (i) =>
                  Padding(
                    padding: EdgeInsets.only(right: i < tabCount - 1 ? tabGap : 0),
                    child: SizedBox(
                      width: tabWidth,
                      child: TextButton(
                        onPressed: () => widget.onTabSelected(i),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                        ),
                        child: Text(
                          widget.tabs[i],
                          style: TextStyle(
                            color: widget.selectedIndex == i ? Colors.blue : Colors.white70,
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                      ),
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