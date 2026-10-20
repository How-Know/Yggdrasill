import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/services/homework_assignment_store.dart';
import 'package:mneme_flutter/widgets/homework_assign_dialog.dart';

HomeworkAssignmentBrief _assignment({
  required String id,
  required DateTime assignedAt,
}) {
  return HomeworkAssignmentBrief(
    id: id,
    homeworkItemId: 'item-$id',
    assignedAt: assignedAt,
    dueDate: null,
    orderIndex: 0,
    status: 'completed',
    progress: 100,
    repeatIndex: 0,
    splitParts: 1,
    splitRound: 0,
  );
}

HomeworkAssignmentCheck _check({
  required String id,
  required String assignmentId,
  required DateTime checkedAt,
}) {
  return HomeworkAssignmentCheck(
    id: id,
    homeworkItemId: 'item-$assignmentId',
    assignmentId: assignmentId,
    checkedAt: checkedAt,
    progress: 100,
  );
}

void main() {
  final day = DateTime(2026, 10, 14, 20);
  final arrival = DateTime(2026, 10, 14, 20, 29);

  test('등원 전에 배정된 숙제의 오늘 첫 검사는 숙제 검사다', () {
    final assignment = _assignment(
      id: 'pre-class',
      assignedAt: DateTime(2026, 10, 13, 22),
    );

    expect(
      hasFirstPreClassAssignmentCheckOn(
        checks: [
          _check(
            id: 'today-first',
            assignmentId: assignment.id,
            checkedAt: DateTime(2026, 10, 14, 21),
          ),
        ],
        assignmentsById: {assignment.id: assignment},
        day: day,
        sessionStart: arrival,
      ),
      isTrue,
    );
  });

  test('등원 후 생성된 수업 과제의 첫 검사는 숙제로 잡지 않는다', () {
    final assignment = _assignment(
      id: 'in-class',
      assignedAt: DateTime(2026, 10, 14, 21, 32, 5),
    );

    expect(
      hasFirstPreClassAssignmentCheckOn(
        checks: [
          // 실제 반환 경로처럼 검사가 assignment보다 먼저 저장돼도
          // 배정 시각과 등원 시각으로 수업 과제임을 판정해야 한다.
          _check(
            id: 'check-before-assignment',
            assignmentId: assignment.id,
            checkedAt: DateTime(2026, 10, 14, 21, 32, 4),
          ),
        ],
        assignmentsById: {assignment.id: assignment},
        day: day,
        sessionStart: arrival,
      ),
      isFalse,
    );
  });

  test('이전 날짜에 이미 검사한 숙제의 오늘 재검사는 첫 검사가 아니다', () {
    final assignment = _assignment(
      id: 'already-checked',
      assignedAt: DateTime(2026, 10, 12, 18),
    );

    expect(
      hasFirstPreClassAssignmentCheckOn(
        checks: [
          _check(
            id: 'previous',
            assignmentId: assignment.id,
            checkedAt: DateTime(2026, 10, 13, 20),
          ),
          _check(
            id: 'today-recheck',
            assignmentId: assignment.id,
            checkedAt: DateTime(2026, 10, 14, 21),
          ),
        ],
        assignmentsById: {assignment.id: assignment},
        day: day,
        sessionStart: arrival,
      ),
      isFalse,
    );
  });
}
