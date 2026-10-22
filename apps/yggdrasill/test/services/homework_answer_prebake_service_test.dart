import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mneme_flutter/services/homework_answer_prebake_service.dart';
import 'package:mneme_flutter/services/learning_problem_bank_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const academyId = '20000000-0000-0000-0000-000000000002';

  ({
    HomeworkAnswerPrebakeService service,
    List<Map<String, dynamic>> bodies,
    SupabaseClient client,
  }) build({int status = 200}) {
    final bodies = <Map<String, dynamic>>[];
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/answers/render-assets/prebake-homework') {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      }
      return http.Response(
        jsonEncode({'ok': status == 200}),
        status,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    });
    final client = SupabaseClient(
      'https://supabase.test',
      'test-anon-key',
      httpClient: mockHttp,
    );
    final problemBank = LearningProblemBankService(
      client: client,
      httpClient: mockHttp,
      gatewayBaseUrl: 'http://gateway.test',
    );
    return (
      service: HomeworkAnswerPrebakeService.forTesting(problemBank),
      bodies: bodies,
      client: client,
    );
  }

  test('학생별로 저장된 과제를 한 번의 요청으로 모은다', () async {
    final t = build();
    t.service.request(academyId: academyId, homeworkItemIds: const ['a']);
    t.service.request(academyId: academyId, homeworkItemIds: const ['b', 'a']);
    await t.service.flush();

    expect(t.bodies, hasLength(1));
    expect(t.bodies.single['academyId'], academyId);
    expect(
      (t.bodies.single['homeworkItemIds'] as List).toSet(),
      {'a', 'b'},
    );
    t.client.dispose();
  });

  test('게이트웨이 실패는 저장 흐름으로 올리지 않는다', () async {
    final t = build(status: 503);
    t.service.request(academyId: academyId, homeworkItemIds: const ['a']);
    await expectLater(t.service.flush(), completes);
    expect(t.bodies, hasLength(1));
    t.client.dispose();
  });
}
