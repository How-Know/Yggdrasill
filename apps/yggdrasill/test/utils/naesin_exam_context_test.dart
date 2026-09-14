import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/utils/naesin_exam_context.dart';

void main() {
  group('NaesinExamContext.canonicalSchoolName', () {
    test('문서 풀네임을 학습앱 축약형으로 바꾼다', () {
      expect(
        NaesinExamContext.canonicalSchoolName('황금중학교', gradeKey: 'M2'),
        '황금중',
      );
      expect(
        NaesinExamContext.canonicalSchoolName('동도중학교', gradeKey: 'M3'),
        '동도중',
      );
      expect(
        NaesinExamContext.canonicalSchoolName('소선여자중학교', gradeKey: 'M1'),
        '소선여중',
      );
      expect(
        NaesinExamContext.canonicalSchoolName('대구여자고등학교', gradeKey: 'H1'),
        '대구여고',
      );
      expect(
        NaesinExamContext.canonicalSchoolName('경북고등학교', gradeKey: 'H2'),
        '경북고',
      );
    });

    test('이미 축약형이면 그대로 둔다', () {
      expect(
        NaesinExamContext.canonicalSchoolName('황금중', gradeKey: 'M2'),
        '황금중',
      );
    });

    test('정화중과 소선여중을 혼동하지 않는다', () {
      expect(
        NaesinExamContext.canonicalSchoolName('정화중학교', gradeKey: 'M2'),
        '정화중',
      );
      expect(
        NaesinExamContext.canonicalSchoolName('소선여자중학교', gradeKey: 'M2'),
        '소선여중',
      );
      expect(
        NaesinExamContext.canonicalSchoolName('정화여자고등학교', gradeKey: 'H1'),
        '정화여고',
      );
    });
  });

  test('풀네임으로 저장된 링크 키도 파싱 시 축약형으로 맞춘다', () {
    final parsed = NaesinExamContext.parseNaesinLinkKey(
      'M2|M2-2|중간고사|황금중학교|2025',
    );
    expect(parsed?.school, '황금중');
    expect(
      NaesinExamContext.buildNaesinLinkKey(
        gradeKey: 'M2',
        courseKey: 'M2-2',
        examTerm: '중간고사',
        school: '황금중학교',
        year: 2025,
      ),
      'M2|M2-2|중간고사|황금중|2025',
    );
  });
}
