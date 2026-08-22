import 'package:flutter/material.dart';

import '../problem_bank_models.dart';

class ProblemBankQuestionCard extends StatelessWidget {
  const ProblemBankQuestionCard({
    required this.child,
    required this.backgroundColor,
    required this.borderColor,
    super.key,
  });

  final Widget child;
  final Color backgroundColor;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor),
        ),
        child: child,
      ),
    );
  }
}

class ProblemBankTimedTestStatsFooter extends StatelessWidget {
  const ProblemBankTimedTestStatsFooter({
    required this.stats,
    this.color,
    super.key,
  });

  final ProblemBankQuestionTimedTestStats stats;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Text(
        stats.displayLabel,
        key: const ValueKey<String>('timed-test-stats-label'),
        textAlign: TextAlign.right,
        style: TextStyle(
          color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 10.8,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
