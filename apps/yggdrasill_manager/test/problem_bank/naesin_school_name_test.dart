import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/problem_bank/naesin_link_school_name.dart';

void main() {
  const middleSchools = <String>[
    '경신중',
    '능인중',
    '대륜중',
    '동도중',
    '소선여중',
    '오성중',
    '정화중',
    '황금중',
  ];
  const highSchools = <String>[
    '경북고',
    '경신고',
    '능인고',
    '대구여고',
    '대륜고',
    '오성고',
    '정화여고',
    '혜화여고',
  ];

  test('문서 학교명을 학습앱 축약형으로 바꾼다', () {
    expect(
      canonicalNaesinSchoolName('황금중학교', canonicalSchools: middleSchools),
      '황금중',
    );
    expect(
      canonicalNaesinSchoolName('동도중학교', canonicalSchools: middleSchools),
      '동도중',
    );
    expect(
      canonicalNaesinSchoolName('소선여중', canonicalSchools: middleSchools),
      '소선여중',
    );
    expect(
      canonicalNaesinSchoolName('대구여자고등학교', canonicalSchools: highSchools),
      '대구여고',
    );
  });

  test('정화중과 소선여중을 구분한다', () {
    expect(
      canonicalNaesinSchoolName('정화중학교', canonicalSchools: middleSchools),
      '정화중',
    );
    expect(
      canonicalNaesinSchoolName('소선여자중학교', canonicalSchools: middleSchools),
      '소선여중',
    );
  });
}
