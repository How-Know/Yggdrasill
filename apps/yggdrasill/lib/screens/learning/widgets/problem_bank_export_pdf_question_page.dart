import 'package:flutter/material.dart';

import '../../../services/learning_problem_bank_service.dart';
import '../models/problem_bank_export_models.dart';
import 'problem_bank_manager_preview_paper.dart';

class ProblemBankExportPdfQuestionPage extends StatelessWidget {
  const ProblemBankExportPdfQuestionPage({
    super.key,
    required this.page,
    required this.settings,
    required this.figureUrlsByQuestionId,
    required this.questionModeByQuestionUid,
  });

  final LearningProblemLayoutPreviewPage page;
  final LearningProblemExportSettings settings;
  final Map<String, Map<String, String>> figureUrlsByQuestionId;
  final Map<String, String> questionModeByQuestionUid;

  @override
  Widget build(BuildContext context) {
    final columns = settings.layoutColumnCount;
    final rowCount = page.rowCount > 0 ? page.rowCount : 1;
    final leftSlots = page.leftColumnSlots;
    final rightSlots = page.rightColumnSlots;

    return Container(
      color: Colors.white,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const exactGap = 0.0;
          final resolvedSlotHeight = rowCount > 0
              ? ((constraints.maxHeight - exactGap * (rowCount - 1)) / rowCount)
              : constraints.maxHeight;
          final safeSlotHeight =
              resolvedSlotHeight.isFinite && resolvedSlotHeight > 0
                  ? resolvedSlotHeight
                  : constraints.maxHeight / rowCount;

          if (columns == 1) {
            return Column(
              children: _buildQuestionSlotColumnWidgets(
                leftSlots,
                rowCount: rowCount,
                baseSlotHeight: safeSlotHeight,
                slotGap: exactGap,
              ),
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  children: _buildQuestionSlotColumnWidgets(
                    leftSlots,
                    rowCount: rowCount,
                    baseSlotHeight: safeSlotHeight,
                    slotGap: exactGap,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  children: _buildQuestionSlotColumnWidgets(
                    rightSlots,
                    rowCount: rowCount,
                    baseSlotHeight: safeSlotHeight,
                    slotGap: exactGap,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _buildQuestionSlotColumnWidgets(
    List<LearningProblemLayoutSlot> slots, {
    required int rowCount,
    required double baseSlotHeight,
    required double slotGap,
  }) {
    final children = <Widget>[];
    var row = 0;
    while (row < rowCount) {
      final slot = row < slots.length
          ? slots[row]
          : const LearningProblemLayoutSlot.empty();
      if (slot.hidden) {
        row += 1;
        continue;
      }
      final maxSpan = rowCount - row;
      final useSpan =
          slot.question == null ? 1 : slot.span.clamp(1, maxSpan).toInt();
      final slotHeight = baseSlotHeight * useSpan + slotGap * (useSpan - 1);
      children.add(
        SizedBox(
          height: slotHeight,
          child: _buildQuestionSlotPreview(
            slot.question,
            slotHeight: slotHeight,
          ),
        ),
      );
      row += useSpan;
      if (row < rowCount && slotGap > 0) {
        children.add(SizedBox(height: slotGap));
      }
    }
    return children;
  }

  Widget _buildQuestionSlotPreview(
    LearningProblemQuestion? question, {
    required double slotHeight,
  }) {
    if (question == null) {
      return const SizedBox.expand(child: ColoredBox(color: Colors.white));
    }
    final mode = effectiveQuestionModeOf(
      question,
      questionModeByQuestionUid: questionModeByQuestionUid,
      fallbackMode: settings.questionModeValue,
    );
    final previewQuestion = questionForLayoutPreviewMode(
      question,
      mode,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final slotWidth =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
        final naturalHeight = slotHeight + 24;
        return ClipRect(
          child: FittedBox(
            fit: BoxFit.contain,
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: slotWidth,
              height: naturalHeight,
              child: ProblemBankManagerPreviewPaper(
                question: previewQuestion,
                figureUrlsByPath: figureUrlsByQuestionId[question.id] ??
                    const <String, String>{},
                expanded: true,
                scrollable: false,
                bordered: false,
                shadow: false,
                showQuestionNumberPrefix: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              ),
            ),
          ),
        );
      },
    );
  }
}
