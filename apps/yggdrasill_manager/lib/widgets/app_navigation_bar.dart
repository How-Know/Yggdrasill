import 'package:flutter/material.dart';

import '../theme/manager_shell_colors.dart';
import 'manager_nav_icons.dart';

const Color kNavAccent = Color(0xFF33A373); // Yggdrasill 시그니처 초록

class AppNavigationBar extends StatelessWidget {
  final int selectedIndex;
  final Function(int) onDestinationSelected;
  final VoidCallback onLogout;

  const AppNavigationBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      color: ManagerShellColors.surfaceBase,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Yggdrasill',
                  style: TextStyle(
                    color: ManagerShellColors.navIcon,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  '관리자',
                  style: TextStyle(
                    color: ManagerShellColors.navSubtitle,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: ManagerShellColors.navDivider, height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                _NavigationItem(
                  svg: managerNavIdeaSvg,
                  label: '개념',
                  isSelected: selectedIndex == 0,
                  onTap: () => onDestinationSelected(0),
                ),
                _NavigationItem(
                  svg: managerNavCalculatorSvg,
                  label: '연산',
                  isSelected: selectedIndex == 1,
                  onTap: () => onDestinationSelected(1),
                ),
                _NavigationItem(
                  svg: managerNavMedalSvg,
                  label: '스킬',
                  isSelected: selectedIndex == 2,
                  onTap: () => onDestinationSelected(2),
                ),
                _NavigationItem(
                  svg: managerNavJourneySvg,
                  label: '문항로드맵',
                  isSelected: selectedIndex == 3,
                  onTap: () => onDestinationSelected(3),
                ),
                _NavigationItem(
                  svg: managerNavCloudStorageSvg,
                  label: '문제은행',
                  isSelected: selectedIndex == 4,
                  onTap: () => onDestinationSelected(4),
                ),
                _NavigationItem(
                  svg: managerNavSurveySvg,
                  label: '성향조사',
                  isSelected: selectedIndex == 5,
                  onTap: () => onDestinationSelected(5),
                ),
                _NavigationItem(
                  svg: managerNavOpenBookSvg,
                  label: '교재',
                  isSelected: selectedIndex == 6,
                  onTap: () => onDestinationSelected(6),
                ),
                _NavigationItem(
                  svg: managerNavChatSvg,
                  label: 'Think',
                  isSelected: selectedIndex == 7,
                  onTap: () => onDestinationSelected(7),
                ),
                _NavigationItem(
                  svg: managerNavSettingsSvg,
                  label: '설정',
                  isSelected: selectedIndex == 8,
                  onTap: () => onDestinationSelected(8),
                ),
              ],
            ),
          ),
          const Divider(color: ManagerShellColors.navDivider, height: 1),
          _NavigationItem(
            svg: managerNavLogoutSvg,
            label: '로그아웃',
            isSelected: false,
            onTap: onLogout,
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _NavigationItem extends StatelessWidget {
  final String svg;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _NavigationItem({
    required this.svg,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isSelected
        ? ManagerShellColors.navIconSelected
        : ManagerShellColors.navIcon;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(26),
          splashColor: Colors.transparent,
          highlightColor: ManagerShellColors.navHighlight,
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: isSelected
                  ? ManagerShellColors.navHighlight
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(26),
            ),
            child: Row(
              children: [
                ManagerNavIcon(svg, color: color),
                const SizedBox(width: 14),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 16,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
