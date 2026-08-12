import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'tenant_service.dart';

/// 포인트 지급/차감 종류.
///
/// 원장(student_point_ledger)의 `kind` 컬럼과 1:1로 대응한다.
/// DB check 제약과 값이 일치해야 하므로 임의로 문자열을 바꾸면 안 된다.
enum PointKind {
  earnAttendance('earn_attendance'),
  earnHomework('earn_homework'),
  earnBonus('earn_bonus'),
  penalty('penalty'),
  spendItem('spend_item'),
  adjust('adjust'),
  reversal('reversal');

  const PointKind(this.wire);
  final String wire;

  static PointKind? fromWire(String? value) {
    if (value == null) return null;
    for (final k in PointKind.values) {
      if (k.wire == value) return k;
    }
    return null;
  }
}

/// 원장 1건(불변 기록).
class PointLedgerEntry {
  final String id;
  final String studentId;
  final int delta;
  final PointKind? kind;
  final String kindRaw;
  final String sourceType;
  final String sourceId;
  final String ruleVersion;
  final Map<String, dynamic> basis;
  final String? memo;
  final DateTime createdAt;

  const PointLedgerEntry({
    required this.id,
    required this.studentId,
    required this.delta,
    required this.kind,
    required this.kindRaw,
    required this.sourceType,
    required this.sourceId,
    required this.ruleVersion,
    required this.basis,
    required this.memo,
    required this.createdAt,
  });

  bool get isEarn => delta > 0;

  String get kindLabel {
    switch (kind) {
      case PointKind.earnAttendance:
        return '출석';
      case PointKind.earnHomework:
        return '과제 완료';
      case PointKind.earnBonus:
        return '보너스';
      case PointKind.penalty:
        return '감점';
      case PointKind.spendItem:
        return '아이템 구매';
      case PointKind.adjust:
        return '수동 조정';
      case PointKind.reversal:
        return '지급 취소';
      case null:
        return kindRaw;
    }
  }

  static PointLedgerEntry? fromRow(Map<String, dynamic> row) {
    final id = row['id']?.toString();
    final studentId = row['student_id']?.toString();
    if (id == null || id.isEmpty || studentId == null || studentId.isEmpty) {
      return null;
    }
    final createdAtRaw = row['created_at']?.toString();
    if (createdAtRaw == null || createdAtRaw.isEmpty) return null;
    final kindRaw = row['kind']?.toString() ?? '';
    final basisRaw = row['basis'];
    return PointLedgerEntry(
      id: id,
      studentId: studentId,
      delta: (row['delta'] is num) ? (row['delta'] as num).toInt() : 0,
      kind: PointKind.fromWire(kindRaw),
      kindRaw: kindRaw,
      sourceType: row['source_type']?.toString() ?? '',
      sourceId: row['source_id']?.toString() ?? '',
      ruleVersion: row['rule_version']?.toString() ?? '',
      basis: (basisRaw is Map)
          ? Map<String, dynamic>.from(basisRaw)
          : const <String, dynamic>{},
      memo: row['memo']?.toString(),
      createdAt: DateTime.parse(createdAtRaw).toLocal(),
    );
  }
}

/// 학생 포인트 요약(파생 잔액 캐시).
class PointSummary {
  /// 사용 가능한 잔액. 아이템 구매 시 줄어든다.
  final int balance;

  /// 누적 획득량. 레벨/등급 계산 기준이며 소비해도 줄어들지 않는다.
  final int lifetimeEarned;
  final int lifetimeSpent;
  final int entryCount;
  final DateTime? lastEventAt;

  const PointSummary({
    required this.balance,
    required this.lifetimeEarned,
    required this.lifetimeSpent,
    required this.entryCount,
    required this.lastEventAt,
  });

  static const PointSummary empty = PointSummary(
    balance: 0,
    lifetimeEarned: 0,
    lifetimeSpent: 0,
    entryCount: 0,
    lastEventAt: null,
  );

