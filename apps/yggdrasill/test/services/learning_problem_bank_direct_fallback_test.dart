import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mneme_flutter/services/learning_problem_bank_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('Gateway 작업 생성 실패 시 Supabase export 큐로 폴백한다', () async {
    var gatewayRequested = false;
    var supabaseInserted = false;
    final mockHttp = MockClient((request) async {
      if (request.url.host == 'gateway.invalid') {
        gatewayRequested = true;
        return http.Response(
          jsonEncode({'ok': false, 'error': 'gateway_unavailable'}),
          503,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      if (request.url.host == 'supabase.test' &&
          request.url.path == '/rest/v1/pb_exports' &&
          request.method == 'POST') {
        supabaseInserted = true;
        return http.Response(
          jsonEncode({
            'id': '10000000-0000-0000-0000-000000000001',
            'academy_id': '20000000-0000-0000-0000-000000000002',
            'document_id': '30000000-0000-0000-0000-000000000003',
            'status': 'queued',
            'template_profile': 'naesin',
            'paper_size': 'A4',
            'include_answer_sheet': true,
            'include_explanation': false,
            'selected_question_ids': [
              '40000000-0000-0000-0000-000000000004',
            ],
            'output_storage_bucket': 'problem-exports',
            'output_storage_path': '',
            'output_url': '',
            'options': <String, dynamic>{},
            'result_summary': <String, dynamic>{},
          }),
          201,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      throw StateError('예상하지 못한 요청: ${request.method} ${request.url}');
    });
    final client = SupabaseClient(
      'https://supabase.test',
      'test-anon-key',
      httpClient: mockHttp,
    );
    final service = LearningProblemBankService(
      client: client,
      httpClient: mockHttp,
      gatewayBaseUrl: 'https://gateway.invalid',
    );

    final job = await service.createExportJob(
      academyId: '20000000-0000-0000-0000-000000000002',
      documentId: '30000000-0000-0000-0000-000000000003',
      templateProfile: 'naesin',
      paperSize: 'A4',
      includeAnswerSheet: true,
      includeExplanation: false,
      selectedQuestionUids: const [
        '40000000-0000-0000-0000-000000000004',
      ],
      previewOnly: true,
    );

    expect(gatewayRequested, isTrue);
    expect(supabaseInserted, isTrue);
    expect(job.status, 'queued');
    expect(job.outputStorageBucket, 'problem-exports');
    client.dispose();
  });
}
