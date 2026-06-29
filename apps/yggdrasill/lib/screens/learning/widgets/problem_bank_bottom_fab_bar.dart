import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../../../widgets/solid_capsule_action_bar.dart';
import 'problem_bank_range_controls.dart';

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
    required this.visibleQuestionCount,
    required this.onToggleTypeFilter,
    required this.onToggleDifficultyFilter,
    required this.onClearFilters,
    required this.onRandomPick,
  });

  final bool disabled;
  final bool filterActive;
  final List<String> typeFilterOptions;
  final List<String> difficultyFilterOptions;
  final Set<String> selectedTypeFilters;
  final Set<String> selectedDifficultyFilters;
  final int visibleQuestionCount;
  final ValueChanged<String> onToggleTypeFilter;
  final ValueChanged<String> onToggleDifficultyFilter;
  final VoidCallback onClearFilters;
  final ValueChanged<int> onRandomPick;

  @override
  State<ProblemBankFilterMenuButton> createState() =>
      _ProblemBankFilterMenuButtonState();
}

class _ProblemBankFilterMenuButtonState
    extends State<ProblemBankFilterMenuButton> {
  final OverlayPortalController _overlayController = OverlayPortalController();

  bool get _isOpen => _overlayController.isShowing;

  void _toggleOverlay() {
    if (widget.disabled) return;
    if (_isOpen) {
      _overlayController.hide();
    } else {
      _overlayController.show();
    }
    setState(() {});
  }

  void _closeOverlay() {
    if (!_isOpen) return;
    _overlayController.hide();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _overlayController,
      overlayChildBuilder: (overlayContext, info) {
        final targetRect = MatrixUtils.transformRect(
          info.childPaintTransform,
          Offset.zero & info.childSize,
        );
        final overlaySize = info.overlaySize;
        final panelWidth = math.min(
          _ProblemBankFilterPanel.panelMaxWidth,
          overlaySize.width - 24,
        );
        final left = (targetRect.right - panelWidth)
            .clamp(12.0, overlaySize.width - panelWidth - 12);
        final top = targetRect.bottom +
            FabTabBarTokens.previewAcademyMenuTopOffsetFromArrow;
        final maxPanelHeight = math.min(
          overlaySize.height * 2 / 3,
          overlaySize.height - top - 16,
        );

        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _closeOverlay,
              ),
            ),
            Positioned(
              left: left,
              top: top,
              width: panelWidth,
              child: Material(
                color: Colors.transparent,
                child: _ProblemBankFilterPanel(
                  maxHeight: maxPanelHeight,
                  filterActive: widget.filterActive,
                  typeFilterOptions: widget.typeFilterOptions,
                  difficultyFilterOptions: widget.difficultyFilterOptions,
                  selectedTypeFilters: widget.selectedTypeFilters,
                  selectedDifficultyFilters: widget.selectedDifficultyFilters,
                  visibleQuestionCount: widget.visibleQuestionCount,
                  onToggleTypeFilter: widget.onToggleTypeFilter,
                  onToggleDifficultyFilter: widget.onToggleDifficultyFilter,
                  onClearFilters: widget.onClearFilters,
                  onRandomPick: widget.onRandomPick,
                  onClose: _closeOverlay,
                ),
              ),
            ),
          ],
        );
      },
      child: SolidCapsuleActionButton(
        tooltip: '출력 필터',
        icon: Icons.filter_list_rounded,
        selected: widget.filterActive || _isOpen,
        accentWhenSelected: true,
        onPressed: widget.disabled ? null : _toggleOverlay,
      ),
    );
  }
}

class _ProblemBankFilterPanel extends StatelessWidget {
  const _ProblemBankFilterPanel({
    required this.maxHeight,
    required this.filterActive,
    required this.typeFilterOptions,
    required this.difficultyFilterOptions,
    required this.selectedTypeFilters,
    required this.selectedDifficultyFilters,
    required this.visibleQuestionCount,
    required this.onToggleTypeFilter,
    required this.onToggleDifficultyFilter,
    required this.onClearFilters,
    required this.onRandomPick,
    required this.onClose,
  });

