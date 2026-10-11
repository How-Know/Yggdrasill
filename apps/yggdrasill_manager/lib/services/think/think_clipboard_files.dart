import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

const thinkDropNoFilesMessage = '끌어온 곳에서 파일을 받지 못했습니다. 브라우저·메신저 이미지는 복사(Ctrl+C)한 뒤 '
    '입력창에서 Ctrl+V로 붙여 넣거나, 파일로 저장해 끌어다 놓아 주세요.';

/// Ctrl+V 또는 Shift+Insert.
bool isThinkPasteKey(LogicalKeyboardKey key, HardwareKeyboard keyboard) =>
    (key == LogicalKeyboardKey.keyV && keyboard.isControlPressed && !keyboard.isAltPressed) ||
    (key == LogicalKeyboardKey.insert && keyboard.isShiftPressed);

/// 클립보드에서 첨부할 파일 경로를 꺼낸다. Windows 전용(그 밖에는 빈 결과).
///   탐색기에서 복사한 파일 → 그 경로.
///   캡처·브라우저 '이미지 복사' 같은 이미지 → 임시 폴더에 PNG로 저장한 경로(첨부가 끝나면 [ThinkClipboardFiles.dispose]).
/// 브라우저·메신저에서 끌어온 이미지는 Windows가 파일 경로를 넘겨주지 않아 끌어다 놓기로는 받을 수 없어 이 길을 쓴다.
class ThinkClipboardFiles {
  ThinkClipboardFiles._(this.paths, this._tempDir);

  static const empty = ThinkClipboardFiles._const();
  const ThinkClipboardFiles._const()
      : paths = const [],
        _tempDir = null;

  final List<String> paths;
  final Directory? _tempDir;

  static const _script = r'''
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if ([Windows.Forms.Clipboard]::ContainsFileDropList()) {
  foreach ($f in [Windows.Forms.Clipboard]::GetFileDropList()) { "F`t$f" }
  exit 0
}
$img = [Windows.Forms.Clipboard]::GetImage()
if ($img -ne $null) {
  $img.Save($env:THINK_PASTE_PNG, [Drawing.Imaging.ImageFormat]::Png)
  "I`t$env:THINK_PASTE_PNG"
  exit 0
}
exit 3
''';

  static Future<ThinkClipboardFiles> read() async {
    if (!Platform.isWindows) return empty;
    final dir = await Directory.systemTemp.createTemp('think_paste_');
    final png = p.join(dir.path, 'clipboard_${DateTime.now().millisecondsSinceEpoch}.png');
    try {
      final r = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-STA', '-EncodedCommand', encodedScript()],
        environment: {'THINK_PASTE_PNG': png},
        stdoutEncoding: utf8,
      ).timeout(const Duration(seconds: 10));
      final paths = r.exitCode == 0 ? parse(r.stdout as String) : const <String>[];
      final usesTemp = paths.contains(png);
      if (!usesTemp) await _delete(dir);
      return paths.isEmpty ? empty : ThinkClipboardFiles._(paths, usesTemp ? dir : null);
    } catch (_) {
      await _delete(dir);
      return empty;
    }
  }

  /// -EncodedCommand 값(UTF-16LE base64). -Command로 넘기면 Windows 인자 처리에서 따옴표가 빠진다.
  static String encodedScript() {
    final bytes = <int>[];
    for (final unit in _script.codeUnits) {
      bytes
        ..add(unit & 0xff)
        ..add(unit >> 8);
    }
    return base64.encode(bytes);
  }

  /// PowerShell 출력(줄마다 `F\t경로` 또는 `I\t경로`)에서 경로만.
  static List<String> parse(String out) => [
        for (final line in const LineSplitter().convert(out))
          if (line.length > 2 && (line.startsWith('F\t') || line.startsWith('I\t'))) line.substring(2).trim(),
      ].where((e) => e.isNotEmpty).toList();

  Future<void> dispose() async {
    final dir = _tempDir;
    if (dir != null) await _delete(dir);
  }

  static Future<void> _delete(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // 임시 폴더는 OS가 정리한다
    }
  }
}
