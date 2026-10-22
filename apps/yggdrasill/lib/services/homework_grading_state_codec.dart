import '../widgets/pdf/homework_answer_viewer_dialog.dart';

String encodeHomeworkGradingUiState(HomeworkAnswerCellState state) {
  switch (state) {
    case HomeworkAnswerCellState.correct:
      return 'correct';
    case HomeworkAnswerCellState.wrong:
      return 'wrong';
    case HomeworkAnswerCellState.blank:
      return 'blank';
    case HomeworkAnswerCellState.notPerformed:
      return 'not_performed';
    case HomeworkAnswerCellState.abandoned:
      return 'abandoned';
  }
}

HomeworkAnswerCellState decodeHomeworkGradingUiState(
  String? raw, {
  String? incorrectKind,
}) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'wrong':
      return (incorrectKind ?? '').trim().toLowerCase() == 'blank'
          ? HomeworkAnswerCellState.blank
          : HomeworkAnswerCellState.wrong;
    case 'blank':
    case 'unsolved':
      // Legacy unsolved represented a blank answer, not non-performance.
      return HomeworkAnswerCellState.blank;
    case 'not_performed':
      return HomeworkAnswerCellState.notPerformed;
    case 'abandoned':
      return HomeworkAnswerCellState.abandoned;
    case 'correct':
    default:
      return HomeworkAnswerCellState.correct;
  }
}

String encodeHomeworkGradingStoredState(HomeworkAnswerCellState state) {
  switch (state) {
    case HomeworkAnswerCellState.correct:
      return 'correct';
    case HomeworkAnswerCellState.wrong:
    case HomeworkAnswerCellState.blank:
      return 'wrong';
    case HomeworkAnswerCellState.notPerformed:
      return 'not_performed';
    case HomeworkAnswerCellState.abandoned:
      return 'abandoned';
  }
}

String? homeworkGradingIncorrectKind(HomeworkAnswerCellState state) {
  switch (state) {
    case HomeworkAnswerCellState.wrong:
      return 'answered';
    case HomeworkAnswerCellState.blank:
      return 'blank';
    case HomeworkAnswerCellState.correct:
    case HomeworkAnswerCellState.notPerformed:
    case HomeworkAnswerCellState.abandoned:
      return null;
  }
}

bool isHomeworkGradingRetryState(HomeworkAnswerCellState state) {
  return state != HomeworkAnswerCellState.correct &&
      state != HomeworkAnswerCellState.abandoned;
}

/// 오답·빈칸만 다음 정답에서 수정으로 남긴다.
/// 미수행은 다시 채점할 문항이지만, 그 뒤 맞춘 것은 그 문항의 첫 채점이다.
bool isHomeworkGradingCorrectionBaseline(HomeworkAnswerCellState? state) {
  return state == HomeworkAnswerCellState.wrong ||
      state == HomeworkAnswerCellState.blank;
}
