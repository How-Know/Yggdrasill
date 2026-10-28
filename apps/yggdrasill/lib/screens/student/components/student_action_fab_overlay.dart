import 'dart:async';

import 'package:flutter/material.dart';

import '../../../widgets/corner_action_bar.dart';
import '../../../widgets/home_grading_edit_icon.dart';
import '../../../widgets/shared_dropdown_dialog.dart';
import '../../../widgets/student_detail_icons.dart';
import '../../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

const double _kFabIconSize = 25;
const double _kFabIconHitSize = 40;
const double _kFabIconOnlyHorizontalInset = 8;
const double _kFabIconOnlyPillWidth =
    _kFabIconOnlyHorizontalInset * 2 + _kFabIconSize;
const double _kCollapsedSearchTrailingGap = 12;
const double _kAddSearchGap = 12;

const int _kStudentMenuIndex = 1;

/// 학생 메뉴 하단 액션 FAB — 추가 + 검색. 유리 막대는 [SharedCornerActionBarHost].
class StudentActionFabOverlay {
  VoidCallback? _onAdd;
  VoidCallback? _onSearchToggle;
  VoidCallback? _onSearchCancel;
  bool _showDetailMenu = false;
  bool _detailPaused = false;
  Future<void> Function()? _onEditStudent;
  Future<void> Function()? _onTogglePause;
  Future<void> Function()? _onWithdrawStudent;
  bool _searchExpanded = false;
  bool _hasSearchQuery = false;
  TextEditingController? _searchController;
  ValueChanged<String>? _onSearchChanged;
  VoidCallback? _onSearchClear;
  FocusNode? _searchFocusNode;
  bool _disposed = false;
  bool _visible = true;

  void sync(
    BuildContext context, {
    required VoidCallback onAdd,
    required VoidCallback onSearchToggle,
    required VoidCallback onSearchCancel,
    bool showDetailMenu = false,
    bool detailPaused = false,
    Future<void> Function()? onEditStudent,
    Future<void> Function()? onTogglePause,
    Future<void> Function()? onWithdrawStudent,
    required bool searchExpanded,
    required bool hasSearchQuery,
    required TextEditingController searchController,
    required ValueChanged<String> onSearchChanged,
    required VoidCallback onSearchClear,
    FocusNode? searchFocusNode,
    bool visible = true,
  }) {
    if (_disposed) return;
    _onAdd = onAdd;
    _onSearchToggle = onSearchToggle;
    _onSearchCancel = onSearchCancel;
    _showDetailMenu = showDetailMenu;
    _detailPaused = detailPaused;
    _onEditStudent = onEditStudent;
    _onTogglePause = onTogglePause;
    _onWithdrawStudent = onWithdrawStudent;
    _searchExpanded = searchExpanded;
    _hasSearchQuery = hasSearchQuery;
    _searchController = searchController;
    _onSearchChanged = onSearchChanged;
    _onSearchClear = onSearchClear;
    _searchFocusNode = searchFocusNode;
    _visible = visible;

    sharedCornerActionBar.bind(
      menuIndex: _kStudentMenuIndex,
      width: _StudentActionFabBar.widthFor(
        searchExpanded: _searchExpanded,
        showDetailMenu: _showDetailMenu,
      ),
      visible: _visible,
      builder: _buildContent,
    );
  }

  void markNeedsBuild() {
    if (!_disposed) sharedCornerActionBar.refresh();
  }

  void dispose() {
    _disposed = true;
    sharedCornerActionBar.unbindMenu(_kStudentMenuIndex);
  }

  Widget _buildContent(BuildContext _) {
    return _StudentActionFabBar(
      searchExpanded: _searchExpanded,
      hasSearchQuery: _hasSearchQuery,
      controller: _searchController!,
      focusNode: _searchFocusNode,
      onAdd: _onAdd ?? () {},
      showDetailMenu: _showDetailMenu,
      detailPaused: _detailPaused,
      onEditStudent: _onEditStudent,
      onTogglePause: _onTogglePause,
      onWithdrawStudent: _onWithdrawStudent,
      onSearchToggle: _onSearchToggle ?? () {},
      onSearchCancel: _onSearchCancel ?? () {},
      onChanged: _onSearchChanged!,
      onClear: _onSearchClear!,
    );
  }
}

class _StudentActionFabBar extends StatelessWidget {
  const _StudentActionFabBar({
    required this.searchExpanded,
    required this.hasSearchQuery,
    required this.controller,
    required this.onAdd,
    required this.showDetailMenu,
    required this.detailPaused,
    required this.onEditStudent,
    required this.onTogglePause,
    required this.onWithdrawStudent,
    required this.onSearchToggle,
    required this.onSearchCancel,
    required this.onChanged,
    required this.onClear,
    this.focusNode,
  });

