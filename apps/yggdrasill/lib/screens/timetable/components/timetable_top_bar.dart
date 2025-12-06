import 'package:flutter/material.dart';

import '../../../widgets/custom_tab_bar.dart';

class TimetableTopBar extends StatelessWidget {
  final Widget registerControls;
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;
  final Widget actionRow;

  const TimetableTopBar({
    super.key,
    required this.registerControls,
    required this.selectedIndex,
    required this.onTabSelected,
    required this.actionRow,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 1,
          child: Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: registerControls,
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: Center(
            child: CustomTabBar(
              selectedIndex: selectedIndex,
              tabs: const ['수업', '일정'],
              onTabSelected: onTabSelected,
            ),
          ),
        ),
        Expanded(
          flex: 1,
          child: Align(
            alignment: Alignment.centerRight,
            child: actionRow,
          ),
        ),
      ],
    );
  }
}

