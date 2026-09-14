import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_pb_export_ui/yggdrasill_pb_export_ui.dart';

void main() {
  test('public DTO and print callback remain consumable', () {
    const request = ProblemBankPreviewRefreshRequest(
      subjectTitleText: '수학 영역',
      titlePageTopText: '문제지',
      titlePageGoalText: '다시 풀기',
      timeLimitText: '50분',
      pageColumnQuestionCounts: <Map<String, dynamic>>[],
      columnLabelAnchors: <Map<String, dynamic>>[],
      titlePageIndices: <int>[],
      titlePageHeaders: <Map<String, dynamic>>[],
      coverPageTexts: <String, dynamic>{},
      includeAcademyLogo: true,
      includeCoverPage: false,
      includeAnswerSheet: false,
      includeExplanation: false,
      includeQuestionScore: false,
      questionScoreByQuestionId: <String, double>{},
    );

    final copied = request.copyWith(timeLimitText: '60분');
    expect(copied.timeLimitText, '60분');

    Future<bool> printFile(String _) async => true;
    final widget = ProblemBankExportServerPreviewDialog(
      pdfUrl: 'https://example.com/preview.pdf',
      titleText: '미리보기',
      expandedDialogSize: const Size(800, 600),
      onPrintRequested: printFile,
    );
    expect(widget.onPrintRequested, isNotNull);
  });
}
