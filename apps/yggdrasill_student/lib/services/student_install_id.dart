import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 이 앱 설치마다 고정되는 ID. iOS 1인 1기기 클레임에 사용.
class StudentInstallId {
  StudentInstallId._();

  static const _prefsKey = 'student_app_ios_install_id';

  /// iOS 가 아니면 null (Windows 등은 기기 제한 없음).
  static Future<String?> iosInstallIdOrNull() async {
    if (kIsWeb || !Platform.isIOS) return null;
    final prefs = await SharedPreferences.getInstance();
    final existing = (prefs.getString(_prefsKey) ?? '').trim();
    if (existing.isNotEmpty) return existing;
    final next = _newId();
    await prefs.setString(_prefsKey, next);
    return next;
  }

  static String _newId() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
