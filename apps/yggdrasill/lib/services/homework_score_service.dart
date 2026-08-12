import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'tenant_service.dart';

/// 과제 점수 v2(비율 기반).
///
/// v1은 EXP 누적값에서 점수를 역산했다. 누적값에서 상태 점수를 뽑으면 천장에 붙는다.
/// 실측상 3개월에 94점, 반년이면 99점대로 포화되어 변별력이 사라졌고, 과제를 1년 끊어도
/// 90점이 유지됐다. v2는 출석 점수와 같은 비율 구조로 바꿔 포화를 없앤다.
///
/// EXP형 누적은 포인트 원장(`PointService`)이 담당한다. 이 점수는 그 원장의 획득 배수
/// (부스터)를 만드는 입력으로 쓰인다.
///
/// 산식은 서버 `_homework_score_all_v2`가 유일한 원본이다. Dart에서 다시 계산하지 않는
/// 이유는 두 가지다. 첫째, 같은 산식을 두 곳에 두면 한쪽만 바뀌는 사고가 난다. 둘째,
/// 배정 이력이 수만 행으로 늘면 클라이언트가 전량을 받을 수 없다(PostgREST 기본 상한).
class HomeworkScoreService {
  HomeworkScoreService._internal();
  static final HomeworkScoreService instance = HomeworkScoreService._internal();

  static const String formulaVersion = 'homework_score_v2';

  /// 서버 파라미터와 동일한 값. 표시용으로만 쓴다.
  static const double halfLifeDays = 28.0;
  static const double requiredWeight = 8.0;

  /// 스탯 탭은 단일 학생 조회와 코호트 순위 조회를 연달아 호출한다.
  /// 같은 응답을 두 번 받지 않도록 짧게 캐시한다.
  static const Duration _cacheTtl = Duration(seconds: 45);

  Map<String, Map<String, dynamic>>? _cache;
  DateTime? _cachedAt;
  Future<Map<String, Map<String, dynamic>>>? _inFlight;

  void invalidateCache() {
    _cache = null;
    _cachedAt = null;
  }

  Future<Map<String, dynamic>> calculateHomeworkScore({
    required String studentId,
    DateTime? nowRef,
  }) async {
    final sid = studentId.trim();
    if (sid.isEmpty) return emptyScoreMap();
    final all = await _loadAll();
    return all[sid] ?? emptyScoreMap();
  }

  Future<Map<String, Map<String, dynamic>>> calculateHomeworkScoresForStudents({
    required List<String> studentIds,
    DateTime? nowRef,
  }) async {
    final ids = studentIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return <String, Map<String, dynamic>>{};

    final all = await _loadAll();
    final out = <String, Map<String, dynamic>>{};
    for (final id in ids) {
      out[id] = all[id] ?? emptyScoreMap();
    }
    return out;
  }

  Future<Map<String, Map<String, dynamic>>> _loadAll() async {
    final cached = _cache;
    final cachedAt = _cachedAt;
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _cacheTtl) {
      return cached;
    }
    final pending = _inFlight;
    if (pending != null) return pending;

    final future = _fetchAll();
    _inFlight = future;
    try {
      final result = await future;
      _cache = result;
      _cachedAt = DateTime.now();
      return result;
    } finally {
      _inFlight = null;
    }
  }

  Future<Map<String, Map<String, dynamic>>> _fetchAll() async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final res = await Supabase.instance.client.rpc(
        'homework_score_all_v2',
        params: <String, dynamic>{'p_academy_id': academyId},
      );
      if (res is! List) return <String, Map<String, dynamic>>{};

      final out = <String, Map<String, dynamic>>{};
      for (final raw in res) {
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw);
        final sid = (row['student_id'] as String?)?.trim() ?? '';
        if (sid.isEmpty) continue;
        out[sid] = _mapRow(row);
      }
      return out;
    } catch (e, st) {
      debugPrint('[HW_SCORE_V2][ERROR] $e\n$st');
      return <String, Map<String, dynamic>>{};
    }
  }

  Map<String, dynamic> _mapRow(Map<String, dynamic> row) {
    final evaluated = _asInt(row['evaluated_count']);
    return <String, dynamic>{
      'score100': _asDouble(row['score100']),
      'ratioRaw': _asDoubleOpt(row['ratio_raw']),
      'ratioAdjusted': _asDouble(row['ratio_adjusted']),
      'totalWeight': _asDouble(row['total_weight']),
      'evaluatedCount': evaluated,
      'completedCount': _asInt(row['completed_count']),
      'partialCount': _asInt(row['partial_count']),
      'untouchedCount': _asInt(row['untouched_count']),
      'pendingCount': _asInt(row['pending_count']),
      'insufficientEvidence': row['insufficient_evidence'] == true,
      // 총점 근거 판정이 이 키를 본다. v1과 이름을 맞춰 호출부를 깨지 않는다.
      'eventCount': evaluated,
      'halfLifeDays': halfLifeDays,
      'requiredWeight': requiredWeight,
      'formulaVersion': formulaVersion,
      'lastEventAt': row['last_event_at'] as String?,
    };
  }

  Map<String, dynamic> emptyScoreMap() => <String, dynamic>{
        'score100': 0.0,
        'ratioRaw': null,
        'ratioAdjusted': 0.0,
        'totalWeight': 0.0,
        'evaluatedCount': 0,
        'completedCount': 0,
        'partialCount': 0,
        'untouchedCount': 0,
        'pendingCount': 0,
        'insufficientEvidence': true,
        'eventCount': 0,
        'halfLifeDays': halfLifeDays,
        'requiredWeight': requiredWeight,
        'formulaVersion': formulaVersion,
        'lastEventAt': null,
      };

  double _asDouble(dynamic v) => _asDoubleOpt(v) ?? 0.0;

  double? _asDoubleOpt(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}
