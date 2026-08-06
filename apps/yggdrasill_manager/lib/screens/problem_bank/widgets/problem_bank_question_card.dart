import 'package:flutter/material.dart';

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
