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
                  _filterButton(disabled: disabled),
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

  Widget _filterButton({required bool disabled}) {
    final fg = filterActive ? const Color(0xFFBEE7D2) : const Color(0xFF9FB3B3);
    return PopupMenuButton<String>(
      enabled: !disabled,
      tooltip: '필터',
      offset: const Offset(0, -260),
      color: const Color(0xFF111A1D),
      elevation: 12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: const Color(0xFF355056).withValues(alpha: 0.8)),
      ),
      onSelected: (value) {
        if (value == '__clear') {
          onClearFilters();
        } else if (value.startsWith('type|')) {
          onToggleTypeFilter(value.substring(5));
        } else if (value.startsWith('difficulty|')) {
          onToggleDifficultyFilter(value.substring(11));
        }
      },
      itemBuilder: (context) {
        final items = <PopupMenuEntry<String>>[
          const PopupMenuItem<String>(
            enabled: false,
            child: Text(
              '문항 필터',
              style: TextStyle(
                color: Color(0xFFEAF2F2),
                fontSize: 13,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          PopupMenuItem<String>(
            value: '__clear',
            child: Text(
              '필터 초기화',
              style: TextStyle(
                color: filterActive
                    ? const Color(0xFFBEE7D2)
                    : const Color(0xFF7A8F8F),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem<String>(
            enabled: false,
            child: Text(
              '유형별',
              style: TextStyle(
                color: Color(0xFFD6ECEA),
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ];
        if (typeFilterOptions.isEmpty) {
          items.add(
            const PopupMenuItem<String>(
              enabled: false,
              child: Text(
                '유형 정보 없음',
                style: TextStyle(color: Color(0xFF6F8585), fontSize: 11),
              ),
            ),
          );
        } else {
          items.addAll(
            typeFilterOptions.map(
              (option) => CheckedPopupMenuItem<String>(
                value: 'type|$option',
                checked: selectedTypeFilters.contains(option),
                child: Text(
                  option,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF9FB3B3),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          );
        }
        items
          ..add(const PopupMenuDivider())
          ..add(
            const PopupMenuItem<String>(
              enabled: false,
              child: Text(
                '난이도별',
                style: TextStyle(
                  color: Color(0xFFD6ECEA),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          );
        if (difficultyFilterOptions.isEmpty) {
          items.add(
            const PopupMenuItem<String>(
              enabled: false,
              child: Text(
                '난이도 정보 없음',
                style: TextStyle(color: Color(0xFF6F8585), fontSize: 11),
              ),
            ),
          );
        } else {
          items.addAll(
            difficultyFilterOptions.map(
              (option) => CheckedPopupMenuItem<String>(
                value: 'difficulty|$option',
                checked: selectedDifficultyFilters.contains(option),
                child: Text(
                  option,
                  style: const TextStyle(
                    color: Color(0xFF9FB3B3),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          );
        }
        return items;
      },
      child: _fabShell(
        icon: Icons.filter_list,
        label: '필터',
        foregroundColor: fg,
        backgroundColor:
            filterActive ? const Color(0xE6173C36) : const Color(0xE610171A),
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

  Widget _fabShell({
    required IconData icon,
    required String label,
    required Color foregroundColor,
    required Color backgroundColor,
  }) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: foregroundColor),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: foregroundColor,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
