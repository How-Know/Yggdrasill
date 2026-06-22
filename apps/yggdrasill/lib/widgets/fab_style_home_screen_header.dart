import 'package:flutter/material.dart';

import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import 'home_header_weather_icon.dart';

/// 홈 상단 날씨·시간·통계 — 공용 메인 타이틀 토큰 + FAB 글래스 패널.
class FabStyleHomeScreenHeader extends StatelessWidget {
  const FabStyleHomeScreenHeader({
    super.key,
    required this.dateTimeText,
    this.statsText,
    this.gradingStats = false,
    this.showAnchorDateHint = false,
    this.trailing = const <Widget>[],
  });

  final String dateTimeText;
  final String? statsText;
  final bool gradingStats;
  final bool showAnchorDateHint;
  final List<Widget> trailing;

  Color _gradingStatsColor(Brightness brightness) {
    return brightness == Brightness.light
        ? const Color(0xFF1976D2)
        : const Color(0xFF8FB3FF);
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final style = PreviewAcademyPanelStyle.forBrightness(brightness);
    final dateStyle = FabTabBarTokens.previewAcademyMainTitleStyle(style);
    final statsStyle = FabTabBarTokens.previewAcademyLabelStyle(style).copyWith(
      fontWeight: FontWeight.w700,
      color: gradingStats ? _gradingStatsColor(brightness) : style.label,
    );
    final hintStyle = FabTabBarTokens.previewAcademyValueStyle(style).copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w600,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        FabStyleGlassPanel(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              HomeHeaderWeatherIcon(
                iconSize: 30,
                color: style.icon,
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    Text(
                      dateTimeText,
                      style: dateStyle,
                      textHeightBehavior: const TextHeightBehavior(
                        applyHeightToFirstAscent: false,
                        applyHeightToLastDescent: false,
                      ),
                    ),
                    if (statsText != null && statsText!.isNotEmpty)
                      Text(statsText!, style: statsStyle),
                    if (showAnchorDateHint)
                      Text('슬라이드시트 기준일', style: hintStyle),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (trailing.isNotEmpty) ...[
          const SizedBox(width: 8),
          ...trailing,
        ],
      ],
    );
  }
}
