import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/app_overlays.dart';
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

    test('abandoned is persisted but excluded from retry', () {
      expect(
        encodeHomeworkGradingStoredState(HomeworkAnswerCellState.abandoned),
        'abandoned',
      );
      expect(
        decodeHomeworkGradingUiState('abandoned'),
        HomeworkAnswerCellState.abandoned,
      );
      expect(
        isHomeworkGradingRetryState(HomeworkAnswerCellState.abandoned),
        isFalse,
      );
      expect(
        homeworkGradingIncorrectKind(HomeworkAnswerCellState.abandoned),
        isNull,
      );
    });
  });

  group('migrated homework smart confirm', () {
    test('blocks completion when every question is abandoned', () {
      expect(
        resolveMigratedHomeworkGradingAction(
          effectiveCount: 0,
          remainingCount: 0,
        ),
        isNull,
      );
    });

    test('completes only when no effective question remains unresolved', () {
      expect(
        resolveMigratedHomeworkGradingAction(
          effectiveCount: 8,
          remainingCount: 0,
        ),
        'complete',
      );
      expect(
        resolveMigratedHomeworkGradingAction(
          effectiveCount: 8,
          remainingCount: 1,
        ),
        'confirm',
      );
    });
  });
}
