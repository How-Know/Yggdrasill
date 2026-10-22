import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yggdrasill_manager/services/concept_book_service.dart';
import 'package:yggdrasill_manager/services/textbook_pdf_service.dart';

const _ok = {'ok': true, 'kind': 'storage', 'migration_status': 'migrated', 'url': 'https://files/a.pdf', 'link_id': 1};

ConceptBookService _svc(List<http.Response> replies, List<Uri> calls) {
  var i = 0;
  final client = MockClient((req) async {
    calls.add(req.url);
    return replies[i++];
  });
  return ConceptBookService(
    pdf: TextbookPdfService(httpClient: client, gatewayBaseUrl: 'http://gw', gatewayApiKey: 'k'),
    httpClient: client,
    retryDelays: const [Duration.zero, Duration.zero],
  );
}

http.Response _json(int status, Map<String, Object?> body) => http.Response(jsonEncode(body), status);

void main() {
  test('게이트웨이가 DB에 닿지 못하면 다시 해서 주소를 받는다', () async {
    final calls = <Uri>[];
    final svc = _svc([
      _json(400, {'ok': false, 'error': 'link_lookup_failed: TypeError: fetch failed'}),
      _json(502, {'ok': false, 'error': 'bad gateway'}),
      _json(200, _ok),
    ], calls);
    expect(await svc.originalUrl(academyId: 'a', bookId: 'b', gradeLabel: 'g'), 'https://files/a.pdf');
    expect(calls, hasLength(3));
  });

  test('다시 해도 같은 실패(링크 없음)는 한 번만 묻고 알린다', () async {
    final calls = <Uri>[];
    final svc = _svc([
      _json(400, {'ok': false, 'error': 'link_not_found'})
    ], calls);
    await expectLater(
      svc.originalUrl(academyId: 'a', bookId: 'b', gradeLabel: 'g'),
      throwsA(predicate((e) => '$e'.contains('link_not_found'))),
    );
    expect(calls, hasLength(1));
  });

  test('일시 실패가 계속되면 정해진 횟수 뒤 원래 오류를 알린다', () async {
    final calls = <Uri>[];
    final fail = _json(400, {'ok': false, 'error': 'link_lookup_failed: TypeError: fetch failed'});
    final svc = _svc([fail, fail, fail], calls);
    await expectLater(
      svc.originalUrl(academyId: 'a', bookId: 'b', gradeLabel: 'g'),
      throwsA(predicate((e) => '$e'.contains('fetch failed'))),
    );
    expect(calls, hasLength(3));
  });

  test('일시 실패 판단', () {
    expect(isTransientPdfError(Exception('download_url_failed(503): x')), isTrue);
    expect(isTransientPdfError(http.ClientException('reset')), isTrue);
    expect(isTransientPdfError(Exception('download_url_failed(400): missing_identifiers')), isFalse);
    expect(isTransientPdfError(Exception('서버 저장 완료(migrated) PDF만 사용할 수 있습니다.')), isFalse);
  });
}
