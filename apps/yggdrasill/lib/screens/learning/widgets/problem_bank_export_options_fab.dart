import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../widgets/solid_capsule_action_bar.dart';
import '../../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

/// 문제은행 우측 상단 — 양식·출력 FAB와 펼침 패널.
class ProblemBankExportOptionsFab extends StatefulWidget {
  const ProblemBankExportOptionsFab({
    super.key,
    required this.panel,
    required this.isBusy,
    this.filterButton,
  });

  final Widget panel;
  final bool isBusy;
  final Widget? filterButton;

  @override
  State<ProblemBankExportOptionsFab> createState() =>
      _ProblemBankExportOptionsFabState();
}

class _ProblemBankExportOptionsFabState
    extends State<ProblemBankExportOptionsFab> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final panelMaxWidth = math.min(920.0, screen.width - 48);
    final panelMaxHeight = math.min(520.0, screen.height * 0.58);
    final brightness = Theme.of(context).brightness;

    final actions = <Widget>[
      SolidCapsuleActionButton(
        tooltip: _expanded ? '양식·출력 닫기' : '양식·출력',
        icon: _expanded ? Icons.close_rounded : Icons.print_outlined,
        selected: _expanded,
        onPressed: widget.isBusy
            ? null
            : () => setState(() => _expanded = !_expanded),
      ),
      if (widget.filterButton != null) widget.filterButton!,
    ];

    return Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          SolidCapsuleActionBar(children: actions),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(
                  FabTabBarTokens.previewAcademyMenuRadius,
                ),
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: FabTabBarTokens.fabRelatedBlurSigmaFor(brightness),
                    sigmaY: FabTabBarTokens.fabRelatedBlurSigmaFor(brightness),
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: panelMaxWidth,
                      maxHeight: panelMaxHeight,
                    ),
                    child: SingleChildScrollView(
                      child: widget.panel,
                    ),
                  ),
                ),
              ),
            ),
            sizeCurve: Curves.easeOutCubic,
          ),
        ],
      ),
    );
  }
}
