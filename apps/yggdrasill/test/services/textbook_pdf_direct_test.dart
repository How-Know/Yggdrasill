import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mneme_flutter/services/textbook_pdf_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('Gateway 없이 resource_file_links의 legacy PDF를 직접 해석한다', () async {
    var directLookupRequested = false;
    final mockHttp = MockClient((request) async {
      if (request.url.host == 'supabase.test' &&
          request.url.path == '/rest/v1/resource_file_links' &&
          request.method == 'GET') {
        directLookupRequested = true;
        return http.Response(
          jsonEncode({
            'id': 17,
            'academy_id': '20000000-0000-0000-0000-000000000002',
            'file_id': '30000000-0000-0000-0000-000000000003',
            'grade': '중1#body',
            'url': 'https://files.example.test/textbook.pdf',
            'storage_driver': null,
            'storage_bucket': null,
            'storage_key': null,
            'migration_status': 'legacy',
            'file_size_bytes': 1234,
            'content_hash': null,
          }),
          200,
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
    final service = TextbookPdfService.forTesting(
      supabaseClient: client,
      httpClient: mockHttp,
    );

    final source = await service.resolve(
      const TextbookPdfRef(linkId: 17),
    );

    expect(directLookupRequested, isTrue);
    expect(source.type, TextbookPdfSourceType.legacyUrl);
    expect(source.url, 'https://files.example.test/textbook.pdf');
    expect(source.linkId, '17');
    client.dispose();
  });
}
