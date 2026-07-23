import 'dart:ui';

import 'package:flutter/material.dart';

/// 학습앱 `FabStyleTabBar` 글래스 토큰을 학생앱 하단 네비에 맞춘 값.
abstract final class StudentBottomNavTokens {
  static const double height = 64;
  static const double bottomInset = 20;
  static const double horizontalInset = 24;
  static const double padding = 6;
  static const double tabWidth = 72;
  static const double iconSize = 30;
  static const double blurDark = 28;
  static const double blurLight = 10;

  static const Color darkSurface = Color(0x80212121);
  static const Color darkHighlight = Color(0x9A383838);
  static const Color darkSelected = Color(0xFFF4F5F5);
  static const Color darkUnselected = Color(0xFF9AA0A0);

  static const Color lightSurface = Color(0x80FFFFFF);
  static const Color lightHighlight = Color(0xB8CFCFCF);
  static const Color lightSelected = Color(0xFF000000);
  static const Color lightUnselected = Color(0xFF6B6B6B);

  static const List<BoxShadow> lightShadows = [
    BoxShadow(
      color: Color(0x24000000),
      blurRadius: 4,
      offset: Offset(0, 2),
    ),
  ];

  /// 본문이 바에 가리지 않도록 확보할 하단 여백.
  static double contentBottomPadding(BuildContext context) {
    return height + bottomInset + MediaQuery.paddingOf(context).bottom;
  }

  static double blurFor(Brightness brightness) =>
      brightness == Brightness.light ? blurLight : blurDark;
}

class _StudentNavDestination {
  const _StudentNavDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// 하단 플로팅 글래스 네비게이션 바 (아이콘만, 선택 알약).
class StudentBottomNavBar extends StatelessWidget {
  const StudentBottomNavBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  static const destinations = <_StudentNavDestination>[
    _StudentNavDestination(
      label: '홈',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home_rounded,
    ),
    _StudentNavDestination(
      label: '교재 풀기',
      icon: Icons.edit_note_outlined,
      selectedIcon: Icons.edit_note_rounded,
    ),
    _StudentNavDestination(
      label: '내 정보',
      icon: Icons.person_outline_rounded,
      selectedIcon: Icons.person_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final surface = isDark
        ? StudentBottomNavTokens.darkSurface
        : StudentBottomNavTokens.lightSurface;
    final highlight = isDark
        ? StudentBottomNavTokens.darkHighlight
        : StudentBottomNavTokens.lightHighlight;
    final selectedColor = isDark
        ? StudentBottomNavTokens.darkSelected
        : StudentBottomNavTokens.lightSelected;
    final unselectedColor = isDark
        ? StudentBottomNavTokens.darkUnselected
        : StudentBottomNavTokens.lightUnselected;
    final blur = StudentBottomNavTokens.blurFor(brightness);
    const height = StudentBottomNavTokens.height;
    const padding = StudentBottomNavTokens.padding;
    const tabWidth = StudentBottomNavTokens.tabWidth;
    const radius = height / 2;
    const innerHeight = height - padding * 2;
    final safeIndex =
        selectedIndex.clamp(0, destinations.length - 1).toInt();
    final totalWidth = tabWidth * destinations.length;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: isDark ? null : StudentBottomNavTokens.lightShadows,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            height: height,
            padding: const EdgeInsets.all(padding),
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(radius),
              border: isDark
                  ? Border.all(color: const Color(0x1AFFFFFF), width: 0.5)
                  : null,
            ),
            child: SizedBox(
              width: totalWidth,
              child: Stack(
                children: [
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    left: tabWidth * safeIndex,
                    top: 0,
                    bottom: 0,
                    width: tabWidth,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: highlight,
                        borderRadius: BorderRadius.circular(innerHeight / 2),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < destinations.length; i++)
                        _NavTab(
                          width: tabWidth,
                          destination: destinations[i],
                          selected: i == safeIndex,
                          selectedColor: selectedColor,
                          unselectedColor: unselectedColor,
                          onTap: () => onDestinationSelected(i),
                        ),
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

class _NavTab extends StatelessWidget {
  const _NavTab({
    required this.width,
    required this.destination,
    required this.selected,
    required this.selectedColor,
    required this.unselectedColor,
    required this.onTap,
  });

  final double width;
  final _StudentNavDestination destination;
  final bool selected;
  final Color selectedColor;
  final Color unselectedColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? selectedColor : unselectedColor;
    return Tooltip(
      message: destination.label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: width,
          child: Center(
            child: Icon(
              selected ? destination.selectedIcon : destination.icon,
              size: StudentBottomNavTokens.iconSize,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}
