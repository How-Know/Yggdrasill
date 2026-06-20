import 'dart:ui';

import 'package:flutter/material.dart';

import '../../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

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

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final palette = FabTabBarTokens.paletteFor(brightness);
    final radius = BorderRadius.circular(FabTabBarTokens.fabBarHeight / 2);
    final disabled = isBusy;
    return Center(
      child: DecoratedBox(
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
                    _BottomActionPill(
                      onPressed: disabled ? null : onToggleSelectAll,
                      icon: allVisibleSelected
                          ? Icons.remove_done
                          : Icons.done_all,
                      label: allVisibleSelected ? '해제' : '전체',
                      selected: allVisibleSelected,
                    ),
                    _BottomActionPill(
                      onPressed: disabled ? null : onCreate,
                      icon: Icons.preview,
                      label: '만들기',
                    ),
                    _BottomActionPill(
                      onPressed: disabled ? null : onAddToCart,
                      icon: Icons.add_shopping_cart_outlined,
                      label: '추가',
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
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomActionPill extends StatelessWidget {
  const _BottomActionPill({
    required this.onPressed,
    required this.icon,
    required this.label,
    this.selected = false,
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final bool selected;

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
        width: 112,
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
                    const SizedBox(width: 7),
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: FabTabBarTokens.previewAcademyLabelFontFamily,
                        color: fg,
                        fontSize: FabTabBarTokens.fabBarLabelFontSize,
                        fontWeight: FontWeight.w600,
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
        width: 144,
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
                      '장바구니 $count',
                      style: TextStyle(
                        fontFamily: FabTabBarTokens.previewAcademyLabelFontFamily,
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
        width: 112,
        height: double.infinity,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(999),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_outline, size: 20, color: fg),
                  const SizedBox(width: 7),
                  Text(
                    '비우기',
                    style: TextStyle(
                      fontFamily: FabTabBarTokens.previewAcademyLabelFontFamily,
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
    );
  }
}

class ProblemBankFilterMenuButton extends StatefulWidget {
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

  @override
  State<ProblemBankFilterMenuButton> createState() =>
      _ProblemBankFilterMenuButtonState();
}

class _ProblemBankFilterMenuButtonState
    extends State<ProblemBankFilterMenuButton> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;

  bool get _isOpen => _overlayEntry != null;

  @override
  void didUpdateWidget(covariant ProblemBankFilterMenuButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_overlayEntry == null) return;
    if (oldWidget.filterActive == widget.filterActive &&
        _setEquals(oldWidget.selectedTypeFilters, widget.selectedTypeFilters) &&
        _setEquals(
          oldWidget.selectedDifficultyFilters,
          widget.selectedDifficultyFilters,
        ) &&
        oldWidget.typeFilterOptions == widget.typeFilterOptions &&
        oldWidget.difficultyFilterOptions == widget.difficultyFilterOptions) {
      return;
    }
    _scheduleOverlayRebuild();
  }

  bool _setEquals(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final value in a) {
      if (!b.contains(value)) return false;
    }
    return true;
  }

  void _scheduleOverlayRebuild() {
    if (_overlayEntry == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _overlayEntry == null) return;
      _overlayEntry!.markNeedsBuild();
    });
  }

  @override
  void dispose() {
    _removeOverlay();
    super.dispose();
  }

  void _toggleOverlay() {
    if (widget.disabled) return;
    if (_isOpen) {
      _removeOverlay();
      return;
    }
    _overlayEntry = _buildOverlayEntry();
    Overlay.of(context).insert(_overlayEntry!);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _removeOverlay() {
    final entry = _overlayEntry;
    if (entry == null) return;
    _overlayEntry = null;
    entry.remove();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  OverlayEntry _buildOverlayEntry() {
    return OverlayEntry(
      builder: (overlayContext) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _removeOverlay,
              ),
            ),
            CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomCenter,
              followerAnchor: Alignment.topCenter,
              offset: const Offset(0, 10),
              child: Material(
                color: Colors.transparent,
                child: _ProblemBankFilterPanel(
                  filterActive: widget.filterActive,
                  typeFilterOptions: widget.typeFilterOptions,
                  difficultyFilterOptions: widget.difficultyFilterOptions,
                  selectedTypeFilters: widget.selectedTypeFilters,
                  selectedDifficultyFilters: widget.selectedDifficultyFilters,
                  onToggleTypeFilter: widget.onToggleTypeFilter,
                  onToggleDifficultyFilter: widget.onToggleDifficultyFilter,
                  onClearFilters: widget.onClearFilters,
                  onClose: _removeOverlay,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final fg = widget.filterActive || _isOpen
        ? (isDark ? const Color(0xFFBEE7D2) : const Color(0xFF1A6B5E))
        : (isDark ? const Color(0xFF9FB3B3) : Colors.black);

    return CompositedTransformTarget(
      link: _layerLink,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _toggleOverlay,
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(Icons.filter_list_rounded, size: 25, color: fg),
          ),
        ),
      ),
    );
  }
}

