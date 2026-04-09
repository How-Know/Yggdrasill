import 'package:flutter/material.dart';

import '../../../services/learning_problem_bank_service.dart';
import '../models/problem_bank_export_models.dart';
import 'problem_bank_export_layout_page.dart';

class ProblemBankExportLayoutPreviewDialog extends StatelessWidget {
  const ProblemBankExportLayoutPreviewDialog({
    super.key,
    required this.selectedQuestions,
    required this.settings,
    required this.figureUrlsByQuestionId,
    required this.questionModeByQuestionUid,
  });

  final List<LearningProblemQuestion> selectedQuestions;
  final LearningProblemExportSettings settings;
  final Map<String, Map<String, String>> figureUrlsByQuestionId;
  final Map<String, String> questionModeByQuestionUid;

  static const _panel = Color(0xFF10171A);
  static const _field = Color(0xFF151C21);
  static const _border = Color(0xFF223131);
  static const _text = Color(0xFFEAF2F2);
  static const _textSub = Color(0xFF9FB3B3);

  static Future<void> open(
    BuildContext context, {
    required List<LearningProblemQuestion> selectedQuestions,
    required LearningProblemExportSettings settings,
    required Map<String, Map<String, String>> figureUrlsByQuestionId,
    required Map<String, String> questionModeByQuestionUid,
  }) async {
    final size = MediaQuery.sizeOf(context);
    final maxWidth = (size.width - 48).clamp(980.0, 1480.0).toDouble();
    final maxHeight = (size.height - 44).clamp(640.0, 1000.0).toDouble();
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: _panel,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: maxHeight,
              minWidth: 780,
              minHeight: 560,
            ),
            child: ProblemBankExportLayoutPreviewDialog(
              selectedQuestions: selectedQuestions,
              settings: settings,
              figureUrlsByQuestionId: figureUrlsByQuestionId,
              questionModeByQuestionUid: questionModeByQuestionUid,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = buildQuestionLayoutPreviewPages(
      selectedQuestions,
      settings: settings,
      questionModeByQuestionUid: questionModeByQuestionUid,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '레이아웃 미리보기',
                style: TextStyle(
                  color: _text,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '닫기',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: _textSub),
              ),
            ],
          ),
          Text(
            '양식=${settings.templateLabel} · 용지=${settings.paperLabel} · '
            '출제형식=문항별 선택 · 단=${settings.layoutColumnCount} · '
            '최대 ${settings.maxQuestionsPerPageCount}문항/페이지 · 선택 ${selectedQuestions.length}문항',
            style: const TextStyle(color: _textSub, fontSize: 11.8),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView(
              children: [
                for (var i = 0; i < pages.length; i += 1) ...[
                  ProblemBankExportLayoutPage(
                    pageIndex: i + 1,
                    page: pages[i],
                    settings: settings,
                    figureUrlsByQuestionId: figureUrlsByQuestionId,
                    questionModeByQuestionUid: questionModeByQuestionUid,
                  ),
                  const SizedBox(height: 12),
                ],
                if (settings.includeAnswerSheet) ...[
                  _buildAnswerSheetLayoutPreview(
                    questions: selectedQuestions,
                    pageIndex: pages.length + 1,
                  ),
                  const SizedBox(height: 12),
                ],
                if (settings.includeExplanation)
                  _buildExplanationLayoutPreview(
                    questions: selectedQuestions,
                    pageIndex:
                        pages.length + (settings.includeAnswerSheet ? 2 : 1),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnswerSheetLayoutPreview({
    required List<LearningProblemQuestion> questions,
    required int pageIndex,
  }) {
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
            '정답지 p.$pageIndex',
            style: const TextStyle(
              color: _textSub,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFFFCFCFC),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFD5D5D5)),
            ),
            padding: const EdgeInsets.all(10),
            child: Wrap(
              spacing: 12,
              runSpacing: 7,
              children: questions.map((q) {
                final mode = effectiveQuestionModeOf(
                  q,
                  questionModeByQuestionUid: questionModeByQuestionUid,
                  fallbackMode: settings.questionModeValue,
                );
                final ans = previewAnswerForMode(q, mode);
                return SizedBox(
                  width: 172,
                  child: _buildNumberedWrappedText(
                    numberText: '${q.displayQuestionNumber}.',
                    valueText: ans.isEmpty ? '-' : ans,
                    textStyle: const TextStyle(
                      color: Color(0xFF2D2D2D),
                      fontSize: 11.5,
                      height: 1.34,
                    ),
                  ),
                );
              }).toList(growable: false),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExplanationLayoutPreview({
    required List<LearningProblemQuestion> questions,
    required int pageIndex,
  }) {
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
            '해설 p.$pageIndex',
            style: const TextStyle(
              color: _textSub,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFFFCFCFC),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFD5D5D5)),
            ),
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < questions.length; i += 1) ...[
                  Builder(
                    builder: (context) {
                      final summarized = _ellipsize(
                        explanationForPreview(questions[i]),
                        max: 160,
                      );
                      return _buildNumberedWrappedText(
                        numberText: '${questions[i].displayQuestionNumber}.',
                        valueText: summarized.isEmpty ? '해설/메모 없음' : summarized,
                        textStyle: const TextStyle(
                          color: Color(0xFF2D2D2D),
                          fontSize: 11.5,
                          height: 1.34,
                        ),
                      );
                    },
                  ),
                  if (i < questions.length - 1) const SizedBox(height: 4),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _ellipsize(String raw, {int max = 94}) {
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length <= max) return text;
    return '${text.substring(0, max)}...';
  }

  Widget _buildNumberedWrappedText({
    required String numberText,
    required String valueText,
    required TextStyle textStyle,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 30,
          child: Text(numberText, style: textStyle),
        ),
        Expanded(
          child: Text(valueText, style: textStyle),
        ),
      ],
    );
  }
}