  static const double panelMaxWidth = 560;
  static const double _filterFontSize = 16;

  final double maxHeight;
  final bool filterActive;
  final List<String> typeFilterOptions;
  final List<String> difficultyFilterOptions;
  final Set<String> selectedTypeFilters;
  final Set<String> selectedDifficultyFilters;
  final int visibleQuestionCount;
  final ValueChanged<String> onToggleTypeFilter;
  final ValueChanged<String> onToggleDifficultyFilter;
  final VoidCallback onClearFilters;
  final ValueChanged<int> onRandomPick;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final style = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final palette = FabTabBarTokens.paletteFor(brightness);
    final glassTint = isDark
        ? FabTabBarTokens.previewAcademyMenuGlassTintDark
        : FabTabBarTokens.previewAcademyMenuGlassTintLight;
    final radius = BorderRadius.circular(
      FabTabBarTokens.previewAcademyMenuRadius,
    );
    final hoverOverlay = isDark
        ? FabTabBarTokens.previewAcademyMenuGlassHoverOverlayDark
        : FabTabBarTokens.previewAcademyMenuGlassHoverOverlayLight;
    final resetColor = filterActive
        ? FabTabBarTokens.previewConfirmActionColor
        : style.hint;
    const headerBlockHeight = 52.0;
    final bodyMaxHeight = math.max(0.0, maxHeight - headerBlockHeight);

