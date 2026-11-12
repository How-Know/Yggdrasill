import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/textbook_problem_review_service.dart';

void main() {
  const choices = [
    {'label': '①', 'text': '1'},
    {'label': '②', 'text': '2'},
    {'label': '③', 'text': '3'},
    {'label': '④', 'text': '11'},
    {'label': '⑤', 'text': '63'},
  ];

  TextbookProblemReviewItem item({
    String stem = '',
    String answer = '⑤',
    List<Map<String, String>> rawChoices = choices,
    String questionType = '객관식',
    bool allowObjective = true,
    bool allowSubjective = true,
    String objectiveKey = '',
    String subjectiveAnswer = '63',
    List<Map<String, String>> objectiveChoices = const [],
  }) =>
      TextbookProblemReviewItem.fromJson({
        'crop_id': 'c1',
        'pb_question_id': 'q1',
        'problem_number': '03',
        'stem': stem,
        'existing_answer': answer,
        'choices': rawChoices,
        'objective_choices': objectiveChoices,
        'question_type': questionType,
        'pb_allow_objective': allowObjective,
        'pb_allow_subjective': allowSubjective,
        'pb_objective_answer_key': objectiveKey,
        'pb_subjective_answer': subjectiveAnswer,
        'math_status': 'approved',
      });

  test('객관식 정답 키가 비어 있으면 문제은행 정답 다름이고 준비됨을 막는다', () {
    final it = item(stem: '다음 중 합성수인 것은?');
    expect(it.pbAnswerDiffers, isTrue);
    expect(it.readyBlockers, contains('문제은행 정답 다름'));
    expect(item(stem: '다음 중 합성수인 것은?', objectiveKey: '⑤').pbAnswerDiffers, isFalse);
  });

  test('주관식 문항에 AI 가 만든 객관식 정답 키는 채점 정답과 비교하지 않는다', () {
    final it = item(
      stem: '12의 약수의 개수를 구하여라.',
      answer: '6',
      rawChoices: const [],
      questionType: '주관식',
      objectiveKey: '③',
      subjectiveAnswer: '6',
      objectiveChoices: choices,
    );
    expect(it.pbAnswerDiffers, isFalse);
    expect(it.needsObjectiveGeneration, isFalse);
  });

  test('주관식 문항에 객관식 보기가 없으면 생성 대상이다', () {
    final it = item(stem: '12의 약수의 개수를 구하여라.', answer: '6', rawChoices: const [], questionType: '주관식', subjectiveAnswer: '6');
    expect(it.needsObjectiveGeneration, isTrue);
  });

  test('선지를 가리키는 발문이나 답이 여러 개면 주관식 겸용이 아니다', () {
    expect(item(stem: '다음 중 합성수인 것은?').subjectiveAlsoPossible, isFalse);
    expect(item(stem: '옳지 않은 것은?').subjectiveAlsoPossible, isFalse);
    expect(item(stem: '63을 소인수분해했을 때 가장 큰 소인수는?', answer: '①, ⑤').subjectiveAlsoPossible, isFalse);
    expect(item(stem: '63을 소인수분해했을 때 가장 큰 소인수의 제곱은?').subjectiveAlsoPossible, isTrue);
  });

  test('ㄱ·ㄴ·ㄷ 조합 선지는 주관식 겸용이 아니다', () {
    final it = item(
      stem: '<보기> 에서 소수를 모두 고른 것은?',
      answer: '②',
      rawChoices: const [
        {'label': '①', 'text': 'ㄱ'},
        {'label': '②', 'text': 'ㄱ, ㄴ'},
      ],
    );
    expect(it.subjectiveAlsoPossible, isFalse);
  });

  test('주관식 겸용 판정과 문제은행 표시가 다르면 유형 수정 대상이다', () {
    expect(item(stem: '다음 중 합성수인 것은?', objectiveKey: '⑤').questionKindMismatch, isTrue);
    expect(item(stem: '다음 중 합성수인 것은?', objectiveKey: '⑤', allowSubjective: false).questionKindMismatch, isFalse);
  });
}
