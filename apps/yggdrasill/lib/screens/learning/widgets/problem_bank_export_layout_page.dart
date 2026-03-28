import 'package:flutter/material.dart';

import '../models/problem_bank_export_models.dart';
import 'problem_bank_export_pdf_question_page.dart';

class ProblemBankExportLayoutPage extends StatelessWidget {
  const ProblemBankExportLayoutPage({
    super.key,
    required this.pageIndex,
    required this.page,
    required this.settings,
    required this.figureUrlsByQuestionId,
    required this.questionModeByQuestionId,
  });

  final int pageIndex;
  final LearningProblemLayoutPreviewPage page;
  final LearningProblemExportSettings settings;
  final Map<String, Map<String, String>> figureUrlsByQuestionId;
  final Map<String, String> questionModeByQuestionId;

  static const _field = Color(0xFF10171A);
  static const _border = Color(0xFF223131);
  static const _textMuted = Color(0xFF9FB3B3);

  @override
  Widget build(BuildContext context) {
    final paperSize = settings.paperPointSize;
    final aspectRatio = paperSize.width / paperSize.height;
    return Container(
      decoration: BoxDecoration(
        color: _field,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '문제지 p.$pageIndex',
            style: const TextStyle(
              color: _textMuted,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: const Color(0xFFD5D5D5)),
              ),
              child: AspectRatio(
                aspectRatio: aspectRatio,
                child: ProblemBankExportPdfQuestionPage(
                  page: page,
                  settings: settings,
                  figureUrlsByQuestionId: figureUrlsByQuestionId,
                  questionModeByQuestionId: questionModeByQuestionId,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
