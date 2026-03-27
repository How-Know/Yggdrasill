import 'package:flutter/material.dart';

class ProblemBankClassificationFilterPanel extends StatelessWidget {
  const ProblemBankClassificationFilterPanel({
    super.key,
    required this.panelColor,
    required this.fieldColor,
    required this.borderColor,
    required this.textColor,
    required this.textSubColor,
    required this.accentColor,
    required this.curriculumLabels,
    required this.sourceTypeLabels,
    required this.questionTypeLabels,
    required this.selectedCurriculumCode,
    required this.selectedSourceTypeCode,
    required this.selectedQuestionType,
    required this.yearController,
    required this.gradeController,
    required this.schoolController,
    required this.isSearching,
    required this.onCurriculumChanged,
    required this.onSourceTypeChanged,
    required this.onQuestionTypeChanged,
    required this.onSearch,
    required this.onReset,
  });

  final Color panelColor;
  final Color fieldColor;
  final Color borderColor;
  final Color textColor;
  final Color textSubColor;
  final Color accentColor;
  final Map<String, String> curriculumLabels;
  final Map<String, String> sourceTypeLabels;
  final Map<String, String> questionTypeLabels;
  final String selectedCurriculumCode;
  final String selectedSourceTypeCode;
  final String selectedQuestionType;
  final TextEditingController yearController;
  final TextEditingController gradeController;
  final TextEditingController schoolController;
  final bool isSearching;
  final ValueChanged<String> onCurriculumChanged;
  final ValueChanged<String> onSourceTypeChanged;
  final ValueChanged<String> onQuestionTypeChanged;
  final VoidCallback onSearch;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: panelColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '저장 문항 검색',
            style: TextStyle(
              color: Color(0xFFEAF2F2),
              fontSize: 13.8,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          _buildDropdown(
            label: '교육과정',
            value: selectedCurriculumCode,
            values: curriculumLabels.keys.toList(growable: false),
            labels: curriculumLabels,
            onChanged: onCurriculumChanged,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildDropdown(
                  label: '출처',
                  value: selectedSourceTypeCode,
                  values: sourceTypeLabels.keys.toList(growable: false),
                  labels: sourceTypeLabels,
                  onChanged: onSourceTypeChanged,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildDropdown(
                  label: '문항유형',
                  value: selectedQuestionType,
                  values: questionTypeLabels.keys.toList(growable: false),
                  labels: questionTypeLabels,
                  onChanged: onQuestionTypeChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildTextField(
                  controller: yearController,
                  label: '년도',
                  hint: '예: 2026',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildTextField(
                  controller: gradeController,
                  label: '학년',
                  hint: '예: 1',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildTextField(
            controller: schoolController,
            label: '학교명/키워드',
            hint: '예: 경신중',
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: isSearching ? null : onSearch,
                  style: FilledButton.styleFrom(
                    backgroundColor: accentColor,
                    foregroundColor: Colors.white,
                  ),
                  icon: isSearching
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.8,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.search, size: 16),
                  label: Text(isSearching ? '검색 중...' : '검색'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: isSearching ? null : onReset,
                style: OutlinedButton.styleFrom(
                  foregroundColor: textSubColor,
                  side: BorderSide(color: borderColor),
                ),
                child: const Text('초기화'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDropdown({
    required String label,
    required String value,
    required List<String> values,
    required Map<String, String> labels,
    required ValueChanged<String> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: textSubColor,
            fontSize: 11.5,
          ),
        ),
        const SizedBox(height: 5),
        Container(
          height: 39,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: fieldColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              dropdownColor: panelColor,
              isExpanded: true,
              style: TextStyle(
                color: textColor,
                fontSize: 12.8,
                fontWeight: FontWeight.w600,
              ),
              items: values
                  .map(
                    (code) => DropdownMenuItem<String>(
                      value: code,
                      child: Text(labels[code] ?? code),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (v) {
                if (v == null) return;
                onChanged(v);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
  }) {
    return TextField(
      controller: controller,
      style: TextStyle(color: textColor, fontSize: 12.6),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: TextStyle(color: textSubColor, fontSize: 11),
        labelStyle: TextStyle(color: textSubColor, fontSize: 11),
        isDense: true,
        filled: true,
        fillColor: fieldColor,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: accentColor),
        ),
      ),
    );
  }
}
