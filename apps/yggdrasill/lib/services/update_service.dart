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

  static const String _appInstallerLatestUrl =
      'ms-appinstaller:?source=https://github.com/How-Know/Yggdrasill/releases/latest/download/Yggdrasill.appinstaller';

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
      // 비차단 모드: 앱은 그대로 실행, 업데이트 준비되면 재시작 안내는 앱이 담당
      if (_isMsixInstall()) {
        // App Installer는 비차단 설정(ShowPrompt=false, UpdateBlocksActivation=false)이면
        // 백그라운드 다운로드/적용을 준비하고, 실제 적용은 다음 재시작 시 진행됨
        _setProgress(UpdateInfo(phase: UpdatePhase.downloading, message: '백그라운드에서 업데이트를 받는 중...', tag: tag));
        unawaited(_tryTriggerAppInstaller(context).then((ok){ _setProgress(UpdateInfo(phase: UpdatePhase.readyToApply, message: '업데이트 준비 완료. 재시작 시 적용됩니다.', tag: tag)); }));
        return;
      }
      // 포터블은 ZIP 백그라운드 업데이트를 수행하고 완료 시 재시작 안내를 앱에서 표시하도록 유지
      _setProgress(UpdateInfo(phase: UpdatePhase.downloading, message: '업데이트 다운로드 중...', tag: tag));
      unawaited(_updateUsingZipForArm64(context, tag: tag));
    } catch (_) {}
  }

  static Future<String?> _fetchLatestTag() async {
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
    return null;
  }

  static Future<void> oneClickUpdate(BuildContext context) async {
    if (!Platform.isWindows) {
      _showSnack(context, 'Windows에서만 지원됩니다.');
      return;
    }

    // 설치 형태 우선 분기: MSIX이면 App Installer 사용
    if (_isMsixInstall()) {
      final ok = await _tryTriggerAppInstaller(context);
      if (!ok) {
        await _updateUsingZipForArm64(context);
      }
      return;
    }

    final arch = _detectWindowsArch();
    if (arch == _WinArch.x64) {
      // 일부 환경에서 ms-appinstaller가 비활성화되어 실패하므로 x64도 ZIP 플로우를 기본 사용
      await _updateUsingZipForArm64(context);
      return;
    }

    if (arch == _WinArch.arm64) {
      // ARM64: AppInstaller 사용을 시도하지 않고 바로 ZIP 경로로 유도
      await _updateUsingZipForArm64(context);
      return;
    }

    _showSnack(context, '지원하지 않는 아키텍처입니다.');
  }

  static Future<bool> _tryTriggerAppInstaller(BuildContext context) async {
    _showSnack(context, '업데이트를 확인하고 있습니다...');
    try {
      final uri = Uri.parse(_appInstallerLatestUrl);
      final can = await canLaunchUrl(uri);
      if (can) {
        final ok = await launchUrl(uri);
        if (ok) {
          await Future.delayed(const Duration(seconds: 2));
          exit(0);
        }
        return false;
      }
      // Fallback: explorer로 호출 (일부 환경에서 차단될 수 있음)
      try {
        await Process.start('explorer.exe', [uri.toString()]);
        await Future.delayed(const Duration(seconds: 2));
        exit(0);
      } catch (_) {
        return false;
      }
    } catch (_) {
      return false;
    }
    return true;
  }

  static Future<void> _updateUsingZipForArm64(BuildContext context, {String? tag}) async {
    _showSnack(context, '업데이트 파일을 확인 중입니다...');
    final client = http.Client();
    try {
      Uri? found;
      http.StreamedResponse? streamResp;
      // 1) ARM64 전용 ZIP 우선 시도
      for (final url in _arm64ZipCandidates) {
        try {
          final req = http.Request('GET', Uri.parse(url));
          final resp = await client.send(req);
          if (resp.statusCode == 200) {
            found = Uri.parse(url);
            streamResp = resp;
            break;
          } else {
            await resp.stream.drain();
          }
        } catch (_) {}
      }
      // 2) 실패 시 x64 포터블 ZIP 폴백 시도 (Windows on ARM의 x64 에뮬레이션)
      if (found == null) {
        for (final url in _x64ZipFallbackCandidates) {
          try {
            final req = http.Request('GET', Uri.parse(url));
            final resp = await client.send(req);
            if (resp.statusCode == 200) {
              found = Uri.parse(url);
              streamResp = resp;
              break;
            } else {
              await resp.stream.drain();
            }
          } catch (_) {}
        }
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
      final zipPath = p.join(tempDir.path, 'ygg_update_arm64.zip');
      final zipFile = File(zipPath);
      final sink = zipFile.openWrite();
      await streamResp.stream.pipe(sink);
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
      await Process.start('powershell.exe', [
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
      exit(0);
    } catch (e) {
      _showSnack(context, '업데이트 중 오류: $e');
      _setProgress(UpdateInfo(phase: UpdatePhase.error, message: e.toString(), tag: tag));
    } finally {
      client.close();
    }
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
  Start-Process -FilePath $targetExe
} catch {
  # 실패 시에도 조용히 종료
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

