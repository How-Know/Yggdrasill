import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/screens/learning/models/problem_bank_export_models.dart';
import 'package:mneme_flutter/services/learning_problem_bank_service.dart';

void main() {
  test('RenderConfig 표준 키를 포함한다', () {
    final settings = LearningProblemExportSettings.initial();
    final config = settings.toRenderConfig(
      selectedQuestionUidsOrdered: const ['q1', 'q2'],
      questionModeByQuestionUid: const {
        'q1': kLearningQuestionModeObjective,
        'q2': kLearningQuestionModeSubjective,
      },
    );
    expect(config['renderConfigVersion'], kLearningRenderConfigVersion);
    expect(config.containsKey('layoutTuning'), isTrue);
    expect(config.containsKey('figureQuality'), isTrue);
    expect(config.containsKey('questionModeByQuestionId'), isTrue);
    expect(config.containsKey('selectedQuestionIdsOrdered'), isTrue);
  });

  test('render hash는 동일 설정에서 안정적이다', () {
    final settings = LearningProblemExportSettings.initial();
    final hashA = buildLearningRenderHash(
      settings: settings,
      selectedQuestionUidsOrdered: const ['q1', 'q2'],
      questionModeByQuestionUid: const {
        'q2': kLearningQuestionModeSubjective,
        'q1': kLearningQuestionModeObjective,
      },
    );
    final hashB = buildLearningRenderHash(
      settings: settings,
      selectedQuestionUidsOrdered: const ['q1', 'q2'],
      questionModeByQuestionUid: const {
        'q1': kLearningQuestionModeObjective,
        'q2': kLearningQuestionModeSubjective,
      },
    );
    expect(hashA, hashB);
  });

  test('원본 주관식은 AI 객관식 보기가 있어도 원본 모드가 유지된다', () {
    final question = LearningProblemQuestion.fromMap(
      const <String, dynamic>{
        'id': 'q1',
        'question_uid': 'uid1',
        'question_type': '주관식',
        'allow_objective': true,
        'allow_subjective': true,
        'objective_choices': <Map<String, String>>[
          <String, String>{'label': '①', 'text': '오답'},
          <String, String>{'label': '②', 'text': '정답'},
        ],
        'objective_answer_key': '②',
        'subjective_answer': '42',
      },
      documentSourceName: '내신 기출',
    );

    expect(originalQuestionModeOf(question), kLearningQuestionModeSubjective);
    expect(
      previewAnswerForMode(question, kLearningQuestionModeOriginal),
      '42',
    );
  });

  test('내신 원본 강제와 일반 과제의 명시적 선택 모드를 분리한다', () {
    final question = LearningProblemQuestion.fromMap(
      const <String, dynamic>{
        'id': 'q1',
        'question_uid': 'uid1',
        'question_type': '주관식',
        'allow_objective': true,
        'allow_subjective': true,
        'objective_choices': <Map<String, String>>[
          <String, String>{'label': '①', 'text': '오답'},
          <String, String>{'label': '②', 'text': '정답'},
        ],
      },
      documentSourceName: '내신 기출',
    );
    const selectedModes = <String, String>{
      'uid1': kLearningQuestionModeObjective,
    };

    expect(
      effectiveQuestionModeOf(
        question,
        questionModeByQuestionUid: selectedModes,
        fallbackMode: kLearningQuestionModeOriginal,
      ),
      kLearningQuestionModeObjective,
    );
    expect(
      effectiveQuestionModeOf(
        question,
        questionModeByQuestionUid: selectedModes,
        fallbackMode: kLearningQuestionModeOriginal,
        forceOriginalMode: true,
      ),
      kLearningQuestionModeSubjective,
    );
  });
}
