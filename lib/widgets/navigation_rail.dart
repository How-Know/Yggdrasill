import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

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
    return NavigationRail(
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
            child: Icon(Symbols.school_rounded),
          ),
          selectedIcon: Tooltip(
            message: '학습',
            child: Icon(Symbols.school_rounded, weight: 700),
          ),
          label: Text(''),
        ),
        NavigationRailDestination(
          padding: EdgeInsets.symmetric(vertical: 10),
          icon: Tooltip(
            message: '설정',
            child: Icon(Symbols.settings_rounded),
          ),
          selectedIcon: Tooltip(
            message: '설정',
            child: Icon(Symbols.settings_rounded, weight: 700),
          ),
          label: Text(''),
        ),
      ],
    );
  }
} 