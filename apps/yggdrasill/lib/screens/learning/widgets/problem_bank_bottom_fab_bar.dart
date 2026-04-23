import 'dart:ui';

import 'package:flutter/material.dart';

class ProblemBankBottomFabBar extends StatelessWidget {
  const ProblemBankBottomFabBar({
    super.key,
    required this.selectedCount,
    required this.showOnlySelectedActive,
    required this.isBusy,
    required this.onSelectAll,
    required this.onClearSelection,
    required this.onToggleShowOnlySelected,
    required this.onPreview,
    required this.onCreatePlaceholder,
    required this.onPreset,
  });

  final int selectedCount;
  final bool showOnlySelectedActive;
  final bool isBusy;
  final VoidCallback onSelectAll;
  final VoidCallback onClearSelection;
  final VoidCallback onToggleShowOnlySelected;
  final VoidCallback onPreview;
  final VoidCallback onCreatePlaceholder;
  final VoidCallback onPreset;

  @override
  Widget build(BuildContext context) {
    final disabled = isBusy;
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF111A1D).withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: const Color(0xFF355056).withValues(alpha: 0.6),
              ),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _fab(
                    onPressed: disabled ? null : onSelectAll,
                    icon: Icons.done_all,
                    label: '전체',
                  ),
                  const SizedBox(width: 8),
                  _fab(
                    onPressed: disabled ? null : onClearSelection,
                    icon: Icons.remove_done,
                    label: '선택',
                  ),
                  const SizedBox(width: 8),
                  _fab(
                    onPressed: disabled ? null : onPreview,
                    icon: Icons.preview,
                    label: '미리보기',
                  ),
                  const SizedBox(width: 8),
                  _fab(
                    onPressed: disabled ? null : onCreatePlaceholder,
                    icon: Icons.auto_awesome,
                    label: '만들기',
                  ),
                  const SizedBox(width: 8),
                  _fab(
                    onPressed: disabled ? null : onPreset,
                    icon: Icons.bookmark_outline,
                    label: '프리셋',
                  ),
                  const SizedBox(width: 10),
                  _selectionCartChip(
                    count: selectedCount,
                    active: showOnlySelectedActive,
                    onTap: disabled ? null : onToggleShowOnlySelected,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 선택 개수 + 탭 시 선택 문항만 그리드에 표시 토글.
  static Widget _selectionCartChip({
    required int count,
    required bool active,
    required VoidCallback? onTap,
  }) {
    final borderColor = active
        ? const Color(0xFF2B6B61)
        : const Color(0xFF223131).withValues(alpha: 0.9);
    final fg = active
        ? const Color(0xFFBEE7D2)
        : const Color(0xFF9FB3B3);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: BoxDecoration(
            color: active
                ? const Color(0x66173C36)
                : const Color(0x9910171A),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.shopping_cart_outlined,
                size: 22,
                color: fg,
              ),
              const SizedBox(height: 2),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: fg,
                  height: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fab({
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
    Color? backgroundColor,
    Color? foregroundColor,
  }) {
    return FloatingActionButton.extended(
      heroTag: null,
      elevation: 0,
      backgroundColor: backgroundColor ?? const Color(0xE610171A),
      foregroundColor: foregroundColor ?? const Color(0xFF9FB3B3),
      extendedPadding: const EdgeInsets.symmetric(horizontal: 14),
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
