import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Resolves a textbook PDF into a usable local source for the in-app viewer.
///
/// Responsibilities:
/// 1. Ask the gateway (`/textbook/pdf/download-url`) how the link is currently
///    routed (`legacy` → Dropbox URL / `dual` or `migrated` → signed Supabase
///    URL).
/// 2. Cache downloaded bytes in the app's persistent support directory so we
///    only pay egress once per link id. Cache metadata lives in its own
///    SQLite database (`textbook_local_cache.db`) to keep the flow isolated
///    from the main academy DB.
/// 3. Fall back to the legacy Dropbox URL when the new path fails and the
///    row is still in `dual` state.
///
/// SECURITY TODO (pre-release):
/// - Encrypt downloaded bytes before writing to disk. The decrypt-in-memory
///   slot lives around `_writeCachedFile` / `resolve`.
/// - Thread a JWT (user/device bound) onto gateway requests instead of the
///   shared `x-api-key`.
class TextbookPdfService {
  TextbookPdfService._internal({
    SupabaseClient? supabaseClient,
    String? gatewayBaseUrl,
    http.Client? httpClient,
  })  : _supabaseOverride = supabaseClient,
        _gatewayBaseUrlOverride = gatewayBaseUrl {
    if (httpClient != null) _http = httpClient;
  }

  /// 네트워크 경로를 격리해 검증하기 위한 생성자.
  TextbookPdfService.forTesting({
    required SupabaseClient supabaseClient,
    required http.Client httpClient,
    String gatewayBaseUrl = '',
  }) : this._internal(
          supabaseClient: supabaseClient,
          httpClient: httpClient,
          gatewayBaseUrl: gatewayBaseUrl,
        );

  static final TextbookPdfService instance = TextbookPdfService._internal();

  http.Client _http = http.Client();
  Database? _db;
  String? _cacheDirPath;
  final SupabaseClient? _supabaseOverride;
  final String? _gatewayBaseUrlOverride;

  static const String _dbFileName = 'textbook_local_cache.db';
  static const String _cacheDirName = 'textbooks';

  static String _resolveGatewayUrl() {
    const dartDefine =
        String.fromEnvironment('PB_GATEWAY_URL', defaultValue: '');
    if (dartDefine.isNotEmpty) return _usableGatewayUrl(dartDefine);
    try {
      final envValue = Platform.environment['PB_GATEWAY_URL'] ?? '';
      if (envValue.isNotEmpty) return _usableGatewayUrl(envValue);
    } catch (_) {}
    return _isMobilePlatform ? '' : 'http://localhost:8787';
  }

