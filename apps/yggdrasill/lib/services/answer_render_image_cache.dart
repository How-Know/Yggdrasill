import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// On-disk cache for answer render / answer image PNGs.
///
/// Storage URLs are re-signed on every fetch, so the URL itself cannot be a
/// cache key. Callers pass a stable key derived from the storage object path,
/// which keeps the bytes reusable across sessions and across re-signing.
class AnswerRenderImageCache {
  AnswerRenderImageCache._();

  static final AnswerRenderImageCache instance = AnswerRenderImageCache._();

  static const String _dirName = 'answer_render_cache';
  static const Duration _maxAge = Duration(days: 30);
  static const int _maxBytes = 256 * 1024 * 1024;

  final http.Client _http = http.Client();
  final Map<String, Future<Uint8List>> _inflight = <String, Future<Uint8List>>{};
  String? _dirPath;
  bool _pruneScheduled = false;

  /// Builds a filesystem-safe, collision-resistant key from a signed URL.
  ///
  /// Only the object path is used; the `token` query parameter changes on every
  /// signing and would otherwise defeat the cache.
  static String cacheKeyForUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return '';
    final path = Uri.tryParse(trimmed)?.path ?? trimmed;
    final digest = md5.convert(utf8.encode(path)).toString();
    final segments = path.split('/').where((e) => e.isNotEmpty).toList();
    final tail = segments.isEmpty ? '' : segments.last;
    final safeTail =
        tail.replaceAll('.png', '').replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final shortTail = safeTail.length <= 32
        ? safeTail
        : safeTail.substring(safeTail.length - 32);
    return shortTail.isEmpty ? digest : '${digest}_$shortTail';
  }

  Future<String> _ensureDir() async {
    final cached = _dirPath;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, _dirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dirPath = dir.path;
    _schedulePrune();
    return dir.path;
  }

  Future<Uint8List> loadBytes({
    required String url,
    required String cacheKey,
  }) {
    final safeKey = cacheKey.trim().isEmpty ? cacheKeyForUrl(url) : cacheKey.trim();
    final existing = _inflight[safeKey];
    if (existing != null) return existing;
    final future = _loadBytes(url: url, cacheKey: safeKey);
    _inflight[safeKey] = future;
    return future.whenComplete(() => _inflight.remove(safeKey));
  }

  Future<Uint8List> _loadBytes({
    required String url,
    required String cacheKey,
  }) async {
    File? file;
    try {
      final dir = await _ensureDir();
      final candidate = File(p.join(dir, '$cacheKey.png'));
      file = candidate;
      if (await candidate.exists()) {
        final bytes = await candidate.readAsBytes();
        if (bytes.isNotEmpty) {
          unawaited(
            candidate.setLastAccessed(DateTime.now()).catchError((_) {}),
          );
          return bytes;
        }
      }
    } catch (_) {
      file = null;
    }
    final uri = Uri.tryParse(url.trim());
    if (uri == null) throw StateError('invalid answer render url');
    final res = await _http.get(uri);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('answer render fetch failed (${res.statusCode})');
    }
    final bytes = res.bodyBytes;
    if (bytes.isEmpty) throw StateError('answer render body empty');
    final target = file;
    if (target != null) {
      unawaited(
        target.writeAsBytes(bytes, flush: false).catchError((_) => target),
      );
    }
    return bytes;
  }

  void _schedulePrune() {
    if (_pruneScheduled) return;
    _pruneScheduled = true;
    Future<void>.delayed(const Duration(seconds: 20), () async {
      try {
        await _prune();
      } catch (_) {}
    });
  }

  Future<void> _prune() async {
    final dirPath = _dirPath;
    if (dirPath == null) return;
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;
    final now = DateTime.now();
    final entries = <({File file, DateTime accessed, int size})>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        final stat = await entity.stat();
        if (now.difference(stat.accessed) > _maxAge) {
          await entity.delete();
          continue;
        }
        entries.add((file: entity, accessed: stat.accessed, size: stat.size));
      } catch (_) {}
    }
    var total = entries.fold<int>(0, (sum, e) => sum + e.size);
    if (total <= _maxBytes) return;
    entries.sort((a, b) => a.accessed.compareTo(b.accessed));
    for (final entry in entries) {
      if (total <= _maxBytes) break;
      try {
        await entry.file.delete();
        total -= entry.size;
      } catch (_) {}
    }
  }
}

/// [ImageProvider] that reads answer PNGs through [AnswerRenderImageCache].
///
/// Equality is based on the stable cache key rather than the URL so that a
/// freshly signed URL still hits Flutter's in-memory image cache.
@immutable
class AnswerRenderImageProvider extends ImageProvider<AnswerRenderImageProvider> {
  AnswerRenderImageProvider(this.url, {String? cacheKey, this.scale = 1.0})
      : cacheKey = (cacheKey == null || cacheKey.trim().isEmpty)
            ? AnswerRenderImageCache.cacheKeyForUrl(url)
            : cacheKey.trim();

  final String url;
  final String cacheKey;
  final double scale;

  @override
  Future<AnswerRenderImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<AnswerRenderImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    AnswerRenderImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadCodec(key, decode),
      scale: key.scale,
      debugLabel: key.cacheKey,
    );
  }

  Future<ui.Codec> _loadCodec(
    AnswerRenderImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await AnswerRenderImageCache.instance.loadBytes(
      url: key.url,
      cacheKey: key.cacheKey,
    );
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AnswerRenderImageProvider &&
        other.cacheKey == cacheKey &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(cacheKey, scale);

  @override
  String toString() => 'AnswerRenderImageProvider($cacheKey)';
}
