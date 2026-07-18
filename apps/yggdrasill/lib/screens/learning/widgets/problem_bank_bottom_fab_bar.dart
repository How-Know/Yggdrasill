import 'dart:ui';

import 'package:flutter/material.dart';

import '../../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../../../widgets/shared_dropdown_dialog.dart';
import '../../../widgets/solid_capsule_action_bar.dart';

class ProblemBankBottomFabBar extends StatelessWidget {
  const ProblemBankBottomFabBar({
    super.key,
    required this.cartCount,
    required this.cartActive,
    required this.allVisibleSelected,
    required this.isBusy,
    required this.onToggleSelectAll,
    required this.onToggleCart,
    required this.onClearCart,
    required this.onAddToCart,
    required this.onCreate,
    this.leading = const <Widget>[],
    this.alignStart = false,
    this.showSelectAll = true,
    this.showPrimaryActions = true,
  });

  final int cartCount;
  final bool cartActive;
  final bool allVisibleSelected;
  final bool isBusy;
  final VoidCallback onToggleSelectAll;
  final VoidCallback onToggleCart;
  final VoidCallback onClearCart;
  final VoidCallback onAddToCart;
  final VoidCallback onCreate;
  final List<Widget> leading;
  final bool alignStart;
  final bool showSelectAll;
  final bool showPrimaryActions;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final palette = FabTabBarTokens.paletteFor(brightness);
    final radius = BorderRadius.circular(FabTabBarTokens.fabBarHeight / 2);
    final disabled = isBusy;
    final bar = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: palette.boxShadows,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: FabTabBarTokens.fabRelatedBlurSigmaFor(brightness),
            sigmaY: FabTabBarTokens.fabRelatedBlurSigmaFor(brightness),
          ),
          child: Container(
            height: FabTabBarTokens.fabBarHeight,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: radius,
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...leading,
                  if (leading.isNotEmpty && showPrimaryActions)
                    const SizedBox(width: 4),
                  if (showPrimaryActions && showSelectAll)
                    _BottomActionPill(
                      onPressed: disabled ? null : onToggleSelectAll,
                      icon: allVisibleSelected
                          ? Icons.remove_done
                          : Icons.done_all,
                      label: allVisibleSelected ? '해제' : '전체',
                      selected: allVisibleSelected,
                    ),
                  if (showPrimaryActions) ...[
                    _BottomActionPill(
                      onPressed: disabled ? null : onCreate,
                      icon: Icons.preview,
                      label: '미리보기',
                    ),
                    _BottomActionPill(
                      onPressed: disabled ? null : onAddToCart,
                      icon: Icons.add,
                      label: '추가',
                      showLabel: false,
                    ),
                    _CartCountPill(
                      count: cartCount,
                      active: cartActive,
                      onTap: disabled ? null : onToggleCart,
                    ),
                    _ClearCartPill(
                      enabled: !disabled && cartCount > 0,
                      onTap: onClearCart,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (alignStart) {
      return Align(alignment: Alignment.centerLeft, child: bar);
    }
    return Center(child: bar);
  }
}

class _BottomActionPill extends StatelessWidget {
  const _BottomActionPill({
    required this.onPressed,
    required this.icon,
    required this.label,
    this.selected = false,
    this.showLabel = true,
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final bool selected;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final palette = FabTabBarTokens.paletteFor(brightness);
    final enabled = onPressed != null;
    final bg = selected ? palette.highlight : Colors.transparent;
    final fg = !enabled
        ? palette.labelUnselected.withValues(alpha: 0.45)
        : (selected ? palette.labelSelected : palette.labelUnselected);

    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 450),
      child: SizedBox(
        width: showLabel ? 112 : 52,
        height: double.infinity,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onPressed,
              borderRadius: BorderRadius.circular(999),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 20, color: fg),
                    if (showLabel) ...[
                      const SizedBox(width: 7),
                      Text(
                        label,
                        style: TextStyle(
                          fontFamily:
                              FabTabBarTokens.previewAcademyLabelFontFamily,
                          color: fg,
                          fontSize: FabTabBarTokens.fabBarLabelFontSize,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 장바구니 개수 + 탭 시 장바구니 문항만 그리드에 표시 토글.
class _CartCountPill extends StatelessWidget {
  const _CartCountPill({
    required this.count,
    required this.active,
    required this.onTap,
  });

  final int count;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final palette = FabTabBarTokens.paletteFor(brightness);
    final enabled = onTap != null;
    final fg = !enabled
        ? palette.labelUnselected.withValues(alpha: 0.45)
        : (active ? palette.labelSelected : palette.labelUnselected);

    return Tooltip(
      message: active ? '전체 문항 보기' : '장바구니 문항 보기',
      waitDuration: const Duration(milliseconds: 450),
      child: SizedBox(
        width: 76,
        height: double.infinity,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: active ? palette.highlight : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(999),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.shopping_cart_outlined, size: 20, color: fg),
                    const SizedBox(width: 7),
                    Text(
                      '$count',
                      style: TextStyle(
                        fontFamily:
                            FabTabBarTokens.previewAcademyLabelFontFamily,
                        fontSize: FabTabBarTokens.fabBarLabelFontSize,
                        fontWeight: FontWeight.w600,
                        color: fg,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ClearCartPill extends StatelessWidget {
  const _ClearCartPill({
    required this.enabled,
    required this.onTap,
  });

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = FabTabBarTokens.paletteFor(Theme.of(context).brightness);
    final fg = enabled
        ? palette.labelUnselected
        : palette.labelUnselected.withValues(alpha: 0.42);

    return Tooltip(
      message: '장바구니 비우기',
      waitDuration: const Duration(milliseconds: 450),
      child: SizedBox(
        width: 52,
        height: double.infinity,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(999),
            child: Center(
              child: Icon(Icons.delete_outline, size: 20, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}

class ProblemBankFilterMenuButton extends StatelessWidget {
  const ProblemBankFilterMenuButton({
    super.key,
    required this.disabled,
    required this.filterActive,
    required this.typeFilterOptions,
    required this.difficultyFilterOptions,
    required this.selectedTypeFilters,
    required this.selectedDifficultyFilters,
    required this.onToggleTypeFilter,
    required this.onToggleDifficultyFilter,
    required this.onClearFilters,
    this.panelRightExtraOffset = 0,
  });

  final bool disabled;
  final bool filterActive;
  final List<String> typeFilterOptions;
  final List<String> difficultyFilterOptions;
  final Set<String> selectedTypeFilters;
  final Set<String> selectedDifficultyFilters;
  final ValueChanged<String> onToggleTypeFilter;
  final ValueChanged<String> onToggleDifficultyFilter;
  final VoidCallback onClearFilters;
  final double panelRightExtraOffset;

  @override
  Widget build(BuildContext context) {
    return SharedDropdownDialog(
      disabled: disabled,
      alignPanelRightToCapsuleBar: true,
      panelRightExtraOffset: panelRightExtraOffset,
      panelBuilder: (context, controller) {
        final brightness = Theme.of(context).brightness;
        final isDark = brightness == Brightness.dark;
        final style = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
        final hoverOverlay = isDark
            ? FabTabBarTokens.previewAcademyMenuGlassHoverOverlayDark
            : FabTabBarTokens.previewAcademyMenuGlassHoverOverlayLight;

        return SharedDropdownDialogPanel(
          title: '문항 필터',
          maxHeight: controller.maxHeight,
          onClose: controller.close,
          onReset: onClearFilters,
          resetEnabled: filterActive,
          body: SharedDropdownDialogSplitBody(
            leading: SharedDropdownDialogSection(
              title: '유형별',
              style: style,
              hoverOverlay: hoverOverlay,
              emptyMessage: '유형 정보 없음',
              children: [
                for (final option in typeFilterOptions)
                  SharedDropdownDialogMenuRow(
                    selected: selectedTypeFilters.contains(option),
                    style: style,
                    hoverOverlay: hoverOverlay,
                    onTap: () => onToggleTypeFilter(option),
                    child: ProblemBankTypeFilterLabel(
                      typeKey: option,
                      style: style,
                    ),
                  ),
              ],
            ),
            trailing: SharedDropdownDialogSection(
              title: '난이도별',
              style: style,
              hoverOverlay: hoverOverlay,
              emptyMessage: '난이도 정보 없음',
              children: [
                for (final option in difficultyFilterOptions)
                  SharedDropdownDialogMenuRow(
                    selected: selectedDifficultyFilters.contains(option),
                    style: style,
                    hoverOverlay: hoverOverlay,
                    onTap: () => onToggleDifficultyFilter(option),
                    child: Text(
                      option,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: FabTabBarTokens.previewMenuItemTextStyle(style)
                          .copyWith(
                        fontSize: SharedDropdownDialogPanel.contentFontSize,
                        fontWeight: selectedDifficultyFilters.contains(option)
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
      childBuilder: (context, controller) => SolidCapsuleActionButton(
        tooltip: '출력 필터',
        icon: Icons.filter_list_rounded,
        selected: filterActive || controller.isOpen,
        accentWhenSelected: true,
        onPressed: disabled ? null : controller.toggle,
      ),
    );
  }
}

class ProblemBankTypeFilterLabel extends StatelessWidget {
  const ProblemBankTypeFilterLabel({
    super.key,
    required this.typeKey,
    required this.style,
  });

  final String typeKey;
  final PreviewAcademyPanelStyle style;

  ({String number, String name}) _parseTypeKey() {
    final parts = typeKey.split('|');
    final number = parts.isNotEmpty ? parts.first.trim() : '';
    final name = parts.length > 1 ? parts.sublist(1).join('|').trim() : '';
    if (number == '유형 미지정') {
      return (number: number, name: '');
    }
    return (number: number, name: name);
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _parseTypeKey();
    final numberStyle =
        FabTabBarTokens.previewMenuItemTextStyle(style).copyWith(
      fontSize: SharedDropdownDialogPanel.contentFontSize,
      fontWeight: FontWeight.w800,
      height: 1.2,
    );
    final nameStyle = FabTabBarTokens.previewMenuItemTextStyle(style).copyWith(
      fontSize: SharedDropdownDialogPanel.contentFontSize,
      fontWeight: FontWeight.w600,
      color: style.hint,
      height: 1.2,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          parsed.number,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: numberStyle,
        ),
        if (parsed.name.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            parsed.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: nameStyle,
          ),
        ],
      ],
    );
  }
}