  static bool get _isMobilePlatform {
    try {
      return Platform.isIOS || Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  static String _usableGatewayUrl(String raw) {
    final value = raw.trim();
    if (!_isMobilePlatform) return value;
    final uri = Uri.tryParse(value);
    final host = (uri?.host ?? '').toLowerCase();
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
      return '';
    }
    return value;
  }

  static String _resolveGatewayApiKey() {
    const dartDefine =
        String.fromEnvironment('PB_GATEWAY_API_KEY', defaultValue: '');
    if (dartDefine.isNotEmpty) return dartDefine;
    try {
      final envValue = Platform.environment['PB_GATEWAY_API_KEY'] ?? '';
      if (envValue.isNotEmpty) return envValue;
    } catch (_) {}
    return '';
  }

  String get _gatewayBaseUrl => _gatewayBaseUrlOverride ?? _resolveGatewayUrl();
  String get _gatewayApiKey => _resolveGatewayApiKey();
  bool get _hasGateway => _gatewayBaseUrl.isNotEmpty;
  SupabaseClient get _supabase => _supabaseOverride ?? Supabase.instance.client;

  Map<String, String> _headers() {
    final out = <String, String>{
      'Content-Type': 'application/json',
    };
    final key = _gatewayApiKey;
    if (key.isNotEmpty) out['x-api-key'] = key;
    return out;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = _gatewayBaseUrl.endsWith('/')
        ? _gatewayBaseUrl.substring(0, _gatewayBaseUrl.length - 1)
        : _gatewayBaseUrl;
    final pp = path.startsWith('/') ? path : '/$path';
    final u = Uri.parse('$base$pp');
    if (query == null || query.isEmpty) return u;
    return u.replace(queryParameters: query);
  }

  // ---------- Cache directory / DB lifecycle ----------

  Future<String> _ensureCacheDir() async {
    final cached = _cacheDirPath;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, _cacheDirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDirPath = dir.path;
    return dir.path;
  }

  Future<Database> _database() async {
    final cached = _db;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dbPath = p.join(support.path, _dbFileName);
    final db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE textbook_local_cache (
            link_id TEXT PRIMARY KEY,
            local_path TEXT NOT NULL,
            content_hash TEXT,
            size_bytes INTEGER,
            last_opened_at INTEGER,
            created_at INTEGER NOT NULL
          )
        ''');
      },
    );
    _db = db;
    return db;
  }

  Future<Map<String, Object?>?> _lookupCache(String linkId) async {
    final db = await _database();
    final rows = await db.query(
      'textbook_local_cache',
      where: 'link_id = ?',
      whereArgs: [linkId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first;
  }

  String _fallbackLinkKey(TextbookPdfRef ref) {
    if (ref.linkId != null) return '${ref.linkId}';
    return 'by_tuple:${ref.academyId}:${ref.fileId}:${ref.gradeLabel}:${ref.kind}';
  }

  Future<bool> _cacheExists(String linkKey) async {
    final row = await _lookupCache(linkKey);
    if (row == null) return false;
    final localPath = '${row['local_path'] ?? ''}'.trim();
    return localPath.isNotEmpty && await File(localPath).exists();
  }

  /// Checks whether a storage-backed textbook PDF has already been downloaded.
  ///
  /// This deliberately does not download. It only resolves the canonical
  /// link id from the gateway, then checks the local cache table.
  Future<bool> isCached(TextbookPdfRef ref) async {
    try {
      final target = await _resolveTarget(ref);
      final linkKey =
          target.linkId.isNotEmpty ? target.linkId : _fallbackLinkKey(ref);
      if (await _cacheExists(linkKey)) return true;
      final fallbackKey = _fallbackLinkKey(ref);
      if (fallbackKey != linkKey) {
        return _cacheExists(fallbackKey);
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeCache({
    required String linkId,
    required String localPath,
    required String contentHash,
    required int sizeBytes,
  }) async {
    final db = await _database();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'textbook_local_cache',
      {
        'link_id': linkId,
        'local_path': localPath,
        'content_hash': contentHash,
        'size_bytes': sizeBytes,
        'last_opened_at': nowMs,
        'created_at': nowMs,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> _touchCache(String linkId) async {
    final db = await _database();
    await db.update(
      'textbook_local_cache',
      {'last_opened_at': DateTime.now().millisecondsSinceEpoch},
      where: 'link_id = ?',
      whereArgs: [linkId],
    );
  }

  // ---------- Gateway round trips ----------

  Future<_ResolvedTarget> _resolveTarget(TextbookPdfRef ref) async {
    Object? gatewayError;
    if (_hasGateway) {
      try {
        return await _askGateway(ref);
      } catch (e) {
        gatewayError = e;
      }
    }
    try {
      return await _resolveFromSupabase(ref);
    } catch (e) {
      final prefix = gatewayError == null ? '' : 'gateway=$gatewayError; ';
      throw TextbookPdfException('${prefix}supabase_direct=$e');
    }
  }

  Future<_ResolvedTarget> _askGateway(TextbookPdfRef ref) async {
    final query = <String, String>{};
    if (ref.storageKey != null && ref.storageKey!.trim().isNotEmpty) {
      query['storage_key'] = ref.storageKey!.trim();
    }
    if (ref.linkId != null) {
      query['link_id'] = '${ref.linkId}';
    } else {
      query.addAll({
        if (ref.academyId != null) 'academy_id': ref.academyId!,
        if (ref.fileId != null) 'file_id': ref.fileId!,
        if (ref.gradeLabel != null) 'grade_label': ref.gradeLabel!,
        if (ref.kind != null) 'kind': ref.kind!,
      });
    }
    final uri = _uri('/textbook/pdf/download-url', query);
    final res = await _http.get(uri, headers: _headers());
    final body = _decodeJsonMap(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300 || body['ok'] != true) {
      throw TextbookPdfException(
        'gateway_download_url_failed(${res.statusCode}): ${body['error'] ?? res.body}',
      );
    }
    return _ResolvedTarget(
      kind: '${body['kind'] ?? 'storage'}',
      url: '${body['url'] ?? ''}',
      migrationStatus: '${body['migration_status'] ?? 'legacy'}',
      linkId: '${body['link_id'] ?? ''}',
      fileSizeBytes: _asInt(body['file_size_bytes']),
      contentHash: '${body['content_hash'] ?? ''}',
    );
  }

  Future<_ResolvedTarget> _resolveFromSupabase(TextbookPdfRef ref) async {
    const columns =
        'id,academy_id,file_id,grade,url,storage_driver,storage_bucket,'
        'storage_key,migration_status,file_size_bytes,content_hash,uploaded_at';
    dynamic row;
    final storageKey = ref.storageKey?.trim() ?? '';
    if (storageKey.isNotEmpty) {
      row = await _supabase
          .from('resource_file_links')
          .select(columns)
          .eq('storage_key', storageKey)
          .maybeSingle();
    }
    if (row == null && ref.linkId != null) {
      row = await _supabase
          .from('resource_file_links')
          .select(columns)
          .eq('id', ref.linkId!)
          .maybeSingle();
    }
    if (row == null &&
        ref.academyId != null &&
        ref.fileId != null &&
        ref.gradeLabel != null &&
        ref.kind != null) {
      final composite =
          '${ref.gradeLabel!.trim()}#${ref.kind!.trim().toLowerCase()}';
      row = await _supabase
          .from('resource_file_links')
          .select(columns)
          .eq('academy_id', ref.academyId!)
          .eq('file_id', ref.fileId!)
          .eq('grade', composite)
          .maybeSingle();
    }
    if (row == null) {
      throw TextbookPdfException('link_not_found');
    }

    final map = Map<String, dynamic>.from(row as Map<dynamic, dynamic>);
    final status = '${map['migration_status'] ?? 'legacy'}'.trim();
    final bucket = '${map['storage_bucket'] ?? ''}'.trim();
    final key = '${map['storage_key'] ?? ''}'.trim();
    final driver = '${map['storage_driver'] ?? ''}'.trim().toLowerCase();
    final legacyUrl = '${map['url'] ?? ''}'.trim();
    final linkId = '${map['id'] ?? ''}'.trim();
    final hasSupabaseStorage =
        bucket.isNotEmpty && key.isNotEmpty && driver == 'supabase';

    if (status == 'legacy' || !hasSupabaseStorage) {
      if (_looksLikeTextbookStoragePath(legacyUrl)) {
        final signed = await _supabase.storage
            .from(bucket.isEmpty ? 'textbooks' : bucket)
            .createSignedUrl(legacyUrl.split('?').first, 60 * 60);
        return _ResolvedTarget(
          kind: 'storage',
          url: signed,
          migrationStatus: status,
          linkId: linkId,
          fileSizeBytes: _asInt(map['file_size_bytes']),
          contentHash: '${map['content_hash'] ?? ''}',
          fallbackUrl: legacyUrl,
        );
      }
      if (legacyUrl.isEmpty) {
        throw TextbookPdfException('no_url_available');
      }
      return _ResolvedTarget(
        kind: 'legacy',
        url: legacyUrl,
        migrationStatus: status,
        linkId: linkId,
        fileSizeBytes: _asInt(map['file_size_bytes']),
        contentHash: '${map['content_hash'] ?? ''}',
      );
    }

    try {
      final signed =
          await _supabase.storage.from(bucket).createSignedUrl(key, 60 * 60);
      return _ResolvedTarget(
        kind: 'storage',
        url: signed,
        migrationStatus: status,
        linkId: linkId,
        fileSizeBytes: _asInt(map['file_size_bytes']),
        contentHash: '${map['content_hash'] ?? ''}',
        fallbackUrl: status == 'dual' ? legacyUrl : '',
      );
    } catch (e) {
      if (status == 'dual' && legacyUrl.isNotEmpty) {
        return _ResolvedTarget(
          kind: 'legacy',
          url: legacyUrl,
          migrationStatus: status,
          linkId: linkId,
          fileSizeBytes: _asInt(map['file_size_bytes']),
          contentHash: '${map['content_hash'] ?? ''}',
        );
      }
      throw TextbookPdfException('storage_signed_url_failed: $e');
    }
  }

  bool _looksLikeTextbookStoragePath(String value) {
    return RegExp(r'^academies/.+\.pdf(?:\?.*)?$', caseSensitive: false)
        .hasMatch(value);
  }

  Map<String, dynamic> _decodeJsonMap(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return v.map((k, dynamic val) => MapEntry('$k', val));
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  // ---------- Public API ----------

  /// Resolves a textbook PDF ref into a viewer source. Downloads and caches
  /// on first access when the row is in `dual` / `migrated` state; returns
  /// the legacy Dropbox URL for `legacy` rows so existing viewers keep
  /// working during the migration.
  ///
  /// [onProgress] receives (received, total) bytes while downloading. When
  /// the PDF is already cached locally it is not invoked.
  Future<TextbookPdfSource> resolve(
    TextbookPdfRef ref, {
    void Function(int received, int total)? onProgress,
  }) async {
    // SECURITY TODO (pre-release): insert device/user binding hook here.
    //   - Verify the active Supabase session & device ID before we even ask
    //     the gateway for a signed URL.
    //   - Example: await SecurityGate.instance.assertTextbookAccess(ref);

    // First ask the gateway so we know the current migration status and the
    // canonical link_id to key the cache off of.
    final target = await _resolveTarget(ref);
    final linkKey = target.linkId.isNotEmpty
        ? target.linkId
        : (ref.linkId != null
            ? '${ref.linkId}'
            : 'by_tuple:${ref.academyId}:${ref.fileId}:${ref.gradeLabel}:${ref.kind}');

    // Legacy rows: no storage download, just hand the Dropbox URL back so
    // the old flow (in-app `PdfViewer.uri` or external launcher) keeps
    // working.
    if (target.kind == 'legacy') {
      return TextbookPdfSource.legacyUrl(
        url: target.url,
        migrationStatus: target.migrationStatus,
        linkId: linkKey,
      );
    }

    // Dual / migrated: try to serve from the local cache first.
    final cached = await _lookupCache(linkKey);
    if (cached != null) {
      final localPath = '${cached['local_path']}';
      final file = File(localPath);
      if (await file.exists()) {
        final localSize = await file.length();
        final expectedSize = target.fileSizeBytes;
        if (expectedSize == 0 || expectedSize == localSize) {
          await _touchCache(linkKey);
          return TextbookPdfSource.localFile(
            path: localPath,
            migrationStatus: target.migrationStatus,
            linkId: linkKey,
          );
        }
        // Size mismatch -> treat as stale, wipe and redownload.
        try {
          await file.delete();
        } catch (_) {}
      }
    }

    // Download signed URL to local cache.
    try {
      final localPath = await _downloadAndStore(
        linkKey: linkKey,
        signedUrl: target.url,
        onProgress: onProgress,
      );
      return TextbookPdfSource.localFile(
        path: localPath,
        migrationStatus: target.migrationStatus,
        linkId: linkKey,
      );
    } catch (e) {
      // Dual rows still have a Dropbox URL we can fall back to. Ask the
      // gateway again forcing legacy awareness by catching the next GET; in
      // practice we can just return the signed URL as a streaming viewer
      // source so the dialog can use `PdfViewer.uri` without caching.
      if (target.migrationStatus == 'dual') {
        if (target.fallbackUrl.isNotEmpty) {
          return TextbookPdfSource.legacyUrl(
            url: target.fallbackUrl,
            migrationStatus: target.migrationStatus,
            linkId: linkKey,
          );
        }
        return TextbookPdfSource.remoteUrl(
          url: target.url,
          migrationStatus: target.migrationStatus,
          linkId: linkKey,
          error: '$e',
        );
      }
      rethrow;
    }
  }

  /// Resolves a single page of a (large) textbook PDF into a tiny local
  /// single-page PDF with the original resolution preserved. The gateway
  /// losslessly extracts the page (`pdfseparate`) and caches it in Storage, so
  /// the heavy original is never downloaded by the client.
  ///
  /// Returns null when the link is not storage-backed (e.g. still `legacy`),
  /// letting callers fall back to the full-PDF flow.
  Future<TextbookPagePdf?> resolvePage(TextbookPdfRef ref, int page) async {
    if (page < 1 || !_hasGateway) return null;
    final query = <String, String>{'page': '$page'};
    if (ref.storageKey != null && ref.storageKey!.trim().isNotEmpty) {
      query['storage_key'] = ref.storageKey!.trim();
    }
    if (ref.linkId != null) {
      query['link_id'] = '${ref.linkId}';
    } else {
      if (ref.academyId != null) query['academy_id'] = ref.academyId!;
      if (ref.fileId != null) query['file_id'] = ref.fileId!;
      if (ref.gradeLabel != null) query['grade_label'] = ref.gradeLabel!;
      if (ref.kind != null) query['kind'] = ref.kind!;
    }
    late http.Response res;
    try {
      final uri = _uri('/textbook/pdf/page', query);
      res = await _http.get(uri, headers: _headers());
    } catch (_) {
      // 단일 페이지 추출은 Gateway 최적화 기능이다. 연결할 수 없으면
      // 호출자가 전체 PDF 로컬 캐시 경로를 사용하도록 한다.
      return null;
    }
    final body = _decodeJsonMap(res.body);
    if (res.statusCode == 409) {
      // Not eligible for page splitting (legacy / no storage) -> fall back.
      return null;
    }
    if (res.statusCode < 200 || res.statusCode >= 300 || body['ok'] != true) {
      throw TextbookPdfException(
        'gateway_page_failed(${res.statusCode}): ${body['error'] ?? res.body}',
      );
    }
    final signedUrl = '${body['url'] ?? ''}'.trim();
    if (signedUrl.isEmpty) return null;
    final linkId = '${body['link_id'] ?? ''}'.trim();
    final localPageRaw = body['local_page'];
    final localPage =
        localPageRaw is int ? localPageRaw : (_asInt(localPageRaw));
    final linkKey = linkId.isNotEmpty
        ? 'link_$linkId'
        : 'tuple_${ref.academyId}_${ref.fileId}_${ref.gradeLabel}_${ref.kind}';
    final localPath = await _downloadPageToCache(
      linkKey: linkKey,
      page: page,
      signedUrl: signedUrl,
    );
    return TextbookPagePdf(
      localPath: localPath,
      sourcePage: page,
      localPage: localPage >= 1 ? localPage : 1,
      linkId: linkId,
    );
  }

  Future<String> _downloadPageToCache({
    required String linkKey,
    required int page,
    required String signedUrl,
  }) async {
    final dirPath = await _ensureCacheDir();
    final pagesDir = Directory(p.join(dirPath, 'pages'));
    if (!await pagesDir.exists()) {
      await pagesDir.create(recursive: true);
    }
    final sanitized = linkKey.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final destPath = p.join(pagesDir.path, '${sanitized}_p$page.pdf');
    final destFile = File(destPath);
    if (await destFile.exists() && await destFile.length() > 0) {
      return destPath;
    }
    final request = http.Request('GET', Uri.parse(signedUrl));
    final streamed = await _http.send(request);
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      final b = await streamed.stream.bytesToString();
      throw TextbookPdfException(
        'page_download_failed(${streamed.statusCode}): $b',
      );
    }
    final tmpPath = '$destPath.download';
    final sink = File(tmpPath).openWrite();
    try {
      await streamed.stream.pipe(sink);
      await sink.flush();
      await sink.close();
      final tmpFile = File(tmpPath);
      if (await destFile.exists()) {
        try {
          await destFile.delete();
        } catch (_) {}
      }
      await tmpFile.rename(destPath);
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        await File(tmpPath).delete();
      } catch (_) {}
      rethrow;
    }
    return destPath;
  }

  Future<String> _downloadAndStore({
    required String linkKey,
    required String signedUrl,
    void Function(int received, int total)? onProgress,
  }) async {
    final request = http.Request('GET', Uri.parse(signedUrl));
    final streamed = await _http.send(request);
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      final body = await streamed.stream.bytesToString();
      throw TextbookPdfException(
        'storage_download_failed(${streamed.statusCode}): $body',
      );
    }
    final total = streamed.contentLength ?? 0;
    final dirPath = await _ensureCacheDir();
    final sanitized = linkKey.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final destPath = p.join(dirPath, '$sanitized.pdf');
    final tempPath = p.join(dirPath, '$sanitized.pdf.download');
    // SECURITY TODO (pre-release): encrypt the bytes that get flushed to
    // disk. Wrap `sink` in an AES-GCM encrypting IOSink whose key is derived
    // from (user_id, device_id) via flutter_secure_storage. The viewer will
    // need a matching decrypt step when feeding bytes to pdfrx.
    final sink = File(tempPath).openWrite();
    final digestSink = _DigestSink();
    final chunkedSha = sha256.startChunkedConversion(digestSink);
    int received = 0;
    try {
      await for (final chunk in streamed.stream) {
        sink.add(chunk);
        chunkedSha.add(chunk);
        received += chunk.length;
        if (onProgress != null) {
          onProgress(received, total);
        }
      }
      await sink.flush();
      await sink.close();
      chunkedSha.close();
      final tempFile = File(tempPath);
      final destFile = File(destPath);
      if (await destFile.exists()) {
        try {
          await destFile.delete();
        } catch (_) {}
      }
      await tempFile.rename(destPath);
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        await File(tempPath).delete();
      } catch (_) {}
      rethrow;
    }
    final size = await File(destPath).length();
    await _writeCache(
      linkId: linkKey,
      localPath: destPath,
      contentHash: digestSink.hexDigest(),
      sizeBytes: size,
    );
    return destPath;
  }

  /// Deletes one cached entry. Used by manual eviction buttons or after
  /// rollback to `legacy` (in case we want a fresh Dropbox fetch).
  Future<void> evict(String linkId) async {
    final row = await _lookupCache(linkId);
    if (row == null) return;
    final localPath = '${row['local_path']}';
    try {
      final f = File(localPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    final db = await _database();
    await db.delete(
      'textbook_local_cache',
      where: 'link_id = ?',
      whereArgs: [linkId],
    );
  }

  /// Wipes every cached textbook PDF plus its metadata entry.
  Future<void> evictAll() async {
    final db = await _database();
    final rows = await db.query('textbook_local_cache');
    for (final row in rows) {
      try {
        final f = File('${row['local_path']}');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    await db.delete('textbook_local_cache');
  }

  /// Returns the total number of bytes currently held on disk.
  Future<int> cacheSizeBytes() async {
    final db = await _database();
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(size_bytes), 0) AS total FROM textbook_local_cache',
    );
    if (rows.isEmpty) return 0;
    return _asInt(rows.first['total']);
  }

  // Testing hook: override HTTP client in unit tests.
  set httpClientForTesting(http.Client client) {
    _http = client;
  }
}

/// Logical identifier for a textbook PDF as seen from the student app.
class TextbookPdfRef {
  const TextbookPdfRef({
    this.linkId,
    this.academyId,
    this.fileId,
    this.gradeLabel,
    this.kind,
    this.storageKey,
    this.displayName,
  });

  /// Preferred identifier once the row exists in `resource_file_links`.
  final int? linkId;

  /// Tuple identifiers used when the caller does not have the row id handy.
  final String? academyId;
  final String? fileId;
  final String? gradeLabel;
  final String? kind; // 'body' | 'ans' | 'sol'

  /// Canonical storage key (`academies/.../<seg>/<kind>.pdf`). Preferred for
  /// resolution because the grade composite in the DB can differ from the
  /// path segment (courseKey vs courseLabel) for high-school books.
  final String? storageKey;

  /// Optional display name for the viewer title bar.
  final String? displayName;
}

/// The three possible viewer source shapes produced by
/// [TextbookPdfService.resolve].
class TextbookPdfSource {
  const TextbookPdfSource._({
    required this.type,
    required this.migrationStatus,
    required this.linkId,
    this.localPath,
    this.url,
    this.fallbackError,
  });

  factory TextbookPdfSource.localFile({
    required String path,
    required String migrationStatus,
    required String linkId,
  }) =>
      TextbookPdfSource._(
        type: TextbookPdfSourceType.localFile,
        localPath: path,
        migrationStatus: migrationStatus,
        linkId: linkId,
      );

  factory TextbookPdfSource.legacyUrl({
    required String url,
    required String migrationStatus,
    required String linkId,
  }) =>
      TextbookPdfSource._(
        type: TextbookPdfSourceType.legacyUrl,
        url: url,
        migrationStatus: migrationStatus,
        linkId: linkId,
      );

  factory TextbookPdfSource.remoteUrl({
    required String url,
    required String migrationStatus,
    required String linkId,
    String? error,
  }) =>
      TextbookPdfSource._(
        type: TextbookPdfSourceType.remoteUrl,
        url: url,
        migrationStatus: migrationStatus,
        linkId: linkId,
        fallbackError: error,
      );

  final TextbookPdfSourceType type;
  final String migrationStatus;
  final String linkId;
  final String? localPath;
  final String? url;
  final String? fallbackError;
}

enum TextbookPdfSourceType { localFile, legacyUrl, remoteUrl }

/// A losslessly-extracted single page of a textbook PDF, cached locally.
class TextbookPagePdf {
  const TextbookPagePdf({
    required this.localPath,
    required this.sourcePage,
    required this.localPage,
    required this.linkId,
  });

  /// Local file path to the tiny single-page PDF.
  final String localPath;

  /// The page number in the original document.
  final int sourcePage;

  /// The page index within the extracted PDF (1 for a single-page extract).
  final int localPage;

  final String linkId;
}

class _ResolvedTarget {
  _ResolvedTarget({
    required this.kind,
    required this.url,
    required this.migrationStatus,
    required this.linkId,
    required this.fileSizeBytes,
    required this.contentHash,
    this.fallbackUrl = '',
  });
  final String kind; // 'storage' | 'legacy'
  final String url;
  final String migrationStatus;
  final String linkId;
  final int fileSizeBytes;
  final String contentHash;
  final String fallbackUrl;
}

class TextbookPdfException implements Exception {
  TextbookPdfException(this.message);
  final String message;
  @override
  String toString() => 'TextbookPdfException: $message';
}

/// Captures the final [Digest] emitted by a chunked sha256 conversion so we
/// can keep the hashing truly streaming (important for ~250MB textbook PDFs).
class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  @override
  void add(Digest data) {
    _digest = data;
  }

  @override
  void close() {}

  String hexDigest() => (_digest ?? sha256.convert(const [])).toString();
}
