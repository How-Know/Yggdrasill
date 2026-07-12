import 'package:flutter/material.dart';

class TimetableTopBar extends StatelessWidget {
  final Widget? leading;
  final Widget actionRow;

  const TimetableTopBar({
    super.key,
    this.leading,
    required this.actionRow,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (leading != null) Expanded(child: leading!),
        actionRow,
      ],
    );
  }
}
