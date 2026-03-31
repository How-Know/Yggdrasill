import 'package:flutter/material.dart';

import '../../../services/learning_problem_bank_service.dart';
import '../models/problem_bank_export_models.dart';
import 'problem_bank_manager_preview_paper.dart';

class ProblemBankQuestionCard extends StatelessWidget {
  const ProblemBankQuestionCard({
    super.key,
    required this.question,
    required this.selected,
    required this.onSelectedChanged,
    required this.selectedMode,
    this.onModeSelected,
    this.figureUrlsByPath = const <String, String>{},
    this.showSelectionControl = true,
    this.paperStyle = false,
    this.previewImageUrl,
  });

  final LearningProblemQuestion question;
  final bool selected;
  final ValueChanged<bool> onSelectedChanged;
  final String selectedMode;
  final ValueChanged<String>? onModeSelected;
  final Map<String, String> figureUrlsByPath;
  final bool showSelectionControl;
  final bool paperStyle;
  final String? previewImageUrl;

  @override
  Widget build(BuildContext context) {
    final color = _palette(paperStyle: paperStyle, selected: selected);
    final previewQuestion = questionForLayoutPreviewMode(
      question,
      selectedMode,
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      decoration: BoxDecoration(
        color: color.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.border, width: selected ? 1.4 : 1),
        boxShadow: color.boxShadow,
      ),
      child: Column(
        children: [
          _buildHeader(color),
          Divider(height: 1, color: color.divider),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildPreviewContent(previewQuestion),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _metaSummaryText(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color.textMuted,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewContent(LearningProblemQuestion previewQuestion) {
    final wrapper = Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: _buildPreviewInner(previewQuestion),
    );
    return wrapper;
  }

  Widget _buildPreviewInner(LearningProblemQuestion previewQuestion) {
    if (previewImageUrl != null && previewImageUrl!.isNotEmpty) {
      return SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: Image.network(
          previewImageUrl!,
          fit: BoxFit.fitWidth,
          alignment: Alignment.topCenter,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return const SizedBox(
              height: 200,
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          },
          errorBuilder: (context, error, stack) {
            return _buildNativeFallback(previewQuestion);
          },
        ),
      );
    }
    return _buildNativeFallback(previewQuestion);
  }

  Widget _buildNativeFallback(LearningProblemQuestion previewQuestion) {
    return ProblemBankManagerPreviewPaper(
      question: previewQuestion,
      figureUrlsByPath: figureUrlsByPath,
      expanded: false,
      scrollable: true,
      bordered: false,
      shadow: false,
      showQuestionNumberPrefix: false,
    );
  }

  Widget _buildHeader(_CardPalette color) {
    final availableModes = selectableQuestionModesOf(question);
    final originalMode = originalQuestionModeOf(question);
    final effectiveSelected = normalizeQuestionModeSelection(
      question,
      selectedMode,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showSelectionControl)
            Checkbox(
              value: selected,
              visualDensity: VisualDensity.compact,
              side: BorderSide(color: color.checkBorder),
              activeColor: color.accent,
              onChanged: (v) => onSelectedChanged(v ?? false),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                '${question.displayQuestionNumber}번 문항',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: color.textPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Align(
              alignment: Alignment.topRight,
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                children: [
                  for (final mode in availableModes)
                    _buildModeChip(
                      mode,
                      color: color,
                      isOriginal: mode == originalMode,
                      isSelected: mode == effectiveSelected,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _metaSummaryText() {
    final originalNumber = question.questionNumber.trim().isNotEmpty
        ? question.questionNumber.trim()
        : question.displayQuestionNumber;
    final parts = <String>[
      if (question.schoolName.isNotEmpty) question.schoolName.trim(),
      if (question.examYear != null) '${question.examYear}',
      if (question.gradeLabel.isNotEmpty) question.gradeLabel.trim(),
      if (question.semesterLabel.isNotEmpty) question.semesterLabel.trim(),
      if (question.examTermLabel.isNotEmpty) question.examTermLabel.trim(),
      if (originalNumber.isNotEmpty) '$originalNumber번',
    ];
    if (parts.isEmpty) return '-';
    return parts.join(', ');
  }

  Widget _buildModeChip(
    String mode, {
    required _CardPalette color,
    required bool isOriginal,
    required bool isSelected,
  }) {
    final label = questionModeLabelOf(mode);
    final enabled = onModeSelected != null && !paperStyle;
    final bg = isOriginal ? color.badgeBg : Colors.transparent;
    final borderColor = isSelected
        ? color.accent
        : (isOriginal ? color.badgeBorder : color.metaChipBorder);
    final textColor = isOriginal ? color.badgeText : color.textMuted;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: enabled ? () => onModeSelected?.call(mode) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isSelected) ...[
                Icon(
                  Icons.check_rounded,
                  size: 13,
                  color: isOriginal ? color.badgeText : color.accent,
                ),
                const SizedBox(width: 3),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardPalette {
  const _CardPalette({
    required this.cardBg,
    required this.border,
    required this.divider,
    required this.textPrimary,
    required this.textMuted,
    required this.badgeBg,
    required this.badgeBorder,
    required this.badgeText,
    required this.metaChipBg,
    required this.metaChipBorder,
    required this.checkBorder,
    required this.accent,
    required this.boxShadow,
  });

  final Color cardBg;
  final Color border;
  final Color divider;
  final Color textPrimary;
  final Color textMuted;
  final Color badgeBg;
  final Color badgeBorder;
  final Color badgeText;
  final Color metaChipBg;
  final Color metaChipBorder;
  final Color checkBorder;
  final Color accent;
  final List<BoxShadow> boxShadow;
}

_CardPalette _palette({
  required bool paperStyle,
  required bool selected,
}) {
  if (paperStyle) {
    return _CardPalette(
      cardBg: Colors.white,
      border: selected ? const Color(0xFF9EC5AF) : const Color(0xFFE0E0E0),
      divider: const Color(0xFFEDEDED),
      textPrimary: const Color(0xFF232323),
      textMuted: const Color(0xFF66727A),
      badgeBg: const Color(0xFFE8F1EC),
      badgeBorder: const Color(0xFFC8DDD0),
      badgeText: const Color(0xFF2F6D4E),
      metaChipBg: const Color(0xFFF6F6F6),
      metaChipBorder: const Color(0xFFE7E7E7),
      checkBorder: const Color(0xFF9E9E9E),
      accent: const Color(0xFF1B6B63),
      boxShadow: const [
        BoxShadow(
          color: Color(0x11000000),
          blurRadius: 8,
          offset: Offset(0, 3),
        ),
      ],
    );
  }
  return _CardPalette(
    cardBg: selected ? const Color(0xFF1B272A) : const Color(0xFF10171A),
    border: selected ? const Color(0xFF2F786B) : const Color(0xFF223131),
    divider: const Color(0xFF223131),
    textPrimary: const Color(0xFFEAF2F2),
    textMuted: const Color(0xFF9FB3B3),
    badgeBg: const Color(0xFF173C36),
    badgeBorder: const Color(0xFF2B6B61),
    badgeText: const Color(0xFFBEE7D2),
    metaChipBg: const Color(0xFF151E24),
    metaChipBorder: const Color(0xFF223131),
    checkBorder: const Color(0xFF5C7272),
    accent: const Color(0xFF1B6B63),
    boxShadow: const [],
  );
}
