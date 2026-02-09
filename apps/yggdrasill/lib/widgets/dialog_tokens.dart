import 'package:flutter/material.dart';

/// ✅ 신형 다이얼로그 톤(학생등록/수업시간/메모 다이얼로그와 통일)
const Color kDlgBg = Color(0xFF0B1112);
const Color kDlgPanelBg = Color(0xFF10171A);
const Color kDlgFieldBg = Color(0xFF15171C);
const Color kDlgBorder = Color(0xFF223131);
const Color kDlgText = Color(0xFFEAF2F2);
const Color kDlgTextSub = Color(0xFF9FB3B3);
const Color kDlgAccent = Color(0xFF33A373);

class YggDialogSectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  const YggDialogSectionHeader({
    super.key,
    required this.icon,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 2),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 16,
            decoration: BoxDecoration(
              color: kDlgAccent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Icon(icon, color: kDlgTextSub, size: 18),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              color: kDlgText,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class YggDialogFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;

  static const Color _chipSelected = Color(0xFF1B6B63);
  static const Color _chipBg = Color(0xFF2A2A2A);
  static const Color _chipText = Color(0xFFCDD5D5);

  const YggDialogFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => onSelected(!selected),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          height: 36,
          decoration: BoxDecoration(
            color: selected ? _chipSelected : _chipBg,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : _chipText,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

