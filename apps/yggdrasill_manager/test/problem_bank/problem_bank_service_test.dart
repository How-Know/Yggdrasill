import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yggdrasill_manager/services/problem_bank_service.dart';

void main() {
  group('loadTimedTestStatsForQuestions', () {
    test('빈 UID 목록은 RPC를 호출하지 않고 빈 Map을 반환한다', () async {
      var requestCount = 0;
      final service = ProblemBankService(
        client: SupabaseClient(
          'http://localhost:54321',
          'anon-key',
          httpClient: MockClient((_) async {
            requestCount += 1;
            return http.Response('[]', 200);
          }),
        ),
      );

      final result = await service.loadTimedTestStatsForQuestions(
        const <String>['', '  '],
      );

      expect(result, isEmpty);
      expect(requestCount, 0);
    });

    test('UID를 중복 제거해 한 번에 RPC로 조회하고 typed Map을 만든다', () async {
      var requestCount = 0;
      late Map<String, dynamic> requestBody;
      final service = ProblemBankService(
        client: SupabaseClient(
          'http://localhost:54321',
          'anon-key',
          httpClient: MockClient((request) async {
            requestCount += 1;
            expect(
              request.url.path,
              '/rest/v1/rpc/pb_question_timed_test_stats_batch_v1',
            );
            requestBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode(<Map<String, dynamic>>[
                <String, dynamic>{
                  'question_uid': '00000000-0000-0000-0000-000000000001',
                  'assigned_student_count': 3,
                  'exposed_student_count': 2,
                  'responded_student_count': 1,
                },
                <String, dynamic>{
                  'question_uid': '00000000-0000-0000-0000-000000000002',
                  'assigned_student_count': 0,
                  'exposed_student_count': 0,
                  'responded_student_count': 0,
                },
              ]),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
              request: request,
            );
          }),
        ),
      );

      final result = await service.loadTimedTestStatsForQuestions(
        const <String>[
          '00000000-0000-0000-0000-000000000001',
          ' 00000000-0000-0000-0000-000000000001 ',
          '00000000-0000-0000-0000-000000000002',
        ],
      );

      expect(requestCount, 1);
      expect(
        requestBody['p_question_uids'],
        <String>[
          '00000000-0000-0000-0000-000000000001',
          '00000000-0000-0000-0000-000000000002',
        ],
      );
      expect(result.length, 2);
      expect(
        result['00000000-0000-0000-0000-000000000001']?.respondedStudentCount,
        1,
      );
      expect(
        result['00000000-0000-0000-0000-000000000002']?.displayLabel,
        '출제 0 · 노출 0 · 응답 0',
      );
    });

    test('RPC 오류를 호출자에게 전달한다', () async {
      final service = ProblemBankService(
        client: SupabaseClient(
          'http://localhost:54321',
          'anon-key',
          httpClient: MockClient(
            (request) async => http.Response(
              jsonEncode(<String, dynamic>{'message': 'forbidden'}),
              403,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
              request: request,
            ),
          ),
        ),
      );

      expect(
        service.loadTimedTestStatsForQuestions(
          const <String>['00000000-0000-0000-0000-000000000001'],
        ),
        throwsA(isA<PostgrestException>()),
      );
    });
  });
}
