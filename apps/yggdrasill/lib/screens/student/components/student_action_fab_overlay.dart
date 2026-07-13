import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../app_overlays.dart';
import '../../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

const double _kFabIconSize = 25;
const double _kFabIconHitSize = 40;
const double _kCollapsedSearchTrailingGap = 12;
const double _kAddSearchGap = 12;

/// 학생 메뉴 하단 액션 FAB — 추가 + 검색 (시간메뉴와 동일 글래스 셸·위치 규칙).
class StudentActionFabOverlay {
  OverlayEntry? _entry;
  VoidCallback? _onAdd;
  VoidCallback? _onSearchToggle;
  VoidCallback? _onSearchCancel;
  bool _searchExpanded = false;
  bool _hasSearchQuery = false;
  TextEditingController? _searchController;
  ValueChanged<String>? _onSearchChanged;
  VoidCallback? _onSearchClear;
  FocusNode? _searchFocusNode;
  bool _syncScheduled = false;
  bool _disposed = false;
  bool _sideSheetWidthListening = false;
  bool _visible = true;

  void _onLeftSideSheetWidthChanged() {
    _entry?.markNeedsBuild();
  }

  void _ensureSideSheetWidthListener() {
    if (_sideSheetWidthListening) return;
    leftSideSheetClipWidthNotifier.addListener(_onLeftSideSheetWidthChanged);
    _sideSheetWidthListening = true;
  }

  void sync(
    BuildContext context, {
    required VoidCallback onAdd,
    required VoidCallback onSearchToggle,
    required VoidCallback onSearchCancel,
    required bool searchExpanded,
    required bool hasSearchQuery,
    required TextEditingController searchController,
    required ValueChanged<String> onSearchChanged,
    required VoidCallback onSearchClear,
    FocusNode? searchFocusNode,
    bool visible = true,
  }) {
    if (_disposed) return;
    _ensureSideSheetWidthListener();
    _onAdd = onAdd;
    _onSearchToggle = onSearchToggle;
    _onSearchCancel = onSearchCancel;
    _searchExpanded = searchExpanded;
    _hasSearchQuery = hasSearchQuery;
    _searchController = searchController;
    _onSearchChanged = onSearchChanged;
    _onSearchClear = onSearchClear;
    _searchFocusNode = searchFocusNode;
    _visible = visible;

    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (_disposed || !context.mounted) return;
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) return;

      if (!_visible) {
        _entry?.remove();
        _entry = null;
        return;
      }

      if (_entry == null) {
        _entry = OverlayEntry(builder: _buildOverlay);
        overlay.insert(_entry!);
      } else {
        _entry!.markNeedsBuild();
      }
    });
  }

  void markNeedsBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) _entry?.markNeedsBuild();
    });
  }

  void dispose() {
    _disposed = true;
    if (_sideSheetWidthListening) {
      leftSideSheetClipWidthNotifier
          .removeListener(_onLeftSideSheetWidthChanged);
      _sideSheetWidthListening = false;
    }
    _entry?.remove();
    _entry = null;
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final railWidth = NavigationRailTheme.of(overlayContext).minWidth ??
        FabTabBarTokens.fabBarNavRailDefaultWidth;
    final sideSheetWidth = leftSideSheetClipWidthNotifier.value;

    return Positioned(
      left: railWidth + sideSheetWidth,
      right: 0,
      bottom: FabTabBarTokens.fabBarBottomInset,
      child: Center(
        child: Material(
          type: MaterialType.transparency,
          color: Colors.transparent,
          child: _StudentActionFabBar(
            searchExpanded: _searchExpanded,
            hasSearchQuery: _hasSearchQuery,
            controller: _searchController!,
            focusNode: _searchFocusNode,
            onAdd: _onAdd ?? () {},
            onSearchToggle: _onSearchToggle ?? () {},
            onSearchCancel: _onSearchCancel ?? () {},
            onChanged: _onSearchChanged!,
            onClear: _onSearchClear!,
          ),
        ),
      ),
    );
  }
}

class _StudentActionFabBar extends StatelessWidget {
  const _StudentActionFabBar({
    required this.searchExpanded,
    required this.hasSearchQuery,
    required this.controller,
    required this.onAdd,
    required this.onSearchToggle,
    required this.onSearchCancel,
    required this.onChanged,
    required this.onClear,
    this.focusNode,
  });

  static const double _expandedWidth = 285;
  // 추가(~112) + 간격(12) + 검색(41) + 검색 오른쪽 여백(12) + 바 좌우 패딩(12).
  static const double _collapsedWidth = 189;
  static const double _searchExpandedLeftInset = 8;
  static const double _barHeight = FabTabBarTokens.fabBarHeight;
  static const double _barPadding = 6;
  static const Duration _animDuration = Duration(milliseconds: 340);

  final bool searchExpanded;
  final bool hasSearchQuery;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final VoidCallback onAdd;
  final VoidCallback onSearchToggle;
  final VoidCallback onSearchCancel;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final palette = FabTabBarTokens.paletteFor(brightness);
    final radius = BorderRadius.circular(_barHeight / 2);
    final innerHeight = _barHeight - _barPadding * 2;

