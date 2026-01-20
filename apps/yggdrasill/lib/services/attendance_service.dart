import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/attendance_record.dart';
import '../models/class_info.dart';
import '../models/cycle_attendance_summary.dart';
import '../models/lesson_occurrence.dart';
import '../models/payment_record.dart';
import '../models/session_override.dart';
import '../models/student_pause_period.dart';
import '../models/student_time_block.dart';
import 'package:uuid/uuid.dart';
import '../models/academy_settings.dart';
import 'tenant_service.dart';

// 하루/세트 단위로 블록을 집계하기 위한 구조체 (가장 빠른 시작/가장 늦은 종료)
class _PlannedDailyAgg {
  _PlannedDailyAgg({
    required this.studentId,
    required this.setId,
    required this.start,
    required this.end,
    this.sessionTypeId,
  });
  final String studentId;
  final String setId;
  DateTime start;
  DateTime end;
  String? sessionTypeId;
}

class AttendanceDependencies {
  AttendanceDependencies({
    required this.getStudentTimeBlocks,
    required this.getPaymentRecords,
    required this.getClasses,
    required this.getSessionOverrides,
    required this.getStudentPausePeriods,
    required this.getAcademySettings,
    required this.loadPaymentRecords,
    required this.updateSessionOverrideRemote,
    required this.applySessionOverrideLocal,
  });

  final List<StudentTimeBlock> Function() getStudentTimeBlocks;
  final List<PaymentRecord> Function() getPaymentRecords;
  final List<ClassInfo> Function() getClasses;
  final List<SessionOverride> Function() getSessionOverrides;
  final List<StudentPausePeriod> Function() getStudentPausePeriods;
  final AcademySettings Function() getAcademySettings;
  final Future<void> Function() loadPaymentRecords;
  final Future<void> Function(SessionOverride) updateSessionOverrideRemote;
  final void Function(SessionOverride) applySessionOverrideLocal;
}

class AttendanceService {
  AttendanceService._internal();
  static final AttendanceService instance = AttendanceService._internal();

  // 사이드 시트 디버그 플래그와 동일한 목적의 로깅 (planned 생성 검증용)
  // ✅ 기본 OFF: planned 생성 과정의 대량 로그는 UI 스레드를 쉽게 막아(특히 Windows) 1~2초 렉을 유발할 수 있다.
  // 필요 시 실행 옵션으로만 켤 수 있게 한다:
  // flutter run ... --dart-define=YG_SIDE_DEBUG=true
  static const bool _sideDebug =
      bool.fromEnvironment('YG_SIDE_DEBUG', defaultValue: false);

  // ✅ 서버는 class_date_time을 UTC 분(minute) 단위로 정규화한다.
  // 클라이언트에서도 동일한 키를 사용해 조회/업데이트가 안정적으로 되도록 맞춘다.
  static DateTime _utcMinute(DateTime dt) {
    final u = dt.toUtc();
    return DateTime.utc(u.year, u.month, u.day, u.hour, u.minute);
  }

  // ✅ cycle/session_order 계산용 키(분 단위)
  // - set_id가 다르면 같은 시각이라도 다른 회차로 취급(요구사항)
  // - 초/밀리초는 무시하고 분 단위로 고정
  static String _minuteKey(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    return '$y-$mo-$d-$h-$mi';
  }

  static String _sessionKeyForOrder(
      {required String setId, required DateTime startLocal}) {
    final sid = setId.trim();
    return '$sid|${_minuteKey(startLocal)}';
  }

  /// 결제 사이클 내 수업을 "시간순(+set_id tie-break)"으로 정렬했을 때의 session_order(1..N) 맵을 만든다.
  ///
  /// - 주 목적: student_time_blocks 연속 수정 후 planned 재생성 시 회차가 랜덤으로 섞이는 문제 방지
  /// - 범위: 해당 cycle 전체(dueDate~다음 dueDate)에서 계산
  Map<String, int> _buildSessionOrderMapForStudentCycle({
    required String studentId,
    required int cycle,
    List<StudentTimeBlock>? blocksOverride,
  }) {
    final range = _cycleRangeForStudent(studentId: studentId, cycle: cycle);
    if (range == null) return const <String, int>{};

    final blocks = (blocksOverride ?? _d.getStudentTimeBlocks())
        .where((b) =>
            b.studentId == studentId && (b.setId ?? '').trim().isNotEmpty)
        .toList();
    if (blocks.isEmpty) return const <String, int>{};

    final candidates = <_PlannedDailyAgg>[];
    for (DateTime day = range.start;
        day.isBefore(range.end);
        day = day.add(const Duration(days: 1))) {
      final dayIdx = day.weekday - 1;
      final Map<String, _PlannedDailyAgg> aggBySet = {};
      for (final b in blocks.where((b) => b.dayIndex == dayIdx)) {
        if (!_isBlockActiveOnDate(b, day)) continue;
        final setId = (b.setId ?? '').trim();
        if (setId.isEmpty) continue;
        final classStart =
            DateTime(day.year, day.month, day.day, b.startHour, b.startMinute);
        final classEnd = classStart.add(b.duration);
        final agg = aggBySet.putIfAbsent(
          setId,
          () => _PlannedDailyAgg(
            studentId: studentId,
            setId: setId,
            start: classStart,
            end: classEnd,
            sessionTypeId: b.sessionTypeId,
          ),
        );
        if (classStart.isBefore(agg.start)) agg.start = classStart;
        if (classEnd.isAfter(agg.end)) agg.end = classEnd;
        if (agg.sessionTypeId == null && b.sessionTypeId != null) {
          agg.sessionTypeId = b.sessionTypeId;
        }
      }
      candidates.addAll(aggBySet.values);
    }

    if (candidates.isEmpty) return const <String, int>{};

    candidates.sort((a, b) {
      final cmpDt = a.start.compareTo(b.start);
      if (cmpDt != 0) return cmpDt;
      return a.setId.compareTo(b.setId);
    });

    final map = <String, int>{};
    for (int i = 0; i < candidates.length; i++) {
      final c = candidates[i];
      map[_sessionKeyForOrder(setId: c.setId, startLocal: c.start)] = i + 1;
    }
    return map;
  }

  AttendanceDependencies? _deps;
  void configure(AttendanceDependencies deps) {
    _deps = deps;
  }

  AttendanceDependencies get _d {
    final deps = _deps;
    if (deps == null) {
      throw StateError('AttendanceService not configured');
    }
    return deps;
  }

  bool _isStudentPausedOn(String studentId, DateTime dateLocal) {
    final d = DateTime(dateLocal.year, dateLocal.month, dateLocal.day);
    for (final p in _d.getStudentPausePeriods()) {
      if (p.studentId != studentId) continue;
      if (p.isActiveOn(d)) return true;
    }
    return false;
  }

  final ValueNotifier<List<AttendanceRecord>> attendanceRecordsNotifier =
      ValueNotifier<List<AttendanceRecord>>([]);
  List<AttendanceRecord> _attendanceRecords = [];
  List<AttendanceRecord> get attendanceRecords =>
      List.unmodifiable(_attendanceRecords);

  final ValueNotifier<List<LessonOccurrence>> lessonOccurrencesNotifier =
      ValueNotifier<List<LessonOccurrence>>([]);
  List<LessonOccurrence> _lessonOccurrences = [];
  List<LessonOccurrence> get lessonOccurrences =>
      List.unmodifiable(_lessonOccurrences);

  RealtimeChannel? _attendanceRealtimeChannel;

  Timer? _plannedRegenTimer;
  final Map<String, Set<String>> _pendingRegenSetIdsByStudent = {};

  void reset() {
    _attendanceRecords = [];
    if (_sideDebug) {
      print('[ATT][reset] attendanceRecords cleared');
    }
    attendanceRecordsNotifier.value = [];
    _lessonOccurrences = [];
    lessonOccurrencesNotifier.value = [];
  }

  Future<void> forceMigration() async {
    try {
      await TenantService.instance.ensureActiveAcademy();
      await loadAttendanceRecords();
    } catch (_) {}
  }

  /// 출석 기록을 서버에서 로드한다.
  ///
  /// ⚠️ PostgREST `max_rows`(예: 1000)에 의해 "전체 select"는 잘릴 수 있다.
  /// 그래서 기본 로딩은 날짜 범위를 제한(rolling window)하고, 그 범위 내에서는 페이지네이션으로 모두 가져온다.
  ///
  /// - 기본 범위: 과거 2년 ~ 미래 1년 (학생 수업기록/달력 인디케이터에서 사용하는 date picker 범위와 정합)
  Future<void> loadAttendanceRecords({
    DateTime? fromInclusive,
    DateTime? toExclusive,
    int pastDays = 365 * 2,
    int futureDays = 365,
  }) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;

      final now = DateTime.now();
      final todayLocal = DateTime(now.year, now.month, now.day);

      // from/to는 "로컬 기준"으로 받고, 서버 필터는 UTC ISO로 변환한다.
      final DateTime fromLocal = fromInclusive != null
          ? fromInclusive.toLocal()
          : todayLocal.subtract(Duration(days: pastDays));
      final DateTime toLocal = toExclusive != null
          ? toExclusive.toLocal()
          : todayLocal.add(Duration(days: futureDays + 1)); // ✅ toExclusive

      final DateTime fromUtc =
          DateTime(fromLocal.year, fromLocal.month, fromLocal.day).toUtc();
      final DateTime toUtc =
          DateTime(toLocal.year, toLocal.month, toLocal.day).toUtc();

      if (!fromUtc.isBefore(toUtc)) {
        // 잘못된 범위면 안전하게 비움
        _attendanceRecords = [];
        attendanceRecordsNotifier.value = const [];
        return;
      }

      const selectCols =
          'id,student_id,occurrence_id,class_date_time,class_end_time,class_name,is_present,arrival_time,departure_time,notes,session_type_id,set_id,cycle,session_order,is_planned,snapshot_id,batch_session_id,created_at,updated_at,version';

      // ✅ 범위 내 페이지네이션 로드
      // - Range header로 0..999, 1000..1999 ... 형태로 계속 가져온다.
      // - 정렬 안정성을 위해 class_date_time + id를 함께 order한다.
      const int pageSize = 1000;
      int offset = 0;
      final List<dynamic> allRows = <dynamic>[];
      while (true) {
        final rows = await supa
            .from('attendance_records')
            .select(selectCols)
            .eq('academy_id', academyId)
            .gte('class_date_time', fromUtc.toIso8601String())
            .lt('class_date_time', toUtc.toIso8601String())
            .order('class_date_time', ascending: false)
            .order('id', ascending: false)
            .range(offset, offset + pageSize - 1);

        final list = (rows is List) ? rows : <dynamic>[];
        allRows.addAll(list);
        if (list.length < pageSize) break;
        offset += list.length;
        // 무한 루프 방지(정상 케이스에서는 도달하지 않음)
        if (offset > 200000) break;
      }

