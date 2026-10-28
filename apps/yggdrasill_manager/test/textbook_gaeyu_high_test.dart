import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/textbook/textbook_authoring_stage_dialog.dart';
import 'package:yggdrasill_manager/screens/textbook/textbook_toc_autofill.dart';
import 'package:yggdrasill_manager/services/textbook_series_catalog.dart';
import 'package:yggdrasill_manager/services/textbook_vlm_answer_service.dart';
import 'package:yggdrasill_manager/services/textbook_vlm_test_service.dart';

void main() {
  test('개념+유형 고등 프로필은 소단원 행에 A~D 네 코너를 쓴다', () {
    final entry = textbookSeriesByKey('gaeyu_high');
    expect(entry, isNotNull);
    expect(entry!.hasSubUnitRows, isTrue);
    expect(entry.unitEndRowName, isEmpty);
    expect(
      entry.subPreset.map((preset) => preset.key).toList(),
      <String>['A', 'B', 'C', 'D'],
    );
    // 정답 PDF 가 없어 해설 PDF 에서 정답까지 읽는다.
    expect(textbookSeriesAnswersFromSolutionPdf('gaeyu_high'), isTrue);
    expect(textbookSeriesAnswersFromSolutionPdf('wonri_middle'), isTrue);
    expect(textbookSeriesAnswersFromSolutionPdf('gaeyu'), isFalse);
  });

  test('탐지 응답의 고등 코너와 연습문제 라벨이 앱 모델에 그대로 남는다', () {
    for (final category in <String>[
      'high_concept_check',
      'high_example',
      'high_problem',
      'high_exercise',
    ]) {
      final item = TextbookVlmItem.fromMap(<String, dynamic>{
        'number': category == 'high_problem' ? '01-1' : '1',
        'category': category,
        'label': category == 'high_exercise' ? '실력+교육청' : '',
        'bbox': <int>[10, 10, 20, 20],
        'item_region': <int>[20, 10, 80, 400],
      });
      expect(item.category, category);
      expect(item.isSetHeader, isFalse);
      if (category == 'high_exercise') expect(item.label, '실력+교육청');
    }
  });

  test('목차의 연습문제 줄은 따로 행을 세우지 않는다', () {
    const toc = TextbookTocParseResult(
      notes: '',
      bigUnits: <TextbookTocBigUnit>[
        TextbookTocBigUnit(
          name: 'I 다항식',
          midUnits: <TextbookTocMidUnit>[
            TextbookTocMidUnit(
              name: '01 다항식의 연산',
              page: 8,
              hasExercise: true,
              subUnits: <TextbookTocSubUnit>[
                TextbookTocSubUnit(name: '1 다항식의 덧셈과 뺄셈', page: 8),
                TextbookTocSubUnit(name: '2 다항식의 곱셈', page: 30),
                TextbookTocSubUnit(name: '연습문제', page: 40, isExercise: true),
              ],
            ),
          ],
        ),
      ],
    );
    final tree = buildTocAutofillTree(
      toc,
      subUnitRows: true,
      seriesKey: 'gaeyu_high',
    );
    final subs = tree.single.midUnits.single.subUnits;
    expect(subs.map((sub) => sub.name).toList(), <String>[
      '다항식의 덧셈과 뺄셈',
      '다항식의 곱셈',
    ]);
    expect(subs.any((sub) => sub.isExercise), isFalse);
  });

  test('해설 기대 키: 개념 Check 는 블록 쪽 접두어를 떼고 상자 쪽으로 짚는다', () {
    expect(textbookAnswerNeedsCorner('gaeyu_high'), isTrue);

    final check = textbookExpectedAnswerFor(
      seriesKey: 'gaeyu_high',
      problemNumber: '8-2',
      section: 'high_concept_check',
      subKey: 'A',
      // 블록이 8~9쪽에 걸쳐 이 문항은 9쪽에 인쇄돼도 상자는 "개념 Check 8쪽".
      displayPage: 9,
    );
    expect(check.number, '2');
    expect(check.corner, '개념 Check');
    expect(check.bodyPage, 8);

    final problem = textbookExpectedAnswerFor(
      seriesKey: 'gaeyu_high',
      problemNumber: '01-2',
      section: 'high_problem',
      subKey: 'C',
      displayPage: 9,
    );
    expect(problem.number, '01-2');
    expect(problem.corner, '문제');
    expect(problem.bodyPage, 9);

    final exercise = textbookExpectedAnswerFor(
      seriesKey: 'gaeyu_high',
      problemNumber: '12',
      section: 'unknown',
      subKey: 'D',
      displayPage: 27,
    );
    expect(exercise.corner, '연습문제');
    expect(exercise.bodyPage, 27);
  });

  test('Stage 크롭 조회는 A~D 모두 소단원 sub_index 로 격리한다', () {
    for (final subKey in <String>['A', 'B', 'C', 'D']) {
      expect(
        textbookStageCropSubIndexForScope(
          'gaeyu_high',
          TextbookAuthoringStageScope(
            bigOrder: 0,
            midOrder: 0,
            subKey: subKey,
            unitRowIndex: 2,
          ),
        ),
        2,
        reason: subKey,
      );
    }
  });
}
