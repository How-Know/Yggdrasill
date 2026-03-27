import 'package:flutter/material.dart';

import '../../../services/learning_problem_bank_service.dart';
import '../../../widgets/latex_text_renderer.dart';

class ProblemBankQuestionCard extends StatelessWidget {
  const ProblemBankQuestionCard({
    super.key,
    required this.question,
    required this.selected,
    required this.onSelectedChanged,
    this.showSelectionControl = true,
  });

  final LearningProblemQuestion question;
  final bool selected;
  final ValueChanged<bool> onSelectedChanged;
  final bool showSelectionControl;

  static const _cardBg = Colors.white;
  static const _cardBorder = Color(0xFFE3D8C8);
  static const _selectedBorder = Color(0xFF7BAE95);
  static const _selectedBg = Color(0xFFF3FAF6);

  @override
  Widget build(BuildContext context) {
    final borderColor = selected ? _selectedBorder : _cardBorder;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      decoration: BoxDecoration(
        color: selected ? _selectedBg : _cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: selected ? 1.4 : 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x11000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          _buildHeader(context),
          const Divider(height: 1, color: Color(0xFFEDE5D8)),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LatexTextRenderer(
                      question.renderedStem,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF2F2A24),
                        height: 1.45,
                      ),
                    ),
                    if (question.effectiveChoices.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      const Divider(height: 1, color: Color(0xFFEDE5D8)),
                      const SizedBox(height: 8),
                      ...question.effectiveChoices
                          .map((choice) => _buildChoice(choice))
                          .toList(growable: false),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (question.schoolName.isNotEmpty)
                          _metaChip('학교: ${question.schoolName}'),
                        if (question.examYear != null)
                          _metaChip('년도: ${question.examYear}'),
                        if (question.gradeLabel.isNotEmpty)
                          _metaChip('학년: ${question.gradeLabel}'),
                        if (question.semesterLabel.isNotEmpty)
                          _metaChip('학기: ${question.semesterLabel}'),
                        if (question.examTermLabel.isNotEmpty)
                          _metaChip('시험: ${question.examTermLabel}'),
                        if (question.documentSourceName.isNotEmpty)
                          _metaChip('문서: ${question.documentSourceName}'),
                        if (question.sourcePage > 0)
                          _metaChip('페이지: ${question.sourcePage}'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final typeLabel = _questionTypeLabel(question.questionType);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Row(
        children: [
          if (showSelectionControl)
            Checkbox(
              value: selected,
              visualDensity: VisualDensity.compact,
              side: const BorderSide(color: Color(0xFFA7A09A)),
              activeColor: const Color(0xFF6EA68D),
              onChanged: (v) => onSelectedChanged(v ?? false),
            ),
          Expanded(
            child: Text(
              '${question.displayQuestionNumber}번 문항',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: Color(0xFF3B342C),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFFE8F1EC),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0xFFC8DDD0)),
            ),
            child: Text(
              typeLabel,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF2F6D4E),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChoice(LearningProblemChoice choice) {
    final text = question.renderChoiceText(choice);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _choiceLabel(choice.label),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF4C443C),
              height: 1.4,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: LatexTextRenderer(
              text,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF3A352F),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metaChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F1E9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE3D9CA)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF746A5E),
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

  String _choiceLabel(String label) {
    final safe = label.trim();
    if (safe.isEmpty) return '';
    if (safe.endsWith('.')) return '$safe ';
    return '$safe. ';
  }
}
