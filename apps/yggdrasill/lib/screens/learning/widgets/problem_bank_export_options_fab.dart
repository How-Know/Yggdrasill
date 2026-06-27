import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

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
    final palette = FabTabBarTokens.paletteFor(brightness);
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final isDark = brightness == Brightness.dark;
    final capsuleColor =
        isDark ? panelStyle.groupedCardBackground : palette.surface;
    final capsuleBorder = isDark
        ? FabTabBarTokens.groupedCardBorderFor(brightness)
        : Border.all(color: Colors.black.withValues(alpha: 0.04));
    final iconColor = palette.labelUnselected;
    final activeIconColor = palette.labelSelected;

    final capsule = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: capsuleColor,
        borderRadius: BorderRadius.circular(999),
        border: capsuleBorder,
        boxShadow: isDark
            ? const <BoxShadow>[]
            : FabTabBarTokens.fabBarLightBoxShadows,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TopIconButton(
            tooltip: _expanded ? '양식·출력 닫기' : '양식·출력',
            icon: _expanded ? Icons.close_rounded : Icons.print_outlined,
            color: _expanded ? activeIconColor : iconColor,
            onPressed:
                widget.isBusy ? null : () => setState(() => _expanded = !_expanded),
          ),
          if (widget.filterButton != null) ...[
            const SizedBox(width: 22),
            widget.filterButton!,
          ],
        ],
      ),
    );

    return Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: isDark
                ? capsule
                : BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: FabTabBarTokens.fabRelatedBlurSigmaFor(brightness),
                      sigmaY: FabTabBarTokens.fabRelatedBlurSigmaFor(brightness),
                    ),
                    child: capsule,
                  ),
          ),
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

class _TopIconButton extends StatelessWidget {
  const _TopIconButton({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 25, color: color),
          ),
        ),
      ),
    );
  }
}
