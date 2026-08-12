import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/screens/class_content/homework_created_date.dart';
import 'package:mneme_flutter/utils/textbook_problem_source_order.dart';

void main() {
  test('그룹 과제 생성일은 자식 수행일과 무관하게 가장 이른 생성일이다', () {
    final createdAt = earliestHomeworkCreatedAt([
      DateTime(2026, 8, 12, 18),
      DateTime(2026, 8, 10, 9),
      null,
      DateTime(2026, 8, 11, 14),
    ]);

    expect(createdAt, DateTime(2026, 8, 10, 9));
    expect(homeworkCreatedDateLabel(createdAt), '08.10');
  });

  test('개념확인 코너는 숫자 문항 여부보다 원본 sub_key 순서를 따른다', () {
    const conceptCheck = TextbookProblemSourceOrderKey(
      subKey: 'A',
      page: 20,
      problemNumber: '개념확인',
    );
    const numberedType = TextbookProblemSourceOrderKey(
      subKey: 'B',
      page: 20,
      problemNumber: '1',
    );

    expect(
      compareTextbookProblemSourceOrder(conceptCheck, numberedType),
      lessThan(0),
    );
  });

  test('페이지-문항 표시는 문자열이 아닌 자연수 순서로 정렬된다', () {
    final values = ['5', '4', '10', '3', '2', '1'];

    values.sort(compareTextbookProblemNumbers);

    expect(values, ['1', '2', '3', '4', '5', '10']);
  });

  test('같은 코너가 반복되면 블록 순서 뒤에 페이지 순서를 적용한다', () {
    const firstBlock = TextbookProblemSourceOrderKey(
      subIndex: 0,
      subKey: 'A',
      page: 25,
      problemNumber: '5',
    );
    const secondBlock = TextbookProblemSourceOrderKey(
      subIndex: 1,
      subKey: 'A',
      page: 26,
      problemNumber: '1',
    );

    expect(
      compareTextbookProblemSourceOrder(firstBlock, secondBlock),
      lessThan(0),
    );
  });

  test('PLWV3578처럼 저장 순서가 역순이어도 원본 코너와 문항 순서로 복원한다', () {
    final stored = [
      const TextbookProblemSourceOrderKey(
        subKey: 'C',
        page: 69,
        problemNumber: '69-5',
      ),
      const TextbookProblemSourceOrderKey(
        subKey: 'C',
        page: 69,
        problemNumber: '69-4',
      ),
      const TextbookProblemSourceOrderKey(
        subKey: 'C',
        page: 69,
        problemNumber: '69-1',
      ),
      const TextbookProblemSourceOrderKey(
        subKey: 'A',
        page: 67,
        problemNumber: '개념확인67',
      ),
    ];

    stored.sort(compareTextbookProblemSourceOrder);

    expect(stored.first.subKey, 'A');
    expect(
      stored
          .where((item) => item.subKey == 'C')
          .map((item) => item.problemNumber),
      ['69-1', '69-4', '69-5'],
    );
  });

  test('같은 페이지에서는 문항번호 숫자보다 교재 원본 코너 순서를 유지한다', () {
    final page67 = [
      const TextbookProblemSourceOrderKey(
        subKey: 'B',
        page: 67,
        problemNumber: '2',
      ),
      const TextbookProblemSourceOrderKey(
        subKey: 'A',
        page: 67,
        problemNumber: '개념확인67',
      ),
    ]..sort(compareTextbookProblemSourceOrder);

    expect(
      page67.map((item) => item.problemNumber),
      ['개념확인67', '2'],
    );
  });
}
