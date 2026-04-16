import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PrintRoutingChannel {
  general,
  todoSheet,
}

enum PrintDuplexMode {
  systemDefault,
  oneSided,
  twoSidedLongEdge,
  twoSidedShortEdge,
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

  String _duplexModeLabel(PrintDuplexMode mode) {
    switch (mode) {
      case PrintDuplexMode.systemDefault:
        return 'systemDefault';
      case PrintDuplexMode.oneSided:
        return 'oneSided';
      case PrintDuplexMode.twoSidedLongEdge:
        return 'twoSidedLongEdge';
      case PrintDuplexMode.twoSidedShortEdge:
        return 'twoSidedShortEdge';
    }
  }

  String? _windowsDuplexToken(PrintDuplexMode mode) {
    switch (mode) {
      case PrintDuplexMode.systemDefault:
        return null;
      case PrintDuplexMode.oneSided:
        return 'OneSided';
      case PrintDuplexMode.twoSidedLongEdge:
        return 'TwoSidedLongEdge';
      case PrintDuplexMode.twoSidedShortEdge:
        return 'TwoSidedShortEdge';
    }
  }

  String _normalizePaperSizeText(String raw) {
    return raw.trim().toUpperCase().replaceAll(RegExp(r'[\s\-_]+'), '');
  }

  String? _windowsPaperSizeToken(String raw) {
    var normalized = _normalizePaperSizeText(raw);
    if (normalized.endsWith('ROTATED')) {
      normalized =
          normalized.substring(0, normalized.length - 'ROTATED'.length);
    }
    if (normalized.isEmpty) return null;
    switch (normalized) {
      case 'A3':
        return 'A3';
      case 'A4':
        return 'A4';
      case 'A5':
        return 'A5';
      case 'B4':
      case 'B4JIS':
      case 'JISB4':
      case 'ISOB4':
        return 'B4';
      case 'B5':
      case 'B5JIS':
      case 'JISB5':
      case 'ISOB5':
        return 'B5';
      case 'LETTER':
      case 'NORTHAMERICALETTER':
        return 'NorthAmericaLetter';
      case 'LEGAL':
      case 'NORTHAMERICALEGAL':
        return 'NorthAmericaLegal';
      default:
        return null;
    }
  }

  String _paperSizeLabel(String raw) {
    final token = _windowsPaperSizeToken(raw);
    if (token != null) return token;
    return raw.trim().isEmpty ? 'systemDefault' : raw.trim();
  }

  bool _isSamePaperSize({
    required String currentRaw,
    required String requestedRaw,
  }) {
    return _normalizePaperSizeText(currentRaw) ==
        _normalizePaperSizeText(requestedRaw);
  }

  PrintDuplexMode _parseWindowsDuplexMode(String raw) {
    final normalized = raw.trim().toLowerCase();
    if (normalized.contains('twosidedshortedge')) {
      return PrintDuplexMode.twoSidedShortEdge;
    }
    if (normalized.contains('twosidedlongedge')) {
      return PrintDuplexMode.twoSidedLongEdge;
    }
    if (normalized.contains('onesided')) {
      return PrintDuplexMode.oneSided;
    }
    return PrintDuplexMode.systemDefault;
  }