class _ProblemBankFilterPanel extends StatelessWidget {
  const _ProblemBankFilterPanel({
    required this.filterActive,
    required this.typeFilterOptions,
    required this.difficultyFilterOptions,
    required this.selectedTypeFilters,
    required this.selectedDifficultyFilters,
    required this.onToggleTypeFilter,
    required this.onToggleDifficultyFilter,
    required this.onClearFilters,
    required this.onClose,
  });

  final bool filterActive;
  final List<String> typeFilterOptions;
  final List<String> difficultyFilterOptions;
  final Set<String> selectedTypeFilters;
  final Set<String> selectedDifficultyFilters;
  final ValueChanged<String> onToggleTypeFilter;
  final ValueChanged<String> onToggleDifficultyFilter;
  final VoidCallback onClearFilters;
  final VoidCallback onClose;

  static const Color _checkboxBorder = Color(0xFF5E7777);
  static const Color _checkboxActive = Color(0xFF1A6B5E);

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final panelColor = isDark ? const Color(0xFF111A1D) : Colors.white;
    final borderColor = isDark
        ? const Color(0xFF355056).withValues(alpha: 0.8)
        : Colors.black.withValues(alpha: 0.08);
    final titleColor =
        isDark ? const Color(0xFFEAF2F2) : const Color(0xFF111A1D);
    final sectionColor =
        isDark ? const Color(0xFFD6ECEA) : const Color(0xFF1F2A2D);
    final mutedColor =
        isDark ? const Color(0xFF8FAAAA) : const Color(0xFF5F6B70);
    final faintColor =
        isDark ? const Color(0xFF6F8585) : const Color(0xFF8A9499);
    final dividerColor =
        isDark ? const Color(0xFF2A3A3A) : const Color(0xFFE7ECEC);
    final resetColor = filterActive
        ? (isDark ? const Color(0xFFBEE7D2) : const Color(0xFF1A6B5E))
        : faintColor;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 420,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: panelColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.1),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '문항 필터',
                    style: TextStyle(
                      color: titleColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: filterActive ? onClearFilters : null,
                  style: TextButton.styleFrom(
                    foregroundColor: resetColor,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    '필터 초기화',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onClose,
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  color: mutedColor,
                  tooltip: '닫기',
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Divider(color: dividerColor, height: 1),
            const SizedBox(height: 10),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildFilterColumn(
                      title: '유형별',
                      emptyMessage: '유형 정보 없음',
                      options: typeFilterOptions,
                      selected: selectedTypeFilters,
                      onToggle: onToggleTypeFilter,
                      titleColor: sectionColor,
                      emptyColor: faintColor,
                      selectedTextColor: sectionColor,
                      textColor: mutedColor,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Container(
                    width: 1,
                    color: dividerColor,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _buildFilterColumn(
                      title: '난이도별',
                      emptyMessage: '난이도 정보 없음',
                      options: difficultyFilterOptions,
                      selected: selectedDifficultyFilters,
                      onToggle: onToggleDifficultyFilter,
                      titleColor: sectionColor,
                      emptyColor: faintColor,
                      selectedTextColor: sectionColor,
                      textColor: mutedColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterColumn({
    required String title,
    required String emptyMessage,
    required List<String> options,
    required Set<String> selected,
    required ValueChanged<String> onToggle,
    required Color titleColor,
    required Color emptyColor,
    required Color selectedTextColor,
    required Color textColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            color: titleColor,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        if (options.isEmpty)
          Text(
            emptyMessage,
            style: TextStyle(
              color: emptyColor,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          )
        else
          for (final option in options)
            _buildFilterCheckbox(
              label: option,
              checked: selected.contains(option),
              onChanged: () => onToggle(option),
              selectedTextColor: selectedTextColor,
              textColor: textColor,
            ),
      ],
    );
  }

  Widget _buildFilterCheckbox({
    required String label,
    required bool checked,
    required VoidCallback onChanged,
    required Color selectedTextColor,
    required Color textColor,
  }) {
    return InkWell(
      onTap: onChanged,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 38,
              height: 38,
              child: Checkbox(
                value: checked,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                side: const BorderSide(color: _checkboxBorder),
                activeColor: _checkboxActive,
                onChanged: (_) => onChanged(),
              ),
            ),
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: checked ? selectedTextColor : textColor,
                  fontSize: 12,
                  fontWeight: checked ? FontWeight.w800 : FontWeight.w700,
                  height: 1.25,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
