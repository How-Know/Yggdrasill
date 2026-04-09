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
    required this.onPageMarginChanged,
    required this.onColumnGapChanged,
    required this.onQuestionGapChanged,
    required this.onNumberLaneWidthChanged,
    required this.onNumberGapChanged,
    required this.onHangingIndentChanged,
    required this.onLineHeightChanged,
    required this.onChoiceSpacingChanged,
    required this.onTargetDpiChanged,
    required this.onPresetPressed,
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
  final ValueChanged<double> onPageMarginChanged;
  final ValueChanged<double> onColumnGapChanged;
  final ValueChanged<double> onQuestionGapChanged;
  final ValueChanged<double> onNumberLaneWidthChanged;
  final ValueChanged<double> onNumberGapChanged;
  final ValueChanged<double> onHangingIndentChanged;
  final ValueChanged<double> onLineHeightChanged;
  final ValueChanged<double> onChoiceSpacingChanged;
  final ValueChanged<int> onTargetDpiChanged;
  final VoidCallback onPresetPressed;

  static const _panelBg = Color(0xFF151C21);
  static const _border = Color(0xFF223131);
  static const _textPrimary = Color(0xFFEAF2F2);
  static const _textMuted = Color(0xFF9FB3B3);
  static const _accent = Color(0xFF33A373);
  static const double _controlHeight = 40;

  @override
  Widget build(BuildContext context) {
    final maxPerPageValues = [
      ...settings.maxQuestionsPerPageOptions.map((e) => '$e'),
      '많이',
    ];
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
          Row(
            children: [
              const Expanded(
                child: Text(
                  '양식 적용 및 출력',
                  style: TextStyle(
                    color: _textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: disabled ? null : onPresetPressed,
                style: OutlinedButton.styleFrom(
                  foregroundColor: _textPrimary,
                  side: const BorderSide(color: Color(0xFF2D4D4B)),
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: const Icon(Icons.bookmark_outline, size: 16),
                label: const Text(
                  '프리셋',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
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
                  label: '문항 배치',
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
                '${settings.layoutColumnCount}열 · ${settings.maxQuestionsPerPageLabel == '많이' ? '많이 배치' : '최대 ${settings.maxQuestionsPerPageCount}문항/페이지'} · 선택 $selectedCount문항',
                style: const TextStyle(
                  color: _textMuted,
                  fontSize: 11.8,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Theme(
            data: Theme.of(context).copyWith(
              dividerColor: Colors.transparent,
            ),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.fromLTRB(0, 0, 0, 2),
              iconColor: _textMuted,
              collapsedIconColor: _textMuted,
              title: const Text(
                '고급 레이아웃 미세조정',
                style: TextStyle(
                  color: _textMuted,
                  fontSize: 12.2,
                  fontWeight: FontWeight.w700,
                ),
              ),
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildTuningStepper(
                      label: '여백',
                      valueText:
                          settings.layoutTuning.pageMargin.toStringAsFixed(0),
                      onMinus: disabled
                          ? null
                          : () => onPageMarginChanged(
                                (settings.layoutTuning.pageMargin - 2)
                                    .clamp(20, 96)
                                    .toDouble(),
                              ),
                      onPlus: disabled
                          ? null
                          : () => onPageMarginChanged(
                                (settings.layoutTuning.pageMargin + 2)
                                    .clamp(20, 96)
                                    .toDouble(),
                              ),
                    ),
                    _buildTuningStepper(
                      label: '단 간격',
                      valueText:
                          settings.layoutTuning.columnGap.toStringAsFixed(0),
                      onMinus: disabled
                          ? null
                          : () => onColumnGapChanged(
                                (settings.layoutTuning.columnGap - 1)
                                    .clamp(0, 72)
                                    .toDouble(),
                              ),
                      onPlus: disabled
                          ? null
                          : () => onColumnGapChanged(
                                (settings.layoutTuning.columnGap + 1)
                                    .clamp(0, 72)
                                    .toDouble(),
                              ),
                    ),
                    _buildTuningStepper(
                      label: '문항 간격',
                      valueText:
                          settings.layoutTuning.questionGap.toStringAsFixed(0),
                      onMinus: disabled
                          ? null
                          : () => onQuestionGapChanged(
                                (settings.layoutTuning.questionGap - 1)
                                    .clamp(0, 64)
                                    .toDouble(),
                              ),
                      onPlus: disabled
                          ? null
                          : () => onQuestionGapChanged(
                                (settings.layoutTuning.questionGap + 1)
                                    .clamp(0, 64)
                                    .toDouble(),
                              ),
                    ),
                    _buildTuningStepper(
                      label: '번호칸',
                      valueText: settings.layoutTuning.numberLaneWidth
                          .toStringAsFixed(0),
                      onMinus: disabled
                          ? null
                          : () => onNumberLaneWidthChanged(
                                (settings.layoutTuning.numberLaneWidth - 1)
                                    .clamp(10, 80)
                                    .toDouble(),
                              ),
                      onPlus: disabled
                          ? null
                          : () => onNumberLaneWidthChanged(
                                (settings.layoutTuning.numberLaneWidth + 1)
                                    .clamp(10, 80)
                                    .toDouble(),
                              ),
                    ),
                    _buildTuningStepper(
                      label: '번호간격',
                      valueText:
                          settings.layoutTuning.numberGap.toStringAsFixed(0),
                      onMinus: disabled
                          ? null
                          : () => onNumberGapChanged(
                                (settings.layoutTuning.numberGap - 1)
                                    .clamp(0, 30)
                                    .toDouble(),
                              ),
                      onPlus: disabled
                          ? null
                          : () => onNumberGapChanged(
                                (settings.layoutTuning.numberGap + 1)
                                    .clamp(0, 30)
                                    .toDouble(),
                              ),
                    ),
                    _buildTuningStepper(
                      label: '내어쓰기',
                      valueText: settings.layoutTuning.hangingIndent
                          .toStringAsFixed(0),
                      onMinus: disabled
                          ? null
                          : () => onHangingIndentChanged(
                                (settings.layoutTuning.hangingIndent - 1)
                                    .clamp(0, 96)
                                    .toDouble(),
                              ),
                      onPlus: disabled
                          ? null
                          : () => onHangingIndentChanged(
                                (settings.layoutTuning.hangingIndent + 1)
                                    .clamp(0, 96)
                                    .toDouble(),
                              ),
                    ),
                    _buildTuningStepper(
                      label: '줄간격',
                      valueText:
                          settings.layoutTuning.lineHeight.toStringAsFixed(1),
                      onMinus: disabled
                          ? null
                          : () => onLineHeightChanged(
                                (settings.layoutTuning.lineHeight - 0.2)
                                    .clamp(10, 32)
                                    .toDouble(),
                              ),
                      onPlus: disabled
                          ? null
                          : () => onLineHeightChanged(
                                (settings.layoutTuning.lineHeight + 0.2)
                                    .clamp(10, 32)
                                    .toDouble(),
                              ),
                    ),
                    _buildTuningStepper(
                      label: '보기간격',
                      valueText: settings.layoutTuning.choiceSpacing
                          .toStringAsFixed(1),
                      onMinus: disabled
                          ? null
                          : () => onChoiceSpacingChanged(
                                (settings.layoutTuning.choiceSpacing - 0.2)
                                    .clamp(0, 24)
                                    .toDouble(),
                              ),
                      onPlus: disabled
                          ? null
                          : () => onChoiceSpacingChanged(
                                (settings.layoutTuning.choiceSpacing + 0.2)
                                    .clamp(0, 24)
                                    .toDouble(),
                              ),
                    ),
                    _buildTuningStepper(
                      label: '그림 DPI',
                      valueText: '${settings.figureQuality.targetDpi}',
                      onMinus: disabled
                          ? null
                          : () => onTargetDpiChanged(
                                (settings.figureQuality.targetDpi - 50)
                                    .clamp(300, 1200)
                                    .toInt(),
                              ),
                      onPlus: disabled
                          ? null
                          : () => onTargetDpiChanged(
                                (settings.figureQuality.targetDpi + 50)
                                    .clamp(300, 1200)
                                    .toInt(),
                              ),
                    ),
                  ],
                ),
              ],
            ),
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
    final safeValue = values.contains(value)
        ? value
        : (values.isNotEmpty ? values.first : null);
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
            value: safeValue,
            style: const TextStyle(
              color: _textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            dropdownColor: const Color(0xFF151C21),
            iconEnabledColor: _textMuted,
            isDense: true,
            isExpanded: true,
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
            onChanged: onChanged == null
                ? null
                : (v) => onChanged(v ?? safeValue ?? value),
          ),
        ),
      ),
    );
  }

  Widget _buildTuningStepper({
    required String label,
    required String valueText,
    required VoidCallback? onMinus,
    required VoidCallback? onPlus,
  }) {
    return Container(
      width: 136,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF10171A),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: _border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: _textMuted,
                    fontSize: 10.8,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  valueText,
                  style: const TextStyle(
                    color: _textPrimary,
                    fontSize: 12.4,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Column(
            children: [
              InkWell(
                onTap: onPlus,
                borderRadius: BorderRadius.circular(4),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(
                    Icons.keyboard_arrow_up,
                    size: 16,
                    color: _textMuted,
                  ),
                ),
              ),
              InkWell(
                onTap: onMinus,
                borderRadius: BorderRadius.circular(4),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    size: 16,
                    color: _textMuted,
                  ),
                ),
              ),
            ],
          ),
        ],
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
