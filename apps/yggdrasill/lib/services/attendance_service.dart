import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/attendance_record.dart';
import '../models/class_info.dart';
import '../models/cycle_attendance_summary.dart';
import '../models/payment_record.dart';
import '../models/session_override.dart';
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
    if (_sideDebug) {
      print('[ATT][reset] attendanceRecords cleared');
    }
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
              'id,student_id,class_date_time,class_end_time,class_name,is_present,arrival_time,departure_time,notes,session_type_id,set_id,cycle,session_order,is_planned,snapshot_id,batch_session_id,created_at,updated_at,version')
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
          snapshotId: m['snapshot_id'] as String?,
          batchSessionId: m['batch_session_id'] as String?,
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
      if (_sideDebug) {
        print('[ATT][loadAttendanceRecords][error] publish empty');
      }
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
                snapshotId: m['snapshot_id'] as String?,
                batchSessionId: m['batch_session_id'] as String?,
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
                snapshotId: m['snapshot_id'] as String? ?? _attendanceRecords[idx].snapshotId,
                batchSessionId:
                    m['batch_session_id'] as String? ?? _attendanceRecords[idx].batchSessionId,
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
      'snapshot_id': record.snapshotId,
      'batch_session_id': record.batchSessionId,
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
      final bool wasConsumed =
          prevState == 'completed' || prevState == 'no_show' || prevState == 'replaced';

      await supa.from('lesson_batch_sessions').update({
        'state': state,
        'attendance_id': attendanceId,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', batchSessionId);

      final bool nowConsumed = state == 'completed' || state == 'no_show' || state == 'replaced';
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
              final DateTime maxPlan =
                  DateTime.tryParse(maxPlanStr)?.toUtc() ?? DateTime.now().toUtc();
              nextReg = maxPlan.add(Duration(days: termDays));
            }
          }
          await supa.from('lesson_batch_headers').update({
            'consumed_sessions': consumed + 1,
            if (nextReg != null) 'next_registration_date': nextReg.toIso8601String().split('T').first,
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
      print('[PLAN][WARN] planned 삭제 실패(student=$studentId sets=$setIds): $e\n$st');
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
      print('[PLAN][cancel-done] student=$studentId removed=${beforeLocal - afterLocal} localAfter=$afterLocal');
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
      print('[BATCH][WARN] planned 세션 삭제 실패(student=$studentId sets=$setIds): $e\n$st');
    }
  }

  Future<void> replanRemainingForStudentSets({
    required String studentId,
    required Set<String> setIds,
    int days = 60,
    DateTime? anchor,
    String? snapshotId,
    List<StudentTimeBlock>? blocksOverride,
  }) async {
    final DateTime effectiveAnchor = anchor ?? DateTime.now().toUtc();
    await _cancelPlannedForSets(studentId: studentId, setIds: setIds, anchor: effectiveAnchor);
    await regeneratePlannedAttendanceForStudentSets(
      studentId: studentId,
      setIds: setIds,
      days: days,
      snapshotId: snapshotId,
      blocksOverride: blocksOverride,
    );
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
    final start = DateTime(block.startDate.year, block.startDate.month, block.startDate.day);
    final end = block.endDate != null
        ? DateTime(block.endDate!.year, block.endDate!.month, block.endDate!.day)
        : null;
    return !start.isAfter(target) && (end == null || !end.isBefore(target));
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

    // ✅ 글로벌 planned 생성기는 "삭제"하지 않는다.
    // - 변경/예약/휴강 등으로 인한 planned 정리는 set_id 단위 regen에서만 수행(범위/스냅샷 유지)
    // - 여기서는 누락된 planned만 추가 생성하여 중복/증식을 방지한다.

    try {
      await _d.loadPaymentRecords();
    } catch (_) {}

    String minKey(DateTime dt) =>
        '${dt.year}-${dt.month}-${dt.day}-${dt.hour}-${dt.minute}';

    // ===== SessionOverride 반영 =====
    // - skip/replace(원래 회차): 해당 분(minute)에 planned 생성 제외
    // - add/replace(대체/추가 회차): replacement 분(minute)에 planned 생성 추가
    final Map<String, SessionOverride> overrideByOriginalKey = {};
    final Map<String, List<SessionOverride>> overridesByReplacementDate = {};
    for (final o in _d.getSessionOverrides()) {
      if (o.status != OverrideStatus.planned) continue;
      final orig = o.originalClassDateTime;
      if ((o.overrideType == OverrideType.skip || o.overrideType == OverrideType.replace) &&
          orig != null) {
        overrideByOriginalKey['${o.studentId}|${minKey(orig)}'] = o;
      }
      final rep = o.replacementClassDateTime;
      if ((o.overrideType == OverrideType.add || o.overrideType == OverrideType.replace) &&
          rep != null) {
        overridesByReplacementDate.putIfAbsent(_dateKey(rep), () => <SessionOverride>[]).add(o);
      }
    }

    final List<Map<String, dynamic>> rows = [];
    final List<AttendanceRecord> localAdds = [];

    final Map<String, DateTime> earliestMonthByKey = {};
    final Map<String, int> monthCountByKey = {};
    _seedCycleMaps(earliestMonthByKey, monthCountByKey);
    final Map<String, Map<String, int>> dateOrderByStudentCycle = {};
    final Map<String, int> counterByStudentCycle = {};
    _seedDateOrderByStudentCycle(dateOrderByStudentCycle, counterByStudentCycle);

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
        print('[PLAN][existing-keys] via rpc keys=${existingPlannedKeys.length} rangeUtc=$fromUtc..$toUtc');
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
        final classDate = DateTime(r.classDateTime.year, r.classDateTime.month, r.classDateTime.day);
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
        if (!_isBlockActiveOnDate(b, date)) continue;
        final classStart = DateTime(date.year, date.month, date.day, b.startHour, b.startMinute);
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

      for (final agg in aggBySet.values) {
        final classDateTime = agg.start;
        final classEndTime = agg.end;
        final keyBase = '${agg.studentId}|${agg.setId}';
        final dateKey = _dateKey(classDateTime);

        // ✅ 휴강/대체(원래 회차)면 base planned는 만들지 않는다.
        final ov = overrideByOriginalKey['${agg.studentId}|${minKey(classDateTime)}'];
        if (ov != null &&
            (ov.overrideType == OverrideType.skip || ov.overrideType == OverrideType.replace)) {
          if (_sideDebug) {
            print('[PLAN][skip-base-by-override] type=${ov.overrideType} student=${agg.studentId} dt=$classDateTime');
          }
          continue;
        }

        // ✅ 이미 실제 기록(출석/등원 등)이 있으면 planned 생성하지 않음
        final existingAtStart = getAttendanceRecord(agg.studentId, classDateTime);
        if (existingAtStart != null &&
            (!existingAtStart.isPlanned ||
                existingAtStart.arrivalTime != null ||
                existingAtStart.isPresent)) {
          continue;
        }

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
          'snapshot_id': null,
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
      final repList = overridesByReplacementDate[_dateKey(date)] ?? const <SessionOverride>[];
      for (final o in repList) {
        final rep = o.replacementClassDateTime;
        if (rep == null) continue;
        if (rep.year != date.year || rep.month != date.month || rep.day != date.day) continue;

        final start = DateTime(rep.year, rep.month, rep.day, rep.hour, rep.minute);
        // 이미 실제 기록이 있으면 planned 생성 불필요
        final existing = getAttendanceRecord(o.studentId, start);
        if (existing != null &&
            (!existing.isPlanned || existing.arrivalTime != null || existing.isPresent)) {
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

        final durMin = o.durationMinutes ?? _d.getAcademySettings().lessonDuration;
        final end = start.add(Duration(minutes: durMin));

        int? cycle = _resolveCycleByDueDate(o.studentId, start);
        int sessionOrder;
        if (cycle == null) {
          final monthDate = _monthKey(start);
          final keyBase = '${o.studentId}|$setId';
          cycle = _calcCycle(earliestMonthByKey, keyBase, monthDate);
        }
        final studentCycleKey = '${o.studentId}|$cycle';
        final m = dateOrderByStudentCycle.putIfAbsent(studentCycleKey, () => {});
        final dateKey = _dateKey(start);
        if (m.containsKey(dateKey)) {
          sessionOrder = m[dateKey]!;
        } else {
          final next = (counterByStudentCycle[studentCycleKey] ?? 0) + 1;
          m[dateKey] = next;
          counterByStudentCycle[studentCycleKey] = next;
          sessionOrder = next;
        }
        if (cycle == null || cycle == 0) cycle = 1;
        if (sessionOrder <= 0) sessionOrder = 1;

        final record = AttendanceRecord.create(
          studentId: o.studentId,
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
          snapshotId: null,
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
          'snapshot_id': null,
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
      final updated = rec.copyWith(batchSessionId: batchSessionByRecordId[rec.id]);
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
            b.startMinute == classDateTime.minute &&
            _isBlockActiveOnDate(b, classDateTime),
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
    int days = 14,
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
    int days = 14,
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

  Future<void> deletePlannedAttendanceForStudent(String studentId, {int days = 14}) async {
    final today = DateTime.now();
    final anchor = DateTime(today.year, today.month, today.day);
    final end = anchor.add(Duration(days: days));
    final academyId =
        await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
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
        if (r.classDateTime.isBefore(anchor) || r.classDateTime.isAfter(end)) continue;
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
        return !r.classDateTime.isBefore(anchor) && !r.classDateTime.isAfter(end);
      });
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      if (_sideDebug) {
        final afterLocal = _attendanceRecords.length;
        print('[PLAN][delete-student-done] student=$studentId removed=${beforeLocal - afterLocal} localAfter=$afterLocal');
      }
    } catch (e, st) {
      print('[WARN] deletePlannedAttendanceForStudent 실패 student=$studentId: $e\n$st');
    }
  }

  Future<void> _regeneratePlannedAttendanceForStudentSets({
    required String studentId,
    required Set<String> setIds,
    int days = 14,
    String? snapshotId,
    List<StudentTimeBlock>? blocksOverride,
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
          // ⚠️ 순수 planned만 삭제 (실제 출석/등원 기록 보호)
          .eq('is_present', false)
          .isFilter('arrival_time', null)
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

    final blocks = (blocksOverride ?? _d.getStudentTimeBlocks())
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

    String minKey(DateTime dt) =>
        '${dt.year}-${dt.month}-${dt.day}-${dt.hour}-${dt.minute}';

    // ===== SessionOverride 반영(학생 단위) =====
    final Map<String, SessionOverride> overrideByOriginalKey = {};
    final Map<String, List<SessionOverride>> overridesByReplacementDate = {};
    for (final o in _d.getSessionOverrides()) {
      if (o.studentId != studentId) continue;
      if (o.status != OverrideStatus.planned) continue;
      final orig = o.originalClassDateTime;
      if ((o.overrideType == OverrideType.skip || o.overrideType == OverrideType.replace) &&
          orig != null) {
        overrideByOriginalKey['$studentId|${minKey(orig)}'] = o;
      }
      final rep = o.replacementClassDateTime;
      if ((o.overrideType == OverrideType.add || o.overrideType == OverrideType.replace) &&
          rep != null) {
        overridesByReplacementDate.putIfAbsent(_dateKey(rep), () => <SessionOverride>[]).add(o);
      }
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
      final classDate = DateTime(r.classDateTime.year, r.classDateTime.month, r.classDateTime.day);
      if (classDate.isBefore(anchor)) continue;
      existingPlannedKeys.add('$studentId|${r.setId}|${_dateKey(r.classDateTime)}');
    }

    bool samplePrinted = false;
    int decisionLogCount = 0;
    for (int i = 0; i < days; i++) {
      final date = anchor.add(Duration(days: i));
      final int dayIdx = date.weekday - 1;

      // 하루/세트(set_id) 단위로 묶어 1회 수업=1레코드 생성
      final Map<String, _PlannedDailyAgg> aggBySet = {};
      for (final b in blocks.where((b) => b.dayIndex == dayIdx)) {
        if (!_isBlockActiveOnDate(b, date)) continue;
        final setId = b.setId;
        if (setId == null || setId.isEmpty) continue;
        final classStart = DateTime(date.year, date.month, date.day, b.startHour, b.startMinute);
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
        final classDateTime = agg.start;
        final classEndTime = agg.end;
        final keyBase = '$studentId|${agg.setId}';
        final dateKey = _dateKey(classDateTime);

        // ✅ 휴강/대체(원래 회차)면 base planned는 만들지 않는다.
        final ov = overrideByOriginalKey['$studentId|${minKey(classDateTime)}'];
        if (ov != null &&
            (ov.overrideType == OverrideType.skip || ov.overrideType == OverrideType.replace)) {
          if (_sideDebug) {
            print('[PLAN-student][skip-base-by-override] type=${ov.overrideType} student=$studentId dt=$classDateTime');
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
              '[WARN][PLAN-student] cycle null/0 → 1 set=${agg.setId} student=$studentId date=$classDateTime (payment_records miss?)');
          _logCycleDebug(studentId, classDateTime);
          cycle = 1;
        }
        if (sessionOrder <= 0) {
          print(
              '[WARN][PLAN-student] sessionOrder<=0 → 1 set=${agg.setId} student=$studentId date=$classDateTime');
          sessionOrder = 1;
        }
        if (decisionLogCount < 3 || cycle == null || cycle == 0 || sessionOrder <= 0) {
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
        if (!samplePrinted) {
          print(
              '[PLAN][SAMPLE-student] set=${agg.setId} student=$studentId date=$classDateTime cycle=$cycle sessionOrder=$sessionOrder dueCycle=${_resolveCycleByDueDate(studentId, classDateTime)}');
          samplePrinted = true;
        }

        final plannedKey = '$studentId|${agg.setId}|${_dateKey(classDateTime)}';
        if (existingPlannedKeys.contains(plannedKey)) {
          if (_sideDebug) {
            print('[PLAN-student][skip-dup] setId=${agg.setId} student=$studentId date=$classDateTime');
          }
          continue;
        }
        existingPlannedKeys.add(plannedKey);

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
      final repList = overridesByReplacementDate[_dateKey(date)] ?? const <SessionOverride>[];
      for (final o in repList) {
        final rep = o.replacementClassDateTime;
        if (rep == null) continue;
        if (rep.year != date.year || rep.month != date.month || rep.day != date.day) continue;

        final start = DateTime(rep.year, rep.month, rep.day, rep.hour, rep.minute);
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
            (!existing.isPlanned || existing.arrivalTime != null || existing.isPresent)) {
          continue;
        }

        final durMin = o.durationMinutes ?? _d.getAcademySettings().lessonDuration;
        final end = start.add(Duration(minutes: durMin));

        int? cycle = _resolveCycleByDueDate(studentId, start);
        int sessionOrder;
        if (cycle == null) {
          final monthDate = _monthKey(start);
          final keyBase = '$studentId|$setId';
          cycle = _calcCycle(earliestMonthByKey, keyBase, monthDate);
        }
        final studentCycleKey = '$studentId|$cycle';
        final m = dateOrderByStudentCycle.putIfAbsent(studentCycleKey, () => {});
        final dateKey = _dateKey(start);
        if (m.containsKey(dateKey)) {
          sessionOrder = m[dateKey]!;
        } else {
          final next = (counterByStudentCycle[studentCycleKey] ?? 0) + 1;
          m[dateKey] = next;
          counterByStudentCycle[studentCycleKey] = next;
          sessionOrder = next;
        }
        if (cycle == null || cycle == 0) cycle = 1;
        if (sessionOrder <= 0) sessionOrder = 1;

        final record = AttendanceRecord.create(
          studentId: studentId,
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
    final Map<String, String> batchSessionByRecordId = await _createBatchSessionsForPlanned(
      studentId: studentId,
      plannedRecords: localAdds,
      snapshotId: snapshotId,
    );
    for (int i = 0; i < localAdds.length; i++) {
      final rec = localAdds[i];
      final updated = rec.copyWith(batchSessionId: batchSessionByRecordId[rec.id]);
      localAdds[i] = updated;
      rows[i]['batch_session_id'] = updated.batchSessionId;
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
    String? snapshotId,
    String? batchSessionId,
  }) async {
    final now = DateTime.now();
    final resolvedSetId = setId ?? _resolveSetId(studentId, classDateTime);
    final existing = getAttendanceRecord(studentId, classDateTime);
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
      // 동일 시각 planned가 있으면 snapshot_id를 이어받는다.
      final planned = _attendanceRecords.firstWhere(
        (r) =>
            r.studentId == studentId &&
            r.classDateTime.year == classDateTime.year &&
            r.classDateTime.month == classDateTime.month &&
            r.classDateTime.day == classDateTime.day &&
            r.classDateTime.hour == classDateTime.hour &&
            r.classDateTime.minute == classDateTime.minute &&
            r.isPlanned,
        orElse: () => AttendanceRecord.create(
          studentId: studentId,
          classDateTime: classDateTime,
          classEndTime: classEndTime,
          className: className,
          isPresent: false,
        ),
      );
      final plannedSnapshotId = planned.snapshotId;
      final plannedBatchSessionId = planned.batchSessionId;

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
        snapshotId: resolvedSnapshotId ?? plannedSnapshotId,
        batchSessionId: resolvedBatchSessionId ?? plannedBatchSessionId,
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

    // 기존 또는 새 레코드에 batch_session_id가 있다면 상태 갱신
    final targetBatchSessionId =
        resolvedBatchSessionId ?? existing?.batchSessionId;
    if (targetBatchSessionId != null) {
      await _updateBatchSessionState(
        batchSessionId: targetBatchSessionId,
        state: isPresent ? 'completed' : 'planned',
        attendanceId: existing?.id,
      );
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
    final DateTime? original = ov.originalClassDateTime;
    final DateTime? replacement = ov.replacementClassDateTime;
    final bool canceled = ov.status == OverrideStatus.canceled;

    // 공통: 원래 회차(휴강/대체) planned 제거 (순수 planned만)
    Future<void> _removeOriginalPlannedIfNeeded() async {
      if (original == null) return;
      await removePlannedAttendanceForDate(studentId: ov.studentId, classDateTime: original);
    }

    // 공통: 스케줄 기반으로 원래 회차 planned를 복원(취소 시)
    Future<void> _restoreOriginalPlannedIfPossible() async {
      if (original == null) return;

      final now = DateTime.now();
      final anchor = DateTime(now.year, now.month, now.day);
      final end = anchor.add(const Duration(days: 14));
      final dateOnly = DateTime(original.year, original.month, original.day);
      if (dateOnly.isBefore(anchor) || dateOnly.isAfter(end)) {
        // planned 유지 범위(다음 14일) 밖은 글로벌 생성기에 맡김
        return;
      }

      final String? inferredSetId = ov.setId ?? _resolveSetId(ov.studentId, original);
      if (inferredSetId == null || inferredSetId.isEmpty) return;

      final dayIdx = original.weekday - 1;
      final allBlocks = _d.getStudentTimeBlocks();
      final cand = allBlocks.where((b) =>
          b.studentId == ov.studentId &&
          b.setId == inferredSetId &&
          b.dayIndex == dayIdx &&
          _isBlockActiveOnDate(b, dateOnly)).toList();
      if (cand.isEmpty) return;

      DateTime? minStart;
      DateTime? maxEnd;
      String? sessionTypeId;
      for (final b in cand) {
        final s = DateTime(dateOnly.year, dateOnly.month, dateOnly.day, b.startHour, b.startMinute);
        final e = s.add(b.duration);
        if (minStart == null || s.isBefore(minStart)) minStart = s;
        if (maxEnd == null || e.isAfter(maxEnd)) maxEnd = e;
        sessionTypeId ??= b.sessionTypeId;
      }
      if (minStart == null || maxEnd == null) return;

      // 이미 실제 기록이 있으면 복원하지 않음
      final existing = getAttendanceRecord(ov.studentId, minStart);
      if (existing != null && (!existing.isPlanned || existing.arrivalTime != null || existing.isPresent)) {
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

      // session_order 계산: student+cycle 기준
      int? cycle = _resolveCycleByDueDate(ov.studentId, minStart);
      if (cycle == null) {
        final Map<String, DateTime> earliestMonthByKey = {};
        final Map<String, int> monthCountByKey = {};
        _seedCycleMaps(earliestMonthByKey, monthCountByKey);
        cycle = _calcCycle(earliestMonthByKey, '${ov.studentId}|$inferredSetId', _monthKey(minStart));
      }
      final Map<String, Map<String, int>> dateOrderByStudentCycle = {};
      final Map<String, int> counterByStudentCycle = {};
      _seedDateOrderByStudentCycle(dateOrderByStudentCycle, counterByStudentCycle);
      final studentCycleKey = '${ov.studentId}|$cycle';
      final m = dateOrderByStudentCycle.putIfAbsent(studentCycleKey, () => {});
      final dateKey = _dateKey(minStart);
      final int sessionOrder = m.containsKey(dateKey)
          ? m[dateKey]!
          : ((counterByStudentCycle[studentCycleKey] ?? 0) + 1);

      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final record = AttendanceRecord.create(
        studentId: ov.studentId,
        classDateTime: minStart,
        classEndTime: maxEnd,
        className: _resolveClassName(sessionTypeId),
        isPresent: false,
        arrivalTime: null,
        departureTime: null,
        notes: null,
        sessionTypeId: sessionTypeId,
        setId: inferredSetId,
        cycle: (cycle == null || cycle == 0) ? 1 : cycle,
        sessionOrder: sessionOrder <= 0 ? 1 : sessionOrder,
        isPlanned: true,
        snapshotId: null,
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
        'snapshot_id': null,
        'batch_session_id': record.batchSessionId,
        'created_at': record.createdAt.toUtc().toIso8601String(),
        'updated_at': record.updatedAt.toUtc().toIso8601String(),
        'version': record.version,
      };
      try {
        await Supabase.instance.client.from('attendance_records').upsert(row, onConflict: 'id');
        _attendanceRecords.add(record);
        attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
        if (_sideDebug) {
          print('[PLAN][override][restore-base] student=${ov.studentId} dt=$minStart setId=$inferredSetId');
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
        await removePlannedAttendanceForDate(studentId: ov.studentId, classDateTime: replacement);
        await _restoreOriginalPlannedIfPossible();
        return;
      }
      // planned 상태: replacement planned 생성(중복은 remove→upsert로 정리)
      await removePlannedAttendanceForDate(studentId: ov.studentId, classDateTime: replacement);
    }

    // 3) 추가(add) 또는 replace의 replacement 생성
    if (replacement == null) return;
    if (canceled) {
      await removePlannedAttendanceForDate(studentId: ov.studentId, classDateTime: replacement);
      return;
    }

    final DateTime target = replacement;

    // set_id: replace는 원래 세트로, add는 override id(또는 명시 set_id)
    final String setId = () {
      if (ov.overrideType == OverrideType.replace) {
        return ov.setId ?? _resolveSetId(ov.studentId, ov.originalClassDateTime ?? target) ?? ov.id;
      }
      return ov.setId ?? ov.id;
    }();

    int? cycle = _resolveCycleByDueDate(ov.studentId, target);
    if (cycle == null) {
      final Map<String, DateTime> earliestMonthByKey = {};
      final Map<String, int> monthCountByKey = {};
      _seedCycleMaps(earliestMonthByKey, monthCountByKey);
      cycle = _calcCycle(earliestMonthByKey, '${ov.studentId}|$setId', _monthKey(target));
    }
    final Map<String, Map<String, int>> dateOrderByStudentCycle = {};
    final Map<String, int> counterByStudentCycle = {};
    _seedDateOrderByStudentCycle(dateOrderByStudentCycle, counterByStudentCycle);
    final studentCycleKey = '${ov.studentId}|$cycle';
    final m = dateOrderByStudentCycle.putIfAbsent(studentCycleKey, () => {});
    final dateKey = _dateKey(target);
    final int sessionOrder = m.containsKey(dateKey)
        ? m[dateKey]!
        : ((counterByStudentCycle[studentCycleKey] ?? 0) + 1);

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
      setId: setId,
      cycle: (cycle == null || cycle == 0) ? 1 : cycle,
      sessionOrder: sessionOrder <= 0 ? 1 : sessionOrder,
      isPlanned: true,
      snapshotId: null,
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
      'snapshot_id': null,
      'batch_session_id': record.batchSessionId,
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
      final targetL = DateTime(classDateTime.year, classDateTime.month, classDateTime.day);
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
        print('[PLAN][remove-date-done] student=$studentId removed=${beforeLocal - afterLocal} localAfter=$afterLocal');
      }
    } catch (e) {
      print('[WARN] planned 제거 실패(student=$studentId, dt=$classDateTime): $e');
    }
  }

  Future<void> regeneratePlannedAttendanceForSet({
    required String studentId,
    required String setId,
    int days = 14,
    String? snapshotId,
    List<StudentTimeBlock>? blocksOverride,
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
          // ⚠️ 순수 planned만 삭제 (실제 출석/등원 기록 보호)
          .eq('is_present', false)
          .isFilter('arrival_time', null)
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
        if (!_isBlockActiveOnDate(b, date)) continue;
        final classStart = DateTime(date.year, date.month, date.day, b.startHour, b.startMinute);
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
        final classDateTime =
            DateTime(agg.start.year, agg.start.month, agg.start.day, agg.start.hour, agg.start.minute);
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
          snapshotId: snapshotId,
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
    final Map<String, String> batchSessionByRecordId = await _createBatchSessionsForPlanned(
      studentId: studentId,
      plannedRecords: localAdds,
      snapshotId: snapshotId,
    );
    for (int i = 0; i < localAdds.length; i++) {
      final rec = localAdds[i];
      final updated = rec.copyWith(batchSessionId: batchSessionByRecordId[rec.id]);
      localAdds[i] = updated;
      rows[i]['batch_session_id'] = updated.batchSessionId;
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
    final paymentRecords = _d.getPaymentRecords().where((p) => p.studentId == studentId).toList();
    PaymentRecord? cur;
    PaymentRecord? next;
    for (final p in paymentRecords) {
      if (p.cycle == cycle) cur = p;
      if (p.cycle == cycle + 1) next = p;
    }
    if (cur == null) return null;

    final DateTime start = DateTime(cur!.dueDate.year, cur!.dueDate.month, cur!.dueDate.day);
    final DateTime end = next != null
        ? DateTime(next!.dueDate.year, next!.dueDate.month, next!.dueDate.day)
        // fallback: 다음 cycle이 없으면 31일을 가정(서버에서 미래 cycles를 생성하므로 보통 발생하지 않음)
        : start.add(const Duration(days: 31));

    final DateTime nowRef = now ?? DateTime.now();

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
      if (r.classDateTime.isBefore(start) || !r.classDateTime.isBefore(end)) continue;

      final int minutes = r.classEndTime.difference(r.classDateTime).inMinutes;
      plannedCount += 1;
      plannedMinutes += minutes;

      final bool isActual = r.isPresent || r.arrivalTime != null || r.departureTime != null;
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

