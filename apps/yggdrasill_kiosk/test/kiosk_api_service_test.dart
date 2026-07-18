import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yggdrasill_kiosk/models/kiosk_models.dart';
import 'package:yggdrasill_kiosk/services/kiosk_api_service.dart';

void main() {
  test('pairing requests match kiosk_api contract', () async {
    final requests = <Map<String, dynamic>>[];
    final service = KioskApiService(
      baseUrl: 'https://example.supabase.co',
      anonKey: 'anon',
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requests.add(body);
        if (body['action'] == 'begin_pairing') {
          return http.Response(
            jsonEncode({
              'ok': true,
              'code': '123456',
              'expires_at': '2026-07-19T01:00:00Z',
            }),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response(
          jsonEncode({
            'ok': true,
            'academy_id': 'academy',
            'token': 'device-token',
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final pairing = await service.beginPairing(
      deviceId: 'webos-device',
      deviceName: '스탠바이미 출석 키오스크',
    );
    final session = await service.pollPairing(pairing);

    expect(requests[0]['device_id'], 'webos-device');
    expect(requests[0]['device_name'], '스탠바이미 출석 키오스크');
    expect(requests[1]['device_id'], 'webos-device');
    expect(requests[1]['code'], '123456');
    expect(session?.deviceId, 'webos-device');
    expect(session?.token, 'device-token');
  });

  test('walk-in check-in sends atomic extra-class flag', () async {
    late Map<String, dynamic> payload;
    final service = KioskApiService(
      baseUrl: 'https://example.supabase.co',
      anonKey: 'anon',
      client: MockClient((request) async {
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'ok': true,
            'status': 'checked_in',
            'attendance_id': 'attendance',
            'arrival_time': '2026-07-19T00:00:00Z',
            'walk_in': true,
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    const student = StudentVisit(
      id: '018f8d4a-53d8-4c2a-9f31-111111111111',
      name: '김학생',
      timeLabel: '',
      checkedIn: false,
      scheduledToday: false,
    );

    final result = await service.checkIn(
      const KioskSession(deviceId: 'webos-device', token: 'device-token'),
      student,
      '1234',
    );

    expect(payload['walk_in'], isTrue);
    expect(payload['student_id'], student.id);
    expect(payload['request_id'], isNotEmpty);
    expect(result.success, isTrue);
  });
}
