import 'package:flutter/material.dart';

import '../../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

/// 체크된 문항의 출제 유형 수. 가능 수가 현재보다 크면 `현재 (가능)`.
class QuestionModeCounts {
  const QuestionModeCounts({
    required this.objective,
    required this.objectivePossible,
    required this.subjective,
    required this.subjectivePossible,
    required this.essay,
    required this.essayPossible,
    required this.total,
    required this.totalPossible,
  });

  final int objective;
  final int objectivePossible;
  final int subjective;
  final int subjectivePossible;
  final int essay;
  final int essayPossible;
  final int total;
  final int totalPossible;
}

/// 문제은행·교재 탐색 상단의 객관식·주관식·서술형·총 집계.
class QuestionModeCountBar extends StatelessWidget {
  const QuestionModeCountBar({
    super.key,
    required this.counts,
    this.height,
  });

  final QuestionModeCounts counts;

  /// 비우면 글자 높이에 위아래 여백 12를 더한다.
  /// 높이를 주면 미리보기 버튼 막대와 같은 유리·글자를 쓴다.
  final double? height;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final palette = FabTabBarTokens.paletteFor(brightness);
    final previewBar = height != null;
    const fontSize = FabTabBarTokens.fabBarLabelFontSize;
    final labelColor =
        previewBar ? palette.labelUnselected : panelStyle.hint;
    final countColor = previewBar ? palette.labelSelected : panelStyle.title;

    String countText(int current, int possible) {
      if (possible > current) return '$current ($possible)';
      return '$current';
    }

    TextStyle statStyle(Color color) {
      return TextStyle(
        fontFamily: previewBar
            ? FabTabBarTokens.previewAcademyLabelFontFamily
            : null,
        color: color,
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        letterSpacing: previewBar ? 0 : -0.1,
        decoration: TextDecoration.none,
        decorationColor: Colors.transparent,
      );
    }

    Widget stat(String label, int current, int possible) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: statStyle(labelColor)),
          const SizedBox(width: 6),
          Text(countText(current, possible), style: statStyle(countColor)),
        ],
      );
    }

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        stat('객관식', counts.objective, counts.objectivePossible),
        const SizedBox(width: 18),
        stat('주관식', counts.subjective, counts.subjectivePossible),
        const SizedBox(width: 18),
        stat('서술형', counts.essay, counts.essayPossible),
        const SizedBox(width: 18),
        stat('총', counts.total, counts.totalPossible),
      ],
    );
    final barHeight = height;
    return Material(
      type: MaterialType.transparency,
      child: DefaultTextStyle(
        style: const TextStyle(decoration: TextDecoration.none),
        child: FabStyleGlassPanel(
          useGroupedCardBackgroundInLight: !previewBar,
          useFabTabBarBackground: previewBar,
          padding: EdgeInsets.symmetric(
            horizontal: 18,
            vertical: barHeight == null ? 12 : 0,
          ),
          child: barHeight == null
              ? row
              : SizedBox(
                  height: barHeight,
                  child: row,
                ),
        ),
      ),
    );
  }
}
