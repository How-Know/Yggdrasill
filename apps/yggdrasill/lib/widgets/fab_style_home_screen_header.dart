import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import 'home_header_weather_icon.dart';

/// 홈 상단 날씨·시간·통계 — 공용 메인 타이틀 토큰 + FAB 글래스 패널.
class FabStyleHomeScreenHeader extends StatelessWidget {
  const FabStyleHomeScreenHeader({
    super.key,
    required this.dateTimeText,
    this.statsText,
    this.secondaryText,
    this.gradingStats = false,
    this.showAnchorDateHint = false,
    this.trailing = const <Widget>[],
  });

  final String dateTimeText;
  final String? statsText;
  final String? secondaryText;
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
    final titleLineHeight =
        FabTabBarTokens.previewAcademyMainTitleFontSize * 1.15;
    final hintStyle = FabTabBarTokens.previewAcademyValueStyle(style).copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w600,
    );
    final isGradingHeader = secondaryText != null;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        FabStyleGlassPanel(
          useTopButtonCapsuleBackground: true,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: isGradingHeader
              ? _buildGradingHeaderBody(
                  style: style,
                  dateStyle: dateStyle,
                  statsStyle: statsStyle,
                  titleLineHeight: titleLineHeight,
                  hintStyle: hintStyle,
                )
              : Row(
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

  static double _measureSingleLineTextWidth(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      textHeightBehavior: const TextHeightBehavior(
        applyHeightToFirstAscent: false,
        applyHeightToLastDescent: false,
      ),
    )..layout();
    return painter.width.ceilToDouble();
  }

  static double _gradingDateColumnWidth(
    TextStyle dateStyle, {
    required String dateTimeText,
    required String timeText,
  }) {
    return [
      _measureSingleLineTextWidth('00.00 (월)', dateStyle),
      _measureSingleLineTextWidth('23:59', dateStyle),
      _measureSingleLineTextWidth(dateTimeText, dateStyle),
      _measureSingleLineTextWidth(timeText, dateStyle),
    ].reduce(math.max);
  }

  static double _gradingStatsColumnWidth(TextStyle statsStyle) {
    return _measureSingleLineTextWidth('제출 99', statsStyle)
        .clamp(30.0, double.infinity);
  }

  Widget _buildGradingHeaderBody({
    required PreviewAcademyPanelStyle style,
    required TextStyle dateStyle,
    required TextStyle statsStyle,
    required double titleLineHeight,
    required TextStyle hintStyle,
  }) {
    const textHeightBehavior = TextHeightBehavior(
      applyHeightToFirstAscent: false,
      applyHeightToLastDescent: false,
    );
    final dateColumnWidth = _gradingDateColumnWidth(
      dateStyle,
      dateTimeText: dateTimeText,
      timeText: secondaryText!,
    );
    final leftColumnWidth = math.max(
      30.0,
      _gradingStatsColumnWidth(statsStyle),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: leftColumnWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: titleLineHeight,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: HomeHeaderWeatherIcon(
                        iconSize: 30,
                        color: style.icon,
                      ),
                    ),
                  ),
                  if (statsText != null && statsText!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    SizedBox(
                      height: titleLineHeight,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          statsText!,
                          style: statsStyle,
                          textHeightBehavior: textHeightBehavior,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: dateColumnWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: titleLineHeight,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        dateTimeText,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.fade,
                        style: dateStyle,
                        textHeightBehavior: textHeightBehavior,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: titleLineHeight,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        secondaryText!,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.fade,
                        style: dateStyle,
                        textAlign: TextAlign.right,
                        textHeightBehavior: textHeightBehavior,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (showAnchorDateHint) ...[
          const SizedBox(height: 4),
          Text('슬라이드시트 기준일', style: hintStyle),
        ],
      ],
    );
  }
}
