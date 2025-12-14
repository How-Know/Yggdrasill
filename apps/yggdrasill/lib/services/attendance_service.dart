import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/attendance_record.dart';
import '../models/class_info.dart';
import '../models/payment_record.dart';
import '../models/session_override.dart';
import '../models/student_time_block.dart';
import '../models/academy_settings.dart';
import 'runtime_flags.dart';
import 'tenant_service.dart';
import 'academy_db.dart';
import 'tag_preset_service.dart';

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
    required this.getAcademySettings,
    required this.loadPaymentRecords,
    required this.updateSessionOverrideRemote,
    required this.applySessionOverrideLocal,
  });

  final List<StudentTimeBlock> Function() getStudentTimeBlocks;
  final List<PaymentRecord> Function() getPaymentRecords;
  final List<ClassInfo> Function() getClasses;
  final List<SessionOverride> Function() getSessionOverrides;
  final AcademySettings Function() getAcademySettings;
  final Future<void> Function() loadPaymentRecords;
  final Future<void> Function(SessionOverride) updateSessionOverrideRemote;
  final void Function(SessionOverride) applySessionOverrideLocal;
}

class AttendanceService {
  AttendanceService._internal();
  static final AttendanceService instance = AttendanceService._internal();

  // 사이드 시트 디버그 플래그와 동일한 목적의 로깅 (planned 생성 검증용)
  static const bool _sideDebug = true;

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

  final ValueNotifier<List<AttendanceRecord>> attendanceRecordsNotifier =
      ValueNotifier<List<AttendanceRecord>>([]);
  List<AttendanceRecord> _attendanceRecords = [];
  List<AttendanceRecord> get attendanceRecords => List.unmodifiable(_attendanceRecords);

  RealtimeChannel? _attendanceRealtimeChannel;

  Timer? _plannedRegenTimer;
  final Map<String, Set<String>> _pendingRegenSetIdsByStudent = {};

  void reset() {
    _attendanceRecords = [];
    attendanceRecordsNotifier.value = [];
  }

  Future<void> forceMigration() async {
    try {
      await TenantService.instance.ensureActiveAcademy();
      await loadAttendanceRecords();
    } catch (_) {}
  }