  Future<String?> _loadWindowsPrinterPaperSize(String printerName) async {
    if (!Platform.isWindows) return null;
    final escapedName = printerName.replaceAll("'", "''");
    try {
      final result = await Process.run(
        'powershell',
        <String>[
          '-NoProfile',
          '-Command',
          "\$cfg = Get-PrintConfiguration -PrinterName '$escapedName' -ErrorAction SilentlyContinue; if (\$null -ne \$cfg) { Write-Output \"\$(\$cfg.PaperSize)\" }",
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
      if (line.isEmpty) return null;
      return line;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _setWindowsPrinterPaperSize({
    required String printerName,
    required String paperSizeToken,
    required String debugSource,
  }) async {
    if (!Platform.isWindows) return false;
    final safeToken = paperSizeToken.trim();
    if (safeToken.isEmpty) return false;
    final escapedName = printerName.replaceAll("'", "''");
    try {
      final result = await Process.run(
        'powershell',
        <String>[
          '-NoProfile',
          '-Command',
          "Set-PrintConfiguration -PrinterName '$escapedName' -PaperSize $safeToken -ErrorAction Stop",
        ],
        runInShell: true,
      );
      _printLog(
        debugSource,
        'Set paper size=$safeToken exit=${result.exitCode} stdout="${_compact(result.stdout)}" stderr="${_compact(result.stderr)}"',
      );
      return result.exitCode == 0;
    } catch (e) {
      _printLog(debugSource, 'Set paper size failed: ${_compact(e)}');
      return false;
    }
  }

  Future<void> _restoreWindowsPrinterPaperSizeLater({
    required String printerName,
    required String paperSizeToken,
    required String debugSource,
    Duration delay = const Duration(seconds: 12),
  }) async {
    await Future<void>.delayed(delay);
    await _setWindowsPrinterPaperSize(
      printerName: printerName,
      paperSizeToken: paperSizeToken,
      debugSource: '$debugSource.restore',
    );
  }

  Future<int?> _loadWindowsPrinterJobCount(String printerName) async {
    if (!Platform.isWindows) return null;
    final escapedName = printerName.replaceAll("'", "''");
    try {
      final result = await Process.run(
        'powershell',
        <String>[
          '-NoProfile',
          '-Command',
          "\$jobs = Get-PrintJob -PrinterName '$escapedName' -ErrorAction SilentlyContinue; if (\$null -eq \$jobs) { Write-Output '0' } else { Write-Output \"\$(\$jobs.Count)\" }",
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
      if (line.isEmpty) return null;
      return int.tryParse(line);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _waitForSpoolerJobIncrease({
    required String printerName,
    required int beforeJobCount,
    required String debugSource,
    required String reason,
    Duration maxWait = const Duration(seconds: 6),
  }) async {
    if (!Platform.isWindows) return false;
    final startedAt = DateTime.now();
    var attempt = 0;
    while (DateTime.now().difference(startedAt) < maxWait) {
      attempt += 1;
      await Future<void>.delayed(const Duration(milliseconds: 450));
      final elapsed = DateTime.now().difference(startedAt);
      final remaining = maxWait - elapsed;
      if (remaining <= Duration.zero) break;
      final pollTimeout = remaining > const Duration(seconds: 1)
          ? const Duration(seconds: 1)
          : remaining;
      final afterJobCount = await _loadWindowsPrinterJobCount(printerName)
          .timeout(pollTimeout, onTimeout: () => null);
      if (afterJobCount != null && afterJobCount > beforeJobCount) {
        _printLog(
          debugSource,
          'Spooler accepted ($reason) jobs: $beforeJobCount -> $afterJobCount attempt=$attempt elapsedMs=${elapsed.inMilliseconds}',
        );
        return true;
      }
    }
    _printLog(
      debugSource,
      'Spooler poll timeout ($reason) maxWaitMs=${maxWait.inMilliseconds} baseline=$beforeJobCount',
    );
    return false;
  }

  Future<PrintDuplexMode?> _loadWindowsPrinterDuplexMode(
      String printerName) async {
    if (!Platform.isWindows) return null;
    final escapedName = printerName.replaceAll("'", "''");
    try {
      final result = await Process.run(
        'powershell',
        <String>[
          '-NoProfile',
          '-Command',
          "\$cfg = Get-PrintConfiguration -PrinterName '$escapedName' -ErrorAction SilentlyContinue; if (\$null -ne \$cfg) { Write-Output \"\$(\$cfg.DuplexingMode)\" }",
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
      if (line.isEmpty) return null;
      return _parseWindowsDuplexMode(line);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _setWindowsPrinterDuplexMode({
    required String printerName,
    required PrintDuplexMode mode,
    required String debugSource,
  }) async {
    if (!Platform.isWindows) return false;
    final token = _windowsDuplexToken(mode);
    if (token == null) return false;
    final escapedName = printerName.replaceAll("'", "''");
    try {
      final result = await Process.run(
        'powershell',
        <String>[
          '-NoProfile',
          '-Command',
          "Set-PrintConfiguration -PrinterName '$escapedName' -DuplexingMode $token -ErrorAction Stop",
        ],
        runInShell: true,
      );
      _printLog(
        debugSource,
        'Set duplex mode=$token exit=${result.exitCode} stdout="${_compact(result.stdout)}" stderr="${_compact(result.stderr)}"',
      );
      return result.exitCode == 0;
    } catch (e) {
      _printLog(debugSource, 'Set duplex mode failed: ${_compact(e)}');
      return false;
    }
  }

  Future<void> _restoreWindowsPrinterDuplexLater({
    required String printerName,
    required PrintDuplexMode mode,
    required String debugSource,
    Duration delay = const Duration(seconds: 12),
  }) async {
    await Future<void>.delayed(delay);
    final token = _windowsDuplexToken(mode);
    if (token == null) return;
    await _setWindowsPrinterDuplexMode(
      printerName: printerName,
      mode: mode,
      debugSource: '$debugSource.restore',
    );
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
      final beforeJobCount = await _loadWindowsPrinterJobCount(normalizedPrinter)
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
      final startedAt = DateTime.now();
      _printLog(
        debugSource,
        'Try direct Acrobat /t exe="$acrobatExe" printer="$normalizedPrinter" driver="${meta.driver}" port="${meta.port}" beforeJobs=${beforeJobCount ?? -1}',
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
          debugSource, 'Direct Acrobat /t process started pid=${process.pid}');

      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      const acrobatExitWait = Duration(seconds: 12);
      late int exitCode;
      late String out;
      late String err;
      try {
        exitCode = await process.exitCode.timeout(acrobatExitWait);
        out = (await stdoutFuture).trim();
        err = (await stderrFuture).trim();
      } on TimeoutException {
        _printLog(
          debugSource,
          'Direct Acrobat /t exitCode wait exceeded ${acrobatExitWait.inSeconds}s; polling spooler.',
        );
        if (beforeJobCount != null) {
          final accepted = await _waitForSpoolerJobIncrease(
            printerName: normalizedPrinter,
            beforeJobCount: beforeJobCount,
            debugSource: debugSource,
            reason: 'acrobat-timeout',
            maxWait: const Duration(seconds: 5),
          );
          if (accepted) return true;
        }
        final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
        if (elapsedMs >= 5000) {
          _printLog(
            debugSource,
            'Direct Acrobat /t timeout but elapsed=${elapsedMs}ms; assuming accepted to avoid duplicate dialog.',
          );
          return true;
        }
        return false;
      }
      if (out.isNotEmpty) {
        _printLog(debugSource, 'Direct Acrobat /t stdout="${_compact(out)}"');
      }
      if (err.isNotEmpty) {
        _printLog(debugSource, 'Direct Acrobat /t stderr="${_compact(err)}"');
      }
      final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
      _printLog(
        debugSource,
        'Direct Acrobat /t process exit=$exitCode elapsedMs=$elapsedMs',
      );
      if (exitCode == 0) return true;

      if (beforeJobCount != null) {
        final accepted = await _waitForSpoolerJobIncrease(
          printerName: normalizedPrinter,
          beforeJobCount: beforeJobCount,
          debugSource: debugSource,
          reason: 'acrobat-nonzero-exit-$exitCode',
          maxWait: const Duration(seconds: 5),
        );
        if (accepted) return true;
      }
      if (out.isEmpty && err.isEmpty && elapsedMs >= 5000) {
        _printLog(
          debugSource,
          'Direct Acrobat /t exited non-zero but looked accepted (silent output + elapsed=${elapsedMs}ms). Skip PrintTo fallback to avoid duplicate print dialog.',
        );
        return true;
      }
      return false;
    } catch (_) {
      _printLog(debugSource, 'Direct Acrobat /t threw exception.');
      return false;
    }
  }

  String? _extractIpFromPrinterPort(String portRaw) {
    final cleaned = portRaw.trim();
    if (cleaned.isEmpty) return null;
    final match =
        RegExp(r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})').firstMatch(cleaned);
    return match?.group(1);
  }

  String? _pjlDuplexCommands(PrintDuplexMode mode) {
    switch (mode) {
      case PrintDuplexMode.systemDefault:
        return null;
      case PrintDuplexMode.oneSided:
        return '@PJL SET DUPLEX=OFF\r\n';
      case PrintDuplexMode.twoSidedLongEdge:
        return '@PJL SET DUPLEX=ON\r\n@PJL SET BINDING=LONGEDGE\r\n';
      case PrintDuplexMode.twoSidedShortEdge:
        return '@PJL SET DUPLEX=ON\r\n@PJL SET BINDING=SHORTEDGE\r\n';
    }
  }

  Future<bool> _tryRawTcpPrint({
    required String target,
    required String portIp,
    required String debugSource,
    int tcpPort = 9100,
    PrintDuplexMode duplexMode = PrintDuplexMode.systemDefault,
  }) async {
    if (!Platform.isWindows) return false;

    final file = File(target);
    if (!await file.exists()) {
      _printLog(debugSource, 'Raw TCP: file not found "$target"');
      return false;
    }

    try {
      final duplexLabel = _duplexModeLabel(duplexMode);
      _printLog(
        debugSource,
        'Try raw TCP print to $portIp:$tcpPort duplex=$duplexLabel',
      );
      final socket = await Socket.connect(
        portIp,
        tcpPort,
        timeout: const Duration(seconds: 15),
      );

      final pdfBytes = await file.readAsBytes();
      _printLog(
        debugSource,
        'Raw TCP connected, sending ${pdfBytes.length} bytes',
      );

      const uel = '\x1b%-12345X';
      final duplexPjl = _pjlDuplexCommands(duplexMode) ?? '';
      socket.add(utf8.encode(
        '$uel@PJL\r\n$duplexPjl@PJL ENTER LANGUAGE = PDF\r\n',
      ));
      socket.add(pdfBytes);
      socket.add(utf8.encode('$uel@PJL EOJ\r\n$uel'));

      await socket.flush();
      try {
        await socket.close().timeout(const Duration(seconds: 5));
      } catch (e) {
        _printLog(
          debugSource,
          'Raw TCP close timed out or failed (${_compact(e)}); destroying socket.',
        );
        try {
          socket.destroy();
        } catch (_) {}
      }
      _printLog(
        debugSource,
        'Raw TCP print completed (${pdfBytes.length} bytes, duplex=$duplexLabel).',
      );
      return true;
    } catch (e) {
      _printLog(debugSource, 'Raw TCP print failed: ${_compact(e)}');
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

  /// Windows에서 Acrobat 직접 인쇄·PrintTo·Print 동사로 스풀러에 넘긴 경우 `true`.
  /// 그 외(파일만 연 경우 등)는 `false`.
  Future<bool> printFile({
    required String path,
    required PrintRoutingChannel channel,
    PrintDuplexMode duplexMode = PrintDuplexMode.systemDefault,
    String preferredPaperSize = '',
    String debugSource = 'unknown',
  }) async {
    final target = path.trim();
    if (target.isEmpty) {
      _printLog(debugSource, 'printFile skipped: empty path');
      return false;
    }

    final configuredPrinter = await loadConfiguredPrinter(channel);
    final exists = await File(target).exists();
    _printLog(
      debugSource,
      'printFile request channel=$channel exists=$exists duplex=${_duplexModeLabel(duplexMode)} paper=${_paperSizeLabel(preferredPaperSize)} printer="${configuredPrinter ?? ''}" path="$target"',
    );
    return _printWithRouting(
      target: target,
      printerName: configuredPrinter,
      channel: channel,
      duplexMode: duplexMode,
      preferredPaperSize: preferredPaperSize,
      debugSource: debugSource,
    );
  }

  Future<bool> _printWithRouting({
    required String target,
    required String? printerName,
    required PrintRoutingChannel channel,
    required PrintDuplexMode duplexMode,
    required String preferredPaperSize,
    required String debugSource,
  }) async {
    try {
      if (Platform.isWindows) {
        final qPath = _psSingleQuoted(target);
        final normalizedPrinter = (printerName ?? '').trim();
        _printLog(
          debugSource,
          'Windows route start channel=$channel duplex=${_duplexModeLabel(duplexMode)} paper=${_paperSizeLabel(preferredPaperSize)} printer="${normalizedPrinter.isEmpty ? '(none)' : normalizedPrinter}"',
        );
        bool shouldRestoreDuplex = false;
        PrintDuplexMode? restoreDuplexMode;
        bool shouldRestorePaperSize = false;
        String? restorePaperSizeToken;
        Duration paperRestoreDelay = const Duration(seconds: 12);
        try {
          if (normalizedPrinter.isNotEmpty &&
              duplexMode != PrintDuplexMode.systemDefault) {
            restoreDuplexMode =
                await _loadWindowsPrinterDuplexMode(normalizedPrinter);
            if (restoreDuplexMode != null && restoreDuplexMode != duplexMode) {
              final applied = await _setWindowsPrinterDuplexMode(
                printerName: normalizedPrinter,
                mode: duplexMode,
                debugSource: '$debugSource.duplex',
              );
              shouldRestoreDuplex = applied;
            } else {
              _printLog(
                '$debugSource.duplex',
                'Skip duplex override: current=${_duplexModeLabel(restoreDuplexMode ?? PrintDuplexMode.systemDefault)} requested=${_duplexModeLabel(duplexMode)}',
              );
            }
          }

          if (normalizedPrinter.isNotEmpty) {
            final requestedPaperToken =
                _windowsPaperSizeToken(preferredPaperSize);

            // For prints with specific paper size, try raw TCP first.
            // Sends the PDF directly to the printer which respects the
            // PDF's native page size, bypassing Acrobat's page scaling.
            if (requestedPaperToken != null) {
              final tcpMeta = await _loadWindowsPrinterMeta(normalizedPrinter);
              if (tcpMeta != null) {
                final portIp = _extractIpFromPrinterPort(tcpMeta.port);
                if (portIp != null) {
                  final rawPrinted = await _tryRawTcpPrint(
                    target: target,
                    portIp: portIp,
                    debugSource: debugSource,
                    duplexMode: duplexMode,
                  );
                  if (rawPrinted) {
                    _printLog(
                      debugSource,
                      'Printed via raw TCP to $portIp:9100.',
                    );
                    return true;
                  }
                }
              }
            }

            if (requestedPaperToken != null) {
              final currentPaperRaw =
                  await _loadWindowsPrinterPaperSize(normalizedPrinter);
              if (currentPaperRaw != null &&
                  currentPaperRaw.trim().isNotEmpty &&
                  !_isSamePaperSize(
                    currentRaw: currentPaperRaw,
                    requestedRaw: requestedPaperToken,
                  )) {
                final currentToken = _windowsPaperSizeToken(currentPaperRaw) ??
                    currentPaperRaw.trim();
                final applied = await _setWindowsPrinterPaperSize(
                  printerName: normalizedPrinter,
                  paperSizeToken: requestedPaperToken,
                  debugSource: '$debugSource.paper',
                );
                shouldRestorePaperSize = applied;
                restorePaperSizeToken = currentToken;
              } else {
                _printLog(
                  '$debugSource.paper',
                  'Skip paper override: current=${_paperSizeLabel(currentPaperRaw ?? '')} requested=${_paperSizeLabel(requestedPaperToken)}',
                );
              }
            }

            final directAcrobatPrinted = await _tryDirectAcrobatPrintTo(
              target: target,
              printerName: normalizedPrinter,
              debugSource: debugSource,
            );
            if (directAcrobatPrinted) {
              if (shouldRestorePaperSize) {
                paperRestoreDelay = const Duration(seconds: 45);
              }
              _printLog(debugSource, 'Printed via direct Acrobat /t route.');
              return true;
            }

            final qPrinter = _psSingleQuoted(normalizedPrinter);
            final printerMeta =
                await _loadWindowsPrinterMeta(normalizedPrinter);
            final printToCommand = (printerMeta == null)
                ? 'Start-Process -FilePath $qPath -Verb PrintTo -ArgumentList $qPrinter'
                : (() {
                    final qDriver = _psSingleQuoted(printerMeta.driver);
                    final qPort = _psSingleQuoted(printerMeta.port);
                    return 'Start-Process -FilePath $qPath -Verb PrintTo -ArgumentList @($qPrinter,$qDriver,$qPort)';
                  })();
            final printTo = await Process.run(
              'powershell',
              <String>[
                '-NoProfile',
                '-Command',
                printToCommand,
              ],
              runInShell: true,
            );
            _printLog(
              debugSource,
              'PrintTo exit=${printTo.exitCode} meta=${printerMeta == null ? "none" : "driver+port"} stdout="${_compact(printTo.stdout)}" stderr="${_compact(printTo.stderr)}"',
            );
            if (printTo.exitCode == 0) {
              if (shouldRestorePaperSize) {
                // PrintTo completion timing is app-dependent; keep longer restore window.
                paperRestoreDelay = const Duration(seconds: 120);
              }
              _printLog(debugSource, 'Printed via PowerShell PrintTo route.');
              return true;
            }
          }
        } finally {
          final paperTokenToRestore = restorePaperSizeToken;
          if (normalizedPrinter.isNotEmpty &&
              shouldRestorePaperSize &&
              paperTokenToRestore != null &&
              paperTokenToRestore.trim().isNotEmpty) {
            _printLog(
              '$debugSource.paper',
              'Schedule paper restore token=$paperTokenToRestore delay=${paperRestoreDelay.inSeconds}s',
            );
            unawaited(_restoreWindowsPrinterPaperSizeLater(
              printerName: normalizedPrinter,
              paperSizeToken: paperTokenToRestore,
              debugSource: debugSource,
              delay: paperRestoreDelay,
            ));
          }
          if (normalizedPrinter.isNotEmpty &&
              shouldRestoreDuplex &&
              restoreDuplexMode != null &&
              _windowsDuplexToken(restoreDuplexMode) != null) {
            unawaited(_restoreWindowsPrinterDuplexLater(
              printerName: normalizedPrinter,
              mode: restoreDuplexMode,
              debugSource: debugSource,
            ));
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
          return true;
        }
        _printLog(debugSource, 'Print fallback failed. Will open file.');
        return false;
      }
    } catch (_) {
      _printLog(debugSource, 'Windows print route threw exception.');
      // fallthrough
    }
    _printLog(debugSource, 'Fallback to OpenFilex.open');
    await OpenFilex.open(target);
    return false;
  }
}
