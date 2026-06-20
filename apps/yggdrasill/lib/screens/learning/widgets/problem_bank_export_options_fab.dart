import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

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
    final isDark = brightness == Brightness.dark;
    final capsuleColor =
        isDark ? const Color(0xE610171A) : Colors.white.withValues(alpha: 0.92);
    final borderColor = isDark
        ? const Color(0xFF355056).withValues(alpha: 0.62)
        : Colors.black.withValues(alpha: 0.04);
    final iconColor = isDark ? const Color(0xFF9FB3B3) : Colors.black;
    final activeIconColor =
        isDark ? const Color(0xFFEAF2F2) : const Color(0xFF111A1D);

    return Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: capsuleColor,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: borderColor),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.22 : 0.08,
                      ),
                      blurRadius: 28,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _TopIconButton(
                      tooltip: _expanded ? '양식·출력 닫기' : '양식·출력',
                      icon: _expanded
                          ? Icons.close_rounded
                          : Icons.print_outlined,
                      color: _expanded ? activeIconColor : iconColor,
                      onPressed: widget.isBusy
                          ? null
                          : () => setState(() => _expanded = !_expanded),
                    ),
                    if (widget.filterButton != null) ...[
                      const SizedBox(width: 22),
                      widget.filterButton!,
                    ],
                  ],
                ),
              ),
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
                borderRadius: BorderRadius.circular(14),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
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
