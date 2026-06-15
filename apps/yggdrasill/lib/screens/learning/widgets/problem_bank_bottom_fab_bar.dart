import 'dart:ui';

import 'package:flutter/material.dart';

class ProblemBankBottomFabBar extends StatelessWidget {
  const ProblemBankBottomFabBar({
    super.key,
    required this.cartCount,
    required this.cartActive,
    required this.allVisibleSelected,
    required this.filterActive,
    required this.isBusy,
    required this.typeFilterOptions,
    required this.difficultyFilterOptions,
    required this.selectedTypeFilters,
    required this.selectedDifficultyFilters,
    required this.onToggleSelectAll,
    required this.onToggleCart,
    required this.onClearCart,
    required this.onAddToCart,
    required this.onCreate,
    required this.onPreset,
    required this.onToggleTypeFilter,
    required this.onToggleDifficultyFilter,
    required this.onClearFilters,
  });

  final int cartCount;
  final bool cartActive;
  final bool allVisibleSelected;
  final bool filterActive;
  final bool isBusy;
  final List<String> typeFilterOptions;
  final List<String> difficultyFilterOptions;
  final Set<String> selectedTypeFilters;
  final Set<String> selectedDifficultyFilters;
  final VoidCallback onToggleSelectAll;
  final VoidCallback onToggleCart;
  final VoidCallback onClearCart;
  final VoidCallback onAddToCart;
  final VoidCallback onCreate;
  final VoidCallback onPreset;
  final ValueChanged<String> onToggleTypeFilter;
  final ValueChanged<String> onToggleDifficultyFilter;
  final VoidCallback onClearFilters;

  @override
  Widget build(BuildContext context) {
    final disabled = isBusy;
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF111A1D).withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: const Color(0xFF355056).withValues(alpha: 0.6),
              ),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _fab(
                    onPressed: disabled ? null : onToggleSelectAll,
                    icon:
                        allVisibleSelected ? Icons.remove_done : Icons.done_all,
                    label: allVisibleSelected ? '해제' : '전체',
                  ),
                  const SizedBox(width: 8),
                  _ProblemBankFilterMenuButton(
                    disabled: disabled,
                    filterActive: filterActive,
                    typeFilterOptions: typeFilterOptions,
                    difficultyFilterOptions: difficultyFilterOptions,
                    selectedTypeFilters: selectedTypeFilters,
                    selectedDifficultyFilters: selectedDifficultyFilters,
                    onToggleTypeFilter: onToggleTypeFilter,
                    onToggleDifficultyFilter: onToggleDifficultyFilter,
                    onClearFilters: onClearFilters,
                  ),
                  const SizedBox(width: 8),
                  _fab(
                    onPressed: disabled ? null : onCreate,
                    icon: Icons.preview,
                    label: '만들기',
                  ),
                  const SizedBox(width: 8),
                  _fab(
                    onPressed: disabled ? null : onAddToCart,
                    icon: Icons.add_shopping_cart_outlined,
                    label: '추가',
                  ),
                  const SizedBox(width: 8),
                  _fab(
                    onPressed: disabled ? null : onPreset,
                    icon: Icons.bookmark_outline,
                    label: '프리셋',
                  ),
                  const SizedBox(width: 10),
                  _selectionCartChip(
                    count: cartCount,
                    active: cartActive,
                    onTap: disabled ? null : onToggleCart,
                  ),
                  const SizedBox(width: 6),
                  _clearCartChip(
                    enabled: !disabled && cartCount > 0,
                    onTap: onClearCart,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 장바구니 개수 + 탭 시 장바구니 문항만 그리드에 표시 토글.
  static Widget _selectionCartChip({
    required int count,
    required bool active,
    required VoidCallback? onTap,
  }) {
    final borderColor = active
        ? const Color(0xFF2B6B61)
        : const Color(0xFF223131).withValues(alpha: 0.9);
    final fg = active ? const Color(0xFFBEE7D2) : const Color(0xFF9FB3B3);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: BoxDecoration(
            color: active ? const Color(0x66173C36) : const Color(0x9910171A),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.shopping_cart_outlined,
                size: 22,
                color: fg,
              ),
              const SizedBox(height: 2),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: fg,
                  height: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _clearCartChip({
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final fg = enabled ? const Color(0xFF9FB3B3) : const Color(0xFF536464);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(9, 6, 9, 6),
          decoration: BoxDecoration(
            color: const Color(0x9910171A),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF223131)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.delete_outline,
                size: 20,
                color: fg,
              ),
              const SizedBox(height: 2),
              Text(
                '비우기',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: fg,
                  height: 1,
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
      backgroundColor: backgroundColor ?? const Color(0xE610171A),
      foregroundColor: foregroundColor ?? const Color(0xFF9FB3B3),
      extendedPadding: const EdgeInsets.symmetric(horizontal: 14),
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

class _ProblemBankFilterMenuButton extends StatefulWidget {
  const _ProblemBankFilterMenuButton({
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
  State<_ProblemBankFilterMenuButton> createState() =>
      _ProblemBankFilterMenuButtonState();
}

class _ProblemBankFilterMenuButtonState
    extends State<_ProblemBankFilterMenuButton> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;

  bool get _isOpen => _overlayEntry != null;

  @override
  void didUpdateWidget(covariant _ProblemBankFilterMenuButton oldWidget) {
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
              targetAnchor: Alignment.topCenter,
              followerAnchor: Alignment.bottomCenter,
              offset: const Offset(0, -10),
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
    final fg = widget.filterActive || _isOpen
        ? const Color(0xFFBEE7D2)
        : const Color(0xFF9FB3B3);
    final bg = widget.filterActive || _isOpen
        ? const Color(0xE6173C36)
        : const Color(0xE610171A);

    return CompositedTransformTarget(
      link: _layerLink,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _toggleOverlay,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.filter_list, size: 18, color: fg),
                const SizedBox(width: 8),
                Text(
                  '필터',
                  style: TextStyle(
                    color: fg,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
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
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 420,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: const Color(0xFF111A1D),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xFF355056).withValues(alpha: 0.8),
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 18,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '문항 필터',
                    style: TextStyle(
                      color: Color(0xFFEAF2F2),
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: filterActive ? onClearFilters : null,
                  style: TextButton.styleFrom(
                    foregroundColor: filterActive
                        ? const Color(0xFFBEE7D2)
                        : const Color(0xFF7A8F8F),
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
                  color: const Color(0xFF9FB3B3),
                  tooltip: '닫기',
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const Divider(color: Color(0xFF2A3A3A), height: 1),
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
                    ),
                  ),
                  const SizedBox(width: 14),
                  Container(
                    width: 1,
                    color: const Color(0xFF2A3A3A),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _buildFilterColumn(
                      title: '난이도별',
                      emptyMessage: '난이도 정보 없음',
                      options: difficultyFilterOptions,
                      selected: selectedDifficultyFilters,
                      onToggle: onToggleDifficultyFilter,
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
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Color(0xFFD6ECEA),
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        if (options.isEmpty)
          Text(
            emptyMessage,
            style: const TextStyle(
              color: Color(0xFF6F8585),
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
            ),
      ],
    );
  }

  Widget _buildFilterCheckbox({
    required String label,
    required bool checked,
    required VoidCallback onChanged,
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
                  color: checked
                      ? const Color(0xFFD6ECEA)
                      : const Color(0xFF8FAAAA),
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
