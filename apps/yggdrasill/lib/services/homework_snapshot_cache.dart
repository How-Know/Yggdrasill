import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef HomeworkSnapshotDirectoryProvider = Future<Directory> Function();

/// Disk-backed, tenant-scoped last-known-good homework snapshot.
///
/// Snapshots are only a cold-start hint. The server remains the source of
/// truth and [HomeworkStore] refreshes the snapshot after successful reads.
class HomeworkSnapshotCache {
  HomeworkSnapshotCache({
    HomeworkSnapshotDirectoryProvider? directoryProvider,
  }) : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  static const int schemaVersion = 1;
  static const String _directoryName = 'homework_snapshots';

  final HomeworkSnapshotDirectoryProvider _directoryProvider;

  Future<Map<String, dynamic>?> read(String academyId) async {
    final id = academyId.trim();
    if (id.isEmpty) return null;
    try {
      final file = await _fileFor(id);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      if (map['schemaVersion'] != schemaVersion ||
          map['academyId'] != id ||
          map['items'] is! List ||
          map['groups'] is! List ||
          map['groupItems'] is! List) {
        return null;
      }
      return map;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(
    String academyId,
    Map<String, dynamic> payload,
  ) async {
    final id = academyId.trim();
    if (id.isEmpty) return;
    final file = await _fileFor(id);
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    final document = <String, dynamic>{
      ...payload,
      'schemaVersion': schemaVersion,
      'academyId': id,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
    };
    await temp.writeAsString(jsonEncode(document), flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await temp.rename(file.path);
  }

  Future<void> delete(String academyId) async {
    final id = academyId.trim();
    if (id.isEmpty) return;
    try {
      final file = await _fileFor(id);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<File> _fileFor(String academyId) async {
    final root = await _directoryProvider();
    final safeId = academyId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return File(p.join(root.path, _directoryName, '$safeId.json'));
  }
}
