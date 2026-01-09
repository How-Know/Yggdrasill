import 'dart:async';
import 'dart:typed_data';
import '../models/student.dart';
import '../models/group_info.dart';
import '../models/operating_hours.dart';
import '../models/academy_settings.dart';
import '../models/payment_type.dart';
import '../models/education_level.dart';
import '../models/student_time_block.dart';
import '../models/group_schedule.dart';
import '../models/teacher.dart';
import '../models/self_study_time_block.dart';
import '../models/class_info.dart';
import '../models/payment_record.dart';
import '../models/attendance_record.dart';
import '../models/cycle_attendance_summary.dart';
import '../models/session_override.dart';
import '../models/student_payment_info.dart';
import 'package:flutter/foundation.dart';
import 'academy_db.dart';
import 'runtime_flags.dart';
import 'tag_store.dart';
import 'sync_service.dart';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../models/memo.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:postgrest/postgrest.dart' show PostgrestException;
import 'package:flutter/material.dart';
import 'tenant_service.dart';
import 'tag_preset_service.dart';
import 'memo_service.dart';
import 'resource_service.dart';
import 'answer_key_service.dart';
import 'attendance_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel, PostgresChangeEvent, PostgresChangeFilter, PostgresChangeFilterType, Supabase, AuthState, AuthChangeEvent;
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel, Supabase;

class StudentWithInfo {
  final Student student;
  final StudentBasicInfo basicInfo;
  StudentWithInfo({required this.student, required this.basicInfo});
  // UI 호환용 getter (임시)
  GroupInfo? get groupInfo => student.groupInfo;
  String? get phoneNumber => student.phoneNumber;
  String? get parentPhoneNumber => student.parentPhoneNumber;
  DateTime? get registrationDate => basicInfo.registrationDate;
  // 호환성을 위한 추가 getter들
  String? get studentPaymentType => 'monthly';
  int? get studentSessionCycle => 1;
}

class DataManager {
  static final DataManager instance = DataManager._internal();
  DataManager._internal();

  List<StudentWithInfo> _studentsWithInfo = [];
  List<GroupInfo> _groups = [];
  List<OperatingHours> _operatingHours = [];
  Map<String, GroupInfo> _groupsById = {};
  bool _isInitialized = false;
  List<PaymentRecord> _paymentRecords = [];
  List<StudentPaymentInfo> _studentPaymentInfos = [];

  final ValueNotifier<List<GroupInfo>> groupsNotifier = ValueNotifier<List<GroupInfo>>([]);
  final ValueNotifier<List<StudentWithInfo>> studentsNotifier = ValueNotifier<List<StudentWithInfo>>([]);
  // invalidation-only refresh: bump 시 화면에서 디바운스 재조회 트리거
  final ValueNotifier<int> studentsRevision = ValueNotifier<int>(0);
  final ValueNotifier<List<PaymentRecord>> paymentRecordsNotifier = ValueNotifier<List<PaymentRecord>>([]);
  final ValueNotifier<List<StudentPaymentInfo>> studentPaymentInfosNotifier = ValueNotifier<List<StudentPaymentInfo>>([]);
  final ValueNotifier<int> studentPaymentInfoRevision = ValueNotifier<int>(0);
  
  // Session Overrides (보강/예외)
  List<SessionOverride> _sessionOverrides = [];
  final ValueNotifier<List<SessionOverride>> sessionOverridesNotifier = ValueNotifier<List<SessionOverride>>([]);
  RealtimeChannel? _sessionOverridesRealtimeChannel;

  List<GroupInfo> get groups {
    // print('[DEBUG] DataManager.groups: $_groups');
    return List.unmodifiable(_groups);
  }
  List<StudentWithInfo> get students => List.unmodifiable(_studentsWithInfo);
  List<PaymentRecord> get paymentRecords => List.unmodifiable(_paymentRecords);
  List<AttendanceRecord> get attendanceRecords => AttendanceService.instance.attendanceRecords;
  ValueNotifier<List<AttendanceRecord>> get attendanceRecordsNotifier =>
      AttendanceService.instance.attendanceRecordsNotifier;

  AcademySettings _academySettings = AcademySettings(name: '', slogan: '', defaultCapacity: 30, lessonDuration: 50, logo: null);
  PaymentType _paymentType = PaymentType.monthly;

  AcademySettings get academySettings => _academySettings;
  PaymentType get paymentType => _paymentType;

  set paymentType(PaymentType type) {
    _paymentType = type;
  }

  List<StudentTimeBlock> _studentTimeBlocks = [];
  final ValueNotifier<List<StudentTimeBlock>> studentTimeBlocksNotifier = ValueNotifier<List<StudentTimeBlock>>([]);
  final ValueNotifier<int> studentTimeBlocksRevision = ValueNotifier<int>(0);
  final ValueNotifier<int> classesRevision = ValueNotifier<int>(0);
  final ValueNotifier<int> classAssignmentsRevision = ValueNotifier<int>(0);

  // ===== student_time_blocks: week-range cache (시간표 UI 최적화/주 이동 대응) =====
  // - 서버/로컬에서 "해당 주에 겹치는 블록만" 가져와 캐시한다.
  // - 기존 _studentTimeBlocks(전역)는 planned/정산/편집 로직에서 그대로 사용하되,
  //   UI는 필요 시 week cache를 우선 활용한다.
  final Map<String, List<StudentTimeBlock>> _studentTimeBlocksByWeek = <String, List<StudentTimeBlock>>{};
  final Set<String> _studentTimeBlocksWeekLoading = <String>{};
  // ✅ 성능: week-cache + 로컬 변경분 merge/sort는 build 중 여러 번 호출될 수 있어 매우 비싸다.
  // 같은 revision에서는 결과가 동일하므로 주(key)별로 병합 결과를 캐시한다.
  final Map<String, List<StudentTimeBlock>> _studentTimeBlocksMergedByWeek = <String, List<StudentTimeBlock>>{};
  final Map<String, int> _studentTimeBlocksMergedByWeekRev = <String, int>{};

  static String _ymd(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
  }

  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
  DateTime _weekMonday(DateTime d) {
    final base = _dateOnly(d);
    return base.subtract(Duration(days: base.weekday - DateTime.monday));
  }

  String _weekKey(DateTime weekStart) => _ymd(_dateOnly(weekStart));

  /// 특정 주(weekStart=월요일)의 "겹치는" student_time_blocks를 캐시한다.
  /// - 겹침 조건: start_date <= weekEnd && (end_date is null || end_date >= weekStart)
  /// - UI에서는 이 목록을 다시 날짜(refDate)로 한 번 더 필터링해 사용한다.
  Future<void> ensureStudentTimeBlocksForWeek(
    DateTime dateInWeek, {
    bool force = false,
  }) async {
    final weekStart = _weekMonday(dateInWeek);
    final key = _weekKey(weekStart);
    if (!force && _studentTimeBlocksByWeek.containsKey(key)) return;
    if (_studentTimeBlocksWeekLoading.contains(key)) return;
    _studentTimeBlocksWeekLoading.add(key);
    try {
      final weekEnd = weekStart.add(const Duration(days: 6));
      List<StudentTimeBlock> blocks = <StudentTimeBlock>[];

      if (TagPresetService.preferSupabaseRead) {
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        blocks = await _fetchStudentTimeBlocksRangeFromSupabase(
          academyId: academyId,
          rangeStart: weekStart,
          rangeEnd: weekEnd,
        );
      } else {
        // 로컬 DB는 일단 전체 로드 후 범위 필터(필요 시 AcademyDbService에 range query 추가 가능)
        final all = await AcademyDbService.instance.getStudentTimeBlocks();
        blocks = all.where((b) => _overlapsRange(b, weekStart, weekEnd)).toList();
      }

      _studentTimeBlocksByWeek[key] = List.unmodifiable(blocks);
      _bumpStudentTimeBlocksRevision(); // UI 캐시 무효화/리빌드 트리거로 재사용
    } catch (e, st) {
      print('[STB][week] load failed week=$key err=$e\n$st');
    } finally {
      _studentTimeBlocksWeekLoading.remove(key);
    }
  }

  /// 주(weekStart=월요일)에 겹치는 블록 목록을 반환한다.
  /// - 서버 week-cache + 로컬 메모리(_studentTimeBlocks)의 변경분(optimistic/pending)을 id 기준으로 병합한다.
  List<StudentTimeBlock> getStudentTimeBlocksForWeek(DateTime weekStart) {
    final ws = _weekMonday(weekStart);
    final key = _weekKey(ws);
    final currentRev = studentTimeBlocksRevision.value;
    final mergedCached = _studentTimeBlocksMergedByWeek[key];
    final mergedRev = _studentTimeBlocksMergedByWeekRev[key];
    if (mergedCached != null && mergedRev == currentRev) {
      return mergedCached;
    }
    final we = ws.add(const Duration(days: 6));
    final Map<String, StudentTimeBlock> byId = <String, StudentTimeBlock>{};

    final cached = _studentTimeBlocksByWeek[key];
    if (cached != null) {
      for (final b in cached) {
        if (b.id.isEmpty) continue;
        byId[b.id] = b;
      }
    }

    // 로컬(메모리) 변경분 우선 반영: 캐시보다 최신일 수 있다.
    for (final b in _studentTimeBlocks) {
      if (b.id.isEmpty) continue;
      if (!_overlapsRange(b, ws, we)) continue;
      byId[b.id] = b;
    }

    final out = byId.values.toList()
      ..sort((a, b) {
        final c1 = a.dayIndex.compareTo(b.dayIndex);
        if (c1 != 0) return c1;
        final c2 = a.startHour.compareTo(b.startHour);
        if (c2 != 0) return c2;
        final c3 = a.startMinute.compareTo(b.startMinute);
        if (c3 != 0) return c3;
        return a.createdAt.compareTo(b.createdAt);
      });
    // 타입 추론이 dynamic으로 떨어지는 케이스가 있어 명시적으로 제네릭을 지정한다.
    final List<StudentTimeBlock> merged =
        List<StudentTimeBlock>.unmodifiable(out);
    _studentTimeBlocksMergedByWeek[key] = merged;
    _studentTimeBlocksMergedByWeekRev[key] = currentRev;
    return merged;
  }

  bool _overlapsRange(StudentTimeBlock b, DateTime rangeStart, DateTime rangeEnd) {
    final rs = _dateOnly(rangeStart);
    final re = _dateOnly(rangeEnd);
    final sd = _dateOnly(b.startDate);
    final ed = b.endDate == null ? null : _dateOnly(b.endDate!);
    if (sd.isAfter(re)) return false;
    if (ed != null && ed.isBefore(rs)) return false;
    return true;
  }

  StudentTimeBlock _stbFromServerRow(Map<String, dynamic> raw) {
    final mm = Map<String, dynamic>.from(raw);
    DateTime parseDateOnlyOr(DateTime fallback, String? v) {
      if (v == null || v.trim().isEmpty) return fallback;
      return DateTime.tryParse(v) ?? fallback;
    }

    final createdAt = DateTime.tryParse((mm['block_created_at'] as String?) ?? '') ?? DateTime.now();
    final startDate = parseDateOnlyOr(createdAt, (mm['start_date'] as String?)) ;
    final endDateStr = (mm['end_date'] as String?);
    final endDate = (endDateStr != null && endDateStr.trim().isNotEmpty) ? DateTime.tryParse(endDateStr) : null;
    return StudentTimeBlock(
      id: (mm['id'] as String?) ?? '',
      studentId: (mm['student_id'] as String?) ?? '',
      dayIndex: (mm['day_index'] as int?) ?? 0,
      startHour: (mm['start_hour'] as int?) ?? 0,
      startMinute: (mm['start_minute'] as int?) ?? 0,
      duration: Duration(minutes: (mm['duration'] as int?) ?? 0),
      createdAt: createdAt,
      startDate: startDate,
      endDate: endDate,
      setId: mm['set_id'] as String?,
      number: mm['number'] as int?,
      sessionTypeId: mm['session_type_id'] as String?,
      weeklyOrder: mm['weekly_order'] as int?,
    );
  }

  Future<List<StudentTimeBlock>> _fetchStudentTimeBlocksRangeFromSupabase({
    required String academyId,
    required DateTime rangeStart,
    required DateTime rangeEnd,
  }) async {
    const int pageSize = 1000;
    final rs = _ymd(_dateOnly(rangeStart));
    final re = _ymd(_dateOnly(rangeEnd));

    final out = <StudentTimeBlock>[];
    int from = 0;
    while (true) {
      final data = await Supabase.instance.client
          .from('student_time_blocks')
          .select('id,student_id,day_index,start_hour,start_minute,duration,block_created_at,start_date,end_date,set_id,number,session_type_id,weekly_order')
          .eq('academy_id', academyId)
          // range overlap
          .lte('start_date', re)
          .or('end_date.is.null,end_date.gte.$rs')
          .order('day_index')
          .order('start_hour')
          .order('start_minute')
          .range(from, from + pageSize - 1);

      final list = (data as List).cast<Map<String, dynamic>>();
      for (final r in list) {
        final b = _stbFromServerRow(r);
        if (b.id.isEmpty || b.studentId.isEmpty) continue;
        out.add(b);
      }
      if (list.length < pageSize) break;
      from += pageSize;
    }
    return out;
  }
  void _bumpStudentTimeBlocksRevision() {
    studentTimeBlocksRevision.value++;
    classAssignmentsRevision.value++;
    // week 병합 캐시는 revision에 종속이므로 전체 무효화
    _studentTimeBlocksMergedByWeek.clear();
    _studentTimeBlocksMergedByWeekRev.clear();
  }
  DateTime _todayDateOnly() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  bool _isBlockActiveOn(StudentTimeBlock block, DateTime date) {
    final target = DateTime(date.year, date.month, date.day);
    final start = DateTime(block.startDate.year, block.startDate.month, block.startDate.day);
    final end = block.endDate != null ? DateTime(block.endDate!.year, block.endDate!.month, block.endDate!.day) : null;
    return !start.isAfter(target) && (end == null || !end.isBefore(target));
  }

  List<StudentTimeBlock> _activeBlocks(DateTime date) =>
      _studentTimeBlocks.where((b) => _isBlockActiveOn(b, date)).toList();

  void _publishStudentTimeBlocks({DateTime? refDate}) {
    final date = refDate ?? _todayDateOnly();
    studentTimeBlocksNotifier.value = List.unmodifiable(_activeBlocks(date));
  }

  // UI 깜빡임을 줄이기 위한 낙관적 반영용 헬퍼
  void applyStudentTimeBlocksOptimistic(List<StudentTimeBlock> blocks, {DateTime? refDate}) {
    _studentTimeBlocks = List<StudentTimeBlock>.from(blocks);
    _publishStudentTimeBlocks(refDate: refDate);
    _bumpStudentTimeBlocksRevision();
  }

