import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/screens/resources/exam_preset_support.dart';
import 'package:mneme_flutter/services/mock_exam_resource_service.dart';

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

  test('2020년 이전 가형·나형 카드 라벨과 제목을 표시한다', () {
    const ga = MockExamResourceCard(
      examId: 'exam-2020-3',
      grade: 3,
      examYear: 2020,
      month: 3,
      org: 'edu',
      elective: 'ga',
      paperId: 'p-ga',
      storageBucket: 'problem-documents',
      storagePath: 'mock/ga.pdf',
      extracted: false,
    );
    const na = MockExamResourceCard(
      examId: 'exam-2020-11',
      grade: 3,
      examYear: 2020,
      month: 11,
      org: 'csat',
      elective: 'na',
      paperId: 'p-na',
      storageBucket: 'problem-documents',
      storagePath: 'mock/na.pdf',
      extracted: false,
    );
    expect(ga.line1, '20 3월 교육청');
    expect(ga.line2, '가형');
    expect(ga.title, '2020 고3 3월 교육청 (가형)');
    expect(na.line1, '20 11월 수능');
    expect(na.line2, '나형');
    expect(na.title, '2020 고3 11월 수능 (나형)');
  });
}
