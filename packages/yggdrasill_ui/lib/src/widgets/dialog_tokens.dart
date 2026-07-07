import 'package:flutter/material.dart';

/// 목업 다이얼로그 톤.
///
/// 학원 탭 공통 입력 다이얼로그와 동일하게
/// - 바깥 시트: #1C1C1E
/// - 내부 입력/패널: #2C2C2E
/// 를 기준으로 둔다.
///
/// 원본: apps/yggdrasill/lib/widgets/dialog_tokens.dart (시범 공유 추출)
const Color kDlgBg = Color(0xFF1C1C1E);
const Color kDlgPanelBg = Color(0xFF2C2C2E);
const Color kDlgFieldBg = Color(0xFF2C2C2E);
const Color kDlgBorder = Color(0xFF38383A);
const Color kDlgText = Color(0xFFEAF2F2);
const Color kDlgTextSub = Color(0xFF9FB3B3);
const Color kDlgAccent = Color(0xFF33A373);

/// 다이얼로그·글래스 시트용 밝기별 색상.
class YggDialogColors {
  const YggDialogColors({
    required this.bg,
    required this.panelBg,
    required this.fieldBg,
    required this.border,
    required this.text,
    required this.textSub,
    required this.glassTint,
    required this.glassBorder,
    required this.headerText,
    required this.closeIcon,
    required this.divider,
    required this.cardBg,
    required this.cardBorder,
    required this.chipBg,
    required this.chipText,
    required this.chipSelected,
    required this.groupChildTitle,
    required this.hint,
  });

  final Color bg;
  final Color panelBg;
  final Color fieldBg;
  final Color border;
  final Color text;
  final Color textSub;
  final Color glassTint;
  final Color glassBorder;
  final Color headerText;
  final Color closeIcon;
  final Color divider;
  final Color cardBg;
  final Color cardBorder;
  final Color chipBg;
  final Color chipText;
  final Color chipSelected;
  final Color groupChildTitle;
  final Color hint;

  factory YggDialogColors.forBrightness(Brightness brightness) {
    if (brightness == Brightness.light) {
      return const YggDialogColors(
        bg: Color(0xFFF2F2F7),
        panelBg: Color(0xFFECECEF),
        fieldBg: Color(0xFFFFFFFF),
        border: Color(0xFFE5E5EA),
        text: Color(0xFF000000),
        textSub: Color(0xFF6B6B6B),
        glassTint: Color(0xE6FFFFFF),
        glassBorder: Color(0x4D000000),
        headerText: Color(0xFF000000),
        closeIcon: Color(0xFF6B6B6B),
        divider: Color(0xFFE5E5EA),
        cardBg: Color(0x0F000000),
        cardBorder: Color(0x1A000000),
        chipBg: Color(0xFFF2F2F7),
        chipText: Color(0xFF6B6B6B),
        chipSelected: Color(0xFF1B6B63),
        groupChildTitle: Color(0xFF3C3C43),
        hint: Color(0xFF8E8E93),
      );
    }
    return const YggDialogColors(
      bg: kDlgBg,
      panelBg: kDlgPanelBg,
      fieldBg: kDlgFieldBg,
      border: kDlgBorder,
      text: kDlgText,
      textSub: kDlgTextSub,
      glassTint: Color(0xB31C1C1E),
      glassBorder: Color(0x33FFFFFF),
      headerText: Color(0xFFF5F5F7),
      closeIcon: Color(0xFFE3E3E6),
      divider: Color(0x22FFFFFF),
      cardBg: Color(0x332C2C2E),
      cardBorder: Color(0x22FFFFFF),
      chipBg: Color(0xFF2A2A2A),
      chipText: Color(0xFFCDD5D5),
      chipSelected: Color(0xFF1B6B63),
      groupChildTitle: Color(0xFFB9C3BA),
      hint: Color(0xFF6E7E7E),
    );
  }

  static YggDialogColors of(BuildContext context) =>
      YggDialogColors.forBrightness(Theme.of(context).brightness);
}

/// 학습·학원 앱 공통 로딩 스피너 (초록 accent).
class YggLoadingIndicator extends StatelessWidget {
  const YggLoadingIndicator({
    super.key,
    this.size = 22,
    double? strokeWidth,
  }) : strokeWidth = strokeWidth ?? (size <= 18 ? 2.0 : 2.6);

  final double size;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        strokeWidth: strokeWidth,
        color: kDlgAccent,
      ),
    );
  }
}

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
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kDlgText,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
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
  final double? labelFontSize;
  final double? height;

  static const Color _chipSelected = Color(0xFF1B6B63);

  const YggDialogFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.labelFontSize,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    final chipHeight = height ?? 36.0;
    final radius = chipHeight / 2;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: () => onSelected(!selected),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: EdgeInsets.symmetric(
            horizontal: 14,
            vertical: height != null ? 0 : 8,
          ),
          height: chipHeight,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? _chipSelected : dlg.chipBg,
            borderRadius: BorderRadius.circular(radius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : dlg.chipText,
                  fontWeight: FontWeight.w600,
                  fontSize: labelFontSize ?? 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