  /// 수업카드 변경/삭제 시, 해당 수업을 참조하는 time block들의 session_type_id를 **일괄 변경**한다.
  ///
  /// - UI는 먼저 즉시 반영(로컬 메모리 갱신/notify)하고,
  /// - Supabase/로컬DB 반영은 await 구간에서 수행한다.
  ///
  /// ✅ 시간/세트(setId)는 그대로이므로 planned 재생성은 수행하지 않는다.
  Future<void> bulkUpdateStudentTimeBlocksSessionTypeIdForClass(
    String oldClassId, {
    required String? newSessionTypeId,
    DateTime? refDate,
    bool publish = true,
  }) async {
    final date = refDate ?? _todayDateOnly();
    bool changed = false;
    final List<StudentTimeBlock> updated = <StudentTimeBlock>[];
    final List<StudentTimeBlock> next = <StudentTimeBlock>[];
    for (final b in _studentTimeBlocks) {
      if (b.sessionTypeId != oldClassId) {
        next.add(b);
        continue;
      }
      changed = true;
      final nb = StudentTimeBlock(
        id: b.id,
        studentId: b.studentId,
        dayIndex: b.dayIndex,
        startHour: b.startHour,
        startMinute: b.startMinute,
        duration: b.duration,
        createdAt: b.createdAt,
        startDate: b.startDate,
        endDate: b.endDate,
        setId: b.setId,
        number: b.number,
        sessionTypeId: newSessionTypeId,
        weeklyOrder: b.weeklyOrder,
      );
      next.add(nb);
      updated.add(nb);
    }

    // ✅ UI 즉시 반영
    if (changed) {
      _studentTimeBlocks = next;
      if (publish) {
        _publishStudentTimeBlocks(refDate: date);
        _bumpStudentTimeBlocksRevision();
      }
    } else {
      return;
    }

    // ===== 서버/로컬 반영 (백그라운드 작업) =====
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        await Supabase.instance.client
            .from('student_time_blocks')
            .update({'session_type_id': newSessionTypeId})
            .eq('academy_id', academyId)
            .eq('session_type_id', oldClassId);
      } catch (e, st) {
        print('[SUPA][stb bulk session_type_id update] $e\n$st');
        rethrow;
      }
      return;
    }

    // local DB
    try {
      for (final b in updated) {
        await AcademyDbService.instance.updateStudentTimeBlock(b.id, b);
      }
    } catch (e, st) {
      print('[LOCAL][stb bulk session_type_id update] $e\n$st');
      rethrow;
    }
  }

  /// (리팩터) `session_type_id`는 실제로 `classes.id`를 참조하므로,
  /// 코드 레벨에서 의미를 드러내기 위한 wrapper.
  ///
  /// - DB 컬럼명은 그대로 유지(마이그레이션 없음)
  /// - 동작은 `bulkUpdateStudentTimeBlocksSessionTypeIdForClass`와 동일
  Future<void> bulkUpdateStudentTimeBlocksClassIdForClass(
    String oldClassId, {
    required String? newClassId,
    DateTime? refDate,
    bool publish = true,
  }) =>
      bulkUpdateStudentTimeBlocksSessionTypeIdForClass(
        oldClassId,
        newSessionTypeId: newClassId,
        refDate: refDate,
        publish: publish,
      );

  // 디버그: 특정 키(dayIdx,startHour,startMinute,studentId)로 내려온 블록 페이로드 덤프
  void debugDumpStudentBlocks({
    required int dayIdx,
    required int startHour,
    required int startMinute,
    String? studentId,
  }) {
    final blocks = _studentTimeBlocks.where((b) {
      final hit = b.dayIndex == dayIdx && b.startHour == startHour && b.startMinute == startMinute;
      if (!hit) return false;
      if (studentId != null && studentId.isNotEmpty) {
        return b.studentId == studentId;
      }
      return true;
    }).toList();
    if (blocks.isEmpty) {
      print('[STB][dump] day=$dayIdx time=$startHour:$startMinute studentId=${studentId ?? 'any'} -> 0');
      return;
    }
    final payload = blocks
        .map((b) =>
            '${b.id}|student=${b.studentId}|set=${b.setId}|sess=${b.sessionTypeId}|sd=${b.startDate.toIso8601String().split("T").first}|ed=${b.endDate?.toIso8601String().split("T").first ?? 'null'}|created=${b.createdAt.toIso8601String()}')
        .join(', ');
    print('[STB][dump] day=$dayIdx time=$startHour:$startMinute studentId=${studentId ?? 'any'} count=${blocks.length} payload=[$payload]');
  }
  
  List<GroupSchedule> _groupSchedules = [];
  final ValueNotifier<List<GroupSchedule>> groupSchedulesNotifier = ValueNotifier<List<GroupSchedule>>([]);
  final ValueNotifier<int> studentBasicInfoRevision = ValueNotifier<int>(0);

  // ===== SNAPSHOT HELPERS =====
  Future<String> createLessonSnapshotForStudent({
    required String studentId,
    DateTime? effectiveStart,
    DateTime? effectiveEnd,
    String source = 'manual',
    double? billedAmount,
    double? unitPrice,
    String? note,
  }) async {
    final now = DateTime.now();
    final effStart = effectiveStart ?? _todayDateOnly();
    final effEnd = effectiveEnd;
    final dateOnlyStart = DateTime(effStart.year, effStart.month, effStart.day);
    final dateOnlyEnd = effEnd != null ? DateTime(effEnd.year, effEnd.month, effEnd.day) : null;

    // 활성 블록 중 대상 학생만 추출
    final blocks = _activeBlocks(dateOnlyStart).where((b) => b.studentId == studentId).toList();
    if (blocks.isEmpty) {
      throw Exception('해당 학생의 활성 블록이 없습니다.');
    }

    // setId 기준 그룹
    final Map<String?, List<StudentTimeBlock>> bySet = {};
    for (final b in blocks) {
      bySet.putIfAbsent(b.setId, () => []).add(b);
    }

    final dayPattern = blocks.map((b) => b.dayIndex).toSet().toList()..sort();
    final weeklyCount = blocks.length;
    final expectedSessions = weeklyCount * 4; // 간단 예상(4주치) - 추후 보완 가능
    final setIds = bySet.keys.whereType<String>().toList();

    // Supabase용/로컬용 헤더
    final headerId = const Uuid().v4();
    Map<String, dynamic> _headerRow(String academyId) => {
      'id': headerId,
      'academy_id': academyId,
      'student_id': studentId,
      'snapshot_at': now.toIso8601String(),
      'effective_start': dateOnlyStart.toIso8601String().split('T').first,
      'effective_end': dateOnlyEnd?.toIso8601String().split('T').first,
      'weekly_count': weeklyCount,
      'day_pattern': dayPattern,
      'expected_sessions': expectedSessions,
      'billed_amount': billedAmount,
      'unit_price': unitPrice,
      'note': note,
      'set_ids': setIds,
      'source': source,
    }..removeWhere((k, v) => v == null);

    List<Map<String, dynamic>> _blockRows(String academyId) =>
      blocks.map((b) => <String, dynamic>{
        'id': const Uuid().v4(),
        'snapshot_id': headerId,
        'day_index': b.dayIndex,
        'start_hour': b.startHour,
        'start_minute': b.startMinute,
        'duration': b.duration.inMinutes,
        'number': b.number,
        'weekly_order': b.weeklyOrder,
        'set_id': b.setId,
        'session_type_id': b.sessionTypeId,
      }..removeWhere((k, v) => v == null)).toList();

    if (TagPresetService.preferSupabaseRead) {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      final header = _headerRow(academyId);
      final blocksRow = _blockRows(academyId);
      final supa = Supabase.instance.client;
      await supa.from('lesson_snapshot_headers').insert(header);
      if (blocksRow.isNotEmpty) {
        await supa.from('lesson_snapshot_blocks').insert(blocksRow);
      }
    } else {
      final header = _headerRow('local');
      final blocksRow = _blockRows('local');
      await AcademyDbService.instance.addLessonSnapshot(header: header, blocks: blocksRow);
    }
    return headerId;
  }

  /// 스냅샷을 생성한 뒤 해당 스냅샷을 근거로 planned를 재생성
  Future<void> regeneratePlannedWithSnapshot({
    required String studentId,
    required Set<String> setIds,
    DateTime? effectiveStart,
    int days = 15,
    double? billedAmount,
    double? unitPrice,
    String? note,
  }) async {
    final today = _todayDateOnly();
    final baseStart = effectiveStart != null
        ? DateTime(effectiveStart.year, effectiveStart.month, effectiveStart.day)
        : today;
    // ✅ planned 생성/재생성에는 "미래 세그먼트"까지 포함된 전체 블록이 필요하다.
    // (오늘 활성 블록만 넘기면 미래 시작 예약/세그먼트가 planned에 반영되지 않음)
    final blocksForSets = _studentTimeBlocks
        .where((b) => b.studentId == studentId && b.setId != null && setIds.contains(b.setId))
        .toList();

    // 스냅샷은 기본적으로 effectiveStart(없으면 today) 기준으로 찍되,
    // 해당 날짜에 활성 블록이 0개(예: 시작일이 더 미래)면 today → 가장 이른 start_date 순으로 폴백한다.
    String snapshotId;
    try {
      snapshotId = await createLessonSnapshotForStudent(
        studentId: studentId,
        effectiveStart: baseStart,
        effectiveEnd: null,
        source: 'plan-regenerate',
        billedAmount: billedAmount,
        unitPrice: unitPrice,
        note: note,
      );
    } catch (e) {
      try {
        snapshotId = await createLessonSnapshotForStudent(
          studentId: studentId,
          effectiveStart: today,
          effectiveEnd: null,
          source: 'plan-regenerate',
          billedAmount: billedAmount,
          unitPrice: unitPrice,
          note: note,
        );
      } catch (_) {
        if (blocksForSets.isEmpty) rethrow;
        DateTime minStart = DateTime(2999, 1, 1);
        for (final b in blocksForSets) {
          final sd = DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
          if (sd.isBefore(minStart)) minStart = sd;
        }
        snapshotId = await createLessonSnapshotForStudent(
          studentId: studentId,
          effectiveStart: minStart,
          effectiveEnd: null,
          source: 'plan-regenerate',
          billedAmount: billedAmount,
          unitPrice: unitPrice,
          note: note,
        );
      }
    }

    // planned cancel anchor:
    // - effectiveStart가 미래면 해당 날짜부터만 재생성
    // - 오늘/과거면 "지금" 이후만(오늘 과거 시간대 planned 기록 보존)
    final nowUtc = DateTime.now().toUtc();
    final startUtc = baseStart.toUtc();
    final anchorUtc = startUtc.isAfter(nowUtc) ? startUtc : nowUtc;
    await AttendanceService.instance.replanRemainingForStudentSets(
      studentId: studentId,
      setIds: setIds,
      days: days,
      anchor: anchorUtc,
      snapshotId: snapshotId,
      blocksOverride: blocksForSets,
    );
  }

  List<StudentTimeBlock> get studentTimeBlocks => List.unmodifiable(_studentTimeBlocks);
  set studentTimeBlocks(List<StudentTimeBlock> value) {
    _studentTimeBlocks = value;
  }
  List<GroupSchedule> get groupSchedules => List.unmodifiable(_groupSchedules);

  List<Teacher> _teachers = [];
  final ValueNotifier<List<Teacher>> teachersNotifier = ValueNotifier<List<Teacher>>([]);
  List<Teacher> get teachers => List.unmodifiable(_teachers);

  List<SelfStudyTimeBlock> _selfStudyTimeBlocks = [];
  final ValueNotifier<List<SelfStudyTimeBlock>> selfStudyTimeBlocksNotifier = ValueNotifier<List<SelfStudyTimeBlock>>([]);
  // ===== EXAM DATA CACHE =====
  // key: '${level.index}|$school|$grade'
  final Map<String, Map<DateTime, List<String>>> _examTitlesBySg = {};
  final Map<String, Map<DateTime, String>> _examRangesBySg = {};
  final Map<String, Set<DateTime>> _examDaysBySg = {};

  String _sgKey(String school, EducationLevel level, int grade) => '${level.index}|$school|$grade';


  List<SelfStudyTimeBlock> get selfStudyTimeBlocks => List.unmodifiable(_selfStudyTimeBlocks);

  // 1Hz 전역 티커: 과제 러닝 타이머 UI 갱신용
  final ValueNotifier<int> globalTick = ValueNotifier<int>(0);
  Timer? _tickTimer;
  set selfStudyTimeBlocks(List<SelfStudyTimeBlock> value) {
    _selfStudyTimeBlocks = value;
    selfStudyTimeBlocksNotifier.value = List.unmodifiable(_selfStudyTimeBlocks);
  }

  void _configureAttendanceService() {
    AttendanceService.instance.configure(
      AttendanceDependencies(
        // 전체 블록을 전달하고, attendance 측에서 날짜별로 start/end를 필터링한다.
        getStudentTimeBlocks: () => _studentTimeBlocks,
        getPaymentRecords: () => _paymentRecords,
        getClasses: () => _classes,
        getSessionOverrides: () => _sessionOverrides,
        getAcademySettings: () => _academySettings,
        loadPaymentRecords: loadPaymentRecords,
        updateSessionOverrideRemote: updateSessionOverride,
        applySessionOverrideLocal: _applySessionOverrideLocal,
      ),
    );
  }


  Future<void> addSelfStudyTimeBlock(SelfStudyTimeBlock block) async {
    _selfStudyTimeBlocks.add(block);
    selfStudyTimeBlocksNotifier.value = List.unmodifiable(_selfStudyTimeBlocks);
    await AcademyDbService.instance.addSelfStudyTimeBlock(block);
  }

  Future<void> removeSelfStudyTimeBlock(String id) async {
    _selfStudyTimeBlocks.removeWhere((b) => b.id == id);
    selfStudyTimeBlocksNotifier.value = List.unmodifiable(_selfStudyTimeBlocks);
    await AcademyDbService.instance.deleteSelfStudyTimeBlock(id);
    await loadSelfStudyTimeBlocks(); // DB 삭제 후 메모리/상태 최신화
  }

  Future<void> updateSelfStudyTimeBlock(String id, SelfStudyTimeBlock newBlock) async {
    final index = _selfStudyTimeBlocks.indexWhere((b) => b.id == id);
    if (index != -1) {
      _selfStudyTimeBlocks[index] = newBlock;
      selfStudyTimeBlocksNotifier.value = List.unmodifiable(_selfStudyTimeBlocks);
      await AcademyDbService.instance.updateSelfStudyTimeBlock(id, newBlock);
      await loadSelfStudyTimeBlocks(); // DB 업데이트 후 메모리/상태 최신화
    }
  }

  Future<void> initialize() async {
    if (_isInitialized) {
      return;
    }

    try {
      _configureAttendanceService();
      // 로그인/테넌트 보장 후 일괄 로딩
      try { await TenantService.instance.ensureActiveAcademy(); } catch (_) {}
      await reloadAllData();
      await _subscribeSessionOverridesRealtime();
      await _subscribeStudentTimeBlocksRealtime();
      await _subscribeStudentsInvalidation();
      await _subscribeStudentBasicInfoInvalidation();
      await _subscribeStudentPaymentInfoInvalidation();
      _subscribeAuthChanges();
      await _subscribeStudentTimeBlocksRealtime();
      await _subscribeAttendanceRealtime(); // 출석 Realtime 구독
      await _subscribePaymentsRealtime(); // 결제 Realtime 구독
      await preloadAllExamData(); // 시험 데이터 캐시 프리로드
      // 1Hz 글로벌 티커 시작
      _tickTimer?.cancel();
      _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        globalTick.value++;
      });
      _isInitialized = true;
    } catch (e) {
      print('Error initializing data: $e');
      _initializeDefaults();
    }
  }

  Future<void> _subscribeSessionOverridesRealtime() async {
    try {
      _sessionOverridesRealtimeChannel?.unsubscribe();
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      final chan = Supabase.instance.client.channel('public:session_overrides:$academyId');
      _sessionOverridesRealtimeChannel = chan
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'session_overrides',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (payload) {
            final m = payload.newRecord;
            if (m == null) return;
            DateTime? parseTsOpt(dynamic v) => (v == null) ? null : DateTime.tryParse(v as String)?.toLocal();
            try {
              final ov = SessionOverride(
                id: m['id'] as String,
                studentId: m['student_id'] as String,
                sessionTypeId: m['session_type_id'] as String?,
                setId: m['set_id'] as String?,
                overrideType: SessionOverride.parseType(m['override_type'] as String),
                originalClassDateTime: parseTsOpt(m['original_class_datetime']),
                replacementClassDateTime: parseTsOpt(m['replacement_class_datetime']),
                durationMinutes: (m['duration_minutes'] as num?)?.toInt(),
                reason: SessionOverride.parseReason(m['reason'] as String?),
                status: SessionOverride.parseStatus(m['status'] as String),
                originalAttendanceId: m['original_attendance_id'] as String?,
                replacementAttendanceId: m['replacement_attendance_id'] as String?,
                createdAt: DateTime.parse(m['created_at'] as String).toLocal(),
                updatedAt: DateTime.parse(m['updated_at'] as String).toLocal(),
                version: (m['version'] is num) ? (m['version'] as num).toInt() : 1,
              );
              if (_sessionOverrides.any((o) => o.id == ov.id)) return;
              _sessionOverrides.insert(0, ov);
              sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);
            } catch (_) {}
          },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'session_overrides',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (payload) {
            final m = payload.newRecord;
            if (m == null) return;
            final idx = _sessionOverrides.indexWhere((o) => o.id == m['id']);
            if (idx == -1) return;
            DateTime? parseTsOpt(dynamic v) => (v == null) ? null : DateTime.tryParse(v as String)?.toLocal();
            try {
              _sessionOverrides[idx] = _sessionOverrides[idx].copyWith(
                sessionTypeId: m['session_type_id'] as String?,
                setId: m['set_id'] as String?,
                overrideType: SessionOverride.parseType(m['override_type'] as String),
                originalClassDateTime: parseTsOpt(m['original_class_datetime']),
                replacementClassDateTime: parseTsOpt(m['replacement_class_datetime']),
                durationMinutes: (m['duration_minutes'] as num?)?.toInt(),
                reason: SessionOverride.parseReason(m['reason'] as String?),
                status: SessionOverride.parseStatus(m['status'] as String),
                originalAttendanceId: m['original_attendance_id'] as String?,
                replacementAttendanceId: m['replacement_attendance_id'] as String?,
                updatedAt: DateTime.parse(m['updated_at'] as String).toLocal(),
                version: (m['version'] is num) ? (m['version'] as num).toInt() : _sessionOverrides[idx].version,
              );
              sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);
            } catch (_) {}
          },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'session_overrides',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (payload) {
            final m = payload.oldRecord;
            if (m == null) return;
            _sessionOverrides.removeWhere((o) => o.id == m['id']);
            sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);
          },
        )
        ..subscribe();
    } catch (_) {}
  }

  // ======== MEMOS ========
  ValueNotifier<List<Memo>> get memosNotifier => MemoService.instance.memosNotifier;

  Future<void> loadMemos() => MemoService.instance.loadMemos();
  Future<void> addMemo(Memo memo) => MemoService.instance.addMemo(memo);
  Future<void> updateMemo(Memo memo) => MemoService.instance.updateMemo(memo);
  Future<void> deleteMemo(String id) => MemoService.instance.deleteMemo(id);

  void _initializeDefaults() {
    _groups = [];
    _groupsById = {};
    _studentsWithInfo = [];
    _operatingHours = [];
    _studentTimeBlocks = [];
    _classes = [];
    _paymentRecords = [];
    AttendanceService.instance.reset();
    _sessionOverrides = [];
    _academySettings = AcademySettings(name: '', slogan: '', defaultCapacity: 30, lessonDuration: 50, logo: null);
    _paymentType = PaymentType.monthly;
    _notifyListeners();
  }

  Future<void> loadGroups() async {
    try {
      if (TagPresetService.preferSupabaseRead) {
        try {
          print('[GROUPS][load] preferSupabaseRead=true → server select 시작');
          final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
          final data = await Supabase.instance.client
              .from('groups')
              .select('id,name,description,capacity,duration,color,display_order')
              .eq('academy_id', academyId)
              .order('display_order', ascending: true)
              .order('name');
          _groups = (data as List).map((m) => GroupInfo(
            id: (m['id'] as String),
            name: (m['name'] as String? ?? ''),
            description: (m['description'] as String? ?? ''),
            capacity: m['capacity'] as int?, // null이면 제한 없음
            duration: (m['duration'] as int?) ?? 0,
            color: Color((((m['color'] as int?) ?? 0xFF607D8B)).toSigned(32)),
            displayOrder: (m['display_order'] as int?),
          )).toList();
          print('[GROUPS][load] server loaded count=' + _groups.length.toString() + ', orders=' + _groups.map((g)=> (g.displayOrder?.toString() ?? 'null') + ':' + g.name).toList().toString());
          // Fallback/backfill은 dualWrite가 켜진 경우에만 수행
          if (_groups.isEmpty && TagPresetService.dualWrite) {
            print('[GROUPS][load] server empty → dualWrite fallback to local');
            final local = (await AcademyDbService.instance.getGroups()).where((g) => g != null).toList();
            if (local.isNotEmpty) {
              _groups = local;
              if (TagPresetService.dualWrite) {
                try {
                  final rows = _groups.map((g) => {
                    'id': g.id,
                    'academy_id': academyId,
                    'name': g.name,
                    'description': g.description,
                    'capacity': g.capacity,
                    'duration': g.duration,
                    'color': g.color.value.toSigned(32),
                  }).toList();
                  if (rows.isNotEmpty) {
                    await Supabase.instance.client.from('groups').insert(rows);
                  }
                } catch (_) {}
              }
            }
          }
          _groupsById = {for (var g in _groups) g.id: g};
          _notifyListeners();
          return;
        } catch (e, st) {
          print('[GROUPS][load] server select 실패, fallback 시도: ' + e.toString());
          // fallback to local below
        }
      }
      // 서버 전용 모드에서는 로컬 폴백을 하지 않는다
      if (!TagPresetService.preferSupabaseRead) {
      print('[GROUPS][load] preferSupabaseRead=false → local DB 로드');
      _groups = (await AcademyDbService.instance.getGroups()).where((g) => g != null).toList();
      print('[GROUPS][load] local loaded count=' + _groups.length.toString() + ', orders=' + _groups.map((g)=> (g.displayOrder?.toString() ?? 'null') + ':' + g.name).toList().toString());
      _groupsById = {for (var g in _groups) g.id: g};
      } else {
        print('[GROUPS][load] preferSupabaseRead=true 이지만 server 경로 실패 → 빈 목록');
        _groups = [];
        _groupsById = {};
      }
    } catch (e) {
      print('Error loading groups: $e');
      _groups = [];
      _groupsById = {};
    }
    _notifyListeners();
  }

  Future<void> loadStudents() async {
    print('[DEBUG][loadStudents] 진입');
    // 서버우선: Supabase에서 먼저 시도 후 성공 시 즉시 반영
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final rows = await supa
            .from('students')
            .select('id,name,school,education_level,grade')
            .eq('academy_id', academyId);
        final supaStudents = (rows as List).map((r) => Student(
          id: r['id'] as String,
          name: (r['name'] as String?) ?? '',
          school: (r['school'] as String?) ?? '',
          grade: (r['grade'] as int?) ?? 0,
          educationLevel: EducationLevel.values[(r['education_level'] as int?) ?? 0],
        )).toList();
        final sbiRows = await supa
            .from('student_basic_info')
            .select('student_id,phone_number,parent_phone_number,group_id,memo')
            .eq('academy_id', academyId);
        final Map<String, Map<String, dynamic>> byId = {
          for (final m in (sbiRows as List)) (m['student_id'] as String): Map<String, dynamic>.from(m)
        };
        final List<StudentBasicInfo> basicInfos = [];
        for (final s in supaStudents) {
          final info = byId[s.id];
          final paymentInfo = _studentPaymentInfos.firstWhere(
            (p) => p.studentId == s.id,
            orElse: () => StudentPaymentInfo(
              id: '', studentId: s.id, registrationDate: DateTime.now(), paymentMethod: 'monthly',
              tuitionFee: 0, latenessThreshold: 10, scheduleNotification: false, attendanceNotification: false,
              departureNotification: false, latenessNotification: false, createdAt: DateTime.now(), updatedAt: DateTime.now(),
            ),
          );
          final reg = paymentInfo.registrationDate;
          if (info != null) {
            basicInfos.add(StudentBasicInfo(
              studentId: s.id,
              phoneNumber: info['phone_number'] as String?,
              parentPhoneNumber: info['parent_phone_number'] as String?,
              groupId: info['group_id'] as String?,
              registrationDate: reg,
              memo: info['memo'] as String?,
            ));
          } else {
            basicInfos.add(StudentBasicInfo(studentId: s.id, registrationDate: reg));
          }
        }
        // 서버에 데이터가 전혀 없으면 로컬로 폴백하여 표시(초기 백필 전 단계 방지)
        if (supaStudents.isEmpty) {
          throw Exception('Empty on server; fallback to local');
        }

        final students = [
          for (int i = 0; i < supaStudents.length; i++)
            Student(
              id: supaStudents[i].id,
              name: supaStudents[i].name,
              school: supaStudents[i].school,
              grade: supaStudents[i].grade,
              educationLevel: supaStudents[i].educationLevel,
              phoneNumber: basicInfos[i].phoneNumber,
              parentPhoneNumber: basicInfos[i].parentPhoneNumber,
              groupId: basicInfos[i].groupId,
              groupInfo: basicInfos[i].groupId != null ? _groupsById[basicInfos[i].groupId] : null,
            )
        ];
        _studentsWithInfo = [
          for (int i = 0; i < students.length; i++) StudentWithInfo(student: students[i], basicInfo: basicInfos[i])
        ];
        studentsNotifier.value = List.unmodifiable(_studentsWithInfo);
        print('[DEBUG][loadStudents] (Supabase) ${_studentsWithInfo.length}명');
        return;
      } catch (_) {
        // fallback below
      }
    }
    // 1. students 테이블에서 기본 정보 불러오기
    if (RuntimeFlags.serverOnly) {
      _studentsWithInfo = [];
      studentsNotifier.value = List.unmodifiable(_studentsWithInfo);
      return;
    }
    final studentsRaw = await AcademyDbService.instance.getStudents();
    // 2. student_basic_info 테이블에서 부가 정보 불러오기
    List<StudentBasicInfo> basicInfos = [];
    for (final s in studentsRaw) {
      final info = await AcademyDbService.instance.getStudentBasicInfo(s.id);
      
      // 3. student_payment_info에서 registration_date 가져오기
      DateTime? registrationDate;
      final paymentInfo = _studentPaymentInfos.firstWhere(
        (p) => p.studentId == s.id,
        orElse: () => StudentPaymentInfo(
          id: '',
          studentId: s.id,
          registrationDate: DateTime.now(),
          paymentMethod: '',
          tuitionFee: 0,
          latenessThreshold: 10,
          scheduleNotification: false,
          attendanceNotification: false,
          departureNotification: false,
          latenessNotification: false,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      registrationDate = paymentInfo.registrationDate;
      
      if (info != null) {
        basicInfos.add(StudentBasicInfo(
          studentId: info['student_id'] as String,
          phoneNumber: info['phone_number'] as String?,
          parentPhoneNumber: info['parent_phone_number'] as String?,
          groupId: info['group_id'] as String?,
          registrationDate: registrationDate,
          memo: info['memo'] as String?,
        ));
      } else {
        // 부가 정보가 없으면 기본값으로 생성
        basicInfos.add(StudentBasicInfo(
          studentId: s.id,
          registrationDate: registrationDate,
        ));
      }
    }
    // 4. groupId로 groupInfo를 찾아서 Student에 할당 (student_basic_info 기준)
    final students = [
      for (int i = 0; i < studentsRaw.length; i++)
        Student(
          id: studentsRaw[i].id,
          name: studentsRaw[i].name,
          school: studentsRaw[i].school,
          grade: studentsRaw[i].grade,
          educationLevel: studentsRaw[i].educationLevel,
          phoneNumber: basicInfos[i].phoneNumber,
          parentPhoneNumber: basicInfos[i].parentPhoneNumber,
          groupId: basicInfos[i].groupId,
          groupInfo: basicInfos[i].groupId != null ? _groupsById[basicInfos[i].groupId] : null,
        )
    ];
    // 5. 매칭해서 StudentWithInfo 리스트 생성
    _studentsWithInfo = [
      for (int i = 0; i < students.length; i++)
        StudentWithInfo(student: students[i], basicInfo: basicInfos[i])
    ];
    studentsNotifier.value = List.unmodifiable(_studentsWithInfo);
    print('[DEBUG][loadStudents] studentsNotifier.value 갱신: ${_studentsWithInfo.length}명');
  }

  Future<void> saveStudents() async {
    if (!RuntimeFlags.serverOnly) {
      await AcademyDbService.instance.saveStudents(_studentsWithInfo.map((si) => si.student).toList());
    }
  }

  Future<void> saveGroups() async {
    try {
      if (TagPresetService.preferSupabaseRead) {
        try {
          print('[GROUPS][save] preferSupabaseRead=true → server upsert 시작, count=' + _groups.length.toString());
          final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
          final supa = Supabase.instance.client;
          if (_groups.isNotEmpty) {
            final rows = _groups.asMap().entries.map((e) {
              final g = e.value; final idx = e.key;
              return {
                'id': g.id,
                'academy_id': academyId,
                'name': g.name,
                'description': g.description,
                'capacity': g.capacity,
                'duration': g.duration,
                'color': g.color.value.toSigned(32),
                'display_order': g.displayOrder ?? idx,
              };
            }).toList();
            print('[GROUPS][save] server upsert rows orders=' + rows.map((r)=> (r['display_order']).toString() + ':' + (r['name'] as String)).toList().toString());
            await supa.from('groups').upsert(rows, onConflict: 'id');
          } else {
            print('[GROUPS][save] server upsert skip: empty');
          }
          return;
        } catch (e, st) { print('[SUPA][groups save] $e\n$st'); }
      }
      if (!RuntimeFlags.serverOnly) {
        print('[GROUPS][save] local DB 저장 시작 (serverOnly=false), count=' + _groups.length.toString());
        await AcademyDbService.instance.saveGroups(_groups);
      }
    } catch (e) {
      print('Error saving groups: $e');
      throw Exception('Failed to save groups data');
    }
  }

  Future<void> loadAcademySettings() async {
    try {
      Map<String, dynamic>? dbData;
      if (TagPresetService.preferSupabaseRead) {
        try {
          final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
          final data = await Supabase.instance.client
              .from('academy_settings')
              .select('name,slogan,default_capacity,lesson_duration,payment_type,logo,session_cycle,logo_bucket,logo_path,logo_url')
              .eq('academy_id', academyId)
              .maybeSingle();
          if (data != null) {
            dbData = Map<String, dynamic>.from(data);
          }
        } catch (e, st) { print('[SUPA][student_payment_info select] $e\n$st'); }
      }
      if (!RuntimeFlags.serverOnly) {
        dbData ??= await AcademyDbService.instance.getAcademySettings();
      }
      if (dbData != null) {
        Uint8List? logoBytes;
        // Prefer storage download if bucket/path provided
        if (TagPresetService.preferSupabaseRead) {
          final bucket = dbData['logo_bucket'] as String?;
          final path = dbData['logo_path'] as String?;
          if (bucket != null && bucket.isNotEmpty && path != null && path.isNotEmpty) {
            try {
              logoBytes = await Supabase.instance.client.storage.from(bucket).download(path);
            } catch (e, st) {
              print('[SUPA][academy logo download] $e\n$st');
            }
          }
        }
        // Fallback to legacy bytea column if present
        if (logoBytes == null) {
          final dynamic legacy = dbData['logo'];
          if (legacy is Uint8List) {
            logoBytes = legacy;
          } else if (legacy is List<int>) {
            logoBytes = Uint8List.fromList(List<int>.from(legacy));
          }
        }
        print('[DataManager] loadAcademySettings: storage bucket=${dbData['logo_bucket']}, path=${dbData['logo_path']}, resolvedBytes=${logoBytes?.length ?? 0}');
        _academySettings = AcademySettings(
          name: dbData['name'] as String? ?? '',
          slogan: dbData['slogan'] as String? ?? '',
          defaultCapacity: dbData['default_capacity'] as int? ?? 30,
          lessonDuration: dbData['lesson_duration'] as int? ?? 50,
          logo: logoBytes,
          sessionCycle: dbData['session_cycle'] as int? ?? 1, // [추가]
        );
        // [추가] payment_type을 enum으로 변환하여 _paymentType에 할당
        final paymentTypeStr = dbData['payment_type'] as String? ?? 'monthly';
        if (paymentTypeStr == 'session') {
          _paymentType = PaymentType.perClass;
        } else {
          _paymentType = PaymentType.monthly;
        }
      } else {
        _academySettings = AcademySettings(name: '', slogan: '', defaultCapacity: 30, lessonDuration: 50, logo: null, sessionCycle: 1);
        _paymentType = PaymentType.monthly;
      }
    } catch (e) {
      print('Error loading settings: $e');
      _academySettings = AcademySettings(name: '', slogan: '', defaultCapacity: 30, lessonDuration: 50, logo: null, sessionCycle: 1);
      _paymentType = PaymentType.monthly;
    }
  }

  Future<void> saveAcademySettings(AcademySettings settings) async {
    try {
      print('[DataManager] saveAcademySettings: logo type=\x1B[32m${settings.logo?.runtimeType}\x1B[0m, length=\x1B[32m${settings.logo?.length}\x1B[0m, isNull=\x1B[32m${settings.logo == null}\x1B[0m');
      print('[DataManager] saveAcademySettings: _paymentType = $_paymentType');
      _academySettings = settings;
      await AcademyDbService.instance.saveAcademySettings(settings, _paymentType == PaymentType.monthly ? 'monthly' : 'session');
      if (TagPresetService.preferSupabaseRead || TagPresetService.dualWrite) {
        try {
          final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
          final supa = Supabase.instance.client;

          String? logoBucket;
          String? logoPath;

          final bytes = settings.logo;
          if (bytes != null && bytes.isNotEmpty) {
            logoBucket = 'academy-logos';
            final objectPath = '$academyId/${const Uuid().v4()}.png';
            await supa.storage.from(logoBucket).uploadBinary(
              objectPath,
              bytes,
              fileOptions: const FileOptions(
                upsert: true,
                contentType: 'image/png',
                cacheControl: '3600',
              ),
            );
            logoPath = objectPath;
          }

          final row = <String, dynamic>{
            'academy_id': academyId,
            'name': settings.name,
            'slogan': settings.slogan,
            'default_capacity': settings.defaultCapacity,
            'lesson_duration': settings.lessonDuration,
            'payment_type': _paymentType == PaymentType.monthly ? 'monthly' : 'session',
            'session_cycle': settings.sessionCycle,
          };

          if (logoBucket != null && logoPath != null) {
            row['logo_bucket'] = logoBucket;
            row['logo_path'] = logoPath;
            row['logo_url'] = null;
          }

          await supa.from('academy_settings').upsert(row, onConflict: 'academy_id');
        } catch (e, st) { print('[SUPA][academy_settings upsert (server)] $e\n$st'); }
      }
    } catch (e) {
      print('Error saving settings: $e');
      throw Exception('Failed to save academy settings');
    }
  }

  void _notifyListeners() {
    groupsNotifier.value = List.unmodifiable(_groups);
    studentsNotifier.value = List.unmodifiable(_studentsWithInfo);
    _publishStudentTimeBlocks();
    groupSchedulesNotifier.value = List.unmodifiable(_groupSchedules);
    teachersNotifier.value = List.unmodifiable(_teachers);
    selfStudyTimeBlocksNotifier.value = List.unmodifiable(_selfStudyTimeBlocks);
    classesNotifier.value = List.unmodifiable(_classes);
    paymentRecordsNotifier.value = List.unmodifiable(_paymentRecords);
    sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);
  }

  void _applySessionOverrideLocal(SessionOverride updated) {
    final idx = _sessionOverrides.indexWhere((o) => o.id == updated.id);
    if (idx != -1) {
      _sessionOverrides[idx] = updated;
    } else {
      _sessionOverrides.add(updated);
    }
    sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);
  }

  // =================== SESSION OVERRIDES (보강/예외) ===================

  List<SessionOverride> get sessionOverrides => List.unmodifiable(_sessionOverrides);

  Future<void> loadSessionOverrides() async {
    try {
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final rows = await supa
          .from('session_overrides')
          .select('id,student_id,session_type_id,set_id,occurrence_id,override_type,original_attendance_id,replacement_attendance_id,original_class_datetime,replacement_class_datetime,duration_minutes,reason,status,created_at,updated_at,version')
          .eq('academy_id', academyId)
          .order('updated_at', ascending: false);
      final list = rows as List<dynamic>;
      _sessionOverrides = list.map<SessionOverride>((m) {
        DateTime? parseTsOpt(String k) {
          final v = m[k] as String?;
          if (v == null || v.isEmpty) return null;
          return DateTime.parse(v).toLocal();
        }
        return SessionOverride(
          id: m['id'] as String,
          studentId: m['student_id'] as String,
          sessionTypeId: m['session_type_id'] as String?,
          setId: m['set_id'] as String?,
          occurrenceId: m['occurrence_id']?.toString(),
          overrideType: SessionOverride.parseType(m['override_type'] as String),
          originalClassDateTime: parseTsOpt('original_class_datetime'),
          replacementClassDateTime: parseTsOpt('replacement_class_datetime'),
          durationMinutes: (m['duration_minutes'] as num?)?.toInt(),
          reason: SessionOverride.parseReason(m['reason'] as String?),
          status: SessionOverride.parseStatus(m['status'] as String),
          originalAttendanceId: m['original_attendance_id'] as String?,
          replacementAttendanceId: m['replacement_attendance_id'] as String?,
          createdAt: DateTime.parse(m['created_at'] as String).toLocal(),
          updatedAt: DateTime.parse(m['updated_at'] as String).toLocal(),
          // ignore: cast_from_null_always_fails
          version: (m['version'] is num) ? (m['version'] as num).toInt() : 1,
        );
      }).toList();
      sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);
      print('[DEBUG] session_overrides 로드 완료(Supabase): ${_sessionOverrides.length}개');
      // TODO: Realtime subscribe (다음 단계)
    } catch (e) {
      print('[ERROR] loadSessionOverrides 실패: $e');
      _sessionOverrides = [];
      sessionOverridesNotifier.value = [];
    }
  }

  Future<void> addSessionOverride(SessionOverride overrideData) async {
    try {
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final row = {
        'id': overrideData.id,
        'academy_id': academyId,
        'student_id': overrideData.studentId,
        'session_type_id': overrideData.sessionTypeId,
        'set_id': overrideData.setId,
        'occurrence_id': overrideData.occurrenceId,
        'override_type': SessionOverride.typeToString(overrideData.overrideType),
        'original_class_datetime': overrideData.originalClassDateTime?.toUtc().toIso8601String(),
        'replacement_class_datetime': overrideData.replacementClassDateTime?.toUtc().toIso8601String(),
        'duration_minutes': overrideData.durationMinutes,
        'reason': SessionOverride.reasonToString(overrideData.reason),
        'status': SessionOverride.statusToString(overrideData.status),
        'original_attendance_id': overrideData.originalAttendanceId,
        'replacement_attendance_id': overrideData.replacementAttendanceId,
        'created_at': overrideData.createdAt.toUtc().toIso8601String(),
        'updated_at': overrideData.updatedAt.toUtc().toIso8601String(),
        'version': overrideData.version,
      };
      final ins = await supa.from('session_overrides').insert(row).select('version').maybeSingle();
      final ver = (ins?['version'] as num?)?.toInt() ?? 1;
      final merged = overrideData.copyWith(version: ver);
      _sessionOverrides.removeWhere((o) => o.id == merged.id);
      _sessionOverrides.add(merged);
      sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);
      print('[DEBUG] session_override 추가(Supabase): id=${merged.id}, status=${merged.status}');
      await _regeneratePlannedAttendanceForOverride(merged);
    } catch (e) {
      print('[ERROR] addSessionOverride 실패: $e');
      rethrow;
    }
  }

  Future<void> updateSessionOverride(SessionOverride newData) async {
    try {
      // ✅ 운영시간 방어 로직은 더이상 사용하지 않음.
      // - 특히 취소/삭제(canceled)는 어떤 경우에도 막히면 안 된다.
      if (newData.status != OverrideStatus.canceled) {
        _validateOverride(newData);
      }
      final supa = Supabase.instance.client;
      final base = {
        'student_id': newData.studentId,
        'session_type_id': newData.sessionTypeId,
        'set_id': newData.setId,
        'occurrence_id': newData.occurrenceId,
        'override_type': SessionOverride.typeToString(newData.overrideType),
        'original_class_datetime': newData.originalClassDateTime?.toUtc().toIso8601String(),
        'replacement_class_datetime': newData.replacementClassDateTime?.toUtc().toIso8601String(),
        'duration_minutes': newData.durationMinutes,
        'reason': SessionOverride.reasonToString(newData.reason),
        'status': SessionOverride.statusToString(newData.status),
        'original_attendance_id': newData.originalAttendanceId,
        'replacement_attendance_id': newData.replacementAttendanceId,
        'updated_at': newData.updatedAt.toUtc().toIso8601String(),
      };
      final res = await supa
          .from('session_overrides')
          .update(base)
          .eq('id', newData.id)
          .eq('version', newData.version)
          .select('version')
          .maybeSingle();
      if (res == null) {
        throw StateError('CONFLICT_SESSION_OVERRIDE_VERSION');
      }
      final newVer = (res['version'] as num?)?.toInt() ?? (newData.version + 1);
      final idx = _sessionOverrides.indexWhere((o) => o.id == newData.id);
      final merged = newData.copyWith(version: newVer);
      if (idx != -1) {
        _sessionOverrides[idx] = merged;
      } else {
        _sessionOverrides.add(merged);
      }
      sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);
      await _regeneratePlannedAttendanceForOverride(merged);
    } catch (e) {
      print('[ERROR] updateSessionOverride 실패: $e');
      rethrow;
    }
  }

  // 운영시간/중복/겹침 검증
  void _validateOverride(SessionOverride ov) {
    // replacement 필수
    final replacement = ov.replacementClassDateTime;
    if (replacement == null) {
      throw Exception('대체 일정이 필요합니다.');
    }
    // 기간 유효성
    final duration = ov.durationMinutes ?? _academySettings.lessonDuration;
    if (duration <= 0 || duration > 360) {
      throw Exception('기간이 올바르지 않습니다. (1~360분)');
    }

    // 겹침 체크용 범위(분 단위)
    final repStart = Duration(hours: replacement.hour, minutes: replacement.minute);
    final repEnd = repStart + Duration(minutes: duration);
    // ✅ 운영시간/휴게시간 검증 제거 (요청 사항)
    // 기존 보강들과 충돌 금지(동일 학생)
    for (final other in _sessionOverrides) {
      if (other.id == ov.id || other.studentId != ov.studentId) continue;
      if (other.status == OverrideStatus.canceled) continue;
      final otherStart = other.replacementClassDateTime ?? other.originalClassDateTime;
      final otherDur = other.durationMinutes ?? _academySettings.lessonDuration;
      if (otherStart == null) continue;
      final otherRangeStart = Duration(hours: otherStart.hour, minutes: otherStart.minute);
      final otherRangeEnd = otherRangeStart + Duration(minutes: otherDur);
      final overlap = repStart < otherRangeEnd && repEnd > otherRangeStart && _isSameDate(replacement, otherStart);
      if (overlap) {
        throw Exception('동일 학생의 다른 보강/예외와 시간이 겹칩니다.');
      }
    }
  }

  bool _isSameDate(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  Future<void> cancelSessionOverride(String id) async {
    try {
      final idx = _sessionOverrides.indexWhere((o) => o.id == id);
      if (idx == -1) return;
      final canceled = _sessionOverrides[idx].copyWith(status: OverrideStatus.canceled, updatedAt: DateTime.now());
      await updateSessionOverride(canceled);
      await _regeneratePlannedAttendanceForOverride(canceled);
    } catch (e) {
      print('[ERROR] cancelSessionOverride 실패: $e');
      rethrow;
    }
  }

  Future<void> deleteSessionOverride(String id) async {
    try {
      SessionOverride? deleted;
      try {
        deleted = _sessionOverrides.firstWhere((o) => o.id == id);
      } catch (_) {}
      final supa = Supabase.instance.client;
      await supa.from('session_overrides').delete().eq('id', id);
      _sessionOverrides.removeWhere((o) => o.id == id);
      sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);
      if (deleted != null && deleted.replacementClassDateTime != null) {
        await _removePlannedAttendanceForDate(
          studentId: deleted.studentId,
          classDateTime: deleted.replacementClassDateTime!,
        );
      }
    } catch (e) {
      print('[ERROR] deleteSessionOverride 실패: $e');
      rethrow;
    }
  }

  List<SessionOverride> getSessionOverridesForStudent(String studentId) {
    return _sessionOverrides.where((o) => o.studentId == studentId).toList();
  }

  void addGroup(GroupInfo groupInfo) {
    _groups.add(groupInfo);
    _groups = _groups.where((g) => g != null).toList();
    _groupsById[groupInfo.id] = groupInfo;
    _notifyListeners();
    saveGroups();
  }

  void updateGroup(GroupInfo groupInfo) {
    _groupsById[groupInfo.id] = groupInfo;
    _groups = _groupsById.values.where((g) => g != null).toList();
    _notifyListeners();
    saveGroups();
  }

  void deleteGroup(GroupInfo groupInfo) {
    if (!_groupsById.containsKey(groupInfo.id)) {
      return;
    }

    _groupsById.remove(groupInfo.id);
    _groups = _groupsById.values.where((g) => g != null).toList();

    final List<StudentWithInfo> affectedStudents = [];
    for (var i = 0; i < _studentsWithInfo.length; i++) {
      final studentWithInfo = _studentsWithInfo[i];
      final String? currentGroupId = studentWithInfo.student.groupInfo?.id ?? studentWithInfo.basicInfo.groupId;
      if (currentGroupId == groupInfo.id) {
        final clearedStudent = studentWithInfo.student.copyWith(clearGroupInfo: true, clearGroupId: true);
        final clearedBasic = studentWithInfo.basicInfo.copyWith(clearGroupId: true);
        final updated = StudentWithInfo(student: clearedStudent, basicInfo: clearedBasic);
        _studentsWithInfo[i] = updated;
        affectedStudents.add(updated);
      }
    }

    _notifyListeners();
    unawaited(_persistGroupDeletion(groupInfo.id, affectedStudents));
  }

  Future<void> _persistGroupDeletion(String groupId, List<StudentWithInfo> clearedStudents) async {
    final List<Future<void>> futures = [];

    futures.add(_deleteGroupFromSupabase(groupId));
    if (clearedStudents.isNotEmpty) {
      futures.add(_clearGroupAssignmentsInSupabase(clearedStudents));
    }

    if (!RuntimeFlags.serverOnly) {
      futures.add(AcademyDbService.instance.deleteGroup(groupId));
      if (clearedStudents.isNotEmpty) {
        futures.add(_clearGroupAssignmentsInLocalDb(clearedStudents));
      }
    }

    futures.add(saveGroups());
    futures.add(saveStudents());

    try {
      await Future.wait(futures);
    } catch (e, st) {
      print('[ERROR][groups delete] 삭제 영속화 실패: $e\n$st');
    }
  }

  Future<void> _clearGroupAssignmentsInSupabase(List<StudentWithInfo> students) async {
    if (students.isEmpty) return;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final rows = students.map((s) {
        return {
          'student_id': s.student.id,
          'academy_id': academyId,
          'phone_number': s.basicInfo.phoneNumber,
          'parent_phone_number': s.basicInfo.parentPhoneNumber,
          'group_id': null,
          'memo': s.basicInfo.memo,
        };
      }).toList();
      await supa.from('student_basic_info').upsert(rows, onConflict: 'student_id');
      print('[GROUPS][students] Cleared group assignments in Supabase: ${students.length}');
    } catch (e, st) {
      print('[SUPA][students clear group] $e\n$st');
      rethrow;
    }
  }

  Future<void> _clearGroupAssignmentsInLocalDb(List<StudentWithInfo> students) async {
    if (students.isEmpty || RuntimeFlags.serverOnly) return;
    for (final s in students) {
      await AcademyDbService.instance.updateStudentBasicInfo(s.student.id, {
        'student_id': s.student.id,
        'phone_number': s.basicInfo.phoneNumber,
        'parent_phone_number': s.basicInfo.parentPhoneNumber,
        'group_id': null,
        'memo': s.basicInfo.memo,
      });
    }
  }

  Future<void> _deleteGroupFromSupabase(String groupId) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      await supa
          .from('groups')
          .delete()
          .eq('academy_id', academyId)
          .eq('id', groupId);
      print('[GROUPS][delete] Supabase 삭제 완료: $groupId');
    } catch (e, st) {
      print('[SUPA][groups delete] $e\n$st');
      rethrow;
    }
  }

  Future<void> addStudent(Student student, StudentBasicInfo basicInfo) async {
    print('[DEBUG][addStudent] student: ' + student.toString());
    print('[DEBUG][addStudent] basicInfo: ' + basicInfo.toString());
    // 그룹 정원 초과 이중 방어
    if (basicInfo.groupId != null) {
      final group = _groupsById[basicInfo.groupId];
      if (group != null && group.capacity != null) {
        final currentCount = _studentsWithInfo.where((s) => s.student.groupInfo?.id == group.id).length;
        if (currentCount >= group.capacity!) {
          throw Exception('정원 초과: ${group.name} 그룹의 정원(${group.capacity})을 초과할 수 없습니다.');
        }
      }
    }
    print('[DEBUG][addStudent] DB에 저장 직전 student.toDb(): ' + student.toDb().toString());
    print('[DEBUG][addStudent] DB에 저장 직전 basicInfo.toDb(): ' + basicInfo.toDb().toString());
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        await supa.from('students').upsert({
          'id': student.id,
          'academy_id': academyId,
          'name': student.name,
          'school': student.school,
          'education_level': student.educationLevel.index,
          'grade': student.grade,
        }, onConflict: 'id');
        await supa.from('student_basic_info').upsert({
          'student_id': student.id,
          'academy_id': academyId,
          'phone_number': basicInfo.phoneNumber,
          'parent_phone_number': basicInfo.parentPhoneNumber,
          'group_id': basicInfo.groupId,
          'memo': basicInfo.memo,
        }, onConflict: 'student_id');
        // registration_date 저장 및 첫 due 생성
        final now = DateTime.now();
        final paymentInfo = StudentPaymentInfo(
          id: const Uuid().v4(),
          studentId: student.id,
          registrationDate: basicInfo.registrationDate ?? now,
          paymentMethod: 'monthly',
          tuitionFee: 0,
          createdAt: now,
          updatedAt: now,
        );
        await Supabase.instance.client.from('student_payment_info').upsert({
          'id': paymentInfo.id,
          'academy_id': academyId,
          'student_id': paymentInfo.studentId,
          'registration_date': paymentInfo.registrationDate.toIso8601String(),
          'payment_method': paymentInfo.paymentMethod,
          'tuition_fee': paymentInfo.tuitionFee,
        }, onConflict: 'student_id');
        await Supabase.instance.client.rpc('init_first_due', params: {
          'p_student_id': paymentInfo.studentId,
          'p_first_due': paymentInfo.registrationDate.toIso8601String().substring(0, 10),
          'p_academy_id': academyId,
        });
      } catch (e, st) { print('[SUPA][addStudent server-only] $e\n$st'); }
      await loadStudents();
      return;
    }

    await AcademyDbService.instance.addStudent(student);
    await AcademyDbService.instance.insertStudentBasicInfo(basicInfo.toDb());
    print('[DEBUG][addStudent] DB 저장 완료');
    await loadStudents();
    if (TagPresetService.dualWrite) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        await supa.from('students').upsert({
          'id': student.id,
          'academy_id': academyId,
          'name': student.name,
          'school': student.school,
          'education_level': student.educationLevel.index,
          'grade': student.grade,
        }, onConflict: 'id');
        await supa.from('student_basic_info').upsert({
          'student_id': student.id,
          'academy_id': academyId,
          'phone_number': basicInfo.phoneNumber,
          'parent_phone_number': basicInfo.parentPhoneNumber,
          'group_id': basicInfo.groupId,
          'memo': basicInfo.memo,
        }, onConflict: 'student_id');
      } catch (e, st) { print('[SUPA][teachers insert] $e\n$st'); }
    }
  }

  Future<void> updateStudent(Student student, StudentBasicInfo basicInfo) async {
    print('[DEBUG][updateStudent] student: ' + student.toString());
    print('[DEBUG][updateStudent] basicInfo: ' + basicInfo.toString());
    // 그룹 정원 초과 이중 방어
    if (basicInfo.groupId != null) {
      final group = _groupsById[basicInfo.groupId];
      if (group != null && group.capacity != null) {
        final currentCount = _studentsWithInfo.where((s) => s.student.groupInfo?.id == group.id && s.student.id != student.id).length;
        if (currentCount >= group.capacity!) {
          throw Exception('정원 초과: ${group.name} 그룹의 정원(${group.capacity})을 초과할 수 없습니다.');
        }
      }
    }
    print('[DEBUG][updateStudent] DB에 저장 직전 student.toDb(): ' + student.toDb().toString());
    print('[DEBUG][updateStudent] DB에 저장 직전 basicInfo.toDb(): ' + basicInfo.toDb().toString());
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        await supa.from('students').upsert({
          'id': student.id,
          'academy_id': academyId,
          'name': student.name,
          'school': student.school,
          'education_level': student.educationLevel.index,
          'grade': student.grade,
        }, onConflict: 'id');
        await supa.from('student_basic_info').upsert({
          'student_id': student.id,
          'academy_id': academyId,
          'phone_number': basicInfo.phoneNumber,
          'parent_phone_number': basicInfo.parentPhoneNumber,
          'group_id': basicInfo.groupId,
          'memo': basicInfo.memo,
        }, onConflict: 'student_id');
      } catch (e, st) { print('[SUPA][updateStudent server-only] $e\n$st'); }
      await loadStudents();
      return;
    }

    await AcademyDbService.instance.updateStudent(student);
    await AcademyDbService.instance.updateStudentBasicInfo(student.id, basicInfo.toDb());
    print('[DEBUG][updateStudent] DB 저장 완료');
    await loadStudents();
    if (TagPresetService.dualWrite) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        await supa.from('students').upsert({
          'id': student.id,
          'academy_id': academyId,
          'name': student.name,
          'school': student.school,
          'education_level': student.educationLevel.index,
          'grade': student.grade,
        }, onConflict: 'id');
        await supa.from('student_basic_info').upsert({
          'student_id': student.id,
          'academy_id': academyId,
          'phone_number': basicInfo.phoneNumber,
          'parent_phone_number': basicInfo.parentPhoneNumber,
          'group_id': basicInfo.groupId,
          'memo': basicInfo.memo,
        }, onConflict: 'student_id');
      } catch (e, st) { print('[SUPA][classes upsert(add)] $e\n$st'); }
    }
  }

  Future<void> deleteStudent(String id) async {
    print('[DEBUG][deleteStudent] 진입: id=$id');
    if (TagPresetService.preferSupabaseRead) {
      final supa = Supabase.instance.client;
      final academyId =
          (await TenantService.instance.getActiveAcademyId()) ??
              await TenantService.instance.ensureActiveAcademy();

      Future<void> timed(String label, Future<void> Function() fn) async {
        final sw = Stopwatch()..start();
        print('[DEBUG][deleteStudent][server-only] $label 시작: id=$id, academyId=$academyId');
        try {
          await fn();
          sw.stop();
          print('[DEBUG][deleteStudent][server-only] $label 완료: elapsedMs=${sw.elapsedMilliseconds}');
        } catch (e, st) {
          sw.stop();
          print('[ERROR][deleteStudent][server-only] $label 실패: elapsedMs=${sw.elapsedMilliseconds} err=$e\n$st');
          rethrow;
        }
      }

      bool isStatementTimeout(dynamic e) {
        if (e is PostgrestException) return e.code == '57014';
        final s = e.toString();
        return s.contains('code: 57014') || (s.contains('57014') && s.toLowerCase().contains('statement timeout'));
      }

      String inFilterForIds(List<String> ids) {
        // PostgREST in filter format: ("id1","id2",...)
        return '(${ids.map((e) => '"$e"').join(',')})';
      }

      Future<List<String>> fetchIdBatch({
        required String table,
        required String studentIdCol,
        bool hasAcademyId = true,
        int limit = 100,
      }) async {
        var q = supa.from(table).select('id').eq(studentIdCol, id);
        if (hasAcademyId) q = q.eq('academy_id', academyId);
        final rows = await q.limit(limit);
        return (rows as List)
            .map((m) => (m as Map)['id']?.toString())
            .whereType<String>()
            .toList();
      }

      Future<int> batchDeleteByStudent({
        required String table,
        String studentIdCol = 'student_id',
        bool hasAcademyId = true,
        int batchSize = 100,
      }) async {
        final sw = Stopwatch()..start();
        int total = 0;
        int batchNo = 0;
        while (true) {
          final ids = await fetchIdBatch(
            table: table,
            studentIdCol: studentIdCol,
            hasAcademyId: hasAcademyId,
            limit: batchSize,
          );
          if (ids.isEmpty) break;
          batchNo++;

          var dq = supa.from(table).delete().filter('id', 'in', inFilterForIds(ids));
          if (hasAcademyId) dq = dq.eq('academy_id', academyId);
          await dq;

          total += ids.length;
          if (batchNo <= 3 || batchNo % 10 == 0) {
            print('[DEBUG][deleteStudent][server-only][hard] $table delete batch=$batchNo size=${ids.length} total=$total');
          }
        }
        sw.stop();
        print('[DEBUG][deleteStudent][server-only][hard] $table delete done: total=$total elapsedMs=${sw.elapsedMilliseconds}');
        return total;
      }

      Future<int> batchNullifyByStudent({
        required String table,
        String studentIdCol = 'student_id',
        bool hasAcademyId = true,
        int batchSize = 100,
      }) async {
        final sw = Stopwatch()..start();
        int total = 0;
        int batchNo = 0;
        while (true) {
          final ids = await fetchIdBatch(
            table: table,
            studentIdCol: studentIdCol,
            hasAcademyId: hasAcademyId,
            limit: batchSize,
          );
          if (ids.isEmpty) break;
          batchNo++;

          var uq = supa.from(table).update({studentIdCol: null}).filter('id', 'in', inFilterForIds(ids));
          if (hasAcademyId) uq = uq.eq('academy_id', academyId);
          await uq;

          total += ids.length;
          if (batchNo <= 3 || batchNo % 10 == 0) {
            print('[DEBUG][deleteStudent][server-only][hard] $table nullify batch=$batchNo size=${ids.length} total=$total');
          }
        }
        sw.stop();
        print('[DEBUG][deleteStudent][server-only][hard] $table nullify done: total=$total elapsedMs=${sw.elapsedMilliseconds}');
        return total;
      }

      Future<void> hardDeleteStudentWithLogs() async {
        print('[WARN][deleteStudent][server-only][hard] 학생 삭제 타임아웃(57014) -> 연관 데이터 배치 삭제로 전환: studentId=$id, academyId=$academyId');

        // 1) FK set-null/연쇄 업데이트 비용을 줄이기 위해 먼저 session_overrides 제거
        await timed('hard: session_overrides 배치 삭제', () async {
          await batchDeleteByStudent(table: 'session_overrides', hasAcademyId: true, batchSize: 100);
        });

        // 2) 출석(가장 큰 테이블일 가능성 높음) 삭제
        await timed('hard: attendance_records 배치 삭제', () async {
          await batchDeleteByStudent(table: 'attendance_records', hasAcademyId: true, batchSize: 120);
        });

        // 3) 결제 레코드 삭제
        await timed('hard: payment_records 배치 삭제', () async {
          await batchDeleteByStudent(table: 'payment_records', hasAcademyId: true, batchSize: 200);
        });

        // 4) 배치/세션 삭제 (academy_id 컬럼 없음)
        await timed('hard: lesson_batch_sessions 배치 삭제', () async {
          await batchDeleteByStudent(table: 'lesson_batch_sessions', hasAcademyId: false, batchSize: 200);
        });
        await timed('hard: lesson_batch_headers 배치 삭제', () async {
          await batchDeleteByStudent(table: 'lesson_batch_headers', hasAcademyId: true, batchSize: 200);
        });

        // 5) 스냅샷 삭제 (attendance_records.snapshot_id FK 때문에 attendance 먼저 삭제)
        await timed('hard: lesson_snapshot_headers 배치 삭제', () async {
          await batchDeleteByStudent(table: 'lesson_snapshot_headers', hasAcademyId: true, batchSize: 200);
        });

        // 6) 시간표 블록 삭제
        await timed('hard: student_time_blocks 배치 삭제', () async {
          await batchDeleteByStudent(table: 'student_time_blocks', hasAcademyId: true, batchSize: 200);
        });

        // 7) on delete set null 대상(규모가 크면 학생 삭제를 느리게 만듦) -> 미리 NULL 처리
        await timed('hard: homework_items student_id null 처리(배치)', () async {
          try {
            await batchNullifyByStudent(table: 'homework_items', hasAcademyId: true, batchSize: 200);
          } catch (e) {
            print('[WARN][deleteStudent][server-only][hard] homework_items nullify 실패(무시): $e');
          }
        });
        await timed('hard: tag_events student_id null 처리(배치)', () async {
          try {
            await batchNullifyByStudent(table: 'tag_events', studentIdCol: 'student_id', hasAcademyId: true, batchSize: 200);
          } catch (e) {
            print('[WARN][deleteStudent][server-only][hard] tag_events nullify 실패(무시): $e');
          }
        });

        // 8) 작은 테이블 정리
        await timed('hard: student_basic_info 삭제', () async {
          await supa.from('student_basic_info').delete().eq('student_id', id).eq('academy_id', academyId);
        });
        await timed('hard: student_payment_info 삭제', () async {
          await supa.from('student_payment_info').delete().eq('student_id', id).eq('academy_id', academyId);
        });

        // 9) 마지막으로 students 삭제 (이 시점엔 cascade 작업량이 매우 줄어야 함)
        await timed('hard: students 최종 삭제', () async {
          await supa.from('students').delete().eq('id', id).eq('academy_id', academyId);
        });
      }

      // ✅ 일부 환경/스키마에서는 학생 삭제가 보강/예외(session_overrides)를 자동 정리하지 못해 orphan이 남을 수 있음.
      // 학생 삭제 전에 session_overrides를 선삭제하여 "학생 삭제 후에도 보강기록이 남는" 문제를 방지한다.
      await timed('session_overrides 삭제(선)', () async {
        await supa.from('session_overrides').delete().eq('student_id', id).eq('academy_id', academyId);
      });
      _sessionOverrides.removeWhere((o) => o.studentId == id);
      sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);

      // 1-shot 삭제 먼저 시도 (빠른 케이스는 여기서 끝)
      try {
        await timed('students 삭제(1-shot)', () async {
          await supa.from('students').delete().eq('id', id).eq('academy_id', academyId);
        });
      } catch (e) {
        if (isStatementTimeout(e)) {
          await hardDeleteStudentWithLogs();
        } else {
          rethrow;
        }
      }

      await loadStudents();
      await loadStudentTimeBlocks();
      return;
    }

    // 학생의 모든 수업시간 블록도 함께 삭제
    await AcademyDbService.instance.deleteStudentTimeBlocksByStudentId(id);
    print('[DEBUG][deleteStudent] StudentTimeBlock 삭제 완료: id=$id');
    // 학생의 보강/예외(SessionOverride)도 함께 삭제
    await AcademyDbService.instance.deleteSessionOverridesByStudentId(id);
    print('[DEBUG][deleteStudent] SessionOverrides 삭제 완료: id=$id');
    _sessionOverrides.removeWhere((o) => o.studentId == id);
    sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);
    // 학생의 부가 정보도 함께 삭제
    await AcademyDbService.instance.deleteStudentBasicInfo(id);
    print('[DEBUG][deleteStudent] StudentBasicInfo 삭제 완료: id=$id');
    await AcademyDbService.instance.deleteStudent(id);
    print('[DEBUG][deleteStudent] DB 삭제 완료: id=$id');
    // 학생의 예정 출석도 정리
    try {
      final supa = Supabase.instance.client;
      final academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      // ✅ 보강/예외(SessionOverride)도 서버에서 함께 제거(세션 오버라이드는 Supabase에서 로드됨)
      await supa.from('session_overrides').delete()
        .eq('student_id', id)
        .eq('academy_id', academyId);
      await supa.from('attendance_records').delete()
        .eq('student_id', id)
        .eq('academy_id', academyId)
        .eq('is_planned', true);
      await AttendanceService.instance.loadAttendanceRecords();
      print('[DEBUG][deleteStudent] planned attendance 삭제 완료: id=$id');
    } catch (e) {
      print('[WARN][deleteStudent] planned attendance 삭제 실패: $e');
    }
    await loadStudents();
    print('[DEBUG][deleteStudent] loadStudents() 호출 완료');
    await loadStudentTimeBlocks();
    print('[DEBUG][deleteStudent] loadStudentTimeBlocks() 호출 완료');
    if (TagPresetService.dualWrite) {
      try {
        final supa = Supabase.instance.client;
        await supa.from('student_basic_info').delete().eq('student_id', id);
        await supa.from('student_payment_info').delete().eq('student_id', id);
        await supa.from('students').delete().eq('id', id);
      } catch (e, st) { print('[SUPA][classes upsert(update)] $e\n$st'); }
    }
  }

  // StudentBasicInfo만 업데이트하는 메소드
  Future<void> updateStudentBasicInfo(String studentId, StudentBasicInfo basicInfo) async {
    print('[DEBUG][updateStudentBasicInfo] studentId: $studentId');
    print('[DEBUG][updateStudentBasicInfo] basicInfo: ${basicInfo.toString()}');
    
    try {
      if (TagPresetService.preferSupabaseRead) {
        try {
          final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
          await Supabase.instance.client.from('student_basic_info').upsert({
            'student_id': studentId,
            'academy_id': academyId,
            'phone_number': basicInfo.phoneNumber,
            'parent_phone_number': basicInfo.parentPhoneNumber,
            'group_id': basicInfo.groupId,
            'memo': basicInfo.memo,
          }, onConflict: 'student_id');
        } catch (e, st) { print('[SUPA][updateStudentBasicInfo server-only] $e\n$st'); }
        await loadStudents();
        return;
      }

      // 로컬 경로
      await AcademyDbService.instance.updateStudentBasicInfo(studentId, basicInfo.toDb());
      print('[DEBUG][updateStudentBasicInfo] DB 저장 완료');
      
      // 메모리 상태 최신화
      await loadStudents();
      print('[DEBUG][updateStudentBasicInfo] 메모리 상태 최신화 완료');
      if (TagPresetService.dualWrite) {
        try {
          final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
          await Supabase.instance.client.from('student_basic_info').upsert({
            'student_id': studentId,
            'academy_id': academyId,
            'phone_number': basicInfo.phoneNumber,
            'parent_phone_number': basicInfo.parentPhoneNumber,
            'group_id': basicInfo.groupId,
            'memo': basicInfo.memo,
          }, onConflict: 'student_id');
        } catch (e, st) { print('[SUPA][student_payment_info upsert(update)] $e\n$st'); }
      }
    } catch (e) {
      print('[ERROR][updateStudentBasicInfo] 오류 발생: $e');
      rethrow;
    }
  }

  void updateStudentGroup(Student student, GroupInfo? newGroup) {
    final index = _studentsWithInfo.indexWhere((si) => si.student.id == student.id);
    if (index != -1) {
      _studentsWithInfo[index] = StudentWithInfo(student: student.copyWith(groupInfo: newGroup), basicInfo: _studentsWithInfo[index].basicInfo);
      _notifyListeners();
      saveStudents();
    }
  }

  Future<void> saveOperatingHours(List<OperatingHours> hours) async {
    try {
      _operatingHours = hours;
      // 서버 전용 모드에서는 로컬 저장을 생략 (메모리 DB 초기 스키마 의존성 제거)
      if (!RuntimeFlags.serverOnly) {
        await AcademyDbService.instance.saveOperatingHours(hours);
      }
      if (TagPresetService.dualWrite) {
        try {
          final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
          final supa = Supabase.instance.client;
          await supa.from('operating_hours').delete().eq('academy_id', academyId);
          if (hours.isNotEmpty) {
            final rows = hours.map((h) => {
              'academy_id': academyId,
              'day_of_week': h.dayOfWeek,
              'start_time': '${h.startHour.toString().padLeft(2,'0')}:${h.startMinute.toString().padLeft(2,'0')}',
              'end_time': '${h.endHour.toString().padLeft(2,'0')}:${h.endMinute.toString().padLeft(2,'0')}',
              'break_times': (h.breakTimes.isEmpty)
                  ? null
                  : jsonEncode(h.breakTimes.map((b)=>{
                      'startHour': b.startHour,
                      'startMinute': b.startMinute,
                      'endHour': b.endHour,
                      'endMinute': b.endMinute,
                    }).toList()),
            }).toList();
            await supa.from('operating_hours').insert(rows);
          }
        } catch (e, st) { print('[SUPA][student_payment_info delete] $e\n$st'); }
      }
    } catch (e) {
      print('Error saving operating hours: $e');
      throw Exception('Failed to save operating hours');
    }
  }

  Future<List<OperatingHours>> getOperatingHours() async {
    if (_operatingHours.isNotEmpty) {
      return _operatingHours;
    }

    try {
      List<OperatingHours> raw;
      if (TagPresetService.preferSupabaseRead) {
        try {
          final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
          final data = await Supabase.instance.client
              .from('operating_hours')
              .select('day_of_week,start_time,end_time,break_times')
              .eq('academy_id', academyId)
              .order('day_of_week');
          raw = (data as List).map((m){
            String? parseTime(String? t){ return t; }
            int hh(String? t){ if(t==null||t.length<2) return 0; return int.tryParse(t.split(':').first)??0; }
            int mm(String? t){ if(t==null||!t.contains(':')) return 0; return int.tryParse(t.split(':').last)??0; }
            List<BreakTime> breaks = [];
            try{
              final bt = m['break_times'];
              if (bt != null) {
                final arr = (bt is String) ? jsonDecode(bt) : bt;
                breaks = (arr as List).map((e)=>BreakTime.fromJson(Map<String,dynamic>.from(e))).toList();
              }
            } catch(_){}
            return OperatingHours(
              dayOfWeek: (m['day_of_week'] as int?) ?? 0,
              startHour: hh(m['start_time'] as String?),
              startMinute: mm(m['start_time'] as String?),
              endHour: hh(m['end_time'] as String?),
              endMinute: mm(m['end_time'] as String?),
              breakTimes: breaks,
            );
          }).toList();
        } catch (_) {
          raw = await AcademyDbService.instance.getOperatingHours();
        }
      } else {
        raw = await AcademyDbService.instance.getOperatingHours();
      }
      // 0=월, 1=화, ..., 6=일로 정렬/매핑
      List<OperatingHours?> weekHours = List.filled(7, null);
      for (final h in raw) {
        if (h.dayOfWeek >= 0 && h.dayOfWeek <= 6) {
          weekHours[h.dayOfWeek] = h;
        }
      }
      _operatingHours = weekHours.whereType<OperatingHours>().toList();
    } catch (e) {
      print('Error loading operating hours: $e');
      _operatingHours = [];
    }

    return _operatingHours;
  }

  Future<void> savePaymentType(PaymentType type) async {
    // _storage 관련 코드와 json/hive 기반 메서드 전체를 완전히 삭제
  }

  Future<void> loadPaymentType() async {
    // _storage 관련 코드와 json/hive 기반 메서드 전체를 완전히 삭제
  }

  Future<void> _loadOperatingHours() async {
    // _storage 관련 코드와 json/hive 기반 메서드 전체를 완전히 삭제
  }

  Future<void> loadStudentTimeBlocks() async {
    final tsStart = DateTime.now();
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        // ✅ 서버 응답 max rows(예: 1000) 제한에 걸리면 일부만 로드되어 "기존 블록이 사라져 보이는" 문제가 생길 수 있다.
        // → (1) 페이지네이션(range) + (2) 아주 오래된 종료 이력은 제외(lookback)로 안정화/최적화.
        const int pageSize = 1000;
        const int lookbackDays = 180; // 결제 사이클/회차(session_order) 안정화를 위해 충분히 넉넉하게 유지
        final today = _todayDateOnly();
        final minEnd = today.subtract(const Duration(days: lookbackDays));
        final minEndYmd = _ymd(minEnd);

        final List<StudentTimeBlock> out = <StudentTimeBlock>[];
        int from = 0;
        while (true) {
          final data = await Supabase.instance.client
              .from('student_time_blocks')
              .select('id,student_id,day_index,start_hour,start_minute,duration,block_created_at,start_date,end_date,set_id,number,session_type_id,weekly_order')
              .eq('academy_id', academyId)
              // "열려있거나, 최근 lookback 기간 내에 종료된 것"만 유지(아주 오래된 이력은 week-cache로 조회)
              .or('end_date.is.null,end_date.gte.$minEndYmd')
              .order('day_index')
              .order('start_hour')
              .order('start_minute')
              .order('id')
              .range(from, from + pageSize - 1);
          final list = (data as List).cast<Map<String, dynamic>>();
          for (final m in list) {
            final b = _stbFromServerRow(m);
            if (b.id.isEmpty || b.studentId.isEmpty) continue;
            out.add(b);
          }
          if (list.length < pageSize) break;
          from += pageSize;
        }
        _studentTimeBlocks = out;
        _publishStudentTimeBlocks();
        // debug log trimmed: keep minimal noise
        print('[STB][load] source=supabase count=${_studentTimeBlocks.length} elapsedMs=${DateTime.now().difference(tsStart).inMilliseconds}');
        return;
      } catch (e) {
        print('[DEBUG] student_time_blocks Supabase 로드 실패, 로컬로 폴백: $e');
      }
    }

    final rawBlocks = await AcademyDbService.instance.getStudentTimeBlocks();
    _studentTimeBlocks = rawBlocks;
    _publishStudentTimeBlocks();
    print('[STB][load] source=local count=${_studentTimeBlocks.length} elapsedMs=${DateTime.now().difference(tsStart).inMilliseconds}');
  }

  Future<void> saveStudentTimeBlocks() async {
    await AcademyDbService.instance.saveStudentTimeBlocks(_studentTimeBlocks);
  }

  Future<void> addStudentTimeBlock(StudentTimeBlock block) async {
    final dateOnly = DateTime(block.startDate.year, block.startDate.month, block.startDate.day);
    final normalized = block.copyWith(
      startDate: dateOnly,
      endDate: block.endDate != null ? DateTime(block.endDate!.year, block.endDate!.month, block.endDate!.day) : null,
    );
    // 중복 체크: 같은 학생, 같은 요일, 같은 시작시간, 같은 duration 블록이 이미 있으면 등록 금지
    final activeAtDate = _activeBlocks(dateOnly);
    final exists = activeAtDate.any((b) =>
      b.studentId == normalized.studentId &&
      b.dayIndex == normalized.dayIndex &&
      b.startHour == normalized.startHour &&
      b.startMinute == normalized.startMinute
    );
    if (exists) {
      final dupes = activeAtDate.where((b) =>
        b.studentId == normalized.studentId &&
        b.dayIndex == normalized.dayIndex &&
        b.startHour == normalized.startHour &&
        b.startMinute == normalized.startMinute
      ).map((b) => '${b.id}|sess=${b.sessionTypeId}|sd=${b.startDate.toIso8601String().split("T").first}|ed=${b.endDate?.toIso8601String().split("T").first}|set=${b.setId}').toList();
      print('[STB][add][conflict] ref=$dateOnly new=${normalized.id}|set=${normalized.setId}|sess=${normalized.sessionTypeId}|day=${normalized.dayIndex}|t=${normalized.startHour}:${normalized.startMinute} existing=$dupes');
      throw Exception('이미 등록된 시간입니다.');
    }
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final row = <String, dynamic>{
          'id': normalized.id,
          'academy_id': academyId,
          'student_id': normalized.studentId,
          'day_index': normalized.dayIndex,
          'start_hour': normalized.startHour,
          'start_minute': normalized.startMinute,
          'duration': normalized.duration.inMinutes,
          'block_created_at': normalized.createdAt.toIso8601String(),
          'start_date': normalized.startDate.toIso8601String().split('T').first,
          'end_date': normalized.endDate?.toIso8601String().split('T').first,
          'set_id': normalized.setId,
          'number': normalized.number,
          'session_type_id': normalized.sessionTypeId,
          'weekly_order': normalized.weeklyOrder,
        }..removeWhere((k, v) => v == null);
        print('[STB][add][supabase] row=$row');
        await Supabase.instance.client.from('student_time_blocks').upsert(row, onConflict: 'id');
        _studentTimeBlocks.add(normalized);
        _publishStudentTimeBlocks(refDate: dateOnly);
        if (normalized.setId != null) {
          await _recalculateWeeklyOrderForStudent(normalized.studentId);
        }
        if (normalized.setId != null) {
          _schedulePlannedRegen(
            normalized.studentId,
            normalized.setId!,
            effectiveStart: normalized.startDate,
          );
        }
        return;
      } catch (e, st) {
        print('[SUPA][stb add] $e\n$st');
        rethrow;
      }
    }
    _studentTimeBlocks.add(normalized);
    _publishStudentTimeBlocks(refDate: dateOnly);
    await AcademyDbService.instance.addStudentTimeBlock(normalized);
    if (normalized.setId != null) {
      await _recalculateWeeklyOrderForStudent(normalized.studentId);
    }
    if (normalized.setId != null) {
      _schedulePlannedRegen(
        normalized.studentId,
        normalized.setId!,
        effectiveStart: normalized.startDate,
      );
    }
  }

  Future<void> removeStudentTimeBlock(String id) async {
    String? sidForSync;
    final today = _todayDateOnly();
    final endDate = today.subtract(const Duration(days: 1));
    if (TagPresetService.preferSupabaseRead) {
      try {
        final removed = _studentTimeBlocks.where((b) => b.id == id).toList();
        sidForSync = removed.isNotEmpty ? removed.first.studentId : null;
        await Supabase.instance.client.from('student_time_blocks').update({
          'end_date': endDate.toIso8601String().split('T').first,
        }).eq('id', id);
        _studentTimeBlocks = _studentTimeBlocks.map((b) => b.id == id ? b.copyWith(endDate: endDate) : b).toList();
        _publishStudentTimeBlocks(refDate: today);
        if (sidForSync != null) {
          final remain = _studentTimeBlocks.where((b) => b.studentId == sidForSync).toList();
          final remainSets = remain.where((b) => b.setId != null && b.setId!.isNotEmpty).map((b) => b.setId!).toSet();
          print('[SYNC][remove] after single delete: studentId=$sidForSync blocks=${remain.length} setIds=$remainSets');
        }
        return;
      } catch (e, st) {
        print('[SUPA][stb delete] $e\n$st');
        rethrow;
      }
    }
    final removed = _studentTimeBlocks.where((b) => b.id == id).toList();
    sidForSync = removed.isNotEmpty ? removed.first.studentId : null;
    _studentTimeBlocks = _studentTimeBlocks.map((b) => b.id == id ? b.copyWith(endDate: endDate) : b).toList();
    _publishStudentTimeBlocks(refDate: today);
    await AcademyDbService.instance.closeStudentTimeBlocks([id], endDate);
    if (sidForSync != null) {
      final remain = _studentTimeBlocks.where((b) => b.studentId == sidForSync).toList();
      final remainSets = remain.where((b) => b.setId != null && b.setId!.isNotEmpty).map((b) => b.setId!).toSet();
      print('[SYNC][remove-local] after single delete: studentId=$sidForSync blocks=${remain.length} setIds=$remainSets');
    }
  }

  Timer? _uiUpdateTimer;
  Timer? _plannedRegenTimer;
  final Map<String, Set<String>> _pendingRegenSetIdsByStudent = {};
  final Map<String, DateTime> _pendingRegenEffectiveStartByStudent = {};
  final List<StudentTimeBlock> _pendingTimeBlocks = [];
  RealtimeChannel? _rtStudentTimeBlocks;
  StreamSubscription<AuthState>? _authSub;

  void _removeStudentTimeBlockFromWeekCaches(String id) {
    final bid = id.trim();
    if (bid.isEmpty) return;
    if (_studentTimeBlocksByWeek.isEmpty) return;
    for (final key in _studentTimeBlocksByWeek.keys.toList()) {
      final current = _studentTimeBlocksByWeek[key];
      if (current == null || current.isEmpty) continue;
      final next = current.where((b) => b.id != bid).toList();
      if (next.length == current.length) continue;
      _studentTimeBlocksByWeek[key] = List.unmodifiable(next);
    }
  }

  void _upsertStudentTimeBlockIntoWeekCaches(StudentTimeBlock b) {
    if (b.id.isEmpty) return;
    if (_studentTimeBlocksByWeek.isEmpty) return;
    for (final key in _studentTimeBlocksByWeek.keys.toList()) {
      final weekStart = DateTime.tryParse(key);
      if (weekStart == null) continue;
      final weekEnd = weekStart.add(const Duration(days: 6));
      if (!_overlapsRange(b, weekStart, weekEnd)) continue;
      final current = _studentTimeBlocksByWeek[key] ?? const <StudentTimeBlock>[];
      final next = current.where((x) => x.id != b.id).toList()
        ..add(b);
      next.sort((a, b) {
        final c1 = a.dayIndex.compareTo(b.dayIndex);
        if (c1 != 0) return c1;
        final c2 = a.startHour.compareTo(b.startHour);
        if (c2 != 0) return c2;
        final c3 = a.startMinute.compareTo(b.startMinute);
        if (c3 != 0) return c3;
        return a.createdAt.compareTo(b.createdAt);
      });
      _studentTimeBlocksByWeek[key] = List.unmodifiable(next);
    }
  }

  void _applyStudentTimeBlocksRealtimePayload(dynamic payload) {
    try {
      final dynamic p = payload;
      final dynamic newRec = p.newRecord;
      final dynamic oldRec = p.oldRecord;

      Map<String, dynamic>? newMap;
      Map<String, dynamic>? oldMap;
      if (newRec is Map && newRec.isNotEmpty) {
        newMap = Map<String, dynamic>.from(newRec as Map);
      }
      if (oldRec is Map && oldRec.isNotEmpty) {
        oldMap = Map<String, dynamic>.from(oldRec as Map);
      }

      // 일부 환경에서는 payload에 레코드가 없을 수 있으므로 안전 폴백
      if ((newMap == null || newMap.isEmpty) && (oldMap == null || oldMap.isEmpty)) {
        _bumpStudentTimeBlocksRevision();
        _debouncedReload(loadStudentTimeBlocks);
        return;
      }

      if (newMap != null && newMap.isNotEmpty) {
        // insert/update: upsert
        final bNew = _stbFromServerRow(newMap);
        if (bNew.id.isEmpty) {
          _bumpStudentTimeBlocksRevision();
          _debouncedReload(loadStudentTimeBlocks);
          return;
        }
        final idx = _studentTimeBlocks.indexWhere((b) => b.id == bNew.id);
        if (idx == -1) {
          _studentTimeBlocks.add(bNew);
        } else {
          _studentTimeBlocks[idx] = bNew;
        }
        // week-cache도 즉시 반영(기존 id 제거 후, 현재 겹치는 주에만 추가)
        _removeStudentTimeBlockFromWeekCaches(bNew.id);
        _upsertStudentTimeBlockIntoWeekCaches(bNew);
      } else {
        // delete: remove
        final id = (oldMap?['id'] as String?)?.trim() ?? '';
        if (id.isEmpty) {
          _bumpStudentTimeBlocksRevision();
          _debouncedReload(loadStudentTimeBlocks);
          return;
        }
        _studentTimeBlocks.removeWhere((b) => b.id == id);
        _pendingTimeBlocks.removeWhere((b) => b.id == id);
        _removeStudentTimeBlockFromWeekCaches(id);
      }

      _publishStudentTimeBlocks();
      _bumpStudentTimeBlocksRevision();
    } catch (e, st) {
      print('[STB][rt] payload apply failed: $e\n$st');
      _bumpStudentTimeBlocksRevision();
      _debouncedReload(loadStudentTimeBlocks);
    }
  }

  Future<void> _subscribeStudentTimeBlocksRealtime() async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      _rtStudentTimeBlocks ??= Supabase.instance.client.channel('public:student_time_blocks:$academyId')
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'student_time_blocks',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (payload) async { _applyStudentTimeBlocksRealtimePayload(payload); },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'student_time_blocks',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (payload) async { _applyStudentTimeBlocksRealtimePayload(payload); },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'student_time_blocks',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (payload) async { _applyStudentTimeBlocksRealtimePayload(payload); },
        )
        ..subscribe();
    } catch (_) {}
  }

  // generic debouncer
  Timer? _debounceTimer;
  void _debouncedReload(Future<void> Function() loader, {Duration delay = const Duration(milliseconds: 500)}) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(delay, () async {
      try { await loader(); } catch (_) {}
    });
  }

  Future<void> _subscribeStudentsInvalidation() async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      final chan = Supabase.instance.client.channel('public:students:' + academyId)
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public', table: 'students',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (_) { studentsRevision.value++; _debouncedReload(loadStudents); },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public', table: 'students',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (_) { studentsRevision.value++; _debouncedReload(loadStudents); },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public', table: 'students',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (_) { studentsRevision.value++; _debouncedReload(loadStudents); },
        )
        ..subscribe();
    } catch (_) {}
  }

  Future<void> _subscribeStudentBasicInfoInvalidation() async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      final chan = Supabase.instance.client.channel('public:student_basic_info:' + academyId)
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public', table: 'student_basic_info',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (_) { studentBasicInfoRevision.value++; _debouncedReload(loadStudents); },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public', table: 'student_basic_info',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (_) { studentBasicInfoRevision.value++; _debouncedReload(loadStudents); },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public', table: 'student_basic_info',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (_) { studentBasicInfoRevision.value++; _debouncedReload(loadStudents); },
        )
        ..subscribe();
    } catch (_) {}
  }

  Future<void> _subscribeStudentPaymentInfoInvalidation() async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      final chan = Supabase.instance.client.channel('public:student_payment_info:' + academyId)
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public', table: 'student_payment_info',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (_) { studentPaymentInfoRevision.value++; _debouncedReload(loadStudentPaymentInfos); },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public', table: 'student_payment_info',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (_) { studentPaymentInfoRevision.value++; _debouncedReload(loadStudentPaymentInfos); },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public', table: 'student_payment_info',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (_) { studentPaymentInfoRevision.value++; _debouncedReload(loadStudentPaymentInfos); },
        )
        ..subscribe();
    } catch (_) {}
  }

  void _subscribeAuthChanges() {
    _authSub ??= Supabase.instance.client.auth.onAuthStateChange.listen((AuthState state) async {
      try {
        if (state.event == AuthChangeEvent.signedIn || state.event == AuthChangeEvent.tokenRefreshed) {
          try { await TenantService.instance.ensureActiveAcademy(); } catch (_) {}
          // 1) 첫 로그인/재로그인 시, 이메일로 교사-사용자 연결 및 멤버십 보장
          try {
            final client = Supabase.instance.client;
            final email = client.auth.currentUser?.email;
            if (email != null && email.isNotEmpty) {
              final aid = await TenantService.instance.getActiveAcademyId();
              final allow = await client.rpc('is_teacher_email_allowed', params: {'p_email': email});
              if (allow is bool && allow) {
                await client.rpc('join_academy_by_email', params: {'p_email': email, 'p_academy_id': aid});
              }
            }
          } catch (_) {}
          await reloadAllData();
        } else if (state.event == AuthChangeEvent.signedOut) {
          // 세션 종료 시 민감 데이터 비움
          _studentsWithInfo = [];
          _studentTimeBlocks = [];
          studentsNotifier.value = List.unmodifiable(_studentsWithInfo);
          _publishStudentTimeBlocks();
        }
      } catch (_) {}
    });
  }

  Future<void> reloadAllData() async {
    try { await loadGroups(); } catch (_) {}
    try { await loadStudentPaymentInfos(); } catch (_) {}
    try { await loadStudents(); } catch (_) {}
    try { await loadAcademySettings(); } catch (_) {}
    try { await loadPaymentType(); } catch (_) {}
    try { await _loadOperatingHours(); } catch (_) {}
    try { await loadStudentTimeBlocks(); } catch (_) {}
    try { await loadSessionOverrides(); } catch (_) {}
    try { await loadSelfStudyTimeBlocks(); } catch (_) {}
    try { await loadGroupSchedules(); } catch (_) {}
    try { await loadTeachers(); } catch (_) {}
    try { await loadClasses(); } catch (_) {}
    try { await loadPaymentRecords(); } catch (_) {}
    try { await AttendanceService.instance.loadLessonOccurrences(); } catch (_) {}
    try { await loadAttendanceRecords(); } catch (_) {}
    try { await loadMemos(); } catch (_) {}
    try { await loadResourceFolders(); } catch (_) {}
    try { await loadResourceFiles(); } catch (_) {}
    try { await TagPresetService.instance.loadPresets(); } catch (_) {}
    try { await TagStore.instance.loadAllFromDb(); } catch (_) {}
    try { await _generatePlannedAttendanceForNextDays(days: 15); } catch (_) {}
  }
  
  Future<void> bulkAddStudentTimeBlocks(
    List<StudentTimeBlock> blocks, {
    bool immediate = false,
    bool injectLocal = true,
    bool skipOverlapCheck = false,
  }) async {
    if (blocks.isEmpty) {
      print('[SUPA][stb bulk add] skip empty payload');
      return;
    }
    print('[SUPA][stb bulk add][start] count=${blocks.length} immediate=$immediate injectLocal=$injectLocal skipOverlap=$skipOverlapCheck sample=${blocks.take(3).map((b)=>'${b.studentId}:${b.sessionTypeId}:${b.setId}:${b.startDate.toIso8601String().split("T").first}').toList()}');
    // 중복 및 시간 겹침 방어: 모든 블록에 대해 검사
    final normalizedBlocks = blocks.map((b) {
      final sd = DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
      final ed = b.endDate != null ? DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day) : null;
      return b.copyWith(startDate: sd, endDate: ed);
    }).toList();

    if (!skipOverlapCheck) {
      for (final newBlock in normalizedBlocks) {
        final overlap = _activeBlocks(newBlock.startDate).any((b) =>
          b.studentId == newBlock.studentId &&
          b.dayIndex == newBlock.dayIndex &&
          // 시간 겹침 검사
          (newBlock.startHour * 60 + newBlock.startMinute) < (b.startHour * 60 + b.startMinute + b.duration.inMinutes) &&
          (b.startHour * 60 + b.startMinute) < (newBlock.startHour * 60 + newBlock.startMinute + newBlock.duration.inMinutes)
        );
        if (overlap) {
          throw Exception('이미 등록된 시간과 겹칩니다.');
        }
      }
    } else {
      print('[SUPA][stb bulk add] overlap check skipped (caller requested)');
    }
    
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final sessionTypes = normalizedBlocks.map((b) => b.sessionTypeId).toSet();
        print('[SYNC][bulkAdd] count=${normalizedBlocks.length}, sessionTypes=$sessionTypes, sample=${normalizedBlocks.take(5).map((b)=>'${b.id}:${b.sessionTypeId}:${b.setId}').toList()}');
        final rows = normalizedBlocks.map((b) => <String, dynamic>{
          'id': b.id,
          'academy_id': academyId,
          'student_id': b.studentId,
          'day_index': b.dayIndex,
          'start_hour': b.startHour,
          'start_minute': b.startMinute,
          'duration': b.duration.inMinutes,
          'block_created_at': b.createdAt.toIso8601String(),
          'start_date': b.startDate.toIso8601String().split('T').first,
          'end_date': b.endDate?.toIso8601String().split('T').first,
          'set_id': b.setId,
          'number': b.number,
          'session_type_id': b.sessionTypeId,
          'weekly_order': b.weeklyOrder,
        }..removeWhere((k, v) => v == null)).toList();
        print('[SUPA][stb bulk add] rows=${rows.length} first=${rows.isNotEmpty ? rows.first : 'none'}');
        await Supabase.instance.client.from('student_time_blocks').upsert(rows, onConflict: 'id');
        if (injectLocal) {
          _studentTimeBlocks.addAll(normalizedBlocks);
        }
      } catch (e, st) {
        print('[SUPA][stb bulk add][error] $e\n$st');
        rethrow;
      }
    } else {
    if (injectLocal) {
      _studentTimeBlocks.addAll(normalizedBlocks);
    }
    print('[SYNC][bulkAdd-local] count=${normalizedBlocks.length}, sessionTypes=${normalizedBlocks.map((b)=>b.sessionTypeId).toSet()}, sample=${normalizedBlocks.take(5).map((b)=>'${b.id}:${b.sessionTypeId}:${b.setId}').toList()}');
    await AcademyDbService.instance.bulkAddStudentTimeBlocks(normalizedBlocks);
    }
    
    final affectedStudents = normalizedBlocks.map((b) => b.studentId).toSet();
    if (immediate || blocks.length == 1) {
      // 단일 블록이나 즉시 반영 요청 시 바로 업데이트
      _publishStudentTimeBlocks();
      _bumpStudentTimeBlocksRevision();
    } else {
      // 다중 블록은 debouncing으로 지연 (150ms 후 한 번에 반영)
      _uiUpdateTimer?.cancel();
      _uiUpdateTimer = Timer(const Duration(milliseconds: 150), () {
        _publishStudentTimeBlocks();
        _bumpStudentTimeBlocksRevision();
      });
    }
    // 블록 추가 후 주간 순번 재계산 (대상 학생들만)
    for (final studentId in affectedStudents) {
      await _recalculateWeeklyOrderForStudent(studentId);
    }
    // 예정 출석 재생성 (setId가 있는 블록) - 학생별로 setId를 모아서 한 번씩만 수행
    for (final b in normalizedBlocks.where((e) => e.setId != null)) {
      _schedulePlannedRegen(
        b.studentId,
        b.setId!,
        effectiveStart: b.startDate,
      );
    }
  }

  Future<void> bulkAddStudentTimeBlocksDeferred(List<StudentTimeBlock> blocks) async {
    // 기존 overlap 방어 로직 재사용
    final normalizedBlocks = blocks.map((b) {
      final sd = DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
      final ed = b.endDate != null ? DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day) : null;
      return b.copyWith(startDate: sd, endDate: ed);
    }).toList();

    // ✅ 성능: 같은 start_date에 대해 _activeBlocks(date)를 반복 계산하지 않도록 캐시한다.
    final Map<String, List<StudentTimeBlock>> activeByDate = <String, List<StudentTimeBlock>>{};
    for (final newBlock in normalizedBlocks) {
      final d = DateTime(newBlock.startDate.year, newBlock.startDate.month, newBlock.startDate.day);
      final key = _ymd(d);
      final active = activeByDate.putIfAbsent(key, () => _activeBlocks(d));
      final overlap = active.any((b) =>
        b.studentId == newBlock.studentId &&
        b.dayIndex == newBlock.dayIndex &&
        (newBlock.startHour * 60 + newBlock.startMinute) < (b.startHour * 60 + b.startMinute + b.duration.inMinutes) &&
        (b.startHour * 60 + b.startMinute) < (newBlock.startHour * 60 + newBlock.startMinute + newBlock.duration.inMinutes)
      );
      if (overlap) {
        throw Exception('이미 등록된 시간과 겹칩니다.');
      }
    }
    _pendingTimeBlocks.addAll(normalizedBlocks);
    _studentTimeBlocks.addAll(normalizedBlocks);
    _publishStudentTimeBlocks();
    _bumpStudentTimeBlocksRevision();
  }

  List<StudentTimeBlock> get pendingStudentTimeBlocks => List.unmodifiable(_pendingTimeBlocks);

  Future<void> discardPendingTimeBlocks(String studentId, {Set<String>? setIds}) async {
    final sid = studentId.trim();
    if (sid.isEmpty) return;

    // ✅ 중요:
    // ESC 취소는 "pending(아직 저장되지 않은) 블록만" 폐기해야 한다.
    // 기존 구현처럼 setIds==null일 때 studentId 기준으로 _studentTimeBlocks를 통째로 remove하면,
    // - 정원(그리드) / 시간기록 다이얼로그(= _studentTimeBlocks 기반)에서 기존 블록이 사라지고
    // - 셀 선택 리스트(= week-cache 기반)에는 서버 캐시가 남아 보이는
    // 불일치/깜빡임이 발생한다.
    //
    // 따라서 pending 목록에서 대상 블록 id를 먼저 확정한 뒤, 그 id만 제거한다.
    final Set<String> pendingIds = _pendingTimeBlocks
        .where((b) {
          if (b.studentId != sid) return false;
          if (setIds == null) return true;
          final s = (b.setId ?? '').trim();
          return s.isNotEmpty && setIds.contains(s);
        })
        .map((b) => b.id)
        .where((id) => id.isNotEmpty)
        .toSet();

    if (pendingIds.isEmpty) return;

    _pendingTimeBlocks.removeWhere((b) => pendingIds.contains(b.id));
    _studentTimeBlocks.removeWhere((b) => pendingIds.contains(b.id));
    _publishStudentTimeBlocks();
    _bumpStudentTimeBlocksRevision();
  }

  Future<void> flushPendingTimeBlocks({bool generatePlanned = true}) async {
    if (_pendingTimeBlocks.isEmpty) return;
    final pending = List<StudentTimeBlock>.from(_pendingTimeBlocks);
    _pendingTimeBlocks.clear();

    final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
    final rows = pending.map((b) => <String, dynamic>{
      'id': b.id,
      'academy_id': academyId,
      'student_id': b.studentId,
      'day_index': b.dayIndex,
      'start_hour': b.startHour,
      'start_minute': b.startMinute,
      'duration': b.duration.inMinutes,
      'block_created_at': b.createdAt.toIso8601String(),
      'start_date': b.startDate.toIso8601String().split('T').first,
      'end_date': b.endDate?.toIso8601String().split('T').first,
      'set_id': b.setId,
      'number': b.number,
      'session_type_id': b.sessionTypeId,
      'weekly_order': b.weeklyOrder,
    }..removeWhere((k, v) => v == null)).toList();
    try {
      print('[SUPA][stb flushPending] rows=${rows.length} first=${rows.isNotEmpty ? rows.first : 'none'}');
      await Supabase.instance.client.from('student_time_blocks').upsert(rows, onConflict: 'id');
    } catch (e, st) {
      print('[SUPA][stb flushPending] $e\n$st');
      rethrow;
    }

    final affectedStudents = pending.map((b) => b.studentId).toSet();
    for (final sid in affectedStudents) {
      await _recalculateWeeklyOrderForStudent(sid);
    }

    if (generatePlanned) {
      final Map<String, Set<String>> setIdsByStudent = {};
      for (final b in pending.where((e) => e.setId != null)) {
        setIdsByStudent.putIfAbsent(b.studentId, () => <String>{}).add(b.setId!);
      }
      for (final entry in setIdsByStudent.entries) {
        await _regeneratePlannedAttendanceForStudentSets(
          studentId: entry.key,
          setIds: entry.value,
          days: 15,
        );
      }
    }
  }

  Future<void> bulkDeleteStudentTimeBlocks(
    List<String> blockIds, {
    bool immediate = false,
    bool skipPlannedRegen = false,
    bool publish = true, // 중간 publish를 건너뛸 수 있게 추가
    DateTime? endDateOverride, // 기본: 오늘-1일. 예약 변경 등에서 특정 날짜로 닫기 위해 사용
  }) async {
    final removedBlocks = _studentTimeBlocks.where((b) => blockIds.contains(b.id)).toList();
    final affectedStudents = removedBlocks.map((b) => b.studentId).toSet();
    final today = _todayDateOnly();
    final endDate = endDateOverride != null
        ? DateTime(endDateOverride.year, endDateOverride.month, endDateOverride.day)
        : today.subtract(const Duration(days: 1));

    if (TagPresetService.preferSupabaseRead) {
      try {
        await Supabase.instance.client
            .from('student_time_blocks')
            .update({'end_date': endDate.toIso8601String().split('T').first})
            .filter('id', 'in', '(${blockIds.map((e) => '"$e"').join(',')})');
        _studentTimeBlocks = _studentTimeBlocks.map((b) => blockIds.contains(b.id) ? b.copyWith(endDate: endDate) : b).toList();
        for (final sid in affectedStudents) {
          final remain = _studentTimeBlocks.where((b) => b.studentId == sid).toList();
          final remainSets = remain.where((b) => b.setId != null && b.setId!.isNotEmpty).map((b) => b.setId!).toSet();
          print('[SYNC][bulkRemove] studentId=$sid blocks=${remain.length} setIds=$remainSets');
        }
      } catch (e, st) {
        print('[SUPA][stb bulk delete] $e\n$st');
        rethrow;
      }
    } else {
      _studentTimeBlocks = _studentTimeBlocks.map((b) => blockIds.contains(b.id) ? b.copyWith(endDate: endDate) : b).toList();
      await AcademyDbService.instance.closeStudentTimeBlocks(blockIds, endDate);
      for (final sid in affectedStudents) {
        final remain = _studentTimeBlocks.where((b) => b.studentId == sid).toList();
        final remainSets = remain.where((b) => b.setId != null && b.setId!.isNotEmpty).map((b) => b.setId!).toSet();
        print('[SYNC][bulkRemove-local] studentId=$sid blocks=${remain.length} setIds=$remainSets');
      }
    }
    
    if (!publish) {
      // 호출 측에서 직접 publish 하는 경우
    } else if (immediate || blockIds.length == 1) {
      // 단일 삭제나 즉시 반영 요청 시 바로 업데이트
      _publishStudentTimeBlocks(refDate: today);
      _bumpStudentTimeBlocksRevision();
    } else {
      // 다중 삭제는 debouncing으로 지연 (100ms 후 한 번에 반영)
      _uiUpdateTimer?.cancel();
      _uiUpdateTimer = Timer(const Duration(milliseconds: 100), () {
        _publishStudentTimeBlocks(refDate: today);
        _bumpStudentTimeBlocksRevision();
      });
    }

    if (!skipPlannedRegen) {
      // 예정 출석 정리: 삭제된 블록들의 setId 기준으로 미래 planned 제거/재생성(없으므로 제거만)
      final setIds = removedBlocks.map((b) => b.setId).whereType<String>().toSet();
      for (final sid in affectedStudents) {
        for (final setId in setIds) {
          await _regeneratePlannedAttendanceForSet(
            studentId: sid,
            setId: setId,
            days: 15,
          );
        }
      }
    }
  }

  /// student_time_blocks 행을 **하드 삭제**한다. (end_date 종료가 아니라 DB row 삭제)
  ///
  /// - 주로 "미래 세그먼트(start_date가 더 미래)"를 완전히 제거할 때 사용한다.
  /// - `publish=false`로 묶어 여러 작업 후 한 번에 UI를 갱신할 수 있다.
  Future<void> hardDeleteStudentTimeBlocks(
    List<String> blockIds, {
    bool publish = true,
    DateTime? refDate,
  }) async {
    if (blockIds.isEmpty) return;
    final ids = blockIds.where((e) => e.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return;

    final before = List<StudentTimeBlock>.from(_studentTimeBlocks);
    final beforePending = List<StudentTimeBlock>.from(_pendingTimeBlocks);

    // ✅ 낙관적 반영(기존 bulkDelete와 동일한 패턴)
    _pendingTimeBlocks.removeWhere((b) => ids.contains(b.id));
    _studentTimeBlocks.removeWhere((b) => ids.contains(b.id));
    // ✅ week-cache에도 남아있으면(merge 로직상) 삭제된 블록이 다시 보일 수 있으므로 즉시 제거
    for (final id in ids) {
      _removeStudentTimeBlockFromWeekCaches(id);
    }
    if (publish) {
      _publishStudentTimeBlocks(refDate: refDate);
      _bumpStudentTimeBlocksRevision();
    }

    if (TagPresetService.preferSupabaseRead) {
      try {
        await Supabase.instance.client
            .from('student_time_blocks')
            .delete()
            .filter('id', 'in', '(${ids.map((e) => '"$e"').join(',')})');
        return;
      } catch (e, st) {
        // rollback
        _studentTimeBlocks = before;
        _pendingTimeBlocks
          ..clear()
          ..addAll(beforePending);
        if (publish) {
          _publishStudentTimeBlocks(refDate: refDate);
          _bumpStudentTimeBlocksRevision();
        }
        print('[SUPA][stb hard delete] $e\n$st');
        rethrow;
      }
    }

    // local DB
    try {
      await AcademyDbService.instance.bulkDeleteStudentTimeBlocks(ids);
    } catch (e, st) {
      // rollback
      _studentTimeBlocks = before;
      _pendingTimeBlocks
        ..clear()
        ..addAll(beforePending);
      if (publish) {
        _publishStudentTimeBlocks(refDate: refDate);
        _bumpStudentTimeBlocksRevision();
      }
      print('[LOCAL][stb hard delete] $e\n$st');
      rethrow;
    }
  }

  /// 같은 setId로 묶인 수업 블록을 "refDate에 활성인 구간" 기준으로 종료(end_date=refDate)한다.
  ///
  /// - `deleteFutureSegments=true`면 refDate 이후에 시작하는 동일 setId 블록(미래 세그먼트)은 하드 삭제한다.
  /// - planned attendance는 refDate 기준으로 재계산되도록 트리거한다(비동기).
  Future<void> closeStudentTimeBlockSetAtDate({
    required String studentId,
    required String setId,
    required DateTime refDate,
    bool deleteFutureSegments = false,
  }) async {
    final sid = studentId.trim();
    final sset = setId.trim();
    if (sid.isEmpty || sset.isEmpty) return;
    final date = DateTime(refDate.year, refDate.month, refDate.day);
    final today = _todayDateOnly();
    // ✅ 기본: refDate부터 삭제(= end_date는 refDate-1)
    // ✅ 단, refDate가 "오늘"이면 오늘까지 유지하고 내일부터 삭제(= end_date=today)
    final bool isToday = date.year == today.year && date.month == today.month && date.day == today.day;
    final DateTime endDateToSet = isToday ? today : date.subtract(const Duration(days: 1));

    final all = _studentTimeBlocks.where((b) => b.studentId == sid && b.setId == sset).toList();
    if (all.isEmpty) return;

    bool isActiveOnRef(StudentTimeBlock b) => _isBlockActiveOn(b, date);
    bool isFutureSegment(StudentTimeBlock b) {
      final sd = DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
      return sd.isAfter(date);
    }

    // refDate에 활성인 블록 중에서도,
    // endDateToSet(refDate-1)가 start_date보다 빠른 경우는 "종료" 대신 하드 삭제가 더 안전하다.
    final active = all.where(isActiveOnRef).toList();
    final closableActiveIds = active.where((b) {
      final sd = DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
      return !sd.isAfter(endDateToSet);
    }).map((b) => b.id).where((id) => id.isNotEmpty).toSet().toList();
    final hardDeleteActiveIds = active.where((b) {
      final sd = DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
      return sd.isAfter(endDateToSet);
    }).map((b) => b.id).where((id) => id.isNotEmpty).toSet().toList();
    final futureIds = all.where(isFutureSegment).map((b) => b.id).where((id) => id.isNotEmpty).toSet().toList();

    // 1) refDate에 활성인 블록들만 종료(end_date=refDate)
    if (closableActiveIds.isNotEmpty) {
      await bulkDeleteStudentTimeBlocks(
        closableActiveIds,
        immediate: true,
        publish: false,
        skipPlannedRegen: true,
        endDateOverride: endDateToSet,
      );
    }
    // (보강) refDate 삭제인데 endDateToSet < startDate인 경우: 유효기간을 꼬이게 만들지 않도록 하드 삭제 처리
    if (hardDeleteActiveIds.isNotEmpty) {
      await hardDeleteStudentTimeBlocks(
        hardDeleteActiveIds,
        publish: false,
      );
    }

    // 2) (옵션) 미래 세그먼트 하드 삭제
    if (deleteFutureSegments && futureIds.isNotEmpty) {
      await hardDeleteStudentTimeBlocks(
        futureIds,
        publish: false,
      );
    }

    // 3) UI 갱신은 한 번만
    _publishStudentTimeBlocks(refDate: date);
    _bumpStudentTimeBlocksRevision();

    // 4) planned 재생성: refDate부터 반영되도록(미래면 anchor가 refDate가 됨)
    _schedulePlannedRegen(
      sid,
      sset,
      effectiveStart: date,
      immediate: false,
    );
  }

  /// 특정 time block의 유효기간(start_date/end_date)을 직접 수정한다.
  ///
  /// - `startDate`/`endDate`는 date-only로 정규화된다.
  /// - `endDate == null`이면 무기한(열림)으로 설정된다.
  /// - setId가 있으면 planned attendance 재생성(다음 14일)을 수행한다.
  Future<void> updateStudentTimeBlockDateRange(
    String blockId, {
    required DateTime startDate,
    DateTime? endDate,
    bool regeneratePlanned = true,
  }) async {
    final sd = DateTime(startDate.year, startDate.month, startDate.day);
    final ed = endDate == null ? null : DateTime(endDate.year, endDate.month, endDate.day);
    if (ed != null && ed.isBefore(sd)) {
      throw Exception('종료일은 시작일보다 빠를 수 없습니다.');
    }

    final prevIndex = _studentTimeBlocks.indexWhere((b) => b.id == blockId);
    if (prevIndex == -1) {
      throw Exception('수업블록을 찾지 못했습니다. (id=$blockId)');
    }
    final prev = _studentTimeBlocks[prevIndex];
    final next = prev.copyWith(startDate: sd, endDate: ed);

    final now = DateTime.now();
    if (TagPresetService.preferSupabaseRead) {
      try {
        await Supabase.instance.client.from('student_time_blocks').update({
          'start_date': sd.toIso8601String().split('T').first,
          'end_date': ed?.toIso8601String().split('T').first,
          'block_created_at': now.toIso8601String(),
        }).eq('id', blockId);
      } catch (e, st) {
        print('[SUPA][stb update range] $e\n$st');
        rethrow;
      }
    } else {
      await AcademyDbService.instance.updateStudentTimeBlock(blockId, next.copyWith(createdAt: now));
    }

    final applied = next.copyWith(createdAt: now);
    _studentTimeBlocks[prevIndex] = applied;
    // 캐시 정합(기간 변경으로 주차 overlap이 달라질 수 있음)
    _removeStudentTimeBlockFromWeekCaches(blockId);
    _upsertStudentTimeBlockIntoWeekCaches(applied);
    _publishStudentTimeBlocks(); // 오늘 기준 active notifier 갱신(검색/리스트 등에 사용)
    _bumpStudentTimeBlocksRevision();

    if (regeneratePlanned && next.setId != null && next.setId!.isNotEmpty) {
      try {
        await _regeneratePlannedAttendanceForSet(
          studentId: next.studentId,
          setId: next.setId!,
          days: 15,
        );
      } catch (e, st) {
        // planned regen 실패는 UI 편집 자체를 막지 않음
        print('[WARN][stb update range planned regen] $e\n$st');
      }
    }
  }

  /// 여러 student_time_blocks의 기간(start_date/end_date)을 한 번에 수정한다.
  ///
  /// - `endDate == null`이면 무기한(열림)으로 설정된다.
  /// - 내부 week-cache 정합을 위해 id를 캐시에서 제거 후(필요 시) 다시 upsert 한다.
  Future<void> updateStudentTimeBlocksDateRangeBulk(
    List<String> blockIds, {
    required DateTime startDate,
    DateTime? endDate,
    bool publish = true,
    DateTime? refDate,
    bool touchModifiedAt = true,
  }) async {
    final ids = blockIds.where((e) => e.trim().isNotEmpty).map((e) => e.trim()).toSet().toList();
    if (ids.isEmpty) return;

    final sd = DateTime(startDate.year, startDate.month, startDate.day);
    final ed = endDate == null ? null : DateTime(endDate.year, endDate.month, endDate.day);
    if (ed != null && ed.isBefore(sd)) {
      throw Exception('종료일은 시작일보다 빠를 수 없습니다.');
    }

    final now = DateTime.now();
    final patch = <String, dynamic>{
      'start_date': sd.toIso8601String().split('T').first,
      'end_date': ed?.toIso8601String().split('T').first,
    };
    if (touchModifiedAt) {
      patch['block_created_at'] = now.toIso8601String();
    }

    if (TagPresetService.preferSupabaseRead) {
      try {
        await Supabase.instance.client
            .from('student_time_blocks')
            .update(patch)
            .filter('id', 'in', '(${ids.map((e) => '"$e"').join(',')})');
      } catch (e, st) {
        print('[SUPA][stb bulk update range] $e\n$st');
        rethrow;
      }
    } else {
      // 로컬DB: 개별 update
      for (final id in ids) {
        final idx = _studentTimeBlocks.indexWhere((b) => b.id == id);
        if (idx == -1) continue;
        final prev = _studentTimeBlocks[idx];
        final next = prev.copyWith(
          startDate: sd,
          endDate: ed,
          createdAt: touchModifiedAt ? now : prev.createdAt,
        );
        await AcademyDbService.instance.updateStudentTimeBlock(id, next);
      }
    }

    // 메모리 반영 + week-cache 정합
    for (int i = 0; i < _studentTimeBlocks.length; i++) {
      final b = _studentTimeBlocks[i];
      if (!ids.contains(b.id)) continue;
      final next = b.copyWith(
        startDate: sd,
        endDate: ed,
        createdAt: touchModifiedAt ? now : b.createdAt,
      );
      _studentTimeBlocks[i] = next;
      _removeStudentTimeBlockFromWeekCaches(next.id);
      _upsertStudentTimeBlockIntoWeekCaches(next);
    }

    if (publish) {
      _publishStudentTimeBlocks(refDate: refDate);
      _bumpStudentTimeBlocksRevision();
    }
  }

  /// 여러 student_time_blocks의 session_type_id를 한 번에 수정한다. (null 포함)
  Future<void> updateStudentTimeBlocksSessionTypeIdBulk(
    List<String> blockIds, {
    required String? sessionTypeId,
    bool publish = true,
    DateTime? refDate,
    bool touchModifiedAt = true,
  }) async {
    final ids = blockIds.where((e) => e.trim().isNotEmpty).map((e) => e.trim()).toSet().toList();
    if (ids.isEmpty) return;

    final now = DateTime.now();
    final patch = <String, dynamic>{
      'session_type_id': (sessionTypeId == null || sessionTypeId.trim().isEmpty) ? null : sessionTypeId.trim(),
    };
    if (touchModifiedAt) {
      patch['block_created_at'] = now.toIso8601String();
    }

    if (TagPresetService.preferSupabaseRead) {
      try {
        await Supabase.instance.client
            .from('student_time_blocks')
            .update(patch)
            .filter('id', 'in', '(${ids.map((e) => '"$e"').join(',')})');
      } catch (e, st) {
        print('[SUPA][stb bulk update session_type_id] $e\n$st');
        rethrow;
      }
    } else {
      for (final id in ids) {
        final idx = _studentTimeBlocks.indexWhere((b) => b.id == id);
        if (idx == -1) continue;
        final prev = _studentTimeBlocks[idx];
        final next = prev.copyWith(
          sessionTypeId: (sessionTypeId == null || sessionTypeId.trim().isEmpty) ? null : sessionTypeId.trim(),
          createdAt: touchModifiedAt ? now : prev.createdAt,
        );
        await AcademyDbService.instance.updateStudentTimeBlock(id, next);
      }
    }

    for (int i = 0; i < _studentTimeBlocks.length; i++) {
      final b = _studentTimeBlocks[i];
      if (!ids.contains(b.id)) continue;
      final next = b.copyWith(
        sessionTypeId: (sessionTypeId == null || sessionTypeId.trim().isEmpty) ? null : sessionTypeId.trim(),
        createdAt: touchModifiedAt ? now : b.createdAt,
      );
      _studentTimeBlocks[i] = next;
      // overlap는 변하지 않지만, 캐시 일관성을 위해 upsert
      _upsertStudentTimeBlockIntoWeekCaches(next);
    }

    if (publish) {
      _publishStudentTimeBlocks(refDate: refDate);
      _bumpStudentTimeBlocksRevision();
    }
  }

  /// 단일 student_time_block의 "시간/요일/길이/번호"를 직접 수정한다. (히스토리 row 인플레이스 편집용)
  Future<void> updateStudentTimeBlockSchedule(
    String blockId, {
    required int dayIndex,
    required int startHour,
    required int startMinute,
    required int durationMinutes,
    int? number,
    bool publish = true,
    DateTime? refDate,
    bool touchModifiedAt = true,
  }) async {
    final id = blockId.trim();
    if (id.isEmpty) return;
    final idx = _studentTimeBlocks.indexWhere((b) => b.id == id);
    if (idx == -1) {
      throw Exception('수업블록을 찾지 못했습니다. (id=$id)');
    }
    final prev = _studentTimeBlocks[idx];
    final now = DateTime.now();
    final next = prev.copyWith(
      dayIndex: dayIndex,
      startHour: startHour,
      startMinute: startMinute,
      duration: Duration(minutes: durationMinutes),
      number: number ?? prev.number,
      createdAt: touchModifiedAt ? now : prev.createdAt,
    );

    final patch = <String, dynamic>{
      'day_index': dayIndex,
      'start_hour': startHour,
      'start_minute': startMinute,
      'duration': durationMinutes,
      'number': number ?? prev.number,
    };
    if (touchModifiedAt) {
      patch['block_created_at'] = now.toIso8601String();
    }

    if (TagPresetService.preferSupabaseRead) {
      try {
        await Supabase.instance.client.from('student_time_blocks').update(patch).eq('id', id);
      } catch (e, st) {
        print('[SUPA][stb update schedule] $e\n$st');
        rethrow;
      }
    } else {
      await AcademyDbService.instance.updateStudentTimeBlock(id, next);
    }

    _studentTimeBlocks[idx] = next;
    _upsertStudentTimeBlockIntoWeekCaches(next);
    if (publish) {
      _publishStudentTimeBlocks(refDate: refDate);
      _bumpStudentTimeBlocksRevision();
    }
  }

  /// (공개) 일정 변경 후 예정(planned) 재생성을 학생+set 단위로 스케줄한다.
  /// 내부적으로는 학생의 활성/미래 모든 set_id를 한 번에 재생성하여 session_order를 안정화한다.
  void schedulePlannedRegenForStudentSet({
    required String studentId,
    required String setId,
    DateTime? effectiveStart,
    bool immediate = false,
  }) {
    final sid = studentId.trim();
    final sset = setId.trim();
    if (sid.isEmpty || sset.isEmpty) return;
    _schedulePlannedRegen(sid, sset, effectiveStart: effectiveStart, immediate: immediate);
  }

  // 특정 학생의 set_id 목록에 해당하는 모든 수업 블록 삭제
  Future<void> removeStudentTimeBlocksBySetIds(String studentId, Set<String> setIds) async {
    if (setIds.isEmpty) return;
    final targets = _studentTimeBlocks.where((b) => b.studentId == studentId && b.setId != null && setIds.contains(b.setId!)).map((b) => b.id).toList();
    if (targets.isEmpty) return;
    await bulkDeleteStudentTimeBlocks(targets, immediate: true);
    // 예정 출석 재생성(삭제)도 함께 처리
    for (final setId in setIds) {
      await _regeneratePlannedAttendanceForSet(
        studentId: studentId,
        setId: setId,
        days: 15,
      );
    }
  }

  Future<void> updateStudentTimeBlock(String id, StudentTimeBlock newBlock) async {
    final prevIndex = _studentTimeBlocks.indexWhere((b) => b.id == id);
    final prev = prevIndex != -1 ? _studentTimeBlocks[prevIndex] : null;
    final prevSession = prev?.sessionTypeId;
    final newSession = newBlock.sessionTypeId;
    final today = _todayDateOnly();
    final endDate = today.subtract(const Duration(days: 1));
    try {
      // --- 기존 단일 슬롯 업데이트 로직은 사용하지 않음 ---
      // 이 함수는 단일 블록 업데이트용으로 호출되므로, set 단위 일괄 교체 로직을 드롭 핸들러 쪽에서 호출하도록 별도 함수로 분리.
      // 여기서는 기존 동작을 유지하되, 최소한의 로그만 남김.
      final toClose = _activeBlocks(today)
          .where((b) =>
              b.studentId == newBlock.studentId &&
              b.dayIndex == newBlock.dayIndex &&
              b.startHour == newBlock.startHour &&
              b.startMinute == newBlock.startMinute)
          .map((b) => b.id)
          .toSet()
          .toList();
      if (toClose.isEmpty) {
        toClose.add(id);
      }
      _studentTimeBlocks = _studentTimeBlocks
          .map((b) => toClose.contains(b.id) ? b.copyWith(endDate: endDate) : b)
          .toList();
      await bulkDeleteStudentTimeBlocks(toClose, immediate: true, publish: false);
      final fresh = newBlock.copyWith(
        id: const Uuid().v4(),
        startDate: today,
        endDate: null,
        createdAt: DateTime.now(),
      );
      await addStudentTimeBlock(fresh);
      _publishStudentTimeBlocks(refDate: today);
      _bumpStudentTimeBlocksRevision();
    } catch (e, st) {
      print('[ERROR][updateStudentTimeBlock] id=$id setId=${newBlock.setId} day=${newBlock.dayIndex} time=${newBlock.startHour}:${newBlock.startMinute} sess=$newSession error=$e\n$st');
      rethrow;
    }
  }

  // 주간 순번 재계산: 학생의 모든 set_id를 대표시간(가장 이른 요일/시간) 기준으로 정렬하여 weekly_order=1..N 부여
  Future<void> _recalculateWeeklyOrderForStudent(String studentId) async {
    // 대상 학생의 활성 블록만 수집
    final blocks = _activeBlocks(_todayDateOnly()).where((b) => b.studentId == studentId).toList();
    if (blocks.isEmpty) return;
    // setId가 있는 블록만 고려
    final Map<String, List<StudentTimeBlock>> bySet = {};
    for (final b in blocks) {
      if (b.setId == null) continue;
      bySet.putIfAbsent(b.setId!, () => []).add(b);
    }
    if (bySet.isEmpty) return;
    // 각 set의 대표시간: 요일(0~6), 시간(시*60+분) 기준 최소값
    List<MapEntry<String, DateTime>> setRepresentatives = [];
    for (final entry in bySet.entries) {
      final rep = entry.value.map((b) => DateTime(0, 1, 1, b.startHour, b.startMinute))
          .reduce((a, b) => (a.hour * 60 + a.minute) <= (b.hour * 60 + b.minute) ? a : b);
      // 요일까지 반영하기 위해 dayIndex를 분에 가중치로 반영
      final minutesWithDay = (entry.value.map((b) => b.dayIndex).reduce((a, b) => a < b ? a : b)) * 24 * 60 + rep.hour * 60 + rep.minute;
      // minutesWithDay를 DateTime으로 재구성(비교용)
      final combined = DateTime(0, 1, 1).add(Duration(minutes: minutesWithDay));
      setRepresentatives.add(MapEntry(entry.key, combined));
    }
    // 대표시간 기준 오름차순 정렬
    setRepresentatives.sort((a, b) => a.value.compareTo(b.value));
    // weekly_order 부여: 1..N
    final Map<String, int> setToOrder = {};
    for (int i = 0; i < setRepresentatives.length; i++) {
      setToOrder[setRepresentatives[i].key] = i + 1;
    }
    // 적용 및 DB 업데이트
    if (TagPresetService.preferSupabaseRead) {
      for (int i = 0; i < _studentTimeBlocks.length; i++) {
        final b = _studentTimeBlocks[i];
        if (b.studentId != studentId || b.setId == null) continue;
        final order = setToOrder[b.setId!];
        if (order == null) continue;
        if (b.weeklyOrder == order) continue;
        final updated = b.copyWith(weeklyOrder: order);
        _studentTimeBlocks[i] = updated;
        try {
          await Supabase.instance.client
              .from('student_time_blocks')
              .update({'weekly_order': order})
              .eq('id', updated.id);
        } catch (e, st) { print('[SUPA][stb weekly_order update] $e\n$st'); }
      }
    } else {
    List<Future> futures = [];
    for (int i = 0; i < _studentTimeBlocks.length; i++) {
      final b = _studentTimeBlocks[i];
      if (b.studentId != studentId || b.setId == null) continue;
      final order = setToOrder[b.setId!];
      if (order == null) continue;
      if (b.weeklyOrder == order) continue;
      final updated = b.copyWith(weeklyOrder: order);
      _studentTimeBlocks[i] = updated;
      futures.add(AcademyDbService.instance.updateStudentTimeBlock(updated.id, updated));
    }
    await Future.wait(futures);
    }
    _publishStudentTimeBlocks();
  }

  // GroupSchedule 관련 메서드들
  Future<void> loadGroupSchedules() async {
    // _storage 관련 코드와 json/hive 기반 메서드 전체를 완전히 삭제
  }

  Future<void> saveGroupSchedules() async {
    // _storage 관련 코드와 json/hive 기반 메서드 전체를 완전히 삭제
  }

  Future<List<GroupSchedule>> getGroupSchedules(String groupId) async {
    // _storage 관련 코드와 json/hive 기반 메서드 전체를 완전히 삭제
    return _groupSchedules.where((schedule) => schedule.groupId == groupId).toList();
  }

  Future<void> addGroupSchedule(GroupSchedule schedule) async {
    // _storage 관련 코드와 json/hive 기반 메서드 전체를 완전히 삭제
    _groupSchedules.add(schedule);
    _notifyListeners();
    await saveGroupSchedules();
  }

  Future<void> updateGroupSchedule(GroupSchedule schedule) async {
    // _storage 관련 코드와 json/hive 기반 메서드 전체를 완전히 삭제
    final index = _groupSchedules.indexWhere((s) => s.id == schedule.id);
    if (index != -1) {
      _groupSchedules[index] = schedule;
      _notifyListeners();
      await saveGroupSchedules();
    }
  }

  Future<void> deleteGroupSchedule(String id) async {
    // _storage 관련 코드와 json/hive 기반 메서드 전체를 완전히 삭제
    _groupSchedules.removeWhere((s) => s.id == id);
    _notifyListeners();
    await saveGroupSchedules();
  }

  Future<void> applyGroupScheduleToStudents(GroupSchedule schedule) async {
    // 해당 그룹에 속한 모든 학생 가져오기
    final groupStudents = _studentsWithInfo.where((si) => si.student.groupInfo?.id == schedule.groupId).toList();
    // 각 학생에 대한 시간 블록 생성 (groupId 전달 제거)
    for (final si in groupStudents) {
      final block = StudentTimeBlock(
        id: '${DateTime.now().millisecondsSinceEpoch}_${si.student.id}',
        studentId: si.student.id,
        dayIndex: schedule.dayIndex,
        startHour: schedule.startTime.hour,
        startMinute: schedule.startTime.minute,
        duration: schedule.duration,
        createdAt: DateTime.now(),
        startDate: _todayDateOnly(),
      );
      _studentTimeBlocks.add(block);
    }
    _notifyListeners();
    await saveStudentTimeBlocks();
  }

  Future<void> loadTeachers() async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      final data = await Supabase.instance.client
          .from('teachers')
          .select('id,user_id,name,role,contact,email,description,display_order,pin_hash,avatar_url,avatar_preset_color,avatar_preset_initial,avatar_use_icon')
          .eq('academy_id', academyId)
          .order('display_order', ascending: true, nullsFirst: false)
          .order('name');
      _teachers = (data as List).map((t) => Teacher(
        id: (t['id'] as String?),
        userId: (t['user_id'] as String?),
        name: t['name'] as String? ?? '',
        role: TeacherRole.values[(t['role'] as int?) ?? 0],
        contact: t['contact'] as String? ?? '',
        email: t['email'] as String? ?? '',
        description: t['description'] as String? ?? '',
        displayOrder: (t['display_order'] as int?),
        pinHash: t['pin_hash'] as String?,
        avatarUrl: t['avatar_url'] as String?,
        avatarPresetColor: t['avatar_preset_color'] as String?,
        avatarPresetInitial: t['avatar_preset_initial'] as String?,
        avatarUseIcon: t['avatar_use_icon'] as bool?,
      )).toList();
      _notifyListeners();
      return;
    } catch (e, st) {
      print('[SUPA][teachers load] $e\n$st');
      // 서버만 사용 → 실패 시 비워둠
      _teachers = [];
      _notifyListeners();
    }
  }

  Future<void> saveTeachers() async {
    try {
      print('[DEBUG] saveTeachers(serverside) 시작: ' + _teachers.length.toString() + '명');
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      // 더 이상 전체 삭제/재삽입하지 않습니다. 필요 시 개별 단건 API를 사용하세요.
      print('[DEBUG] saveTeachers 완료');
    } catch (e, st) {
      print('[SUPA][ERROR] saveTeachers: $e\n$st');
      rethrow;
    }
  }

  Future<void> addTeacher(Teacher teacher) async {
    print('[DEBUG] addTeacher 호출: $teacher');
    // 1) 로컬 선반영
    _teachers.add(teacher);
    teachersNotifier.value = List.unmodifiable(_teachers);
    // 2) 서버 단건 삽입
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final idx = _teachers.length - 1;
      final row = {
        'academy_id': academyId,
        'user_id': teacher.userId,
        'name': teacher.name,
        'role': teacher.role.index,
        'contact': teacher.contact,
        'email': teacher.email,
        'description': teacher.description,
        'display_order': teacher.displayOrder ?? idx,
        'pin_hash': teacher.pinHash,
        'avatar_url': teacher.avatarUrl,
        'avatar_preset_color': teacher.avatarPresetColor,
        'avatar_preset_initial': teacher.avatarPresetInitial,
        'avatar_use_icon': teacher.avatarUseIcon,
      }..removeWhere((k, v) => v == null);
      final inserted = await supa.from('teachers').insert(row).select('id,user_id,display_order').single();
      final newId = inserted['id'] as String?;
      final newUserId = inserted['user_id'] as String?;
      final newOrder = (inserted['display_order'] as int?) ?? (teacher.displayOrder ?? idx);
      // 3) 로컬 반영(id/순서 갱신)
      final prev = _teachers[idx];
      _teachers[idx] = Teacher(
        id: newId ?? prev.id,
        userId: newUserId ?? prev.userId,
        name: prev.name,
        role: prev.role,
        contact: prev.contact,
        email: prev.email,
        description: prev.description,
        displayOrder: newOrder,
        pinHash: prev.pinHash,
        avatarUrl: prev.avatarUrl,
        avatarPresetColor: prev.avatarPresetColor,
        avatarPresetInitial: prev.avatarPresetInitial,
        avatarUseIcon: prev.avatarUseIcon,
      );
      teachersNotifier.value = List.unmodifiable(_teachers);
    } catch (e, st) {
      print('[SUPA][ERROR] addTeacher(insert): $e\n$st');
      rethrow;
    }
  }

  Future<void> deleteTeacher(int idx) async {
    if (idx >= 0 && idx < _teachers.length) {
      final t = _teachers[idx];
      // 서버 삭제 시도(원장 카드 삭제는 DB 트리거가 막음)
      try {
        final id = t.id;
        if (id != null && id.isNotEmpty) {
          await Supabase.instance.client.from('teachers').delete().eq('id', id);
        }
      } catch (e, st) {
        print('[SUPA][ERROR] deleteTeacher: $e\n$st');
      }
      // 로컬에서도 제거(서버가 막은 경우 UI에서 이미 차단되어야 함)
      _teachers.removeAt(idx);
      teachersNotifier.value = List.unmodifiable(_teachers);
    }
  }

  Future<void> updateTeacher(int idx, Teacher updated) async {
    if (idx >= 0 && idx < _teachers.length) {
      final prev = _teachers[idx];
      // 1) 로컬 선반영
      _teachers[idx] = Teacher(
        id: prev.id,
        userId: updated.userId ?? prev.userId,
        name: updated.name,
        role: updated.role,
        contact: updated.contact,
        email: updated.email,
        description: updated.description,
        displayOrder: updated.displayOrder ?? prev.displayOrder,
        pinHash: updated.pinHash ?? prev.pinHash,
        avatarUrl: updated.avatarUrl ?? prev.avatarUrl,
        avatarPresetColor: updated.avatarPresetColor ?? prev.avatarPresetColor,
        avatarPresetInitial: updated.avatarPresetInitial ?? prev.avatarPresetInitial,
        avatarUseIcon: updated.avatarUseIcon ?? prev.avatarUseIcon,
      );
      teachersNotifier.value = List.unmodifiable(_teachers);
      // 2) 서버 업데이트(없으면 생성)
      try {
        final id = prev.id;
        final supa = Supabase.instance.client;
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final row = {
          'academy_id': academyId,
          'user_id': updated.userId ?? prev.userId,
          'name': updated.name,
          'role': updated.role.index,
          'contact': updated.contact,
          'email': updated.email,
          'description': updated.description,
          'display_order': updated.displayOrder ?? prev.displayOrder,
          'pin_hash': updated.pinHash ?? prev.pinHash,
          'avatar_url': updated.avatarUrl ?? prev.avatarUrl,
          'avatar_preset_color': updated.avatarPresetColor ?? prev.avatarPresetColor,
          'avatar_preset_initial': updated.avatarPresetInitial ?? prev.avatarPresetInitial,
          'avatar_use_icon': updated.avatarUseIcon ?? prev.avatarUseIcon,
        }..removeWhere((k, v) => v == null);
        if (id != null && id.isNotEmpty) {
          await supa.from('teachers').update(row).eq('id', id);
        } else {
          final inserted = await supa.from('teachers').insert(row).select('id').single();
          final newId = inserted['id'] as String?;
          _teachers[idx] = Teacher(
            id: newId,
            userId: _teachers[idx].userId,
            name: _teachers[idx].name,
            role: _teachers[idx].role,
            contact: _teachers[idx].contact,
            email: _teachers[idx].email,
            description: _teachers[idx].description,
            displayOrder: _teachers[idx].displayOrder,
            pinHash: _teachers[idx].pinHash,
            avatarUrl: _teachers[idx].avatarUrl,
            avatarPresetColor: _teachers[idx].avatarPresetColor,
            avatarPresetInitial: _teachers[idx].avatarPresetInitial,
            avatarUseIcon: _teachers[idx].avatarUseIcon,
          );
          teachersNotifier.value = List.unmodifiable(_teachers);
        }
      } catch (e, st) {
        print('[SUPA][ERROR] updateTeacher: $e\n$st');
        rethrow;
      }
    }
  }

  // 현재 인증된 사용자의 구글 아바타 URL을 해당 이메일의 teacher.avatar_url로 저장
  Future<void> updateTeacherAvatarFromCurrentAuth() async {
    try {
      final client = Supabase.instance.client;
      final email = client.auth.currentUser?.email;
      if (email == null || email.isEmpty) return;
      await updateTeacherAvatarByEmail(email);
    } catch (_) {}
  }

  // 지정 이메일의 teacher.avatar_url을 현재 인증 세션의 구글 아바타로 업데이트
  Future<void> updateTeacherAvatarByEmail(String email) async {
    try {
      final client = Supabase.instance.client;
      final meta = client.auth.currentUser?.userMetadata ?? {};
      String? url;
      try { url = (meta['avatar_url'] as String?); } catch (_) {}
      url ??= (meta['picture'] as String?);
      if ((url ?? '').isEmpty) return;

      // 로컬에서 해당 교사 찾기
      int idx = -1;
      for (int i = 0; i < _teachers.length; i++) {
        if ((_teachers[i].email).toLowerCase() == email.toLowerCase()) { idx = i; break; }
      }
      if (idx < 0) {
        try { await loadTeachers(); } catch (_) {}
        for (int i = 0; i < _teachers.length; i++) {
          if ((_teachers[i].email).toLowerCase() == email.toLowerCase()) { idx = i; break; }
        }
        if (idx < 0) return;
      }
      final id = _teachers[idx].id;
      if (id == null || id.isEmpty) return;

      // 서버 업데이트
      await Supabase.instance.client.from('teachers').update({'avatar_url': url}).eq('id', id);
      // 로컬 반영
      final prev = _teachers[idx];
      _teachers[idx] = Teacher(
        id: prev.id,
        userId: prev.userId,
        name: prev.name,
        role: prev.role,
        contact: prev.contact,
        email: prev.email,
        description: prev.description,
        displayOrder: prev.displayOrder,
        pinHash: prev.pinHash,
        avatarUrl: url,
        avatarPresetColor: prev.avatarPresetColor,
        avatarPresetInitial: prev.avatarPresetInitial,
        avatarUseIcon: prev.avatarUseIcon,
      );
      teachersNotifier.value = List.unmodifiable(_teachers);
    } catch (_) {}
  }

  Future<void> setMyPinHash(String pinHash, {String? emailFallback}) async {
    try {
      final client = Supabase.instance.client;
      await client.rpc('set_my_pin', params: {
        'p_pin_hash': pinHash,
        'p_email': emailFallback,
      });
      // 메모리 즉시 반영: 현재 사용자 이메일/teacher 매칭
      final email = client.auth.currentUser?.email ?? emailFallback;
      if (email != null) {
        final idx = _teachers.indexWhere((t) => t.email == email);
        if (idx >= 0) {
          final prev = _teachers[idx];
          _teachers[idx] = Teacher(
            id: prev.id,
            userId: prev.userId,
            name: prev.name,
            role: prev.role,
            contact: prev.contact,
            email: prev.email,
            description: prev.description,
            displayOrder: prev.displayOrder,
            pinHash: pinHash,
            avatarUrl: prev.avatarUrl,
            avatarPresetColor: prev.avatarPresetColor,
            avatarPresetInitial: prev.avatarPresetInitial,
            avatarUseIcon: prev.avatarUseIcon,
          );
          teachersNotifier.value = List.unmodifiable(_teachers);
        }
      }
    } catch (e, st) {
      print('[SUPA][ERROR] setMyPinHash: $e\n$st');
      rethrow;
    }
  }

  void setGroupsOrder(List<GroupInfo> newOrder) {
    _groups = newOrder.where((g) => g != null).toList();
    _groupsById = {for (var g in _groups) g.id: g};
    _notifyListeners();
    saveGroups();
  }

  void setTeachersOrder(List<Teacher> newOrder) {
    // 재정렬된 순서에 맞춰 displayOrder를 0부터 재계산하여 일관성 보장
    final recalculated = <Teacher>[];
    for (int i = 0; i < newOrder.length; i++) {
      final t = newOrder[i];
      recalculated.add(Teacher(
        id: t.id,
        userId: t.userId,
        name: t.name,
        role: t.role,
        contact: t.contact,
        email: t.email,
        description: t.description,
        displayOrder: i,
        pinHash: t.pinHash,
        avatarUrl: t.avatarUrl,
        avatarPresetColor: t.avatarPresetColor,
        avatarPresetInitial: t.avatarPresetInitial,
        avatarUseIcon: t.avatarUseIcon,
      ));
    }
    _teachers = List<Teacher>.from(recalculated);
    teachersNotifier.value = List.unmodifiable(_teachers);
    saveTeachersOrderOnly();
  }

  Future<void> saveTeachersOrderOnly() async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      // id가 있는 항목만 display_order를 업서트. id가 null인 신규 항목은 전체 저장 경로에서 처리.
      final rows = _teachers
          .where((t) => (t.id ?? '').isNotEmpty)
          .map((t) => {
                'id': t.id,
                'academy_id': academyId,
                'display_order': t.displayOrder ?? 0,
              })
          .toList();
      if (rows.isNotEmpty) {
        await supa.from('teachers').upsert(rows, onConflict: 'id');
      }
    } catch (e, st) {
      print('[SUPA][ERROR] saveTeachersOrderOnly: $e\n$st');
      rethrow;
    }
  }

  /// 학생별 수업블록(setId 기준) 개수 반환 (수업명 무관, setId 고유 개수)
  int getStudentLessonSetCount(String studentId, {DateTime? refDate}) {
    // 기준 날짜(refDate, 기본 오늘) 기준 활성 블록만 포함하여 setId 개수 계산
    final date = refDate != null ? DateTime(refDate.year, refDate.month, refDate.day) : _todayDateOnly();
    final blocks = _studentTimeBlocks.where((b) {
      if (b.studentId != studentId) return false;
      if (b.setId == null || b.setId!.isEmpty) return false;
      final start = DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
      final end = b.endDate != null ? DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day) : null;
      return !start.isAfter(date) && (end == null || !end.isBefore(date));
    }).toList();
    final setIds = blocks.map((b) => b.setId!).toSet();
    final detail = blocks.take(20).map((b) => '${b.sessionTypeId}|set:${b.setId}|day:${b.dayIndex}|t=${b.startHour}:${b.startMinute}|start=${b.startDate.toIso8601String().split("T").first}|end=${b.endDate?.toIso8601String().split("T").first}').toList();
    print('[DEBUG][DataManager] getStudentLessonSetCount($studentId, date=$date) = ${setIds.length}, blocks=${blocks.length}, setIds=$setIds, detail=$detail');
    return setIds.length;
  }

  bool _hasAnyOpenOrFutureLessonBlocks(String studentId, DateTime refDate) {
    final date = DateTime(refDate.year, refDate.month, refDate.day);
    return _studentTimeBlocks.any((b) {
      if (b.studentId != studentId) return false;
      final end = b.endDate != null
          ? DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day)
          : null;
      // 종료일이 오늘보다 이전이면(완전히 끝난 이력) 추천 기준에서는 "없음"으로 본다.
      if (end != null && end.isBefore(date)) return false;
      // end가 null이거나 오늘 이후면(현재/미래에 유효한 블록) 존재로 간주
      return true;
    });
  }

  /// 추천 학생(수업시간 등록 대상): "수업시간블록이 없는 학생"으로 통일
  /// - 기준: 오늘 기준으로 end_date가 지나지 않은 블록이 0개 (미래 시작 블록도 제외)
  /// - 정렬: 등록일(registration_date) 최신순 → 이름순
  List<StudentWithInfo> getLessonEligibleStudents({DateTime? refDate}) {
    final date = refDate != null
        ? DateTime(refDate.year, refDate.month, refDate.day)
        : _todayDateOnly();
    final result = students
        .where((s) => !_hasAnyOpenOrFutureLessonBlocks(s.student.id, date))
        .toList();
    result.sort((a, b) {
      final pa = getStudentPaymentInfo(a.student.id);
      final pb = getStudentPaymentInfo(b.student.id);
      final da = pa?.registrationDate;
      final db = pb?.registrationDate;
      if (da != null && db != null) return db.compareTo(da);
      if (da != null) return -1;
      if (db != null) return 1;
      return a.student.name.compareTo(b.student.name);
    });
    return result;
  }

  /// 학생별 고유 세트 개수 반환 (setId 고유 개수, sessionTypeId 여부 무관)
  /// refDate 기준 활성 블록만 카운트한다.
  int getStudentSetCount(String studentId, {DateTime? refDate}) {
    final date = refDate != null ? DateTime(refDate.year, refDate.month, refDate.day) : _todayDateOnly();
    final blocks = _studentTimeBlocks.where((b) {
      if (b.studentId != studentId) return false;
      if (b.setId == null || b.setId!.isEmpty) return false;
      final start = DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
      final end = b.endDate != null ? DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day) : null;
      return !start.isAfter(date) && (end == null || !end.isBefore(date));
    }).toList();
    final setIds = blocks.map((b) => b.setId!).toSet();
    final detail = blocks.take(50).map((b) => '${b.id}|set:${b.setId}|sess:${b.sessionTypeId}|day:${b.dayIndex}|t=${b.startHour}:${b.startMinute}|start=${b.startDate.toIso8601String().split("T").first}|end=${b.endDate?.toIso8601String().split("T").first}').toList();
    final cnt = setIds.length;
    print('[SYNC][setCount] studentId=$studentId date=$date blocks=${blocks.length} setIds=$setIds setCount=$cnt detail=$detail');
    return cnt;
  }

  /// 자습 등록 가능 학생 리스트 반환
  List<StudentWithInfo> getSelfStudyEligibleStudents() {
    final eligible = students.where((s) {
      final setCount = getStudentLessonSetCount(s.student.id);
      final remain = 1 - setCount;
      print('[DEBUG][DataManager] getSelfStudyEligibleStudents: ${s.student.name}, remain=$remain');
      return remain <= 0;
    }).toList();
    print('[DEBUG][DataManager] getSelfStudyEligibleStudents: ${eligible.map((s) => s.student.name).toList()}');
    return eligible;
  }

  /// 특정 수업에 등록된 학생 수 반환
  /// - refDate를 주면 "보고 있는 날짜" 기준으로 start_date/end_date 활성판정 후 카운트
  int getStudentCountForClass(String classId, {DateTime? refDate}) {
    // print('[DEBUG][getStudentCountForClass] 전체 studentTimeBlocks.length=${_studentTimeBlocks.length}');
    final d = refDate != null ? DateTime(refDate.year, refDate.month, refDate.day) : _todayDateOnly();
    final blocks = _activeBlocks(d).where((b) => b.sessionTypeId == classId).toList();
    //print('[DEBUG][getStudentCountForClass] classId=$classId, blocks=' + blocks.map((b) => '${b.studentId}:${b.setId}:${b.number}').toList().toString());
    final studentIds = blocks.map((b) => b.studentId).toSet();
    //print('[DEBUG][getStudentCountForClass] studentIds=$studentIds');
    return studentIds.length;
  }

  /// 학생이 속한 수업 색상 반환 (없으면 null)
  Color? getStudentClassColor(String studentId) {
    final block = _activeBlocks(_todayDateOnly()).firstWhere(
      (b) => b.studentId == studentId && b.sessionTypeId != null,
      orElse: () => StudentTimeBlock(
        id: '',
        studentId: '',
        dayIndex: 0,
        startHour: 0,
        startMinute: 0,
        duration: Duration.zero,
        createdAt: DateTime(0),
        startDate: DateTime(0),
        sessionTypeId: null,
      ),
    );
    if (block.sessionTypeId == null) return null;
    final cls = _classes.firstWhere(
      (c) => c.id == block.sessionTypeId,
      orElse: () => ClassInfo(id: '', name: '', description: '', capacity: null, color: null),
    );
    return cls.id.isEmpty ? null : cls.color;
  }

  /// 특정 요일/시간(+선택적 setId) 블록 기준 학생의 수업 색상 반환 (없으면 null)
  /// refDate를 넘기면 해당 날짜 기준 활성 블록을 판단; 없으면 오늘 날짜 사용
  Color? getStudentClassColorAt(String studentId, int dayIdx, DateTime startTime, {String? setId, DateTime? refDate}) {
    const bool _colorDebug = false;
    final refDateResolved = refDate ?? _todayDateOnly();
    // ✅ 주 이동(과거/미래)에서도 정확한 값을 얻기 위해 week-cache(해당 주 겹침) 기반으로 후보를 만든다.
    final weekStart = _weekMonday(refDateResolved);
    final weekBlocks = getStudentTimeBlocksForWeek(weekStart);
    final candidates = weekBlocks
        .where((b) {
          if (b.studentId != studentId) return false;
          if (b.dayIndex != dayIdx) return false;
          if (b.startHour != startTime.hour) return false;
          if (b.startMinute != startTime.minute) return false;
          if (setId != null && setId.isNotEmpty && b.setId != setId) return false;
          return _isBlockActiveOn(b, refDateResolved);
        })
        .toList();
    if (_colorDebug) {
      if (candidates.isNotEmpty) {
        print('[COLOR][ref] sid=$studentId day=$dayIdx time=${startTime.hour}:${startTime.minute} set=$setId ref=$refDateResolved candidates=${candidates.map((b) => '${b.id}|sess=${b.sessionTypeId}|set=${b.setId}|sd=${b.startDate.toIso8601String().split("T").first}|ed=${b.endDate?.toIso8601String().split("T").first ?? 'null'}').join(',')}');
      } else {
        print('[COLOR][ref] sid=$studentId day=$dayIdx time=${startTime.hour}:${startTime.minute} set=$setId ref=$refDateResolved candidates=0');
      }
    }
    if (candidates.isEmpty) {
      if (_colorDebug) {
        print('[COLOR][pick] sid=$studentId day=$dayIdx time=${startTime.hour}:${startTime.minute} set=$setId ref=$refDateResolved no-active-candidates');
      }
      return null;
    }

    final withSession = candidates.where((b) => b.sessionTypeId != null && b.sessionTypeId!.isNotEmpty).toList();
    if (withSession.isNotEmpty) {
      withSession.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final block = withSession.first; // 최신 createdAt
      final cls = _classes.firstWhere(
        (c) => c.id == block.sessionTypeId,
        orElse: () => ClassInfo(id: '', name: '', description: '', capacity: null, color: null),
      );
      final color = cls.id.isEmpty ? null : cls.color;
      if (_colorDebug) {
        print('[COLOR][pick] sid=$studentId day=$dayIdx time=${startTime.hour}:${startTime.minute} set=$setId ref=$refDateResolved choose=${block.id}|sess=${block.sessionTypeId}|set=${block.setId}|sd=${block.startDate.toIso8601String().split("T").first}|ed=${block.endDate?.toIso8601String().split("T").first} color=$color candidates=${candidates.length} withSession=${withSession.length}');
        if (color == null) {
          print('[COLOR][lookup] sid=$studentId day=$dayIdx time=${startTime.hour}:${startTime.minute} set=$setId ref=$refDateResolved reason=no-class-color block=${block.id}|sess=${block.sessionTypeId}|set=${block.setId}|sd=${block.startDate.toIso8601String().split("T").first}|ed=${block.endDate?.toIso8601String().split("T").first}');
        }
      }
      return color;
    }

    candidates.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final fallback = candidates.first; // sessionTypeId 없을 때도 최신 createdAt 사용
    final cls = _classes.firstWhere(
      (c) => c.id == fallback.sessionTypeId,
      orElse: () => ClassInfo(id: '', name: '', description: '', capacity: null, color: null),
    );
    final color = cls.id.isEmpty ? null : cls.color;
    if (_colorDebug) {
      print('[COLOR][pick] sid=$studentId day=$dayIdx time=${startTime.hour}:${startTime.minute} set=$setId ref=$refDateResolved choose=${fallback.id}|sess=${fallback.sessionTypeId}|set=${fallback.setId}|sd=${fallback.startDate.toIso8601String().split("T").first}|ed=${fallback.endDate?.toIso8601String().split("T").first} (no sess) candidates=${candidates.length}');
      if (color == null) {
        print('[COLOR][lookup] sid=$studentId day=$dayIdx time=${startTime.hour}:${startTime.minute} set=$setId ref=$refDateResolved reason=no-session block=${fallback.id}|sess=${fallback.sessionTypeId}|set=${fallback.setId}|sd=${fallback.startDate.toIso8601String().split("T").first}|ed=${fallback.endDate?.toIso8601String().split("T").first}');
      }
    }
    return color;
  }

  // 자습 블록을 DB에서 불러오는 메서드 추가
  Future<void> loadSelfStudyTimeBlocks() async {
    try {
      _selfStudyTimeBlocks = await AcademyDbService.instance.getSelfStudyTimeBlocks();
      selfStudyTimeBlocksNotifier.value = List.unmodifiable(_selfStudyTimeBlocks);
    } catch (e) {
      print('Error loading self study time blocks: $e');
      _selfStudyTimeBlocks = [];
      selfStudyTimeBlocksNotifier.value = [];
    }
  }

