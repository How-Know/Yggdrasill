import 'package:flutter/material.dart';

class ProblemBankModeTabBar extends StatelessWidget {
  const ProblemBankModeTabBar({
    super.key,
    required this.controller,
    required this.panelColor,
    required this.borderColor,
    required this.textColor,
    required this.textSubColor,
    required this.accentColor,
  });

  final TabController controller;
  final Color panelColor;
  final Color borderColor;
  final Color textColor;
  final Color textSubColor;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: panelColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final selectedIndex = controller.index;
          return Row(
            children: [
              Expanded(
                child: _ModeTabButton(
                  label: '업로드',
                  icon: Icons.cloud_upload_outlined,
                  selected: selectedIndex == 0,
                  accentColor: accentColor,
                  textColor: textColor,
                  textSubColor: textSubColor,
                  onTap: () {
                    if (controller.index != 0) {
                      controller.animateTo(0);
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ModeTabButton(
                  label: '분류',
                  icon: Icons.grid_view_rounded,
                  selected: selectedIndex == 1,
                  accentColor: accentColor,
                  textColor: textColor,
                  textSubColor: textSubColor,
                  onTap: () {
                    if (controller.index != 1) {
                      controller.animateTo(1);
                    }
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ModeTabButton extends StatelessWidget {
  const _ModeTabButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.accentColor,
    required this.textColor,
    required this.textSubColor,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final Color accentColor;
  final Color textColor;
  final Color textSubColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        splashColor: Colors.transparent,
        highlightColor: accentColor.withValues(alpha: 0.12),
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected
                ? accentColor.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: selected
                ? Border.all(
                    color: accentColor.withValues(alpha: 0.28), width: 1)
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? accentColor : textSubColor,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: selected ? textColor : textSubColor,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
