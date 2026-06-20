import 'package:flutter/material.dart';

import '../../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

const double problemBankRangeControlHeight = 40;

/// 문제은행 범위 선택 — 초·중·고 세그먼트 탭.
class ProblemBankLevelSegmentBar extends StatelessWidget {
  const ProblemBankLevelSegmentBar({
    super.key,
    required this.selectedLevel,
    required this.levelOptions,
    required this.onLevelChanged,
    required this.isBusy,
  });

  final String selectedLevel;
  final List<String> levelOptions;
  final ValueChanged<String> onLevelChanged;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);

    return Container(
      height: problemBankRangeControlHeight,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: panelStyle.dropdownBackground,
        borderRadius: BorderRadius.circular(999),
        border: FabTabBarTokens.groupedCardBorderFor(brightness),
      ),
      child: Row(
        children: [
          for (var i = 0; i < levelOptions.length; i++) ...[
            Expanded(
              child: _LevelSegmentChip(
                label: levelOptions[i],
                selected: selectedLevel == levelOptions[i],
                enabled: !isBusy,
                onTap: () => onLevelChanged(levelOptions[i]),
              ),
            ),
            if (i < levelOptions.length - 1) const SizedBox(width: 4),
          ],
        ],
      ),
    );
  }
}

/// 문제은행 범위 선택 — 공용 드롭다운.
class ProblemBankFilterDropdown<T> extends StatelessWidget {
  const ProblemBankFilterDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.isBusy = false,
  });

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);

    return SizedBox(
      height: problemBankRangeControlHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: panelStyle.dropdownBackground,
          borderRadius: BorderRadius.circular(10),
          border: FabTabBarTokens.groupedCardBorderFor(brightness),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            isExpanded: true,
            style: TextStyle(
              color: panelStyle.inputText,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            dropdownColor: panelStyle.dropdownBackground,
            iconEnabledColor: panelStyle.icon,
            isDense: true,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            borderRadius: BorderRadius.circular(10),
            items: items,
            onChanged: isBusy ? null : onChanged,
          ),
        ),
      ),
    );
  }
}

class _LevelSegmentChip extends StatelessWidget {
  const _LevelSegmentChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final highlight = FabTabBarTokens.fabHighlightPillFill(brightness);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: selected ? highlight : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: enabled ? onTap : null,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? panelStyle.title : panelStyle.hint,
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
