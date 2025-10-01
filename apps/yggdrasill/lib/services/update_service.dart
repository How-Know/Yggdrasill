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

  // 앱 실행 시 무인 자동 업데이트: 최신 태그와 로컬 저장 태그가 다르면 ZIP 업데이트 수행
  static Future<void> checkAndUpdateSilently(BuildContext context) async {
    try {
      final tag = await _fetchLatestTag();
      if (tag == null || tag.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getString(_kLastInstalledTag);
      if (last == tag) return;
      // 안내 스낵바만 띄우고 ZIP 업데이트 수행
      _showSnack(context, '새 버전($tag)을 설치합니다...');
      // 업데이트 성공 시 재시작되므로, 태그를 미리 저장해 루프 방지
      await prefs.setString(_kLastInstalledTag, tag);
      await _updateUsingZipForArm64(context);
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

  static Future<void> _updateUsingZipForArm64(BuildContext context) async {
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
      final exeDir = p.dirname(exePath);
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
      ], mode: ProcessStartMode.detached);

      _showSnack(context, '업데이트를 시작합니다. 잠시 후 앱이 재실행됩니다.');
      await Future.delayed(const Duration(milliseconds: 800));
      exit(0);
    } catch (e) {
      _showSnack(context, '업데이트 중 오류: $e');
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

  static const String _psScriptContent = r'''
param(
  [Parameter(Mandatory=$true)][string]$ZipPath,
  [Parameter(Mandatory=$true)][string]$InstallDir,
  [Parameter(Mandatory=$true)][string]$ExeName
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

  Copy-Item -Path (Join-Path $srcDir '*') -Destination $InstallDir -Recurse -Force

  # data 복원
  $bakData = Join-Path $backupDir 'data'
  if (Test-Path $bakData) {
    Move-Item -Force $bakData (Join-Path $InstallDir 'data')
  }

  Start-Process -FilePath (Join-Path $InstallDir $ExeName)
} catch {
  # 실패 시에도 조용히 종료
}
''';
}

enum _WinArch { x64, arm64, unknown }


