import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PrintRoutingChannel {
  general,
  todoSheet,
}

class PrintRoutingService {
  PrintRoutingService._internal();
  static final PrintRoutingService instance = PrintRoutingService._internal();

  static const String _kGeneralPrinterKey = 'print_routing.general_printer';
  static const String _kTodoPrinterKey = 'print_routing.todo_printer';

  String _prefKeyOf(PrintRoutingChannel channel) {
    switch (channel) {
      case PrintRoutingChannel.general:
        return _kGeneralPrinterKey;
      case PrintRoutingChannel.todoSheet:
        return _kTodoPrinterKey;
    }
  }

  String _psSingleQuoted(String input) => "'${input.replaceAll("'", "''")}'";

  void _printLog(String source, String message) {
    final ts = DateTime.now().toIso8601String();
    print('[PRINT][$ts][$source] $message');
  }

  String _compact(Object? value, {int max = 280}) {
    final raw =
        (value ?? '').toString().replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (raw.length <= max) return raw;
    return '${raw.substring(0, max)}...';
  }

  String? _resolveAcrobatExecutablePath() {
    const candidates = <String>[
      r'C:\Program Files\Adobe\Acrobat DC\Acrobat\Acrobat.exe',
      r'C:\Program Files\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe',
      r'C:\Program Files (x86)\Adobe\Acrobat DC\Acrobat\Acrobat.exe',
      r'C:\Program Files (x86)\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  Future<({String driver, String port})?> _loadWindowsPrinterMeta(
      String printerName) async {
    if (!Platform.isWindows) return null;
    final escapedName = printerName.replaceAll("'", "''");
    try {
      final result = await Process.run(
        'powershell',
        <String>[
          '-NoProfile',
          '-Command',
          "\$p = Get-CimInstance -ClassName Win32_Printer | Where-Object { \$_.Name -eq '$escapedName' } | Select-Object -First 1; if (\$null -ne \$p) { Write-Output \"\$(\$p.DriverName)||\$(\$p.PortName)\" }",
        ],
      );
      if (result.exitCode != 0) return null;
      final line = (result.stdout?.toString() ?? '')
          .split(RegExp(r'[\r\n]+'))
          .map((e) => e.trim())
          .firstWhere(
            (e) => e.isNotEmpty,
            orElse: () => '',
          );
      if (line.isEmpty || !line.contains('||')) return null;
      final parts = line.split('||');
      if (parts.length < 2) return null;
      final driver = parts[0].trim();
      final port = parts[1].trim();
      if (driver.isEmpty || port.isEmpty) return null;
      return (driver: driver, port: port);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _tryDirectAcrobatPrintTo({
    required String target,
    required String printerName,
    required String debugSource,
  }) async {
    if (!Platform.isWindows) return false;
    if (!target.toLowerCase().endsWith('.pdf')) return false;
    final normalizedPrinter = printerName.trim();
    if (normalizedPrinter.isEmpty) return false;

    final acrobatExe = _resolveAcrobatExecutablePath();
    if (acrobatExe == null) {
      _printLog(debugSource, 'Acrobat executable not found for direct /t.');
      return false;
    }

    final meta = await _loadWindowsPrinterMeta(normalizedPrinter);
    if (meta == null) {
      _printLog(
        debugSource,
        'Printer meta(driver/port) not found for "$normalizedPrinter".',
      );
      return false;
    }

    try {
      _printLog(
        debugSource,
        'Try direct Acrobat /t exe="$acrobatExe" printer="$normalizedPrinter" driver="${meta.driver}" port="${meta.port}"',
      );
      final process = await Process.start(
        acrobatExe,
        <String>[
          '/n',
          '/s',
          '/o',
          '/h',
          '/t',
          target,
          normalizedPrinter,
          meta.driver,
          meta.port,
        ],
        runInShell: false,
      );
      _printLog(
        debugSource,
        'Direct Acrobat /t process started pid=${process.pid}',
      );
      unawaited(process.exitCode.then((code) {
        _printLog(debugSource, 'Direct Acrobat /t process exit=$code');
      }));
      unawaited(process.stdout.transform(utf8.decoder).join().then((out) {
        final msg = out.trim();
        if (msg.isNotEmpty) {
          _printLog(debugSource, 'Direct Acrobat /t stdout="${_compact(msg)}"');
        }
      }));
      unawaited(process.stderr.transform(utf8.decoder).join().then((err) {
        final msg = err.trim();
        if (msg.isNotEmpty) {
          _printLog(debugSource, 'Direct Acrobat /t stderr="${_compact(msg)}"');
        }
      }));
      return true;
    } catch (_) {
      _printLog(debugSource, 'Direct Acrobat /t threw exception.');
      return false;
    }
  }

  Future<List<String>> listInstalledPrinters() async {
    if (!Platform.isWindows) return const <String>[];
    try {
      final result = await Process.run(
        'powershell',
        <String>[
          '-NoProfile',
          '-Command',
          'Get-CimInstance -ClassName Win32_Printer | Select-Object -ExpandProperty Name',
        ],
      );
      if (result.exitCode != 0) return const <String>[];
      final out = result.stdout?.toString() ?? '';
      final printers = out
          .split(RegExp(r'[\r\n]+'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return printers;
    } catch (_) {
      return const <String>[];
    }
  }

  Future<String?> loadConfiguredPrinter(PrintRoutingChannel channel) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = (prefs.getString(_prefKeyOf(channel)) ?? '').trim();
    return raw.isEmpty ? null : raw;
  }

  Future<void> saveConfiguredPrinter({
    required PrintRoutingChannel channel,
    required String? printerName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = (printerName ?? '').trim();
    final key = _prefKeyOf(channel);
    if (normalized.isEmpty) {
      await prefs.remove(key);
      return;
    }
    await prefs.setString(key, normalized);
  }

  Future<void> printFile({
    required String path,
    required PrintRoutingChannel channel,
    String debugSource = 'unknown',
  }) async {
    final target = path.trim();
    if (target.isEmpty) {
      _printLog(debugSource, 'printFile skipped: empty path');
      return;
    }

    final configuredPrinter = await loadConfiguredPrinter(channel);
    final exists = await File(target).exists();
    _printLog(
      debugSource,
      'printFile request channel=$channel exists=$exists printer="${configuredPrinter ?? ''}" path="$target"',
    );
    await _printWithRouting(
      target: target,
      printerName: configuredPrinter,
      channel: channel,
      debugSource: debugSource,
    );
  }

  Future<void> _printWithRouting({
    required String target,
    required String? printerName,
    required PrintRoutingChannel channel,
    required String debugSource,
  }) async {
    try {
      if (Platform.isWindows) {
        final qPath = _psSingleQuoted(target);
        final normalizedPrinter = (printerName ?? '').trim();
        _printLog(
          debugSource,
          'Windows route start channel=$channel printer="${normalizedPrinter.isEmpty ? '(none)' : normalizedPrinter}"',
        );
        if (normalizedPrinter.isNotEmpty) {
          final directAcrobatPrinted = await _tryDirectAcrobatPrintTo(
            target: target,
            printerName: normalizedPrinter,
            debugSource: debugSource,
          );
          if (directAcrobatPrinted) {
            _printLog(debugSource, 'Printed via direct Acrobat /t route.');
            return;
          }

          final qPrinter = _psSingleQuoted(normalizedPrinter);
          final printTo = await Process.run(
            'powershell',
            <String>[
              '-NoProfile',
              '-Command',
              'Start-Process -FilePath $qPath -Verb PrintTo -ArgumentList $qPrinter',
            ],
            runInShell: true,
          );
          _printLog(
            debugSource,
            'PrintTo exit=${printTo.exitCode} stdout="${_compact(printTo.stdout)}" stderr="${_compact(printTo.stderr)}"',
          );
          if (printTo.exitCode == 0) {
            _printLog(debugSource, 'Printed via PowerShell PrintTo route.');
            return;
          }
        }

        final printResult = await Process.run(
          'powershell',
          <String>[
            '-NoProfile',
            '-Command',
            'Start-Process -FilePath $qPath -Verb Print',
          ],
          runInShell: true,
        );
        _printLog(
          debugSource,
          'Print fallback exit=${printResult.exitCode} stdout="${_compact(printResult.stdout)}" stderr="${_compact(printResult.stderr)}"',
        );
        if (printResult.exitCode == 0) {
          _printLog(debugSource, 'Printed via PowerShell Print fallback.');
          return;
        }
        _printLog(debugSource, 'Print fallback failed. Will open file.');
        return;
      }
    } catch (_) {
      _printLog(debugSource, 'Windows print route threw exception.');
      // fallthrough
    }
    _printLog(debugSource, 'Fallback to OpenFilex.open');
    await OpenFilex.open(target);
  }
}