    return DecoratedBox(
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
          child: AnimatedContainer(
            duration: _animDuration,
            curve: Curves.easeInOutCubic,
            width: searchExpanded ? _expandedWidth : _collapsedWidth,
            height: _barHeight,
            padding: const EdgeInsets.all(_barPadding),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: radius,
            ),
            child: ClipRect(
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  AnimatedOpacity(
                    opacity: searchExpanded ? 0 : 1,
                    duration: _animDuration,
                    curve: Curves.easeInOutCubic,
                    child: IgnorePointer(
                      ignoring: searchExpanded,
                      child: SizedBox(
                        height: innerHeight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FabStyleActionTabPill(
                              icon: Icons.add_rounded,
                              label: '추가',
                              onTap: onAdd,
                              barHeight: _barHeight,
                              barPadding: _barPadding,
                            ),
                            const SizedBox(width: _kAddSearchGap),
                            FabStyleActionTabPill(
                              icon: Icons.search_rounded,
                              label: '검색',
                              iconOnly: true,
                              iconSize: _kFabIconSize,
                              selected: hasSearchQuery,
                              onTap: onSearchToggle,
                              barHeight: _barHeight,
                              barPadding: _barPadding,
                            ),
                            const SizedBox(width: _kCollapsedSearchTrailingGap),
                          ],
                        ),
                      ),
                    ),
                  ),
                  AnimatedOpacity(
                    opacity: searchExpanded ? 1 : 0,
                    duration: _animDuration,
                    curve: Curves.easeInOutCubic,
                    child: IgnorePointer(
                      ignoring: !searchExpanded,
                      child: SizedBox(
                        width: _expandedWidth - _barPadding * 2,
                        height: innerHeight,
                        child: _InlineSearchRow(
                          controller: controller,
                          focusNode: focusNode,
                          hasText: hasSearchQuery,
                          onChanged: onChanged,
                          onClear: onClear,
                          onCancel: onSearchCancel,
                          barHeight: _barHeight,
                          barPadding: _barPadding,
                          leftInset: _searchExpandedLeftInset,
                        ),
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
}

class _InlineSearchRow extends StatelessWidget {
  const _InlineSearchRow({
    required this.controller,
    required this.onChanged,
    required this.onClear,
    required this.onCancel,
    required this.hasText,
    required this.barHeight,
    required this.barPadding,
    this.focusNode,
    this.leftInset = 0,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final VoidCallback onCancel;
  final bool hasText;
  final double barHeight;
  final double barPadding;
  final FocusNode? focusNode;
  final double leftInset;

  @override
  Widget build(BuildContext context) {
    final palette = FabTabBarTokens.paletteFor(Theme.of(context).brightness);
    final innerHeight = barHeight - barPadding * 2;

    return SizedBox(
      height: innerHeight,
      child: Padding(
        padding: EdgeInsets.only(left: leftInset),
        child: Row(
          children: [
            Icon(
              Icons.search_rounded,
              size: 20,
              color: palette.labelUnselected,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Material(
                type: MaterialType.transparency,
                color: Colors.transparent,
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  autofocus: true,
                  onChanged: onChanged,
                  style: TextStyle(
                    fontFamily: FabTabBarTokens.previewAcademyLabelFontFamily,
                    color: palette.labelSelected,
                    fontSize: FabTabBarTokens.fabBarLabelFontSize,
                    fontWeight: FontWeight.w500,
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    hintText: '검색',
                    hintStyle: TextStyle(
                      fontFamily: FabTabBarTokens.previewAcademyLabelFontFamily,
                      color: palette.labelUnselected.withValues(alpha: 0.7),
                      fontSize: FabTabBarTokens.fabBarLabelFontSize,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            if (hasText)
              _FabIconOnlyPill(
                icon: Icons.clear_rounded,
                iconSize: 18,
                hitSize: 32,
                tooltip: '지우기',
                onTap: onClear,
                barHeight: barHeight,
                barPadding: barPadding,
              )
            else
              _FabIconOnlyPill(
                icon: Icons.close_rounded,
                iconSize: 18,
                hitSize: 32,
                tooltip: '검색 닫기',
                onTap: onCancel,
                barHeight: barHeight,
                barPadding: barPadding,
              ),
          ],
        ),
      ),
    );
  }
}

class _FabIconOnlyPill extends StatelessWidget {
  const _FabIconOnlyPill({
    required this.icon,
    required this.onTap,
    this.selected = false,
    this.tooltip,
    this.iconSize = _kFabIconSize,
    this.hitSize = _kFabIconHitSize,
    this.barHeight = FabTabBarTokens.fabBarHeight,
    this.barPadding = 6,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool selected;
  final String? tooltip;
  final double iconSize;
  final double hitSize;
  final double barHeight;
  final double barPadding;

  @override
  Widget build(BuildContext context) {
    final palette = FabTabBarTokens.paletteFor(Theme.of(context).brightness);
    final innerHeight = barHeight - barPadding * 2;
    final fg = selected ? palette.labelSelected : palette.labelUnselected;
    final bg = selected ? palette.highlight : Colors.transparent;

    final pill = GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        width: hitSize,
        height: innerHeight,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(innerHeight / 2),
        ),
        child: Center(child: Icon(icon, size: iconSize, color: fg)),
      ),
    );

    if (tooltip == null || tooltip!.isEmpty) return pill;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 450),
      child: pill,
    );
  }
}
