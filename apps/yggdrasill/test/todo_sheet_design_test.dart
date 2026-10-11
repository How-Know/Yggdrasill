import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/widgets/homework_assign_dialog.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('both todo sheet designs render a two-page PDF', () async {
    final outDir = Platform.environment['TODO_SHEET_PREVIEW_DIR'];
    for (final design in TodoSheetDesign.values) {
      final bytes = await renderTodoSheetSample(design);
      expect(bytes.length, greaterThan(1000));
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      if (outDir != null && outDir.isNotEmpty) {
        await Directory(outDir).create(recursive: true);
        await File(p.join(outDir, '${design.name}.pdf')).writeAsBytes(bytes);
      }
    }
  });

  test('design preference defaults to classic and persists', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await loadTodoSheetDesign(), TodoSheetDesign.classic);
    await saveTodoSheetDesign(TodoSheetDesign.refined);
    expect(await loadTodoSheetDesign(), TodoSheetDesign.refined);
  });
}
