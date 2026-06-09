import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'app_bar_title.dart'; // for AccountButton
import '../theme/ygg_semantic_colors.dart';

const double _navIconSize = 26.0;
const Color _navIconColorDark = Color(0xFFEAF2F2);
const Color _navIconColorLight = Color(0xFF1F2933);

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
    final navBackground =
        context.yggSurfaceBase;
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color navIconColor =
        isDark ? _navIconColorDark : _navIconColorLight;
    // 선택 인디케이터/구분선도 모드에 맞춰 대비를 확보한다.
    final Color indicatorColor =
        isDark ? const Color(0xFF223131) : const Color(0xFFE2E8E8);
    final Color dividerColor =
        isDark ? Colors.white24 : Colors.black26;
    // Row 안에서는 가로 제약이 무한대(Infinity)로 들어올 수 있어서,
    // 하단 영역에서 width: double.infinity 를 쓰면 레이아웃이 깨질 수 있다.
    // (navigationRailTheme.minWidth와 동일한 폭으로 고정)
    final double railWidth = NavigationRailTheme.of(context).minWidth ?? 84.0;
    return Column(
      children: [
        Expanded(
          child: NavigationRail(
            backgroundColor: navBackground,
            unselectedIconTheme:
                IconThemeData(color: navIconColor, size: _navIconSize),
            selectedIconTheme:
                IconThemeData(color: navIconColor, size: _navIconSize),
            indicatorColor: indicatorColor,
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
                        return Transform.rotate(
                          angle: rotationAnimation.value * (math.pi / 2),
                          child: Icon(
                            Symbols.package_2,
                            color: navIconColor,
                            size: 36,
                          ),
                        );
                      },
                    ),
                    onPressed: onMenuPressed,
                  ),
                  const SizedBox(height: 12),
                  Container(width: 32, height: 1, color: dividerColor),
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
                  child: Icon(
                    Symbols.home_rounded,
                    weight: 700,
                    size: _navIconSize,
                  ),
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
                  child: Icon(
                    Symbols.person_rounded,
                    weight: 700,
                    size: _navIconSize,
                  ),
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
                  child: Icon(
                    Symbols.timer_rounded,
                    weight: 700,
                    size: _navIconSize,
                  ),
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
                  child: Icon(
                    Symbols.network_intel_node,
                    weight: 700,
                    size: _navIconSize,
                  ),
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
                  child: Icon(
                    Symbols.auto_stories,
                    weight: 700,
                    size: _navIconSize,
                  ),
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
                  child: Icon(
                    Symbols.settings,
                    weight: 700,
                    size: _navIconSize,
                  ),
                ),
                label: Text(''),
              ),
            ],
          ),
        ),
        // 하단 계정(로그인) 버튼 영역 배경을 상단 네비게이션 바와 동일하게 맞춤
        // - 네비게이션바(레일) 배경색과 동일하게 맞춤: 0xFF0B1112
        SizedBox(
          width: railWidth,
          child: ColoredBox(
            color: navBackground,
            child: Align(
              alignment: Alignment.center,
              child: AccountButton(
                padding: const EdgeInsets.only(bottom: 16.0, top: 8.0),
                radius: 20,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