    final panelContent = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '문항 필터',
                  style: FabTabBarTokens.previewMenuItemTextStyle(style)
                      .copyWith(
                    fontSize: _filterFontSize,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              TextButton(
                onPressed: filterActive ? onClearFilters : null,
                style: TextButton.styleFrom(
                  foregroundColor: resetColor,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  '초기화',
                  style: FabTabBarTokens.previewAcademyLabelStyle(style)
                      .copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: resetColor,
                  ),
                ),
              ),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onClose,
                  borderRadius: BorderRadius.circular(999),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.close_rounded,
                      size: 20,
                      color: style.icon,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Divider(color: style.divider, height: 1),
        Flexible(
          fit: FlexFit.loose,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: bodyMaxHeight),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 3,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: _buildTypeFilterColumn(
                      emptyMessage: '유형 정보 없음',
                      options: typeFilterOptions,
                      selected: selectedTypeFilters,
                      onToggle: onToggleTypeFilter,
                      style: style,
                      hoverOverlay: hoverOverlay,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Container(width: 1, color: style.divider),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: _buildRightFilterColumn(
                    difficultyOptions: difficultyFilterOptions,
                    selectedDifficultyFilters: selectedDifficultyFilters,
                    onToggleDifficultyFilter: onToggleDifficultyFilter,
                    visibleQuestionCount: visibleQuestionCount,
                    onRandomPick: onRandomPick,
                    style: style,
                    hoverOverlay: hoverOverlay,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Material(
        type: MaterialType.transparency,
        color: Colors.transparent,
        child: DefaultTextStyle(
          style: const TextStyle(
            decoration: TextDecoration.none,
            decorationColor: Colors.transparent,
          ),
          child: isDark
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    color: style.groupedCardBackground,
                    borderRadius: radius,
                    border: FabTabBarTokens.groupedCardBorderFor(brightness),
                  ),
                  child: panelContent,
                )
              : DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: const Color(0x40FFFFFF),
                      width: 0.5,
                    ),
                    boxShadow: palette.boxShadows,
                  ),
                  child: ClipRRect(
                    borderRadius: radius,
                    clipBehavior: Clip.antiAlias,
                    child: ColoredBox(
                      color: glassTint,
                      child: panelContent,
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildRightFilterColumn({
    required List<String> difficultyOptions,
    required Set<String> selectedDifficultyFilters,
    required ValueChanged<String> onToggleDifficultyFilter,
    required int visibleQuestionCount,
    required ValueChanged<int> onRandomPick,
    required PreviewAcademyPanelStyle style,
    required Color hoverOverlay,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 6, 4),
          child: Text(
            '난이도별',
            style: FabTabBarTokens.previewAcademyLabelStyle(style).copyWith(
              fontSize: _filterFontSize,
              fontWeight: FontWeight.w800,
              color: style.label,
            ),
          ),
        ),
        Expanded(
          child: difficultyOptions.isEmpty
              ? Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  child: Text(
                    '난이도 정보 없음',
                    style: FabTabBarTokens.previewBodyTextStyle(
                      style,
                      color: style.hint,
                      fontWeight: FontWeight.w600,
                    ).copyWith(fontSize: _filterFontSize),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final option in difficultyOptions)
                        _ProblemBankFilterMenuRow(
                          selected:
                              selectedDifficultyFilters.contains(option),
                          style: style,
                          hoverOverlay: hoverOverlay,
                          onTap: () => onToggleDifficultyFilter(option),
                          child: Text(
                            option,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: FabTabBarTokens.previewMenuItemTextStyle(
                              style,
                            ).copyWith(
                              fontSize: _filterFontSize,
                              fontWeight:
                                  selectedDifficultyFilters.contains(option)
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
        Divider(color: style.divider, height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
          child: _ProblemBankRandomPickSection(
            visibleQuestionCount: visibleQuestionCount,
            style: style,
            onPick: onRandomPick,
          ),
        ),
      ],
    );
  }

  Widget _buildTypeFilterColumn({
    required String emptyMessage,
    required List<String> options,
    required Set<String> selected,
    required ValueChanged<String> onToggle,
    required PreviewAcademyPanelStyle style,
    required Color hoverOverlay,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 6, 4),
          child: Text(
            '유형별',
            style: FabTabBarTokens.previewAcademyLabelStyle(style).copyWith(
              fontSize: _filterFontSize,
              fontWeight: FontWeight.w800,
              color: style.label,
            ),
          ),
        ),
        if (options.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Text(
              emptyMessage,
              style: FabTabBarTokens.previewBodyTextStyle(
                style,
                color: style.hint,
                fontWeight: FontWeight.w600,
              ).copyWith(fontSize: _filterFontSize),
            ),
          )
        else
          for (final option in options)
            _ProblemBankFilterMenuRow(
              selected: selected.contains(option),
              style: style,
              hoverOverlay: hoverOverlay,
              onTap: () => onToggle(option),
              child: _ProblemBankTypeFilterLabel(
                typeKey: option,
                style: style,
              ),
            ),
      ],
    );
  }
}

class _ProblemBankTypeFilterLabel extends StatelessWidget {
  const _ProblemBankTypeFilterLabel({
    required this.typeKey,
    required this.style,
  });

  final String typeKey;
  final PreviewAcademyPanelStyle style;

