import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

/// 문제은행 우측 상단 — 양식·출력 FAB와 펼침 패널.
class ProblemBankExportOptionsFab extends StatefulWidget {
  const ProblemBankExportOptionsFab({
    super.key,
    required this.panel,
    required this.isBusy,
  });

  final Widget panel;
  final bool isBusy;

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

    return Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.only(bottom: 8),
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
          FloatingActionButton.extended(
            heroTag: 'problem_bank_export_options_fab',
            elevation: 0,
            backgroundColor:
                _expanded ? const Color(0xFF1A6B5E) : const Color(0xE610171A),
            foregroundColor:
                _expanded ? const Color(0xFFEAF2F2) : const Color(0xFF9FB3B3),
            extendedPadding: const EdgeInsets.symmetric(horizontal: 14),
            onPressed: widget.isBusy
                ? null
                : () => setState(() => _expanded = !_expanded),
            icon: Icon(
              _expanded ? Icons.close_rounded : Icons.print_outlined,
              size: 18,
            ),
            label: Text(
              _expanded ? '닫기' : '양식·출력',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
