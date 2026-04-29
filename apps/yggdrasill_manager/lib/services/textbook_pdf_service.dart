import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Client for the `/textbook/pdf/*` endpoints on the gateway.
///
/// This mirrors the pattern used by `ProblemBankService` (see
/// [lib/services/problem_bank_service.dart]) but stays focused on the
/// textbook PDF dual-track migration flow: request a signed upload URL,
/// stream bytes to Supabase Storage, then call `finalize` so the
/// `resource_file_links` row flips to `migration_status='dual'`.
///
/// SECURITY TODO (pre-release):
/// - Thread a JWT / user-bound header through [_headers] instead of relying
///   on the shared `x-api-key`.
/// - Encrypt PDF bytes in memory before PUT so the gateway sees ciphertext.
class TextbookPdfService {
  TextbookPdfService({
    http.Client? httpClient,
    String? gatewayBaseUrl,
    String? gatewayApiKey,
  })  : _http = httpClient ?? http.Client(),
        _gatewayBaseUrl = _resolveGatewayUrl(gatewayBaseUrl),
        _gatewayApiKey = (gatewayApiKey ??
                const String.fromEnvironment('PB_GATEWAY_API_KEY',
                    defaultValue: ''))
            .trim();

  static String _resolveGatewayUrl(String? explicit) {
    if (explicit != null && explicit.trim().isNotEmpty) {
      return explicit.trim();
    }
    const dartDefine =
        String.fromEnvironment('PB_GATEWAY_URL', defaultValue: '');
    if (dartDefine.isNotEmpty) return dartDefine;
    try {
      final envValue = Platform.environment['PB_GATEWAY_URL'] ?? '';
      if (envValue.isNotEmpty) return envValue;
    } catch (_) {}
    return 'http://localhost:8787';
  }

  final http.Client _http;
  final String _gatewayBaseUrl;
  final String _gatewayApiKey;

