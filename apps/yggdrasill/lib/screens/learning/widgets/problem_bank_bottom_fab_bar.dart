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
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFEFE8DC).withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0xFFD5C8B6)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x22000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
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
                foregroundColor: const Color(0xFF1B5E20),
                backgroundColor: const Color(0xFFE8F5E9),
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
                  color: const Color(0xFFF8F3EA),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(0xFFE1D4C3)),
                ),
                child: Text(
                  '선택 $selectedCount개',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF6B6256),
                  ),
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
      backgroundColor: backgroundColor ?? const Color(0xFFF8F3EA),
      foregroundColor: foregroundColor ?? const Color(0xFF5C5246),
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
