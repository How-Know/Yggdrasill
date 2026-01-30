import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateService {
  UpdateService._();

  // NOTE:
  // - MSIX/AppInstaller 기반 업데이트는 Windows 정책/보안에 의해 쉽게 깨질 수 있어(특히 ms-appinstaller 프로토콜),
  //   앞으로는 "포터블 ZIP + 자체 업데이터"만 사용한다.
  // - MSIX로 설치된 경우에도 ZIP 업데이트는 LocalAppData로 "마이그레이션 설치"되며, 이후부터는 동일하게 동작한다.

  static const List<String> _arm64ZipCandidates = [
    'https://github.com/How-Know/Yggdrasill/releases/latest/download/Yggdrasill-Windows-ARM64.zip',
    'https://github.com/How-Know/Yggdrasill/releases/latest/download/Yggdrasill-windows-arm64.zip',
    'https://github.com/How-Know/Yggdrasill/releases/latest/download/mneme_flutter_windows_arm64.zip',
    'https://github.com/How-Know/Yggdrasill/releases/latest/download/yggdrasill_arm64.zip',
    'https://github.com/How-Know/Yggdrasill/releases/latest/download/mneme_flutter_arm64.zip',
  ];

  // ARM64 기기에서 x64 에뮬레이션 실행을 허용하는 폴백 ZIP 후보들
  static const List<String> _x64ZipFallbackCandidates = [
    'https://github.com/How-Know/Yggdrasill/releases/latest/download/Yggdrasill_portable_x64.zip',
    'https://github.com/How-Know/Yggdrasill/releases/latest/download/mneme_flutter_windows_x64_portable.zip',
    'https://github.com/How-Know/Yggdrasill/releases/latest/download/Yggdrasill-windows-x64.zip',
    'https://github.com/How-Know/Yggdrasill/releases/latest/download/yggdrasill_x64.zip',
  ];

  static const String _kLastInstalledTag = 'last_installed_tag';

  // 간단한 진행 상태 노출용 모델/노티파이어 (앱 내 커스텀 UI 연동)
  static final ValueNotifier<UpdateInfo> progressNotifier =
      ValueNotifier<UpdateInfo>(const UpdateInfo(phase: UpdatePhase.idle));

  static void _setProgress(UpdateInfo info) {
    try { progressNotifier.value = info; } catch (_) {}
  }

  // 앱 실행 시 무인 자동 업데이트: 최신 태그와 로컬 저장 태그가 다르면 ZIP 업데이트 수행
  static Future<void> checkAndUpdateSilently(BuildContext context) async {
    try {
      _setProgress(const UpdateInfo(phase: UpdatePhase.checking));
      final tag = await _fetchLatestTag();
      if (tag == null || tag.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final diskTag = await _readInstalledTagFromDisk();
      final last = diskTag ?? prefs.getString(_kLastInstalledTag);
      if (last == tag) return;
      // 포터블 ZIP 백그라운드 업데이트
      _setProgress(UpdateInfo(phase: UpdatePhase.downloading, message: '업데이트 다운로드 중...', tag: tag));
      unawaited(_updateUsingZip(context, tag: tag));
    } catch (_) {}
  }

  static Future<String?> _fetchLatestTag() async {
    // 1) GitHub REST API (차단/레이트리밋될 수 있음)
    try {
      final resp = await http.get(
        Uri.parse('https://api.github.com/repos/How-Know/Yggdrasill/releases/latest'),
        headers: {'User-Agent': 'Yggdrasill-Updater'},
      );
      if (resp.statusCode == 200) {
        final map = jsonDecode(resp.body) as Map<String, dynamic>;
        return (map['tag_name'] as String?)?.trim();
      }
    } catch (_) {}

    // 2) Fallback: GitHub 웹 리다이렉트로 태그 추출
    // - https://github.com/.../releases/latest 는 /releases/tag/vX.Y.Z.N 으로 302/301 리다이렉트 됨
    try {
      final req = http.Request('GET', Uri.parse('https://github.com/How-Know/Yggdrasill/releases/latest'));
      req.followRedirects = false;
      final resp = await http.Client().send(req);
      try {
        final loc = resp.headers['location'];
        if (loc != null && loc.isNotEmpty) {
          final m = RegExp(r'/releases/tag/(v[0-9]+(?:\.[0-9]+){2,3})$').firstMatch(loc.trim());
          if (m != null) return m.group(1);
        }
      } finally {
        await resp.stream.drain();
      }
    } catch (_) {}
    return null;
  }

  static Future<void> oneClickUpdate(BuildContext context) async {
    if (!Platform.isWindows) {
      _showSnack(context, 'Windows에서만 지원됩니다.');
      return;
    }

    // 항상 ZIP 자체업데이터 사용 (MSIX/AppInstaller 경로는 폐기)
    final latest = await _fetchLatestTag();
    await _updateUsingZip(context, tag: latest);
  }

  static Future<void> _updateUsingZip(BuildContext context, {String? tag}) async {
    _showSnack(context, '업데이트 파일을 확인 중입니다...');
    final client = http.Client();
    try {
      Uri? found;
      http.StreamedResponse? streamResp;
      final arch = _detectWindowsArch();
      final List<String> candidates = <String>[
        // x64는 포터블 ZIP이 1순위
        ..._x64ZipFallbackCandidates,
        // ARM64 장비는 전용 ZIP을 먼저 시도 후 x64 폴백으로
        if (arch == _WinArch.arm64) ..._arm64ZipCandidates,
      ];
      for (final url in candidates) {
        try {
          final req = http.Request('GET', Uri.parse(url));
          final resp = await client.send(req).timeout(const Duration(seconds: 20));
          if (resp.statusCode == 200) {
            found = Uri.parse(url);
            streamResp = resp;
            break;
          } else {
            await resp.stream.drain();
          }
        } catch (_) {}
      }
      if (found == null || streamResp == null) {
        // 최종 폴백: 릴리스 페이지 열기
        _showSnack(context, '업데이트 패키지를 찾을 수 없습니다. 릴리스 페이지를 엽니다.');
        final rel = Uri.parse('https://github.com/How-Know/Yggdrasill/releases/latest');
        if (await canLaunchUrl(rel)) {
          await launchUrl(rel);
        }
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final zipPath = p.join(tempDir.path, 'ygg_update.zip');
      final zipFile = File(zipPath);
      final total = streamResp.contentLength ?? -1;
      int received = 0;
      final sink = zipFile.openWrite();
      final sw = Stopwatch()..start();
      int lastTick = 0;
      _setProgress(UpdateInfo(
        phase: UpdatePhase.downloading,
        message: total > 0 ? '다운로드 중... (0/${(total / (1024 * 1024)).toStringAsFixed(0)}MB)' : '다운로드 중...',
        tag: tag,
      ));
      await for (final chunk in streamResp.stream.timeout(const Duration(seconds: 30))) {
        received += chunk.length;
        sink.add(chunk);
        final now = sw.elapsedMilliseconds;
        if (now - lastTick > 900) {
          lastTick = now;
          if (total > 0) {
            final pct = (received / total * 100).clamp(0, 100).toStringAsFixed(0);
            final mb = (received / (1024 * 1024)).toStringAsFixed(0);
            final tmb = (total / (1024 * 1024)).toStringAsFixed(0);
            _setProgress(UpdateInfo(phase: UpdatePhase.downloading, message: '다운로드 중... ($pct% · ${mb}MB/$tmbMB)', tag: tag));
          } else {
            final mb = (received / (1024 * 1024)).toStringAsFixed(0);
            _setProgress(UpdateInfo(phase: UpdatePhase.downloading, message: '다운로드 중... (${mb}MB)', tag: tag));
          }
        }
      }
      await sink.flush();
      await sink.close();

      if (!await zipFile.exists() || (await zipFile.length()) < 1024 * 1024) {
        _showSnack(context, '다운로드에 실패했습니다.');
        return;
      }

      final exePath = Platform.resolvedExecutable;
      final exeDir = _preferredInstallDir(exePath);
      final exeName = p.basename(exePath);

      // PowerShell 스크립트 작성
      final ps1 = p.join(tempDir.path, 'ygg_do_update.ps1');
      await File(ps1).writeAsString(_psScriptContent);

      // 스크립트 실행 (현재 프로세스 종료 후 교체 및 재실행)
      if (_isMsixInstall()) {
        _showSnack(context, 'MSIX 설치본은 포터블로 전환하여 업데이트합니다. (최초 1회)');
      }
      final psExe = (await _resolvePowerShellExe()) ?? 'powershell.exe';
      await Process.start(psExe, [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        ps1,
        '-ZipPath',
        zipPath,
        '-InstallDir',
        exeDir,
        '-ExeName',
        exeName,
        '-Tag',
        (tag ?? ''),
      ], mode: ProcessStartMode.detached);

      _setProgress(UpdateInfo(phase: UpdatePhase.readyToApply, message: '업데이트 준비 완료. 재시작합니다.', tag: tag));
      _showSnack(context, '업데이트를 시작합니다. 잠시 후 앱이 재실행됩니다.');
      await Future.delayed(const Duration(milliseconds: 800));
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('show_update_snack', true);
      } catch (_) {}
      exit(0);
    } catch (e) {
      _showSnack(context, '업데이트 중 오류: $e');
      _setProgress(UpdateInfo(phase: UpdatePhase.error, message: e.toString(), tag: tag));
    } finally {
      client.close();
    }
  }

  static Future<String?> _resolvePowerShellExe() async {
    // pwsh가 있으면 우선(더 안정적인 환경이 많음), 없으면 powershell.exe
    try {
      final p1 = await Process.run('where', ['pwsh.exe']);
      if (p1.exitCode == 0) {
        final line = (p1.stdout?.toString() ?? '').split(RegExp(r'\r?\n')).firstWhere((s) => s.trim().isNotEmpty, orElse: () => '');
        if (line.isNotEmpty) return line.trim();
      }
    } catch (_) {}
    try {
      final p2 = await Process.run('where', ['powershell.exe']);
      if (p2.exitCode == 0) {
        final line = (p2.stdout?.toString() ?? '').split(RegExp(r'\r?\n')).firstWhere((s) => s.trim().isNotEmpty, orElse: () => '');
        if (line.isNotEmpty) return line.trim();
      }
    } catch (_) {}
    return null;
  }

  static void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF1976D2),
      ),
    );
  }

  static _WinArch _detectWindowsArch() {
    final env = Platform.environment;
    final arch = (env['PROCESSOR_ARCHITEW6432'] ?? env['PROCESSOR_ARCHITECTURE'] ?? '').toUpperCase();
    if (arch.contains('ARM64')) return _WinArch.arm64;
    if (arch.contains('AMD64') || arch.contains('X64')) return _WinArch.x64;
    return _WinArch.unknown;
  }

  static bool _isMsixInstall() {
    try {
      final exe = Platform.resolvedExecutable.replaceAll('\\', '/').toLowerCase();
      return exe.contains('/windowsapps/');
    } catch (_) {
      return false;
    }
  }

  // MSIX 설치본이면 쓰기 가능한 경로로 설치 위치를 바꾼다
  static String _preferredInstallDir(String exePath) {
    try {
      final normalized = exePath.replaceAll('\\', '/').toLowerCase();
      if (normalized.contains('/windowsapps/')) {
        final local = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
        return p.join(local, 'Yggdrasill', 'app');
      }
      return p.dirname(exePath);
    } catch (_) {
      return p.dirname(exePath);
    }
  }

  static Future<String?> _readInstalledTagFromDisk() async {
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final f = File(p.join(exeDir, 'installed_tag.txt'));
      if (await f.exists()) {
        final s = (await f.readAsString()).trim();
        if (s.isNotEmpty) return s;
      }
    } catch (_) {}
    return null;
  }

  static const String _psScriptContent = r'''
param(
  [Parameter(Mandatory=$true)][string]$ZipPath,
  [Parameter(Mandatory=$true)][string]$InstallDir,
  [Parameter(Mandatory=$true)][string]$ExeName,
  [Parameter(Mandatory=$false)][string]$Tag = ''
)

try {
  $log = Join-Path $env:TEMP 'ygg_update_log.txt'
  "=== Yggdrasill updater start $(Get-Date -Format o) ===" | Out-File -FilePath $log -Encoding UTF8 -Append
  "ZipPath=$ZipPath" | Out-File -FilePath $log -Encoding UTF8 -Append
  "InstallDir=$InstallDir" | Out-File -FilePath $log -Encoding UTF8 -Append
  "ExeName=$ExeName" | Out-File -FilePath $log -Encoding UTF8 -Append
  "Tag=$Tag" | Out-File -FilePath $log -Encoding UTF8 -Append

  $procName = [System.IO.Path]::GetFileNameWithoutExtension($ExeName)
  try { Wait-Process -Name $procName -Timeout 60 } catch {}

  $timestamp = Get-Date -Format yyyyMMddHHmmss
  $backupDir = Join-Path $InstallDir ("backup_$timestamp")
  New-Item -ItemType Directory -Path $backupDir | Out-Null

  # data 폴더 백업 (있으면)
  $dataPath = Join-Path $InstallDir 'data'
  if (Test-Path $dataPath) {
    Move-Item -Force $dataPath $backupDir
  }

  $tmpExtract = Join-Path $env:TEMP ("ygg_update_" + [guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $tmpExtract | Out-Null
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $tmpExtract -Force

  $entries = Get-ChildItem $tmpExtract
  if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) {
    $srcDir = $entries[0].FullName
  } else {
    $srcDir = $tmpExtract
  }

  # 설치 경로 보장
  New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
  Copy-Item -Path (Join-Path $srcDir '*') -Destination $InstallDir -Recurse -Force

  # data 복원
  $bakData = Join-Path $backupDir 'data'
  if (Test-Path $bakData) {
    Move-Item -Force $bakData (Join-Path $InstallDir 'data')
  }

  # 설치된 태그 기록 (성공 시)
  if ($Tag -ne '') {
    Set-Content -Path (Join-Path $InstallDir 'installed_tag.txt') -Value $Tag -Encoding UTF8
  }

  # 실행 파일 결정 (지정 exe가 없으면 후보 검색)
  $targetExe = Join-Path $InstallDir $ExeName
  if (-not (Test-Path $targetExe)) {
    $cands = Get-ChildItem -Path $InstallDir -Filter *.exe -File | Sort-Object Length -Descending
    foreach ($c in $cands) { if ($c.Name -match 'yggdrasill|mneme') { $targetExe = $c.FullName; break } }
    if (-not (Test-Path $targetExe) -and $cands.Count -gt 0) { $targetExe = $cands[0].FullName }
  }
  # 데스크탑 바로가기 생성(기존 MSIX 바로가기 대신 포터블을 쉽게 실행하도록)
  try {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ($desktop -and (Test-Path $desktop)) {
      $lnk = Join-Path $desktop 'Yggdrasill.lnk'
      $wsh = New-Object -ComObject WScript.Shell
      $sc = $wsh.CreateShortcut($lnk)
      $sc.TargetPath = $targetExe
      $sc.WorkingDirectory = (Split-Path $targetExe -Parent)
      $sc.WindowStyle = 1
      $sc.Description = 'Yggdrasill (portable)'
      $sc.Save()
      "Created shortcut: $lnk" | Out-File -FilePath $log -Encoding UTF8 -Append
    }
  } catch {
    "Shortcut creation failed: $($_.Exception.Message)" | Out-File -FilePath $log -Encoding UTF8 -Append
  }

  "Start-Process: $targetExe" | Out-File -FilePath $log -Encoding UTF8 -Append
  Start-Process -FilePath $targetExe -WorkingDirectory (Split-Path $targetExe -Parent)
} catch {
  try {
    $log = Join-Path $env:TEMP 'ygg_update_log.txt'
    "Updater failed: $($_.Exception.Message)" | Out-File -FilePath $log -Encoding UTF8 -Append
    "Stack: $($_.ScriptStackTrace)" | Out-File -FilePath $log -Encoding UTF8 -Append
    Start-Process explorer.exe $env:TEMP
  } catch {}
}
''';
}

enum _WinArch { x64, arm64, unknown }


enum UpdatePhase { idle, checking, downloading, readyToApply, error }

class UpdateInfo {
  final UpdatePhase phase;
  final String? message;
  final String? tag;
  const UpdateInfo({required this.phase, this.message, this.tag});
}

extension UpdateServiceActions on UpdateService {
  static Future<void> restartApp() async {
    try {
      final exe = Platform.resolvedExecutable;
      await Process.start(exe, <String>[], mode: ProcessStartMode.detached);
    } catch (_) {}
    exit(0);
  }
}

