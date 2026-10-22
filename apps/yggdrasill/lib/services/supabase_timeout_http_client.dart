import 'dart:async';

import 'package:http/http.dart' as http;

/// Supabase REST·Auth 요청이 응답 없이 멈추면 시작 로드와 홈 동기화가 끝나지 않는다.
/// 멈춘 요청을 [TimeoutException]으로 바꿔 호출부의 실패·재시도 흐름에 태운다.
/// Storage 업로드와 Edge Function은 정상적으로 오래 걸릴 수 있어 제한하지 않는다.
class SupabaseTimeoutHttpClient extends http.BaseClient {
  SupabaseTimeoutHttpClient({
    http.Client? inner,
    this.timeout = const Duration(seconds: 30),
    this.rpcTimeout = const Duration(seconds: 75),
  }) : _inner = inner ?? http.Client();

  final http.Client _inner;

  /// 테이블 조회·Auth: 응답 헤더까지의 시간, 그리고 본문 청크 사이의 최대 간격.
  final Duration timeout;

  /// 일부 RPC(학생 삭제·휴원 등)는 서버에서 statement_timeout을 60초까지 늘린다.
  final Duration rpcTimeout;

  Duration? timeoutFor(Uri url) {
    final path = url.path;
    if (path.startsWith('/rest/v1/rpc/')) return rpcTimeout;
    if (path.startsWith('/rest/v1/') || path.startsWith('/auth/v1/')) {
      return timeout;
    }
    return null;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final limit = timeoutFor(request.url);
    if (limit == null) return _inner.send(request);
    final label = '${request.method} ${request.url.path}';
    final response = await _inner.send(request).timeout(
          limit,
          onTimeout: () => throw TimeoutException(
            'Supabase request timed out: $label',
            limit,
          ),
        );
    return http.StreamedResponse(
      response.stream.timeout(
        limit,
        onTimeout: (sink) {
          sink.addError(TimeoutException(
            'Supabase response body stalled: $label',
            limit,
          ));
          sink.close();
        },
      ),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}
