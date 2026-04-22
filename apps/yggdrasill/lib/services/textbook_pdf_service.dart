import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

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
  TextbookPdfService._internal();

  static final TextbookPdfService instance = TextbookPdfService._internal();

  http.Client _http = http.Client();
  Database? _db;
  String? _cacheDirPath;

  static const String _dbFileName = 'textbook_local_cache.db';
  static const String _cacheDirName = 'textbooks';

  static String _resolveGatewayUrl() {
    const dartDefine =
        String.fromEnvironment('PB_GATEWAY_URL', defaultValue: '');
    if (dartDefine.isNotEmpty) return dartDefine;
    try {
      final envValue = Platform.environment['PB_GATEWAY_URL'] ?? '';
      if (envValue.isNotEmpty) return envValue;
    } catch (_) {}
    return 'http://localhost:8787';
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

  String get _gatewayBaseUrl => _resolveGatewayUrl();
  String get _gatewayApiKey => _resolveGatewayApiKey();

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

  Future<_ResolvedTarget> _askGateway(TextbookPdfRef ref) async {
    final query = <String, String>{};
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
    final target = await _askGateway(ref);
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
    this.displayName,
  });

  /// Preferred identifier once the row exists in `resource_file_links`.
  final int? linkId;

  /// Tuple identifiers used when the caller does not have the row id handy.
  final String? academyId;
  final String? fileId;
  final String? gradeLabel;
  final String? kind; // 'body' | 'ans' | 'sol'

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

class _ResolvedTarget {
  _ResolvedTarget({
    required this.kind,
    required this.url,
    required this.migrationStatus,
    required this.linkId,
    required this.fileSizeBytes,
    required this.contentHash,
  });
  final String kind; // 'storage' | 'legacy'
  final String url;
  final String migrationStatus;
  final String linkId;
  final int fileSizeBytes;
  final String contentHash;
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
