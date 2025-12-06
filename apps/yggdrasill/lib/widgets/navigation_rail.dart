import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'app_bar_title.dart'; // for AccountButton

const double _navIconSize = 26.0;
const Color _navAccentColor = Color(0xFF1B6B63);
const Color _navBackgroundColor = Color(0xFF0B1112);
const Color _navIconColor = Color(0xFFEAF2F2);

class CustomNavigationRail extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final Animation<double> rotationAnimation;
  final VoidCallback onMenuPressed;

  const CustomNavigationRail({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.rotationAnimation,
    required this.onMenuPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: NavigationRail(
            backgroundColor: _navBackgroundColor,
            unselectedIconTheme: const IconThemeData(color: _navIconColor, size: _navIconSize),
            selectedIconTheme: const IconThemeData(color: _navIconColor, size: _navIconSize),
            indicatorColor: const Color(0xFF223131),
            selectedIndex: selectedIndex.clamp(0, 5),
            onDestinationSelected: onDestinationSelected,
            leading: Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: AnimatedBuilder(
                      animation: rotationAnimation,
                      builder: (context, child) {
                        final isExpanded = rotationAnimation.value != 0;
                        return Transform.rotate(
                          angle: rotationAnimation.value,
                          child: Icon(
                            Symbols.package_2,
                            color: isExpanded ? _navAccentColor : Colors.white,
                            size: 36,
                          ),
                        );
                      },
                    ),
                    onPressed: onMenuPressed,
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: 32,
                    height: 1,
                    color: Colors.white24,
                  ),
                ],
              ),
            ),
            useIndicator: true,
            indicatorShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            destinations: const [
              NavigationRailDestination(
                padding: EdgeInsets.symmetric(vertical: 10),
                icon: Tooltip(
                  message: '홈',
                  child: Icon(Symbols.home_rounded, size: _navIconSize),
                ),
                selectedIcon: Tooltip(
                  message: '홈',
                  child: Icon(Symbols.home_rounded, weight: 700, size: _navIconSize),
                ),
                label: Text(''),
              ),
              NavigationRailDestination(
                padding: EdgeInsets.symmetric(vertical: 10),
                icon: Tooltip(
                  message: '학생',
                  child: Icon(Symbols.person_rounded, size: _navIconSize),
                ),
                selectedIcon: Tooltip(
                  message: '학생',
                  child: Icon(Symbols.person_rounded, weight: 700, size: _navIconSize),
                ),
                label: Text(''),
              ),
              NavigationRailDestination(
                padding: EdgeInsets.symmetric(vertical: 10),
                icon: Tooltip(
                  message: '시간',
                  child: Icon(Symbols.timer_rounded, size: _navIconSize),
                ),
                selectedIcon: Tooltip(
                  message: '시간',
                  child: Icon(Symbols.timer_rounded, weight: 700, size: _navIconSize),
                ),
                label: Text(''),
              ),
              NavigationRailDestination(
                padding: EdgeInsets.symmetric(vertical: 10),
                icon: Tooltip(
                  message: '학습',
                  child: Icon(Symbols.network_intel_node, size: _navIconSize),
                ),
                selectedIcon: Tooltip(
                  message: '학습',
                  child: Icon(Symbols.network_intel_node, weight: 700, size: _navIconSize),
                ),
                label: Text(''),
              ),
              NavigationRailDestination(
                padding: EdgeInsets.symmetric(vertical: 10),
                icon: Tooltip(
                  message: '자료',
                  child: Icon(Symbols.auto_stories, size: _navIconSize),
                ),
                selectedIcon: Tooltip(
                  message: '자료',
                  child: Icon(Symbols.auto_stories, weight: 700, size: _navIconSize),
                ),
                label: Text(''),
              ),
              NavigationRailDestination(
                padding: EdgeInsets.symmetric(vertical: 10),
                icon: Tooltip(
                  message: '설정',
                  child: Icon(Symbols.settings, size: _navIconSize),
                ),
                selectedIcon: Tooltip(
                  message: '설정',
                  child: Icon(Symbols.settings, weight: 700, size: _navIconSize),
                ),
                label: Text(''),
              ),
            ],
          ),
        ),
        AccountButton(
          padding: const EdgeInsets.only(bottom: 16.0),
          radius: 20,
        ),
      ],
    );
  }
} 