  bool get isEmpty => entryCount == 0;
}

/// 포인트 제도 v1.
///
/// 설계 요지
///  - 원장은 append-only이고 지급은 발생 시점 값으로 확정된다. 이후 점수 공식이
///    바뀌어도 과거 지급분은 재계산하지 않는다.
///  - 중복 지급은 DB 유니크 제약이 막는다. 같은 출석/과제를 몇 번 호출해도 1회만
///    반영되므로 호출 측에서 별도 중복 검사를 하지 않아도 된다.
///  - 과제 완료 포인트는 DB 트리거가 지급한다(품질 지표가 DB에 있고, 학생앱 경로도
///    함께 커버해야 하므로). 출석 포인트만 여기서 지급한다(출석 점수와 지각 기준이
///    앱 쪽에만 있으므로).
class PointService {
  PointService._internal();
  static final PointService instance = PointService._internal();

  static const String ruleVersion = 'point_rule_v2';

  /// 정시 출석 기본 포인트.
  static const int attendanceOnTimeBase = 20;

  /// 지각 기본 포인트.
  static const int attendanceLateBase = 12;

  /// EXP 부스터 범위.
  ///
  /// 포인트는 감쇠 없이 누적되는 EXP다. 그래서 "지금 얼마나 잘하고 있나"는 잔액이 아니라
  /// 획득 배수로 반영한다. 총점이 높은 학생은 같은 과제/출석으로 더 많이 받는다.
  /// 하한을 1.0 아래로 둔 이유는 저성실 구간에 실질 패널티를 주기 위해서다.
  static const double boosterMin = 0.6;
  static const double boosterMax = 2.0;

  /// 부스터 근거가 없을 때(신규 학생) 사용하는 중립 배수.
  static const double boosterNeutral = 1.0;

