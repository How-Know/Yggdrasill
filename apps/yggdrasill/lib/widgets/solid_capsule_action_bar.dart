import 'package:flutter/material.dart';

import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

/// 불투명 알약형 상단 액션 버튼 모음 토큰.
///
/// 문제은행 우측 상단(양식·출력 / 필터) 등에서 쓰는 솔리드 캡슐 스타일.
class SolidCapsuleActionBarTokens {
  const SolidCapsuleActionBarTokens._();

  static const Color backgroundDark = Color(0xFF000000);
  static const Color backgroundLight = Color(0xFFFFFFFF);

  static Color background(Brightness brightness) =>
      brightness == Brightness.dark ? backgroundDark : backgroundLight;

  static Color border(Brightness brightness) => brightness == Brightness.dark
      ? Colors.white.withValues(alpha: 0.12)
      : Colors.black.withValues(alpha: 0.04);

  static List<BoxShadow> boxShadows(Brightness brightness) => [
        BoxShadow(
          color: Colors.black.withValues(
            alpha: brightness == Brightness.dark ? 0.22 : 0.08,
          ),
          blurRadius: 28,
          offset: const Offset(0, 12),
        ),
      ];

  static Color iconColor(
    Brightness brightness, {
    bool selected = false,
    bool accentWhenSelected = false,
  }) {
    if (brightness == Brightness.dark) {
      return FabTabBarTokens.paletteFor(brightness).labelSelected;
    }
    if (accentWhenSelected && selected) {
      return const Color(0xFF1A6B5E);
    }
    if (selected) {
      return const Color(0xFF111A1D);
    }
    return Colors.black;
  }
}

/// 불투명 알약 배경 위에 아이콘 버튼을 가로로 묶는 공용 셸.
class SolidCapsuleActionBar extends StatelessWidget {
  const SolidCapsuleActionBar({
    super.key,
    this.child,
    this.children,
    this.padding = SolidCapsuleActionBar.defaultPadding,
    this.itemSpacing = 22,
    this.borderRadius = 999,
  }) : assert(child != null || children != null);

  final Widget? child;
  final List<Widget>? children;
  final EdgeInsetsGeometry padding;
  final double itemSpacing;
  final double borderRadius;

  static const EdgeInsets defaultPadding =
      EdgeInsets.symmetric(horizontal: 14, vertical: 8);

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final radius = BorderRadius.circular(borderRadius);

    final Widget rowChild;
    if (children != null) {
      final items = <Widget>[];
      for (var i = 0; i < children!.length; i++) {
        if (i > 0) items.add(SizedBox(width: itemSpacing));
        items.add(children![i]);
      }
      rowChild = Row(mainAxisSize: MainAxisSize.min, children: items);
    } else {
      rowChild = child!;
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: SolidCapsuleActionBarTokens.boxShadows(brightness),
      ),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: SolidCapsuleActionBarTokens.background(brightness),
          borderRadius: radius,
          border: Border.all(color: SolidCapsuleActionBarTokens.border(brightness)),
        ),
        child: rowChild,
      ),
    );
  }
}

/// [SolidCapsuleActionBar] 내부 텍스트 버튼.
class SolidCapsuleTextActionButton extends StatelessWidget {
  const SolidCapsuleTextActionButton({
    super.key,
    this.tooltip,
    required this.label,
    this.onPressed,
    this.selected = false,
    this.horizontalPadding = 12,
  });

  final String? tooltip;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final fg = SolidCapsuleActionBarTokens.iconColor(
      brightness,
      selected: selected,
    );

    final button = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 10,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: FabTabBarTokens.previewAcademyLabelFontFamily,
              fontSize: FabTabBarTokens.fabBarLabelFontSize,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ),
      ),
    );

    if (tooltip == null || tooltip!.isEmpty) return button;
    return Tooltip(message: tooltip, child: button);
  }
}

/// [SolidCapsuleActionBar] 내부 아이콘 버튼.
class SolidCapsuleActionButton extends StatelessWidget {
  const SolidCapsuleActionButton({
    super.key,
    this.tooltip,
    required this.icon,
    this.onPressed,
    this.selected = false,
    this.accentWhenSelected = false,
    this.iconSize = 25,
    this.hitSize = 40,
  });

  final String? tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;
  final bool accentWhenSelected;
  final double iconSize;
  final double hitSize;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final fg = SolidCapsuleActionBarTokens.iconColor(
      brightness,
      selected: selected,
      accentWhenSelected: accentWhenSelected,
    );

    final button = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(999),
        child: SizedBox(
          width: hitSize,
          height: hitSize,
          child: Icon(icon, size: iconSize, color: fg),
        ),
      ),
    );

    if (tooltip == null || tooltip!.isEmpty) return button;
    return Tooltip(message: tooltip, child: button);
  }
}