  static const double _expandedWidth = 285;
  // 추가(112) + 간격(12) + 검색(41) + 검색 오른쪽 여백(12) + 바 좌우 패딩(12).
  static const double _collapsedWidth = 189;
  // 위에 아이콘 버튼(41)을 추가와 검색 사이에 붙인 너비.
  static const double _collapsedWidthWithMenu = 230;
  static const double _searchExpandedLeftInset = 8;
  static const double _barHeight = SharedCornerActionBarHost.barHeight;
  static const double _barPadding = SharedCornerActionBarHost.barPadding;
  static const Duration _animDuration = SharedCornerActionBarHost.animDuration;

  final bool searchExpanded;
  final bool hasSearchQuery;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final VoidCallback onAdd;
  final bool showDetailMenu;
  final bool detailPaused;
  final Future<void> Function()? onEditStudent;
  final Future<void> Function()? onTogglePause;
  final Future<void> Function()? onWithdrawStudent;
  final VoidCallback onSearchToggle;
  final VoidCallback onSearchCancel;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  static double widthFor({
    required bool searchExpanded,
    required bool showDetailMenu,
  }) {
    if (searchExpanded) return _expandedWidth;
    return showDetailMenu ? _collapsedWidthWithMenu : _collapsedWidth;
  }

  @override
  Widget build(BuildContext context) {
    const innerHeight = _barHeight - _barPadding * 2;

    return Stack(
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
                  if (showDetailMenu)
                    _StudentDetailMenuButton(
                      detailPaused: detailPaused,
                      onEdit: onEditStudent,
                      onTogglePause: onTogglePause,
                      onWithdraw: onWithdrawStudent,
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
    );
  }
}

class _StudentDetailMenuButton extends StatelessWidget {
  const _StudentDetailMenuButton({
    required this.detailPaused,
    required this.onEdit,
    required this.onTogglePause,
    required this.onWithdraw,
    required this.barHeight,
    required this.barPadding,
  });

  final bool detailPaused;
  final Future<void> Function()? onEdit;
  final Future<void> Function()? onTogglePause;
  final Future<void> Function()? onWithdraw;
  final double barHeight;
  final double barPadding;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final style = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final hoverOverlay = brightness == Brightness.dark
        ? FabTabBarTokens.previewAcademyMenuGlassHoverOverlayDark
        : FabTabBarTokens.previewAcademyMenuGlassHoverOverlayLight;
    final enabled =
        onEdit != null && onTogglePause != null && onWithdraw != null;
    const danger = Color(0xFFE57373);

    Widget row({
      required String svg,
      required String label,
      required Color color,
      required Future<void> Function() action,
      required SharedDropdownDialogPanelController controller,
    }) {
      return SharedDropdownDialogMenuRow(
        selected: false,
        style: style,
        hoverOverlay: hoverOverlay,
        onTap: () {
          controller.close();
          unawaited(action());
        },
        child: Row(
          children: [
            StudentDetailIcon(svg, size: 20, color: color),
            const SizedBox(width: 10),
            Text(
              label,
              style: FabTabBarTokens.previewMenuItemTextStyle(style).copyWith(
                fontSize: SharedDropdownDialogPanel.contentFontSize,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      );
    }

    return SharedDropdownDialog(
      disabled: !enabled,
      panelMaxWidth: 280,
      alignPanelRightToCapsuleBar: true,
      openPanelAboveAnchor: true,
      panelRightExtraOffset: _kAddSearchGap +
          _kFabIconOnlyPillWidth +
          _kCollapsedSearchTrailingGap,
      panelBuilder: (context, controller) {
        return SharedDropdownDialogPanel(
          title: '',
          maxHeight: controller.maxHeight,
          onClose: controller.close,
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              row(
                svg: homeGradingEditOutlineSvg,
                label: '수정',
                color: style.title,
                action: onEdit!,
                controller: controller,
              ),
              row(
                svg:
                    detailPaused ? studentDetailPlaySvg : studentDetailPauseSvg,
                label: detailPaused ? '등원' : '휴원',
                color: style.title,
                action: onTogglePause!,
                controller: controller,
              ),
              row(
                svg: studentDetailLogoutSvg,
                label: '퇴원',
                color: danger,
                action: onWithdraw!,
                controller: controller,
              ),
            ],
          ),
        );
      },
      childBuilder: (context, controller) => FabStyleActionTabPill(
        icon: Icons.menu_rounded,
        label: '수정, 휴원, 퇴원',
        iconOnly: true,
        iconSize: _kFabIconSize,
        selected: controller.isOpen,
        enabled: enabled,
        onTap: enabled ? controller.toggle : () {},
        barHeight: barHeight,
        barPadding: barPadding,
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