  /// 포인트가 변동될 때 증가한다. UI가 이 값을 듣고 갱신한다.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void _bumpRevision() {
    revision.value = revision.value + 1;
  }

  /// 총점(0~100)을 EXP 부스터로 변환한다.
  ///
  /// 서버 `_booster_from_total_v1`과 같은 산식이다. 실제 지급에는 서버 값을 쓰고,
  /// 이 함수는 UI 미리보기와 서버 조회 실패 시의 대비용이다.
  static double boosterFromTotal(double? total100) {
    if (total100 == null) return boosterNeutral;
    final t = total100.clamp(0.0, 100.0).toDouble();
    final raw = boosterMin + (t / 100.0) * (boosterMax - boosterMin);
    return raw.clamp(boosterMin, boosterMax).toDouble();
  }

  /// 출석 1회에 지급할 포인트를 계산한다.
  static int attendancePointsFor({
    required bool isLate,
    required double? booster,
  }) {
    final base = isLate ? attendanceLateBase : attendanceOnTimeBase;
    final b = (booster ?? boosterNeutral).clamp(boosterMin, boosterMax).toDouble();
    final points = (base * b).round();
    return points < 1 ? 1 : points;
  }

  /// 트리거가 쓰는 것과 동일한 부스터를 서버에서 읽는다.
  ///
  /// 캐시가 오래되면 서버가 스스로 갱신하므로 클라이언트는 신선도를 관리하지 않는다.
  Future<Map<String, dynamic>?> loadBooster(String studentId) async {
    final sid = studentId.trim();
    if (sid.isEmpty) return null;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final res = await Supabase.instance.client.rpc(
        'booster_for_v1',
        params: <String, dynamic>{
          'p_academy_id': academyId,
          'p_student_id': sid,
        },
      );
      if (res is List && res.isNotEmpty) {
        final first = res.first;
        if (first is Map) return Map<String, dynamic>.from(first);
      }
      if (res is Map) return Map<String, dynamic>.from(res);
      return null;
    } catch (e) {
      debugPrint('[PointService] 부스터 조회 실패: $e');
      return null;
    }
  }

  /// 출석 확정 시 포인트를 지급한다.
  ///
  /// [attendanceRecordId]가 멱등 키이므로 같은 출석 기록에 대해 반복 호출해도
  /// 안전하다. 실패해도 출석 저장 자체를 되돌리지 않는다(포인트는 부가 기능).
  Future<Map<String, dynamic>?> grantAttendancePoints({
    required String studentId,
    required String attendanceRecordId,
    required bool isLate,
    required double? score100,
    DateTime? classDateTime,
    String? className,
  }) async {
    final sid = studentId.trim();
    final recordId = attendanceRecordId.trim();
    if (sid.isEmpty || recordId.isEmpty) return null;

    // 부스터는 과제 완료 트리거와 같은 서버 값을 쓴다. 조회에 실패하면 중립 배수로
    // 지급한다. 배수를 못 읽었다는 이유로 적립을 건너뛰면 학생이 손해를 본다.
    final boosterRow = await loadBooster(sid);
    final booster = boosterRow == null
        ? boosterNeutral
        : ((boosterRow['booster'] as num?)?.toDouble() ?? boosterNeutral);
    final boosterInput = (boosterRow?['booster_input'] as num?)?.toDouble();

    final points = attendancePointsFor(isLate: isLate, booster: booster);
    if (points <= 0) return null;

    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final res = await Supabase.instance.client.rpc(
        'point_grant_v1',
        params: <String, dynamic>{
          'p_academy_id': academyId,
          'p_student_id': sid,
          'p_delta': points,
          'p_kind': PointKind.earnAttendance.wire,
          'p_source_type': 'attendance_record',
          'p_source_id': recordId,
          'p_rule_version': ruleVersion,
          'p_basis': <String, dynamic>{
            'base': isLate ? attendanceLateBase : attendanceOnTimeBase,
            'is_late': isLate,
            'attendance_score100': score100,
            'booster': booster,
            'booster_input': boosterInput,
            'class_date_time': classDateTime?.toIso8601String(),
            'class_name': className,
          },
        },
      );
      final map = (res is Map) ? Map<String, dynamic>.from(res) : null;
      if (map != null && map['ok'] == true && map['duplicate'] != true) {
        _bumpRevision();
      }
      return map;
    } catch (e) {
      debugPrint('[PointService] 출석 포인트 지급 실패: $e');
      return null;
    }
  }

  /// 잘못 지급된 건을 되돌린다. 원장을 수정하지 않고 반대 거래를 추가한다.
  Future<Map<String, dynamic>?> reverseEntry({
    required PointLedgerEntry entry,
    String? memo,
  }) async {
    if (entry.delta == 0) return null;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final res = await Supabase.instance.client.rpc(
        'point_grant_v1',
        params: <String, dynamic>{
          'p_academy_id': academyId,
          'p_student_id': entry.studentId,
          'p_delta': -entry.delta,
          'p_kind': PointKind.reversal.wire,
          'p_source_type': entry.sourceType,
          'p_source_id': entry.sourceId,
          'p_rule_version': ruleVersion,
          'p_basis': <String, dynamic>{
            'reverses_ledger_id': entry.id,
            'original_kind': entry.kindRaw,
            'original_delta': entry.delta,
          },
          'p_memo': memo,
        },
      );
      final map = (res is Map) ? Map<String, dynamic>.from(res) : null;
      if (map != null && map['ok'] == true && map['duplicate'] != true) {
        _bumpRevision();
      }
      return map;
    } catch (e) {
      debugPrint('[PointService] 포인트 취소 실패: $e');
      return null;
    }
  }

  /// 학생 1명의 포인트 요약을 읽는다.
  Future<PointSummary> loadSummary(String studentId) async {
    final sid = studentId.trim();
    if (sid.isEmpty) return PointSummary.empty;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final row = await Supabase.instance.client
          .from('student_point_balances')
          .select(
            'balance,lifetime_earned,lifetime_spent,entry_count,last_event_at',
          )
          .eq('academy_id', academyId)
          .eq('student_id', sid)
          .maybeSingle();
      if (row == null) return PointSummary.empty;
      final m = Map<String, dynamic>.from(row as Map);
      final lastRaw = m['last_event_at']?.toString();
      return PointSummary(
        balance: _asInt(m['balance']),
        lifetimeEarned: _asInt(m['lifetime_earned']),
        lifetimeSpent: _asInt(m['lifetime_spent']),
        entryCount: _asInt(m['entry_count']),
        lastEventAt: (lastRaw == null || lastRaw.isEmpty)
            ? null
            : DateTime.parse(lastRaw).toLocal(),
      );
    } catch (e) {
      debugPrint('[PointService] 포인트 요약 조회 실패: $e');
      return PointSummary.empty;
    }
  }

  /// 최근 원장 내역을 읽는다.
  Future<List<PointLedgerEntry>> loadRecentLedger({
    required String studentId,
    int limit = 20,
  }) async {
    final sid = studentId.trim();
    if (sid.isEmpty) return const <PointLedgerEntry>[];
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final rows = await Supabase.instance.client
          .from('student_point_ledger')
          .select(
            'id,student_id,delta,kind,source_type,source_id,rule_version,basis,memo,created_at',
          )
          .eq('academy_id', academyId)
          .eq('student_id', sid)
          .order('created_at', ascending: false)
          .limit(limit);
      final out = <PointLedgerEntry>[];
      for (final r in (rows as List)) {
        final parsed = PointLedgerEntry.fromRow(Map<String, dynamic>.from(r as Map));
        if (parsed != null) out.add(parsed);
      }
      return out;
    } catch (e) {
      debugPrint('[PointService] 포인트 내역 조회 실패: $e');
      return const <PointLedgerEntry>[];
    }
  }

  /// 코호트 내 포인트 순위를 계산한다.
  ///
  /// 잔액은 소비에 따라 흔들리므로 순위는 누적 획득량(lifetime_earned) 기준으로 낸다.
  Future<Map<String, dynamic>> loadLifetimeRank({
    required String studentId,
    required List<String> cohortStudentIds,
  }) async {
    final sid = studentId.trim();
    final cohort = cohortStudentIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    if (sid.isEmpty || cohort.isEmpty) {
      return <String, dynamic>{
        'lifetime_earned': 0,
        'rank': null,
        'cohort_size': 0,
        'top_percent': null,
      };
    }
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final rows = await Supabase.instance.client
          .from('student_point_balances')
          .select('student_id,lifetime_earned')
          .eq('academy_id', academyId)
          .inFilter('student_id', cohort.toList());
      final earnedById = <String, int>{};
      for (final r in (rows as List)) {
        final m = Map<String, dynamic>.from(r as Map);
        final id = m['student_id']?.toString();
        if (id == null || id.isEmpty) continue;
        earnedById[id] = _asInt(m['lifetime_earned']);
      }
      // 원장이 없는 학생도 0점으로 코호트에 포함해야 순위가 왜곡되지 않는다.
      final scores = <String, int>{};
      for (final id in cohort) {
        scores[id] = earnedById[id] ?? 0;
      }
      final mine = scores[sid] ?? 0;
      final sorted = scores.values.toList()..sort((a, b) => b.compareTo(a));
      final rank = sorted.indexWhere((v) => v <= mine) + 1;
      final cohortSize = sorted.length;
      final topPercent =
          cohortSize <= 0 ? null : (rank / cohortSize) * 100.0;
      return <String, dynamic>{
        'lifetime_earned': mine,
        'rank': rank <= 0 ? null : rank,
        'cohort_size': cohortSize,
        'top_percent': topPercent,
      };
    } catch (e) {
      debugPrint('[PointService] 포인트 순위 계산 실패: $e');
      return <String, dynamic>{
        'lifetime_earned': 0,
        'rank': null,
        'cohort_size': 0,
        'top_percent': null,
      };
    }
  }

  static int _asInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}
