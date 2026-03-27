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

  static const _panelBg = Color(0xFFFBF7EE);
  static const _border = Color(0xFFE2D8C7);
  static const _accent = Color(0xFF6EA68D);

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
              color: const Color(0xFF7A746A),
              fontWeight: FontWeight.w700,
            ) ??
        const TextStyle(
          color: Color(0xFF7A746A),
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
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _LabeledDropdown(
                label: '교육과정',
                titleStyle: titleStyle,
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
                  width: 210,
                ),
              ),
              _LabeledDropdown(
                label: '세부 과정',
                titleStyle: titleStyle,
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
                  width: 180,
                ),
              ),
              _LabeledDropdown(
                label: '출처',
                titleStyle: titleStyle,
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
                  width: 170,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('초중고', style: titleStyle),
              for (final level in levelOptions)
                ChoiceChip(
                  label: Text(level),
                  selected: selectedLevel == level,
                  onSelected: isBusy
                      ? null
                      : (selected) {
                          if (!selected) return;
                          onLevelChanged(level);
                        },
                  selectedColor: _accent.withValues(alpha: 0.15),
                  side: BorderSide(
                    color: selectedLevel == level ? _accent : _border,
                  ),
                  labelStyle: TextStyle(
                    color: selectedLevel == level
                        ? const Color(0xFF2A6A4A)
                        : const Color(0xFF6E6558),
                    fontWeight: selectedLevel == level
                        ? FontWeight.w700
                        : FontWeight.w500,
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
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _border),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
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

class _LabeledDropdown extends StatelessWidget {
  const _LabeledDropdown({
    required this.label,
    required this.titleStyle,
    required this.child,
  });

  final String label;
  final TextStyle titleStyle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
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