  Future<void> loadAttendanceRecords() async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final rows = await supa
          .from('attendance_records')
          .select(
              'id,student_id,class_date_time,class_end_time,class_name,is_present,arrival_time,departure_time,notes,session_type_id,set_id,cycle,session_order,is_planned,created_at,updated_at,version')
          .eq('academy_id', academyId)
          .order('class_date_time', ascending: false);
      final list = rows as List<dynamic>;
      _attendanceRecords = list.map<AttendanceRecord>((m) {
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
          classDateTime: parseTs('class_date_time'),
          classEndTime: parseTs('class_end_time'),
          className: (m['class_name'] as String?) ?? '',
          isPresent: isPresent,
          arrivalTime: parseTsOpt('arrival_time'),
          departureTime: parseTsOpt('departure_time'),
          notes: m['notes'] as String?,
          sessionTypeId: m['session_type_id'] as String?,
          setId: m['set_id'] as String?,
          cycle: (m['cycle'] is num) ? (m['cycle'] as num).toInt() : null,
          sessionOrder:
              (m['session_order'] is num) ? (m['session_order'] as num).toInt() : null,
          isPlanned: m['is_planned'] == true || m['is_planned'] == 1,
          createdAt: parseTs('created_at'),
          updatedAt: parseTs('updated_at'),
          version: (m['version'] is num) ? (m['version'] as num).toInt() : 1,
        );
      }).toList();
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      print('[SUPA] 출석 기록 로드: ${_attendanceRecords.length}개');
    } catch (e, st) {
      print('[SUPA][ERROR] 출석 기록 로드 실패: $e\n$st');
      _attendanceRecords = [];
      attendanceRecordsNotifier.value = [];
    }
  }

  Future<void> subscribeAttendanceRealtime() async {
    try {
      _attendanceRealtimeChannel?.unsubscribe();
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ??
          await TenantService.instance.ensureActiveAcademy();
      final chan =
          Supabase.instance.client.channel('public:attendance_records:$academyId');
      _attendanceRealtimeChannel = chan
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'attendance_records',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (payload) {
            final m = payload.newRecord;
            if (m == null) return;
            try {
              final rec = AttendanceRecord(
                id: m['id'] as String?,
                studentId: m['student_id'] as String,
                classDateTime: DateTime.parse(m['class_date_time'] as String).toLocal(),
                classEndTime: DateTime.parse(m['class_end_time'] as String).toLocal(),
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
                cycle: (m['cycle'] is num) ? (m['cycle'] as num).toInt() : null,
                sessionOrder: (m['session_order'] is num)
                    ? (m['session_order'] as num).toInt()
                    : null,
                isPlanned: m['is_planned'] == true || m['is_planned'] == 1,
                createdAt: DateTime.parse(m['created_at'] as String).toLocal(),
                updatedAt: DateTime.parse(m['updated_at'] as String).toLocal(),
                version: (m['version'] is num) ? (m['version'] as num).toInt() : 1,
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
              type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (payload) {
            final m = payload.newRecord;
            if (m == null) return;
            try {
              final id = m['id'] as String?;
              if (id == null) return;
              final idx = _attendanceRecords.indexWhere((r) => r.id == id);
              if (idx == -1) return;
              final updated = _attendanceRecords[idx].copyWith(
                classDateTime: DateTime.parse(m['class_date_time'] as String).toLocal(),
                classEndTime: DateTime.parse(m['class_end_time'] as String).toLocal(),
                className:
                    (m['class_name'] as String?) ?? _attendanceRecords[idx].className,
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
                sessionTypeId:
                    m['session_type_id'] as String? ?? _attendanceRecords[idx].sessionTypeId,
                setId: m['set_id'] as String? ?? _attendanceRecords[idx].setId,
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
              attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
            } catch (_) {}
          },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'attendance_records',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (payload) {
            final m = payload.oldRecord;
            if (m == null) return;
            try {
              final id = m['id'] as String?;
              if (id == null) return;
              _attendanceRecords.removeWhere((r) => r.id == id);
              attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
            } catch (_) {}
          },
        )
        ..subscribe();
    } catch (_) {}
  }

  Future<void> addAttendanceRecord(AttendanceRecord record) async {
    final String academyId = (await TenantService.instance.getActiveAcademyId()) ??
        await TenantService.instance.ensureActiveAcademy();
    final supa = Supabase.instance.client;
    final row = {
      'id': record.id,
      'academy_id': academyId,
      'student_id': record.studentId,
      'class_date_time': record.classDateTime.toUtc().toIso8601String(),
      'class_end_time': record.classEndTime.toUtc().toIso8601String(),
      'class_name': record.className,
      'is_present': record.isPresent,
      'arrival_time': record.arrivalTime?.toUtc().toIso8601String(),
      'departure_time': record.departureTime?.toUtc().toIso8601String(),
      'notes': record.notes,
      'session_type_id': record.sessionTypeId,
      'set_id': record.setId,
      'cycle': record.cycle,
      'session_order': record.sessionOrder,
      'is_planned': record.isPlanned,
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'updated_at': record.updatedAt.toUtc().toIso8601String(),
      'version': record.version,
    };
    final inserted =
        await supa.from('attendance_records').insert(row).select('id,version').maybeSingle();
    if (inserted != null) {
      final withId = record.copyWith(
          id: (inserted['id'] as String?),
          version: (inserted['version'] as num?)?.toInt() ?? 1);
      _attendanceRecords.add(withId);
    } else {
      _attendanceRecords.add(record);
    }
    attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
  }

  Future<void> updateAttendanceRecord(AttendanceRecord record) async {
    final supa = Supabase.instance.client;
    if (record.id != null) {
      final row = {
        'student_id': record.studentId,
        'class_date_time': record.classDateTime.toUtc().toIso8601String(),
        'class_end_time': record.classEndTime.toUtc().toIso8601String(),
        'class_name': record.className,
        'is_present': record.isPresent,
        'arrival_time': record.arrivalTime?.toUtc().toIso8601String(),
        'departure_time': record.departureTime?.toUtc().toIso8601String(),
        'notes': record.notes,
        'session_type_id': record.sessionTypeId,
        'set_id': record.setId,
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

    final String academyId = (await TenantService.instance.getActiveAcademyId()) ??
        await TenantService.instance.ensureActiveAcademy();
    final keyFilter = supa
        .from('attendance_records')
        .select('id')
        .eq('academy_id', academyId)
        .eq('student_id', record.studentId)
        .eq('class_date_time', record.classDateTime.toUtc().toIso8601String())
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

  AttendanceRecord? getAttendanceRecord(String studentId, DateTime classDateTime) {
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

  String _resolveClassName(String? sessionTypeId) {
    final classes = _d.getClasses();
    if (sessionTypeId == null) return '수업';
    try {
      final cls = classes.firstWhere((c) => c.id == sessionTypeId);
      if (cls.name.trim().isNotEmpty) return cls.name;
    } catch (_) {}
    return '수업';
  }

  Future<void> generatePlannedAttendanceForNextDays({int days = 14}) async {
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

    // 기존 순수 planned(출석/도착 없는) 오늘 이후 데이터 정리 → 중복/증식 방지
    try {
      final delRes = await supa
          .from('attendance_records')
          .delete()
          .eq('academy_id', academyId)
          .eq('is_planned', true)
          .eq('is_present', false)
          .isFilter('arrival_time', null)
          .gte('class_date_time', anchor.toUtc().toIso8601String());
      if (_sideDebug) {
        print('[PLAN][init-clean] deleted=${delRes.runtimeType == List ? (delRes as List).length : delRes}');
      }
    } catch (e, st) {
      print('[PLAN][init-clean][WARN] $e\n$st');
    }
    _attendanceRecords.removeWhere((r) =>
        r.isPlanned == true &&
        r.isPresent == false &&
        r.arrivalTime == null &&
        !r.classDateTime.isBefore(anchor));

    try {
      await _d.loadPaymentRecords();
    } catch (_) {}

    final List<Map<String, dynamic>> rows = [];
    final List<AttendanceRecord> localAdds = [];

    final Map<String, DateTime> earliestMonthByKey = {};
    final Map<String, int> monthCountByKey = {};
    _seedCycleMaps(earliestMonthByKey, monthCountByKey);
    final Map<String, Map<String, int>> dateOrderByStudentCycle = {};
    final Map<String, int> counterByStudentCycle = {};
    _seedDateOrderByStudentCycle(dateOrderByStudentCycle, counterByStudentCycle);

    // 기존 planned (출석/도착 없는 순수 예정) 중 오늘 이후를 키로 보관하여 중복 생성 방지
    final Set<String> existingPlannedKeys = {};
    final todayKey = _dateKey(anchor);
    for (final r in _attendanceRecords) {
      if (!r.isPlanned) continue;
      if (r.isPresent || r.arrivalTime != null) continue;
      if (r.setId == null || r.setId!.isEmpty) continue;
      final dk = _dateKey(r.classDateTime);
      // anchor(오늘 00:00) 이후만 고려
      final classDate = DateTime(r.classDateTime.year, r.classDateTime.month, r.classDateTime.day);
      if (classDate.isBefore(anchor)) continue;
      existingPlannedKeys.add('${r.studentId}|${r.setId}|$dk');
    }

    bool samplePrinted = false;
    int decisionLogCount = 0;
    for (int i = 0; i < days; i++) {
      final date = anchor.add(Duration(days: i));
      final dayIdx = date.weekday - 1;

      // 하루/세트 단위로 묶어서 하나의 예정 레코드만 생성
      final Map<String, _PlannedDailyAgg> aggBySet = {};
      for (final b in blocks.where((b) => b.dayIndex == dayIdx)) {
        final classStart = DateTime(date.year, date.month, date.day, b.startHour, b.startMinute);
        final classEnd = classStart.add(b.duration);
        final setId = b.setId!;

        final existing = getAttendanceRecord(b.studentId, classStart);
        if (existing != null &&
            (existing.arrivalTime != null || existing.isPresent || existing.isPlanned)) {
          continue;
        }

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

      for (final agg in aggBySet.values) {
        final classDateTime = agg.start;
        final classEndTime = agg.end;
        final keyBase = '${agg.studentId}|${agg.setId}';
        final dateKey = _dateKey(classDateTime);

        int? cycle = _resolveCycleByDueDate(agg.studentId, classDateTime);
        int sessionOrder;
        if (cycle == null) {
          final monthDate = _monthKey(classDateTime);
          cycle = _calcCycle(earliestMonthByKey, keyBase, monthDate);
        }
        final studentCycleKey = '${agg.studentId}|$cycle';
        final m = dateOrderByStudentCycle.putIfAbsent(studentCycleKey, () => {});
        if (m.containsKey(dateKey)) {
          sessionOrder = m[dateKey]!;
        } else {
          final next = (counterByStudentCycle[studentCycleKey] ?? 0) + 1;
          m[dateKey] = next;
          counterByStudentCycle[studentCycleKey] = next;
          sessionOrder = next;
        }
        if (decisionLogCount < 3 || cycle == null || cycle == 0 || sessionOrder <= 0) {
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
        if (cycle == null || cycle == 0) {
          print(
              '[WARN][PLAN] cycle null/0 → 1 set=${agg.setId} student=${agg.studentId} date=$classDateTime (payment_records miss?)');
          _logCycleDebug(agg.studentId, classDateTime);
          cycle = 1;
        }
        if (sessionOrder <= 0) {
          print(
              '[WARN][PLAN] sessionOrder<=0 → 1 set=${agg.setId} student=${agg.studentId} date=$classDateTime');
          sessionOrder = 1;
        }
        final plannedKey = '${agg.studentId}|${agg.setId}|${_dateKey(classDateTime)}';
        if (existingPlannedKeys.contains(plannedKey)) {
          if (_sideDebug) {
            print('[PLAN][skip-dup] setId=${agg.setId} student=${agg.studentId} date=$classDateTime');
          }
          continue;
        }
        existingPlannedKeys.add(plannedKey);
        if (!samplePrinted) {
          print(
              '[PLAN][SAMPLE] set=${agg.setId} student=${agg.studentId} date=$classDateTime cycle=$cycle sessionOrder=$sessionOrder dueCycle=${_resolveCycleByDueDate(agg.studentId, classDateTime)}');
          samplePrinted = true;
        }

        final record = AttendanceRecord.create(
          studentId: agg.studentId,
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
        );

        rows.add({
          'id': record.id,
          'academy_id': academyId,
          'student_id': record.studentId,
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
    }

    if (rows.isEmpty) return;

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

  int _calcCycle(Map<String, DateTime> earliestMonthByKey, String keyBase, DateTime monthDate) {
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


  void _seedDateOrderByStudentCycle(
    Map<String, Map<String, int>> dateOrderByKey,
    Map<String, int> counterByKey,
  ) {
    for (final r in _attendanceRecords) {
      if (r.setId == null || r.setId!.isEmpty || r.cycle == null) continue;
      final studentCycleKey = '${r.studentId}|${r.cycle}';
      final dateKey = _dateKey(r.classDateTime);
      final m = dateOrderByKey.putIfAbsent(studentCycleKey, () => {});
      if (m.containsKey(dateKey)) continue;
      final next = (counterByKey[studentCycleKey] ?? 0) + 1;
      m[dateKey] = next;
      counterByKey[studentCycleKey] = next;
    }
  }

  int? _resolveCycleByDueDate(String studentId, DateTime classDate) {
    final prs = _d
        .getPaymentRecords()
        .where((p) => p.studentId == studentId && p.dueDate != null && p.cycle != null)
        .toList();
    if (prs.isEmpty) return null;
    prs.sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
    final classDateOnly = DateTime(classDate.year, classDate.month, classDate.day);
    for (var i = 0; i < prs.length; i++) {
      final curDue =
          DateTime(prs[i].dueDate!.year, prs[i].dueDate!.month, prs[i].dueDate!.day);
      final nextDue = (i + 1 < prs.length)
          ? DateTime(prs[i + 1].dueDate!.year, prs[i + 1].dueDate!.month,
              prs[i + 1].dueDate!.day)
          : null;
      if (classDateOnly.isBefore(curDue)) continue;
      if (nextDue == null || classDateOnly.isBefore(nextDue)) {
        return prs[i].cycle;
      }
    }
    if (classDateOnly.isBefore(
        DateTime(prs.first.dueDate!.year, prs.first.dueDate!.month, prs.first.dueDate!.day))) {
      return prs.first.cycle ?? 1;
    }
    return prs.last.cycle;
  }

  void _logCycleDebug(String studentId, DateTime classDate) {
    final prs = _d
        .getPaymentRecords()
        .where((p) => p.studentId == studentId && p.dueDate != null && p.cycle != null)
        .toList();
    prs.sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
    final list = prs.map((p) => 'cycle=${p.cycle} due=${p.dueDate}').toList();
    print('[PLAN][CYCLE-DEBUG] student=$studentId date=$classDate payments=${list.join('; ')}');
  }

  void _logCycleDecision({
    required String studentId,
    required String setId,
    required DateTime classDateTime,
    required int? resolvedCycle,
    required int sessionOrderCandidate,
    required String source,
  }) {
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
            b.startMinute == classDateTime.minute,
      );
      return block.setId;
    } catch (_) {
      return null;
    }
  }

  void schedulePlannedRegen(String studentId, String setId, {bool immediate = false}) {
    _pendingRegenSetIdsByStudent.putIfAbsent(studentId, () => <String>{}).add(setId);
    if (immediate) {
      _flushPlannedRegen();
      return;
    }
    _plannedRegenTimer ??= Timer(const Duration(seconds: 1), _flushPlannedRegen);
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
        days: 14,
      );
    }
  }

  Future<void> flushPendingPlannedRegens() async {
    await _flushPlannedRegen();
  }

  Future<void> regeneratePlannedAttendanceForStudentSets({
    required String studentId,
    required Set<String> setIds,
    int days = 14,
  }) =>
      _regeneratePlannedAttendanceForStudentSets(
        studentId: studentId,
        setIds: setIds,
        days: days,
      );

  Future<void> regeneratePlannedAttendanceForStudent({
    required String studentId,
    int days = 14,
  }) async {
    final allSetIds = _d
        .getStudentTimeBlocks()
        .where((b) => b.studentId == studentId && b.setId != null && b.setId!.isNotEmpty)
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
    );
  }

  Future<void> deletePlannedAttendanceForStudent(String studentId, {int days = 14}) async {
    final today = DateTime.now();
    final anchor = DateTime(today.year, today.month, today.day);
    final end = anchor.add(Duration(days: days));
    final academyId =
        await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
    try {
      await Supabase.instance.client
          .from('attendance_records')
          .delete()
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .eq('is_planned', true)
          .gte('class_date_time', anchor.toUtc().toIso8601String())
          .lte('class_date_time', end.toUtc().toIso8601String());
      _attendanceRecords.removeWhere((r) {
        if (r.studentId != studentId) return false;
        if (r.isPlanned != true) return false;
        if (r.arrivalTime != null || r.isPresent) return false;
        return !r.classDateTime.isBefore(anchor) && !r.classDateTime.isAfter(end);
      });
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
    } catch (e, st) {
      print('[WARN] deletePlannedAttendanceForStudent 실패 student=$studentId: $e\n$st');
    }
  }

  Future<void> _regeneratePlannedAttendanceForStudentSets({
    required String studentId,
    required Set<String> setIds,
    int days = 14,
  }) async {
    if (setIds.isEmpty) return;

    final hasPaymentInfo = _d.getPaymentRecords().any((p) => p.studentId == studentId);
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
          .gte('class_date_time', anchor.toUtc().toIso8601String());
      print('[PLAN] deleted planned rows (student): $delRes');
      _attendanceRecords.removeWhere((r) =>
          r.studentId == studentId &&
          setIds.contains(r.setId) &&
          r.isPlanned == true &&
          !r.isPresent &&
          r.arrivalTime == null &&
          !r.classDateTime.isBefore(anchor));
    } catch (e) {
      print('[WARN] planned 삭제 실패(student=$studentId setIds=$setIds): $e');
    }

    final blocks = _d
        .getStudentTimeBlocks()
        .where((b) => b.studentId == studentId && b.setId != null && setIds.contains(b.setId))
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
    final Map<String, Map<String, int>> dateOrderByKey = {};
    final Map<String, int> counterByKey = {};
    _seedDateOrderBySetCycle(dateOrderByKey, counterByKey);
    final Map<String, Map<String, int>> dateOrderByStudentCycle = {};
    final Map<String, int> counterByStudentCycle = {};
    _seedDateOrderByStudentCycle(dateOrderByStudentCycle, counterByStudentCycle);

    bool samplePrinted = false;
    int decisionLogCount = 0;
    for (int i = 0; i < days; i++) {
      final date = anchor.add(Duration(days: i));
      final int dayIdx = date.weekday - 1;
      for (final b in blocks.where((b) => b.dayIndex == dayIdx)) {
        final classDateTime =
            DateTime(date.year, date.month, date.day, b.startHour, b.startMinute);
        final classEndTime = classDateTime.add(b.duration);

        final existing = getAttendanceRecord(studentId, classDateTime);
        if (existing != null &&
            (!existing.isPlanned || existing.arrivalTime != null || existing.isPresent)) {
          continue;
        }

        final keyBase = '$studentId|${b.setId}';
        final dateKey = _dateKey(classDateTime);

        int? cycle = _resolveCycleByDueDate(studentId, classDateTime);
        int sessionOrder;
        if (cycle == null) {
          final monthDate = _monthKey(classDateTime);
          cycle = _calcCycle(earliestMonthByKey, keyBase, monthDate);
        }
        final studentCycleKey = '$studentId|$cycle';
        final m = dateOrderByStudentCycle.putIfAbsent(studentCycleKey, () => {});
        if (m.containsKey(dateKey)) {
          sessionOrder = m[dateKey]!;
        } else {
          final next = (counterByStudentCycle[studentCycleKey] ?? 0) + 1;
          m[dateKey] = next;
          counterByStudentCycle[studentCycleKey] = next;
          sessionOrder = next;
        }
        if (cycle == null || cycle == 0) {
          print(
              '[WARN][PLAN-student] cycle null/0 → 1 set=${b.setId} student=$studentId date=$classDateTime (payment_records miss?)');
          _logCycleDebug(studentId, classDateTime);
          cycle = 1;
        }
        if (sessionOrder <= 0) {
          print(
              '[WARN][PLAN-student] sessionOrder<=0 → 1 set=${b.setId} student=$studentId date=$classDateTime');
          sessionOrder = 1;
        }
        if (decisionLogCount < 3 || cycle == null || cycle == 0 || sessionOrder <= 0) {
          _logCycleDecision(
            studentId: studentId,
            setId: b.setId ?? '',
            classDateTime: classDateTime,
            resolvedCycle: cycle,
            sessionOrderCandidate: sessionOrder,
            source: 'plan-student',
          );
          decisionLogCount++;
        }
        if (!samplePrinted) {
          print(
              '[PLAN][SAMPLE-student] set=${b.setId} student=$studentId date=$classDateTime cycle=$cycle sessionOrder=$sessionOrder dueCycle=${_resolveCycleByDueDate(studentId, classDateTime)}');
          samplePrinted = true;
        }

        final record = AttendanceRecord.create(
          studentId: studentId,
          classDateTime: classDateTime,
          classEndTime: classEndTime,
          className: _resolveClassName(b.sessionTypeId),
          isPresent: false,
          arrivalTime: null,
          departureTime: null,
          notes: null,
          sessionTypeId: b.sessionTypeId,
          setId: b.setId,
          cycle: cycle,
          sessionOrder: sessionOrder,
          isPlanned: true,
        );

        rows.add({
          'id': record.id,
          'academy_id': academyId,
          'student_id': record.studentId,
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
          'created_at': record.createdAt.toUtc().toIso8601String(),
          'updated_at': record.updatedAt.toUtc().toIso8601String(),
          'version': record.version,
        });
        localAdds.add(record);
      }
    }

    if (rows.isEmpty) {
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      return;
    }

    try {
      final upRes = await supa.from('attendance_records').upsert(rows, onConflict: 'id');
      _attendanceRecords.addAll(localAdds);
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      print('[PLAN] regen(student) done setIds=$setIds added=${localAdds.length} rowsResp=$upRes');
    } catch (e, st) {
      print('[ERROR] 예정 출석 upsert 실패(student=$studentId setIds=$setIds): $e\n$st');
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
        counterByKey[key] =
            next > (counterByKey[key] ?? 0) ? next : (counterByKey[key] ?? next);
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
  }) async {
    final now = DateTime.now();
    final resolvedSetId = setId ?? _resolveSetId(studentId, classDateTime);
    final existing = getAttendanceRecord(studentId, classDateTime);
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
      final idx = _attendanceRecords.indexWhere((r) => r.studentId == studentId &&
          r.classDateTime.year == classDateTime.year &&
          r.classDateTime.month == classDateTime.month &&
          r.classDateTime.day == classDateTime.day &&
          r.classDateTime.hour == classDateTime.hour &&
          r.classDateTime.minute == classDateTime.minute);
      if (idx != -1) {
        _attendanceRecords[idx] = updated;
        attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
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
    } else {
      final newRecord = AttendanceRecord.create(
        studentId: studentId,
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
      if (!(o.overrideType == OverrideType.add || o.overrideType == OverrideType.replace)) {
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
  }

  Future<void> regeneratePlannedAttendanceForOverride(SessionOverride ov) async {
    if (ov.replacementClassDateTime == null) return;
    if (ov.status == OverrideStatus.canceled) {
      await removePlannedAttendanceForDate(
          studentId: ov.studentId, classDateTime: ov.replacementClassDateTime!);
      return;
    }
    final DateTime target = ov.replacementClassDateTime!;
    await removePlannedAttendanceForDate(studentId: ov.studentId, classDateTime: target);

    int? cycle = _resolveCycleByDueDate(ov.studentId, target);
    int sessionOrder;
    if (cycle != null) {
      final setCycleKey = '${(ov.setId ?? ov.id)}|$cycle';
      final dateKey = _dateKey(target);
      final Map<String, Map<String, int>> dateOrderByKey = {};
      final Map<String, int> counterByKey = {};
      _seedDateOrderBySetCycle(dateOrderByKey, counterByKey);
      final m = dateOrderByKey.putIfAbsent(setCycleKey, () => {});
      if (m.containsKey(dateKey)) {
        sessionOrder = m[dateKey]!;
      } else {
        final next = (counterByKey[setCycleKey] ?? 0) + 1;
        m[dateKey] = next;
        counterByKey[setCycleKey] = next;
        sessionOrder = next;
      }
    } else {
      final Map<String, DateTime> earliestMonthByKey = {};
      final Map<String, int> monthCountByKey = {};
      _seedCycleMaps(earliestMonthByKey, monthCountByKey);
      final keyBase = '${ov.studentId}|${(ov.setId ?? ov.id)}';
      final monthDate = _monthKey(target);
      cycle = _calcCycle(earliestMonthByKey, keyBase, monthDate);
      final setCycleKey = '${(ov.setId ?? ov.id)}|$cycle';
      final dateKey = _dateKey(target);
      final Map<String, Map<String, int>> dateOrderByKey = {};
      final Map<String, int> counterByKey = {};
      _seedDateOrderBySetCycle(dateOrderByKey, counterByKey);
      final m = dateOrderByKey.putIfAbsent(setCycleKey, () => {});
      if (m.containsKey(dateKey)) {
        sessionOrder = m[dateKey]!;
      } else {
        final next = (counterByKey[setCycleKey] ?? 0) + 1;
        m[dateKey] = next;
        counterByKey[setCycleKey] = next;
        sessionOrder = next;
      }
    }
    if (cycle == null || cycle == 0) {
      print(
          '[WARN][PLAN][OVR] cycle null/0 → 1 set=${ov.setId ?? ov.id} student=${ov.studentId} date=$target (payment_records miss?)');
      cycle = 1;
    }
    if (sessionOrder <= 0) {
      print(
          '[WARN][PLAN][OVR] sessionOrder<=0 → 1 set=${ov.setId ?? ov.id} student=${ov.studentId} date=$target');
      sessionOrder = 1;
    }

    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    final classEndTime =
        target.add(Duration(minutes: ov.durationMinutes ?? _d.getAcademySettings().lessonDuration));
    final record = AttendanceRecord.create(
      studentId: ov.studentId,
      classDateTime: target,
      classEndTime: classEndTime,
      className: _resolveClassName(ov.sessionTypeId),
      isPresent: false,
      arrivalTime: null,
      departureTime: null,
      notes: null,
      sessionTypeId: ov.sessionTypeId,
      setId: ov.setId ?? ov.id,
      cycle: cycle,
      sessionOrder: sessionOrder,
      isPlanned: true,
    );

    final row = {
      'id': record.id,
      'academy_id': academyId,
      'student_id': record.studentId,
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
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'updated_at': record.updatedAt.toUtc().toIso8601String(),
      'version': record.version,
    };

    try {
      await Supabase.instance.client.from('attendance_records').upsert(row, onConflict: 'id');
      _attendanceRecords.add(record);
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      print('[INFO] override planned regenerated: student=${ov.studentId}, date=$target');
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
    try {
      await Supabase.instance.client
          .from('attendance_records')
          .delete()
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .eq('is_planned', true)
          .eq('class_date_time', classDateTime.toUtc().toIso8601String());
      _attendanceRecords.removeWhere((r) =>
          r.studentId == studentId &&
          r.isPlanned == true &&
          r.classDateTime.year == classDateTime.year &&
          r.classDateTime.month == classDateTime.month &&
          r.classDateTime.day == classDateTime.day &&
          r.classDateTime.hour == classDateTime.hour &&
          r.classDateTime.minute == classDateTime.minute);
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
    } catch (e) {
      print('[WARN] planned 제거 실패(student=$studentId, dt=$classDateTime): $e');
    }
  }

  Future<void> regeneratePlannedAttendanceForSet({
    required String studentId,
    required String setId,
    int days = 14,
  }) async {
    if (setId.isEmpty) return;

    final hasPaymentInfo = _d.getPaymentRecords().any((p) => p.studentId == studentId);
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
          .gte('class_date_time', anchor.toUtc().toIso8601String());
      print('[PLAN] deleted planned rows: $delRes');
      _attendanceRecords.removeWhere((r) =>
          r.studentId == studentId &&
          r.setId == setId &&
          r.isPlanned == true &&
          !r.isPresent &&
          r.arrivalTime == null &&
          !r.classDateTime.isBefore(anchor));
    } catch (e) {
      print('[WARN] planned 삭제 실패(student=$studentId set=$setId): $e');
    }

    final blocks = _d
        .getStudentTimeBlocks()
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
    final Map<String, Map<String, int>> dateOrderByKey = {};
    final Map<String, int> counterByKey = {};
    _seedDateOrderBySetCycle(dateOrderByKey, counterByKey);
    final Map<String, Map<String, int>> dateOrderByStudentCycle = {};
    final Map<String, int> counterByStudentCycle = {};
    _seedDateOrderByStudentCycle(dateOrderByStudentCycle, counterByStudentCycle);

    // 중복 생성 방지: 하루/세트 키
    final Set<String> existingPlannedKeys = {};

    bool samplePrinted = false;
    int decisionLogCount = 0;
    for (int i = 0; i < days; i++) {
      final date = anchor.add(Duration(days: i));
      final int dayIdx = date.weekday - 1;

      final Map<String, _PlannedDailyAgg> aggBySet = {};
      for (final b in blocks.where((b) => b.dayIndex == dayIdx)) {
        final classStart = DateTime(date.year, date.month, date.day, b.startHour, b.startMinute);
        final classEnd = classStart.add(b.duration);

        final existing = getAttendanceRecord(studentId, classStart);
        if (existing != null &&
            (!existing.isPlanned || existing.arrivalTime != null || existing.isPresent)) {
          continue;
        }

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
        final classDateTime =
            DateTime(agg.start.year, agg.start.month, agg.start.day, agg.start.hour, agg.start.minute);
        final classEndTime = agg.end;

        final keyBase = '$studentId|$setId';
        final dateKey = _dateKey(classDateTime);

        int? cycle = _resolveCycleByDueDate(studentId, classDateTime);
        int sessionOrder;
        if (cycle == null) {
          final monthDate = _monthKey(classDateTime);
          cycle = _calcCycle(earliestMonthByKey, keyBase, monthDate);
        }
        final studentCycleKey = '$studentId|$cycle';
        final m = dateOrderByStudentCycle.putIfAbsent(studentCycleKey, () => {});
        if (m.containsKey(dateKey)) {
          sessionOrder = m[dateKey]!;
        } else {
          final next = (counterByStudentCycle[studentCycleKey] ?? 0) + 1;
          m[dateKey] = next;
          counterByStudentCycle[studentCycleKey] = next;
          sessionOrder = next;
        }
        if (cycle == null || cycle == 0) {
          print(
              '[WARN][PLAN-set] cycle null/0 → 1 set=$setId student=$studentId date=$classDateTime (payment_records miss?)');
          _logCycleDebug(studentId, classDateTime);
          cycle = 1;
        }
        if (sessionOrder <= 0) {
          print(
              '[WARN][PLAN-set] sessionOrder<=0 → 1 set=$setId student=$studentId date=$classDateTime');
          sessionOrder = 1;
        }
        final plannedKey = '$studentId|$setId|${_dateKey(classDateTime)}';
        if (existingPlannedKeys.contains(plannedKey)) {
          if (_sideDebug) {
            print('[PLAN-set][skip-dup] setId=$setId student=$studentId date=$classDateTime');
          }
          continue;
        }
        existingPlannedKeys.add(plannedKey);
        if (decisionLogCount < 3 || cycle == null || cycle == 0 || sessionOrder <= 0) {
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
        if (!samplePrinted) {
          print(
              '[PLAN][SAMPLE-set] set=$setId student=$studentId date=$classDateTime cycle=$cycle sessionOrder=$sessionOrder dueCycle=${_resolveCycleByDueDate(studentId, classDateTime)}');
          samplePrinted = true;
        }

        final record = AttendanceRecord.create(
          studentId: studentId,
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
        );

        rows.add({
          'id': record.id,
          'academy_id': academyId,
          'student_id': record.studentId,
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

    try {
      final upRes = await supa.from('attendance_records').upsert(rows, onConflict: 'id');
      _attendanceRecords.addAll(localAdds);
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      print('[PLAN] regen done set_id=$setId added=${localAdds.length} rowsResp=$upRes');
    } catch (e, st) {
      print('[ERROR] set_id=$setId 예정 출석 upsert 실패: $e\n$st');
    }
  }

  Future<void> fixMissingDeparturesForYesterdayKst() async {
    try {
      final int lessonMinutes = _d.getAcademySettings().lessonDuration;
      final DateTime nowKst = DateTime.now().toUtc().add(const Duration(hours: 9));
      final DateTime ymdYesterdayKst =
          DateTime(nowKst.year, nowKst.month, nowKst.day).subtract(const Duration(days: 1));

      bool isSameKstDay(DateTime dt, DateTime ymdKst) {
        final k = dt.toUtc().add(const Duration(hours: 9));
        return k.year == ymdKst.year && k.month == ymdKst.month && k.day == ymdKst.day;
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
}

