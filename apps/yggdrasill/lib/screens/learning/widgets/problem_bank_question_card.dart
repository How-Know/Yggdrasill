import 'package:flutter/material.dart';

import '../../../services/learning_problem_bank_service.dart';
import 'problem_bank_manager_preview_paper.dart';

class ProblemBankQuestionCard extends StatelessWidget {
  const ProblemBankQuestionCard({
    super.key,
    required this.question,
    required this.selected,
    required this.onSelectedChanged,
    this.figureUrlsByPath = const <String, String>{},
    this.showSelectionControl = true,
    this.paperStyle = false,
  });

  final LearningProblemQuestion question;
  final bool selected;
  final ValueChanged<bool> onSelectedChanged;
  final Map<String, String> figureUrlsByPath;
  final bool showSelectionControl;
  final bool paperStyle;

  @override
  Widget build(BuildContext context) {
    final color = _palette(paperStyle: paperStyle, selected: selected);
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
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color:
                            paperStyle ? Colors.white : const Color(0xFF0E1518),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: paperStyle
                              ? const Color(0xFFD5D5D5)
                              : const Color(0xFF223131),
                        ),
                      ),
                      padding: const EdgeInsets.all(8.5),
                      child: ProblemBankManagerPreviewPaper(
                        question: question,
                        figureUrlsByPath: figureUrlsByPath,
                        expanded: false,
                        scrollable: true,
                        bordered: true,
                        shadow: true,
                        showQuestionNumberPrefix: false,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (question.schoolName.isNotEmpty)
                        _metaChip('학교: ${question.schoolName}', color),
                      if (question.examYear != null)
                        _metaChip('년도: ${question.examYear}', color),
                      if (question.gradeLabel.isNotEmpty)
                        _metaChip('학년: ${question.gradeLabel}', color),
                      if (question.semesterLabel.isNotEmpty)
                        _metaChip('학기: ${question.semesterLabel}', color),
                      if (question.examTermLabel.isNotEmpty)
                        _metaChip('시험: ${question.examTermLabel}', color),
                      if (question.documentSourceName.isNotEmpty)
                        _metaChip('문서: ${question.documentSourceName}', color),
                      if (question.sourcePage > 0)
                        _metaChip('페이지: ${question.sourcePage}', color),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(_CardPalette color) {
    final typeLabel = _questionTypeLabel(question.questionType);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Row(
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
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: color.badgeBg,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: color.badgeBorder),
            ),
            child: Text(
              typeLabel,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color.badgeText,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metaChip(String label, _CardPalette color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.metaChipBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.metaChipBorder),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String _questionTypeLabel(String value) {
    if (value == 'objective') return '객관식';
    if (value == 'subjective') return '주관식';
    if (value == 'essay') return '서술형';
    return value.isEmpty ? '유형 미정' : value;
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
