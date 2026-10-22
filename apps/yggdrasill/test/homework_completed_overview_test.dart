import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/services/homework_store.dart';
import 'package:mneme_flutter/utils/homework_completed_overview.dart';

HomeworkItem _item({
  required String id,
  HomeworkStatus status = HomeworkStatus.inProgress,
  int phase = 4,
  DateTime? completedAt,
  String? sourceUnitLevel,
  String? content,
  String? type,
}) {
  return HomeworkItem(
    id: id,
    title: '과제',
    body: '',
    status: status,
    phase: phase,
    completedAt: completedAt,
    sourceUnitLevel: sourceUnitLevel,
    content: content,
    type: type,
  );
}

void main() {
  test('홈에서 빠진 과제만 완료로 본다', () {
    final done = _item(
      id: 'done',
      status: HomeworkStatus.completed,
      phase: 0,
      completedAt: DateTime(2026, 10, 21, 15),
    );
    final flagged = _item(
      id: 'flagged',
      status: HomeworkStatus.inProgress,
      phase: 4,
    );
    expect(homeworkLeftHomeList(done), isTrue);
    expect(homeworkLeftHomeList(flagged), isFalse);
    expect(homeworkGroupLeftHomeAt([done, flagged]), isNull);
    expect(
      homeworkGroupLeftHomeAt([
        done,
        _item(
          id: 'later',
          status: HomeworkStatus.completed,
          phase: 0,
          completedAt: DateTime(2026, 10, 21, 16),
        ),
      ]),
      DateTime(2026, 10, 21, 16),
    );
  });

  test('교재 필터 이름에 문제은행과 내신 기출이 구분된다', () {
    final textbook = _item(
      id: 'book',
      status: HomeworkStatus.completed,
      content: '교재: 개념원리\n과정: 중2-1',
    );
    final bank = _item(
      id: 'bank',
      status: HomeworkStatus.completed,
      sourceUnitLevel: 'problem_bank_assignment',
      content: '과정: 중2-1',
      type: '프린트',
    );
    final bankBare = _item(
      id: 'bank-bare',
      status: HomeworkStatus.completed,
      sourceUnitLevel: 'problem_bank_assignment',
      type: '프린트',
    );
    final naesin = _item(
      id: 'naesin',
      status: HomeworkStatus.completed,
      sourceUnitLevel: 'naesin',
      type: '프린트',
      content: '내신 기출\n학교: 신일고\n연도: 2025\n학년: 2학년',
    );

    expect(homeworkOverviewBookLabel(textbook), '개념원리');
    expect(homeworkOverviewBookLabel(bank), '문제은행 · 중2-1');
    expect(homeworkOverviewBookLabel(bankBare), '문제은행');
    expect(
      homeworkOverviewBookLabel(naesin),
      '2025 신일고 2학년 내신 기출',
    );
    expect(
      homeworkOverviewGroupBookLabel(
        [naesin],
        groupTitle: '2024 신일고 1학년 내신 기출',
      ),
      '2024 신일고 1학년 내신 기출',
    );
  });

  test('날짜 범위는 시작일과 종료일을 포함한다', () {
    expect(
      homeworkCompletionOnDayRange(
        DateTime(2026, 10, 1, 9),
        start: DateTime(2026, 10, 1),
        end: DateTime(2026, 10, 3, 23),
      ),
      isTrue,
    );
    expect(
      homeworkCompletionOnDayRange(
        DateTime(2026, 10, 3, 23, 50),
        start: DateTime(2026, 10, 1),
        end: DateTime(2026, 10, 3),
      ),
      isTrue,
    );
    expect(
      homeworkCompletionOnDayRange(
        DateTime(2026, 9, 30, 23),
        start: DateTime(2026, 10, 1),
        end: DateTime(2026, 10, 3),
      ),
      isFalse,
    );
  });
}
