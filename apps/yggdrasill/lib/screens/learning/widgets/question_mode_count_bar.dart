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
  const QuestionModeCountBar({super.key, required this.counts});

  final QuestionModeCounts counts;

  @override
  Widget build(BuildContext context) {
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(
      Theme.of(context).brightness,
    );
    const fontSize = FabTabBarTokens.fabBarLabelFontSize;

    String countText(int current, int possible) {
      if (possible > current) return '$current ($possible)';
      return '$current';
    }

    Widget stat(String label, int current, int possible) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: panelStyle.hint,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.1,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            countText(current, possible),
            style: TextStyle(
              color: panelStyle.title,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.1,
            ),
          ),
        ],
      );
    }

    return FabStyleGlassPanel(
      useGroupedCardBackgroundInLight: true,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Row(
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
      ),
    );
  }
}
