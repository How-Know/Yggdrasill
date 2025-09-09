import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ExamModeService {
  ExamModeService._();
  static final ExamModeService instance = ExamModeService._();

  /// 전역 시험기간 모드 상태
  final ValueNotifier<bool> isOn = ValueNotifier<bool>(false);

  /// 인디케이터 커스텀 값
  final ValueNotifier<Color> indicatorColor = ValueNotifier<Color>(const Color(0xFFE53935));
  final ValueNotifier<double> speed = ValueNotifier<double>(1.0); // 1.0 = 기본 속도
  final ValueNotifier<String> effect = ValueNotifier<String>('glow');

  static const String _kOnKey = 'exam_mode_on';
  static const String _kUntilKey = 'exam_mode_until_iso';
  static const String _kUserOffKey = 'exam_mode_user_off';
  static const String _kColorKey = 'exam_indicator_color';
  static const String _kSpeedKey = 'exam_indicator_speed';
  static const String _kEffectKey = 'exam_indicator_effect';

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    // 색/효과/속도
    final colorValue = prefs.getInt(_kColorKey);
    if (colorValue != null) indicatorColor.value = Color(colorValue);
    speed.value = prefs.getDouble(_kSpeedKey) ?? 1.0;
    effect.value = prefs.getString(_kEffectKey) ?? 'glow';

    // 모드 ON/OFF 자동 복원
    final userOff = prefs.getBool(_kUserOffKey) ?? false;
    final untilIso = prefs.getString(_kUntilKey);
    if (!userOff && untilIso != null && untilIso.isNotEmpty) {
      try {
        final until = DateTime.parse(untilIso);
        isOn.value = DateTime.now().isBefore(until) || DateTime.now().isAtSameMomentAs(until);
      } catch (_) {
        isOn.value = prefs.getBool(_kOnKey) ?? false;
      }
    } else {
      isOn.value = prefs.getBool(_kOnKey) ?? false;
    }
  }

  // until이 저장되어 있지 않거나 과거라면 DB를 조회하여 자동 복원
  Future<void> ensureOnFromDatabase(Future<List<Map<String, dynamic>>> Function() loadDays,
      Future<List<Map<String, dynamic>>> Function() loadSchedules) async {
    final prefs = await SharedPreferences.getInstance();
    final userOff = prefs.getBool(_kUserOffKey) ?? false;
    if (userOff) return;
    DateTime? maxDate;
    try {
      final days = await loadDays();
      for (final r in days) {
        final iso = (r['date'] as String?) ?? '';
        if (iso.isEmpty) continue;
        final d = DateTime.tryParse(iso);
        if (d == null) continue;
        final key = DateTime(d.year, d.month, d.day);
        if (maxDate == null || key.isAfter(maxDate!)) maxDate = key;
      }
    } catch (_) {}
    try {
      final sch = await loadSchedules();
      for (final r in sch) {
        final iso = (r['date'] as String?) ?? '';
        if (iso.isEmpty) continue;
        final d = DateTime.tryParse(iso);
        if (d == null) continue;
        final key = DateTime(d.year, d.month, d.day);
        if (maxDate == null || key.isAfter(maxDate!)) maxDate = key;
      }
    } catch (_) {}
    if (maxDate != null) {
      final until = DateTime(maxDate!.year, maxDate!.month, maxDate!.day, 23, 59, 59);
      await setUntil(until);
      await setOn(true);
    }
  }

  Future<void> setOn(bool value) async {
    isOn.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnKey, value);
  }

  Future<void> setUserOff(bool off) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUserOffKey, off);
  }

  Future<void> setUntil(DateTime? until) async {
    final prefs = await SharedPreferences.getInstance();
    if (until == null) {
      await prefs.remove(_kUntilKey);
      return;
    }
    await prefs.setString(_kUntilKey, until.toIso8601String());
  }

  Future<void> setIndicatorColor(Color color) async {
    indicatorColor.value = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kColorKey, color.value);
  }

  Future<void> setSpeed(double v) async {
    speed.value = v.clamp(0.3, 3.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kSpeedKey, speed.value);
  }

  Future<void> setEffect(String e) async {
    effect.value = e;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kEffectKey, e);
  }
}


