import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 기출 그리드 셀별 로컬 파일 바로가기 (`naesinLinkKey` → 절대 경로).
class PastExamShortcutStore {
  PastExamShortcutStore._();
  static final PastExamShortcutStore instance = PastExamShortcutStore._();

  static const String _kVersionPrefix = 'past_exam_shortcuts_v1_';

  String _prefsKey(String academyId) => '$_kVersionPrefix$academyId';

  Future<Map<String, String>> loadAll(String academyId) async {
    final id = academyId.trim();
    if (id.isEmpty) return <String, String>{};
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey(id));
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      final out = <String, String>{};
      for (final e in decoded.entries) {
        final k = e.key?.toString().trim() ?? '';
        final v = e.value?.toString().trim() ?? '';
        if (k.isNotEmpty && v.isNotEmpty) out[k] = v;
      }
      return out;
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> setPath({
    required String academyId,
    required String linkKey,
    required String filePath,
  }) async {
    final id = academyId.trim();
    final key = linkKey.trim();
    final path = filePath.trim();
    if (id.isEmpty || key.isEmpty || path.isEmpty) return;
    final map = await loadAll(id);
    map[key] = path;
    await _saveMap(id, map);
  }

  Future<void> remove({
    required String academyId,
    required String linkKey,
  }) async {
    final id = academyId.trim();
    final key = linkKey.trim();
    if (id.isEmpty || key.isEmpty) return;
    final map = await loadAll(id);
    map.remove(key);
    await _saveMap(id, map);
  }

  Future<void> _saveMap(String academyId, Map<String, String> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey(academyId), jsonEncode(map));
  }

  static const String _kLastGradeKey = 'past_exam_last_grade_key';
  static const String _kLastCourseKey = 'past_exam_last_course_key';

  Future<({String? gradeKey, String? courseKey})> loadLastGradeCourse() async {
    final prefs = await SharedPreferences.getInstance();
    final g = prefs.getString(_kLastGradeKey)?.trim();
    final c = prefs.getString(_kLastCourseKey)?.trim();
    if (g == null || g.isEmpty) return (gradeKey: null, courseKey: null);
    return (gradeKey: g, courseKey: c?.isEmpty ?? true ? null : c);
  }

  Future<void> saveLastGradeCourse({
    required String gradeKey,
    required String courseKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastGradeKey, gradeKey.trim());
    await prefs.setString(_kLastCourseKey, courseKey.trim());
  }
}
