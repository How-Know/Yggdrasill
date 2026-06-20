import 'package:flutter/material.dart';

import '../models/problem_bank_curriculum_filter.dart';
import 'problem_bank_legacy_curriculum_dialog.dart';

class ProblemBankFilterBar extends StatelessWidget {
  const ProblemBankFilterBar({
    super.key,
    required this.curriculumFilter,
    required this.onCurriculumFilterChanged,
    required this.selectedCourse,
    required this.courseOptions,
    required this.onCourseChanged,
    this.selectedPrivateMaterialKey = '',
    this.privateMaterialOptions = const <DropdownMenuItem<String>>[],
    this.onPrivateMaterialChanged,
    required this.isBusy,
    this.showPrivateMaterialDropdown = false,
  });

  final ProblemBankCurriculumFilter curriculumFilter;
  final ValueChanged<ProblemBankCurriculumFilter> onCurriculumFilterChanged;

  final String selectedCourse;
  final List<String> courseOptions;
  final ValueChanged<String?> onCourseChanged;

  final String selectedPrivateMaterialKey;
  final List<DropdownMenuItem<String>> privateMaterialOptions;
  final ValueChanged<String?>? onPrivateMaterialChanged;
  final bool showPrivateMaterialDropdown;

  final bool isBusy;

  static const _panelBg = Color(0xFF222222);
  static const _border = Color(0xFF333333);
  static const double _controlHeight = 40;
  static const Color _checkboxBorder = Color(0xFF5E7777);
  static const Color _checkboxActive = Color(0xFF1A6B5E);

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
    final titleStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
              color: const Color(0xFF9FB3B3),
              fontWeight: FontWeight.w700,
            ) ??
        const TextStyle(
          color: Color(0xFF9FB3B3),
          fontWeight: FontWeight.w700,
          fontSize: 12,
        );
    final filter = curriculumFilter;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: _panelBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _LabeledSection(
                  label: '교육과정',
                  titleStyle: titleStyle,
                  child: _buildCurriculumSelector(context, filter),
                ),
                const SizedBox(width: 12),
                _LabeledDropdown(
                  label: '세부 과정',
                  titleStyle: titleStyle,
                  width: 220,
                  child: _buildDropdown<String>(
                    value: selectedCourse,
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
                    onChanged: isBusy ? null : onCourseChanged,
                    width: 220,
                  ),
                ),
                if (showPrivateMaterialDropdown) ...[
                  const SizedBox(width: 12),
                  _LabeledDropdown(
                    label: '교재명',
                    titleStyle: titleStyle,
                    width: 260,
                    child: _buildDropdown<String>(
                      value: selectedPrivateMaterialKey,
                      items: privateMaterialOptions.isEmpty
                          ? const <DropdownMenuItem<String>>[
                              DropdownMenuItem<String>(
                                value: '',
                                child: Text('교재 없음'),
                              ),
                            ]
                          : privateMaterialOptions,
                      onChanged: isBusy ? null : onPrivateMaterialChanged,
                      width: 260,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurriculumSelector(
    BuildContext context,
    ProblemBankCurriculumFilter filter,
  ) {
    return Container(
      constraints: const BoxConstraints(minHeight: _controlHeight),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF10171A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          _CurriculumCheckbox(
            label: '전체',
            value: filter.allSelected,
            enabled: !isBusy,
            onChanged: _toggleAll,
          ),
          _CurriculumCheckbox(
            label: filter.latestLabel,
            value: !filter.allSelected && filter.latestSelected,
            enabled: !isBusy,
            onChanged: _toggleLatest,
          ),
          _CurriculumCheckbox(
            label: filter.previousLabel,
            value: !filter.allSelected && filter.previousSelected,
            enabled: !isBusy,
            onChanged: _togglePrevious,
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CurriculumCheckbox(
                label: filter.legacyGroupLabel(),
                value: !filter.allSelected && filter.legacyGroupSelected,
                enabled: !isBusy,
                maxLabelWidth: 220,
                onChanged: (checked) => _toggleLegacyGroup(context, checked),
              ),
              const SizedBox(width: 4),
              OutlinedButton(
                onPressed: isBusy ? null : () => _openLegacyPicker(context),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFBEE7D2),
                  disabledForegroundColor: const Color(0xFF6B7F7F),
                  side: const BorderSide(color: Color(0xFF2B6B61)),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 34),
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
    );
  }

  Widget _buildDropdown<T>({
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?>? onChanged,
    required double width,
  }) {
    return SizedBox(
      width: width,
      height: _controlHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF10171A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _border),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            style: const TextStyle(
              color: Color(0xFFEAF2F2),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            dropdownColor: const Color(0xFF151C21),
            iconEnabledColor: const Color(0xFF9FB3B3),
            isDense: true,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            borderRadius: BorderRadius.circular(10),
            items: items,
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}

class _CurriculumCheckbox extends StatelessWidget {
  const _CurriculumCheckbox({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.maxLabelWidth = 132,
  });

  final String label;
  final bool value;
  final bool enabled;
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
              side:
                  const BorderSide(color: ProblemBankFilterBar._checkboxBorder),
              activeColor: ProblemBankFilterBar._checkboxActive,
              onChanged: enabled ? onChanged : null,
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxLabelWidth),
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color:
                      value ? const Color(0xFFD6ECEA) : const Color(0xFF8FAAAA),
                  fontSize: 12,
                  fontWeight: value ? FontWeight.w800 : FontWeight.w700,
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

class _LabeledSection extends StatelessWidget {
  const _LabeledSection({
    required this.label,
    required this.titleStyle,
    required this.child,
  });

  final String label;
  final TextStyle titleStyle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: titleStyle),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}

class _LabeledDropdown extends StatelessWidget {
  const _LabeledDropdown({
    required this.label,
    required this.titleStyle,
    required this.child,
    this.width = 220,
  });

  final String label;
  final TextStyle titleStyle;
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: titleStyle),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}
