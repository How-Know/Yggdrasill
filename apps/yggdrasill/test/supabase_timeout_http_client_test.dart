import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mneme_flutter/services/supabase_timeout_http_client.dart';

void main() {
  const timeout = Duration(milliseconds: 50);

  SupabaseTimeoutHttpClient clientRespondingAfter(Duration delay) {
    return SupabaseTimeoutHttpClient(
      timeout: timeout,
      rpcTimeout: const Duration(milliseconds: 300),
      inner: MockClient((request) async {
        await Future<void>.delayed(delay);
        return http.Response('[]', 200);
      }),
    );
  }

  test('멈춘 REST 요청은 TimeoutException으로 끝난다', () async {
    final client = clientRespondingAfter(const Duration(seconds: 5));
    await expectLater(
      client.get(Uri.parse('https://x.supabase.co/rest/v1/students')),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('멈춘 Auth 요청도 TimeoutException으로 끝난다', () async {
    final client = clientRespondingAfter(const Duration(seconds: 5));
    await expectLater(
      client.post(Uri.parse('https://x.supabase.co/auth/v1/token')),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('제한 시간 안의 REST 응답은 그대로 전달된다', () async {
    final client = clientRespondingAfter(Duration.zero);
    final res =
        await client.get(Uri.parse('https://x.supabase.co/rest/v1/students'));
    expect(res.statusCode, 200);
    expect(res.body, '[]');
  });

  test('RPC는 더 긴 제한을 쓰고, 그것도 넘으면 끝난다', () async {
    final slow = clientRespondingAfter(const Duration(milliseconds: 150));
    final res = await slow
        .post(Uri.parse('https://x.supabase.co/rest/v1/rpc/delete_student'));
    expect(res.statusCode, 200);

    final stuck = clientRespondingAfter(const Duration(seconds: 5));
    await expectLater(
      stuck.post(Uri.parse('https://x.supabase.co/rest/v1/rpc/delete_student')),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('Storage와 Edge Function 요청은 제한하지 않는다', () async {
    final client = clientRespondingAfter(const Duration(milliseconds: 150));
    final storage = await client
        .get(Uri.parse('https://x.supabase.co/storage/v1/object/a.pdf'));
    final fn = await client
        .post(Uri.parse('https://x.supabase.co/functions/v1/think'));
    expect(storage.statusCode, 200);
    expect(fn.statusCode, 200);
  });
}
