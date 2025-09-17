import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../services/data_manager.dart';

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
    final logoBytes = DataManager.instance.academySettings.logo;
    final academyName = DataManager.instance.academySettings.name;
    return Column(
      children: [
        Expanded(
          child: NavigationRail(
            backgroundColor: const Color(0xFF1F1F1F),
            selectedIndex: selectedIndex,
            onDestinationSelected: onDestinationSelected,
            leading: Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: IconButton(
                icon: AnimatedBuilder(
                  animation: rotationAnimation,
                  builder: (context, child) => Transform.rotate(
                    angle: rotationAnimation.value,
                    child: child,
                  ),
                  child: const Icon(
                    Symbols.package_2,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
                onPressed: onMenuPressed,
              ),
            ),
            useIndicator: true,
            indicatorShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            destinations: const [
              NavigationRailDestination(
                padding: EdgeInsets.symmetric(vertical: 10),
                icon: Tooltip(
                  message: '홈',
                  child: Icon(Symbols.home_rounded),
                ),
                selectedIcon: Tooltip(
                  message: '홈',
                  child: Icon(Symbols.home_rounded, weight: 700),
                ),
                label: Text(''),
              ),
              NavigationRailDestination(
                padding: EdgeInsets.symmetric(vertical: 10),
                icon: Tooltip(
                  message: '학생',
                  child: Icon(Symbols.person_rounded),
                ),
                selectedIcon: Tooltip(
                  message: '학생',
                  child: Icon(Symbols.person_rounded, weight: 700),
                ),
                label: Text(''),
              ),
              NavigationRailDestination(
                padding: EdgeInsets.symmetric(vertical: 10),
                icon: Tooltip(
                  message: '시간',
                  child: Icon(Symbols.timer_rounded),
                ),
                selectedIcon: Tooltip(
                  message: '시간',
                  child: Icon(Symbols.timer_rounded, weight: 700),
                ),
                label: Text(''),
              ),
              NavigationRailDestination(
                padding: EdgeInsets.symmetric(vertical: 10),
                icon: Tooltip(
                  message: '학습',
                  child: Icon(Symbols.network_intel_node),
                ),
                selectedIcon: Tooltip(
                  message: '학습',
                  child: Icon(Symbols.network_intel_node, weight: 700),
                ),
                label: Text(''),
              ),
              NavigationRailDestination(
                padding: EdgeInsets.symmetric(vertical: 10),
                icon: Tooltip(
                  message: '자료',
                  child: Icon(Symbols.auto_stories),
                ),
                selectedIcon: Tooltip(
                  message: '자료',
                  child: Icon(Symbols.auto_stories, weight: 700),
                ),
                label: Text(''),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 16.0),
          child: logoBytes != null && logoBytes.isNotEmpty
              ? Tooltip(
                  message: academyName.isNotEmpty ? academyName : '학원명',
                  child: ClipOval(
                    child: Image.memory(
                      logoBytes,
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                    ),
                  ),
                )
              : Tooltip(
                  message: academyName.isNotEmpty ? academyName : '학원명',
                  child: CircleAvatar(
                    radius: 24,
                    backgroundColor: Colors.grey[700],
                    child: const Icon(Icons.school, color: Colors.white, size: 28),
                  ),
                ),
        ),
      ],
    );
  }
} 