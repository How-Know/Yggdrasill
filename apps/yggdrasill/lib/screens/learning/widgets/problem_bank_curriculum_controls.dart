import 'package:flutter/material.dart';

import '../../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../models/problem_bank_curriculum_filter.dart';
import 'problem_bank_legacy_curriculum_dialog.dart';
import 'problem_bank_range_controls.dart';

/// 문제은행 좌측 범위 선택 — 교육과정·세부 과정(설정 펼침 영역).
class ProblemBankCurriculumControls extends StatelessWidget {
  const ProblemBankCurriculumControls({
    super.key,
    required this.curriculumFilter,
    required this.onCurriculumFilterChanged,
    required this.selectedCourse,
    required this.courseOptions,
    required this.onCourseChanged,
    required this.isBusy,
  });

  final ProblemBankCurriculumFilter curriculumFilter;
  final ValueChanged<ProblemBankCurriculumFilter> onCurriculumFilterChanged;
  final String selectedCourse;
  final List<String> courseOptions;
  final ValueChanged<String?> onCourseChanged;
  final bool isBusy;

  static const Color _checkboxActive = Color(0xFF33A373);

  Future<void> _openLegacyPicker(BuildContext context) async {
    if (isBusy) return;
    final picked = await showProblemBankLegacyCurriculumDialog(
      context: context,
      initialSelected: curriculumFilter.legacyCodes,
    );
    if (picked == null) return;
    onCurriculumFilterChanged(
      curriculumFilter
          .copyWith(
            allSelected: false,
            legacyCodes: picked,
          )
          .normalized(),
    );
  }

  void _toggleAll(bool? checked) {
    if (isBusy || checked != true) return;
    onCurriculumFilterChanged(
      const ProblemBankCurriculumFilter(allSelected: true).normalized(),
    );
  }

  void _toggleLatest(bool? checked) {
    if (isBusy) return;
    onCurriculumFilterChanged(
      curriculumFilter
          .copyWith(
            allSelected: false,
            latestSelected: checked == true,
          )
          .normalized(),
    );
  }

  void _togglePrevious(bool? checked) {
    if (isBusy) return;
    onCurriculumFilterChanged(
      curriculumFilter
          .copyWith(
            allSelected: false,
            previousSelected: checked == true,
          )
          .normalized(),
    );
  }

  Future<void> _toggleLegacyGroup(
    BuildContext context,
    bool? checked,
  ) async {
    if (isBusy) return;
    if (checked == true) {
      if (curriculumFilter.legacyCodes.isEmpty) {
        await _openLegacyPicker(context);
        return;
      }
      onCurriculumFilterChanged(
        curriculumFilter.copyWith(allSelected: false).normalized(),
      );
      return;
    }
    onCurriculumFilterChanged(
      curriculumFilter.copyWith(
        allSelected: false,
        legacyCodes: const <String>{},
      ).normalized(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final filter = curriculumFilter;
    final labelStyle = TextStyle(
      color: panelStyle.label,
      fontWeight: FontWeight.w600,
      fontSize: 12,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('교육과정', style: labelStyle),
        const SizedBox(height: 8),
        DecoratedBox(
          decoration: BoxDecoration(
            color: panelStyle.dropdownBackground,
            borderRadius: BorderRadius.circular(10),
            border: FabTabBarTokens.groupedCardBorderFor(brightness),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              runSpacing: 2,
              children: [
                _CurriculumCheckbox(
                  label: '전체',
                  value: filter.allSelected,
                  enabled: !isBusy,
                  panelStyle: panelStyle,
                  onChanged: _toggleAll,
                ),
                _CurriculumCheckbox(
                  label: filter.latestLabel,
                  value: !filter.allSelected && filter.latestSelected,
                  enabled: !isBusy,
                  panelStyle: panelStyle,
                  onChanged: _toggleLatest,
                ),
                _CurriculumCheckbox(
                  label: filter.previousLabel,
                  value: !filter.allSelected && filter.previousSelected,
                  enabled: !isBusy,
                  panelStyle: panelStyle,
                  onChanged: _togglePrevious,
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _CurriculumCheckbox(
                      label: filter.legacyGroupLabel(),
                      value: !filter.allSelected && filter.legacyGroupSelected,
                      enabled: !isBusy,
                      panelStyle: panelStyle,
                      maxLabelWidth: 160,
                      onChanged: (checked) =>
                          _toggleLegacyGroup(context, checked),
                    ),
                    const SizedBox(width: 4),
                    OutlinedButton(
                      onPressed:
                          isBusy ? null : () => _openLegacyPicker(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: panelStyle.title,
                        disabledForegroundColor: panelStyle.hint,
                        side: BorderSide(color: panelStyle.border),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      child: const Text(
                        '선택',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text('세부 과정', style: labelStyle),
        const SizedBox(height: 8),
        ProblemBankFilterDropdown<String>(
          value: selectedCourse,
          isBusy: isBusy,
          items: courseOptions
              .map(
                (course) => DropdownMenuItem<String>(
                  value: course,
                  child: Text(
                    course,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(growable: false),
          onChanged: onCourseChanged,
        ),
      ],
    );
  }
}

class _CurriculumCheckbox extends StatelessWidget {
  const _CurriculumCheckbox({
    required this.label,
    required this.value,
    required this.enabled,
    required this.panelStyle,
    required this.onChanged,
    this.maxLabelWidth = 120,
  });

  final String label;
  final bool value;
  final bool enabled;
  final PreviewAcademyPanelStyle panelStyle;
  final ValueChanged<bool?> onChanged;
  final double maxLabelWidth;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: value,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              side: BorderSide(color: panelStyle.border),
              activeColor: ProblemBankCurriculumControls._checkboxActive,
              onChanged: enabled ? onChanged : null,
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxLabelWidth),
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: value ? panelStyle.title : panelStyle.hint,
                  fontSize: 12,
                  fontWeight: value ? FontWeight.w800 : FontWeight.w600,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
