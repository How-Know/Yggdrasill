import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import 'home_header_weather_icon.dart';

/// ????? ??????????? ???? ?? ?????? ??? + FAB ???? ???.
class FabStyleHomeScreenHeader extends StatelessWidget {
  const FabStyleHomeScreenHeader({
    super.key,
    required this.dateTimeText,
    this.statsText,
    this.stats = const <HomeHeaderStat>[],
    this.secondaryText,
    this.gradingStats = false,
    this.showAnchorDateHint = false,
    this.trailing = const <Widget>[],
  });

  final String dateTimeText;
  final String? statsText;

  /// 등원 머리의 한 줄 요약. 비어 있으면 [statsText]를 쓴다.
  final List<HomeHeaderStat> stats;
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
    final hasStatusBody = stats.isNotEmpty ||
        (statsText != null && statsText!.isNotEmpty) ||
        showAnchorDateHint;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (isGradingHeader || hasStatusBody)
        FabStyleGlassPanel(
          useTopButtonCapsuleBackground: brightness == Brightness.light,
          useFabTabBarBackground: brightness == Brightness.dark,
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
                    if (stats.isNotEmpty)
                      _HomeHeaderStatStrip(stats: stats, style: style)
                    else if (statsText != null && statsText!.isNotEmpty)
                      Text(statsText!, style: statsStyle),
                    if ((stats.isNotEmpty ||
                            (statsText != null && statsText!.isNotEmpty)) &&
                        showAnchorDateHint)
                      const SizedBox(width: 12),
                    if (showAnchorDateHint)
                      Text(
                        '슬라이드시트 기준일',
                        style: hintStyle,
                      ),
                  ],
                ),
        ),
        if ((isGradingHeader || hasStatusBody) && trailing.isNotEmpty)
          const SizedBox(width: 8),
        if (trailing.isNotEmpty) ...trailing,
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
      _measureSingleLineTextWidth('00.00 (??', dateStyle),
      _measureSingleLineTextWidth('23:59', dateStyle),
      _measureSingleLineTextWidth(dateTimeText, dateStyle),
      _measureSingleLineTextWidth(timeText, dateStyle),
    ].reduce(math.max);
  }

  static double _gradingStatsColumnWidth(TextStyle statsStyle) {
    return _measureSingleLineTextWidth('??? 99', statsStyle)
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
                    height: 40,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: HomeHeaderWeatherIcon(
                        iconSize: 40,
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
            const SizedBox(width: 18),
            SizedBox(
              width: dateColumnWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: titleLineHeight,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        dateTimeText,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.clip,
                        textAlign: TextAlign.right,
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
                        overflow: TextOverflow.clip,
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
          Text(
            '\uC2AC\uB77C\uC774\uB4DC\uC2DC\uD2B8 \uAE30\uC900\uC77C',
            style: hintStyle,
          ),
        ],
      ],
    );
  }
}

/// 수업 현황 머리의 숫자 하나. 라벨과 숫자는 패널 색만 쓰고 항목마다 색을 바꾸지 않는다.
class HomeHeaderStat {
  const HomeHeaderStat({
    required this.label,
    required this.value,
    this.tooltip,
  });

  final String label;
  final int value;
  final String? tooltip;
}

class _HomeHeaderStatStrip extends StatelessWidget {
  const _HomeHeaderStatStrip({
    required this.stats,
    required this.style,
  });

  final List<HomeHeaderStat> stats;
  final PreviewAcademyPanelStyle style;

  @override
  Widget build(BuildContext context) {
    final labelStyle = TextStyle(
      fontFamily: FabTabBarTokens.previewAcademyLabelFontFamily,
      fontSize: 15,
      fontWeight: FontWeight.w500,
      height: 1.0,
      color: style.hint,
    );
    final valueStyle = TextStyle(
      fontFamily: FabTabBarTokens.previewAcademyLabelFontFamily,
      fontSize: 18,
      fontWeight: FontWeight.w700,
      height: 1.0,
      color: style.title,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final tick = style.hint.withValues(alpha: 0.28);

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < stats.length; i++) ...[
          if (i > 0) ...[
            const SizedBox(width: 18),
            Container(width: 1, height: 14, color: tick),
            const SizedBox(width: 18),
          ],
          _HomeHeaderStatItem(
            stat: stats[i],
            labelStyle: labelStyle,
            valueStyle: valueStyle,
          ),
        ],
      ],
    );
  }
}

class _HomeHeaderStatItem extends StatelessWidget {
  const _HomeHeaderStatItem({
    required this.stat,
    required this.labelStyle,
    required this.valueStyle,
  });

  final HomeHeaderStat stat;
  final TextStyle labelStyle;
  final TextStyle valueStyle;

  @override
  Widget build(BuildContext context) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(stat.label, style: labelStyle),
        const SizedBox(width: 6),
        Text('${stat.value}', style: valueStyle),
      ],
    );
    final tip = stat.tooltip;
    if (tip == null || tip.isEmpty) return row;
    return Tooltip(message: tip, child: row);
  }
}
