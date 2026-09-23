import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/services/homework_snapshot_cache.dart';

void main() {
  late Directory root;
  late HomeworkSnapshotCache cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('homework_snapshot_test_');
    cache = HomeworkSnapshotCache(directoryProvider: () async => root);
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('round trips a valid tenant-scoped snapshot', () async {
    await cache.write('academy-a', {
      'items': [
        {'id': 'item-1'}
      ],
      'groups': const [],
      'groupItems': const [],
    });

    final restored = await cache.read('academy-a');

    expect(restored, isNotNull);
    expect(restored!['academyId'], 'academy-a');
    expect(restored['schemaVersion'], HomeworkSnapshotCache.schemaVersion);
    expect((restored['items'] as List).single['id'], 'item-1');
    expect(await cache.read('academy-b'), isNull);
  });

  test('ignores corrupt or incompatible snapshots', () async {
    await cache.write('academy-a', {
      'items': const [],
      'groups': const [],
      'groupItems': const [],
    });
    final files = root.listSync(recursive: true).whereType<File>().toList();
    expect(files, hasLength(1));

    await files.single.writeAsString('{broken');
    expect(await cache.read('academy-a'), isNull);
  });
}
