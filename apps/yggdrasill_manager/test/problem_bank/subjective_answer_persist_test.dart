import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/problem_bank/problem_bank_models.dart';

ProblemBankQuestion _question({
  required String id,
  String questionType = '객관식',
  bool allowObjective = true,
  bool allowSubjective = true,
  String objectiveAnswerKey = '',
  String subjectiveAnswer = '',
  List<Map<String, String>> choices = const <Map<String, String>>[],
  Map<String, dynamic>? meta,
}) {
  return ProblemBankQuestion.fromMap(<String, dynamic>{
    'id': id,
    'question_uid': 'uid-$id',
    'question_type': questionType,
    'allow_objective': allowObjective,
    'allow_subjective': allowSubjective,
    'objective_answer_key': objectiveAnswerKey,
    'subjective_answer': subjectiveAnswer,
    'objective_choices': choices,
    'choices': choices,
    'meta': meta ?? const <String, dynamic>{},
  });
}

void main() {
  final choices = <Map<String, String>>[
    <String, String>{'label': '①', 'text': '5'},
    <String, String>{'label': '②', 'text': '13'},
    <String, String>{'label': '③', 'text': '25'},
    <String, String>{'label': '④', 'text': '41'},
    <String, String>{'label': '⑤', 'text': '61'},
  ];

  test('원래 객관식은 주관식 칸이 비면 보기 텍스트를 저장 대상으로 삼는다', () {
    final question = _question(
      id: 'obj-1',
      objectiveAnswerKey: '①',
      choices: choices,
    );

    expect(persistableSubjectiveAnswerOf(question), '5');
    expect(shouldPersistDerivedSubjectiveAnswer(question), isTrue);
  });

  test('주관식 허용이 꺼져 있으면 저장 대상이 아니다', () {
    final question = _question(
      id: 'obj-off',
      allowSubjective: false,
      objectiveAnswerKey: '①',
      choices: choices,
    );

    expect(persistableSubjectiveAnswerOf(question), isEmpty);
    expect(shouldPersistDerivedSubjectiveAnswer(question), isFalse);
  });

  test('이미 보기 텍스트가 메타에 있으면 재저장하지 않는다', () {
    final question = _question(
      id: 'obj-saved',
      objectiveAnswerKey: '①',
      subjectiveAnswer: '5',
      choices: choices,
      meta: const <String, dynamic>{'subjective_answer': '5'},
    );

    expect(persistableSubjectiveAnswerOf(question), '5');
    expect(shouldPersistDerivedSubjectiveAnswer(question), isFalse);
  });

  test('원래 주관식 정답은 그대로 저장 대상으로 쓴다', () {
    final question = _question(
      id: 'sub-1',
      questionType: '주관식',
      allowObjective: false,
      subjectiveAnswer: r'\left(\frac{5}{2}, -\frac{1}{2}\right)',
    );

    expect(
      persistableSubjectiveAnswerOf(question),
      r'\left(\frac{5}{2}, -\frac{1}{2}\right)',
    );
  });
}
