import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_student/services/student_api.dart';
import 'package:yggdrasill_student/services/textbook_api.dart';

void main() {
  test('시간제한 테스트 세션 결과 계약을 파싱한다', () {
    final session = TimedTestSession.fromJson(const {
      'session_id': 'session-1',
      'status': 'completed',
      'started_at': '2026-08-22T15:00:00Z',
      'deadline_at': '2026-08-22T15:10:00Z',
      'remaining_sec': 0,
      'time_limit_sec': 600,
      'expired': true,
      'correct': 3,
      'wrong': 2,
      'skipped': 1,
      'timeout': 1,
      'exposed': 7,
      'accuracy': 0.5,
    });

    expect(session.isOpen, isFalse);
    expect(session.correct, 3);
    expect(session.pass, 1);
    expect(session.timeout, 1);
    expect(session.exposed, 7);
    expect(session.accuracy, 0.5);
  });

  test('채점 payload에 서버 식별자와 시간 메타를 넣는다', () {
    final payload = const TimedTestGradeContext(
      sessionId: 'session-1',
      exposureId: 'exposure-1',
      durationMs: 1200,
      position: 2,
      wallDurationMs: 1500,
      interruptionMs: 300,
    ).toJson();

    expect(payload['session_id'], 'session-1');
    expect(payload['exposure_id'], 'exposure-1');
    expect(payload['duration_ms'], 1200);
    expect(payload['position'], 2);
    expect(payload['interruption_ms'], 300);
  });

  test('테스트·시간·디지털 조건이 모두 맞아야 전용 흐름이다', () {
    HomeworkGroup group(
        {required bool test, int? minutes, bool digital = true}) {
      return HomeworkGroup.fromRow({
        'group_id': 'group-1',
        'is_test': test,
        'time_limit_minutes': minutes,
        'digital_solvable': digital,
      })
        ..isTest = test;
    }

    expect(group(test: true, minutes: 10).isTimedTest, isTrue);
    expect(group(test: true, minutes: 0).isTimedTest, isFalse);
    expect(group(test: false, minutes: 10).isTimedTest, isFalse);
    expect(group(test: true, minutes: 10, digital: false).isTimedTest, isFalse);
  });
}
