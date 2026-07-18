import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_kiosk/models/kiosk_models.dart';

void main() {
  test('backend pairing response parses code and expiry', () {
    final state = PairingState.fromJson({
      'ok': true,
      'code': '012345',
      'expires_at': '2026-07-19T00:10:00Z',
    }).withPairingId('webos-device');

    expect(state.pairingId, 'webos-device');
    expect(state.pin, '012345');
    expect(state.expiresAt, isNotNull);
  });

  test('backend bootstrap response parses academy and announcement', () {
    final data = BootstrapData.fromJson({
      'ok': true,
      'academy': {'name': '정현수학교습소', 'address': '서울특별시 강남구'},
      'announcement': {'title': '휴원 안내', 'body': '오늘은 휴원입니다.'},
    });

    expect(data.academy.name, '정현수학교습소');
    expect(data.academy.address, '서울특별시 강남구');
    expect(data.announcement?.title, '휴원 안내');
  });

  test('today attendance response formats class time', () {
    final visit = StudentVisit.fromJson({
      'student_id': 'student-1',
      'name': '김학생',
      'class_date_time': '2026-07-19T09:30:00',
      'checked_in': true,
    });

    expect(visit.id, 'student-1');
    expect(visit.timeLabel, '09:30');
    expect(visit.checkedIn, isTrue);
    expect(visit.scheduledToday, isTrue);
  });
}
