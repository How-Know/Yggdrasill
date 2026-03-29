import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/screens/learning/models/problem_bank_export_models.dart';

void main() {
  test('RenderConfig 표준 키를 포함한다', () {
    final settings = LearningProblemExportSettings.initial();
    final config = settings.toRenderConfig(
      selectedQuestionIdsOrdered: const ['q1', 'q2'],
      questionModeByQuestionId: const {
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
      selectedQuestionIdsOrdered: const ['q1', 'q2'],
      questionModeByQuestionId: const {
        'q2': kLearningQuestionModeSubjective,
        'q1': kLearningQuestionModeObjective,
      },
    );
    final hashB = buildLearningRenderHash(
      settings: settings,
      selectedQuestionIdsOrdered: const ['q1', 'q2'],
      questionModeByQuestionId: const {
        'q1': kLearningQuestionModeObjective,
        'q2': kLearningQuestionModeSubjective,
      },
    );
    expect(hashA, hashB);
  });
}
