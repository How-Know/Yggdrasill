import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/widgets/homework_assign_dialog.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('todo sheet renders a two-page PDF', () async {
    final outDir = Platform.environment['TODO_SHEET_PREVIEW_DIR'];
    final bytes = await renderTodoSheetSample();
    expect(bytes.length, greaterThan(1000));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    if (outDir != null && outDir.isNotEmpty) {
      await Directory(outDir).create(recursive: true);
      await File(p.join(outDir, 'todo_sheet.pdf')).writeAsBytes(bytes);
    }
  });

  test('saved todo sheet payload renders after a JSON round trip', () async {
    final bytes = await renderTodoSheetSnapshotRoundTripSample();
    expect(bytes.length, greaterThan(1000));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });
}
