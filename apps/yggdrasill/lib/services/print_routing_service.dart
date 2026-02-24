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
  }) async {
    final target = path.trim();
    if (target.isEmpty) return;

    final configuredPrinter = await loadConfiguredPrinter(channel);
    await _printWithRouting(
      target: target,
      printerName: configuredPrinter,
    );
  }

  Future<void> _printWithRouting({
    required String target,
    required String? printerName,
  }) async {
    try {
      if (Platform.isWindows) {
        final qPath = _psSingleQuoted(target);
        final normalizedPrinter = (printerName ?? '').trim();
        if (normalizedPrinter.isNotEmpty) {
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
          if (printTo.exitCode == 0) {
            return;
          }
        }

        await Process.start(
          'powershell',
          <String>[
            '-NoProfile',
            '-Command',
            'Start-Process -FilePath $qPath -Verb Print',
          ],
          runInShell: true,
        );
        return;
      }
    } catch (_) {
      // fallthrough
    }
    await OpenFilex.open(target);
  }
}
