import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/screens/resources/exam_preset_support.dart';

void main() {
  test('모의고사 월 폴더는 그달만 가리킨다', () {
    final month = parseExamFolderSelection(mockExamMonthFolderId('H3', 11));
    expect(month?.gradeKey, 'H3');
    expect(month?.isMock, isTrue);
    expect(month?.month, 11);

    final grade = parseExamFolderSelection('exam-folder-H1-mock');
    expect(grade?.gradeKey, 'H1');
    expect(grade?.isMock, isTrue);
    expect(grade?.month, isNull);

    expect(parseExamFolderSelection('exam-folder-H3-mock-m0'), isNull);
    expect(parseExamFolderSelection('exam-folder-H3-mock-m13'), isNull);
  });
}