  ({String number, String name}) _parseTypeKey() {
    final parts = typeKey.split('|');
    final number = parts.isNotEmpty ? parts.first.trim() : '';
    final name =
        parts.length > 1 ? parts.sublist(1).join('|').trim() : '';
    if (number == '유형 미지정') {
      return (number: number, name: '');
    }
    return (number: number, name: name);
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _parseTypeKey();
    final numberStyle = FabTabBarTokens.previewMenuItemTextStyle(style).copyWith(
      fontSize: _ProblemBankFilterPanel._filterFontSize,
      fontWeight: FontWeight.w800,
      height: 1.2,
    );
    final nameStyle = FabTabBarTokens.previewMenuItemTextStyle(style).copyWith(
      fontSize: _ProblemBankFilterPanel._filterFontSize,
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

class _ProblemBankFilterMenuRow extends StatefulWidget {
  const _ProblemBankFilterMenuRow({
    required this.selected,
    required this.style,
    required this.hoverOverlay,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final PreviewAcademyPanelStyle style;
  final Color hoverOverlay;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_ProblemBankFilterMenuRow> createState() =>
      _ProblemBankFilterMenuRowState();
}

class _ProblemBankFilterMenuRowState extends State<_ProblemBankFilterMenuRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: ColoredBox(
          color: _hovered ? widget.hoverOverlay : Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 24,
                  child: widget.selected
                      ? Icon(
                          Icons.check_rounded,
                          size: _ProblemBankFilterPanel._filterFontSize,
                          color: widget.style.title,
                        )
                      : null,
                ),
                Expanded(child: widget.child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProblemBankRandomPickSection extends StatefulWidget {
  const _ProblemBankRandomPickSection({
    required this.visibleQuestionCount,
    required this.style,
    required this.onPick,
  });

  final int visibleQuestionCount;
  final PreviewAcademyPanelStyle style;
  final ValueChanged<int> onPick;

  @override
  State<_ProblemBankRandomPickSection> createState() =>
      _ProblemBankRandomPickSectionState();
}

class _ProblemBankRandomPickSectionState
    extends State<_ProblemBankRandomPickSection> {
  final TextEditingController _countController = TextEditingController();

  @override
  void dispose() {
    _countController.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = int.tryParse(_countController.text.trim());
    if (parsed == null || parsed <= 0) return;
    if (widget.visibleQuestionCount <= 0) return;
    widget.onPick(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final canPick = widget.visibleQuestionCount > 0;
    final hintColor = widget.style.hint;
    final brightness = Theme.of(context).brightness;
    final fieldDecoration = BoxDecoration(
      color: widget.style.dropdownBackground,
      borderRadius: BorderRadius.circular(10),
      border: FabTabBarTokens.groupedCardBorderFor(brightness),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '랜덤 선택',
            style: FabTabBarTokens.previewAcademyLabelStyle(widget.style)
                .copyWith(
              fontSize: _ProblemBankFilterPanel._filterFontSize,
              fontWeight: FontWeight.w800,
              color: widget.style.label,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            canPick
                ? '현재 화면 ${widget.visibleQuestionCount}문항 중'
                : '선택 가능한 문항이 없습니다',
            style: FabTabBarTokens.previewBodyTextStyle(
              widget.style,
              color: hintColor,
              fontWeight: FontWeight.w600,
            ).copyWith(fontSize: _ProblemBankFilterPanel._filterFontSize),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 88),
                  child: SizedBox(
                    height: problemBankRangeControlHeight,
                    child: DecoratedBox(
                      decoration: fieldDecoration,
                      child: TextField(
                        controller: _countController,
                        enabled: canPick,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: FabTabBarTokens.previewBodyTextStyle(
                          widget.style,
                          fontWeight: FontWeight.w600,
                        ).copyWith(
                          fontSize: _ProblemBankFilterPanel._filterFontSize,
                        ),
                        decoration: InputDecoration(
                          hintText: '개수',
                          hintStyle: TextStyle(
                            color: hintColor,
                            fontSize: _ProblemBankFilterPanel._filterFontSize,
                            fontWeight: FontWeight.w600,
                          ),
                          isDense: true,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 10,
                          ),
                        ),
                        onSubmitted: canPick ? (_) => _submit() : null,
                      ),
                    ),
                  ),
                ),
              ),
              const Spacer(),
              SizedBox(
                height: problemBankRangeControlHeight,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: canPick ? _submit : null,
                    borderRadius: BorderRadius.circular(10),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: canPick
                            ? FabTabBarTokens.previewConfirmActionColor
                            : widget.style.dropdownBackground,
                        borderRadius: BorderRadius.circular(10),
                        border: FabTabBarTokens.groupedCardBorderFor(brightness),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Center(
                          child: Text(
                            '뽑기',
                            style: TextStyle(
                              fontFamily: FabTabBarTokens
                                  .previewAcademyLabelFontFamily,
                              color: canPick ? Colors.white : hintColor,
                              fontSize: _ProblemBankFilterPanel._filterFontSize,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
