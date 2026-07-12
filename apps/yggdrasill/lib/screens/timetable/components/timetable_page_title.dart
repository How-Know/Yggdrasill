import 'package:flutter/material.dart';

import '../../../models/academic_season.dart';
import '../../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

/// 시간 메뉴 상단 좌측 페이지 타이틀 (시즌 라벨 + 월 라벨).
class TimetablePageTitle extends StatelessWidget {
  const TimetablePageTitle({
    super.key,
    required this.selectedDate,
    this.showSeasonLabel = true,
    this.onSeasonPressed,
  });

  final DateTime selectedDate;
  final bool showSeasonLabel;
  final VoidCallback? onSeasonPressed;

  @override
  Widget build(BuildContext context) {
    final season = AcademicSeason.fromDate(selectedDate);
    final style = FabTabBarTokens.previewAcademyPanelStyleFor(
      Theme.of(context).brightness,
    );
    final titleStyle = FabTabBarTokens.previewAcademyMainTitleStyle(style);

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (showSeasonLabel) ...[
          _TimetableSeasonTitle(
            season: season,
            style: titleStyle,
            onPressed: onSeasonPressed,
          ),
          const SizedBox(width: 12),
        ],
        Text(
          '${selectedDate.month}월',
          style: titleStyle,
        ),
      ],
    );
  }
}

class _TimetableSeasonTitle extends StatelessWidget {
  const _TimetableSeasonTitle({
    required this.season,
    required this.style,
    this.onPressed,
  });

  final AcademicSeason season;
  final TextStyle style;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final label = Text(season.shortLabel, style: style);

    if (onPressed == null) return label;

    return Tooltip(
      message: '${season.displayName}\n시즌 로드맵 열기',
      waitDuration: const Duration(milliseconds: 200),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          hoverColor: Colors.white.withValues(alpha: 0.06),
          highlightColor: Colors.white.withValues(alpha: 0.04),
          splashColor: Colors.white.withValues(alpha: 0.10),
          mouseCursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: label,
          ),
        ),
      ),
    );
  }
}
