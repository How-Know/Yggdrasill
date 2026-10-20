import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yggdrasill_manager/services/concept_book_service.dart';
import 'package:yggdrasill_manager/services/concept_draft_service.dart';
import 'package:yggdrasill_manager/services/textbook_pdf_service.dart';

final _noHttp = MockClient((_) async => http.Response('', 404));

ConceptDraftService _service(String body, int status) => ConceptDraftService(
      client: SupabaseClient(
        'http://localhost:54321',
        'anon-key',
        httpClient: MockClient((_) async => http.Response(body, status, headers: {'content-type': 'application/json'})),
      ),
      books: ConceptBookService(pdf: TextbookPdfService(httpClient: _noHttp), httpClient: _noHttp),
    );

Future<String> _code(Future<void> Function() run) async {
  try {
    await run();
  } on ConceptDraftException catch (e) {
    return e.code;
  }
  return 'none';
}

void main() {
  group('긴 정리 응답', () {
    test('앞 공백 뒤 결과를 읽고, 200 안의 실패는 원래 상태 코드로 알린다', () async {
      expect(await _service('   {"ok":true,"draft_id":"d2","http_status":200}', 200).rerun('a1'), 'd2');
      final svc = _service('  {"ok":false,"error":"Signal timed out.","http_status":502}', 200);
      try {
        await svc.rerun('a1');
        fail('실패로 알려야 한다');
      } on ConceptDraftException catch (e) {
        expect(e.code, 'Signal timed out.');
        expect(e.message, contains('서버 오류(502)'));
      }
      expect(await _code(() => _service('{"ok":false,"error":"action_not_pending","message":"x"}', 409).rerun('a1')),
          'action_not_pending');
    });

    test('중간에 끊긴 응답은 끊겼다고 알린다', () async {
      expect(await _code(() => _service('      {"ok":', 200).rerun('a1')), 'response_cut');
    });
  });

  group('백그라운드 정리', () {
    final book = ConceptBookEntry(
      academyId: 'ac',
      bookId: 'bk',
      bookName: '개념+유형',
      gradeLabel: '1-2',
      textbookType: null,
      units: const [],
    );

    test('작업을 시작하고, 끝날 때까지 물어보며 기다린 시간을 알린다', () async {
      final s = _sequence([
        (200, '{"ok":true,"job_id":"j1","status":"running"}'),
        (200, '{"ok":true,"status":"running","elapsed_ms":6000}'),
        (200, '{"ok":true,"status":"running","elapsed_ms":71000}'),
        (200, '{"ok":true,"status":"done","draft_id":"d9"}'),
      ]);
      final waits = <Duration>[];
      final id =
          await s.service.createDraft(book: book, unitPath: const ['기본 도형'], pages: const [8, 9], onWait: waits.add);
      expect(id, 'd9');
      expect(waits, const [Duration(seconds: 6), Duration(seconds: 71)]);
      expect(s.bodies.first['background'], isTrue);
      expect(s.bodies.skip(1).map((b) => '${b['task']}:${b['job_id']}').toSet(), {'collect:j1'});
    });

    test('결과 확인이 잠깐 실패하면 다시 묻고, 정리 실패는 그대로 알린다', () async {
      final flaky = _sequence([
        (200, '{"ok":true,"job_id":"j1"}'),
        (502, '{"ok":false,"error":"ai_poll_failed","message":"x","retryable":true}'),
        (200, '{"ok":true,"status":"done","draft_id":"d1"}'),
      ]);
      expect(await flaky.service.rerun('a1'), 'd1');

      final failed = _sequence([
        (200, '{"ok":true,"job_id":"j1"}'),
        (502, '{"ok":false,"status":"failed","error":"invalid_output","message":"invalid_output"}'),
      ]);
      expect(await _code(() => failed.service.rerun('a1')), 'invalid_output');
    });

    test('너무 오래 걸리면 앱도 기다림을 멈춘다', () async {
      final s = _sequence([
        (200, '{"ok":true,"job_id":"j1"}'),
        (200, '{"ok":true,"status":"running","elapsed_ms":1000}'),
      ], maxWait: Duration.zero);
      expect(await _code(() => s.service.rerun('a1')), 'ai_timeout');
    });

    test('진행 글에 기다린 시간을 붙인다', () {
      expect(conceptDraftWaitText('정리하는 중', null), '정리하는 중 (보통 1~5분)');
      expect(conceptDraftWaitText('정리하는 중', const Duration(seconds: 7)), '정리하는 중 (7초 지남)');
      expect(conceptDraftWaitText('정리하는 중', const Duration(seconds: 131)), '정리하는 중 (2분 11초 지남)');
    });

    test('응답이 멈춘 실패만 다시 읽을 대상으로 본다', () {
      expect(isConceptDraftTimeout(ConceptDraftException('Signal timed out.', '')), isTrue);
      expect(isConceptDraftTimeout(ConceptDraftException('response_cut', '')), isTrue);
      expect(isConceptDraftTimeout(ConceptDraftException('invalid_image', '')), isFalse);
      expect(isConceptDraftTimeout(ConceptDraftException('rate_limited', '')), isFalse);
    });
  });
}

/// 차례대로 답하는 서버. 마지막 답은 계속 되풀이한다.
({ConceptDraftService service, List<Map<String, dynamic>> bodies}) _sequence(
  List<(int, String)> replies, {
  Duration maxWait = const Duration(minutes: 1),
}) {
  final bodies = <Map<String, dynamic>>[];
  var i = 0;
  final service = ConceptDraftService(
    client: SupabaseClient(
      'http://localhost:54321',
      'anon-key',
      httpClient: MockClient((req) async {
        bodies.add(Map<String, dynamic>.from(jsonDecode(req.body) as Map));
        final (status, body) = replies[i < replies.length ? i++ : replies.length - 1];
        return http.Response(body, status, headers: {'content-type': 'application/json'});
      }),
    ),
    books: ConceptBookService(pdf: TextbookPdfService(httpClient: _noHttp), httpClient: _noHttp),
    pollInterval: Duration.zero,
    maxWait: maxWait,
  );
  return (service: service, bodies: bodies);
}
