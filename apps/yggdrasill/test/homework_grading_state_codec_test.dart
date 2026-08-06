import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/services/homework_grading_state_codec.dart';
import 'package:mneme_flutter/widgets/pdf/homework_answer_viewer_dialog.dart';

void main() {
  group('homework grading state codec', () {
    test('legacy unsolved is restored as blank wrong', () {
      expect(
        decodeHomeworkGradingUiState('unsolved'),
        HomeworkAnswerCellState.blank,
      );
      expect(
        encodeHomeworkGradingStoredState(HomeworkAnswerCellState.blank),
        'wrong',
      );
      expect(
        homeworkGradingIncorrectKind(HomeworkAnswerCellState.blank),
        'blank',
      );
    });

    test('answered wrong and blank wrong remain distinguishable', () {
      expect(
        decodeHomeworkGradingUiState(
          'wrong',
          incorrectKind: 'answered',
        ),
        HomeworkAnswerCellState.wrong,
      );
      expect(
        decodeHomeworkGradingUiState(
          'wrong',
          incorrectKind: 'blank',
        ),
        HomeworkAnswerCellState.blank,
      );
    });

    test('not performed remains separate and scores as a retry state', () {
      expect(
        encodeHomeworkGradingStoredState(
          HomeworkAnswerCellState.notPerformed,
        ),
        'not_performed',
      );
      expect(
        decodeHomeworkGradingUiState('not_performed'),
        HomeworkAnswerCellState.notPerformed,
      );
      expect(
        isHomeworkGradingRetryState(HomeworkAnswerCellState.notPerformed),
        isTrue,
      );
      expect(
        homeworkGradingIncorrectKind(HomeworkAnswerCellState.notPerformed),
        isNull,
      );
    });
  });
}
