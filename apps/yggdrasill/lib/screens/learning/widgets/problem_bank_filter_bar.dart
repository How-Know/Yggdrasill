import 'package:flutter/material.dart';

class ProblemBankFilterBar extends StatelessWidget {
  const ProblemBankFilterBar({
    super.key,
    required this.selectedCurriculumCode,
    required this.curriculumLabels,
    required this.onCurriculumChanged,
    required this.selectedLevel,
    required this.levelOptions,
    required this.onLevelChanged,
    required this.selectedCourse,
    required this.courseOptions,
    required this.onCourseChanged,
    required this.selectedSourceTypeCode,
    required this.sourceTypeLabels,
    required this.onSourceTypeChanged,
    required this.isBusy,
  });

  final String selectedCurriculumCode;
  final Map<String, String> curriculumLabels;
  final ValueChanged<String?> onCurriculumChanged;

  final String selectedLevel;
  final List<String> levelOptions;
  final ValueChanged<String> onLevelChanged;

  final String selectedCourse;
  final List<String> courseOptions;
  final ValueChanged<String?> onCourseChanged;

  final String selectedSourceTypeCode;
  final Map<String, String> sourceTypeLabels;
  final ValueChanged<String?> onSourceTypeChanged;

  final bool isBusy;

  static const _panelBg = Color(0xFF222222);
  static const _border = Color(0xFF333333);
  static const double _controlHeight = 40;

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
          const Text(
            '범위 선택',
            style: TextStyle(
              color: Color(0xFFEAF2F2),
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _LabeledDropdown(
                  label: '교육과정',
                  titleStyle: titleStyle,
                  width: 240,
                  child: _buildDropdown<String>(
                    value: selectedCurriculumCode,
                    items: curriculumLabels.entries
                        .map(
                          (e) => DropdownMenuItem<String>(
                            value: e.key,
                            child: Text(
                              e.value,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: isBusy ? null : onCurriculumChanged,
                    width: 240,
                  ),
                ),
                const SizedBox(width: 12),
                _LabeledSection(
                  label: '초중고',
                  titleStyle: titleStyle,
                  child: _buildLevelSegmentSelector(),
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
                const SizedBox(width: 12),
                _LabeledDropdown(
                  label: '출처',
                  titleStyle: titleStyle,
                  width: 190,
                  child: _buildDropdown<String>(
                    value: selectedSourceTypeCode,
                    items: sourceTypeLabels.entries
                        .map(
                          (e) => DropdownMenuItem<String>(
                            value: e.key,
                            child: Text(
                              e.value,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: isBusy ? null : onSourceTypeChanged,
                    width: 190,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLevelSegmentSelector() {
    return Container(
      height: _controlHeight,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF10171A).withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final level in levelOptions) ...[
            _LevelSegmentChip(
              label: level,
              selected: selectedLevel == level,
              enabled: !isBusy,
              onTap: () => onLevelChanged(level),
            ),
            if (level != levelOptions.last) const SizedBox(width: 4),
          ],
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
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF173C36) : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: selected ? const Color(0xFF2E7C70) : Colors.transparent,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Text(
              label,
              style: TextStyle(
                color: selected
                    ? const Color(0xFFBEE7D2)
                    : const Color(0xFF9FB3B3),
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
