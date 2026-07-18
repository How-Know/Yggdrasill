import 'package:flutter/material.dart';

import '../../../widgets/shared_dropdown_dialog.dart';
import '../../../widgets/solid_capsule_action_bar.dart';

/// 문제은행·교재 탐색 우측 상단 — 양식·출력(공용 드롭다운) + 필터 버튼.
class ProblemBankExportOptionsFab extends StatelessWidget {
  const ProblemBankExportOptionsFab({
    super.key,
    required this.panel,
    required this.isBusy,
    this.filterButton,
    this.questionOptionsButton,
    this.selectionButton,
    this.panelMaxWidth = 920,
  });

  final Widget panel;
  final bool isBusy;
  final Widget? filterButton;
  final Widget? questionOptionsButton;
  final Widget? selectionButton;
  final double panelMaxWidth;

  static const double _barItemSpacing = 22;
  static const double _barButtonHitSize = 40;

  @override
  Widget build(BuildContext context) {
    final hasFilter = filterButton != null;
    final hasQuestionOptions = questionOptionsButton != null;
    final hasSelection = selectionButton != null;
    final siblingOffset =
        (hasFilter ? _barItemSpacing + _barButtonHitSize : 0.0) +
            (hasQuestionOptions ? _barItemSpacing + _barButtonHitSize : 0.0) +
            (hasSelection ? _barItemSpacing + 52 : 0.0);

    return Material(
      color: Colors.transparent,
      child: SolidCapsuleActionBar(
        children: [
          SharedDropdownDialog(
            disabled: isBusy,
            panelMaxWidth: panelMaxWidth,
            maxHeightScreenFraction: 0.58,
            alignPanelRightToCapsuleBar: true,
            panelRightExtraOffset: siblingOffset,
            panelBuilder: (context, controller) => SharedDropdownDialogPanel(
              title: '양식 및 출력',
              maxHeight: controller.maxHeight,
              onClose: controller.close,
              body: SingleChildScrollView(
                padding: SharedDropdownDialogPanel.bodyPadding,
                child: panel,
              ),
            ),
            childBuilder: (context, controller) => SolidCapsuleActionButton(
              tooltip: controller.isOpen ? '양식·출력 닫기' : '양식·출력',
              icon: Icons.print_outlined,
              selected: controller.isOpen,
              onPressed: isBusy ? null : controller.toggle,
            ),
          ),
          if (filterButton != null) filterButton!,
          if (questionOptionsButton != null) questionOptionsButton!,
          if (selectionButton != null) selectionButton!,
        ],
      ),
    );
  }
}
