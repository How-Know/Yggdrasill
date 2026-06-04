import 'package:flutter/material.dart';

import '../../../../theme/ygg_semantic_colors.dart';
import '../../../../widgets/navigation_rail.dart';
import '../../../settings/settings_screen.dart';

/// 프로덕션 [SettingsScreen]을 메인 셸(좌측 NavRail)과 함께 표시하는 Preview.
///
/// 레이아웃 미세 조정 시 본앱과 동일한 좌측 여백·폭을 맞추기 위함.
class SettingsBaselinePreviewScreen extends StatefulWidget {
  const SettingsBaselinePreviewScreen({super.key});

  @override
  State<SettingsBaselinePreviewScreen> createState() =>
      _SettingsBaselinePreviewScreenState();
}

class _SettingsBaselinePreviewScreenState
    extends State<SettingsBaselinePreviewScreen>
    with SingleTickerProviderStateMixin {
  static const int _settingsRailIndex = 5;

  late final AnimationController _menuRotation;

  @override
  void initState() {
    super.initState();
    _menuRotation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 0,
    );
  }

  @override
  void dispose() {
    _menuRotation.dispose();
    super.dispose();
  }

  void _previewSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        backgroundColor: const Color(0xFF2A2A2A),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        navigationRailTheme: const NavigationRailThemeData(
          minWidth: 84,
          groupAlignment: -1,
          useIndicator: true,
        ),
      ),
      child: Scaffold(
        backgroundColor: context.yggSurfaceBase,
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CustomNavigationRail(
              selectedIndex: _settingsRailIndex,
              onDestinationSelected: (_) {
                _previewSnack('Preview: 설정 화면만 표시됩니다.');
              },
              rotationAnimation: _menuRotation,
              onMenuPressed: () {
                _previewSnack('Preview: 사이드 시트는 포함하지 않습니다.');
              },
            ),
            const Expanded(
              child: SettingsScreen(
                previewUseFabStyleTabBar: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
