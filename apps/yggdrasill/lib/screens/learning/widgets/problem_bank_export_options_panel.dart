import 'package:flutter/material.dart';

import '../../../services/learning_problem_bank_service.dart';
import '../../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../models/problem_bank_export_models.dart';

/// 양식·출력 공용 드롭다운 본문 — [SharedDropdownDialogPanel] 안에 배치한다.
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

  static const double controlHeight = 40;
  static const double sectionTitleSize = 14;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final style = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final accent = FabTabBarTokens.previewConfirmActionColor;
    final maxPerPageValues = [
      ...settings.maxQuestionsPerPageOptions.map((e) => '$e'),
      '많이',
    ];
    final disabled = isBusy || isSavingLocally;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        sectionTitle(style, '기본 양식'),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              labeledDropdown(
                style: style,
                brightness: brightness,
                label: '시험 양식',
                width: 170,
                value: settings.templateLabel,
                values: kLearningProblemTemplateOptions,
                onChanged: disabled ? null : onTemplateChanged,
              ),
              const SizedBox(width: 10),
              labeledDropdown(
                style: style,
                brightness: brightness,
                label: '용지',
                width: 110,
                value: settings.paperLabel,
                values: kLearningProblemPaperOptions,
                onChanged: disabled ? null : onPaperChanged,
              ),
              const SizedBox(width: 10),
              labeledDropdown(
                style: style,
                brightness: brightness,
                label: '출제형식',
                width: 130,
                value: settings.questionModeLabel,
                values: kLearningProblemQuestionModeOptions,
                onChanged: disabled ? null : onQuestionModeChanged,
              ),
              const SizedBox(width: 10),
              labeledDropdown(
                style: style,
                brightness: brightness,
                label: '단 선택',
                width: 110,
                value: settings.layoutColumnLabel,
                values: kLearningProblemLayoutColumnOptions,
                onChanged: disabled ? null : onLayoutColumnsChanged,
              ),
              const SizedBox(width: 10),
              labeledDropdown(
                style: style,
                brightness: brightness,
                label: '문항 배치',
                width: 160,
                value: settings.maxQuestionsPerPageLabel,
                values: maxPerPageValues,
                onChanged: disabled ? null : onMaxQuestionsPerPageChanged,
              ),
              const SizedBox(width: 10),
              labeledDropdown(
                style: style,
                brightness: brightness,
                label: '폰트',
                width: 150,
                value: settings.fontFamilyLabel,
                values: kLearningProblemFontFamilyOptions,
                onChanged: disabled ? null : onFontFamilyChanged,
              ),
              const SizedBox(width: 10),
              labeledDropdown(
                style: style,
                brightness: brightness,
                label: '폰트 크기',
                width: 120,
                value: settings.fontSizeLabel,
                values: kLearningProblemFontSizeOptions,
                onChanged: disabled ? null : onFontSizeChanged,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Divider(color: style.divider, height: 1),
        const SizedBox(height: 12),
        sectionTitle(style, '포함 옵션'),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            optionCheckbox(
              style: style,
              accent: accent,
              label: '정답지 포함',
              value: settings.includeAnswerSheet,
              disabled: disabled,
              onChanged: onIncludeAnswerSheetChanged,
            ),
            optionCheckbox(
              style: style,
              accent: accent,
              label: '해설 포함',
              value: settings.includeExplanation,
              disabled: disabled,
              onChanged: onIncludeExplanationChanged,
            ),
            Text(
              '${settings.layoutColumnCount}열 · ${settings.maxQuestionsPerPageLabel == '많이' ? '많이 배치' : '최대 ${settings.maxQuestionsPerPageCount}문항/페이지'} · 선택 $selectedCount문항',
              style: FabTabBarTokens.previewBodyTextStyle(
                style,
                color: style.hint,
                fontWeight: FontWeight.w700,
              ).copyWith(fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 4),
            iconColor: style.hint,
            collapsedIconColor: style.hint,
            title: Text(
              '고급 레이아웃 미세조정',
              style: FabTabBarTokens.previewAcademyLabelStyle(style).copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: style.hint,
              ),
            ),
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  tuningStepper(
                    style: style,
                    brightness: brightness,
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
                  tuningStepper(
                    style: style,
                    brightness: brightness,
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
                  tuningStepper(
                    style: style,
                    brightness: brightness,
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
                  tuningStepper(
                    style: style,
                    brightness: brightness,
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
                  tuningStepper(
                    style: style,
                    brightness: brightness,
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
                  tuningStepper(
                    style: style,
                    brightness: brightness,
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
                  tuningStepper(
                    style: style,
                    brightness: brightness,
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
                  tuningStepper(
                    style: style,
                    brightness: brightness,
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
                  tuningStepper(
                    style: style,
                    brightness: brightness,
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
            style: FabTabBarTokens.previewBodyTextStyle(
              style,
              color: style.hint,
              fontWeight: FontWeight.w600,
            ).copyWith(fontSize: 11.5),
          ),
        ],
      ],
    );
  }

  static Widget sectionTitle(PreviewAcademyPanelStyle style, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: FabTabBarTokens.previewAcademyLabelStyle(style).copyWith(
          fontSize: sectionTitleSize,
          fontWeight: FontWeight.w800,
          color: style.label,
        ),
      ),
    );
  }

  static Widget labeledDropdown({
    required PreviewAcademyPanelStyle style,
    required Brightness brightness,
    required String label,
    required double width,
    required String value,
    required List<String> values,
    required ValueChanged<String>? onChanged,
  }) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: FabTabBarTokens.previewAcademyLabelStyle(style).copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: style.hint,
            ),
          ),
          const SizedBox(height: 4),
          dropdown(
            style: style,
            brightness: brightness,
            width: width,
            value: value,
            values: values,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  static Widget dropdown({
    required PreviewAcademyPanelStyle style,
    required Brightness brightness,
    required double width,
    required String value,
    required List<String> values,
    required ValueChanged<String>? onChanged,
  }) {
    final safeValue =
        values.contains(value) ? value : (values.isNotEmpty ? values.first : null);
    return SizedBox(
      width: width,
      height: controlHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: style.dropdownBackground,
          borderRadius: BorderRadius.circular(10),
          border: FabTabBarTokens.groupedCardBorderFor(brightness),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: safeValue,
            style: FabTabBarTokens.previewBodyTextStyle(
              style,
              fontWeight: FontWeight.w600,
            ).copyWith(fontSize: 13),
            dropdownColor: style.groupedCardBackground,
            iconEnabledColor: style.hint,
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

  static Widget optionCheckbox({
    required PreviewAcademyPanelStyle style,
    required Color accent,
    required String label,
    required bool value,
    required bool disabled,
    required ValueChanged<bool> onChanged,
  }) {
    return SizedBox(
      width: 138,
      child: CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: value,
        activeColor: accent,
        title: Text(
          label,
          style: FabTabBarTokens.previewBodyTextStyle(
            style,
            color: style.hint,
            fontWeight: FontWeight.w600,
          ).copyWith(fontSize: 12.5),
        ),
        controlAffinity: ListTileControlAffinity.leading,
        onChanged: disabled ? null : (v) => onChanged(v ?? false),
      ),
    );
  }

  static Widget tuningStepper({
    required PreviewAcademyPanelStyle style,
    required Brightness brightness,
    required String label,
    required String valueText,
    required VoidCallback? onMinus,
    required VoidCallback? onPlus,
  }) {
    return Container(
      width: 136,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: style.dropdownBackground,
        borderRadius: BorderRadius.circular(9),
        border: FabTabBarTokens.groupedCardBorderFor(brightness),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: FabTabBarTokens.previewBodyTextStyle(
                    style,
                    color: style.hint,
                    fontWeight: FontWeight.w700,
                  ).copyWith(fontSize: 10.8),
                ),
                const SizedBox(height: 1),
                Text(
                  valueText,
                  style: FabTabBarTokens.previewMenuItemTextStyle(style).copyWith(
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
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    Icons.keyboard_arrow_up,
                    size: 16,
                    color: style.hint,
                  ),
                ),
              ),
              InkWell(
                onTap: onMinus,
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    size: 16,
                    color: style.hint,
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

/// 문제은행 전용 — 양식 패널 아래 문항 선택·순서 옵션.
class ProblemBankQuestionSelectionOptionsPanel extends StatelessWidget {
  const ProblemBankQuestionSelectionOptionsPanel({
    super.key,
    required this.isBusy,
    required this.possibleObjectiveCount,
    required this.possibleSubjectiveCount,
    required this.shuffleEnabled,
    required this.shuffleMode,
    required this.typePriorityEnabled,
    required this.typePriorityMode,
    required this.onSetObjectiveMode,
    required this.onSetSubjectiveMode,
    required this.onShuffleEnabledChanged,
    required this.onShuffleModeChanged,
    required this.onTypePriorityEnabledChanged,
    required this.onTypePriorityModeChanged,
  });

  final bool isBusy;
  final int possibleObjectiveCount;
  final int possibleSubjectiveCount;
  final bool shuffleEnabled;
  final String shuffleMode;
  final bool typePriorityEnabled;
  final String typePriorityMode;
  final VoidCallback onSetObjectiveMode;
  final VoidCallback onSetSubjectiveMode;
  final ValueChanged<bool> onShuffleEnabledChanged;
  final ValueChanged<String> onShuffleModeChanged;
  final ValueChanged<bool> onTypePriorityEnabledChanged;
  final ValueChanged<String> onTypePriorityModeChanged;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final style = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final accent = FabTabBarTokens.previewConfirmActionColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 4),
        Divider(color: style.divider, height: 1),
        const SizedBox(height: 12),
        ProblemBankExportOptionsPanel.sectionTitle(style, '문항 선택'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _actionButton(
              style: style,
              label: '가능 문항 객관식',
              onPressed:
                  possibleObjectiveCount == 0 || isBusy ? null : onSetObjectiveMode,
            ),
            _actionButton(
              style: style,
              label: '가능 문항 주관식',
              onPressed:
                  possibleSubjectiveCount == 0 || isBusy ? null : onSetSubjectiveMode,
            ),
            _checkDropdown(
              style: style,
              brightness: brightness,
              accent: accent,
              label: '섞기/난이도',
              checked: shuffleEnabled,
              onChecked: onShuffleEnabledChanged,
              value: shuffleMode,
              options: const [
                '랜덤',
                '난이도 오름차순',
                '난이도 내림차순',
              ],
              disabled: isBusy,
              onChanged: onShuffleModeChanged,
            ),
            _checkDropdown(
              style: style,
              brightness: brightness,
              accent: accent,
              label: '유형 우선',
              checked: typePriorityEnabled,
              onChecked: onTypePriorityEnabledChanged,
              value: typePriorityMode,
              options: const ['객관식 먼저', '주관식 먼저'],
              disabled: isBusy,
              onChanged: onTypePriorityModeChanged,
            ),
          ],
        ),
      ],
    );
  }

  static Widget _actionButton({
    required PreviewAcademyPanelStyle style,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      height: 34,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: style.title,
          side: BorderSide(color: style.border),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }

  static Widget _checkDropdown({
    required PreviewAcademyPanelStyle style,
    required Brightness brightness,
    required Color accent,
    required String label,
    required bool checked,
    required ValueChanged<bool> onChecked,
    required String value,
    required List<String> options,
    required bool disabled,
    required ValueChanged<String> onChanged,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(
          value: checked,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          side: BorderSide(color: style.border),
          activeColor: accent,
          onChanged: disabled ? null : (v) => onChecked(v == true),
        ),
        Text(
          label,
          style: FabTabBarTokens.previewBodyTextStyle(
            style,
            color: style.hint,
            fontWeight: FontWeight.w700,
          ).copyWith(fontSize: 11),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 132,
          height: 34,
          child: ProblemBankExportOptionsPanel.dropdown(
            style: style,
            brightness: brightness,
            width: 132,
            value: value,
            values: options,
            onChanged: checked && !disabled ? onChanged : null,
          ),
        ),
      ],
    );
  }
}