  bool get hasGateway => _gatewayBaseUrl.isNotEmpty;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = _gatewayBaseUrl.endsWith('/')
        ? _gatewayBaseUrl.substring(0, _gatewayBaseUrl.length - 1)
        : _gatewayBaseUrl;
    final p = path.startsWith('/') ? path : '/$path';
    final u = Uri.parse('$base$p');
    if (query == null || query.isEmpty) return u;
    return u.replace(queryParameters: query);
  }

  Map<String, String> _headers() {
    final out = <String, String>{
      'Content-Type': 'application/json',
    };
    if (_gatewayApiKey.isNotEmpty) {
      out['x-api-key'] = _gatewayApiKey;
    }
    return out;
  }

  Map<String, dynamic> _decode(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return v.map((k, dynamic val) => MapEntry('$k', val));
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// Requests a signed upload URL from the gateway. Must be called once per
  /// upload; the returned `uploadUrl` is the Supabase Storage signed URL
  /// that accepts an HTTP PUT with the raw PDF bytes.
  Future<TextbookUploadTarget> requestUploadUrl({
    required String academyId,
    required String fileId,
    required String gradeLabel,
    required String kind,
  }) async {
    final res = await _http.post(
      _uri('/textbook/pdf/upload-url'),
      headers: _headers(),
      body: jsonEncode(<String, dynamic>{
        'academy_id': academyId,
        'file_id': fileId,
        'grade_label': gradeLabel,
        'kind': kind,
      }),
    );
    final json = _decode(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300 || json['ok'] != true) {
      throw Exception(
        'upload_url_failed(${res.statusCode}): ${json['error'] ?? res.body}',
      );
    }
    final upload = (json['upload'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final storage = (json['storage'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    return TextbookUploadTarget(
      uploadUrl: '${upload['url'] ?? ''}',
      method: '${upload['method'] ?? 'PUT'}',
      headers: ((upload['headers'] as Map?) ?? const <String, dynamic>{})
          .map((k, v) => MapEntry('$k', '$v')),
      storageDriver: '${storage['driver'] ?? 'supabase'}',
      storageBucket: '${storage['bucket'] ?? 'textbooks'}',
      storageKey: '${storage['key'] ?? ''}',
      gradeComposite: '${json['grade_composite'] ?? ''}',
    );
  }

  /// Uploads the raw PDF bytes to the signed URL returned by [requestUploadUrl].
  /// Calls [onProgress] with sent/total bytes so the UI can render a progress
  /// indicator (important for ~250MB textbook PDFs).
  Future<void> uploadBytes({
    required TextbookUploadTarget target,
    required Uint8List bytes,
    void Function(int sent, int total)? onProgress,
  }) async {
    final uri = Uri.parse(target.uploadUrl);
    final client = _http;
    final request = http.Request(target.method, uri);
    request.bodyBytes = bytes;
    target.headers.forEach((k, v) {
      request.headers[k] = v;
    });
    if (!request.headers.containsKey('Content-Type')) {
      request.headers['Content-Type'] = 'application/pdf';
    }

    // Emit an initial progress event so the UI shows 0%.
    onProgress?.call(0, bytes.length);
    final streamed = await client.send(request);
    // Supabase returns 200 on success; anything 2xx is acceptable.
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      final body = await streamed.stream.bytesToString();
      throw Exception(
        'storage_put_failed(${streamed.statusCode}): $body',
      );
    }
    await streamed.stream.drain();
    onProgress?.call(bytes.length, bytes.length);
  }

  /// Notifies the gateway that an upload finished so it can update the
  /// `resource_file_links` row (insert-or-update).
  Future<TextbookLinkSnapshot> finalizeUpload({
    int? linkId,
    required String academyId,
    required String fileId,
    required String gradeLabel,
    String? gradeKey,
    String? courseKey,
    String? courseLabel,
    required String kind,
    required String storageDriver,
    required String storageBucket,
    required String storageKey,
    required int fileSizeBytes,
    required String contentHash,
    String? legacyUrl,
    String migrationStatus = 'dual',
  }) async {
    final body = <String, dynamic>{
      if (linkId != null) 'link_id': linkId,
      'academy_id': academyId,
      'file_id': fileId,
      'grade_label': gradeLabel,
      if ((gradeKey ?? '').trim().isNotEmpty) 'grade_key': gradeKey!.trim(),
      if ((courseKey ?? '').trim().isNotEmpty) 'course_key': courseKey!.trim(),
      if ((courseLabel ?? '').trim().isNotEmpty)
        'course_label': courseLabel!.trim(),
      'kind': kind,
      'storage_driver': storageDriver,
      'storage_bucket': storageBucket,
      'storage_key': storageKey,
      'file_size_bytes': fileSizeBytes,
      'content_hash': contentHash,
      if (legacyUrl != null) 'legacy_url': legacyUrl,
      'migration_status': migrationStatus,
    };
    final res = await _http.post(
      _uri('/textbook/pdf/finalize'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    final json = _decode(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300 || json['ok'] != true) {
      throw Exception(
        'finalize_failed(${res.statusCode}): ${json['error'] ?? res.body}',
      );
    }
    return TextbookLinkSnapshot.fromMap(
      ((json['link'] as Map?) ?? const <String, dynamic>{})
          .cast<String, dynamic>(),
    );
  }

  /// Changes only `migration_status` on an existing link row. Used by the
  /// manager UI for the "promote to migrated" and "rollback to legacy"
  /// buttons.
  Future<TextbookLinkSnapshot> setMigrationStatus({
    required int linkId,
    required String migrationStatus,
  }) async {
    final res = await _http.post(
      _uri('/textbook/pdf/status'),
      headers: _headers(),
      body: jsonEncode(<String, dynamic>{
        'link_id': linkId,
        'migration_status': migrationStatus,
      }),
    );
    final json = _decode(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300 || json['ok'] != true) {
      throw Exception(
        'status_failed(${res.statusCode}): ${json['error'] ?? res.body}',
      );
    }
    return TextbookLinkSnapshot.fromMap(
      ((json['link'] as Map?) ?? const <String, dynamic>{})
          .cast<String, dynamic>(),
    );
  }

  /// Requests a short-lived download URL for an uploaded textbook PDF.
  /// Returns either a Supabase signed URL (`kind == 'storage'`) or the
  /// legacy Dropbox URL (`kind == 'legacy'`) depending on the current
  /// `migration_status` of the row.
  Future<TextbookDownloadTarget> requestDownloadUrl({
    int? linkId,
    String? academyId,
    String? fileId,
    String? gradeLabel,
    String? kind,
  }) async {
    final qp = <String, String>{
      if (linkId != null) 'link_id': '$linkId',
      if (academyId != null && academyId.isNotEmpty) 'academy_id': academyId,
      if (fileId != null && fileId.isNotEmpty) 'file_id': fileId,
      if (gradeLabel != null && gradeLabel.isNotEmpty)
        'grade_label': gradeLabel,
      if (kind != null && kind.isNotEmpty) 'kind': kind,
    };
    final res = await _http.get(
      _uri('/textbook/pdf/download-url', qp),
      headers: _headers(),
    );
    final json = _decode(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300 || json['ok'] != true) {
      throw Exception(
        'download_url_failed(${res.statusCode}): ${json['error'] ?? res.body}',
      );
    }
    return TextbookDownloadTarget(
      kind: '${json['kind'] ?? ''}',
      url: '${json['url'] ?? ''}',
      migrationStatus: '${json['migration_status'] ?? ''}',
      linkId: (json['link_id'] is num)
          ? (json['link_id'] as num).toInt()
          : int.tryParse('${json['link_id'] ?? ''}') ?? 0,
      fileSizeBytes: (json['file_size_bytes'] is num)
          ? (json['file_size_bytes'] as num).toInt()
          : null,
      contentHash: json['content_hash']?.toString(),
      expiresIn: (json['expires_in'] is num)
          ? (json['expires_in'] as num).toInt()
          : null,
    );
  }

  Future<List<TextbookStageScopeStatus>> fetchStageStatuses({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required List<Map<String, dynamic>> scopes,
  }) async {
    if (scopes.isEmpty) return const <TextbookStageScopeStatus>[];
    final res = await _http.post(
      _uri('/textbook/stage/status'),
      headers: _headers(),
      body: jsonEncode(<String, dynamic>{
        'academy_id': academyId,
        'book_id': bookId,
        'grade_label': gradeLabel,
        'scopes': scopes,
      }),
    );
    final json = _decode(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300 || json['ok'] != true) {
      throw Exception(
        'stage_status_failed(${res.statusCode}): ${json['error'] ?? res.body}',
      );
    }
    final rows = (json['statuses'] as List?) ?? const [];
    return [
      for (final row in rows)
        if (row is Map)
          TextbookStageScopeStatus.fromMap(
            row.map((k, dynamic v) => MapEntry('$k', v)),
          ),
    ];
  }

  Future<TextbookStageDeleteResult> deleteStageData({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required int bigOrder,
    required int midOrder,
    required String subKey,
    required String stage,
  }) async {
    final res = await _http.post(
      _uri('/textbook/stage/delete'),
      headers: _headers(),
      body: jsonEncode(<String, dynamic>{
        'academy_id': academyId,
        'book_id': bookId,
        'grade_label': gradeLabel,
        'big_order': bigOrder,
        'mid_order': midOrder,
        'sub_key': subKey,
        'stage': stage,
      }),
    );
    final json = _decode(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300 || json['ok'] != true) {
      throw Exception(
        'stage_delete_failed(${res.statusCode}): ${json['error'] ?? res.body}',
      );
    }
    return TextbookStageDeleteResult.fromMap(json);
  }

  /// Convenience helper that hashes the bytes client-side. The gateway also
  /// stores the hash so future work (content-addressable dedup, integrity
  /// checks) has a canonical identifier to compare against.
  static String sha256Hex(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }

  /// Deletes an entire textbook: PDFs, crops, cover and the DB row. The
  /// gateway handles the Storage sweeping; `resource_files` row removal
  /// cascades to `resource_file_links`, `textbook_metadata`, and
  /// `textbook_problem_crops`.
  Future<TextbookDeleteResult> deleteBook({
    required String academyId,
    required String bookId,
  }) async {
    final res = await _http.post(
      _uri('/textbook/book/delete'),
      headers: _headers(),
      body: jsonEncode(<String, dynamic>{
        'academy_id': academyId,
        'book_id': bookId,
      }),
    );
    final json = _decode(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300 || json['ok'] != true) {
      throw Exception(
        'delete_failed(${res.statusCode}): ${json['error'] ?? res.body}',
      );
    }
    final removedMap = (json['removed'] as Map?) ?? const <String, dynamic>{};
    final warnings = <String>[];
    final rawWarnings = json['warnings'];
    if (rawWarnings is List) {
      for (final w in rawWarnings) {
        warnings.add('$w');
      }
    }
    int asInt(dynamic v) => v is num ? v.toInt() : 0;
    return TextbookDeleteResult(
      bookId: bookId,
      removedCrops: asInt(removedMap['crops']),
      removedPdfs: asInt(removedMap['pdfs']),
      removedCovers: asInt(removedMap['covers']),
      warnings: warnings,
    );
  }
}

class TextbookDeleteResult {
  const TextbookDeleteResult({
    required this.bookId,
    required this.removedCrops,
    required this.removedPdfs,
    required this.removedCovers,
    required this.warnings,
  });

  final String bookId;
  final int removedCrops;
  final int removedPdfs;
  final int removedCovers;
  final List<String> warnings;
}

class TextbookStageScopeStatus {
  const TextbookStageScopeStatus({
    required this.bigOrder,
    required this.midOrder,
    required this.subKey,
    required this.bodyDone,
    required this.bodyTotal,
    required this.answerDone,
    required this.answerTotal,
    required this.solutionDone,
    required this.solutionTotal,
  });

  final int bigOrder;
  final int midOrder;
  final String subKey;
  final int bodyDone;
  final int bodyTotal;
  final int answerDone;
  final int answerTotal;
  final int solutionDone;
  final int solutionTotal;

  int get completedStages =>
      (bodyDone > 0 ? 1 : 0) +
      (answerTotal > 0 && answerDone >= answerTotal ? 1 : 0) +
      (solutionTotal > 0 && solutionDone >= solutionTotal ? 1 : 0);

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  factory TextbookStageScopeStatus.fromMap(Map<String, dynamic> map) {
    final scope = (map['scope'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final body = (map['body'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final answer = (map['answer'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final solution = (map['solution'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    return TextbookStageScopeStatus(
      bigOrder: _asInt(scope['big_order'] ?? map['big_order']),
      midOrder: _asInt(scope['mid_order'] ?? map['mid_order']),
      subKey: '${scope['sub_key'] ?? map['sub_key'] ?? ''}',
      bodyDone: _asInt(body['done']),
      bodyTotal: _asInt(body['total']),
      answerDone: _asInt(answer['done']),
      answerTotal: _asInt(answer['total']),
      solutionDone: _asInt(solution['done']),
      solutionTotal: _asInt(solution['total']),
    );
  }
}

class TextbookStageDeleteResult {
  const TextbookStageDeleteResult({
    required this.stage,
    required this.removed,
    required this.warnings,
    required this.affectedSubKeys,
  });

  final String stage;
  final Map<String, int> removed;
  final List<String> warnings;
  final List<String> affectedSubKeys;

  factory TextbookStageDeleteResult.fromMap(Map<String, dynamic> map) {
    final rawRemoved = (map['removed'] as Map?) ?? const <String, dynamic>{};
    return TextbookStageDeleteResult(
      stage: '${map['stage'] ?? ''}',
      removed: rawRemoved.map(
        (k, dynamic v) => MapEntry(
          '$k',
          v is num ? v.toInt() : int.tryParse('$v') ?? 0,
        ),
      ),
      warnings: ((map['warnings'] as List?) ?? const [])
          .map((e) => '$e')
          .toList(growable: false),
      affectedSubKeys: ((map['affected_sub_keys'] as List?) ?? const [])
          .map((e) => '$e')
          .toList(growable: false),
    );
  }
}

class TextbookDownloadTarget {
  const TextbookDownloadTarget({
    required this.kind,
    required this.url,
    required this.migrationStatus,
    required this.linkId,
    this.fileSizeBytes,
    this.contentHash,
    this.expiresIn,
  });

  /// 'storage' for Supabase Storage signed URLs, 'legacy' for the original
  /// Dropbox (or other external) URL.
  final String kind;
  final String url;
  final String migrationStatus;
  final int linkId;
  final int? fileSizeBytes;
  final String? contentHash;
  final int? expiresIn;
}

class TextbookUploadTarget {
  const TextbookUploadTarget({
    required this.uploadUrl,
    required this.method,
    required this.headers,
    required this.storageDriver,
    required this.storageBucket,
    required this.storageKey,
    required this.gradeComposite,
  });

  final String uploadUrl;
  final String method;
  final Map<String, String> headers;
  final String storageDriver;
  final String storageBucket;
  final String storageKey;
  final String gradeComposite;
}

class TextbookLinkSnapshot {
  const TextbookLinkSnapshot({
    required this.id,
    required this.academyId,
    required this.fileId,
    required this.grade,
    required this.url,
    required this.storageDriver,
    required this.storageBucket,
    required this.storageKey,
    required this.migrationStatus,
    required this.fileSizeBytes,
    required this.contentHash,
    required this.uploadedAt,
  });

  final int id;
  final String academyId;
  final String fileId;
  final String grade;
  final String url;
  final String storageDriver;
  final String storageBucket;
  final String storageKey;
  final String migrationStatus;
  final int fileSizeBytes;
  final String contentHash;
  final String uploadedAt;

  factory TextbookLinkSnapshot.fromMap(Map<String, dynamic> map) {
    int asInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('$v') ?? 0;
    }

    return TextbookLinkSnapshot(
      id: asInt(map['id']),
      academyId: '${map['academy_id'] ?? ''}',
      fileId: '${map['file_id'] ?? ''}',
      grade: '${map['grade'] ?? ''}',
      url: '${map['url'] ?? ''}',
      storageDriver: '${map['storage_driver'] ?? ''}',
      storageBucket: '${map['storage_bucket'] ?? ''}',
      storageKey: '${map['storage_key'] ?? ''}',
      migrationStatus: '${map['migration_status'] ?? 'legacy'}',
      fileSizeBytes: asInt(map['file_size_bytes']),
      contentHash: '${map['content_hash'] ?? ''}',
      uploadedAt: '${map['uploaded_at'] ?? ''}',
    );
  }
}