List<ClassInfo> _classes = [];
final ValueNotifier<List<ClassInfo>> classesNotifier = ValueNotifier<List<ClassInfo>>([]);
List<ClassInfo> get classes => List.unmodifiable(_classes);
bool _isSavingClassesOrder = false;
DateTime? _lastClassesOrderSaveEnd;
DateTime? _lastClassesOrderSaveStart;

  /// UI 즉시 반영용: 수업을 로컬 상태에서 먼저 제거한다(서버 작업은 별도).
  void removeClassOptimistic(String id) {
    _classes.removeWhere((c) => c.id == id);
    classesNotifier.value = List.unmodifiable(_classes);
    classesRevision.value++;
    classAssignmentsRevision.value++;
  }

  Future<void> loadClasses() async {
    final now = DateTime.now();
    final loadStartedAt = now;
    if (_isSavingClassesOrder) {
      print('[SUPA][classes load] skip because _isSavingClassesOrder=true');
      return;
    }
    if (_lastClassesOrderSaveEnd != null &&
        now.difference(_lastClassesOrderSaveEnd!) < const Duration(seconds: 1)) {
      print('[SUPA][classes load] skip because recent order save completed <1s ago');
      return;
    }
    if (TagPresetService.preferSupabaseRead) {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      print('[SUPA][classes load] academyId=$academyId preferSupabaseRead=true');
      // 1차: order_index 지원 스키마
      try {
        final data = await Supabase.instance.client
            .from('classes')
            .select('id,name,capacity,description,color,order_index')
            .eq('academy_id', academyId)
            .order('order_index', ascending: true)
            .order('name');
        _classes = (data as List).map((m) => ClassInfo(
          id: (m['id'] as String),
          name: (m['name'] as String? ?? ''),
          capacity: (m['capacity'] as int?),
          description: (m['description'] as String? ?? ''),
          color: (m['color'] == null) ? null : Color(m['color'] as int),
        )).toList();
        print('[SUPA][classes load] order_index schema 로드: ${_classes.map((c) => c.name).toList()}');

          // 저장이 더 최근에 시작되었으면 이 로드 결과는 폐기
          if (_lastClassesOrderSaveStart != null && loadStartedAt.isBefore(_lastClassesOrderSaveStart!)) {
            print('[SUPA][classes load] skip apply because newer save started after load began');
            return;
          }
      } catch (e, st) {
        print('[SUPA][classes load order_index] $e\n$st');
        // 2차: 구 스키마( order_index 없음 ) fallback
        try {
          final data = await Supabase.instance.client
              .from('classes')
              .select('id,name,capacity,description,color')
              .eq('academy_id', academyId)
              .order('name');
          _classes = (data as List).map((m) => ClassInfo(
            id: (m['id'] as String),
            name: (m['name'] as String? ?? ''),
            capacity: (m['capacity'] as int?),
            description: (m['description'] as String? ?? ''),
            color: (m['color'] == null) ? null : Color(m['color'] as int),
          )).toList();
          print('[SUPA][classes load] fallback name order 로드: ${_classes.map((c) => c.name).toList()}');

          // 저장이 더 최근에 시작되었으면 이 로드 결과는 폐기
          if (_lastClassesOrderSaveStart != null && loadStartedAt.isBefore(_lastClassesOrderSaveStart!)) {
            print('[SUPA][classes load] skip apply (fallback) because newer save started after load began');
            return;
          }
        } catch (e2, st2) {
          print('[SUPA][classes load fallback name order] $e2\n$st2');
        }
      }

      // Supabase 모드에서는 로컬 DB와 섞이지 않도록, 로컬 fallback 중단
      if (_classes.isNotEmpty) {
        print('[SUPA][classes load] 최종 _classes=${_classes.map((c) => c.name).toList()}');
      } else {
        print('[SUPA][classes load] Supabase 결과 없음(비어 있음), 로컬 fallback 생략');
      }
      classesNotifier.value = List.unmodifiable(_classes);
      classesRevision.value++;
      classAssignmentsRevision.value++;
      return;
    }
    // Supabase 미사용 모드에서만 로컬 DB 사용
    _classes = await AcademyDbService.instance.getClasses();
    classesNotifier.value = List.unmodifiable(_classes);
    classesRevision.value++;
    classAssignmentsRevision.value++;
  }
  Future<void> saveClasses() async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final rows = _classes.map((c) => {
          'id': c.id,
          'academy_id': academyId,
          'name': c.name,
          'capacity': c.capacity,
          'description': c.description,
          'color': c.color?.value.toSigned(32),
        }).toList();
        if (rows.isNotEmpty) {
          await Supabase.instance.client.from('classes').upsert(rows, onConflict: 'id');
        }
      } catch (e, st) { print('[SUPA][classes save] $e\n$st'); }
      classesNotifier.value = List.unmodifiable(_classes);
      return;
    }
    for (final c in _classes) {
      await AcademyDbService.instance.addClass(c);
    }
    classesNotifier.value = List.unmodifiable(_classes);
  }
  Future<void> addClass(ClassInfo c) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final row = {
          'id': c.id,
          'academy_id': academyId,
          'name': c.name,
          'capacity': c.capacity,
          'description': c.description,
          'color': c.color?.value.toSigned(32),
        };
        await Supabase.instance.client.from('classes').upsert(row, onConflict: 'id');
        // 서버 반영 후 메모리 반영 및 UI 업데이트
        _classes.add(c);
        classesNotifier.value = List.unmodifiable(_classes);
        classesRevision.value++;
        return;
      } catch (e, st) {
        print('[SUPA][classes upsert(add)] $e\n$st');
        return; // server-only: 실패 시 로컬 저장하지 않음
      }
    }
    _classes.add(c);
    await AcademyDbService.instance.addClass(c);
    classesNotifier.value = List.unmodifiable(_classes);
    classesRevision.value++;
  }
  Future<void> updateClass(ClassInfo c) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        await Supabase.instance.client.from('classes').upsert({
          'id': c.id,
          'academy_id': academyId,
          'name': c.name,
          'capacity': c.capacity,
          'description': c.description,
          'color': c.color?.value.toSigned(32),
        }, onConflict: 'id');
    final idx = _classes.indexWhere((e) => e.id == c.id);
        if (idx != -1) _classes[idx] = c; else _classes.add(c);
        classesNotifier.value = List.unmodifiable(_classes);
        classesRevision.value++;
        classAssignmentsRevision.value++;
        return;
      } catch (e, st) {
        print('[SUPA][classes upsert(update)] $e\n$st');
        return; // server-only: 실패 시 로컬 저장하지 않음
      }
    }
    final idx = _classes.indexWhere((e) => e.id == c.id);
    if (idx != -1) _classes[idx] = c; else _classes.add(c);
    await AcademyDbService.instance.updateClass(c);
    classesNotifier.value = List.unmodifiable(_classes);
    classesRevision.value++;
    classAssignmentsRevision.value++;
  }
  Future<void> deleteClass(String id) async {
    _classes.removeWhere((c) => c.id == id);
    classesNotifier.value = List.unmodifiable(_classes);
    classesRevision.value++;
    classAssignmentsRevision.value++;

    if (TagPresetService.preferSupabaseRead) {
      try {
        await Supabase.instance.client.from('classes').delete().eq('id', id);
        return;
      } catch (e, st) {
        // UI는 이미 반영(낙관적). 실패 시 다음 로드에서 복구된다.
        print('[SUPA][classes delete] $e\n$st');
        return;
      }
    }
    await AcademyDbService.instance.deleteClass(id);
  }

  Future<void> saveClassesOrder(List<ClassInfo> newOrder, {bool skipNotifierUpdate = false}) async {
    print('[DEBUG][DataManager.saveClassesOrder] 시작: ${newOrder.map((c) => c.name).toList()}');
    _classes = List<ClassInfo>.from(newOrder);
    print('[DEBUG][DataManager.saveClassesOrder] _classes 업데이트: ${_classes.map((c) => c.name).toList()}');
    
    if (_isSavingClassesOrder) {
      print('[SUPA][classes reorder] 이미 저장 중이라 중복 호출 무시');
      return;
    }
    _lastClassesOrderSaveStart = DateTime.now();
    _isSavingClassesOrder = true;
    try {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        print('[SUPA][classes reorder] academyId=$academyId rows=${_classes.length}');
        if (_classes.isNotEmpty) {
          final rows = _classes.asMap().entries.map((entry) {
            final idx = entry.key;
            final c = entry.value;
            return {
              'id': c.id,
              'academy_id': academyId,
              'name': c.name,
              'capacity': c.capacity,
              'description': c.description,
              'color': c.color?.value.toSigned(32),
              'order_index': idx,
            };
          }).toList();
          try {
            print('[SUPA][classes reorder upsert] rows(detail)=${rows.map((r) => '${r['name']}|${r['order_index']}').toList()}');
            await supa.from('classes').upsert(rows, onConflict: 'id');
            print('[SUPA][classes reorder upsert] order_index 사용 rows=${rows.length}');
          } catch (e, st) {
            print('[SUPA][classes reorder upsert order_index] $e\n$st');
            // order_index가 없는 구스키마 대비: order_index를 제외하고 upsert 재시도
            final fallbackRows = _classes.map((c) => {
              'id': c.id,
              'academy_id': academyId,
              'name': c.name,
              'capacity': c.capacity,
              'description': c.description,
              'color': c.color?.value.toSigned(32),
            }).toList();
            print('[SUPA][classes reorder fallback upsert] rows(detail)=${fallbackRows.map((r) => '${r['name']}').toList()}');
            await supa.from('classes').upsert(fallbackRows, onConflict: 'id');
            print('[SUPA][classes reorder upsert] fallback rows=${fallbackRows.length}');
          }
        }
      } catch (e, st) { print('[SUPA][classes reorder] $e\n$st'); }
    } else {
    await AcademyDbService.instance.deleteAllClasses();
    print('[DEBUG][DataManager.saveClassesOrder] deleteAllClasses 완료');
    for (final c in _classes) {
      await AcademyDbService.instance.addClass(c);
    }
    print('[DEBUG][DataManager.saveClassesOrder] 모든 클래스 재저장 완료');
    }
    
    if (!skipNotifierUpdate) {
      classesNotifier.value = List.unmodifiable(_classes);
      print('[DEBUG][DataManager.saveClassesOrder] classesNotifier 업데이트 완료');
      classesRevision.value++;
      classAssignmentsRevision.value++;
    } else {
      // 로컬 UI만 업데이트한 경우, 불필요한 리비전 bump를 생략해 불필요한 재빌드/리셋을 방지
      print('[DEBUG][DataManager.saveClassesOrder] skipNotifierUpdate=true → revision bump 생략');
    }
    } finally {
      _isSavingClassesOrder = false;
      _lastClassesOrderSaveEnd = DateTime.now();
    }
  }

  // Payment Records 관련 메소드들
  Future<void> loadPaymentRecords() async {
    // 서버 우선 읽기: Supabase에서 결제 레코드를 불러온다.
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final data = await Supabase.instance.client
            .from('payment_records')
            .select('id,student_id,cycle,due_date,paid_date,postpone_reason')
            .eq('academy_id', academyId)
            .order('student_id')
            .order('cycle');
        _paymentRecords = (data as List).map((m) {
          final String sid = m['student_id'] as String;
          final int cycle = (m['cycle'] as int);
          final String? dueStr = m['due_date'] as String?; // DATE → 'YYYY-MM-DD'
          final String? paidStr = m['paid_date'] as String?; // nullable
          final DateTime due = (dueStr != null && dueStr.isNotEmpty)
              ? DateTime.parse(dueStr)
              : DateTime.now();
          final DateTime? paid = (paidStr != null && paidStr.isNotEmpty)
              ? DateTime.parse(paidStr)
              : null;
          return PaymentRecord(
            id: null, // local autoincrement와 다르게 서버는 별도 UUID. 필요 시 확장
            studentId: sid,
            cycle: cycle,
            dueDate: due,
            paidDate: paid,
            postponeReason: m['postpone_reason'] as String?,
          );
        }).toList();
        paymentRecordsNotifier.value = List.unmodifiable(_paymentRecords);
        print('[DEBUG] payment_records 로드 완료(Supabase): ${_paymentRecords.length}개');
        return;
      } catch (e, st) {
        print('[ERROR] payment_records Supabase 로드 실패: $e\n$st');
        // 서버 전용 모드: 폴백 없음
        _paymentRecords = [];
        paymentRecordsNotifier.value = List.unmodifiable(_paymentRecords);
        return;
      }
    }
    // 로컬 사용 안함 (서버-only 모드)
    _paymentRecords = [];
    paymentRecordsNotifier.value = List.unmodifiable(_paymentRecords);
  }

  Future<void> addPaymentRecord(PaymentRecord record) async {
    // 서버 전용 처리: 결제 발생 시 RPC 사용
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        await Supabase.instance.client.rpc('record_payment', params: {
          'p_student_id': record.studentId,
          'p_cycle': record.cycle,
          'p_paid': (record.paidDate ?? DateTime.now()).toIso8601String().substring(0, 10),
          'p_academy_id': academyId,
        });
        await loadPaymentRecords();
        return;
      } catch (e, st) {
        print('[ERROR] record_payment RPC 실패: $e\n$st');
      }
    }
    // 서버-only 모드: 실패 시 로컬 저장하지 않음
  }

  Future<void> updatePaymentRecord(PaymentRecord record) async {
    // 서버 전용: 납부 처리만 허용하며, 납부된 항목은 수정 불가. 납부 처리 역시 RPC 사용.
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        await Supabase.instance.client.rpc('record_payment', params: {
          'p_student_id': record.studentId,
          'p_cycle': record.cycle,
          'p_paid': (record.paidDate ?? DateTime.now()).toIso8601String().substring(0, 10),
          'p_academy_id': academyId,
        });
        await loadPaymentRecords();
        return;
      } catch (e, st) {
        print('[ERROR] record_payment RPC 실패(update): $e\n$st');
      }
    }
    // 서버-only 모드: 실패 시 로컬 업데이트하지 않음
  }

  Future<void> deletePaymentRecord(int id) async {
    _paymentRecords.removeWhere((r) => r.id == id);
    await AcademyDbService.instance.deletePaymentRecord(id);
    paymentRecordsNotifier.value = List.unmodifiable(_paymentRecords);
  }

  List<PaymentRecord> getPaymentRecordsForStudent(String studentId) {
    return _paymentRecords.where((r) => r.studentId == studentId).toList();
  }

  PaymentRecord? getPaymentRecord(String studentId, int cycle) {
    try {
      return _paymentRecords.firstWhere(
        (r) => r.studentId == studentId && r.cycle == cycle,
      );
    } catch (e) {
      return null;
    }
  }

  // ===== 결제 RPC 래퍼 =====
  Future<void> initFirstDue(String studentId, DateTime firstDue) async {
    if (!TagPresetService.preferSupabaseRead) return; // 서버 우선 모드에서만 사용
    try {
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      await Supabase.instance.client.rpc('init_first_due', params: {
        'p_student_id': studentId,
        'p_first_due': firstDue.toIso8601String().substring(0, 10),
        'p_academy_id': academyId,
      });
      await loadPaymentRecords();
    } catch (e, st) {
      print('[ERROR] init_first_due RPC 실패: $e\n$st');
    }
  }

  Future<void> recordPayment(String studentId, int cycle, DateTime paidDate) async {
    if (!TagPresetService.preferSupabaseRead) return; // 서버 우선 모드에서만 사용
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      await Supabase.instance.client.rpc('record_payment', params: {
        'p_student_id': studentId,
        'p_cycle': cycle,
        'p_paid': paidDate.toIso8601String().substring(0, 10),
        'p_academy_id': academyId,
      });
      await loadPaymentRecords();
    } catch (e, st) {
      print('[ERROR] record_payment RPC 실패(wrapper): $e\n$st');
    }
  }

  Future<void> postponeDueDate(String studentId, int cycle, DateTime newDue, String reason) async {
    if (!TagPresetService.preferSupabaseRead) return; // 서버 우선 모드에서만 사용
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      await Supabase.instance.client.rpc('postpone_due_date', params: {
        'p_student_id': studentId,
        'p_cycle': cycle,
        'p_new_due': newDue.toIso8601String().substring(0, 10),
        'p_reason': reason,
        'p_academy_id': academyId,
      });
      await loadPaymentRecords();
    } catch (e, st) {
      print('[ERROR] postpone_due_date RPC 실패: $e\n$st');
    }
  }

  // 결제 보정 로직 완전 제거 (요청에 따라 비활성화)

  // =================== ATTENDANCE RECORDS ===================

  Future<void> forceMigration() => AttendanceService.instance.forceMigration();
  Future<void> loadAttendanceRecords() =>
      AttendanceService.instance.loadAttendanceRecords();
  Future<void> _subscribeAttendanceRealtime() =>
      AttendanceService.instance.subscribeAttendanceRealtime();
  Future<void> addAttendanceRecord(AttendanceRecord record) =>
      AttendanceService.instance.addAttendanceRecord(record);
  Future<void> updateAttendanceRecord(AttendanceRecord record) =>
      AttendanceService.instance.updateAttendanceRecord(record);
  Future<void> deleteAttendanceRecord(String id) =>
      AttendanceService.instance.deleteAttendanceRecord(id);
  List<AttendanceRecord> getAttendanceRecordsForStudent(String studentId) =>
      AttendanceService.instance.getAttendanceRecordsForStudent(studentId);
  AttendanceRecord? getAttendanceRecord(String studentId, DateTime classDateTime) =>
      AttendanceService.instance.getAttendanceRecord(studentId, classDateTime);
  Future<void> ensurePlannedAttendanceForNextDays({int days = 15}) =>
      AttendanceService.instance.generatePlannedAttendanceForNextDays(days: days);


  /// (디버그/정리용) 특정 학생의 "순수 planned(예정수업)"를 전부 삭제한 뒤,
  /// 현재 시간표(student_time_blocks)를 기준으로 planned를 다시 생성한다.
  ///
  /// - 출석/등원 기록이 있는 행은 삭제하지 않는다(AttendanceService 기준).
  /// - 재생성은 snapshot 기반(regeneratePlannedWithSnapshot)으로 수행하여 snapshot_id/batch_session_id가 채워지도록 한다.
  Future<void> resetPlannedAttendanceForStudent(
    String studentId, {
    int days = 15,
  }) async {
    final sid = studentId.trim();
    if (sid.isEmpty) return;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // 예정 재생성 대상 setIds: 오늘 기준 "활성/미래" 세트만 포함
    final activeOrFutureSetIds = _studentTimeBlocks
        .where((b) {
          if (b.studentId != sid) return false;
          final setId = (b.setId ?? '').trim();
          if (setId.isEmpty) return false;
          final end = b.endDate != null
              ? DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day)
              : null;
          if (end != null && end.isBefore(today)) return false;
          return true;
        })
        .map((b) => (b.setId ?? '').trim())
        .where((s) => s.isNotEmpty)
        .toSet();

    // purge(순수 planned만)
    await AttendanceService.instance.purgePurePlannedAttendance(studentId: sid);
    await AttendanceService.instance.purgePlannedBatchSessions(studentId: sid);

    if (activeOrFutureSetIds.isEmpty) {
      print('[PLAN][resetStudent] skip regen: no active/future setIds student=$sid');
      return;
    }

    // snapshot 기반 재생성
    await regeneratePlannedWithSnapshot(
      studentId: sid,
      setIds: activeOrFutureSetIds,
      effectiveStart: today,
      days: days,
      note: 'manual reset planned',
    );
  }

  /// (디버그/정리용) 모든 학생의 "순수 planned(예정수업)"를 전부 삭제한 뒤,
  /// 현재 시간표(student_time_blocks)를 기준으로 planned를 다시 생성한다.
  ///
  /// - 출석/등원 기록이 있는 행은 삭제하지 않는다(AttendanceService 기준).
  /// - 재생성은 학생별 snapshot 기반(regeneratePlannedWithSnapshot)으로 수행한다.
  Future<void> resetPlannedAttendanceForAllStudents({int days = 15}) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // 학생별 예정 재생성 대상 setIds: 오늘 기준 "활성/미래" 세트만 포함
    final Map<String, Set<String>> setIdsByStudent = {};
    for (final b in _studentTimeBlocks) {
      final sid = (b.studentId).trim();
      if (sid.isEmpty) continue;
      final setId = (b.setId ?? '').trim();
      if (setId.isEmpty) continue;
      final end = b.endDate != null
          ? DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day)
          : null;
      if (end != null && end.isBefore(today)) continue;
      setIdsByStudent.putIfAbsent(sid, () => <String>{}).add(setId);
    }

    // purge(순수 planned만) - 전체
    await AttendanceService.instance.purgePurePlannedAttendance();
    await AttendanceService.instance.purgePlannedBatchSessions();

    if (setIdsByStudent.isEmpty) {
      print('[PLAN][resetAll] skip regen: no active/future setIds in student_time_blocks');
      return;
    }

    // 표시 순서: 이름 기준(없으면 id)
    final nameById = <String, String>{
      for (final s in _studentsWithInfo) s.student.id: s.student.name,
    };
    final entries = setIdsByStudent.entries.toList()
      ..sort((a, b) {
        final an = (nameById[a.key] ?? a.key).trim();
        final bn = (nameById[b.key] ?? b.key).trim();
        return an.compareTo(bn);
      });

    print('[PLAN][resetAll] regen start students=${entries.length} days=$days');
    int done = 0;
    int failed = 0;
    for (final e in entries) {
      done++;
      final sid = e.key;
      final setIds = e.value;
      final label = (nameById[sid] ?? sid).trim();
      try {
        print('[PLAN][resetAll] ($done/${entries.length}) student=$label setIds=${setIds.length}');
        await regeneratePlannedWithSnapshot(
          studentId: sid,
          setIds: setIds,
          effectiveStart: today,
          days: days,
          note: 'manual reset planned (all)',
        );
      } catch (err, st) {
        failed++;
        print('[PLAN][resetAll][ERROR] student=$label err=$err\n$st');
      }
    }
    print('[PLAN][resetAll] regen done students=${entries.length} failed=$failed');
  }

  /// 출석 기록(is_planned=false 등)으로 들어온 "추가수업"을
  /// 미처리 예정 수업(순수 planned) 1건과 연결하여 "보강(replace)"으로 처리한다.
  ///
  /// - 연결 대상 planned는 안전하게 제거(순수 planned만)하고,
  /// - 추가수업 레코드에는 planned의 set/cycle/order/snapshot/batch 정보를 이식한다.
  /// - 이후 session_override(replace, makeup, completed)를 생성하여 보강으로 기록한다.
  Future<void> connectWalkInToPlannedAsMakeup({
    required AttendanceRecord walkIn,
    required AttendanceRecord planned,
  }) async {
    if (walkIn.studentId != planned.studentId) {
      throw Exception('학생이 다릅니다.');
    }
    if (!(planned.isPlanned && !planned.isPresent && planned.arrivalTime == null)) {
      throw Exception('연결 대상이 순수 예정 수업이 아닙니다.');
    }

    final int durMin = () {
      final d = walkIn.classEndTime.difference(walkIn.classDateTime).inMinutes;
      if (d > 0) return d;
      final pd = planned.classEndTime.difference(planned.classDateTime).inMinutes;
      if (pd > 0) return pd;
      return _academySettings.lessonDuration;
    }();

    // 1) walk-in 레코드에 planned 메타를 이식(배치/스냅샷 포함)
    await saveOrUpdateAttendance(
      studentId: walkIn.studentId,
      classDateTime: walkIn.classDateTime,
      classEndTime: walkIn.classEndTime,
      className: (planned.className.trim().isNotEmpty ? planned.className : walkIn.className),
      isPresent: walkIn.isPresent,
      arrivalTime: walkIn.arrivalTime,
      departureTime: walkIn.departureTime,
      notes: walkIn.notes,
      sessionTypeId: planned.sessionTypeId ?? walkIn.sessionTypeId,
      setId: planned.setId ?? walkIn.setId,
      cycle: planned.cycle ?? walkIn.cycle,
      sessionOrder: planned.sessionOrder ?? walkIn.sessionOrder,
      isPlanned: walkIn.isPlanned,
      snapshotId: planned.snapshotId,
      batchSessionId: planned.batchSessionId,
    );

    // 2) 원본 planned 제거(순수 planned만)
    await AttendanceService.instance.removePlannedAttendanceForDate(
      studentId: planned.studentId,
      classDateTime: planned.classDateTime,
    );

    // 3) 보강(replace) 오버라이드 생성(완료)
    final ov = SessionOverride(
      studentId: walkIn.studentId,
      sessionTypeId: planned.sessionTypeId,
      setId: planned.setId,
      overrideType: OverrideType.replace,
      originalClassDateTime: planned.classDateTime,
      replacementClassDateTime: walkIn.classDateTime,
      durationMinutes: durMin,
      reason: OverrideReason.makeup,
      status: OverrideStatus.completed,
      originalAttendanceId: planned.id,
      replacementAttendanceId: walkIn.id,
    );
    await addSessionOverride(ov);
  }
  CycleAttendanceSummary? getCycleAttendanceSummary({
    required String studentId,
    required int cycle,
  }) =>
      AttendanceService.instance.getCycleAttendanceSummary(
        studentId: studentId,
        cycle: cycle,
      );
  Future<void> _generatePlannedAttendanceForNextDays({int days = 15}) =>
      AttendanceService.instance.generatePlannedAttendanceForNextDays(days: days);
  Future<void> _regeneratePlannedAttendanceForSet({
    required String studentId,
    required String setId,
    int days = 15,
  }) async {
    await regeneratePlannedWithSnapshot(
      studentId: studentId,
      setIds: {setId},
      days: days,
    );
  }
  Future<void> _regeneratePlannedAttendanceForStudentSets({
    required String studentId,
    required Set<String> setIds,
    int days = 15,
  }) async {
    await regeneratePlannedWithSnapshot(
      studentId: studentId,
      setIds: setIds,
      days: days,
    );
  }
  Future<void> _regeneratePlannedAttendanceForStudent({
    required String studentId,
    int days = 15,
  }) =>
      AttendanceService.instance.regeneratePlannedAttendanceForStudent(
        studentId: studentId,
        days: days,
      );
  void _schedulePlannedRegen(
    String studentId,
    String setId, {
    DateTime? effectiveStart,
    bool immediate = false,
  }) {
    _pendingRegenSetIdsByStudent.putIfAbsent(studentId, () => <String>{}).add(setId);
    if (effectiveStart != null) {
      final d = DateTime(effectiveStart.year, effectiveStart.month, effectiveStart.day);
      final prev = _pendingRegenEffectiveStartByStudent[studentId];
      if (prev == null || d.isBefore(prev)) {
        _pendingRegenEffectiveStartByStudent[studentId] = d;
      }
    }
    if (immediate) {
      _flushPlannedRegen();
      return;
    }
    _plannedRegenTimer ??= Timer(const Duration(milliseconds: 200), _flushPlannedRegen);
  }

  Future<void> flushPendingPlannedRegens() => _flushPlannedRegen();

  Future<void> _flushPlannedRegen() async {
    final pending = Map<String, Set<String>>.from(_pendingRegenSetIdsByStudent);
    _pendingRegenSetIdsByStudent.clear();
    final pendingStart = Map<String, DateTime>.from(_pendingRegenEffectiveStartByStudent);
    _pendingRegenEffectiveStartByStudent.clear();
    _plannedRegenTimer?.cancel();
    _plannedRegenTimer = null;
    final today = _todayDateOnly();
    for (final entry in pending.entries) {
      final studentId = entry.key;

      // ✅ 회차(session_order)는 결제 사이클 내 "전체 수업"을 시간순으로 나열한 값이므로,
      // set 단위로만 재생성하면(연속 수정 시) 기존 다른 set과의 순서가 섞여 랜덤처럼 보일 수 있다.
      // → 학생 단위로 "활성/미래" 모든 set_id를 한 번에 재생성하여 순서를 안정화한다.
      final allSetIds = _studentTimeBlocks
          .where((b) {
            if (b.studentId != studentId) return false;
            final setId = (b.setId ?? '').trim();
            if (setId.isEmpty) return false;
            final end = b.endDate != null
                ? DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day)
                : null;
            if (end != null && end.isBefore(today)) return false;
            return true;
          })
          .map((b) => (b.setId ?? '').trim())
          .where((s) => s.isNotEmpty)
          .toSet();

      if (allSetIds.isEmpty) continue;

      await regeneratePlannedWithSnapshot(
        studentId: studentId,
        setIds: allSetIds,
        effectiveStart: pendingStart[studentId],
        days: 15,
      );
    }
  }
  Future<void> _regeneratePlannedAttendanceForOverride(SessionOverride ov) =>
      AttendanceService.instance.regeneratePlannedAttendanceForOverride(ov);
  Future<void> _removePlannedAttendanceForDate({
    required String studentId,
    required DateTime classDateTime,
  }) =>
      AttendanceService.instance.removePlannedAttendanceForDate(
        studentId: studentId,
        classDateTime: classDateTime,
      );
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
  }) =>
      AttendanceService.instance.saveOrUpdateAttendance(
        studentId: studentId,
        classDateTime: classDateTime,
        classEndTime: classEndTime,
        className: className,
        isPresent: isPresent,
        arrivalTime: arrivalTime,
        departureTime: departureTime,
        notes: notes,
        sessionTypeId: sessionTypeId,
        setId: setId,
        cycle: cycle,
        sessionOrder: sessionOrder,
        isPlanned: isPlanned,
        snapshotId: snapshotId,
        batchSessionId: batchSessionId,
      );
  Future<void> fixMissingDeparturesForYesterdayKst() =>
      AttendanceService.instance.fixMissingDeparturesForYesterdayKst();

  // =================== PAYMENTS REALTIME ===================
  RealtimeChannel? _paymentsRealtimeChannel;
  Future<void> _subscribePaymentsRealtime() async {
    try {
      _paymentsRealtimeChannel?.unsubscribe();
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      final chan = Supabase.instance.client.channel('public:payment_records:' + academyId);
      _paymentsRealtimeChannel = chan
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'payment_records',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (_) async {
            try { await loadPaymentRecords(); } catch (_) {}
          },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'payment_records',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (_) async {
            try { await loadPaymentRecords(); } catch (_) {}
          },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'payment_records',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (_) async {
            try { await loadPaymentRecords(); } catch (_) {}
          },
        )
        ..subscribe();
    } catch (_) {}
  }

  // =================== STUDENT PAYMENT INFO ===================

  List<StudentPaymentInfo> get studentPaymentInfos => List.unmodifiable(_studentPaymentInfos);

  // 학생 결제 정보 로드
  Future<void> loadStudentPaymentInfos() async {
    try {
      if (TagPresetService.preferSupabaseRead) {
        try {
          final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
          final rows = await Supabase.instance.client
              .from('student_payment_info')
              .select('id,student_id,registration_date,payment_method,tuition_fee,lateness_threshold,'
                      'schedule_notification,attendance_notification,departure_notification,lateness_notification,'
                      'created_at,updated_at')
              .eq('academy_id', academyId);
          _studentPaymentInfos = (rows as List).map((m) => StudentPaymentInfo(
            id: (m['id'] as String?),
            studentId: (m['student_id'] as String),
            registrationDate: DateTime.tryParse((m['registration_date'] as String?) ?? '') ?? DateTime.now(),
            paymentMethod: (m['payment_method'] as String?) ?? 'monthly',
            tuitionFee: (m['tuition_fee'] as int?) ?? 0,
            latenessThreshold: (m['lateness_threshold'] as int?) ?? 10,
            scheduleNotification: (m['schedule_notification'] as bool?) ?? false,
            attendanceNotification: (m['attendance_notification'] as bool?) ?? false,
            departureNotification: (m['departure_notification'] as bool?) ?? false,
            latenessNotification: (m['lateness_notification'] as bool?) ?? false,
            createdAt: DateTime.tryParse((m['created_at'] as String?) ?? '') ?? DateTime.now(),
            updatedAt: DateTime.tryParse((m['updated_at'] as String?) ?? '') ?? DateTime.now(),
          )).toList();
          studentPaymentInfosNotifier.value = List.unmodifiable(_studentPaymentInfos);
          print('[DEBUG] 학생 결제 정보 로드 완료(Supabase): ${_studentPaymentInfos.length}개');
          return;
        } catch (_) {}
      }
      await AcademyDbService.instance.ensureStudentPaymentInfoTable();
      final paymentInfoMaps = await AcademyDbService.instance.getAllStudentPaymentInfo();
      _studentPaymentInfos = paymentInfoMaps.map((map) => StudentPaymentInfo.fromJson(map)).toList();
      studentPaymentInfosNotifier.value = List.unmodifiable(_studentPaymentInfos);
      print('[DEBUG] 학생 결제 정보 로드 완료(Local): ${_studentPaymentInfos.length}개');
    } catch (e) {
      print('[ERROR] 학생 결제 정보 로드 실패: $e');
      _studentPaymentInfos = [];
      studentPaymentInfosNotifier.value = List.unmodifiable(_studentPaymentInfos);
    }
  }

  // 특정 학생의 결제 정보 조회
  StudentPaymentInfo? getStudentPaymentInfo(String studentId) {
    try {
      return _studentPaymentInfos.firstWhere((info) => info.studentId == studentId);
    } catch (e) {
      return null;
    }
  }

  // 학생 결제 정보 추가
  Future<void> addStudentPaymentInfo(StudentPaymentInfo paymentInfo) async {
    try {
      final paymentInfoData = paymentInfo.toJson();
      await AcademyDbService.instance.addStudentPaymentInfo(paymentInfoData);
      
      // 메모리 업데이트
      final existingIndex = _studentPaymentInfos.indexWhere((info) => info.studentId == paymentInfo.studentId);
      if (existingIndex != -1) {
        _studentPaymentInfos[existingIndex] = paymentInfo;
      } else {
        _studentPaymentInfos.add(paymentInfo);
      }
      
      studentPaymentInfosNotifier.value = List.unmodifiable(_studentPaymentInfos);
      print('[DEBUG] 학생 결제 정보 추가/업데이트 완료: ${paymentInfo.studentId}');
      // 서버 우선 모드: 결제 정보 upsert + 최초 due 생성 RPC 호출
      if (TagPresetService.preferSupabaseRead) {
        try {
          final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
          await Supabase.instance.client.from('student_payment_info').upsert({
            'id': paymentInfo.id,
            'academy_id': academyId,
            'student_id': paymentInfo.studentId,
            'registration_date': paymentInfo.registrationDate.toIso8601String(),
            'payment_method': paymentInfo.paymentMethod,
            'tuition_fee': paymentInfo.tuitionFee,
            'lateness_threshold': paymentInfo.latenessThreshold,
            'schedule_notification': paymentInfo.scheduleNotification,
            'attendance_notification': paymentInfo.attendanceNotification,
            'departure_notification': paymentInfo.departureNotification,
            'lateness_notification': paymentInfo.latenessNotification,
          }, onConflict: 'student_id');
          await Supabase.instance.client.rpc('init_first_due', params: {
            'p_student_id': paymentInfo.studentId,
            'p_first_due': paymentInfo.registrationDate.toIso8601String().substring(0, 10),
            'p_academy_id': academyId,
          });
        } catch (e, st) { print('[SUPA][student_payment_info upsert/init_first_due] $e\n$st'); }
      } else if (TagPresetService.dualWrite) {
        // 레거시 듀얼라이트 지원
        try {
          final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
          await Supabase.instance.client.from('student_payment_info').upsert({
            'id': paymentInfo.id,
            'academy_id': academyId,
            'student_id': paymentInfo.studentId,
            'registration_date': paymentInfo.registrationDate.toIso8601String(),
            'payment_method': paymentInfo.paymentMethod,
            'tuition_fee': paymentInfo.tuitionFee,
            'lateness_threshold': paymentInfo.latenessThreshold,
            'schedule_notification': paymentInfo.scheduleNotification,
            'attendance_notification': paymentInfo.attendanceNotification,
            'departure_notification': paymentInfo.departureNotification,
            'lateness_notification': paymentInfo.latenessNotification,
          }, onConflict: 'student_id');
        } catch (_) {}
      }
    } catch (e) {
      print('[ERROR] 학생 결제 정보 추가 실패: $e');
      rethrow;
    }
  }

  // 학생 결제 정보 업데이트
  Future<void> updateStudentPaymentInfo(StudentPaymentInfo paymentInfo) async {
    try {
      final updatedPaymentInfo = paymentInfo.copyWith(updatedAt: DateTime.now());
      final paymentInfoData = updatedPaymentInfo.toJson();
      await AcademyDbService.instance.updateStudentPaymentInfo(paymentInfo.studentId, paymentInfoData);
      
      // 메모리 업데이트
      final index = _studentPaymentInfos.indexWhere((info) => info.studentId == paymentInfo.studentId);
      if (index != -1) {
        _studentPaymentInfos[index] = updatedPaymentInfo;
        studentPaymentInfosNotifier.value = List.unmodifiable(_studentPaymentInfos);
      }
      
      print('[DEBUG] 학생 결제 정보 업데이트 완료: ${paymentInfo.studentId}');
      if (TagPresetService.dualWrite) {
        try {
          final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
          await Supabase.instance.client.from('student_payment_info').upsert({
            'id': updatedPaymentInfo.id,
            'academy_id': academyId,
            'student_id': updatedPaymentInfo.studentId,
            'registration_date': updatedPaymentInfo.registrationDate.toIso8601String(),
            'payment_method': updatedPaymentInfo.paymentMethod,
            'tuition_fee': updatedPaymentInfo.tuitionFee,
            'lateness_threshold': updatedPaymentInfo.latenessThreshold,
            'schedule_notification': updatedPaymentInfo.scheduleNotification,
            'attendance_notification': updatedPaymentInfo.attendanceNotification,
            'departure_notification': updatedPaymentInfo.departureNotification,
            'lateness_notification': updatedPaymentInfo.latenessNotification,
          }, onConflict: 'student_id');
        } catch (_) {}
      }
    } catch (e) {
      print('[ERROR] 학생 결제 정보 업데이트 실패: $e');
      rethrow;
    }
  }

  // 학생 결제 정보 삭제
  Future<void> deleteStudentPaymentInfo(String studentId) async {
    try {
      await AcademyDbService.instance.deleteStudentPaymentInfo(studentId);
      
      // 메모리에서 제거
      _studentPaymentInfos.removeWhere((info) => info.studentId == studentId);
      studentPaymentInfosNotifier.value = List.unmodifiable(_studentPaymentInfos);
      
      print('[DEBUG] 학생 결제 정보 삭제 완료: $studentId');
      if (TagPresetService.dualWrite) {
        try {
          await Supabase.instance.client.from('student_payment_info').delete().eq('student_id', studentId);
        } catch (_) {}
      }
    } catch (e) {
      print('[ERROR] 학생 결제 정보 삭제 실패: $e');
      rethrow;
    }
  }

  // ======== RESOURCES (FOLDERS/FILES) ========
  Future<void> saveResourceFolders(List<Map<String, dynamic>> rows) =>
      ResourceService.instance.saveResourceFolders(rows);
  Future<void> saveResourceFoldersForCategory(String category, List<Map<String, dynamic>> rows) =>
      ResourceService.instance.saveResourceFoldersForCategory(category, rows);
  Future<List<Map<String, dynamic>>> loadResourceFolders() =>
      ResourceService.instance.loadResourceFolders();
  Future<List<Map<String, dynamic>>> loadResourceFoldersForCategory(String category) =>
      ResourceService.instance.loadResourceFoldersForCategory(category);
  Future<void> saveResourceFile(Map<String, dynamic> row) =>
      ResourceService.instance.saveResourceFile(row);
  Future<void> saveResourceFileWithCategory(Map<String, dynamic> row, String category) =>
      ResourceService.instance.saveResourceFileWithCategory(row, category);
  Future<List<Map<String, dynamic>>> loadResourceFiles() =>
      ResourceService.instance.loadResourceFiles();
  Future<List<Map<String, dynamic>>> loadResourceFilesForCategory(String category) =>
      ResourceService.instance.loadResourceFilesForCategory(category);
  Future<void> saveResourceFileLinks(String fileId, Map<String, String> links) =>
      ResourceService.instance.saveResourceFileLinks(fileId, links);
  Future<Map<String, String>> loadResourceFileLinks(String fileId) =>
      ResourceService.instance.loadResourceFileLinks(fileId);
  Future<void> deleteResourceFile(String fileId) =>
      ResourceService.instance.deleteResourceFile(fileId);

  // ======== RESOURCE FAVORITES ========
  Future<Set<String>> loadResourceFavorites() =>
      ResourceService.instance.loadResourceFavorites();
  Future<void> addResourceFavorite(String fileId) =>
      ResourceService.instance.addResourceFavorite(fileId);
  Future<void> removeResourceFavorite(String fileId) =>
      ResourceService.instance.removeResourceFavorite(fileId);

  // ======== RESOURCE FILE BOOKMARKS ========
  Future<List<Map<String, dynamic>>> loadResourceFileBookmarks(String fileId) =>
      ResourceService.instance.loadResourceFileBookmarks(fileId);
  Future<void> saveResourceFileBookmarks(String fileId, List<Map<String, dynamic>> items) =>
      ResourceService.instance.saveResourceFileBookmarks(fileId, items);

  // ======== RESOURCE GRADES (학년 목록/순서) ========
  Future<List<Map<String, dynamic>>> getResourceGrades() =>
      ResourceService.instance.getResourceGrades();
  Future<void> saveResourceGrades(List<String> names) =>
      ResourceService.instance.saveResourceGrades(names);

  // ======== RESOURCE GRADE ICONS ========
  Future<Map<String, int>> getResourceGradeIcons() =>
      ResourceService.instance.getResourceGradeIcons();
  Future<void> setResourceGradeIcon(String name, int icon) =>
      ResourceService.instance.setResourceGradeIcon(name, icon);
  Future<void> deleteResourceGradeIcon(String name) =>
      ResourceService.instance.deleteResourceGradeIcon(name);

  // ======== ANSWER KEY (우측 사이드시트: 책 리스트) ========
  Future<List<Map<String, dynamic>>> loadAnswerKeyGrades() =>
      AnswerKeyService.instance.loadAnswerKeyGrades();
  Future<void> saveAnswerKeyGrades(List<Map<String, dynamic>> rows) =>
      AnswerKeyService.instance.saveAnswerKeyGrades(rows);

  Future<List<Map<String, dynamic>>> loadAnswerKeyBooks() =>
      AnswerKeyService.instance.loadAnswerKeyBooks();
  Future<void> saveAnswerKeyBook(Map<String, dynamic> row) =>
      AnswerKeyService.instance.saveAnswerKeyBook(row);
  Future<void> saveAnswerKeyBooks(List<Map<String, dynamic>> rows) =>
      AnswerKeyService.instance.saveAnswerKeyBooks(rows);
  Future<void> deleteAnswerKeyBook(String id) =>
      AnswerKeyService.instance.deleteAnswerKeyBook(id);

  Future<List<Map<String, dynamic>>> loadAnswerKeyBookPdfs() =>
      AnswerKeyService.instance.loadAnswerKeyBookPdfs();
  Future<void> saveAnswerKeyBookPdf(Map<String, dynamic> row) =>
      AnswerKeyService.instance.saveAnswerKeyBookPdf(row);
  Future<void> deleteAnswerKeyBookPdf({
    required String bookId,
    required String gradeKey,
  }) =>
      AnswerKeyService.instance.deleteAnswerKeyBookPdf(bookId: bookId, gradeKey: gradeKey);

  // ===== EXAM (persisted) =====
  Future<void> saveExamFor(String school, EducationLevel level, int grade, Map<DateTime, List<String>> titles, Map<DateTime, String> ranges) async {
    await AcademyDbService.instance.saveExamDataForSchoolGrade(
      school: school,
      level: level.index,
      grade: grade,
      titlesByDateIso: {
        for (final e in titles.entries)
          DateTime(e.key.year, e.key.month, e.key.day).toIso8601String(): e.value,
      },
      rangesByDateIso: {
        for (final e in ranges.entries)
          DateTime(e.key.year, e.key.month, e.key.day).toIso8601String(): e.value,
      },
    );
    final key = _sgKey(school, level, grade);
    _examTitlesBySg[key] = {
      for (final e in titles.entries)
        DateTime(e.key.year, e.key.month, e.key.day): e.value,
    };
    _examRangesBySg[key] = {
      for (final e in ranges.entries)
        DateTime(e.key.year, e.key.month, e.key.day): e.value,
    };

    // Supabase dual-write: exam_schedules + exam_ranges
    if (TagPresetService.dualWrite) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        // schedules
        await supa.from('exam_schedules').delete().match({'academy_id': academyId, 'school': school, 'level': level.index, 'grade': grade});
        if (titles.isNotEmpty) {
          final rows = titles.entries.map((e) => {
            'academy_id': academyId,
          'school': school,
          'level': level.index,
          'grade': grade,
            'date': DateTime(e.key.year, e.key.month, e.key.day).toIso8601String().substring(0,10),
            'names_json': jsonEncode(e.value),
          }).toList();
          await supa.from('exam_schedules').insert(rows);
        }
        // ranges
        await supa.from('exam_ranges').delete().match({'academy_id': academyId, 'school': school, 'level': level.index, 'grade': grade});
        if (ranges.isNotEmpty) {
          final rows2 = ranges.entries.map((e) => {
            'academy_id': academyId,
          'school': school,
          'level': level.index,
          'grade': grade,
            'date': DateTime(e.key.year, e.key.month, e.key.day).toIso8601String().substring(0,10),
            'range_text': e.value,
          }).toList();
          await supa.from('exam_ranges').insert(rows2);
        }
      } catch (_) {}
    }
  }

  Future<Map<String, dynamic>> loadExamFor(String school, EducationLevel level, int grade) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final schedules = await supa.from('exam_schedules').select('date,names_json').match({'academy_id': academyId, 'school': school, 'level': level.index, 'grade': grade}).order('date');
        final ranges = await supa.from('exam_ranges').select('date,range_text').match({'academy_id': academyId, 'school': school, 'level': level.index, 'grade': grade}).order('date');
        final days = await supa.from('exam_days').select('date').match({'academy_id': academyId, 'school': school, 'level': level.index, 'grade': grade}).order('date');
        final res = {
          'schedules': (schedules as List).map((r) => {
            'date': (r['date'] as String?) ?? '',
            'names_json': (r['names_json'] as String?) ?? '[]',
          }).toList(),
          'ranges': (ranges as List).map((r) => {
            'date': (r['date'] as String?) ?? '',
            'range_text': (r['range_text'] as String?) ?? '',
          }).toList(),
          'days': (days as List).map((r) => {
            'date': (r['date'] as String?) ?? '',
          }).toList(),
        };
        // 캐시에 반영
        final titles = <DateTime, List<String>>{};
        for (final row in (res['schedules'] as List).cast<Map<String, dynamic>>()) {
          final iso = row['date'] as String?; if (iso == null || iso.isEmpty) continue;
          final d = DateTime.parse(iso);
          List<dynamic> list; try { list = jsonDecode((row['names_json'] as String?) ?? '[]'); } catch (_) { list = []; }
          titles[DateTime(d.year, d.month, d.day)] = list.map((e)=>e.toString()).toList();
        }
        final rangesMap = <DateTime, String>{};
        for (final row in (res['ranges'] as List).cast<Map<String, dynamic>>()) {
          final iso = row['date'] as String?; if (iso == null || iso.isEmpty) continue;
          final d = DateTime.parse(iso);
          rangesMap[DateTime(d.year, d.month, d.day)] = (row['range_text'] as String?) ?? '';
        }
        final daysSet = <DateTime>{};
        for (final row in (res['days'] as List).cast<Map<String, dynamic>>()) {
          final iso = row['date'] as String?; if (iso == null || iso.isEmpty) continue;
          final d = DateTime.parse(iso);
          daysSet.add(DateTime(d.year, d.month, d.day));
        }
        final key2 = _sgKey(school, level, grade);
        _examTitlesBySg[key2] = titles;
        _examRangesBySg[key2] = rangesMap;
        _examDaysBySg[key2] = daysSet;
        return res;
      } catch (_) {
        // fallback below
      }
    }
    final res = await AcademyDbService.instance.loadExamDataForSchoolGrade(
      school: school,
      level: level.index,
      grade: grade,
    );
    // 기존 캐시 반영 로직 유지
    final titles = <DateTime, List<String>>{};
    for (final row in (res['schedules'] as List).cast<Map<String, dynamic>>()) {
      final iso = row['date'] as String?; if (iso == null || iso.isEmpty) continue;
      final d = DateTime.parse(iso);
      List<dynamic> list; try { list = jsonDecode((row['names_json'] as String?) ?? '[]'); } catch (_) { list = []; }
      titles[DateTime(d.year, d.month, d.day)] = list.map((e)=>e.toString()).toList();
    }
    final rangesMap = <DateTime, String>{};
    for (final row in (res['ranges'] as List).cast<Map<String, dynamic>>()) {
      final iso = row['date'] as String?; if (iso == null || iso.isEmpty) continue;
      final d = DateTime.parse(iso);
      rangesMap[DateTime(d.year, d.month, d.day)] = (row['range_text'] as String?) ?? '';
    }
    final daysSet = <DateTime>{};
    for (final row in (res['days'] as List).cast<Map<String, dynamic>>()) {
      final iso = row['date'] as String?; if (iso == null || iso.isEmpty) continue;
      final d = DateTime.parse(iso);
      daysSet.add(DateTime(d.year, d.month, d.day));
    }
    final key2 = _sgKey(school, level, grade);
    _examTitlesBySg[key2] = titles;
    _examRangesBySg[key2] = rangesMap;
    _examDaysBySg[key2] = daysSet;
    return res;
  }

  Future<void> deleteExamData(String school, EducationLevel level, int grade) async {
    // 서버 우선: Supabase에서 삭제, 실패 시 로컬로 폴백
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        await supa.from('exam_schedules').delete().match({'academy_id': academyId, 'school': school, 'level': level.index, 'grade': grade});
        await supa.from('exam_ranges').delete().match({'academy_id': academyId, 'school': school, 'level': level.index, 'grade': grade});
        await supa.from('exam_days').delete().match({'academy_id': academyId, 'school': school, 'level': level.index, 'grade': grade});
      } catch (e, st) {
        print('[SUPA][exam delete] $e\n$st');
        // 폴백: 로컬 삭제
    await AcademyDbService.instance.deleteExamDataForSchoolGrade(
      school: school,
      level: level.index,
      grade: grade,
    );
      }
    } else {
      await AcademyDbService.instance.deleteExamDataForSchoolGrade(
        school: school,
        level: level.index,
        grade: grade,
      );
    }
    // 캐시 정리
    final key = _sgKey(school, level, grade);
    _examTitlesBySg.remove(key);
    _examRangesBySg.remove(key);
    _examDaysBySg.remove(key);
  }

  Future<void> saveExamDays(String school, EducationLevel level, int grade, Set<DateTime> days) async {
    final list = days.map((d) => DateTime(d.year, d.month, d.day).toIso8601String()).toList();
    await AcademyDbService.instance.saveExamDaysForSchoolGrade(
      school: school,
      level: level.index,
      grade: grade,
      daysIso: list,
    );
    final key = _sgKey(school, level, grade);
    _examDaysBySg[key] = days.map((d)=>DateTime(d.year, d.month, d.day)).toSet();

    // Supabase dual-write
    if (TagPresetService.dualWrite) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        // delete all then insert to keep exact match
        await supa.from('exam_days').delete().match({'academy_id': academyId, 'school': school, 'level': level.index, 'grade': grade});
        if (list.isNotEmpty) {
          final rows = list.map((iso) => {
            'academy_id': academyId,
            'school': school,
            'level': level.index,
            'grade': grade,
            'date': iso.substring(0, 10),
          }).toList();
          await supa.from('exam_days').insert(rows);
        }
      } catch (_) {}
    }
  }

  // exam_days(DB) 기반으로 저장된 날짜 집합 조회용 공개 getter
  // 주의: 외부 변조를 막기 위해 날짜만 남긴 사본(Set)을 반환합니다.
  Set<DateTime> getExamDaysForSchoolGrade({
    required String school,
    required EducationLevel level,
    required int grade,
  }) {
    final key = _sgKey(school, level, grade);
    final set = _examDaysBySg[key];
    if (set == null || set.isEmpty) {
      return <DateTime>{};
    }
    return set.map((d) => DateTime(d.year, d.month, d.day)).toSet();
  }

  Future<void> preloadAllExamData() async {
    try {
      final schedules = await AcademyDbService.instance.loadAllExamSchedules();
      for (final r in schedules) {
        final school = (r['school'] as String?) ?? '';
        final level = EducationLevel.values[(r['level'] as int?) ?? 0];
        final grade = (r['grade'] as int?) ?? 0;
        final iso = (r['date'] as String?) ?? '';
        if (school.isEmpty || iso.isEmpty) continue;
        final d = DateTime.parse(iso);
        List<dynamic> list; try { list = jsonDecode((r['names_json'] as String?) ?? '[]'); } catch (_) { list = []; }
        final key = _sgKey(school, level, grade);
        final map = _examTitlesBySg.putIfAbsent(key, ()=>{});
        map[DateTime(d.year, d.month, d.day)] = list.map((e)=>e.toString()).toList();
      }
      final ranges = await AcademyDbService.instance.loadAllExamRanges();
      for (final r in ranges) {
        final school = (r['school'] as String?) ?? '';
        final level = EducationLevel.values[(r['level'] as int?) ?? 0];
        final grade = (r['grade'] as int?) ?? 0;
        final iso = (r['date'] as String?) ?? '';
        final text = (r['range_text'] as String?) ?? '';
        if (school.isEmpty || iso.isEmpty) continue;
        final d = DateTime.parse(iso);
        final key = _sgKey(school, level, grade);
        final map = _examRangesBySg.putIfAbsent(key, ()=>{});
        map[DateTime(d.year, d.month, d.day)] = text;
      }
      final days = await AcademyDbService.instance.loadAllExamDays();
      for (final r in days) {
        final school = (r['school'] as String?) ?? '';
        final level = EducationLevel.values[(r['level'] as int?) ?? 0];
        final grade = (r['grade'] as int?) ?? 0;
        final iso = (r['date'] as String?) ?? '';
        if (school.isEmpty || iso.isEmpty) continue;
        final d = DateTime.parse(iso);
        final key = _sgKey(school, level, grade);
        final set = _examDaysBySg.putIfAbsent(key, ()=>{});
        set.add(DateTime(d.year, d.month, d.day));
      }
    } catch (_) {}
  }
} 