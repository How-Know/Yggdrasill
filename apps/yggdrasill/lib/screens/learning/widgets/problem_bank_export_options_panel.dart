import 'package:flutter/material.dart';

import '../../../services/learning_problem_bank_service.dart';
import '../models/problem_bank_export_models.dart';

class ProblemBankExportOptionsPanel extends StatelessWidget {
  const ProblemBankExportOptionsPanel({
    super.key,
    required this.settings,
    required this.selectedCount,
    required this.isBusy,
    required this.isSavingLocally,
    required this.activeJob,
    required this.onTemplateChanged,
    required this.onPaperChanged,
    required this.onQuestionModeChanged,
    required this.onLayoutColumnsChanged,
    required this.onMaxQuestionsPerPageChanged,
    required this.onFontFamilyChanged,
    required this.onFontSizeChanged,
    required this.onIncludeAnswerSheetChanged,
    required this.onIncludeExplanationChanged,
  });

  final LearningProblemExportSettings settings;
  final int selectedCount;
  final bool isBusy;
  final bool isSavingLocally;
  final LearningProblemExportJob? activeJob;

  final ValueChanged<String> onTemplateChanged;
  final ValueChanged<String> onPaperChanged;
  final ValueChanged<String> onQuestionModeChanged;
  final ValueChanged<String> onLayoutColumnsChanged;
  final ValueChanged<String> onMaxQuestionsPerPageChanged;
  final ValueChanged<String> onFontFamilyChanged;
  final ValueChanged<String> onFontSizeChanged;
  final ValueChanged<bool> onIncludeAnswerSheetChanged;
  final ValueChanged<bool> onIncludeExplanationChanged;

  static const _panelBg = Color(0xFF151C21);
  static const _border = Color(0xFF223131);
  static const _textPrimary = Color(0xFFEAF2F2);
  static const _textMuted = Color(0xFF9FB3B3);
  static const _accent = Color(0xFF33A373);
  static const double _controlHeight = 40;

  @override
  Widget build(BuildContext context) {
    final maxPerPageValues = settings.maxQuestionsPerPageOptions
        .map((e) => '$e')
        .toList(growable: false);
    final disabled = isBusy || isSavingLocally;

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
            '양식 적용 및 출력',
            style: TextStyle(
              color: _textPrimary,
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
                  label: '시험 양식',
                  width: 170,
                  child: _buildDropdown(
                    value: settings.templateLabel,
                    values: kLearningProblemTemplateOptions,
                    onChanged: disabled ? null : onTemplateChanged,
                    width: 170,
                  ),
                ),
                const SizedBox(width: 10),
                _LabeledDropdown(
                  label: '용지',
                  width: 110,
                  child: _buildDropdown(
                    value: settings.paperLabel,
                    values: kLearningProblemPaperOptions,
                    onChanged: disabled ? null : onPaperChanged,
                    width: 110,
                  ),
                ),
                const SizedBox(width: 10),
                _LabeledDropdown(
                  label: '출제형식',
                  width: 130,
                  child: _buildDropdown(
                    value: settings.questionModeLabel,
                    values: kLearningProblemQuestionModeOptions,
                    onChanged: disabled ? null : onQuestionModeChanged,
                    width: 130,
                  ),
                ),
                const SizedBox(width: 10),
                _LabeledDropdown(
                  label: '단 선택',
                  width: 110,
                  child: _buildDropdown(
                    value: settings.layoutColumnLabel,
                    values: kLearningProblemLayoutColumnOptions,
                    onChanged: disabled ? null : onLayoutColumnsChanged,
                    width: 110,
                  ),
                ),
                const SizedBox(width: 10),
                _LabeledDropdown(
                  label: '페이지당 최대 문항',
                  width: 160,
                  child: _buildDropdown(
                    value: settings.maxQuestionsPerPageLabel,
                    values: maxPerPageValues,
                    onChanged: disabled ? null : onMaxQuestionsPerPageChanged,
                    width: 160,
                  ),
                ),
                const SizedBox(width: 10),
                _LabeledDropdown(
                  label: '폰트',
                  width: 150,
                  child: _buildDropdown(
                    value: settings.fontFamilyLabel,
                    values: kLearningProblemFontFamilyOptions,
                    onChanged: disabled ? null : onFontFamilyChanged,
                    width: 150,
                  ),
                ),
                const SizedBox(width: 10),
                _LabeledDropdown(
                  label: '폰트 크기',
                  width: 120,
                  child: _buildDropdown(
                    value: settings.fontSizeLabel,
                    values: kLearningProblemFontSizeOptions,
                    onChanged: disabled ? null : onFontSizeChanged,
                    width: 120,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 138,
                child: CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: settings.includeAnswerSheet,
                  activeColor: _accent,
                  title: const Text(
                    '정답지 포함',
                    style: TextStyle(
                      color: _textMuted,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: disabled
                      ? null
                      : (v) => onIncludeAnswerSheetChanged(v ?? false),
                ),
              ),
              SizedBox(
                width: 128,
                child: CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: settings.includeExplanation,
                  activeColor: _accent,
                  title: const Text(
                    '해설 포함',
                    style: TextStyle(
                      color: _textMuted,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: disabled
                      ? null
                      : (v) => onIncludeExplanationChanged(v ?? false),
                ),
              ),
              Text(
                '${settings.layoutColumnCount}열 · 최대 ${settings.maxQuestionsPerPageCount}문항/페이지 · 선택 $selectedCount문항',
                style: const TextStyle(
                  color: _textMuted,
                  fontSize: 11.8,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (activeJob != null) ...[
            const SizedBox(height: 8),
            Text(
              'export_job: ${activeJob!.status}'
              '${activeJob!.pageCount > 0 ? ' · ${activeJob!.pageCount}p' : ''}',
              style: const TextStyle(
                color: _textMuted,
                fontSize: 11.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDropdown({
    required String value,
    required List<String> values,
    required ValueChanged<String>? onChanged,
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
          child: DropdownButton<String>(
            value: value,
            style: const TextStyle(
              color: _textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            dropdownColor: const Color(0xFF151C21),
            iconEnabledColor: _textMuted,
            isDense: true,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            borderRadius: BorderRadius.circular(10),
            items: values
                .map(
                  (item) => DropdownMenuItem<String>(
                    value: item,
                    child: Text(item, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(growable: false),
            onChanged: onChanged == null ? null : (v) => onChanged(v ?? value),
          ),
        ),
      ),
    );
  }
}

class _LabeledDropdown extends StatelessWidget {
  const _LabeledDropdown({
    required this.label,
    required this.width,
    required this.child,
  });

  final String label;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF9FB3B3),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}
