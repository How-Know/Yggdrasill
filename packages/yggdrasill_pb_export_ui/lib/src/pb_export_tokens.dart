import 'package:flutter/material.dart';

const Color kDlgBg = Color(0xFF1C1C1E);
const Color kDlgPanelBg = Color(0xFF2C2C2E);

class FabTabBarTokens {
  const FabTabBarTokens._();

  static const double previewAcademyGroupedCardRadius = 28;
  static const Color previewConfirmActionColor = Color(0xFF33A373);
  static const double previewAcademyInputSheetRadius = 34;
  static const Color previewAcademyInfoPanelDark = Color(0xFF121212);
  static const Color previewAcademyInfoPanelLight = Color(0xFFF1F1F1);
  static const Color previewAcademyInputSheetFieldSurfaceDark = Color(
    0xFF2C2C2E,
  );
  static const Duration previewAcademyInputSheetTransitionDuration = Duration(
    milliseconds: 280,
  );

  static Color previewAcademyDialogGroupedFillColor(Brightness brightness) {
    return brightness == Brightness.dark
        ? previewAcademyInputSheetFieldSurfaceDark
        : Colors.white;
  }

  static PreviewAcademyPanelStyle previewAcademyPanelStyleFor(
    Brightness brightness,
  ) {
    return PreviewAcademyPanelStyle.forBrightness(brightness);
  }

  static Border groupedCardBorderFor(Brightness brightness) {
    return Border.all(
      color: brightness == Brightness.light
          ? const Color(0x12000000)
          : const Color(0x1AFFFFFF),
      width: 0.5,
      strokeAlign: BorderSide.strokeAlignInside,
    );
  }
}

@immutable
class PreviewAcademyPanelStyle {
  const PreviewAcademyPanelStyle({
    required this.title,
    required this.hint,
    required this.inputText,
    required this.label,
    required this.border,
    required this.dropdownBackground,
    required this.icon,
    required this.avatarPlaceholderBackground,
    required this.avatarPlaceholderIcon,
    required this.groupedCardBackground,
    required this.rowValue,
    required this.chevron,
    required this.divider,
    required this.changeButtonBackground,
    required this.changeButtonText,
  });

  final Color title;
  final Color hint;
  final Color inputText;
  final Color label;
  final Color border;
  final Color dropdownBackground;
  final Color icon;
  final Color avatarPlaceholderBackground;
  final Color avatarPlaceholderIcon;
  final Color groupedCardBackground;
  final Color rowValue;
  final Color chevron;
  final Color divider;
  final Color changeButtonBackground;
  final Color changeButtonText;

  factory PreviewAcademyPanelStyle.forBrightness(Brightness brightness) {
    if (brightness == Brightness.light) {
      return const PreviewAcademyPanelStyle(
        title: Color(0xFF000000),
        hint: Color(0xFF6B6B6B),
        inputText: Color(0xFF000000),
        label: Color(0xFF6B6B6B),
        border: Color(0x4D000000),
        dropdownBackground: Color(0xFFFFFFFF),
        icon: Color(0xFF6B6B6B),
        avatarPlaceholderBackground: Color(0xFFE0E0E0),
        avatarPlaceholderIcon: Color(0xFF9E9E9E),
        groupedCardBackground: FabTabBarTokens.previewAcademyInfoPanelLight,
        rowValue: Color(0xFF8E8E93),
        chevron: Color(0xFFC7C7CC),
        divider: Color(0xFFE5E5EA),
        changeButtonBackground: Color(0xFFEAF3FF),
        changeButtonText: FabTabBarTokens.previewConfirmActionColor,
      );
    }
    return const PreviewAcademyPanelStyle(
      title: Color(0xFFFFFFFF),
      hint: Color(0xB3FFFFFF),
      inputText: Color(0xFFFFFFFF),
      label: Color(0xB3FFFFFF),
      border: Color(0x4DFFFFFF),
      dropdownBackground: Color(0xFF1F1F1F),
      icon: Color(0xB3FFFFFF),
      avatarPlaceholderBackground: Color(0xFF424242),
      avatarPlaceholderIcon: Color(0x8AFFFFFF),
      groupedCardBackground: FabTabBarTokens.previewAcademyInfoPanelDark,
      rowValue: Color(0xFF8E8E93),
      chevron: Color(0xFF636366),
      divider: Color(0xFF38383A),
      changeButtonBackground: Color(0xFF2C2C2E),
      changeButtonText: FabTabBarTokens.previewConfirmActionColor,
    );
  }
}