      _attendanceRecords = allRows.map<AttendanceRecord>((m0) {
        final m = Map<String, dynamic>.from(m0 as Map);
        DateTime parseTs(String k) => DateTime.parse(m[k] as String).toLocal();
        DateTime? parseTsOpt(String k) {
          final v = m[k] as String?;
          if (v == null || v.isEmpty) return null;
          return DateTime.parse(v).toLocal();
        }

        final dynamic isPresentDyn = m['is_present'];
        final bool isPresent = (isPresentDyn is bool)
            ? isPresentDyn
            : ((isPresentDyn is num) ? isPresentDyn == 1 : false);
        return AttendanceRecord(
          id: m['id'] as String?,
          studentId: m['student_id'] as String,
          occurrenceId: m['occurrence_id']?.toString(),
          classDateTime: parseTs('class_date_time'),
          classEndTime: parseTs('class_end_time'),
          className: (m['class_name'] as String?) ?? '',
          isPresent: isPresent,
          arrivalTime: parseTsOpt('arrival_time'),
          departureTime: parseTsOpt('departure_time'),
          notes: m['notes'] as String?,
          sessionTypeId: m['session_type_id'] as String?,
          setId: m['set_id'] as String?,
          snapshotId: m['snapshot_id'] as String?,
          batchSessionId: m['batch_session_id'] as String?,
          cycle: (m['cycle'] is num) ? (m['cycle'] as num).toInt() : null,
          sessionOrder: (m['session_order'] is num)
              ? (m['session_order'] as num).toInt()
              : null,
          isPlanned: m['is_planned'] == true || m['is_planned'] == 1,
          createdAt: parseTs('created_at'),
          updatedAt: parseTs('updated_at'),
          version: (m['version'] is num) ? (m['version'] as num).toInt() : 1,
        );
      }).toList()
        ..sort((a, b) => b.classDateTime.compareTo(a.classDateTime));

      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      print(
        '[SUPA] 출석 기록 로드: ${_attendanceRecords.length}개 (rangeUtc=${fromUtc.toIso8601String()}..${toUtc.toIso8601String()})',
      );
    } catch (e, st) {
      print('[SUPA][ERROR] 출석 기록 로드 실패: $e\n$st');
      _attendanceRecords = [];
      if (_sideDebug) {
        print('[ATT][loadAttendanceRecords][error] publish empty');
      }
      attendanceRecordsNotifier.value = [];
    }
  }

  /// 원본 회차(lesson_occurrences)를 서버에서 로드한다.
  ///
  /// - 기본 범위: 과거 ~200일 ~ 미래 ~60일 (cycle/정산 UI에서 주로 사용)
  Future<void> loadLessonOccurrences({
    DateTime? fromInclusive,
    DateTime? toExclusive,
    int pastDays = 200,
    int futureDays = 60,
  }) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;

      final now = DateTime.now();
      final todayLocal = DateTime(now.year, now.month, now.day);

      final DateTime fromLocal = fromInclusive != null
          ? fromInclusive.toLocal()
          : todayLocal.subtract(Duration(days: pastDays));
      final DateTime toLocal = toExclusive != null
          ? toExclusive.toLocal()
          : todayLocal.add(Duration(days: futureDays + 1));

      final DateTime fromUtc =
          DateTime(fromLocal.year, fromLocal.month, fromLocal.day).toUtc();
      final DateTime toUtc =
          DateTime(toLocal.year, toLocal.month, toLocal.day).toUtc();
      if (!fromUtc.isBefore(toUtc)) {
        _lessonOccurrences = [];
        lessonOccurrencesNotifier.value = const [];
        return;
      }

      const selectCols =
          'id,student_id,kind,cycle,session_order,original_class_datetime,original_class_end_time,duration_minutes,session_type_id,set_id,snapshot_id,created_at,updated_at,version';

      const int pageSize = 1000;
      int offset = 0;
      final List<dynamic> allRows = <dynamic>[];
      while (true) {
        final rows = await supa
            .from('lesson_occurrences')
            .select(selectCols)
            .eq('academy_id', academyId)
            .gte('original_class_datetime', fromUtc.toIso8601String())
            .lt('original_class_datetime', toUtc.toIso8601String())
            .order('original_class_datetime', ascending: false)
            .order('id', ascending: false)
            .range(offset, offset + pageSize - 1);

        final list = (rows is List) ? rows : <dynamic>[];
        allRows.addAll(list);
        if (list.length < pageSize) break;
        offset += list.length;
        if (offset > 200000) break;
      }

      _lessonOccurrences = allRows.map<LessonOccurrence>((m0) {
        final m = Map<String, dynamic>.from(m0 as Map);
        DateTime parseTs(String k) => DateTime.parse(m[k] as String).toLocal();
        DateTime? parseTsOpt(String k) {
          final v = m[k] as String?;
          if (v == null || v.isEmpty) return null;
          return DateTime.parse(v).toLocal();
        }

        int? asIntOpt(dynamic v) {
          if (v == null) return null;
          if (v is int) return v;
          if (v is num) return v.toInt();
          if (v is String) return int.tryParse(v);
          return null;
        }

        return LessonOccurrence(
          id: m['id']?.toString() ?? '',
          studentId: m['student_id']?.toString() ?? '',
          kind: (m['kind']?.toString() ?? 'regular').trim(),
          cycle: asIntOpt(m['cycle']) ?? 0,
          sessionOrder: asIntOpt(m['session_order']),
          originalClassDateTime: parseTs('original_class_datetime'),
          originalClassEndTime: parseTsOpt('original_class_end_time'),
          durationMinutes: asIntOpt(m['duration_minutes']),
          sessionTypeId: m['session_type_id']?.toString(),
          setId: m['set_id']?.toString(),
          snapshotId: m['snapshot_id']?.toString(),
          createdAt: parseTsOpt('created_at'),
          updatedAt: parseTsOpt('updated_at'),
          version: asIntOpt(m['version']),
        );
      }).toList()
        ..sort((a, b) =>
            b.originalClassDateTime.compareTo(a.originalClassDateTime));

      lessonOccurrencesNotifier.value = List.unmodifiable(_lessonOccurrences);
      if (_sideDebug) {
        print(
          '[SUPA] lesson_occurrences 로드: ${_lessonOccurrences.length}개 (rangeUtc=${fromUtc.toIso8601String()}..${toUtc.toIso8601String()})',
        );
      }
    } catch (e, st) {
      // 아직 마이그레이션 전/테이블 미존재 등도 여기로 올 수 있으므로 조용히 fallback
      if (_sideDebug) {
        print('[SUPA][WARN] lesson_occurrences 로드 실패(무시): $e\n$st');
      }
      _lessonOccurrences = [];
      lessonOccurrencesNotifier.value = [];
    }
  }

  ({DateTime start, DateTime end})? _cycleRangeForStudent({
    required String studentId,
    required int cycle,
  }) {
    final paymentRecords =
        _d.getPaymentRecords().where((p) => p.studentId == studentId).toList();
    PaymentRecord? cur;
    PaymentRecord? next;
    for (final p in paymentRecords) {
      if (p.cycle == cycle) cur = p;
      if (p.cycle == cycle + 1) next = p;
    }
    if (cur == null) return null;
    final DateTime start =
        DateTime(cur!.dueDate.year, cur!.dueDate.month, cur!.dueDate.day);
    final DateTime end = next != null
        ? DateTime(next!.dueDate.year, next!.dueDate.month, next!.dueDate.day)
        : start.add(const Duration(days: 31));
    return (start: start, end: end);
  }

  Future<List<LessonOccurrence>> _fetchLessonOccurrencesForStudentCycle({
    required String academyId,
    required String studentId,
    required int cycle,
    required String kind,
  }) async {
    final supa = Supabase.instance.client;
    const selectCols =
        'id,student_id,kind,cycle,session_order,original_class_datetime,original_class_end_time,duration_minutes,session_type_id,set_id,snapshot_id,created_at,updated_at,version';
    final rows = await supa
        .from('lesson_occurrences')
        .select(selectCols)
        .eq('academy_id', academyId)
        .eq('student_id', studentId)
        .eq('cycle', cycle)
        .eq('kind', kind)
        .order('original_class_datetime', ascending: true)
        .order('id', ascending: true);
    final list = (rows is List) ? rows : <dynamic>[];
    DateTime parseTs(Map m, String k) =>
        DateTime.parse(m[k] as String).toLocal();
    DateTime? parseTsOpt(Map m, String k) {
      final v = m[k] as String?;
      if (v == null || v.isEmpty) return null;
      return DateTime.parse(v).toLocal();
    }

    int? asIntOpt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    return list.map<LessonOccurrence>((m0) {
      final m = Map<String, dynamic>.from(m0 as Map);
      return LessonOccurrence(
        id: m['id']?.toString() ?? '',
        studentId: m['student_id']?.toString() ?? '',
        kind: (m['kind']?.toString() ?? kind).trim(),
        cycle: asIntOpt(m['cycle']) ?? cycle,
        sessionOrder: asIntOpt(m['session_order']),
        originalClassDateTime: parseTs(m, 'original_class_datetime'),
        originalClassEndTime: parseTsOpt(m, 'original_class_end_time'),
        durationMinutes: asIntOpt(m['duration_minutes']),
        sessionTypeId: m['session_type_id']?.toString(),
        setId: m['set_id']?.toString(),
        snapshotId: m['snapshot_id']?.toString(),
        createdAt: parseTsOpt(m, 'created_at'),
        updatedAt: parseTsOpt(m, 'updated_at'),
        version: asIntOpt(m['version']),
      );
    }).toList();
  }

  Future<List<LessonOccurrence>>
      _ensureRegularLessonOccurrencesForStudentCycle({
    required String academyId,
    required String studentId,
    required int cycle,
  }) async {
    // 1) already exists?
    try {
      final existing = await _fetchLessonOccurrencesForStudentCycle(
        academyId: academyId,
        studentId: studentId,
        cycle: cycle,
        kind: 'regular',
      );
      if (existing.isNotEmpty) {
        _mergeLessonOccurrences(existing);
        return existing;
      }
    } catch (_) {
      // 테이블 미존재/권한 등: 상위 로직에서 fallback하도록 비움 반환
      return const <LessonOccurrence>[];
    }

    final range = _cycleRangeForStudent(studentId: studentId, cycle: cycle);
    if (range == null) return const <LessonOccurrence>[];

    // ✅ cycle 시작 시점에 "활성"이었던 블록만을 원본 회차 생성의 근거로 사용한다.
    // (보강/추가수업이 원본 회차를 훼손하지 않도록, 원본은 고정 엔티티로 저장)
    final DateTime start = range.start;
    final DateTime end = range.end;

    final blocks = _d.getStudentTimeBlocks().where((b) {
      if (b.studentId != studentId) return false;
      final sid = (b.setId ?? '').trim();
      if (sid.isEmpty) return false;
      return _isBlockActiveOnDate(b, start);
    }).toList();
    if (blocks.isEmpty) return const <LessonOccurrence>[];

    // 날짜별/세트별 집계(하루/세트당 1개 occurrence)
    final candidates = <_PlannedDailyAgg>[];
    for (DateTime d = start;
        d.isBefore(end);
        d = d.add(const Duration(days: 1))) {
      final dayIdx = d.weekday - 1;
      final Map<String, _PlannedDailyAgg> aggBySet = {};
      for (final b in blocks.where((b) => b.dayIndex == dayIdx)) {
        final setId = (b.setId ?? '').trim();
        if (setId.isEmpty) continue;
        final classStart =
            DateTime(d.year, d.month, d.day, b.startHour, b.startMinute);
        final classEnd = classStart.add(b.duration);
        final agg = aggBySet.putIfAbsent(
          setId,
          () => _PlannedDailyAgg(
            studentId: b.studentId,
            setId: setId,
            start: classStart,
            end: classEnd,
            sessionTypeId: b.sessionTypeId,
          ),
        );
        if (classStart.isBefore(agg.start)) agg.start = classStart;
        if (classEnd.isAfter(agg.end)) agg.end = classEnd;
        if (agg.sessionTypeId == null && b.sessionTypeId != null) {
          agg.sessionTypeId = b.sessionTypeId;
        }
      }
      candidates.addAll(aggBySet.values);
    }
    if (candidates.isEmpty) return const <LessonOccurrence>[];

    candidates.sort((a, b) {
      final cmpDt = a.start.compareTo(b.start);
      if (cmpDt != 0) return cmpDt;
      return a.setId.compareTo(b.setId);
    });

    final rows = <Map<String, dynamic>>[];
    for (int i = 0; i < candidates.length; i++) {
      final c = candidates[i];
      final int sessionOrder = i + 1;
      final startUtc = _utcMinute(c.start);
      final durMin = c.end.difference(c.start).inMinutes;
      final endUtc = startUtc.add(Duration(
          minutes:
              durMin <= 0 ? _d.getAcademySettings().lessonDuration : durMin));
      rows.add({
        'academy_id': academyId,
        'student_id': studentId,
        'kind': 'regular',
        'cycle': cycle,
        'session_order': sessionOrder,
        'original_class_datetime': startUtc.toIso8601String(),
        'original_class_end_time': endUtc.toIso8601String(),
        'duration_minutes': durMin,
        'session_type_id': c.sessionTypeId,
        'set_id': c.setId,
      }..removeWhere((k, v) => v == null));
    }

    // insert (chunked)
    final supa = Supabase.instance.client;
    const int chunk = 500;
    try {
      for (int i = 0; i < rows.length; i += chunk) {
        final part = rows.sublist(
            i, (i + chunk > rows.length) ? rows.length : i + chunk);
        await supa.from('lesson_occurrences').insert(part);
      }
    } catch (e) {
      // 다른 클라이언트가 동시에 생성했을 수 있으므로, 실패해도 "재조회"로 마무리한다.
      if (_sideDebug) {
        print(
            '[OCC][WARN] regular occurrences insert failed (will refetch): $e');
      }
    }

    try {
      final created = await _fetchLessonOccurrencesForStudentCycle(
        academyId: academyId,
        studentId: studentId,
        cycle: cycle,
        kind: 'regular',
      );
      _mergeLessonOccurrences(created);
      return created;
    } catch (_) {
      return const <LessonOccurrence>[];
    }
  }

  void _mergeLessonOccurrences(List<LessonOccurrence> incoming) {
    if (incoming.isEmpty) return;
    final byId = <String, LessonOccurrence>{
      for (final o in _lessonOccurrences) o.id: o,
    };
    for (final o in incoming) {
      if (o.id.isEmpty) continue;
      byId[o.id] = o;
    }
    _lessonOccurrences = byId.values.toList()
      ..sort(
          (a, b) => b.originalClassDateTime.compareTo(a.originalClassDateTime));
    lessonOccurrencesNotifier.value = List.unmodifiable(_lessonOccurrences);
  }

  /// (임시 관리자 도구) lesson_occurrences(원본 회차) 생성 + occurrence_id 백필
  ///
  /// 목적:
  /// - 보강(replace): 원본 cycle/sessionOrder가 훼손되지 않도록, 원본 occurrence에 귀속시키는 링크를 채운다.
  /// - 추가수업(add): kind='extra' occurrence로 분리 저장하여 사이클 집계에서 제외 가능하게 한다.
  ///
  /// 범위:
  /// - 기본: 과거 2년 ~ 미래 60일 (출석 로드 기본 범위와 유사)
  ///
  /// NOTE:
  /// - Supabase 마이그레이션(lesson_occurrences + occurrence_id 컬럼)이 적용되지 않은 환경에서는
  ///   조용히 실패할 수 있다(예외는 호출자가 UI에서 처리).
  Future<
      ({
        int ensuredCycles,
        int updatedOverrides,
        int updatedAttendance,
        int createdExtraOccurrences,
      })> runOccurrenceBackfillTool({
    DateTime? fromInclusive,
    DateTime? toExclusive,
    int pastDays = 365 * 2,
    int futureDays = 60,
    void Function(String phase, int done, int total)? onProgress,
  }) async {
    final String academyId =
        (await TenantService.instance.getActiveAcademyId()) ??
            await TenantService.instance.ensureActiveAcademy();
    final supa = Supabase.instance.client;

    final now = DateTime.now();
    final todayLocal = DateTime(now.year, now.month, now.day);
    final DateTime fromLocal = fromInclusive != null
        ? fromInclusive.toLocal()
        : todayLocal.subtract(Duration(days: pastDays));
    final DateTime toLocal = toExclusive != null
        ? toExclusive.toLocal()
        : todayLocal.add(Duration(days: futureDays + 1));

    if (!fromLocal.isBefore(toLocal)) {
      return (
        ensuredCycles: 0,
        updatedOverrides: 0,
        updatedAttendance: 0,
        createdExtraOccurrences: 0
      );
    }

    try {
      await _d.loadPaymentRecords();
    } catch (_) {}

    // 1) regular occurrence 생성/보장 (cycle 범위에 걸치는 것만)
    final prs = _d.getPaymentRecords().toList();
    final Map<String, List<PaymentRecord>> byStudent = {};
    for (final p in prs) {
      byStudent.putIfAbsent(p.studentId, () => <PaymentRecord>[]).add(p);
    }

    bool intersects(
        DateTime aStart, DateTime aEnd, DateTime bStart, DateTime bEnd) {
      return aEnd.isAfter(bStart) && aStart.isBefore(bEnd);
    }

    final cycles = <({String studentId, int cycle})>[];
    for (final entry in byStudent.entries) {
      final sid = entry.key;
      final list = entry.value..sort((a, b) => a.cycle.compareTo(b.cycle));
      for (int i = 0; i < list.length; i++) {
        final cur = list[i];
        final start =
            DateTime(cur.dueDate.year, cur.dueDate.month, cur.dueDate.day);
        final end = (i + 1 < list.length)
            ? DateTime(list[i + 1].dueDate.year, list[i + 1].dueDate.month,
                list[i + 1].dueDate.day)
            : start.add(const Duration(days: 31));
        if (!intersects(start, end, fromLocal, toLocal)) continue;
        cycles.add((studentId: sid, cycle: cur.cycle));
      }
    }

    int ensuredCycles = 0;
    for (int i = 0; i < cycles.length; i++) {
      onProgress?.call('원본 회차 생성(regular)', i, cycles.length);
      final c = cycles[i];
      try {
        await _ensureRegularLessonOccurrencesForStudentCycle(
          academyId: academyId,
          studentId: c.studentId,
          cycle: c.cycle,
        );
        ensuredCycles += 1;
      } catch (_) {
        // ignore per cycle
      }
    }

    // 최신 occurrence 로드/정렬(맵 생성용)
    try {
      await loadLessonOccurrences(
          fromInclusive: fromLocal, toExclusive: toLocal);
    } catch (_) {}

    String minKey(DateTime dt) =>
        '${dt.year}-${dt.month}-${dt.day}-${dt.hour}-${dt.minute}';
    String occKey(String studentId, String setId, DateTime dt) =>
        '$studentId|$setId|${minKey(dt)}';

    final Map<String, LessonOccurrence> regularOccByKey = {};
    final Map<String, LessonOccurrence> regularOccByCycleOrder = {};
    final Map<String, LessonOccurrence> extraOccByKey = {};
    for (final o in _lessonOccurrences) {
      final sid = (o.setId ?? '').trim();
      if (o.kind == 'regular') {
        if (sid.isNotEmpty) {
          regularOccByKey[occKey(o.studentId, sid, o.originalClassDateTime)] =
              o;
        }
        if (o.sessionOrder != null && o.sessionOrder! > 0) {
          regularOccByCycleOrder[
              '${o.studentId}|${o.cycle}|${o.sessionOrder}'] = o;
        }
      } else if (o.kind == 'extra') {
        if (sid.isNotEmpty) {
          extraOccByKey[occKey(o.studentId, sid, o.originalClassDateTime)] = o;
        }
      }
    }

    Future<LessonOccurrence?> ensureExtraOcc({
      required String studentId,
      required String setId,
      required DateTime replacementLocal,
      required int durationMinutes,
      String? sessionTypeId,
    }) async {
      final existing =
          extraOccByKey[occKey(studentId, setId, replacementLocal)];
      if (existing != null) return existing;
      final int cycle =
          _resolveCycleByDueDate(studentId, replacementLocal) ?? 1;
      final startUtc = _utcMinute(replacementLocal);
      final endUtc = startUtc.add(Duration(minutes: durationMinutes));
      const occSelect =
          'id,student_id,kind,cycle,session_order,original_class_datetime,original_class_end_time,duration_minutes,session_type_id,set_id,snapshot_id,created_at,updated_at,version';
      try {
        final inserted = await supa
            .from('lesson_occurrences')
            .insert({
              'academy_id': academyId,
              'student_id': studentId,
              'kind': 'extra',
              'cycle': cycle,
              'session_order': null,
              'original_class_datetime': startUtc.toIso8601String(),
              'original_class_end_time': endUtc.toIso8601String(),
              'duration_minutes': durationMinutes,
              'session_type_id': sessionTypeId,
              'set_id': setId,
            }..removeWhere((k, v) => v == null))
            .select(occSelect)
            .maybeSingle();
        if (inserted != null) {
          final m = Map<String, dynamic>.from(inserted as Map);
          DateTime parseTs(String k) =>
              DateTime.parse(m[k] as String).toLocal();
          DateTime? parseTsOpt(String k) {
            final v = m[k] as String?;
            if (v == null || v.isEmpty) return null;
            return DateTime.parse(v).toLocal();
          }

          int? asIntOpt(dynamic v) {
            if (v == null) return null;
            if (v is int) return v;
            if (v is num) return v.toInt();
            if (v is String) return int.tryParse(v);
            return null;
          }

          final occ = LessonOccurrence(
            id: m['id']?.toString() ?? '',
            studentId: m['student_id']?.toString() ?? studentId,
            kind: (m['kind']?.toString() ?? 'extra').trim(),
            cycle: asIntOpt(m['cycle']) ?? cycle,
            sessionOrder: asIntOpt(m['session_order']),
            originalClassDateTime: parseTs('original_class_datetime'),
            originalClassEndTime: parseTsOpt('original_class_end_time'),
            durationMinutes: asIntOpt(m['duration_minutes']) ?? durationMinutes,
            sessionTypeId: m['session_type_id']?.toString(),
            setId: m['set_id']?.toString(),
            snapshotId: m['snapshot_id']?.toString(),
            createdAt: parseTsOpt('created_at'),
            updatedAt: parseTsOpt('updated_at'),
            version: asIntOpt(m['version']),
          );
          _mergeLessonOccurrences([occ]);
          final sid = (occ.setId ?? '').trim();
          if (sid.isNotEmpty) {
            extraOccByKey[
                occKey(occ.studentId, sid, occ.originalClassDateTime)] = occ;
          }
          return occ;
        }
      } catch (_) {
        // duplicate or table missing -> try fetch
        try {
          final fetched = await supa
              .from('lesson_occurrences')
              .select(occSelect)
              .eq('academy_id', academyId)
              .eq('student_id', studentId)
              .eq('kind', 'extra')
              .eq('set_id', setId)
              .eq('original_class_datetime', startUtc.toIso8601String())
              .maybeSingle();
          if (fetched != null) {
            final m = Map<String, dynamic>.from(fetched as Map);
            DateTime parseTs(String k) =>
                DateTime.parse(m[k] as String).toLocal();
            DateTime? parseTsOpt(String k) {
              final v = m[k] as String?;
              if (v == null || v.isEmpty) return null;
              return DateTime.parse(v).toLocal();
            }

            int? asIntOpt(dynamic v) {
              if (v == null) return null;
              if (v is int) return v;
              if (v is num) return v.toInt();
              if (v is String) return int.tryParse(v);
              return null;
            }

            final occ = LessonOccurrence(
              id: m['id']?.toString() ?? '',
              studentId: m['student_id']?.toString() ?? studentId,
              kind: (m['kind']?.toString() ?? 'extra').trim(),
              cycle: asIntOpt(m['cycle']) ?? cycle,
              sessionOrder: asIntOpt(m['session_order']),
              originalClassDateTime: parseTs('original_class_datetime'),
              originalClassEndTime: parseTsOpt('original_class_end_time'),
              durationMinutes:
                  asIntOpt(m['duration_minutes']) ?? durationMinutes,
              sessionTypeId: m['session_type_id']?.toString(),
              setId: m['set_id']?.toString(),
              snapshotId: m['snapshot_id']?.toString(),
              createdAt: parseTsOpt('created_at'),
              updatedAt: parseTsOpt('updated_at'),
              version: asIntOpt(m['version']),
            );
            _mergeLessonOccurrences([occ]);
            final sid = (occ.setId ?? '').trim();
            if (sid.isNotEmpty) {
              extraOccByKey[
                  occKey(occ.studentId, sid, occ.originalClassDateTime)] = occ;
            }
            return occ;
          }
        } catch (_) {}
      }
      return null;
    }

    // 2) session_overrides occurrence_id 백필
    int updatedOverrides = 0;
    int createdExtraOccurrences = 0;
    final overrides = _d.getSessionOverrides().toList();
    int ovDone = 0;
    for (final ov in overrides) {
      ovDone++;
      onProgress?.call('보강/추가수업 오버라이드 백필', ovDone, overrides.length);
      final curOcc = (ov.occurrenceId ?? '').trim();
      if (curOcc.isNotEmpty) continue;

      String? occId;
      if (ov.overrideType == OverrideType.replace) {
        final orig = ov.originalClassDateTime;
        if (orig != null) {
          final setId =
              (ov.setId ?? _resolveSetId(ov.studentId, orig) ?? '').trim();
          if (setId.isNotEmpty) {
            occId = regularOccByKey[occKey(ov.studentId, setId, orig)]?.id;
          }
        }
      } else if (ov.overrideType == OverrideType.add) {
        final rep = ov.replacementClassDateTime;
        if (rep != null) {
          final setId = (ov.setId ?? ov.id).trim();
          if (setId.isNotEmpty) {
            final dur =
                ov.durationMinutes ?? _d.getAcademySettings().lessonDuration;
            final occ = await ensureExtraOcc(
              studentId: ov.studentId,
              setId: setId,
              replacementLocal: rep,
              durationMinutes: dur,
              sessionTypeId: ov.sessionTypeId,
            );
            if (occ != null) {
              occId = occ.id;
              if (extraOccByKey.containsKey(occKey(ov.studentId, setId, rep)) ==
                  false) {
                createdExtraOccurrences += 1;
              }
            }
          }
        }
      } else {
        continue;
      }

      if (occId == null || occId!.isEmpty) continue;
      try {
        await supa
            .from('session_overrides')
            .update({'occurrence_id': occId}).eq('id', ov.id);
        // local reflect (no regen)
        _d.applySessionOverrideLocal(
            ov.copyWith(occurrenceId: occId, updatedAt: DateTime.now()));
        updatedOverrides += 1;
      } catch (_) {}
    }

    // 3) attendance_records occurrence_id 백필
    // override replacement 매칭(보강/추가수업 우선)
    final Map<String, String> replaceOccByReplacement = {};
    final Map<String, String> addOccByReplacement = {};
    for (final ov in _d.getSessionOverrides()) {
      final rep = ov.replacementClassDateTime;
      final occId = (ov.occurrenceId ?? '').trim();
      if (rep == null || occId.isEmpty) continue;
      final k = '${ov.studentId}|${minKey(rep)}';
      if (ov.overrideType == OverrideType.replace) {
        replaceOccByReplacement[k] = occId;
      } else if (ov.overrideType == OverrideType.add) {
        addOccByReplacement[k] = occId;
      }
    }

    final targets = _attendanceRecords.where((r) {
      final oid = (r.occurrenceId ?? '').trim();
      if (oid.isNotEmpty) return false;
      if (r.classDateTime.isBefore(fromLocal) ||
          !r.classDateTime.isBefore(toLocal)) return false;
      return true;
    }).toList();

    int updatedAttendance = 0;
    for (int i = 0; i < targets.length; i++) {
      onProgress?.call('출석 기록 백필', i, targets.length);
      final r = targets[i];
      final rid = (r.id ?? '').trim();
      if (rid.isEmpty) continue;

      String? occId;
      final keyByRep = '${r.studentId}|${minKey(r.classDateTime)}';
      occId =
          replaceOccByReplacement[keyByRep] ?? addOccByReplacement[keyByRep];

      if (occId == null || occId.isEmpty) {
        final setId = (r.setId ?? '').trim();
        if (setId.isNotEmpty) {
          occId =
              regularOccByKey[occKey(r.studentId, setId, r.classDateTime)]?.id;
        }
      }
      if ((occId == null || occId.isEmpty) &&
          r.cycle != null &&
          r.sessionOrder != null) {
        occId = regularOccByCycleOrder[
                '${r.studentId}|${r.cycle}|${r.sessionOrder}']
            ?.id;
      }

      if (occId == null || occId!.isEmpty) continue;
      try {
        await supa
            .from('attendance_records')
            .update({'occurrence_id': occId}).eq('id', rid);
        final idx = _attendanceRecords.indexWhere((x) => x.id == rid);
        if (idx != -1) {
          _attendanceRecords[idx] = _attendanceRecords[idx].copyWith(
            occurrenceId: occId,
            updatedAt: DateTime.now(),
          );
        }
        updatedAttendance += 1;
      } catch (_) {}
    }
    attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);

    onProgress?.call('완료', 1, 1);
    return (
      ensuredCycles: ensuredCycles,
      updatedOverrides: updatedOverrides,
      updatedAttendance: updatedAttendance,
      createdExtraOccurrences: createdExtraOccurrences,
    );
  }

  /// (임시 관리자 도구) attendance_records의 cycle/session_order 백필
  ///
  /// 요구사항:
  /// - 결제 사이클 내 수업을 시간순(+set_id tie-break)으로 나열한 값을 session_order로 사용
  /// - 등록일자 이전의 기록은 cycle/session_order를 null로 비운다.
  ///
  /// 주의:
  /// - 대량 업데이트로 인해 updated_at/version이 변경되며, 다른 기기/사용자와 동시 편집 시 충돌이 날 수 있다.
  Future<
      ({
        int scanned,
        int updated,
        int clearedBeforeRegistration,
      })> runCycleSessionOrderBackfillTool({
    DateTime? fromInclusive,
    DateTime? toExclusive,
    int pastDays = 365 * 2,
    int futureDays = 365,
    void Function(String phase, int done, int total)? onProgress,
  }) async {
    final String academyId =
        (await TenantService.instance.getActiveAcademyId()) ??
            await TenantService.instance.ensureActiveAcademy();
    final supa = Supabase.instance.client;

    final now = DateTime.now();
    final todayLocal = DateTime(now.year, now.month, now.day);
    final DateTime fromLocal = fromInclusive != null
        ? fromInclusive.toLocal()
        : todayLocal.subtract(Duration(days: pastDays));
    final DateTime toLocal = toExclusive != null
        ? toExclusive.toLocal()
        : todayLocal.add(Duration(days: futureDays + 1)); // ✅ toExclusive

    if (!fromLocal.isBefore(toLocal)) {
      return (scanned: 0, updated: 0, clearedBeforeRegistration: 0);
    }

    // 0) prereq loads
    try {
      await _d.loadPaymentRecords();
    } catch (_) {}

    // ✅ 이 도구는 현재 메모리에 로드된 출석만 처리하면 누락이 생길 수 있으므로,
    // 지정 범위를 먼저 서버에서 재로딩하여 "범위 내 전체"를 대상으로 처리한다.
    onProgress?.call('출석 기록 로드', 0, 1);
    await loadAttendanceRecords(fromInclusive: fromLocal, toExclusive: toLocal);

    try {
      await loadLessonOccurrences(
          fromInclusive: fromLocal, toExclusive: toLocal);
    } catch (_) {}

    // 1) registration_date map
    onProgress?.call('학생 등록일 로드', 0, 1);
    final Map<String, DateTime> registrationDateByStudent = {};
    try {
      final rows = await supa
          .from('student_payment_info')
          .select('student_id,registration_date')
          .eq('academy_id', academyId);
      if (rows is List) {
        for (final row0 in rows) {
          final m = Map<String, dynamic>.from(row0 as Map);
          final sid = (m['student_id'] ?? '').toString().trim();
          final regStr = m['registration_date']?.toString();
          if (sid.isEmpty || regStr == null || regStr.isEmpty) continue;
          final reg = DateTime.tryParse(regStr);
          if (reg == null) continue;
          final d = reg.toLocal();
          registrationDateByStudent[sid] = DateTime(d.year, d.month, d.day);
        }
      }
    } catch (e) {
      if (_sideDebug) {
        print(
            '[BACKFILL][cycle/session][WARN] registration_date 로드 실패(무시): $e');
      }
    }

    // 2) occurrence map (cycle/session_order 우선)
    final Map<String, LessonOccurrence> occById = {
      for (final o in _lessonOccurrences)
        if (o.id.isNotEmpty) o.id: o,
    };

    // 3) replace override map (replacement -> original)
    final Map<String, DateTime> originalByReplacementMinute = {};
    for (final ov in _d.getSessionOverrides()) {
      if (ov.overrideType != OverrideType.replace) continue;
      if (ov.status == OverrideStatus.canceled) continue;
      final rep = ov.replacementClassDateTime;
      final orig = ov.originalClassDateTime;
      if (rep == null || orig == null) continue;
      originalByReplacementMinute[
          '${ov.studentId}|${_minuteKey(rep.toLocal())}'] = orig.toLocal();
    }

    DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

    // 4) per-student-cycle order map cache
    final Map<String, Map<String, int>> orderMapCache = {};
    Map<String, int> orderMapOf(String studentId, int cycle) {
      final key = '$studentId|$cycle';
      return orderMapCache.putIfAbsent(
        key,
        () => _buildSessionOrderMapForStudentCycle(
          studentId: studentId,
          cycle: cycle,
          blocksOverride: _d.getStudentTimeBlocks(),
        ),
      );
    }

    // 5) targets within range
    final targets = _attendanceRecords.where((r) {
      final dt = r.classDateTime;
      return !dt.isBefore(fromLocal) && dt.isBefore(toLocal);
    }).toList();

    int updated = 0;
    int cleared = 0;

    for (int i = 0; i < targets.length; i++) {
      onProgress?.call('출석 cycle/회차 백필', i, targets.length);
      final r = targets[i];
      final rid = (r.id ?? '').trim();
      if (rid.isEmpty) continue;

      final reg = registrationDateByStudent[r.studentId];

      // replacement(보강)인 경우: cycle/session_order는 원본 시간 기준으로 계산해야 한다.
      final repKey = '${r.studentId}|${_minuteKey(r.classDateTime.toLocal())}';
      final DateTime effectiveLocalForOrder =
          originalByReplacementMinute[repKey] ?? r.classDateTime.toLocal();

      int? nextCycle;
      int? nextOrder;

      // 등록일 이전은 null 처리
      if (reg != null && dateOnly(effectiveLocalForOrder).isBefore(reg)) {
        nextCycle = null;
        nextOrder = null;
        if (r.cycle != null || r.sessionOrder != null) {
          cleared += 1;
        }
      } else {
        // ✅ 원칙: cycle/session_order는 "전체 스케줄(시간순 + set_id tie-break)" 기준으로 결정한다.
        // occurrence는 링크(원본/추가수업 구분) 용도로만 사용하며, order 값은 덮어쓰지 않는다.
        final oid = (r.occurrenceId ?? '').trim();
        final occ = (oid.isEmpty) ? null : occById[oid];
        final setId = (r.setId ?? occ?.setId ?? '').trim();

        // 1) cycle은 결제 due_date 기준(없으면 null)
        nextCycle = _resolveCycleByDueDate(r.studentId, effectiveLocalForOrder);
        // 2) session_order는 스케줄 맵에서 결정 (setId가 없으면 계산 불가)
        if (nextCycle != null && nextCycle! > 0 && setId.isNotEmpty) {
          final map = orderMapOf(r.studentId, nextCycle!);
          final k = _sessionKeyForOrder(
              setId: setId, startLocal: effectiveLocalForOrder);
          nextOrder = map[k];
        } else {
          nextOrder = null;
        }
      }

      // no change -> skip
      if (r.cycle == nextCycle && r.sessionOrder == nextOrder) {
        continue;
      }

      try {
        await supa.from('attendance_records').update({
          'cycle': nextCycle,
          'session_order': nextOrder,
        }).eq('id', rid);

        final idx = _attendanceRecords.indexWhere((x) => x.id == rid);
        if (idx != -1) {
          _attendanceRecords[idx] = _attendanceRecords[idx].copyWith(
            cycle: nextCycle,
            sessionOrder: nextOrder,
            updatedAt: DateTime.now(),
          );
        }
        updated += 1;
      } catch (e) {
        if (_sideDebug) {
          print('[BACKFILL][cycle/session][WARN] update failed id=$rid: $e');
        }
      }
    }

    attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
    onProgress?.call('완료', 1, 1);
    return (
      scanned: targets.length,
      updated: updated,
      clearedBeforeRegistration: cleared
    );
  }

  /// (경량) 특정 학생의 cycle/session_order를 "현재 스케줄" 기준으로 재계산하여 업데이트한다.
  ///
  /// - 기존 planned/출석 레코드를 삭제하지 않는다(필드만 수정).
  /// - 같은 날에 서로 다른 set_id 수업이 있는 경우에도, session_order가 꼬이지 않도록
  ///   `_buildSessionOrderMapForStudentCycle`(시간순 + set_id tie-break) 로직을 사용한다.
  ///
  /// 주의:
  /// - 이 함수는 **메모리에 로드된 출석 레코드 중** 범위에 걸치는 것만 갱신한다.
  ///   (대량/전체 백필은 `runCycleSessionOrderBackfillTool` 사용)
  Future<int> fixCycleSessionOrderForStudentInLoadedRange({
    required String studentId,
    required DateTime fromInclusive,
    required DateTime toExclusive,
  }) async {
    final sid = studentId.trim();
    if (sid.isEmpty) return 0;

    // payment_records는 cycle 계산에 필요
    try {
      await _d.loadPaymentRecords();
    } catch (_) {}

    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    final supa = Supabase.instance.client;

    // replace override: replacement(대체 수업)은 원본 시간 기준으로 cycle/session_order를 계산해야 한다.
    final Map<String, DateTime> originalByReplacementMinute = {};
    for (final ov in _d.getSessionOverrides()) {
      if (ov.studentId != sid) continue;
      if (ov.overrideType != OverrideType.replace) continue;
      if (ov.status == OverrideStatus.canceled) continue;
      final rep = ov.replacementClassDateTime;
      final orig = ov.originalClassDateTime;
      if (rep == null || orig == null) continue;
      originalByReplacementMinute['$sid|${_minuteKey(rep.toLocal())}'] =
          orig.toLocal();
    }

    final Map<String, LessonOccurrence> occById = {
      for (final o in _lessonOccurrences)
        if (o.id.trim().isNotEmpty) o.id: o,
    };

    final DateTime fromLocal = fromInclusive.toLocal();
    final DateTime toLocal = toExclusive.toLocal();
    if (!fromLocal.isBefore(toLocal)) return 0;

    // per-student-cycle order map cache
    final Map<String, Map<String, int>> orderMapCache = {};
    Map<String, int> orderMapOf(String studentId, int cycle) {
      final key = '$studentId|$cycle';
      return orderMapCache.putIfAbsent(
        key,
        () => _buildSessionOrderMapForStudentCycle(
          studentId: studentId,
          cycle: cycle,
          blocksOverride: _d.getStudentTimeBlocks(),
        ),
      );
    }

    int updated = 0;

    for (final r in _attendanceRecords) {
      if (r.studentId != sid) continue;
      final dt = r.classDateTime.toLocal();
      if (dt.isBefore(fromLocal) || !dt.isBefore(toLocal)) continue;

      final rid = (r.id ?? '').trim();
      if (rid.isEmpty) continue;

      // extra/add는 기본적으로 회차(session_order)를 비우는 정책(기존 유지)
      if (r.sessionOrder == null) {
        continue;
      }

      final oid = (r.occurrenceId ?? '').trim();
      final occ = oid.isEmpty ? null : occById[oid];
      final setId = (r.setId ?? occ?.setId ?? '').trim();
      if (setId.isEmpty) continue;

      // replacement인 경우 원본 시각으로 회차 판정
      final repKey = '$sid|${_minuteKey(dt)}';
      final DateTime effectiveLocalForOrder =
          originalByReplacementMinute[repKey] ??
              (occ?.originalClassDateTime ?? dt);

      int? nextCycle;
      int? nextOrder;

      // cycle은 결제 due_date 기준(가능한 경우)으로 계산하고, 없으면 기존 값을 유지
      nextCycle = _resolveCycleByDueDate(sid, effectiveLocalForOrder) ??
          r.cycle ??
          occ?.cycle;

      // session_order는 결제 사이클 내 "전체 수업"을 시간순(+set_id tie-break)으로 나열한 맵에서 결정
      if (nextCycle != null && nextCycle! > 0) {
        final map = orderMapOf(sid, nextCycle!);
        final k = _sessionKeyForOrder(
            setId: setId, startLocal: effectiveLocalForOrder);
        nextOrder = map[k] ?? r.sessionOrder;
      } else {
        nextOrder = r.sessionOrder;
      }

      if (r.cycle == nextCycle && r.sessionOrder == nextOrder) {
        continue;
      }

      try {
        await supa
            .from('attendance_records')
            .update({'cycle': nextCycle, 'session_order': nextOrder})
            .eq('academy_id', academyId)
            .eq('id', rid);

        final idx = _attendanceRecords.indexWhere((x) => x.id == rid);
        if (idx != -1) {
          _attendanceRecords[idx] = _attendanceRecords[idx].copyWith(
            cycle: nextCycle,
            sessionOrder: nextOrder,
            updatedAt: DateTime.now(),
          );
        }
        updated += 1;
      } catch (e) {
        if (_sideDebug) {
          // ignore: avoid_print
          print('[FIX][cycle/session][WARN] update failed id=$rid: $e');
        }
      }
    }

    if (updated > 0) {
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
    }
    return updated;
  }

  // ===== debug helpers (read-only) =====
  // NOTE: UI 디버그 출력에서만 사용. 데이터 변경 없음.

  Map<String, int> debugBuildSessionOrderMapForStudentCycle({
    required String studentId,
    required int cycle,
  }) {
    return _buildSessionOrderMapForStudentCycle(
      studentId: studentId,
      cycle: cycle,
      blocksOverride: _d.getStudentTimeBlocks(),
    );
  }

  String debugSessionKeyForOrder({
    required String setId,
    required DateTime startLocal,
  }) {
    return _sessionKeyForOrder(setId: setId, startLocal: startLocal);
  }

  int? debugResolveCycleByDueDate(String studentId, DateTime classDateLocal) {
    return _resolveCycleByDueDate(studentId, classDateLocal);
  }

  Future<void> subscribeAttendanceRealtime() async {
    try {
      _attendanceRealtimeChannel?.unsubscribe();
      final String academyId =
          (await TenantService.instance.getActiveAcademyId()) ??
              await TenantService.instance.ensureActiveAcademy();
      final chan = Supabase.instance.client
          .channel('public:attendance_records:$academyId');
      _attendanceRealtimeChannel = chan
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'attendance_records',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'academy_id',
              value: academyId),
          callback: (payload) {
            final m = payload.newRecord;
            if (m == null) return;
            try {
              final rec = AttendanceRecord(
                id: m['id'] as String?,
                studentId: m['student_id'] as String,
                classDateTime:
                    DateTime.parse(m['class_date_time'] as String).toLocal(),
                classEndTime:
                    DateTime.parse(m['class_end_time'] as String).toLocal(),
                className: (m['class_name'] as String?) ?? '',
                isPresent: (m['is_present'] is bool)
                    ? m['is_present'] as bool
                    : ((m['is_present'] is num)
                        ? (m['is_present'] as num) == 1
                        : false),
                arrivalTime: (m['arrival_time'] != null)
                    ? DateTime.parse(m['arrival_time'] as String).toLocal()
                    : null,
                departureTime: (m['departure_time'] != null)
                    ? DateTime.parse(m['departure_time'] as String).toLocal()
                    : null,
                notes: m['notes'] as String?,
                sessionTypeId: m['session_type_id'] as String?,
                setId: m['set_id'] as String?,
                snapshotId: m['snapshot_id'] as String?,
                batchSessionId: m['batch_session_id'] as String?,
                cycle: (m['cycle'] is num) ? (m['cycle'] as num).toInt() : null,
                sessionOrder: (m['session_order'] is num)
                    ? (m['session_order'] as num).toInt()
                    : null,
                isPlanned: m['is_planned'] == true || m['is_planned'] == 1,
                createdAt: DateTime.parse(m['created_at'] as String).toLocal(),
                updatedAt: DateTime.parse(m['updated_at'] as String).toLocal(),
                version:
                    (m['version'] is num) ? (m['version'] as num).toInt() : 1,
              );
              final exists = _attendanceRecords.any((r) => r.id == rec.id);
              if (!exists) {
                _attendanceRecords.add(rec);
                attendanceRecordsNotifier.value =
                    List.unmodifiable(_attendanceRecords);
              }
            } catch (_) {}
          },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'attendance_records',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'academy_id',
              value: academyId),
          callback: (payload) {
            final m = payload.newRecord;
            if (m == null) return;
            try {
              final id = m['id'] as String?;
              if (id == null) return;
              final idx = _attendanceRecords.indexWhere((r) => r.id == id);
              if (idx == -1) return;
              final updated = _attendanceRecords[idx].copyWith(
                classDateTime:
                    DateTime.parse(m['class_date_time'] as String).toLocal(),
                classEndTime:
                    DateTime.parse(m['class_end_time'] as String).toLocal(),
                className: (m['class_name'] as String?) ??
                    _attendanceRecords[idx].className,
                isPresent: (m['is_present'] is bool)
                    ? m['is_present'] as bool
                    : ((m['is_present'] is num)
                        ? (m['is_present'] as num) == 1
                        : _attendanceRecords[idx].isPresent),
                arrivalTime: (m['arrival_time'] != null)
                    ? DateTime.parse(m['arrival_time'] as String).toLocal()
                    : null,
                departureTime: (m['departure_time'] != null)
                    ? DateTime.parse(m['departure_time'] as String).toLocal()
                    : null,
                notes: m['notes'] as String?,
                sessionTypeId: m['session_type_id'] as String? ??
                    _attendanceRecords[idx].sessionTypeId,
                setId: m['set_id'] as String? ?? _attendanceRecords[idx].setId,
                occurrenceId: m['occurrence_id'] as String? ??
                    _attendanceRecords[idx].occurrenceId,
                snapshotId: m['snapshot_id'] as String? ??
                    _attendanceRecords[idx].snapshotId,
                batchSessionId: m['batch_session_id'] as String? ??
                    _attendanceRecords[idx].batchSessionId,
                cycle: (m['cycle'] is num)
                    ? (m['cycle'] as num).toInt()
                    : _attendanceRecords[idx].cycle,
                sessionOrder: (m['session_order'] is num)
                    ? (m['session_order'] as num).toInt()
                    : _attendanceRecords[idx].sessionOrder,
                isPlanned: m['is_planned'] == true ||
                    m['is_planned'] == 1 ||
                    _attendanceRecords[idx].isPlanned,
                updatedAt: DateTime.parse(m['updated_at'] as String).toLocal(),
                version: (m['version'] is num)
                    ? (m['version'] as num).toInt()
                    : _attendanceRecords[idx].version,
              );
              _attendanceRecords[idx] = updated;
              attendanceRecordsNotifier.value =
                  List.unmodifiable(_attendanceRecords);
            } catch (_) {}
          },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'attendance_records',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'academy_id',
              value: academyId),
          callback: (payload) {
            final m = payload.oldRecord;
            if (m == null) return;
            try {
              final id = m['id'] as String?;
              if (id == null) return;
              _attendanceRecords.removeWhere((r) => r.id == id);
              attendanceRecordsNotifier.value =
                  List.unmodifiable(_attendanceRecords);
            } catch (_) {}
          },
        )
        ..subscribe();
    } catch (_) {}
  }

  Future<void> addAttendanceRecord(AttendanceRecord record) async {
    final String academyId =
        (await TenantService.instance.getActiveAcademyId()) ??
            await TenantService.instance.ensureActiveAcademy();
    final supa = Supabase.instance.client;
    final classDtUtc = _utcMinute(record.classDateTime);
    final bool effectivePresent =
        record.isPresent || record.arrivalTime != null || record.departureTime != null;
    final row = {
      'id': record.id,
      'academy_id': academyId,
      'student_id': record.studentId,
      'occurrence_id': record.occurrenceId,
      // ✅ 서버는 UTC minute boundary로 정규화하므로, 클라이언트도 분 단위로 정규화해 전송한다.
      'class_date_time': classDtUtc.toIso8601String(),
      'class_end_time': record.classEndTime.toUtc().toIso8601String(),
      'class_name': record.className,
      // 정합성: 시간 기록이 있으면 출석으로 저장
      'is_present': effectivePresent,
      'arrival_time': record.arrivalTime?.toUtc().toIso8601String(),
      'departure_time': record.departureTime?.toUtc().toIso8601String(),
      'notes': record.notes,
      'session_type_id': record.sessionTypeId,
      'set_id': record.setId,
      'snapshot_id': record.snapshotId,
      'batch_session_id': record.batchSessionId,
      'cycle': record.cycle,
      'session_order': record.sessionOrder,
      'is_planned': record.isPlanned,
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'updated_at': record.updatedAt.toUtc().toIso8601String(),
      'version': record.version,
    };
    try {
      final inserted = await supa
          .from('attendance_records')
          .insert(row)
          .select('id,version')
          .maybeSingle();
      if (inserted != null) {
        final withId = record.copyWith(
            id: (inserted['id'] as String?),
            version: (inserted['version'] as num?)?.toInt() ?? 1);
        _attendanceRecords.add(withId);
      } else {
        _attendanceRecords.add(record);
      }
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      return;
    } on PostgrestException catch (e) {
      // ✅ 유니크 인덱스(academy_id, student_id, class_date_time) 충돌 시:
      // 이미 존재하는 레코드를 찾아 "업데이트"로 전환한다.
      if (e.code != '23505') rethrow;

      const selectCols =
          'id,student_id,occurrence_id,class_date_time,class_end_time,class_name,is_present,arrival_time,departure_time,notes,session_type_id,set_id,cycle,session_order,is_planned,snapshot_id,batch_session_id,created_at,updated_at,version';
      final existing = await supa
          .from('attendance_records')
          .select(selectCols)
          .eq('academy_id', academyId)
          .eq('student_id', record.studentId)
          .eq('class_date_time', classDtUtc.toIso8601String())
          .maybeSingle();
      if (existing == null) rethrow;

      DateTime parseTs(String k) =>
          DateTime.parse(existing[k] as String).toLocal();
      DateTime? parseTsOpt(String k) {
        final v = existing[k] as String?;
        if (v == null || v.isEmpty) return null;
        return DateTime.parse(v).toLocal();
      }

      final dynamic isPresentDyn = existing['is_present'];
      final bool existingPresent = (isPresentDyn is bool)
          ? isPresentDyn
          : ((isPresentDyn is num) ? isPresentDyn == 1 : false);
      final bool existingPlanned =
          existing['is_planned'] == true || existing['is_planned'] == 1;
      final AttendanceRecord existingRec = AttendanceRecord(
        id: existing['id'] as String?,
        studentId: existing['student_id'] as String,
        occurrenceId: existing['occurrence_id']?.toString(),
        classDateTime: parseTs('class_date_time'),
        classEndTime: parseTs('class_end_time'),
        className: (existing['class_name'] as String?) ?? '',
        isPresent: existingPresent,
        arrivalTime: parseTsOpt('arrival_time'),
        departureTime: parseTsOpt('departure_time'),
        notes: existing['notes'] as String?,
        sessionTypeId: existing['session_type_id'] as String?,
        setId: existing['set_id'] as String?,
        snapshotId: existing['snapshot_id'] as String?,
        batchSessionId: existing['batch_session_id'] as String?,
        cycle: (existing['cycle'] is num)
            ? (existing['cycle'] as num).toInt()
            : null,
        sessionOrder: (existing['session_order'] is num)
            ? (existing['session_order'] as num).toInt()
            : null,
        isPlanned: existingPlanned,
        createdAt: parseTs('created_at'),
        updatedAt: parseTs('updated_at'),
        version: (existing['version'] is num)
            ? (existing['version'] as num).toInt()
            : 1,
      );

      // ensure in-memory (so updateAttendanceRecord updates notifier immediately)
      if (existingRec.id != null &&
          !_attendanceRecords.any((r) => r.id == existingRec.id)) {
        _attendanceRecords.add(existingRec);
      }

      DateTime? mergedArrival = existingRec.arrivalTime;
      if (record.arrivalTime != null) {
        mergedArrival = (mergedArrival == null ||
                record.arrivalTime!.isBefore(mergedArrival))
            ? record.arrivalTime
            : mergedArrival;
      }
      DateTime? mergedDeparture = existingRec.departureTime;
      if (record.departureTime != null) {
        mergedDeparture = (mergedDeparture == null ||
                record.departureTime!.isAfter(mergedDeparture))
            ? record.departureTime
            : mergedDeparture;
      }
      bool mergedPresent = existingRec.isPresent ||
          record.isPresent ||
          mergedArrival != null ||
          mergedDeparture != null;
      if (mergedArrival != null) mergedPresent = true;
      final DateTime mergedEnd =
          record.classEndTime.isAfter(existingRec.classEndTime)
              ? record.classEndTime
              : existingRec.classEndTime;
      final String mergedClassName = existingRec.className.trim().isEmpty &&
              record.className.trim().isNotEmpty
          ? record.className
          : existingRec.className;

      final merged = existingRec.copyWith(
        classEndTime: mergedEnd,
        className: mergedClassName,
        isPresent: mergedPresent,
        arrivalTime: mergedArrival,
        departureTime: mergedDeparture,
        notes: existingRec.notes ?? record.notes,
        sessionTypeId: existingRec.sessionTypeId ?? record.sessionTypeId,
        setId: existingRec.setId ?? record.setId,
        occurrenceId: existingRec.occurrenceId ?? record.occurrenceId,
        cycle: existingRec.cycle ?? record.cycle,
        sessionOrder: existingRec.sessionOrder ?? record.sessionOrder,
        isPlanned: existingRec.isPlanned || record.isPlanned,
        snapshotId: existingRec.snapshotId ?? record.snapshotId,
        batchSessionId: existingRec.batchSessionId ?? record.batchSessionId,
        updatedAt: DateTime.now(),
      );

      try {
        await updateAttendanceRecord(merged);
      } on StateError catch (e2) {
        if (e2.message != 'CONFLICT_ATTENDANCE_VERSION') rethrow;
        final cur = await supa
            .from('attendance_records')
            .select('version')
            .eq('id', merged.id!)
            .limit(1)
            .maybeSingle();
        final curVersion = (cur?['version'] as num?)?.toInt() ?? merged.version;
        await updateAttendanceRecord(merged.copyWith(version: curVersion));
      }
    }
  }

  Future<void> updateAttendanceRecord(AttendanceRecord record) async {
    final supa = Supabase.instance.client;
    if (record.id != null) {
      final bool effectivePresent =
          record.isPresent || record.arrivalTime != null || record.departureTime != null;
      final row = {
        'student_id': record.studentId,
        'occurrence_id': record.occurrenceId,
        'class_date_time': _utcMinute(record.classDateTime).toIso8601String(),
        'class_end_time': record.classEndTime.toUtc().toIso8601String(),
        'class_name': record.className,
        // 정합성: 시간 기록이 있으면 출석으로 저장
        'is_present': effectivePresent,
        'arrival_time': record.arrivalTime?.toUtc().toIso8601String(),
        'departure_time': record.departureTime?.toUtc().toIso8601String(),
        'notes': record.notes,
        'session_type_id': record.sessionTypeId,
        'set_id': record.setId,
        'snapshot_id': record.snapshotId,
        'batch_session_id': record.batchSessionId,
        'cycle': record.cycle,
        'session_order': record.sessionOrder,
        'is_planned': record.isPlanned,
        'updated_at': record.updatedAt.toUtc().toIso8601String(),
      };
      final updated = await supa
          .from('attendance_records')
          .update(row)
          .eq('id', record.id!)
          .eq('version', record.version)
          .select('id,version')
          .maybeSingle();
      if (updated == null) {
        throw StateError('CONFLICT_ATTENDANCE_VERSION');
      }
      final index = _attendanceRecords.indexWhere((r) => r.id == record.id);
      if (index != -1) {
        final newVersion =
            (updated['version'] as num?)?.toInt() ?? (record.version + 1);
        _attendanceRecords[index] = record.copyWith(version: newVersion);
        attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      }
      return;
    }

    final String academyId =
        (await TenantService.instance.getActiveAcademyId()) ??
            await TenantService.instance.ensureActiveAcademy();
    final keyFilter = supa
        .from('attendance_records')
        .select('id')
        .eq('academy_id', academyId)
        .eq('student_id', record.studentId)
        .eq('class_date_time',
            _utcMinute(record.classDateTime).toIso8601String())
        .limit(1);
    final found = await keyFilter;
    if (found is List && found.isNotEmpty && found.first['id'] is String) {
      final id = found.first['id'] as String;
      final current = await supa
          .from('attendance_records')
          .select('version')
          .eq('id', id)
          .limit(1)
          .maybeSingle();
      final curVersion = (current?['version'] as num?)?.toInt() ?? 1;
      final updated = record.copyWith(id: id, version: curVersion);
      await updateAttendanceRecord(updated);
    } else {
      await addAttendanceRecord(record);
    }
  }

  Future<void> deleteAttendanceRecord(String id) async {
    try {
      final supa = Supabase.instance.client;
      await supa.from('attendance_records').delete().eq('id', id);
    } catch (_) {}
    _attendanceRecords.removeWhere((r) => r.id == id);
    attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
  }

  List<AttendanceRecord> getAttendanceRecordsForStudent(String studentId) {
    return _attendanceRecords.where((r) => r.studentId == studentId).toList();
  }

  /// (데이터 정합성 백필) 등/하원 시간이 기록되어 있는데 `is_present=false`로 남아있는 행을
  /// `is_present=true`로 보정한다.
  ///
  /// - 증상: 결제/요약 UI 등에서 `isPresent` 기반으로 결석으로 표시될 수 있음
  /// - 원인: 일부 업데이트 경로에서 arrival/departure만 저장하고 isPresent를 올리지 않음(legacy/충돌/동기화 등)
  ///
  /// 안전장치:
  /// - academy 단위로 1회만 수행(SharedPreferences 플래그)
  Future<int> backfillIsPresentFromTimesOnce({bool force = false}) async {
    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    final prefs = await SharedPreferences.getInstance();
    final key = 'backfill_is_present_from_times_v1:$academyId';
    if (!force && (prefs.getBool(key) ?? false)) {
      return 0;
    }

    final supa = Supabase.instance.client;
    int totalUpdated = 0;
    final nowUtc = DateTime.now().toUtc().toIso8601String();

    // PostgREST에서 OR 조건은 `.or()`로 처리한다.
    // 반복/청크 방식: id를 제한(limit)해서 가져오고, 그 id들만 update한다.
    while (true) {
      final rows = await supa
          .from('attendance_records')
          .select('id')
          .eq('academy_id', academyId)
          .eq('is_present', false)
          .or('arrival_time.not.is.null,departure_time.not.is.null')
          .limit(500);

      final list = (rows is List)
          ? rows.cast<Map<String, dynamic>>()
          : const <Map<String, dynamic>>[];
      if (list.isEmpty) break;

      final ids = <String>[];
      for (final r in list) {
        final id = (r['id'] as String?) ?? '';
        if (id.isNotEmpty) ids.add(id);
      }
      if (ids.isEmpty) break;

      await supa
          .from('attendance_records')
          .update({'is_present': true, 'updated_at': nowUtc})
          .eq('academy_id', academyId)
          .inFilter('id', ids);

      // 메모리(캐시)도 함께 보정해서 UI 즉시 반영
      for (final id in ids) {
        final idx = _attendanceRecords.indexWhere((x) => x.id == id);
        if (idx == -1) continue;
        final cur = _attendanceRecords[idx];
        if (cur.isPresent) continue;
        _attendanceRecords[idx] = cur.copyWith(
          isPresent: true,
          updatedAt: DateTime.now(),
        );
      }

      totalUpdated += ids.length;
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
    }

    await prefs.setBool(key, true);
    return totalUpdated;
  }

  Future<Map<String, String>> _createBatchSessionsForPlanned({
    required String studentId,
    required List<AttendanceRecord> plannedRecords,
    String? snapshotId,
  }) async {
    if (plannedRecords.isEmpty) return {};
    // ✅ snapshot 기반 planned 재생성에서만 batch tables를 사용한다.
    // - snapshotId == null 인 전역 planned 생성기는 누락 보강 목적이며,
    //   여기서 batch headers/sessions를 만들면 (중복/폭증 시) 테이블이 빠르게 커지고 삭제/조회에 장애가 발생한다.
    // - 현재 중복 폭증의 거의 전부가 snapshotId == null 경로에서 발생한 것이 DB에서 확인됨.
    if (snapshotId == null) return {};
    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    plannedRecords.sort((a, b) => a.classDateTime.compareTo(b.classDateTime));
    final headerId = const Uuid().v4();
    final headerRow = {
      'id': headerId,
      'academy_id': academyId,
      'student_id': studentId,
      'snapshot_id': snapshotId,
      'total_sessions': plannedRecords.length,
      'expected_sessions': plannedRecords.length,
      'consumed_sessions': 0,
      'status': 'active',
    };
    final Map<String, String> mapping = {};
    final List<Map<String, dynamic>> sessionRows = [];
    for (var i = 0; i < plannedRecords.length; i++) {
      final rec = plannedRecords[i];
      final sessionId = const Uuid().v4();
      mapping[rec.id ?? sessionId] = sessionId;
      sessionRows.add({
        'id': sessionId,
        'batch_id': headerId,
        'student_id': studentId,
        'session_no': i + 1,
        'planned_at': rec.classDateTime.toUtc().toIso8601String(),
        'state': 'planned',
        'snapshot_id': snapshotId,
        'set_id': rec.setId,
        'session_type_id': rec.sessionTypeId,
      });
    }
    try {
      final supa = Supabase.instance.client;
      await supa.from('lesson_batch_headers').insert(headerRow);
      if (sessionRows.isNotEmpty) {
        await supa.from('lesson_batch_sessions').insert(sessionRows);
      }
    } catch (e, st) {
      print('[BATCH][ERROR] 배치 세션 생성 실패(student=$studentId): $e\n$st');
      return {};
    }
    return mapping;
  }

  AttendanceRecord? getAttendanceRecord(
      String studentId, DateTime classDateTime) {
    final matches = _attendanceRecords.where(
      (r) =>
          r.studentId == studentId &&
          r.classDateTime.year == classDateTime.year &&
          r.classDateTime.month == classDateTime.month &&
          r.classDateTime.day == classDateTime.day &&
          r.classDateTime.hour == classDateTime.hour &&
          r.classDateTime.minute == classDateTime.minute,
    );
    if (matches.isEmpty) return null;

    // 우선순위: 실제 등원/하원 기록 있는 항목 > 실출석 표시 > 나머지
    final withAttendance = matches.firstWhere(
      (r) => r.arrivalTime != null || r.departureTime != null || r.isPresent,
      orElse: () => matches.first,
    );
    return withAttendance;
  }

  Future<void> _updateBatchSessionState({
    required String batchSessionId,
    required String state,
    String? attendanceId,
  }) async {
    try {
      final supa = Supabase.instance.client;
      // 현재 세션과 배치 정보 조회
      final session = await supa
          .from('lesson_batch_sessions')
          .select('id,batch_id,state,planned_at')
          .eq('id', batchSessionId)
          .maybeSingle();
      if (session == null) return;
      final String batchId = session['batch_id'] as String;
      final String prevState = session['state'] as String? ?? 'planned';
      final bool wasConsumed = prevState == 'completed' ||
          prevState == 'no_show' ||
          prevState == 'replaced';

      await supa.from('lesson_batch_sessions').update({
        'state': state,
        'attendance_id': attendanceId,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', batchSessionId);

      final bool nowConsumed =
          state == 'completed' || state == 'no_show' || state == 'replaced';
      if (!wasConsumed && nowConsumed) {
        // 소비 카운트 및 next_registration_date 갱신
        final header = await supa
            .from('lesson_batch_headers')
            .select('consumed_sessions,term_days')
            .eq('id', batchId)
            .maybeSingle();
        if (header != null) {
          final int consumed = (header['consumed_sessions'] as int?) ?? 0;
          final int? termDays = (header['term_days'] as int?);
          DateTime? nextReg;
          if (termDays != null && termDays > 0) {
            final maxPlanned = await supa
                .from('lesson_batch_sessions')
                .select('planned_at')
                .eq('batch_id', batchId)
                .order('planned_at', ascending: false)
                .limit(1)
                .maybeSingle();
            if (maxPlanned != null && maxPlanned['planned_at'] != null) {
              final String maxPlanStr = maxPlanned['planned_at'] as String;
              final DateTime maxPlan = DateTime.tryParse(maxPlanStr)?.toUtc() ??
                  DateTime.now().toUtc();
              nextReg = maxPlan.add(Duration(days: termDays));
            }
          }
          await supa.from('lesson_batch_headers').update({
            'consumed_sessions': consumed + 1,
            if (nextReg != null)
              'next_registration_date':
                  nextReg.toIso8601String().split('T').first,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }).eq('id', batchId);
        }
      }
    } catch (e, st) {
      print('[BATCH][WARN] 세션 상태 업데이트 실패(id=$batchSessionId): $e\n$st');
    }
  }

  Future<void> _cancelPlannedForSets({
    required String studentId,
    required Set<String> setIds,
    DateTime? anchor,
  }) async {
    final DateTime dateAnchor = anchor ?? DateTime.now().toUtc();
    final supa = Supabase.instance.client;
    if (_sideDebug) {
      final before = _attendanceRecords.length;
      int willRemove = 0;
      DateTime? minDt;
      DateTime? maxDt;
      final nowL = DateTime.now();
      final todayL = DateTime(nowL.year, nowL.month, nowL.day);
      bool touchesToday = false;
      for (final r in _attendanceRecords) {
        if (!r.isPlanned) continue;
        if (r.isPresent || r.arrivalTime != null) continue;
        if (r.setId == null || !setIds.contains(r.setId)) continue;
        if (r.classDateTime.toUtc().isBefore(dateAnchor)) continue;
        willRemove++;
        final dt = r.classDateTime;
        if (minDt == null || dt.isBefore(minDt)) minDt = dt;
        if (maxDt == null || dt.isAfter(maxDt)) maxDt = dt;
        final dOnly = DateTime(dt.year, dt.month, dt.day);
        if (dOnly == todayL) touchesToday = true;
      }
      print(
        '[PLAN][cancel-start] student=$studentId sets=${setIds.length} anchorUtc=$dateAnchor localBefore=$before localWillRemove=$willRemove touchesToday=$touchesToday min=${minDt?.toIso8601String()} max=${maxDt?.toIso8601String()}',
      );
    }
    try {
      await supa
          .from('attendance_records')
          .delete()
          .eq('student_id', studentId)
          .eq('is_planned', true)
          .eq('is_present', false)
          .isFilter('arrival_time', null)
          .inFilter('set_id', setIds.toList())
          .gte('class_date_time', dateAnchor.toIso8601String());
    } catch (e, st) {
      if (_sideDebug) {
        // ignore: avoid_print
        print(
            '[PLAN][WARN] planned 삭제 실패(student=$studentId sets=$setIds): $e\n$st');
      }
    }
    final beforeLocal = _attendanceRecords.length;
    _attendanceRecords.removeWhere((r) {
      if (!r.isPlanned) return false;
      if (r.isPresent || r.arrivalTime != null) return false;
      if (r.setId == null || !setIds.contains(r.setId)) return false;
      return !r.classDateTime.toUtc().isBefore(dateAnchor);
    });
    attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
    if (_sideDebug) {
      final afterLocal = _attendanceRecords.length;
      print(
          '[PLAN][cancel-done] student=$studentId removed=${beforeLocal - afterLocal} localAfter=$afterLocal');
    }

    // 배치 세션: planned 상태인 동일 세트의 미래 세션 삭제
    try {
      await supa
          .from('lesson_batch_sessions')
          .delete()
          .eq('student_id', studentId)
          .eq('state', 'planned')
          .inFilter('set_id', setIds.toList())
          .gte('planned_at', dateAnchor.toIso8601String());
    } catch (e, st) {
      print(
          '[BATCH][WARN] planned 세션 삭제 실패(student=$studentId sets=$setIds): $e\n$st');
    }
  }

  Future<void> replanRemainingForStudentSets({
    required String studentId,
    required Set<String> setIds,
    int days = 15,
    DateTime? anchor,
    String? snapshotId,
    List<StudentTimeBlock>? blocksOverride,
  }) async {
    final DateTime effectiveAnchor = anchor ?? DateTime.now().toUtc();
    await _cancelPlannedForSets(
        studentId: studentId, setIds: setIds, anchor: effectiveAnchor);
    await regeneratePlannedAttendanceForStudentSets(
      studentId: studentId,
      setIds: setIds,
      days: days,
      snapshotId: snapshotId,
      blocksOverride: blocksOverride,
    );
  }

  /// "순수 planned" 출석 레코드(=예정 수업)만 일괄 삭제한다.
  ///
  /// ✅ 안전장치:
  /// - `is_planned=true`
  /// - `is_present=false`
  /// - `arrival_time IS NULL`
  ///
  /// 즉, 실제 출석/등원 기록이 들어간 행은 삭제하지 않는다.
  Future<void> purgePurePlannedAttendance({
    String? studentId,
    Set<String>? setIds,
  }) async {
    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    final supa = Supabase.instance.client;
    final sid = studentId?.trim();
    final sets =
        setIds?.where((e) => e.trim().isNotEmpty).map((e) => e.trim()).toSet();

    bool match(AttendanceRecord r) {
      if (!r.isPlanned) return false;
      if (r.isPresent) return false;
      if (r.arrivalTime != null) return false;
      if (sid != null && sid.isNotEmpty && r.studentId != sid) return false;
      if (sets != null && sets.isNotEmpty) {
        final s = r.setId;
        if (s == null || s.isEmpty) return false;
        if (!sets.contains(s)) return false;
      }
      return true;
    }

    final beforeLocal = _attendanceRecords.length;
    final willRemove = _attendanceRecords.where(match).length;
    if (_sideDebug) {
      // ignore: avoid_print
      print(
          '[PLAN][purge] start academy=$academyId student=${sid ?? "ALL"} sets=${sets?.length ?? 0} localWillRemove=$willRemove localBefore=$beforeLocal');
    }

    try {
      var q = supa
          .from('attendance_records')
          .delete()
          .eq('academy_id', academyId)
          .eq('is_planned', true)
          .eq('is_present', false)
          .isFilter('arrival_time', null);
      if (sid != null && sid.isNotEmpty) {
        q = q.eq('student_id', sid);
      }
      if (sets != null && sets.isNotEmpty) {
        q = q.inFilter('set_id', sets.toList());
      }
      await q;
    } catch (e, st) {
      print('[PLAN][purge][ERROR] attendance_records delete failed: $e\n$st');
      rethrow;
    }

    _attendanceRecords.removeWhere(match);
    attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
    final afterLocal = _attendanceRecords.length;
    if (_sideDebug) {
      // ignore: avoid_print
      print(
          '[PLAN][purge] done removed=${beforeLocal - afterLocal} localAfter=$afterLocal');
    }
  }

  /// snapshot 기반 planned가 생성한 batch 세션 중 "planned 상태"만 일괄 삭제한다.
  ///
  /// - snapshotId == null 경로(전역 planned 보강)는 원래 batch를 만들지 않기 때문에,
  ///   이 함수는 주로 "재생성/초기화" 시 정리 용도로 사용한다.
  Future<void> purgePlannedBatchSessions({
    String? studentId,
    Set<String>? setIds,
  }) async {
    final supa = Supabase.instance.client;
    final sid = studentId?.trim();
    final sets =
        setIds?.where((e) => e.trim().isNotEmpty).map((e) => e.trim()).toSet();

    try {
      var q =
          supa.from('lesson_batch_sessions').delete().eq('state', 'planned');
      if (sid != null && sid.isNotEmpty) {
        q = q.eq('student_id', sid);
      }
      if (sets != null && sets.isNotEmpty) {
        q = q.inFilter('set_id', sets.toList());
      }
      await q;
      print(
          '[BATCH][purge] planned sessions deleted student=${sid ?? "ALL"} sets=${sets?.length ?? 0}');
    } catch (e, st) {
      print(
          '[BATCH][purge][WARN] planned sessions delete failed student=${sid ?? "ALL"}: $e\n$st');
    }
  }

  String _resolveClassName(String? sessionTypeId) {
    final classes = _d.getClasses();
    if (sessionTypeId == null) return '수업';
    try {
      final cls = classes.firstWhere((c) => c.id == sessionTypeId);
      if (cls.name.trim().isNotEmpty) return cls.name;
    } catch (_) {}
    return '수업';
  }

  bool _isBlockActiveOnDate(StudentTimeBlock block, DateTime date) {
    final target = DateTime(date.year, date.month, date.day);
    final start = DateTime(
        block.startDate.year, block.startDate.month, block.startDate.day);
    final end = block.endDate != null
        ? DateTime(
            block.endDate!.year, block.endDate!.month, block.endDate!.day)
        : null;
    return !start.isAfter(target) && (end == null || !end.isBefore(target));
  }

  Future<void> generatePlannedAttendanceForNextDays({int days = 15}) async {
    final blocks = _d
        .getStudentTimeBlocks()
        .where((b) => b.setId != null && b.setId!.isNotEmpty)
        .toList();
    if (blocks.isEmpty) return;

    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    final now = DateTime.now();
    final anchor = DateTime(now.year, now.month, now.day);
    final supa = Supabase.instance.client;

    // ✅ planned 생성 범위(오늘~N일) 밖에 남아있는 "순수 planned"는 정리한다.
    // - planned는 자동 생성 데이터이므로, 달력/리스트에서 혼동을 줄이기 위해
    //   '오늘 기준 days' 범위를 초과하는 항목은 삭제(재생성 가능).
    // - 실제 출석/등원 기록이 있는 행(is_present=true 또는 arrival_time!=null)은 절대 삭제하지 않는다.
    // - set_id 단위 regen이 아닌 전역 생성기에서도 "상한 정리"만 수행한다.

    try {
      await _d.loadPaymentRecords();
    } catch (_) {}

    String minKey(DateTime dt) =>
        '${dt.year}-${dt.month}-${dt.day}-${dt.hour}-${dt.minute}';

    bool isPausedDay(String studentId, DateTime dayLocal) =>
        _isStudentPausedOn(studentId, dayLocal);

    // ===== SessionOverride 반영 =====
    // - skip/replace(원래 회차): planned/completed 모두 해당 분(minute)에 planned 생성 제외
    // - add/replace(대체/추가 회차): planned 상태만 replacement 분(minute)에 planned 생성 추가
    final Map<String, SessionOverride> overrideByOriginalKey = {};
    final Map<String, List<SessionOverride>> overridesByReplacementDate = {};
    for (final o in _d.getSessionOverrides()) {
      if (o.status == OverrideStatus.canceled) continue;
      final orig = o.originalClassDateTime;
      if ((o.overrideType == OverrideType.skip ||
              o.overrideType == OverrideType.replace) &&
          orig != null) {
        overrideByOriginalKey['${o.studentId}|${minKey(orig)}'] = o;
      }
      if (o.status != OverrideStatus.planned) continue;
      final rep = o.replacementClassDateTime;
      if ((o.overrideType == OverrideType.add ||
              o.overrideType == OverrideType.replace) &&
          rep != null) {
        overridesByReplacementDate
            .putIfAbsent(_dateKey(rep), () => <SessionOverride>[])
            .add(o);
      }
    }

    // ===== lesson_occurrences (원본 회차) 보장/맵 =====
    // - regular occurrence가 있으면 cycle/session_order/원본시간을 고정값으로 사용할 수 있다.
    // - 없으면(마이그레이션 전 등) 기존 cycle/sessionOrder 계산 로직으로 fallback한다.
    final DateTime rangeEnd = anchor.add(Duration(days: days));

    // 0) 과도하게 누적된 미래 planned(순수 예정) 정리: class_date_time >= rangeEnd
    try {
      await supa
          .from('attendance_records')
          .delete()
          .eq('academy_id', academyId)
          .eq('is_planned', true)
          // ⚠️ 순수 planned(출석/등원 기록 없는 것)만 삭제
          .eq('is_present', false)
          .isFilter('arrival_time', null)
          .gte('class_date_time', rangeEnd.toUtc().toIso8601String());

      _attendanceRecords.removeWhere((r) {
        if (r.isPlanned != true) return false;
        if (r.isPresent) return false;
        if (r.arrivalTime != null) return false;
        return !r.classDateTime.isBefore(rangeEnd);
      });
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
    } catch (e, st) {
      // 누락분 생성은 계속 진행되도록 warn만 남김
      print('[PLAN][cap][WARN] future planned cleanup failed: $e\n$st');
    }
    final Set<String> studentIds = <String>{
      for (final b in blocks) b.studentId,
    };
    for (final o in _d.getSessionOverrides()) {
      if (o.status != OverrideStatus.planned) continue;
      final rep = o.replacementClassDateTime;
      if (rep == null) continue;
      // 이번 planned 생성 범위 내 replacement가 있으면 해당 학생도 포함
      if (!rep.isBefore(anchor) && rep.isBefore(rangeEnd)) {
        studentIds.add(o.studentId);
      }
    }

    final Map<String, Set<int>> cyclesByStudent = {};
    for (final sid in studentIds) {
      final c1 = _resolveCycleByDueDate(sid, anchor);
      final c2 = _resolveCycleByDueDate(sid, rangeEnd);
      if (c1 != null) cyclesByStudent.putIfAbsent(sid, () => <int>{}).add(c1);
      if (c2 != null) cyclesByStudent.putIfAbsent(sid, () => <int>{}).add(c2);
    }
    // replace 오버라이드의 원본 cycle도 포함(원본이 과거 cycle일 수 있음)
    for (final o in _d.getSessionOverrides()) {
      if (o.status != OverrideStatus.planned) continue;
      if (o.overrideType != OverrideType.replace) continue;
      final orig = o.originalClassDateTime;
      if (orig == null) continue;
      final c0 = _resolveCycleByDueDate(o.studentId, orig);
      if (c0 != null)
        cyclesByStudent.putIfAbsent(o.studentId, () => <int>{}).add(c0);
    }

    // regular occurrences ensure(없으면 생성)
    try {
      for (final e in cyclesByStudent.entries) {
        final sid = e.key;
        for (final c in e.value) {
          final has = _lessonOccurrences.any(
              (o) => o.studentId == sid && o.kind == 'regular' && o.cycle == c);
          if (has) continue;
          await _ensureRegularLessonOccurrencesForStudentCycle(
            academyId: academyId,
            studentId: sid,
            cycle: c,
          );
        }
      }
    } catch (_) {
      // 테이블 미존재/권한 등: fallback
    }

    // lookup: student|setId|yyyy-mm-dd-hh-mm (original)
    String occKey(String studentId, String setId, DateTime originalLocal) =>
        '$studentId|$setId|${minKey(originalLocal)}';
    final Map<String, LessonOccurrence> regularOccByKey = {};
    for (final o in _lessonOccurrences) {
      if (o.kind != 'regular') continue;
      if (!studentIds.contains(o.studentId)) continue;
      final sid = (o.setId ?? '').trim();
      if (sid.isEmpty) continue;
      regularOccByKey[occKey(o.studentId, sid, o.originalClassDateTime)] = o;
    }

    // ===== planned 생성(휴원일 스킵) =====
    // 실제 레코드 insert 로직은 아래에서 수행되며,
    // 휴원 기간에 속한 날짜는 planned 후보에서 제외한다.
    final Map<String, LessonOccurrence> extraOccByKey = {};
    for (final o in _lessonOccurrences) {
      if (o.kind != 'extra') continue;
      if (!studentIds.contains(o.studentId)) continue;
      final sid = (o.setId ?? '').trim();
      if (sid.isEmpty) continue;
      extraOccByKey[occKey(o.studentId, sid, o.originalClassDateTime)] = o;
    }

    final List<Map<String, dynamic>> rows = [];
    final List<AttendanceRecord> localAdds = [];

    final Map<String, DateTime> earliestMonthByKey = {};
    final Map<String, int> monthCountByKey = {};
    _seedCycleMaps(earliestMonthByKey, monthCountByKey);
    // ✅ 회차(session_order)는 "결제 사이클 내 수업을 시간순(+set_id tie-break)"으로 정렬한 값이어야 한다.
    // 기존(dateKey=yyyy-mm-dd) 기반 계산은 "같은 날 다른 set_id 수업"을 1개로 합쳐버려 회차가 깨질 수 있음.
    final Map<String, Map<String, int>> orderMapCache = {};
    Map<String, int> orderMapOf(String studentId, int cycle) {
      final key = '$studentId|$cycle';
      return orderMapCache.putIfAbsent(
        key,
        () => _buildSessionOrderMapForStudentCycle(
          studentId: studentId,
          cycle: cycle,
          // cycle 전체 순서를 계산할 때는 "전체 블록"이 필요
          blocksOverride: _d.getStudentTimeBlocks(),
        ),
      );
    }

    final Map<String, Map<String, int>> fallbackOrderByStudentCycle = {};
    final Map<String, int> fallbackCounterByStudentCycle = {};
    int fallbackOrder({
      required String studentId,
      required int cycle,
      required String setId,
      required DateTime startLocal,
    }) {
      final studentCycleKey = '$studentId|$cycle';
      final m =
          fallbackOrderByStudentCycle.putIfAbsent(studentCycleKey, () => {});
      final k = _sessionKeyForOrder(setId: setId, startLocal: startLocal);
      final existing = m[k];
      if (existing != null && existing > 0) return existing;

      // orderMap이 부분적으로라도 있으면, 그 최대값 이후로만 fallback을 부여해 충돌을 피한다.
      int base = fallbackCounterByStudentCycle[studentCycleKey] ?? 0;
      if (base <= 0) {
        final om = orderMapOf(studentId, cycle);
        for (final v in om.values) {
          if (v > base) base = v;
        }
      }
      final next = base + 1;
      fallbackCounterByStudentCycle[studentCycleKey] = next;
      m[k] = next;
      return next;
    }

    // 기존 planned 중복 방지 키:
    // ⚠️ _attendanceRecords는 Supabase(PostgREST) max_rows 설정에 의해 ~1000개로 잘릴 수 있어(실제 로그: recordsLen≈990),
    //     이 메모리 기반 체크만으로는 중복 생성 방지가 불완전해질 수 있다.
    // ✅ DB에서 DISTINCT로 키를 가져와 중복 폭증을 방지한다.
    final Set<String> existingPlannedKeys = {};
    try {
      final fromUtc = anchor.toUtc();
      final toUtc = anchor.add(Duration(days: days)).toUtc();
      final data = await supa.rpc('list_planned_attendance_minutes', params: {
        'p_academy_id': academyId,
        'p_from': fromUtc.toIso8601String(),
        'p_to': toUtc.toIso8601String(),
      });
      if (data is List) {
        for (final row in data) {
          final m = Map<String, dynamic>.from(row as Map);
          final sid = m['student_id']?.toString();
          final setId = m['set_id']?.toString();
          final minuteStr = m['class_minute']?.toString();
          if (sid == null || sid.isEmpty) continue;
          if (setId == null || setId.isEmpty) continue;
          if (minuteStr == null || minuteStr.isEmpty) continue;
          final dt = DateTime.tryParse(minuteStr);
          if (dt == null) continue;
          existingPlannedKeys.add('$sid|$setId|${_dateKey(dt.toLocal())}');
        }
      }
      if (_sideDebug) {
        print(
            '[PLAN][existing-keys] via rpc keys=${existingPlannedKeys.length} rangeUtc=$fromUtc..$toUtc');
      }
    } catch (e) {
      // fallback: 기존 메모리 기반(정확도 낮을 수 있음)
      if (_sideDebug) {
        print('[PLAN][existing-keys][WARN] rpc 실패 -> memory fallback: $e');
      }
      for (final r in _attendanceRecords) {
        if (!r.isPlanned) continue;
        if (r.isPresent || r.arrivalTime != null) continue;
        if (r.setId == null || r.setId!.isEmpty) continue;
        final dk = _dateKey(r.classDateTime);
        final classDate = DateTime(
            r.classDateTime.year, r.classDateTime.month, r.classDateTime.day);
        if (classDate.isBefore(anchor)) continue;
        existingPlannedKeys.add('${r.studentId}|${r.setId}|$dk');
      }
    }

    bool samplePrinted = false;
    int decisionLogCount = 0;
    for (int i = 0; i < days; i++) {
      final date = anchor.add(Duration(days: i));
      final dayIdx = date.weekday - 1;

      // 하루/세트 단위로 묶어서 하나의 예정 레코드만 생성
      final Map<String, _PlannedDailyAgg> aggBySet = {};
      for (final b in blocks.where((b) => b.dayIndex == dayIdx)) {
        // ✅ 휴원 기간에는 예정 수업을 생성하지 않는다.
        if (isPausedDay(b.studentId, date)) continue;
        if (!_isBlockActiveOnDate(b, date)) continue;
        final classStart = DateTime(
            date.year, date.month, date.day, b.startHour, b.startMinute);
        final classEnd = classStart.add(b.duration);
        final setId = b.setId!;

        final agg = aggBySet.putIfAbsent(
          '${b.studentId}|$setId',
          () => _PlannedDailyAgg(
            studentId: b.studentId,
            setId: setId,
            start: classStart,
            end: classEnd,
            sessionTypeId: b.sessionTypeId,
          ),
        );
        if (classStart.isBefore(agg.start)) agg.start = classStart;
        if (classEnd.isAfter(agg.end)) agg.end = classEnd;
        if (agg.sessionTypeId == null && b.sessionTypeId != null) {
          agg.sessionTypeId = b.sessionTypeId;
        }
      }

      final aggs = aggBySet.values.toList()
        ..sort((a, b) {
          final cmp = a.start.compareTo(b.start);
          if (cmp != 0) return cmp;
          return a.setId.compareTo(b.setId);
        });
      for (final agg in aggs) {
        final classDateTime = agg.start;
        final classEndTime = agg.end;
        final keyBase = '${agg.studentId}|${agg.setId}';
        final dateKey = _dateKey(classDateTime);

        // ✅ 휴강/대체(원래 회차)면 base planned는 만들지 않는다.
        final ov =
            overrideByOriginalKey['${agg.studentId}|${minKey(classDateTime)}'];
        if (ov != null &&
            (ov.overrideType == OverrideType.skip ||
                ov.overrideType == OverrideType.replace)) {
          if (_sideDebug) {
            print(
                '[PLAN][skip-base-by-override] type=${ov.overrideType} student=${agg.studentId} dt=$classDateTime');
          }
          continue;
        }

        // ✅ 이미 실제 기록(출석/등원 등)이 있으면 planned 생성하지 않음
        final existingAtStart =
            getAttendanceRecord(agg.studentId, classDateTime);
        if (existingAtStart != null &&
            (!existingAtStart.isPlanned ||
                existingAtStart.arrivalTime != null ||
                existingAtStart.isPresent)) {
          continue;
        }

        int? cycle = _resolveCycleByDueDate(agg.studentId, classDateTime);
        if (cycle == null) {
          final monthDate = _monthKey(classDateTime);
          cycle = _calcCycle(earliestMonthByKey, keyBase, monthDate);
        }
        if (cycle == null || cycle == 0) cycle = 1;

        int sessionOrder = 1;
        final om = orderMapOf(agg.studentId, cycle);
        final k =
            _sessionKeyForOrder(setId: agg.setId, startLocal: classDateTime);
        final so = om[k];
        if (so != null && so > 0) {
          sessionOrder = so;
        } else {
          sessionOrder = fallbackOrder(
            studentId: agg.studentId,
            cycle: cycle,
            setId: agg.setId,
            startLocal: classDateTime,
          );
        }
        if (decisionLogCount < 3 ||
            cycle == null ||
            cycle == 0 ||
            sessionOrder <= 0) {
          _logCycleDecision(
            studentId: agg.studentId,
            setId: agg.setId,
            classDateTime: classDateTime,
            resolvedCycle: cycle,
            sessionOrderCandidate: sessionOrder,
            source: 'plan-init',
          );
          decisionLogCount++;
        }
        if (sessionOrder <= 0) {
          if (_sideDebug) {
            // ignore: avoid_print
            print(
                '[WARN][PLAN] sessionOrder<=0 → 1 set=${agg.setId} student=${agg.studentId} date=$classDateTime');
          }
          sessionOrder = 1;
        }

        final occ =
            regularOccByKey[occKey(agg.studentId, agg.setId, classDateTime)];
        // occurrence는 링크용(occurrence_id)으로만 사용한다. session_order는 스케줄 기반(orderMap) 값이 정답.

        final plannedKey =
            '${agg.studentId}|${agg.setId}|${_dateKey(classDateTime)}';
        if (existingPlannedKeys.contains(plannedKey)) {
          if (_sideDebug) {
            print(
                '[PLAN][skip-dup] setId=${agg.setId} student=${agg.studentId} date=$classDateTime');
          }
          continue;
        }
        existingPlannedKeys.add(plannedKey);
        if (_sideDebug && !samplePrinted) {
          // ignore: avoid_print
          print(
              '[PLAN][SAMPLE] set=${agg.setId} student=${agg.studentId} date=$classDateTime cycle=$cycle sessionOrder=$sessionOrder dueCycle=${_resolveCycleByDueDate(agg.studentId, classDateTime)}');
          samplePrinted = true;
        }

        final record = AttendanceRecord.create(
          studentId: agg.studentId,
          occurrenceId: occ?.id,
          classDateTime: classDateTime,
          classEndTime: classEndTime,
          className: _resolveClassName(agg.sessionTypeId),
          isPresent: false,
          arrivalTime: null,
          departureTime: null,
          notes: null,
          sessionTypeId: agg.sessionTypeId,
          setId: agg.setId,
          cycle: cycle,
          sessionOrder: sessionOrder,
          isPlanned: true,
          snapshotId: occ?.snapshotId,
        );

        rows.add({
          'id': record.id,
          'academy_id': academyId,
          'student_id': record.studentId,
          'occurrence_id': record.occurrenceId,
          'class_date_time': record.classDateTime.toUtc().toIso8601String(),
          'class_end_time': record.classEndTime.toUtc().toIso8601String(),
          'class_name': record.className,
          'is_present': record.isPresent,
          'arrival_time': null,
          'departure_time': null,
          'notes': null,
          'session_type_id': record.sessionTypeId,
          'set_id': record.setId,
          'cycle': record.cycle,
          'session_order': record.sessionOrder,
          'is_planned': record.isPlanned,
          'snapshot_id': record.snapshotId,
          'batch_session_id': record.batchSessionId,
          'created_at': record.createdAt.toUtc().toIso8601String(),
          'updated_at': record.updatedAt.toUtc().toIso8601String(),
          'version': record.version,
        });
        if (_sideDebug) {
          print(
              '[PLAN][init-add] setId=${record.setId} student=${record.studentId} dt=${record.classDateTime} cycle=${record.cycle} order=${record.sessionOrder} end=${record.classEndTime}');
        }
        localAdds.add(record);
      }

      // ✅ add/replace(대체/추가 회차) planned 생성
      final repList = overridesByReplacementDate[_dateKey(date)] ??
          const <SessionOverride>[];
      for (final o in repList) {
        final rep = o.replacementClassDateTime;
        if (rep == null) continue;
        if (rep.year != date.year ||
            rep.month != date.month ||
            rep.day != date.day) continue;

        final start =
            DateTime(rep.year, rep.month, rep.day, rep.hour, rep.minute);
        if (isPausedDay(o.studentId, start)) continue;
        // 이미 실제 기록이 있으면 planned 생성 불필요
        final existing = getAttendanceRecord(o.studentId, start);
        if (existing != null &&
            (!existing.isPlanned ||
                existing.arrivalTime != null ||
                existing.isPresent)) {
          continue;
        }

        // set_id: replace는 원래 세트로, add는 override id(또는 명시 set_id)
        final String setId = () {
          if (o.overrideType == OverrideType.replace) {
            return o.setId ??
                _resolveSetId(o.studentId, o.originalClassDateTime ?? start) ??
                o.id;
          }
          return o.setId ?? o.id;
        }();

        final plannedKey = '${o.studentId}|$setId|${_dateKey(start)}';
        if (existingPlannedKeys.contains(plannedKey)) continue;

        final durMin =
            o.durationMinutes ?? _d.getAcademySettings().lessonDuration;
        final end = start.add(Duration(minutes: durMin));

        // ✅ occurrence 연결:
        // - replace: 원본 회차(regular occurrence)로 귀속 (cycle/sessionOrder 고정)
        // - add: 별도 집계용 extra occurrence 생성/연결
        LessonOccurrence? occ;
        final ovOccId = (o.occurrenceId ?? '').trim();
        if (ovOccId.isNotEmpty) {
          for (final it in _lessonOccurrences) {
            if (it.id == ovOccId) {
              occ = it;
              break;
            }
          }
        }
        if (occ == null && o.overrideType == OverrideType.replace) {
          final orig = o.originalClassDateTime;
          if (orig != null) {
            final resolvedSet =
                (o.setId ?? _resolveSetId(o.studentId, orig) ?? setId).trim();
            if (resolvedSet.isNotEmpty) {
              occ = regularOccByKey[occKey(o.studentId, resolvedSet, orig)];
            }
          }
        }
        if (occ == null && o.overrideType == OverrideType.add) {
          final extraSetId = (o.setId ?? o.id).trim();
          if (extraSetId.isNotEmpty) {
            occ = extraOccByKey[occKey(o.studentId, extraSetId, start)];
          }
          if (occ == null && extraSetId.isNotEmpty) {
            const occSelect =
                'id,student_id,kind,cycle,session_order,original_class_datetime,original_class_end_time,duration_minutes,session_type_id,set_id,snapshot_id,created_at,updated_at,version';
            final int extraCycle =
                _resolveCycleByDueDate(o.studentId, start) ?? 1;
            final startUtc = _utcMinute(start);
            final endUtc = startUtc.add(Duration(minutes: durMin));
            try {
              final inserted = await supa
                  .from('lesson_occurrences')
                  .insert({
                    'academy_id': academyId,
                    'student_id': o.studentId,
                    'kind': 'extra',
                    'cycle': extraCycle,
                    'session_order': null,
                    'original_class_datetime': startUtc.toIso8601String(),
                    'original_class_end_time': endUtc.toIso8601String(),
                    'duration_minutes': durMin,
                    'session_type_id': o.sessionTypeId,
                    'set_id': extraSetId,
                  }..removeWhere((k, v) => v == null))
                  .select(occSelect)
                  .maybeSingle();
              if (inserted != null) {
                final m = Map<String, dynamic>.from(inserted as Map);
                DateTime parseTs(String k) =>
                    DateTime.parse(m[k] as String).toLocal();
                DateTime? parseTsOpt(String k) {
                  final v = m[k] as String?;
                  if (v == null || v.isEmpty) return null;
                  return DateTime.parse(v).toLocal();
                }

                int? asIntOpt(dynamic v) {
                  if (v == null) return null;
                  if (v is int) return v;
                  if (v is num) return v.toInt();
                  if (v is String) return int.tryParse(v);
                  return null;
                }

                occ = LessonOccurrence(
                  id: m['id']?.toString() ?? '',
                  studentId: m['student_id']?.toString() ?? o.studentId,
                  kind: (m['kind']?.toString() ?? 'extra').trim(),
                  cycle: asIntOpt(m['cycle']) ?? extraCycle,
                  sessionOrder: asIntOpt(m['session_order']),
                  originalClassDateTime: parseTs('original_class_datetime'),
                  originalClassEndTime: parseTsOpt('original_class_end_time'),
                  durationMinutes: asIntOpt(m['duration_minutes']) ?? durMin,
                  sessionTypeId: m['session_type_id']?.toString(),
                  setId: m['set_id']?.toString(),
                  snapshotId: m['snapshot_id']?.toString(),
                  createdAt: parseTsOpt('created_at'),
                  updatedAt: parseTsOpt('updated_at'),
                  version: asIntOpt(m['version']),
                );
              }
            } catch (e) {
              // unique conflict 등: fetch existing
              try {
                final fetched = await supa
                    .from('lesson_occurrences')
                    .select(occSelect)
                    .eq('academy_id', academyId)
                    .eq('student_id', o.studentId)
                    .eq('kind', 'extra')
                    .eq('set_id', extraSetId)
                    .eq('original_class_datetime', startUtc.toIso8601String())
                    .maybeSingle();
                if (fetched != null) {
                  final m = Map<String, dynamic>.from(fetched as Map);
                  DateTime parseTs(String k) =>
                      DateTime.parse(m[k] as String).toLocal();
                  DateTime? parseTsOpt(String k) {
                    final v = m[k] as String?;
                    if (v == null || v.isEmpty) return null;
                    return DateTime.parse(v).toLocal();
                  }

                  int? asIntOpt(dynamic v) {
                    if (v == null) return null;
                    if (v is int) return v;
                    if (v is num) return v.toInt();
                    if (v is String) return int.tryParse(v);
                    return null;
                  }

                  occ = LessonOccurrence(
                    id: m['id']?.toString() ?? '',
                    studentId: m['student_id']?.toString() ?? o.studentId,
                    kind: (m['kind']?.toString() ?? 'extra').trim(),
                    cycle: asIntOpt(m['cycle']) ?? extraCycle,
                    sessionOrder: asIntOpt(m['session_order']),
                    originalClassDateTime: parseTs('original_class_datetime'),
                    originalClassEndTime: parseTsOpt('original_class_end_time'),
                    durationMinutes: asIntOpt(m['duration_minutes']) ?? durMin,
                    sessionTypeId: m['session_type_id']?.toString(),
                    setId: m['set_id']?.toString(),
                    snapshotId: m['snapshot_id']?.toString(),
                    createdAt: parseTsOpt('created_at'),
                    updatedAt: parseTsOpt('updated_at'),
                    version: asIntOpt(m['version']),
                  );
                }
              } catch (_) {}
              if (_sideDebug) {
                print('[OCC][extra][WARN] ensure failed: $e');
              }
            }
            if (occ != null) {
              _mergeLessonOccurrences([occ!]);
              final sid = (occ!.setId ?? '').trim();
              if (sid.isNotEmpty) {
                extraOccByKey[occKey(
                    occ!.studentId, sid, occ!.originalClassDateTime)] = occ!;
              }
            }
          }
        }

        // ✅ cycle/session_order 계산:
        // - replace(대체): 원본 회차에 귀속되어야 하므로 원본 시작시각(가능하면)을 기준으로 계산
        // - add(추가): session_order는 null이지만 cycle은 결제 사이클 기준으로 둔다
        final bool isReplace = o.overrideType == OverrideType.replace;
        final DateTime orderAnchor =
            (isReplace ? (o.originalClassDateTime ?? start) : start);

        int? cycle = _resolveCycleByDueDate(o.studentId, orderAnchor);
        if (cycle == null) {
          final monthDate = _monthKey(orderAnchor);
          final keyBase = '${o.studentId}|$setId';
          cycle = _calcCycle(earliestMonthByKey, keyBase, monthDate);
        }
        if (cycle == null || cycle == 0) cycle = 1;

        int sessionOrder = 1;
        final om = orderMapOf(o.studentId, cycle);
        final k = _sessionKeyForOrder(setId: setId, startLocal: orderAnchor);
        final so = om[k];
        if (so != null && so > 0) {
          sessionOrder = so;
        } else {
          sessionOrder = fallbackOrder(
            studentId: o.studentId,
            cycle: cycle,
            setId: setId,
            startLocal: orderAnchor,
          );
        }
        if (sessionOrder <= 0) sessionOrder = 1;

        // occurrence는 링크용(occurrence_id)으로만 사용한다. session_order는 스케줄 기반(orderMap) 값이 정답.

        final String effectiveSetId = (occ?.setId ?? setId).trim().isNotEmpty
            ? (occ?.setId ?? setId)
            : setId;

        final record = AttendanceRecord.create(
          studentId: o.studentId,
          occurrenceId: occ?.id,
          classDateTime: start,
          classEndTime: end,
          className: _resolveClassName(o.sessionTypeId),
          isPresent: false,
          arrivalTime: null,
          departureTime: null,
          notes: null,
          sessionTypeId: o.sessionTypeId,
          setId: effectiveSetId,
          cycle: cycle,
          sessionOrder:
              o.overrideType == OverrideType.add ? null : sessionOrder,
          isPlanned: true,
          snapshotId: occ?.snapshotId,
        );

        rows.add({
          'id': record.id,
          'academy_id': academyId,
          'student_id': record.studentId,
          'occurrence_id': record.occurrenceId,
          'class_date_time': record.classDateTime.toUtc().toIso8601String(),
          'class_end_time': record.classEndTime.toUtc().toIso8601String(),
          'class_name': record.className,
          'is_present': record.isPresent,
          'arrival_time': null,
          'departure_time': null,
          'notes': null,
          'session_type_id': record.sessionTypeId,
          'set_id': record.setId,
          'cycle': record.cycle,
          'session_order': record.sessionOrder,
          'is_planned': record.isPlanned,
          'snapshot_id': record.snapshotId,
          'batch_session_id': record.batchSessionId,
          'created_at': record.createdAt.toUtc().toIso8601String(),
          'updated_at': record.updatedAt.toUtc().toIso8601String(),
          'version': record.version,
        });
        localAdds.add(record);
        existingPlannedKeys.add(plannedKey);
      }
    }

    if (rows.isEmpty) return;

    // 배치 세션 생성 후 매핑 적용
    final Map<String, List<AttendanceRecord>> byStudent = {};
    for (final r in localAdds) {
      byStudent.putIfAbsent(r.studentId, () => []).add(r);
    }
    final Map<String, String> batchSessionByRecordId = {};
    for (final entry in byStudent.entries) {
      final map = await _createBatchSessionsForPlanned(
        studentId: entry.key,
        plannedRecords: entry.value,
        snapshotId: null,
      );
      batchSessionByRecordId.addAll(map);
    }
    for (int i = 0; i < localAdds.length; i++) {
      final rec = localAdds[i];
      final updated =
          rec.copyWith(batchSessionId: batchSessionByRecordId[rec.id]);
      localAdds[i] = updated;
      rows[i]['batch_session_id'] = updated.batchSessionId;
    }

    try {
      await supa.from('attendance_records').upsert(rows, onConflict: 'id');
      _attendanceRecords.addAll(localAdds);
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      print('[INFO] planned 생성: ${localAdds.length}건 (다음 ${days}일)');
    } catch (e, st) {
      print('[ERROR] planned 생성 실패: $e\n$st');
    }
  }

  DateTime _monthKey(DateTime dt) => DateTime(dt.year, dt.month);
  int _monthsBetween(DateTime start, DateTime end) =>
      (end.year - start.year) * 12 + (end.month - start.month);

  void _seedCycleMaps(
    Map<String, DateTime> earliestMonthByKey,
    Map<String, int> monthCountByKey,
  ) {
    for (final r in _attendanceRecords) {
      if (r.setId == null || r.setId!.isEmpty) continue;
      final keyBase = '${r.studentId}|${r.setId}';
      final m = _monthKey(r.classDateTime);
      final existingEarliest = earliestMonthByKey[keyBase];
      if (existingEarliest == null || m.isBefore(existingEarliest)) {
        earliestMonthByKey[keyBase] = m;
      }
      final mk = '$keyBase|${m.year}-${m.month}';
      monthCountByKey[mk] = (monthCountByKey[mk] ?? 0) + 1;
    }
  }

  int _calcCycle(Map<String, DateTime> earliestMonthByKey, String keyBase,
      DateTime monthDate) {
    final existing = earliestMonthByKey[keyBase];
    if (existing == null) {
      earliestMonthByKey[keyBase] = monthDate;
      return 1;
    }
    if (monthDate.isBefore(existing)) {
      earliestMonthByKey[keyBase] = monthDate;
      return 1;
    }
    return _monthsBetween(existing, monthDate) + 1;
  }

  String _dateKey(DateTime dt) => '${dt.year}-${dt.month}-${dt.day}';

  int? _resolveCycleByDueDate(String studentId, DateTime classDate) {
    final prs = _d
        .getPaymentRecords()
        .where((p) =>
            p.studentId == studentId && p.dueDate != null && p.cycle != null)
        .toList();
    if (prs.isEmpty) return null;
    prs.sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
    final classDateOnly =
        DateTime(classDate.year, classDate.month, classDate.day);
    for (var i = 0; i < prs.length; i++) {
      final curDue = DateTime(
          prs[i].dueDate!.year, prs[i].dueDate!.month, prs[i].dueDate!.day);
      final nextDue = (i + 1 < prs.length)
          ? DateTime(prs[i + 1].dueDate!.year, prs[i + 1].dueDate!.month,
              prs[i + 1].dueDate!.day)
          : null;
      if (classDateOnly.isBefore(curDue)) continue;
      if (nextDue == null || classDateOnly.isBefore(nextDue)) {
        return prs[i].cycle;
      }
    }
    if (classDateOnly.isBefore(DateTime(prs.first.dueDate!.year,
        prs.first.dueDate!.month, prs.first.dueDate!.day))) {
      return prs.first.cycle ?? 1;
    }
    return prs.last.cycle;
  }

  void _logCycleDebug(String studentId, DateTime classDate) {
    if (!_sideDebug) return;
    final prs = _d
        .getPaymentRecords()
        .where((p) =>
            p.studentId == studentId && p.dueDate != null && p.cycle != null)
        .toList();
    prs.sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
    final list = prs.map((p) => 'cycle=${p.cycle} due=${p.dueDate}').toList();
    // ignore: avoid_print
    print(
        '[PLAN][CYCLE-DEBUG] student=$studentId date=$classDate payments=${list.join('; ')}');
  }

  void _logCycleDecision({
    required String studentId,
    required String setId,
    required DateTime classDateTime,
    required int? resolvedCycle,
    required int sessionOrderCandidate,
    required String source,
  }) {
    if (!_sideDebug) return;
    // ignore: avoid_print
    print(
      '[PLAN][CYCLE-DECISION][$source] student=$studentId set=$setId date=$classDateTime '
      'resolvedCycle=$resolvedCycle sessionOrderCandidate=$sessionOrderCandidate '
      'dueCycle=${_resolveCycleByDueDate(studentId, classDateTime)} '
      'payCount=${_d.getPaymentRecords().where((p) => p.studentId == studentId).length}',
    );
  }

  String? _resolveSetId(String studentId, DateTime classDateTime) {
    final blocks = _d.getStudentTimeBlocks();
    final dayIdx = classDateTime.weekday - 1;
    try {
      final block = blocks.firstWhere(
        (b) =>
            b.studentId == studentId &&
            b.dayIndex == dayIdx &&
            b.startHour == classDateTime.hour &&
            b.startMinute == classDateTime.minute &&
            _isBlockActiveOnDate(b, classDateTime),
      );
      return block.setId;
    } catch (_) {
      return null;
    }
  }

  void schedulePlannedRegen(String studentId, String setId,
      {bool immediate = false}) {
    _pendingRegenSetIdsByStudent
        .putIfAbsent(studentId, () => <String>{})
        .add(setId);
    if (immediate) {
      _flushPlannedRegen();
      return;
    }
    _plannedRegenTimer ??=
        Timer(const Duration(seconds: 1), _flushPlannedRegen);
  }

  Future<void> _flushPlannedRegen() async {
    final pending = Map<String, Set<String>>.from(_pendingRegenSetIdsByStudent);
    _pendingRegenSetIdsByStudent.clear();
    _plannedRegenTimer?.cancel();
    _plannedRegenTimer = null;
    for (final entry in pending.entries) {
      await _regeneratePlannedAttendanceForStudentSets(
        studentId: entry.key,
        setIds: entry.value,
        days: 15,
        snapshotId: null,
        blocksOverride: null,
      );
    }
  }

  Future<void> flushPendingPlannedRegens() async {
    await _flushPlannedRegen();
  }

  Future<void> regeneratePlannedAttendanceForStudentSets({
    required String studentId,
    required Set<String> setIds,
    int days = 15,
    String? snapshotId,
    List<StudentTimeBlock>? blocksOverride,
  }) =>
      _regeneratePlannedAttendanceForStudentSets(
        studentId: studentId,
        setIds: setIds,
        days: days,
        snapshotId: snapshotId,
        blocksOverride: blocksOverride,
      );

  Future<void> regeneratePlannedAttendanceForStudent({
    required String studentId,
    int days = 15,
    String? snapshotId,
    List<StudentTimeBlock>? blocksOverride,
  }) async {
    final today = DateTime.now();
    final allSetIds = _d
        .getStudentTimeBlocks()
        .where((b) =>
            b.studentId == studentId &&
            b.setId != null &&
            b.setId!.isNotEmpty &&
            // 오늘 활성뿐 아니라 "미래 시작" 세트도 포함해야 예정 생성이 누락되지 않는다.
            (b.endDate == null ||
                !DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day)
                    .isBefore(DateTime(today.year, today.month, today.day))))
        .map((b) => b.setId!)
        .toSet();
    if (allSetIds.isEmpty) {
      await deletePlannedAttendanceForStudent(studentId, days: days);
      return;
    }
    await deletePlannedAttendanceForStudent(studentId, days: days);
    await regeneratePlannedAttendanceForStudentSets(
      studentId: studentId,
      setIds: allSetIds,
      days: days,
      snapshotId: snapshotId,
      blocksOverride: blocksOverride,
    );
  }

  Future<void> deletePlannedAttendanceForStudent(String studentId,
      {int days = 15}) async {
    final today = DateTime.now();
    final anchor = DateTime(today.year, today.month, today.day);
    final end = anchor.add(Duration(days: days));
    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    if (_sideDebug) {
      final before = _attendanceRecords.length;
      int willRemove = 0;
      DateTime? minDt;
      DateTime? maxDt;
      bool touchesToday = false;
      for (final r in _attendanceRecords) {
        if (r.studentId != studentId) continue;
        if (r.isPlanned != true) continue;
        if (r.arrivalTime != null || r.isPresent) continue;
        if (r.classDateTime.isBefore(anchor) || r.classDateTime.isAfter(end))
          continue;
        willRemove++;
        final dt = r.classDateTime;
        if (minDt == null || dt.isBefore(minDt)) minDt = dt;
        if (maxDt == null || dt.isAfter(maxDt)) maxDt = dt;
        final dOnly = DateTime(dt.year, dt.month, dt.day);
        if (dOnly == anchor) touchesToday = true;
      }
      print(
        '[PLAN][delete-student-start] student=$studentId range=${anchor.toIso8601String()}..${end.toIso8601String()} localBefore=$before localWillRemove=$willRemove touchesToday=$touchesToday min=${minDt?.toIso8601String()} max=${maxDt?.toIso8601String()}',
      );
    }
    try {
      await Supabase.instance.client
          .from('attendance_records')
          .delete()
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .eq('is_planned', true)
          // ⚠️ 순수 planned(출석/등원 기록 없는 것)만 삭제해야 실제 기록이 날아가지 않는다.
          .eq('is_present', false)
          .isFilter('arrival_time', null)
          .gte('class_date_time', anchor.toUtc().toIso8601String())
          .lte('class_date_time', end.toUtc().toIso8601String());
      final beforeLocal = _attendanceRecords.length;
      _attendanceRecords.removeWhere((r) {
        if (r.studentId != studentId) return false;
        if (r.isPlanned != true) return false;
        if (r.arrivalTime != null || r.isPresent) return false;
        return !r.classDateTime.isBefore(anchor) &&
            !r.classDateTime.isAfter(end);
      });
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      if (_sideDebug) {
        final afterLocal = _attendanceRecords.length;
        print(
            '[PLAN][delete-student-done] student=$studentId removed=${beforeLocal - afterLocal} localAfter=$afterLocal');
      }
    } catch (e, st) {
      print(
          '[WARN] deletePlannedAttendanceForStudent 실패 student=$studentId: $e\n$st');
    }
  }

  Future<void> _regeneratePlannedAttendanceForStudentSets({
    required String studentId,
    required Set<String> setIds,
    int days = 15,
    String? snapshotId,
    List<StudentTimeBlock>? blocksOverride,
  }) async {
    if (setIds.isEmpty) return;

    final hasPaymentInfo =
        _d.getPaymentRecords().any((p) => p.studentId == studentId);
    if (!hasPaymentInfo) {
      try {
        await _d.loadPaymentRecords();
      } catch (_) {}
    }

    final today = DateTime.now();
    final anchor = DateTime(today.year, today.month, today.day);
    final DateTime endDate = anchor.add(Duration(days: days));

    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    final supa = Supabase.instance.client;

    try {
      final delRes = await supa
          .from('attendance_records')
          .delete()
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .inFilter('set_id', setIds.toList())
          .eq('is_planned', true)
          // ⚠️ 순수 planned만 삭제 (실제 출석/등원 기록 보호)
          .eq('is_present', false)
          .isFilter('arrival_time', null)
          .gte('class_date_time', anchor.toUtc().toIso8601String());
      if (_sideDebug) {
        // ignore: avoid_print
        print('[PLAN] deleted planned rows (student): $delRes');
      }
      _attendanceRecords.removeWhere((r) =>
          r.studentId == studentId &&
          setIds.contains(r.setId) &&
          r.isPlanned == true &&
          !r.isPresent &&
          r.arrivalTime == null &&
          !r.classDateTime.isBefore(anchor));
    } catch (e) {
      if (_sideDebug) {
        // ignore: avoid_print
        print('[WARN] planned 삭제 실패(student=$studentId setIds=$setIds): $e');
      }
    }

    final blocks = (blocksOverride ?? _d.getStudentTimeBlocks())
        .where((b) =>
            b.studentId == studentId &&
            b.setId != null &&
            setIds.contains(b.setId))
        .toList();
    if (blocks.isEmpty) {
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      return;
    }

    final List<Map<String, dynamic>> rows = [];
    final List<AttendanceRecord> localAdds = [];

    final Map<String, DateTime> earliestMonthByKey = {};
    final Map<String, int> monthCountByKey = {};
    _seedCycleMaps(earliestMonthByKey, monthCountByKey);
    // ✅ 회차(session_order)는 "결제 사이클 내 수업을 시간순으로 나열"한 순서를 따른다.
    // - set_id가 다르면 같은 날짜라도 서로 다른 회차
    // - student_time_blocks 연속 수정 시에도 결정적으로 동일한 결과가 나오도록, cycle 전체 범위를 기반으로 맵을 만든다.
    final Map<int, Map<String, int>> _orderMapByCycle = {};
    Map<String, int> _getOrderMap(int cycle) => _orderMapByCycle.putIfAbsent(
          cycle,
          () => _buildSessionOrderMapForStudentCycle(
            studentId: studentId,
            cycle: cycle,
            // cycle 전체를 계산할 때는 "전체 블록"이 필요(부분 setIds만 넘기면 글로벌 순서가 깨짐)
            blocksOverride: _d.getStudentTimeBlocks(),
          ),
        );

    String minKey(DateTime dt) =>
        '${dt.year}-${dt.month}-${dt.day}-${dt.hour}-${dt.minute}';

    // ===== SessionOverride 반영(학생 단위) =====
    final Map<String, SessionOverride> overrideByOriginalKey = {};
    final Map<String, List<SessionOverride>> overridesByReplacementDate = {};
    for (final o in _d.getSessionOverrides()) {
      if (o.studentId != studentId) continue;
      if (o.status != OverrideStatus.planned) continue;
      final orig = o.originalClassDateTime;
      if ((o.overrideType == OverrideType.skip ||
              o.overrideType == OverrideType.replace) &&
          orig != null) {
        overrideByOriginalKey['$studentId|${minKey(orig)}'] = o;
      }
      final rep = o.replacementClassDateTime;
      if ((o.overrideType == OverrideType.add ||
              o.overrideType == OverrideType.replace) &&
          rep != null) {
        overridesByReplacementDate
            .putIfAbsent(_dateKey(rep), () => <SessionOverride>[])
            .add(o);
      }
    }

    // ===== lesson_occurrences(원본 회차) 보장/맵 (학생 단위 regen) =====
    final Set<int> cyclesNeeded = <int>{};
    final c1 = _resolveCycleByDueDate(studentId, anchor);
    final c2 = _resolveCycleByDueDate(studentId, endDate);
    if (c1 != null) cyclesNeeded.add(c1);
    if (c2 != null) cyclesNeeded.add(c2);
    for (final o in _d.getSessionOverrides()) {
      if (o.studentId != studentId) continue;
      if (o.status != OverrideStatus.planned) continue;
      if (o.overrideType != OverrideType.replace) continue;
      final orig = o.originalClassDateTime;
      if (orig == null) continue;
      final c0 = _resolveCycleByDueDate(studentId, orig);
      if (c0 != null) cyclesNeeded.add(c0);
    }
    try {
      for (final c in cyclesNeeded) {
        final has = _lessonOccurrences.any((o) =>
            o.studentId == studentId && o.kind == 'regular' && o.cycle == c);
        if (has) continue;
        await _ensureRegularLessonOccurrencesForStudentCycle(
          academyId: academyId,
          studentId: studentId,
          cycle: c,
        );
      }
    } catch (_) {}
    String occKey(String setId, DateTime originalLocal) =>
        '$studentId|$setId|${minKey(originalLocal)}';
    final Map<String, LessonOccurrence> regularOccByKey = {};
    for (final o in _lessonOccurrences) {
      if (o.studentId != studentId) continue;
      if (o.kind != 'regular') continue;
      final sid = (o.setId ?? '').trim();
      if (sid.isEmpty) continue;
      regularOccByKey[occKey(sid, o.originalClassDateTime)] = o;
    }

    // 중복 생성 방지: 하루/세트 키 (동일 학생)
    final Set<String> existingPlannedKeys = {};
    for (final r in _attendanceRecords) {
      if (r.studentId != studentId) continue;
      if (!r.isPlanned) continue;
      if (r.isPresent || r.arrivalTime != null) continue;
      if (r.setId == null || r.setId!.isEmpty) continue;
      if (!setIds.contains(r.setId)) continue;
      // anchor(오늘 00:00) 이후만 고려
      final classDate = DateTime(
          r.classDateTime.year, r.classDateTime.month, r.classDateTime.day);
      if (classDate.isBefore(anchor)) continue;
      existingPlannedKeys
          .add('$studentId|${r.setId}|${_dateKey(r.classDateTime)}');
    }

    bool samplePrinted = false;
    int decisionLogCount = 0;
    for (int i = 0; i < days; i++) {
      final date = anchor.add(Duration(days: i));
      final int dayIdx = date.weekday - 1;

      // ✅ 휴원 기간에는 예정 수업을 생성하지 않는다.
      if (_isStudentPausedOn(studentId, date)) continue;

      // 하루/세트(set_id) 단위로 묶어 1회 수업=1레코드 생성
      final Map<String, _PlannedDailyAgg> aggBySet = {};
      for (final b in blocks.where((b) => b.dayIndex == dayIdx)) {
        if (!_isBlockActiveOnDate(b, date)) continue;
        final setId = b.setId;
        if (setId == null || setId.isEmpty) continue;
        final classStart = DateTime(
            date.year, date.month, date.day, b.startHour, b.startMinute);
        final classEnd = classStart.add(b.duration);

        final agg = aggBySet.putIfAbsent(
          '$studentId|$setId',
          () => _PlannedDailyAgg(
            studentId: studentId,
            setId: setId,
            start: classStart,
            end: classEnd,
            sessionTypeId: b.sessionTypeId,
          ),
        );
        if (classStart.isBefore(agg.start)) agg.start = classStart;
        if (classEnd.isAfter(agg.end)) agg.end = classEnd;
        if (agg.sessionTypeId == null && b.sessionTypeId != null) {
          agg.sessionTypeId = b.sessionTypeId;
        }
      }

      final aggs = aggBySet.values.toList()
        ..sort((a, b) {
          final cmpDt = a.start.compareTo(b.start);
          if (cmpDt != 0) return cmpDt;
          return a.setId.compareTo(b.setId);
        });

      for (final agg in aggs) {
        final classDateTime = agg.start;
        final classEndTime = agg.end;
        final keyBase = '$studentId|${agg.setId}';

        // ✅ 휴강/대체(원래 회차)면 base planned는 만들지 않는다.
        final ov = overrideByOriginalKey['$studentId|${minKey(classDateTime)}'];
        if (ov != null &&
            (ov.overrideType == OverrideType.skip ||
                ov.overrideType == OverrideType.replace)) {
          if (_sideDebug) {
            print(
                '[PLAN-student][skip-base-by-override] type=${ov.overrideType} student=$studentId dt=$classDateTime');
          }
          continue;
        }

        // ✅ 이미 실제 기록(출석/등원 등)이 있으면 planned 생성하지 않음
        final existingAtStart = getAttendanceRecord(studentId, classDateTime);
        if (existingAtStart != null &&
            (!existingAtStart.isPlanned ||
                existingAtStart.arrivalTime != null ||
                existingAtStart.isPresent)) {
          continue;
        }

        int? cycle = _resolveCycleByDueDate(studentId, classDateTime);
        int sessionOrder = 1;
        if (cycle == null) {
          final monthDate = _monthKey(classDateTime);
          cycle = _calcCycle(earliestMonthByKey, keyBase, monthDate);
        }
        if (cycle != null && cycle > 0) {
          final orderMap = _getOrderMap(cycle);
          final key =
              _sessionKeyForOrder(setId: agg.setId, startLocal: classDateTime);
          final so = orderMap[key];
          if (so != null && so > 0) {
            sessionOrder = so;
          }
        }
        if (cycle == null || cycle == 0) {
          if (_sideDebug) {
            // ignore: avoid_print
            print(
                '[WARN][PLAN-student] cycle null/0 → 1 set=${agg.setId} student=$studentId date=$classDateTime (payment_records miss?)');
            _logCycleDebug(studentId, classDateTime);
          }
          cycle = 1;
        }
        if (sessionOrder <= 0) {
          if (_sideDebug) {
            // ignore: avoid_print
            print(
                '[WARN][PLAN-student] sessionOrder<=0 → 1 set=${agg.setId} student=$studentId date=$classDateTime');
          }
          sessionOrder = 1;
        }

        final occ = regularOccByKey[occKey(agg.setId, classDateTime)];
        // occurrence는 링크용(occurrence_id)으로만 사용한다. session_order는 스케줄 기반(orderMap) 값이 정답.
        if (decisionLogCount < 3 ||
            cycle == null ||
            cycle == 0 ||
            sessionOrder <= 0) {
          _logCycleDecision(
            studentId: studentId,
            setId: agg.setId,
            classDateTime: classDateTime,
            resolvedCycle: cycle,
            sessionOrderCandidate: sessionOrder,
            source: 'plan-student',
          );
          decisionLogCount++;
        }
        if (_sideDebug && !samplePrinted) {
          // ignore: avoid_print
          print(
              '[PLAN][SAMPLE-student] set=${agg.setId} student=$studentId date=$classDateTime cycle=$cycle sessionOrder=$sessionOrder dueCycle=${_resolveCycleByDueDate(studentId, classDateTime)}');
          samplePrinted = true;
        }

        final plannedKey = '$studentId|${agg.setId}|${_dateKey(classDateTime)}';
        if (existingPlannedKeys.contains(plannedKey)) {
          if (_sideDebug) {
            print(
                '[PLAN-student][skip-dup] setId=${agg.setId} student=$studentId date=$classDateTime');
          }
          continue;
        }
        existingPlannedKeys.add(plannedKey);

        final record = AttendanceRecord.create(
          studentId: studentId,
          occurrenceId: occ?.id,
          classDateTime: classDateTime,
          classEndTime: classEndTime,
          className: _resolveClassName(agg.sessionTypeId),
          isPresent: false,
          arrivalTime: null,
          departureTime: null,
          notes: null,
          sessionTypeId: agg.sessionTypeId,
          setId: agg.setId,
          cycle: cycle,
          sessionOrder: sessionOrder,
          isPlanned: true,
          snapshotId: snapshotId,
        );

        rows.add({
          'id': record.id,
          'academy_id': academyId,
          'student_id': record.studentId,
          'occurrence_id': record.occurrenceId,
          'class_date_time': record.classDateTime.toUtc().toIso8601String(),
          'class_end_time': record.classEndTime.toUtc().toIso8601String(),
          'class_name': record.className,
          'is_present': record.isPresent,
          'arrival_time': null,
          'departure_time': null,
          'notes': null,
          'session_type_id': record.sessionTypeId,
          'set_id': record.setId,
          'cycle': record.cycle,
          'session_order': record.sessionOrder,
          'is_planned': record.isPlanned,
          'snapshot_id': snapshotId,
          'batch_session_id': record.batchSessionId,
          'created_at': record.createdAt.toUtc().toIso8601String(),
          'updated_at': record.updatedAt.toUtc().toIso8601String(),
          'version': record.version,
        });
        localAdds.add(record);
      }

      // ✅ add/replace(대체/추가 회차) planned 생성 (단, 이번 regen 대상 setIds에 속하는 것만)
      final repList = overridesByReplacementDate[_dateKey(date)] ??
          const <SessionOverride>[];
      for (final o in repList) {
        final rep = o.replacementClassDateTime;
        if (rep == null) continue;
        if (rep.year != date.year ||
            rep.month != date.month ||
            rep.day != date.day) continue;

        final start =
            DateTime(rep.year, rep.month, rep.day, rep.hour, rep.minute);
        final String setId = () {
          if (o.overrideType == OverrideType.replace) {
            return o.setId ??
                _resolveSetId(studentId, o.originalClassDateTime ?? start) ??
                o.id;
          }
          return o.setId ?? o.id;
        }();
        if (!setIds.contains(setId)) continue;

        final plannedKey = '$studentId|$setId|${_dateKey(start)}';
        if (existingPlannedKeys.contains(plannedKey)) continue;

        final existing = getAttendanceRecord(studentId, start);
        if (existing != null &&
            (!existing.isPlanned ||
                existing.arrivalTime != null ||
                existing.isPresent)) {
          continue;
        }

        final durMin =
            o.durationMinutes ?? _d.getAcademySettings().lessonDuration;
        final end = start.add(Duration(minutes: durMin));

        int? cycle = _resolveCycleByDueDate(studentId, start);
        int? sessionOrder;
        if (cycle == null) {
          final monthDate = _monthKey(start);
          final keyBase = '$studentId|$setId';
          cycle = _calcCycle(earliestMonthByKey, keyBase, monthDate);
        }
        if (cycle == null || cycle == 0) cycle = 1;

        // ✅ session_order는 결제 사이클 내 "전체 수업"을 시간순(+set_id tie-break)으로 나열한 값
        // (set_id가 다르면 다른 회차)
        if (cycle != null && cycle > 0) {
          final map = _getOrderMap(cycle);
          final k = _sessionKeyForOrder(setId: setId, startLocal: start);
          final so = map[k];
          if (so != null && so > 0) {
            sessionOrder = so;
          }
        }

        // ✅ replace 오버라이드는 원본 occurrence로 귀속(링크용)
        LessonOccurrence? repOcc;
        if (o.overrideType == OverrideType.replace) {
          final orig = o.originalClassDateTime;
          if (orig != null) {
            repOcc = regularOccByKey[occKey(setId, orig)];
          }
        }

        final record = AttendanceRecord.create(
          studentId: studentId,
          occurrenceId: repOcc?.id,
          classDateTime: start,
          classEndTime: end,
          className: _resolveClassName(o.sessionTypeId),
          isPresent: false,
          arrivalTime: null,
          departureTime: null,
          notes: null,
          sessionTypeId: o.sessionTypeId,
          setId: setId,
          cycle: cycle,
          sessionOrder: sessionOrder,
          isPlanned: true,
          snapshotId: snapshotId,
        );

        rows.add({
          'id': record.id,
          'academy_id': academyId,
          'student_id': record.studentId,
          'occurrence_id': record.occurrenceId,
          'class_date_time': record.classDateTime.toUtc().toIso8601String(),
          'class_end_time': record.classEndTime.toUtc().toIso8601String(),
          'class_name': record.className,
          'is_present': record.isPresent,
          'arrival_time': null,
          'departure_time': null,
          'notes': null,
          'session_type_id': record.sessionTypeId,
          'set_id': record.setId,
          'cycle': record.cycle,
          'session_order': record.sessionOrder,
          'is_planned': record.isPlanned,
          'snapshot_id': snapshotId,
          'batch_session_id': record.batchSessionId,
          'created_at': record.createdAt.toUtc().toIso8601String(),
          'updated_at': record.updatedAt.toUtc().toIso8601String(),
          'version': record.version,
        });
        localAdds.add(record);
        existingPlannedKeys.add(plannedKey);
      }
    }

    if (rows.isEmpty) {
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      return;
    }

    // 배치 세션 생성 후 매핑 적용 (학생 단위)
    final Map<String, String> batchSessionByRecordId =
        await _createBatchSessionsForPlanned(
      studentId: studentId,
      plannedRecords: localAdds,
      snapshotId: snapshotId,
    );
    for (int i = 0; i < localAdds.length; i++) {
      final rec = localAdds[i];
      final updated =
          rec.copyWith(batchSessionId: batchSessionByRecordId[rec.id]);
      localAdds[i] = updated;
      rows[i]['batch_session_id'] = updated.batchSessionId;
    }

    try {
      final upRes =
          await supa.from('attendance_records').upsert(rows, onConflict: 'id');
      _attendanceRecords.addAll(localAdds);
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      if (_sideDebug) {
        // ignore: avoid_print
        print(
            '[PLAN] regen(student) done setIds=$setIds added=${localAdds.length} rowsResp=$upRes');
      }
    } catch (e, st) {
      print(
          '[ERROR] 예정 출석 upsert 실패(student=$studentId setIds=$setIds): $e\n$st');
    }
  }

  void _seedDateOrderBySetCycle(
    Map<String, Map<String, int>> dateOrderByKey,
    Map<String, int> counterByKey,
  ) {
    for (final r in _attendanceRecords) {
      if (r.setId == null || r.setId!.isEmpty) continue;
      if (r.cycle == null) continue;
      final key = '${r.setId}|${r.cycle}';
      final dk = _dateKey(r.classDateTime);
      final m = dateOrderByKey.putIfAbsent(key, () => {});
      if (!m.containsKey(dk)) {
        final next = (counterByKey[key] ?? 0) + 1;
        m[dk] = r.sessionOrder ?? next;
        counterByKey[key] = next > (counterByKey[key] ?? 0)
            ? next
            : (counterByKey[key] ?? next);
      }
    }
  }

  Future<void> saveOrUpdateAttendance({
    required String studentId,
    required DateTime classDateTime,
    required DateTime classEndTime,
    required String className,
    required bool isPresent,
    DateTime? arrivalTime,
    DateTime? departureTime,
    String? notes,
    String? sessionTypeId,
    String? setId,
    int? cycle,
    int? sessionOrder,
    bool isPlanned = false,
    String? snapshotId,
    String? batchSessionId,
  }) async {
    final now = DateTime.now();
    final resolvedSetId = setId ?? _resolveSetId(studentId, classDateTime);
    AttendanceRecord? existing = getAttendanceRecord(studentId, classDateTime);
    // ✅ 메모리에 없더라도 서버에 "planned(또는 기존)" 행이 있으면 그 행을 먼저 업데이트한다.
    // (유니크 인덱스 적용 이후에는 insert 시도보다 update가 더 안전/명확)
    if (existing == null) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        const selectCols =
            'id,student_id,occurrence_id,class_date_time,class_end_time,class_name,is_present,arrival_time,departure_time,notes,session_type_id,set_id,cycle,session_order,is_planned,snapshot_id,batch_session_id,created_at,updated_at,version';
        final classDtUtc = _utcMinute(classDateTime);
        final row = await Supabase.instance.client
            .from('attendance_records')
            .select(selectCols)
            .eq('academy_id', academyId)
            .eq('student_id', studentId)
            .eq('class_date_time', classDtUtc.toIso8601String())
            .maybeSingle();
        if (row != null) {
          final m = Map<String, dynamic>.from(row as Map);
          DateTime parseTs(String k) =>
              DateTime.parse(m[k] as String).toLocal();
          DateTime? parseTsOpt(String k) {
            final v = m[k] as String?;
            if (v == null || v.isEmpty) return null;
            return DateTime.parse(v).toLocal();
          }

          final dynamic isPresentDyn = m['is_present'];
          final bool isPresent0 = (isPresentDyn is bool)
              ? isPresentDyn
              : ((isPresentDyn is num) ? isPresentDyn == 1 : false);
          final AttendanceRecord fetched = AttendanceRecord(
            id: m['id'] as String?,
            studentId: m['student_id'] as String,
            occurrenceId: m['occurrence_id']?.toString(),
            classDateTime: parseTs('class_date_time'),
            classEndTime: parseTs('class_end_time'),
            className: (m['class_name'] as String?) ?? '',
            isPresent: isPresent0,
            arrivalTime: parseTsOpt('arrival_time'),
            departureTime: parseTsOpt('departure_time'),
            notes: m['notes'] as String?,
            sessionTypeId: m['session_type_id'] as String?,
            setId: m['set_id'] as String?,
            snapshotId: m['snapshot_id'] as String?,
            batchSessionId: m['batch_session_id'] as String?,
            cycle: (m['cycle'] is num) ? (m['cycle'] as num).toInt() : null,
            sessionOrder: (m['session_order'] is num)
                ? (m['session_order'] as num).toInt()
                : null,
            isPlanned: m['is_planned'] == true || m['is_planned'] == 1,
            createdAt: parseTs('created_at'),
            updatedAt: parseTs('updated_at'),
            version: (m['version'] is num) ? (m['version'] as num).toInt() : 1,
          );
          if (fetched.id != null &&
              !_attendanceRecords.any((r) => r.id == fetched.id)) {
            _attendanceRecords.add(fetched);
            attendanceRecordsNotifier.value =
                List.unmodifiable(_attendanceRecords);
          }
          existing = fetched;
        }
      } catch (_) {
        // 네트워크/권한 문제 등: 기존 로직(INSERT 시도)로 fallback
      }
    }

    final resolvedSnapshotId = snapshotId ?? existing?.snapshotId;
    final resolvedBatchSessionId = batchSessionId ?? existing?.batchSessionId;
    if (existing != null) {
      final updated = existing.copyWith(
        classEndTime: classEndTime,
        className: className,
        isPresent: isPresent,
        arrivalTime: arrivalTime,
        departureTime: departureTime,
        notes: notes,
        sessionTypeId: sessionTypeId ?? existing.sessionTypeId,
        setId: resolvedSetId ?? existing.setId,
        cycle: cycle ?? existing.cycle,
        sessionOrder: sessionOrder ?? existing.sessionOrder,
        isPlanned: isPlanned || existing.isPlanned,
        snapshotId: resolvedSnapshotId ?? existing.snapshotId,
        batchSessionId: resolvedBatchSessionId ?? existing.batchSessionId,
        updatedAt: now,
      );
      try {
        await updateAttendanceRecord(updated);
      } on StateError catch (e) {
        if (e.message == 'CONFLICT_ATTENDANCE_VERSION') {
          await loadAttendanceRecords();
          throw Exception('다른 기기에서 먼저 수정했습니다. 내용을 확인 후 다시 시도하세요.');
        } else {
          rethrow;
        }
      }
      try {
        if (updated.id != null) {
          await _completePlannedOverrideFor(
            studentId: studentId,
            replacementDateTime: classDateTime,
            replacementAttendanceId: updated.id!,
          );
        }
      } catch (e) {
        print('[WARN] planned→completed 링크 실패(업데이트): $e');
      }

      // batch_session_id가 있으면 상태 갱신(UPDATE 경로)
      if (updated.batchSessionId != null) {
        await _updateBatchSessionState(
          batchSessionId: updated.batchSessionId!,
          state: isPresent ? 'completed' : 'planned',
          attendanceId: updated.id,
        );
      }
    } else {
      // occurrence_id를 최대한 채워 넣는다(원본 회차/추가수업 역추적)
      String? inferredOccurrenceId;
      bool sameMinute(DateTime a, DateTime b) =>
          a.year == b.year &&
          a.month == b.month &&
          a.day == b.day &&
          a.hour == b.hour &&
          a.minute == b.minute;
      final sid = (resolvedSetId ?? '').trim();
      if (sid.isNotEmpty) {
        for (final o in _lessonOccurrences) {
          if (o.studentId != studentId) continue;
          if ((o.setId ?? '') != sid) continue;
          if (sameMinute(o.originalClassDateTime, classDateTime)) {
            inferredOccurrenceId = o.id;
            break;
          }
        }
      }
      final newRecord = AttendanceRecord.create(
        studentId: studentId,
        occurrenceId: inferredOccurrenceId,
        classDateTime: classDateTime,
        classEndTime: classEndTime,
        className: className,
        isPresent: isPresent,
        arrivalTime: arrivalTime,
        departureTime: departureTime,
        notes: notes,
        sessionTypeId: sessionTypeId,
        setId: resolvedSetId,
        cycle: cycle,
        sessionOrder: sessionOrder,
        isPlanned: isPlanned,
        snapshotId: resolvedSnapshotId,
        batchSessionId: resolvedBatchSessionId,
      );
      await addAttendanceRecord(newRecord);
      try {
        if (newRecord.id != null) {
          await _completePlannedOverrideFor(
            studentId: studentId,
            replacementDateTime: classDateTime,
            replacementAttendanceId: newRecord.id!,
          );
        }
        if (newRecord.batchSessionId != null) {
          await _updateBatchSessionState(
            batchSessionId: newRecord.batchSessionId!,
            state: isPresent ? 'completed' : 'planned',
            attendanceId: newRecord.id,
          );
        }
      } catch (e) {
        print('[WARN] planned→completed 링크 실패(추가): $e');
      }
    }
  }

  Future<void> _completePlannedOverrideFor({
    required String studentId,
    required DateTime replacementDateTime,
    required String replacementAttendanceId,
  }) async {
    bool sameMinute(DateTime a, DateTime b) {
      return a.year == b.year &&
          a.month == b.month &&
          a.day == b.day &&
          a.hour == b.hour &&
          a.minute == b.minute;
    }

    SessionOverride? target;
    for (final o in _d.getSessionOverrides()) {
      if (o.studentId != studentId) continue;
      if (o.status != OverrideStatus.planned) continue;
      if (!(o.overrideType == OverrideType.add ||
          o.overrideType == OverrideType.replace)) {
        continue;
      }
      if (o.replacementClassDateTime == null) continue;
      if (sameMinute(o.replacementClassDateTime!, replacementDateTime)) {
        target = o;
        break;
      }
    }

    if (target == null) {
      return;
    }

    final updated = target.copyWith(
      status: OverrideStatus.completed,
      replacementAttendanceId: replacementAttendanceId,
      updatedAt: DateTime.now(),
    );
    try {
      await _d.updateSessionOverrideRemote(updated);
    } catch (_) {}
    _d.applySessionOverrideLocal(updated);
    if (updated.overrideType == OverrideType.replace &&
        updated.originalClassDateTime != null) {
      await removePlannedAttendanceForDate(
        studentId: updated.studentId,
        classDateTime: updated.originalClassDateTime!,
      );
    }
  }

  Future<void> regeneratePlannedAttendanceForOverride(
      SessionOverride ov) async {
    final DateTime? original = ov.originalClassDateTime;
    final DateTime? replacement = ov.replacementClassDateTime;
    final bool canceled = ov.status == OverrideStatus.canceled;

    // 공통: 원래 회차(휴강/대체) planned 제거 (순수 planned만)
    Future<void> _removeOriginalPlannedIfNeeded() async {
      if (original == null) return;
      await removePlannedAttendanceForDate(
          studentId: ov.studentId, classDateTime: original);
    }

    // 공통: 스케줄 기반으로 원래 회차 planned를 복원(취소 시)
    Future<void> _restoreOriginalPlannedIfPossible() async {
      if (original == null) return;

      final now = DateTime.now();
      final anchor = DateTime(now.year, now.month, now.day);
      final end = anchor.add(const Duration(days: 15));
      final dateOnly = DateTime(original.year, original.month, original.day);
      if (dateOnly.isBefore(anchor) || dateOnly.isAfter(end)) {
        // planned 유지 범위(다음 15일) 밖은 글로벌 생성기에 맡김
        return;
      }

      final String? inferredSetId =
          ov.setId ?? _resolveSetId(ov.studentId, original);
      if (inferredSetId == null || inferredSetId.isEmpty) return;

      final dayIdx = original.weekday - 1;
      final allBlocks = _d.getStudentTimeBlocks();
      final cand = allBlocks
          .where((b) =>
              b.studentId == ov.studentId &&
              b.setId == inferredSetId &&
              b.dayIndex == dayIdx &&
              _isBlockActiveOnDate(b, dateOnly))
          .toList();
      if (cand.isEmpty) return;

      DateTime? minStart;
      DateTime? maxEnd;
      String? sessionTypeId;
      for (final b in cand) {
        final s = DateTime(dateOnly.year, dateOnly.month, dateOnly.day,
            b.startHour, b.startMinute);
        final e = s.add(b.duration);
        if (minStart == null || s.isBefore(minStart)) minStart = s;
        if (maxEnd == null || e.isAfter(maxEnd)) maxEnd = e;
        sessionTypeId ??= b.sessionTypeId;
      }
      if (minStart == null || maxEnd == null) return;

      // 이미 실제 기록이 있으면 복원하지 않음
      final existing = getAttendanceRecord(ov.studentId, minStart);
      if (existing != null &&
          (!existing.isPlanned ||
              existing.arrivalTime != null ||
              existing.isPresent)) {
        return;
      }

      // 중복 방지: 같은 set_id의 같은 날짜 planned가 이미 있으면 스킵
      final minStartDateKey = _dateKey(minStart);
      final hasPlannedSameDay = _attendanceRecords.any((r) =>
          r.studentId == ov.studentId &&
          r.setId == inferredSetId &&
          r.isPlanned &&
          !r.isPresent &&
          r.arrivalTime == null &&
          _dateKey(r.classDateTime) == minStartDateKey);
      if (hasPlannedSameDay) return;

      // ✅ occurrence 매칭(원본 회차 고정)
      bool sameMinute(DateTime a, DateTime b) =>
          a.year == b.year &&
          a.month == b.month &&
          a.day == b.day &&
          a.hour == b.hour &&
          a.minute == b.minute;
      LessonOccurrence? occ;
      final hint = (ov.occurrenceId ?? '').trim();
      if (hint.isNotEmpty) {
        for (final it in _lessonOccurrences) {
          if (it.id == hint) {
            occ = it;
            break;
          }
        }
      }
      if (occ == null) {
        for (final it in _lessonOccurrences) {
          if (it.kind != 'regular') continue;
          if (it.studentId != ov.studentId) continue;
          if ((it.setId ?? '') != inferredSetId) continue;
          if (sameMinute(it.originalClassDateTime, minStart)) {
            occ = it;
            break;
          }
        }
      }
      if (occ == null) {
        final c0 = _resolveCycleByDueDate(ov.studentId, minStart);
        if (c0 != null) {
          try {
            final academyId0 =
                await TenantService.instance.getActiveAcademyId() ??
                    await TenantService.instance.ensureActiveAcademy();
            await _ensureRegularLessonOccurrencesForStudentCycle(
              academyId: academyId0,
              studentId: ov.studentId,
              cycle: c0,
            );
          } catch (_) {}
          for (final it in _lessonOccurrences) {
            if (it.kind != 'regular') continue;
            if (it.studentId != ov.studentId) continue;
            if ((it.setId ?? '') != inferredSetId) continue;
            if (sameMinute(it.originalClassDateTime, minStart)) {
              occ = it;
              break;
            }
          }
        }
      }

      // ✅ cycle/session_order는 "전체 스케줄(시간순 + set_id tie-break)" 기준으로 결정한다.
      int? cycle = _resolveCycleByDueDate(ov.studentId, minStart);
      if (cycle == null) {
        final Map<String, DateTime> earliestMonthByKey = {};
        final Map<String, int> monthCountByKey = {};
        _seedCycleMaps(earliestMonthByKey, monthCountByKey);
        cycle = _calcCycle(earliestMonthByKey, '${ov.studentId}|$inferredSetId',
            _monthKey(minStart));
      }
      if (cycle == null || cycle == 0) cycle = 1;
      final int fixedCycle = cycle;
      int fixedOrder = 1;
      final om = _buildSessionOrderMapForStudentCycle(
        studentId: ov.studentId,
        cycle: fixedCycle,
        blocksOverride: _d.getStudentTimeBlocks(),
      );
      final k = _sessionKeyForOrder(setId: inferredSetId, startLocal: minStart);
      final so = om[k];
      if (so != null && so > 0) {
        fixedOrder = so;
      }

      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final record = AttendanceRecord.create(
        studentId: ov.studentId,
        occurrenceId: occ?.id,
        classDateTime: minStart,
        classEndTime: maxEnd,
        className: _resolveClassName(sessionTypeId),
        isPresent: false,
        arrivalTime: null,
        departureTime: null,
        notes: null,
        sessionTypeId: sessionTypeId,
        setId: inferredSetId,
        cycle: fixedCycle,
        sessionOrder: fixedOrder,
        isPlanned: true,
        snapshotId: null,
      );

      final row = {
        'id': record.id,
        'academy_id': academyId,
        'student_id': record.studentId,
        'occurrence_id': record.occurrenceId,
        'class_date_time': record.classDateTime.toUtc().toIso8601String(),
        'class_end_time': record.classEndTime.toUtc().toIso8601String(),
        'class_name': record.className,
        'is_present': record.isPresent,
        'arrival_time': null,
        'departure_time': null,
        'notes': null,
        'session_type_id': record.sessionTypeId,
        'set_id': record.setId,
        'cycle': record.cycle,
        'session_order': record.sessionOrder,
        'is_planned': record.isPlanned,
        'snapshot_id': null,
        'batch_session_id': record.batchSessionId,
        'created_at': record.createdAt.toUtc().toIso8601String(),
        'updated_at': record.updatedAt.toUtc().toIso8601String(),
        'version': record.version,
      };
      try {
        await Supabase.instance.client
            .from('attendance_records')
            .upsert(row, onConflict: 'id');
        _attendanceRecords.add(record);
        attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
        if (_sideDebug) {
          print(
              '[PLAN][override][restore-base] student=${ov.studentId} dt=$minStart setId=$inferredSetId');
        }
      } catch (e, st) {
        print('[PLAN][override][restore-base][ERROR] $e\n$st');
      }
    }

    // 1) 휴강(skip)
    if (ov.overrideType == OverrideType.skip) {
      if (original == null) return;
      if (canceled) {
        await _restoreOriginalPlannedIfPossible();
      } else {
        await _removeOriginalPlannedIfNeeded();
      }
      return;
    }

    // 2) 대체(replace)
    if (ov.overrideType == OverrideType.replace) {
      if (original != null) {
        await _removeOriginalPlannedIfNeeded();
      }
      if (replacement == null) {
        if (canceled) {
          await _restoreOriginalPlannedIfPossible();
        }
        return;
      }
      if (canceled) {
        await removePlannedAttendanceForDate(
            studentId: ov.studentId, classDateTime: replacement);
        await _restoreOriginalPlannedIfPossible();
        return;
      }
      // planned 상태: replacement planned 생성(중복은 remove→upsert로 정리)
      await removePlannedAttendanceForDate(
          studentId: ov.studentId, classDateTime: replacement);
    }

    // 3) 추가(add) 또는 replace의 replacement 생성
    if (replacement == null) return;
    if (canceled) {
      await removePlannedAttendanceForDate(
          studentId: ov.studentId, classDateTime: replacement);
      return;
    }

    // ✅ completed(이미 처리된 보강/추가) 또는 과거 replacement는 planned를 새로 만들지 않는다.
    // - 실제 출석/등원 기록이 이미 존재할 가능성이 높고,
    // - 과거 planned 생성은 중복/혼선을 유발한다.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final repDay =
        DateTime(replacement.year, replacement.month, replacement.day);
    if (ov.status == OverrideStatus.completed || repDay.isBefore(today)) {
      // 혹시 남아있을 수 있는 "순수 planned"만 정리
      await removePlannedAttendanceForDate(
          studentId: ov.studentId, classDateTime: replacement);
      return;
    }

    final DateTime target = replacement;

    // set_id: replace는 원래 세트로, add는 override id(또는 명시 set_id)
    final String setId = () {
      if (ov.overrideType == OverrideType.replace) {
        return ov.setId ??
            _resolveSetId(ov.studentId, ov.originalClassDateTime ?? target) ??
            ov.id;
      }
      return ov.setId ?? ov.id;
    }();

    bool sameMinute(DateTime a, DateTime b) =>
        a.year == b.year &&
        a.month == b.month &&
        a.day == b.day &&
        a.hour == b.hour &&
        a.minute == b.minute;

    LessonOccurrence? occ;
    final hint = (ov.occurrenceId ?? '').trim();
    if (hint.isNotEmpty) {
      for (final it in _lessonOccurrences) {
        if (it.id == hint) {
          occ = it;
          break;
        }
      }
    }

    // replace: 원본 occurrence로 귀속
    if (occ == null && ov.overrideType == OverrideType.replace) {
      final orig = ov.originalClassDateTime;
      if (orig != null) {
        final resolvedSet =
            (ov.setId ?? _resolveSetId(ov.studentId, orig) ?? setId).trim();
        for (final it in _lessonOccurrences) {
          if (it.kind != 'regular') continue;
          if (it.studentId != ov.studentId) continue;
          if ((it.setId ?? '') != resolvedSet) continue;
          if (sameMinute(it.originalClassDateTime, orig)) {
            occ = it;
            break;
          }
        }
        if (occ == null) {
          final c0 = _resolveCycleByDueDate(ov.studentId, orig);
          if (c0 != null) {
            try {
              await _ensureRegularLessonOccurrencesForStudentCycle(
                academyId: await TenantService.instance.getActiveAcademyId() ??
                    await TenantService.instance.ensureActiveAcademy(),
                studentId: ov.studentId,
                cycle: c0,
              );
            } catch (_) {}
            for (final it in _lessonOccurrences) {
              if (it.kind != 'regular') continue;
              if (it.studentId != ov.studentId) continue;
              if ((it.setId ?? '') != resolvedSet) continue;
              if (sameMinute(it.originalClassDateTime, orig)) {
                occ = it;
                break;
              }
            }
          }
        }
      }
    }

    // add: extra occurrence 생성/연결(별도 집계)
    if (occ == null && ov.overrideType == OverrideType.add) {
      final extraSetId = (ov.setId ?? ov.id).trim();
      if (extraSetId.isNotEmpty) {
        for (final it in _lessonOccurrences) {
          if (it.kind != 'extra') continue;
          if (it.studentId != ov.studentId) continue;
          if ((it.setId ?? '') != extraSetId) continue;
          if (sameMinute(it.originalClassDateTime, target)) {
            occ = it;
            break;
          }
        }
        if (occ == null) {
          const occSelect =
              'id,student_id,kind,cycle,session_order,original_class_datetime,original_class_end_time,duration_minutes,session_type_id,set_id,snapshot_id,created_at,updated_at,version';
          final int extraCycle =
              _resolveCycleByDueDate(ov.studentId, target) ?? 1;
          final startUtc = _utcMinute(target);
          final int durMin =
              ov.durationMinutes ?? _d.getAcademySettings().lessonDuration;
          final endUtc = startUtc.add(Duration(minutes: durMin));
          try {
            final inserted = await Supabase.instance.client
                .from('lesson_occurrences')
                .insert({
                  'academy_id':
                      await TenantService.instance.getActiveAcademyId() ??
                          await TenantService.instance.ensureActiveAcademy(),
                  'student_id': ov.studentId,
                  'kind': 'extra',
                  'cycle': extraCycle,
                  'session_order': null,
                  'original_class_datetime': startUtc.toIso8601String(),
                  'original_class_end_time': endUtc.toIso8601String(),
                  'duration_minutes': durMin,
                  'session_type_id': ov.sessionTypeId,
                  'set_id': extraSetId,
                }..removeWhere((k, v) => v == null))
                .select(occSelect)
                .maybeSingle();
            if (inserted != null) {
              final m = Map<String, dynamic>.from(inserted as Map);
              DateTime parseTs(String k) =>
                  DateTime.parse(m[k] as String).toLocal();
              DateTime? parseTsOpt(String k) {
                final v = m[k] as String?;
                if (v == null || v.isEmpty) return null;
                return DateTime.parse(v).toLocal();
              }

              int? asIntOpt(dynamic v) {
                if (v == null) return null;
                if (v is int) return v;
                if (v is num) return v.toInt();
                if (v is String) return int.tryParse(v);
                return null;
              }

              occ = LessonOccurrence(
                id: m['id']?.toString() ?? '',
                studentId: m['student_id']?.toString() ?? ov.studentId,
                kind: (m['kind']?.toString() ?? 'extra').trim(),
                cycle: asIntOpt(m['cycle']) ?? extraCycle,
                sessionOrder: asIntOpt(m['session_order']),
                originalClassDateTime: parseTs('original_class_datetime'),
                originalClassEndTime: parseTsOpt('original_class_end_time'),
                durationMinutes: asIntOpt(m['duration_minutes']) ?? durMin,
                sessionTypeId: m['session_type_id']?.toString(),
                setId: m['set_id']?.toString(),
                snapshotId: m['snapshot_id']?.toString(),
                createdAt: parseTsOpt('created_at'),
                updatedAt: parseTsOpt('updated_at'),
                version: asIntOpt(m['version']),
              );
            }
          } catch (_) {
            // ignore (table may not exist yet)
          }
          if (occ != null) {
            _mergeLessonOccurrences([occ!]);
          }
        }
      }
    }

    // ✅ cycle/session_order는 "전체 스케줄(시간순 + set_id tie-break)" 기준으로 결정한다.
    final DateTime orderAnchor = (ov.overrideType == OverrideType.replace)
        ? (ov.originalClassDateTime ?? target)
        : target;

    int? cycle = _resolveCycleByDueDate(ov.studentId, orderAnchor);
    if (cycle == null) {
      final Map<String, DateTime> earliestMonthByKey = {};
      final Map<String, int> monthCountByKey = {};
      _seedCycleMaps(earliestMonthByKey, monthCountByKey);
      cycle = _calcCycle(
          earliestMonthByKey, '${ov.studentId}|$setId', _monthKey(orderAnchor));
    }
    if (cycle == null || cycle == 0) cycle = 1;
    final int fixedCycle = cycle;

    int? fixedOrder;
    if (ov.overrideType != OverrideType.add) {
      final om = _buildSessionOrderMapForStudentCycle(
        studentId: ov.studentId,
        cycle: fixedCycle,
        blocksOverride: _d.getStudentTimeBlocks(),
      );
      final effectiveSet = ((occ?.setId ?? setId).trim().isNotEmpty)
          ? (occ?.setId ?? setId)
          : setId;
      final k =
          _sessionKeyForOrder(setId: effectiveSet, startLocal: orderAnchor);
      fixedOrder = om[k];
      if (fixedOrder != null && fixedOrder! <= 0) fixedOrder = null;
      fixedOrder ??= 1;
    }

    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    final classEndTime = target.add(Duration(
        minutes: ov.durationMinutes ?? _d.getAcademySettings().lessonDuration));
    final record = AttendanceRecord.create(
      studentId: ov.studentId,
      occurrenceId: occ?.id,
      classDateTime: target,
      classEndTime: classEndTime,
      className: _resolveClassName(ov.sessionTypeId),
      isPresent: false,
      arrivalTime: null,
      departureTime: null,
      notes: null,
      sessionTypeId: ov.sessionTypeId,
      setId: (occ?.setId ?? setId),
      cycle: fixedCycle,
      sessionOrder: ov.overrideType == OverrideType.add ? null : fixedOrder,
      isPlanned: true,
      snapshotId: null,
    );

    final row = {
      'id': record.id,
      'academy_id': academyId,
      'student_id': record.studentId,
      'occurrence_id': record.occurrenceId,
      'class_date_time': record.classDateTime.toUtc().toIso8601String(),
      'class_end_time': record.classEndTime.toUtc().toIso8601String(),
      'class_name': record.className,
      'is_present': record.isPresent,
      'arrival_time': null,
      'departure_time': null,
      'notes': null,
      'session_type_id': record.sessionTypeId,
      'set_id': record.setId,
      'cycle': record.cycle,
      'session_order': record.sessionOrder,
      'is_planned': record.isPlanned,
      'snapshot_id': null,
      'batch_session_id': record.batchSessionId,
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'updated_at': record.updatedAt.toUtc().toIso8601String(),
      'version': record.version,
    };

    try {
      await Supabase.instance.client
          .from('attendance_records')
          .upsert(row, onConflict: 'id');
      _attendanceRecords.add(record);
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      print(
          '[INFO] override planned regenerated: student=${ov.studentId}, date=$target');
    } catch (e, st) {
      print('[ERROR] override planned upsert 실패: $e\n$st');
    }
  }

  Future<void> removePlannedAttendanceForDate({
    required String studentId,
    required DateTime classDateTime,
  }) async {
    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    if (_sideDebug) {
      final before = _attendanceRecords.length;
      int willRemove = 0;
      for (final r in _attendanceRecords) {
        if (r.studentId != studentId) continue;
        if (r.isPlanned != true) continue;
        if (r.isPresent || r.arrivalTime != null) continue;
        if (r.classDateTime.year != classDateTime.year ||
            r.classDateTime.month != classDateTime.month ||
            r.classDateTime.day != classDateTime.day ||
            r.classDateTime.hour != classDateTime.hour ||
            r.classDateTime.minute != classDateTime.minute) continue;
        willRemove++;
      }
      final nowL = DateTime.now();
      final todayL = DateTime(nowL.year, nowL.month, nowL.day);
      final targetL =
          DateTime(classDateTime.year, classDateTime.month, classDateTime.day);
      print(
        '[PLAN][remove-date-start] student=$studentId dt=$classDateTime isToday=${targetL == todayL} localBefore=$before localWillRemove=$willRemove',
      );
    }
    try {
      await Supabase.instance.client
          .from('attendance_records')
          .delete()
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .eq('is_planned', true)
          // ⚠️ 순수 planned만 제거 (실제 기록 보호)
          .eq('is_present', false)
          .isFilter('arrival_time', null)
          .eq('class_date_time', classDateTime.toUtc().toIso8601String());
      final beforeLocal = _attendanceRecords.length;
      _attendanceRecords.removeWhere((r) =>
          r.studentId == studentId &&
          r.isPlanned == true &&
          !r.isPresent &&
          r.arrivalTime == null &&
          r.classDateTime.year == classDateTime.year &&
          r.classDateTime.month == classDateTime.month &&
          r.classDateTime.day == classDateTime.day &&
          r.classDateTime.hour == classDateTime.hour &&
          r.classDateTime.minute == classDateTime.minute);
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      if (_sideDebug) {
        final afterLocal = _attendanceRecords.length;
        print(
            '[PLAN][remove-date-done] student=$studentId removed=${beforeLocal - afterLocal} localAfter=$afterLocal');
      }
    } catch (e) {
      print('[WARN] planned 제거 실패(student=$studentId, dt=$classDateTime): $e');
    }
  }

  Future<void> regeneratePlannedAttendanceForSet({
    required String studentId,
    required String setId,
    int days = 15,
    String? snapshotId,
    List<StudentTimeBlock>? blocksOverride,
  }) async {
    if (setId.isEmpty) return;

    final hasPaymentInfo =
        _d.getPaymentRecords().any((p) => p.studentId == studentId);
    if (!hasPaymentInfo) {
      try {
        await _d.loadPaymentRecords();
      } catch (_) {}
    }
    final today = DateTime.now();
    final anchor = DateTime(today.year, today.month, today.day);

    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    final supa = Supabase.instance.client;

    try {
      final delRes = await supa
          .from('attendance_records')
          .delete()
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .eq('set_id', setId)
          .eq('is_planned', true)
          // ⚠️ 순수 planned만 삭제 (실제 출석/등원 기록 보호)
          .eq('is_present', false)
          .isFilter('arrival_time', null)
          .gte('class_date_time', anchor.toUtc().toIso8601String());
      if (_sideDebug) {
        // ignore: avoid_print
        print('[PLAN] deleted planned rows: $delRes');
      }
      _attendanceRecords.removeWhere((r) =>
          r.studentId == studentId &&
          r.setId == setId &&
          r.isPlanned == true &&
          !r.isPresent &&
          r.arrivalTime == null &&
          !r.classDateTime.isBefore(anchor));
    } catch (e) {
      if (_sideDebug) {
        // ignore: avoid_print
        print('[WARN] planned 삭제 실패(student=$studentId set=$setId): $e');
      }
    }

    final blocks = (blocksOverride ?? _d.getStudentTimeBlocks())
        .where((b) => b.studentId == studentId && b.setId == setId)
        .toList();
    if (blocks.isEmpty) {
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      return;
    }

    final List<Map<String, dynamic>> rows = [];
    final List<AttendanceRecord> localAdds = [];

    final Map<String, DateTime> earliestMonthByKey = {};
    final Map<String, int> monthCountByKey = {};
    _seedCycleMaps(earliestMonthByKey, monthCountByKey);

    final Map<int, Map<String, int>> orderMapCache = {};
    Map<String, int> orderMapOf(int cycle) {
      return orderMapCache.putIfAbsent(
        cycle,
        () => _buildSessionOrderMapForStudentCycle(
          studentId: studentId,
          cycle: cycle,
          blocksOverride: _d.getStudentTimeBlocks(),
        ),
      );
    }

    // ===== lesson_occurrences(원본 회차) 보장/맵 (세트 단위 regen) =====
    String minKey(DateTime dt) =>
        '${dt.year}-${dt.month}-${dt.day}-${dt.hour}-${dt.minute}';
    final Set<int> cyclesNeeded = <int>{};
    final c1 = _resolveCycleByDueDate(studentId, anchor);
    final c2 =
        _resolveCycleByDueDate(studentId, anchor.add(Duration(days: days)));
    if (c1 != null) cyclesNeeded.add(c1);
    if (c2 != null) cyclesNeeded.add(c2);
    try {
      for (final c in cyclesNeeded) {
        final has = _lessonOccurrences.any((o) =>
            o.studentId == studentId && o.kind == 'regular' && o.cycle == c);
        if (has) continue;
        await _ensureRegularLessonOccurrencesForStudentCycle(
          academyId: academyId,
          studentId: studentId,
          cycle: c,
        );
      }
    } catch (_) {}
    final Map<String, LessonOccurrence> regularOccByMinute = {};
    for (final o in _lessonOccurrences) {
      if (o.kind != 'regular') continue;
      if (o.studentId != studentId) continue;
      if ((o.setId ?? '') != setId) continue;
      regularOccByMinute[minKey(o.originalClassDateTime)] = o;
    }

    // 중복 생성 방지: 하루/세트 키
    final Set<String> existingPlannedKeys = {};

    bool samplePrinted = false;
    int decisionLogCount = 0;
    for (int i = 0; i < days; i++) {
      final date = anchor.add(Duration(days: i));
      final int dayIdx = date.weekday - 1;

      final Map<String, _PlannedDailyAgg> aggBySet = {};
      for (final b in blocks.where((b) => b.dayIndex == dayIdx)) {
        if (!_isBlockActiveOnDate(b, date)) continue;
        final classStart = DateTime(
            date.year, date.month, date.day, b.startHour, b.startMinute);
        final classEnd = classStart.add(b.duration);

        final agg = aggBySet.putIfAbsent(
          '$studentId|$setId',
          () => _PlannedDailyAgg(
            studentId: studentId,
            setId: setId,
            start: classStart,
            end: classEnd,
            sessionTypeId: b.sessionTypeId,
          ),
        );
        if (classStart.isBefore(agg.start)) agg.start = classStart;
        if (classEnd.isAfter(agg.end)) agg.end = classEnd;
        if (agg.sessionTypeId == null && b.sessionTypeId != null) {
          agg.sessionTypeId = b.sessionTypeId;
        }
      }

      for (final agg in aggBySet.values) {
        final classDateTime = DateTime(agg.start.year, agg.start.month,
            agg.start.day, agg.start.hour, agg.start.minute);
        final classEndTime = agg.end;

        // ✅ 이미 실제 기록(출석/등원 등)이 있으면 planned 생성하지 않음
        final existingAtStart = getAttendanceRecord(studentId, classDateTime);
        if (existingAtStart != null &&
            (!existingAtStart.isPlanned ||
                existingAtStart.arrivalTime != null ||
                existingAtStart.isPresent)) {
          continue;
        }

        final keyBase = '$studentId|$setId';

        int? cycle = _resolveCycleByDueDate(studentId, classDateTime);
        int sessionOrder = 1;
        if (cycle == null) {
          final monthDate = _monthKey(classDateTime);
          cycle = _calcCycle(earliestMonthByKey, keyBase, monthDate);
        }
        if (cycle == null || cycle == 0) {
          if (_sideDebug) {
            // ignore: avoid_print
            print(
                '[WARN][PLAN-set] cycle null/0 → 1 set=$setId student=$studentId date=$classDateTime (payment_records miss?)');
            _logCycleDebug(studentId, classDateTime);
          }
          cycle = 1;
        }

        // ✅ session_order는 결제 사이클 내 "전체 스케줄"을 시간순(+set_id)으로 나열한 값
        if (cycle != null && cycle > 0) {
          final map = orderMapOf(cycle);
          final k =
              _sessionKeyForOrder(setId: setId, startLocal: classDateTime);
          final so = map[k];
          if (so != null && so > 0) {
            sessionOrder = so;
          }
        }
        if (sessionOrder <= 0) {
          if (_sideDebug) {
            // ignore: avoid_print
            print(
                '[WARN][PLAN-set] sessionOrder<=0 → 1 set=$setId student=$studentId date=$classDateTime');
          }
          sessionOrder = 1;
        }

        final occ = regularOccByMinute[minKey(classDateTime)];
        // occurrence는 링크용(occurrence_id)으로만 사용한다. session_order는 스케줄 기반(orderMap) 값이 정답.
        final plannedKey = '$studentId|$setId|${_dateKey(classDateTime)}';
        if (existingPlannedKeys.contains(plannedKey)) {
          if (_sideDebug) {
            print(
                '[PLAN-set][skip-dup] setId=$setId student=$studentId date=$classDateTime');
          }
          continue;
        }
        existingPlannedKeys.add(plannedKey);
        if (decisionLogCount < 3 ||
            cycle == null ||
            cycle == 0 ||
            sessionOrder <= 0) {
          _logCycleDecision(
            studentId: studentId,
            setId: setId,
            classDateTime: classDateTime,
            resolvedCycle: cycle,
            sessionOrderCandidate: sessionOrder,
            source: 'plan-set',
          );
          decisionLogCount++;
        }
        if (_sideDebug && !samplePrinted) {
          // ignore: avoid_print
          print(
              '[PLAN][SAMPLE-set] set=$setId student=$studentId date=$classDateTime cycle=$cycle sessionOrder=$sessionOrder dueCycle=${_resolveCycleByDueDate(studentId, classDateTime)}');
          samplePrinted = true;
        }

        final record = AttendanceRecord.create(
          studentId: studentId,
          occurrenceId: occ?.id,
          classDateTime: classDateTime,
          classEndTime: classEndTime,
          className: _resolveClassName(agg.sessionTypeId),
          isPresent: false,
          arrivalTime: null,
          departureTime: null,
          notes: null,
          sessionTypeId: agg.sessionTypeId,
          setId: setId,
          cycle: cycle,
          sessionOrder: sessionOrder,
          isPlanned: true,
          snapshotId: snapshotId,
        );

        rows.add({
          'id': record.id,
          'academy_id': academyId,
          'student_id': record.studentId,
          'occurrence_id': record.occurrenceId,
          'class_date_time': record.classDateTime.toUtc().toIso8601String(),
          'class_end_time': record.classEndTime.toUtc().toIso8601String(),
          'class_name': record.className,
          'is_present': record.isPresent,
          'arrival_time': null,
          'departure_time': null,
          'notes': null,
          'session_type_id': record.sessionTypeId,
          'set_id': record.setId,
          'cycle': record.cycle,
          'session_order': record.sessionOrder,
          'is_planned': record.isPlanned,
          'snapshot_id': snapshotId,
          'batch_session_id': record.batchSessionId,
          'created_at': record.createdAt.toUtc().toIso8601String(),
          'updated_at': record.updatedAt.toUtc().toIso8601String(),
          'version': record.version,
        });
        if (_sideDebug) {
          print(
              '[PLAN][set-add] setId=${record.setId} student=${record.studentId} dt=${record.classDateTime} end=${record.classEndTime} cycle=${record.cycle} order=${record.sessionOrder}');
        }
        localAdds.add(record);
      }
    }

    if (rows.isEmpty) {
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      return;
    }

    // 배치 세션 생성 후 매핑 적용 (세트 단위지만 학생 단일)
    final Map<String, String> batchSessionByRecordId =
        await _createBatchSessionsForPlanned(
      studentId: studentId,
      plannedRecords: localAdds,
      snapshotId: snapshotId,
    );
    for (int i = 0; i < localAdds.length; i++) {
      final rec = localAdds[i];
      final updated =
          rec.copyWith(batchSessionId: batchSessionByRecordId[rec.id]);
      localAdds[i] = updated;
      rows[i]['batch_session_id'] = updated.batchSessionId;
    }

    try {
      final upRes =
          await supa.from('attendance_records').upsert(rows, onConflict: 'id');
      _attendanceRecords.addAll(localAdds);
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      if (_sideDebug) {
        // ignore: avoid_print
        print(
            '[PLAN] regen done set_id=$setId added=${localAdds.length} rowsResp=$upRes');
      }
    } catch (e, st) {
      print('[ERROR] set_id=$setId 예정 출석 upsert 실패: $e\n$st');
    }
  }

  Future<void> fixMissingDeparturesForYesterdayKst() async {
    try {
      final int lessonMinutes = _d.getAcademySettings().lessonDuration;
      final DateTime nowKst =
          DateTime.now().toUtc().add(const Duration(hours: 9));
      final DateTime ymdYesterdayKst =
          DateTime(nowKst.year, nowKst.month, nowKst.day)
              .subtract(const Duration(days: 1));

      bool isSameKstDay(DateTime dt, DateTime ymdKst) {
        final k = dt.toUtc().add(const Duration(hours: 9));
        return k.year == ymdKst.year &&
            k.month == ymdKst.month &&
            k.day == ymdKst.day;
      }

      int updated = 0;
      for (final rec in _attendanceRecords) {
        final arrival = rec.arrivalTime;
        if (arrival == null) continue;
        if (rec.departureTime != null) continue;
        if (!isSameKstDay(arrival, ymdYesterdayKst)) continue;

        final DateTime dep = arrival.add(Duration(minutes: lessonMinutes));
        final updatedRec = rec.copyWith(
          isPresent: true,
          departureTime: dep,
        );
        await updateAttendanceRecord(updatedRec);
        updated++;
      }
      print('[ATT] 어제(KST) 미하원 자동 처리: $updated건');
    } catch (e, st) {
      print('[ATT][ERROR] 미하원 자동 처리 실패: $e\n$st');
    }
  }

  /// 결제 사이클(dueDate~다음 dueDate) 기준으로 planned/actual(결석 제외) 집계를 제공한다.
  ///
  /// - plannedCount: cycle 구간의 출석 레코드(예정 포함) 전체
  /// - actualCount: 출석/등원/하원 기록이 있는 회차
  /// - absent/pending: is_planned 여부로 구분(현재 스키마 한계상 완벽하진 않음)
  CycleAttendanceSummary? getCycleAttendanceSummary({
    required String studentId,
    required int cycle,
    DateTime? now,
  }) {
    final paymentRecords =
        _d.getPaymentRecords().where((p) => p.studentId == studentId).toList();
    PaymentRecord? cur;
    PaymentRecord? next;
    for (final p in paymentRecords) {
      if (p.cycle == cycle) cur = p;
      if (p.cycle == cycle + 1) next = p;
    }
    if (cur == null) return null;

    final DateTime start =
        DateTime(cur!.dueDate.year, cur!.dueDate.month, cur!.dueDate.day);
    final DateTime end = next != null
        ? DateTime(next!.dueDate.year, next!.dueDate.month, next!.dueDate.day)
        // fallback: 다음 cycle이 없으면 31일을 가정(서버에서 미래 cycles를 생성하므로 보통 발생하지 않음)
        : start.add(const Duration(days: 31));

    final DateTime nowRef = now ?? DateTime.now();

    // ✅ occurrence 기반 집계(가능하면 우선 적용)
    // - kind='regular'만 사이클 집계에 포함(추가수업(kind='extra')는 별도 집계)
    final regularOccs = _lessonOccurrences
        .where((o) =>
            o.studentId == studentId && o.kind == 'regular' && o.cycle == cycle)
        .toList();

    if (regularOccs.isNotEmpty) {
      // 원본 시간 기준 정렬(표시/안정성)
      regularOccs.sort(
          (a, b) => a.originalClassDateTime.compareTo(b.originalClassDateTime));

      bool sameMinute(DateTime a, DateTime b) =>
          a.year == b.year &&
          a.month == b.month &&
          a.day == b.day &&
          a.hour == b.hour &&
          a.minute == b.minute;

      int minutesOfOccurrence(LessonOccurrence o) {
        final dm = o.durationMinutes;
        if (dm != null && dm > 0) return dm;
        final end = o.originalClassEndTime;
        if (end != null) {
          final d = end.difference(o.originalClassDateTime).inMinutes;
          if (d > 0) return d;
        }
        return _d.getAcademySettings().lessonDuration;
      }

      DateTime effectiveDateTimeOfOccurrence(LessonOccurrence o) {
        // replace 오버라이드가 있으면 replacement 시각을 "실제 예정 시각"으로 본다.
        // (occurrenceId를 채우는 단계로 넘어가면 ov.occurrenceId 우선 매칭으로 강화 가능)
        for (final ov in _d.getSessionOverrides()) {
          if (ov.studentId != studentId) continue;
          if (ov.status == OverrideStatus.canceled) continue;
          if (ov.overrideType != OverrideType.replace) continue;
          final orig = ov.originalClassDateTime;
          final rep = ov.replacementClassDateTime;
          if (orig == null || rep == null) continue;
          if (sameMinute(orig, o.originalClassDateTime)) return rep;
        }
        return o.originalClassDateTime;
      }

      int plannedCount = 0;
      int actualCount = 0;
      int absentCount = 0;
      int pendingCount = 0;
      int plannedMinutes = 0;
      int actualMinutes = 0;
      int absentMinutes = 0;
      int pendingMinutes = 0;

      for (final o in regularOccs) {
        final minutes = minutesOfOccurrence(o);
        plannedCount += 1;
        plannedMinutes += minutes;

        var records = _attendanceRecords
            .where((r) => r.studentId == studentId && r.occurrenceId == o.id)
            .toList();
        // Backward compatible fallback:
        // occurrence_id가 아직 백필되지 않은 과거 데이터는 "시간/세트"로 매칭하여 집계 정확도를 유지한다.
        if (records.isEmpty) {
          final sid = (o.setId ?? '').trim();
          final eff = effectiveDateTimeOfOccurrence(o);
          records = _attendanceRecords.where((r) {
            if (r.studentId != studentId) return false;
            if (!sameMinute(r.classDateTime, eff)) return false;
            if (sid.isNotEmpty && (r.setId ?? '') != sid) return false;
            return true;
          }).toList();
        }

        AttendanceRecord? actualRec;
        AttendanceRecord? absentRec;
        for (final r in records) {
          final bool isActual =
              r.isPresent || r.arrivalTime != null || r.departureTime != null;
          if (isActual) {
            actualRec = r;
            break;
          }
          // 명시 결석: isPlanned=false && 미출석
          if (!r.isPlanned &&
              !r.isPresent &&
              r.arrivalTime == null &&
              r.departureTime == null) {
            absentRec = r;
          }
        }

        if (actualRec != null) {
          actualCount += 1;
          final m = actualRec!.classEndTime
              .difference(actualRec.classDateTime)
              .inMinutes;
          actualMinutes += (m > 0 ? m : minutes);
          continue;
        }

        // 미래 회차는 결석/미기록으로 분류하지 않는다.
        final effectiveDt = effectiveDateTimeOfOccurrence(o);
        if (effectiveDt.isAfter(nowRef)) {
          continue;
        }

        if (absentRec != null) {
          absentCount += 1;
          absentMinutes += minutes;
        } else {
          pendingCount += 1;
          pendingMinutes += minutes;
        }
      }

      return CycleAttendanceSummary(
        studentId: studentId,
        cycle: cycle,
        start: start,
        end: end,
        plannedCount: plannedCount,
        actualCount: actualCount,
        absentCount: absentCount,
        pendingCount: pendingCount,
        plannedMinutes: plannedMinutes,
        actualMinutes: actualMinutes,
        absentMinutes: absentMinutes,
        pendingMinutes: pendingMinutes,
      );
    }

    int plannedCount = 0;
    int actualCount = 0;
    int absentCount = 0;
    int pendingCount = 0;
    int plannedMinutes = 0;
    int actualMinutes = 0;
    int absentMinutes = 0;
    int pendingMinutes = 0;

    for (final r in _attendanceRecords) {
      if (r.studentId != studentId) continue;
      if (r.classDateTime.isBefore(start) || !r.classDateTime.isBefore(end))
        continue;

      final int minutes = r.classEndTime.difference(r.classDateTime).inMinutes;
      plannedCount += 1;
      plannedMinutes += minutes;

      final bool isActual =
          r.isPresent || r.arrivalTime != null || r.departureTime != null;
      if (isActual) {
        actualCount += 1;
        actualMinutes += minutes;
        continue;
      }

      // 미래 회차는 결석/미기록으로 분류하지 않는다.
      if (r.classDateTime.isAfter(nowRef)) {
        continue;
      }

      // 결석은 actual 0 (요구사항). 다만 스키마상 "명시 결석"과 "미기록"을 완벽히 구분하기 어려워
      // isPlanned를 기준으로 pending/absent로 나누어 제공한다.
      if (r.isPlanned) {
        pendingCount += 1;
        pendingMinutes += minutes;
      } else {
        absentCount += 1;
        absentMinutes += minutes;
      }
    }

    return CycleAttendanceSummary(
      studentId: studentId,
      cycle: cycle,
      start: start,
      end: end,
      plannedCount: plannedCount,
      actualCount: actualCount,
      absentCount: absentCount,
      pendingCount: pendingCount,
      plannedMinutes: plannedMinutes,
      actualMinutes: actualMinutes,
      absentMinutes: absentMinutes,
      pendingMinutes: pendingMinutes,
    );
  }
}
