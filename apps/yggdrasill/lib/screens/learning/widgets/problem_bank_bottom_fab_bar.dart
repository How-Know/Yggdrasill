import 'dart:ui';

import 'package:flutter/material.dart';

class ProblemBankBottomFabBar extends StatelessWidget {
  const ProblemBankBottomFabBar({
    super.key,
    required this.selectedCount,
    required this.isBusy,
    required this.onSelectAll,
    required this.onClearSelection,
    required this.onPreview,
    required this.onGeneratePdf,
    required this.onCreatePlaceholder,
  });

  final int selectedCount;
  final bool isBusy;
  final VoidCallback onSelectAll;
  final VoidCallback onClearSelection;
  final VoidCallback onPreview;
  final VoidCallback onGeneratePdf;
  final VoidCallback onCreatePlaceholder;

  @override
  Widget build(BuildContext context) {
    final disabled = isBusy;
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                    label: '전체 선택',
                  ),
                  const SizedBox(width: 8),
                  _fab(
                    onPressed: disabled ? null : onClearSelection,
                    icon: Icons.remove_done,
                    label: '선택 해제',
                  ),
                  const SizedBox(width: 8),
                  _fab(
                    onPressed: disabled ? null : onPreview,
                    icon: Icons.preview,
                    label: '미리보기',
                  ),
                  const SizedBox(width: 8),
                  _fab(
                    onPressed: disabled ? null : onGeneratePdf,
                    icon: Icons.picture_as_pdf,
                    label: 'PDF 생성',
                    foregroundColor: const Color(0xFFC7F2D8),
                    backgroundColor: const Color(0xFF173C36),
                  ),
                  const SizedBox(width: 8),
                  _fab(
                    onPressed: disabled ? null : onCreatePlaceholder,
                    icon: Icons.auto_awesome,
                    label: '만들기',
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0x9910171A),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: const Color(0xFF223131).withValues(alpha: 0.9),
                      ),
                    ),
                    child: Text(
                      '선택 $selectedCount개',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF9FB3B3),
                      ),
                    ),
                  ),
                ],
              ),
            ),
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
