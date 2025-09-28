import 'dart:async';
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
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
import '../models/session_override.dart';
import '../models/student_payment_info.dart';
import 'package:flutter/foundation.dart';
import 'academy_db.dart';
import 'sync_service.dart';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../models/memo.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/material.dart';
import 'tenant_service.dart';
import 'tag_preset_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel, PostgresChangeEvent, PostgresChangeFilter, PostgresChangeFilterType;
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
  // 기본 주간 수업 횟수
  int get weeklyClassCount => 1;
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
  List<AttendanceRecord> _attendanceRecords = [];
  List<StudentPaymentInfo> _studentPaymentInfos = [];
  RealtimeChannel? _attendanceRealtimeChannel;

  final ValueNotifier<List<GroupInfo>> groupsNotifier = ValueNotifier<List<GroupInfo>>([]);
  final ValueNotifier<List<StudentWithInfo>> studentsNotifier = ValueNotifier<List<StudentWithInfo>>([]);
  final ValueNotifier<List<PaymentRecord>> paymentRecordsNotifier = ValueNotifier<List<PaymentRecord>>([]);
  final ValueNotifier<List<AttendanceRecord>> attendanceRecordsNotifier = ValueNotifier<List<AttendanceRecord>>([]);
  final ValueNotifier<List<StudentPaymentInfo>> studentPaymentInfosNotifier = ValueNotifier<List<StudentPaymentInfo>>([]);
  
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
  List<AttendanceRecord> get attendanceRecords => List.unmodifiable(_attendanceRecords);

  AcademySettings _academySettings = AcademySettings(name: '', slogan: '', defaultCapacity: 30, lessonDuration: 50, logo: null);
  PaymentType _paymentType = PaymentType.monthly;

  AcademySettings get academySettings => _academySettings;
  PaymentType get paymentType => _paymentType;

  set paymentType(PaymentType type) {
    _paymentType = type;
  }

  List<StudentTimeBlock> _studentTimeBlocks = [];
  final ValueNotifier<List<StudentTimeBlock>> studentTimeBlocksNotifier = ValueNotifier<List<StudentTimeBlock>>([]);
  
  List<GroupSchedule> _groupSchedules = [];
  final ValueNotifier<List<GroupSchedule>> groupSchedulesNotifier = ValueNotifier<List<GroupSchedule>>([]);

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
  set selfStudyTimeBlocks(List<SelfStudyTimeBlock> value) {
    _selfStudyTimeBlocks = value;
    selfStudyTimeBlocksNotifier.value = List.unmodifiable(_selfStudyTimeBlocks);
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
      await loadGroups();
      await loadStudentPaymentInfos(); // 학생 결제 정보를 먼저 로딩
      await loadStudents(); // registration_date를 가져오기 위해 student_payment_info 후에 호출
      await loadAcademySettings();
      await loadPaymentType();
      await _loadOperatingHours();
      await loadStudentTimeBlocks();
      await loadSessionOverrides();
      await _subscribeSessionOverridesRealtime();
      await loadSelfStudyTimeBlocks(); // 자습 블록도 반드시 불러오기
      await loadGroupSchedules();
      await loadTeachers();
      await loadClasses(); // 수업 정보 로딩 추가
      await loadPaymentRecords(); // 수강료 납부 기록 로딩 추가
      await loadAttendanceRecords(); // 출석 기록 로딩 추가
      await _subscribeAttendanceRealtime(); // 출석 Realtime 구독
      await loadMemos();
      await preloadAllExamData(); // 시험 데이터 캐시 프리로드
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
  List<Memo> _memos = [];
  final ValueNotifier<List<Memo>> memosNotifier = ValueNotifier<List<Memo>>([]);

  Future<void> loadMemos() async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final rows = await supa.from('memos')
            .select('id,original,summary,scheduled_at,dismissed,created_at,updated_at,recurrence_type,weekdays,recurrence_end,recurrence_count')
            .eq('academy_id', academyId)
            .order('scheduled_at', ascending: true);
        final List<dynamic> list = rows as List<dynamic>;
        _memos = list.map<Memo>((m) {
          final String? schedStr = m['scheduled_at'] as String?;
          final String? createdStr = m['created_at'] as String?;
          final String? updatedStr = m['updated_at'] as String?;
          final String? weekdaysStr = m['weekdays'] as String?;
          final String? recurEndStr = m['recurrence_end'] as String?;
          return Memo(
            id: m['id'] as String,
            original: (m['original'] as String?) ?? '',
            summary: (m['summary'] as String?) ?? '',
            scheduledAt: (schedStr != null && schedStr.isNotEmpty) ? DateTime.parse(schedStr) : null,
            dismissed: (m['dismissed'] as bool?) ?? false,
            createdAt: (createdStr != null && createdStr.isNotEmpty) ? DateTime.parse(createdStr) : DateTime.now(),
            updatedAt: (updatedStr != null && updatedStr.isNotEmpty) ? DateTime.parse(updatedStr) : DateTime.now(),
            recurrenceType: m['recurrence_type'] as String?,
            weekdays: (weekdaysStr == null || weekdaysStr.isEmpty)
                ? null
                : weekdaysStr.split(',').where((e) => e.isNotEmpty).map(int.parse).toList(),
            recurrenceEnd: (recurEndStr != null && recurEndStr.isNotEmpty) ? DateTime.parse(recurEndStr) : null,
            recurrenceCount: m['recurrence_count'] as int?,
          );
        }).toList();
        memosNotifier.value = List.unmodifiable(_memos);
        return;
      } catch (e, st) {
        print('[SUPA][memos load] $e\n$st');
      }
    }
    final rows = await AcademyDbService.instance.getMemos();
    _memos = rows.map((m) => Memo.fromMap(m)).toList();
    memosNotifier.value = List.unmodifiable(_memos);
  }

  Future<void> addMemo(Memo memo) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final row = {
          'id': memo.id,
          'academy_id': academyId,
          'original': memo.original,
          'summary': memo.summary,
          'scheduled_at': memo.scheduledAt?.toIso8601String(),
          'dismissed': memo.dismissed,
          'recurrence_type': memo.recurrenceType,
          'weekdays': memo.weekdays?.join(','),
          'recurrence_end': memo.recurrenceEnd?.toIso8601String().substring(0,10),
          'recurrence_count': memo.recurrenceCount,
        }..removeWhere((k,v)=>v==null);
        await supa.from('memos').upsert(row, onConflict: 'id');
        _memos.insert(0, memo);
        memosNotifier.value = List.unmodifiable(_memos);
        return;
      } catch (e, st) { print('[SUPA][memos add] $e\n$st'); }
    }
    _memos.insert(0, memo);
    memosNotifier.value = List.unmodifiable(_memos);
    await AcademyDbService.instance.addMemo(memo.toMap());
  }

  Future<void> updateMemo(Memo memo) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final row = {
          'id': memo.id,
          'academy_id': academyId,
          'original': memo.original,
          'summary': memo.summary,
          'scheduled_at': memo.scheduledAt?.toIso8601String(),
          'dismissed': memo.dismissed,
          'recurrence_type': memo.recurrenceType,
          'weekdays': memo.weekdays?.join(','),
          'recurrence_end': memo.recurrenceEnd?.toIso8601String().substring(0,10),
          'recurrence_count': memo.recurrenceCount,
        }..removeWhere((k,v)=>v==null);
        await supa.from('memos').upsert(row, onConflict: 'id');
        final idx = _memos.indexWhere((m) => m.id == memo.id);
        if (idx != -1) _memos[idx] = memo;
        memosNotifier.value = List.unmodifiable(_memos);
        return;
      } catch (e, st) { print('[SUPA][memos update] $e\n$st'); }
    }
    final idx = _memos.indexWhere((m) => m.id == memo.id);
    if (idx != -1) {
      _memos[idx] = memo;
      memosNotifier.value = List.unmodifiable(_memos);
      await AcademyDbService.instance.updateMemo(memo.id, memo.toMap());
    }
  }

  Future<void> deleteMemo(String id) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        await Supabase.instance.client.from('memos').delete().eq('id', id);
        _memos.removeWhere((m) => m.id == id);
        memosNotifier.value = List.unmodifiable(_memos);
        return;
      } catch (e, st) { print('[SUPA][memos delete] $e\n$st'); }
    }
    _memos.removeWhere((m) => m.id == id);
    memosNotifier.value = List.unmodifiable(_memos);
    await AcademyDbService.instance.deleteMemo(id);
  }

  void _initializeDefaults() {
    _groups = [];
    _groupsById = {};
    _studentsWithInfo = [];
    _operatingHours = [];
    _studentTimeBlocks = [];
    _classes = [];
    _paymentRecords = [];
    _attendanceRecords = [];
    _sessionOverrides = [];
    _academySettings = AcademySettings(name: '', slogan: '', defaultCapacity: 30, lessonDuration: 50, logo: null);
    _paymentType = PaymentType.monthly;
    _notifyListeners();
  }

  Future<void> loadGroups() async {
    try {
      if (TagPresetService.preferSupabaseRead) {
        try {
          final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
          final data = await Supabase.instance.client
              .from('groups')
              .select('id,name,description,capacity,duration,color')
              .eq('academy_id', academyId)
              .order('name');
          _groups = (data as List).map((m) => GroupInfo(
            id: (m['id'] as String),
            name: (m['name'] as String? ?? ''),
            description: (m['description'] as String? ?? ''),
            capacity: (m['capacity'] as int?) ?? 0,
            duration: (m['duration'] as int?) ?? 0,
            color: Color((((m['color'] as int?) ?? 0xFF607D8B)).toSigned(32)),
          )).toList();
          // Fallback/backfill은 dualWrite가 켜진 경우에만 수행
          if (_groups.isEmpty && TagPresetService.dualWrite) {
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
        } catch (_) {
          // fallback to local below
        }
      }
      // 서버 전용 모드에서는 로컬 폴백을 하지 않는다
      if (!TagPresetService.preferSupabaseRead) {
      _groups = (await AcademyDbService.instance.getGroups()).where((g) => g != null).toList();
      _groupsById = {for (var g in _groups) g.id: g};
      } else {
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
              id: '', studentId: s.id, registrationDate: DateTime.now(), paymentMethod: 'monthly', weeklyClassCount: 1,
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
    await AcademyDbService.instance.saveStudents(_studentsWithInfo.map((si) => si.student).toList());
  }

  Future<void> saveGroups() async {
    try {
      if (TagPresetService.preferSupabaseRead) {
        try {
          final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
          final supa = Supabase.instance.client;
          await supa.from('groups').delete().eq('academy_id', academyId);
          if (_groups.isNotEmpty) {
            final rows = _groups.map((g) => {
              'id': g.id,
              'academy_id': academyId,
              'name': g.name,
              'description': g.description,
              'capacity': g.capacity,
              'duration': g.duration,
              'color': g.color.value.toSigned(32),
            }).toList();
            await supa.from('groups').insert(rows);
          }
          return;
        } catch (e, st) { print('[SUPA][groups save] $e\n$st'); }
      }
      await AcademyDbService.instance.saveGroups(_groups);
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
      dbData ??= await AcademyDbService.instance.getAcademySettings();
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
    studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
    groupSchedulesNotifier.value = List.unmodifiable(_groupSchedules);
    teachersNotifier.value = List.unmodifiable(_teachers);
    selfStudyTimeBlocksNotifier.value = List.unmodifiable(_selfStudyTimeBlocks);
    classesNotifier.value = List.unmodifiable(_classes);
    paymentRecordsNotifier.value = List.unmodifiable(_paymentRecords);
    attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
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
          .select('id,student_id,session_type_id,set_id,override_type,original_attendance_id,replacement_attendance_id,original_class_datetime,replacement_class_datetime,duration_minutes,reason,status,created_at,updated_at,version')
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
    } catch (e) {
      print('[ERROR] addSessionOverride 실패: $e');
      rethrow;
    }
  }

  Future<void> updateSessionOverride(SessionOverride newData) async {
    try {
      _validateOverride(newData);
      final supa = Supabase.instance.client;
      final base = {
        'student_id': newData.studentId,
        'session_type_id': newData.sessionTypeId,
        'set_id': newData.setId,
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
      print('[DEBUG] session_override 업데이트(Supabase): id=${newData.id}, status=${newData.status}');
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
    // 운영시간 체크
    final weekday = replacement.weekday % 7; // DateTime weekday: 1=Mon..7=Sun → 0~6로 변환
    final hours = _operatingHours.firstWhere(
      (h) => h.dayOfWeek == (weekday == 0 ? 6 : weekday - 1),
      orElse: () => OperatingHours(dayOfWeek: 0, startHour: 0, startMinute: 0, endHour: 23, endMinute: 59),
    );
    final repStart = Duration(hours: replacement.hour, minutes: replacement.minute);
    final repEnd = repStart + Duration(minutes: duration);
    final opStart = Duration(hours: hours.startHour, minutes: hours.startMinute);
    final opEnd = Duration(hours: hours.endHour, minutes: hours.endMinute);
    if (repStart < opStart || repEnd > opEnd) {
      throw Exception('운영시간을 벗어났습니다. (${hours.startHour.toString().padLeft(2,'0')}:${hours.startMinute.toString().padLeft(2,'0')}~${hours.endHour.toString().padLeft(2,'0')}:${hours.endMinute.toString().padLeft(2,'0')})');
    }
    // 휴게시간과 겹침 금지
    for (final b in hours.breakTimes) {
      final bStart = Duration(hours: b.startHour, minutes: b.startMinute);
      final bEnd = Duration(hours: b.endHour, minutes: b.endMinute);
      final overlap = repStart < bEnd && repEnd > bStart;
      if (overlap) {
        throw Exception('휴게시간과 겹칩니다.');
      }
    }
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
      print('[DEBUG] session_override 취소(Supabase): id=$id');
    } catch (e) {
      print('[ERROR] cancelSessionOverride 실패: $e');
      rethrow;
    }
  }

  Future<void> deleteSessionOverride(String id) async {
    try {
      final supa = Supabase.instance.client;
      await supa.from('session_overrides').delete().eq('id', id);
      _sessionOverrides.removeWhere((o) => o.id == id);
      sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);
      print('[DEBUG] session_override 삭제(Supabase): id=$id');
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
    if (_groupsById.containsKey(groupInfo.id)) {
      _groupsById.remove(groupInfo.id);
      _groups = _groupsById.values.where((g) => g != null).toList();
      
      // Remove group from students
      for (var i = 0; i < _studentsWithInfo.length; i++) {
        if (_studentsWithInfo[i].student.groupInfo?.id == groupInfo.id) {
          _studentsWithInfo.removeAt(i);
          i--;
        }
      }
      
      _notifyListeners();
      Future.wait([
        saveGroups(),
        saveStudents(),
      ]);
    }
  }

  Future<void> addStudent(Student student, StudentBasicInfo basicInfo) async {
    print('[DEBUG][addStudent] student: ' + student.toString());
    print('[DEBUG][addStudent] basicInfo: ' + basicInfo.toString());
    // 그룹 정원 초과 이중 방어
    if (basicInfo.groupId != null) {
      final group = _groupsById[basicInfo.groupId];
      if (group != null) {
        final currentCount = _studentsWithInfo.where((s) => s.student.groupInfo?.id == group.id).length;
        if (currentCount >= group.capacity) {
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
          weeklyClassCount: 1,
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
          'weekly_class_count': paymentInfo.weeklyClassCount,
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
      if (group != null) {
        final currentCount = _studentsWithInfo.where((s) => s.student.groupInfo?.id == group.id && s.student.id != student.id).length;
        if (currentCount >= group.capacity) {
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
      try {
        final supa = Supabase.instance.client;
        await supa.from('student_basic_info').delete().eq('student_id', id);
        await supa.from('student_payment_info').delete().eq('student_id', id);
        await supa.from('students').delete().eq('id', id);
      } catch (e, st) { print('[SUPA][deleteStudent server-only] $e\n$st'); }
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
    // 학생의 부가 정보도 함께 삭제
    await AcademyDbService.instance.deleteStudentBasicInfo(id);
    print('[DEBUG][deleteStudent] StudentBasicInfo 삭제 완료: id=$id');
    await AcademyDbService.instance.deleteStudent(id);
    print('[DEBUG][deleteStudent] DB 삭제 완료: id=$id');
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
      await AcademyDbService.instance.saveOperatingHours(hours);
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
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final data = await Supabase.instance.client
            .from('student_time_blocks')
            .select('id,student_id,day_index,start_hour,start_minute,duration,block_created_at,set_id,number,session_type_id,weekly_order')
            .eq('academy_id', academyId)
            .order('day_index')
            .order('start_hour')
            .order('start_minute');
        _studentTimeBlocks = (data as List).map((m) {
          final Map<String, dynamic> mm = Map<String, dynamic>.from(m);
          return StudentTimeBlock(
            id: (mm['id'] as String),
            studentId: (mm['student_id'] as String),
            dayIndex: (mm['day_index'] as int?) ?? 0,
            startHour: (mm['start_hour'] as int?) ?? 0,
            startMinute: (mm['start_minute'] as int?) ?? 0,
            duration: Duration(minutes: (mm['duration'] as int?) ?? 0),
            createdAt: DateTime.tryParse((mm['block_created_at'] as String?) ?? '') ?? DateTime.now(),
            setId: mm['set_id'] as String?,
            number: mm['number'] as int?,
            sessionTypeId: mm['session_type_id'] as String?,
            weeklyOrder: mm['weekly_order'] as int?,
          );
        }).toList();
        studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
        print('[DEBUG] student_time_blocks 로드 완료(Supabase): ${_studentTimeBlocks.length}개');
        return;
      } catch (e) {
        print('[DEBUG] student_time_blocks Supabase 로드 실패, 로컬로 폴백: $e');
      }
    }

    final rawBlocks = await AcademyDbService.instance.getStudentTimeBlocks();
    _studentTimeBlocks = rawBlocks;
    studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
  }

  Future<void> saveStudentTimeBlocks() async {
    await AcademyDbService.instance.saveStudentTimeBlocks(_studentTimeBlocks);
  }

  Future<void> addStudentTimeBlock(StudentTimeBlock block) async {
    // 중복 체크: 같은 학생, 같은 요일, 같은 시작시간, 같은 duration 블록이 이미 있으면 등록 금지
    final exists = _studentTimeBlocks.any((b) =>
      b.studentId == block.studentId &&
      b.dayIndex == block.dayIndex &&
      b.startHour == block.startHour &&
      b.startMinute == block.startMinute
    );
    if (exists) {
      throw Exception('이미 등록된 시간입니다.');
    }
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final row = <String, dynamic>{
          'id': block.id,
          'academy_id': academyId,
          'student_id': block.studentId,
          'day_index': block.dayIndex,
          'start_hour': block.startHour,
          'start_minute': block.startMinute,
          'duration': block.duration.inMinutes,
          'block_created_at': block.createdAt.toIso8601String(),
          'set_id': block.setId,
          'number': block.number,
          'session_type_id': block.sessionTypeId,
          'weekly_order': block.weeklyOrder,
        }..removeWhere((k, v) => v == null);
        await Supabase.instance.client.from('student_time_blocks').upsert(row, onConflict: 'id');
        _studentTimeBlocks.add(block);
        studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
        if (block.setId != null) {
          await _recalculateWeeklyOrderForStudent(block.studentId);
        }
        return;
      } catch (e, st) {
        print('[SUPA][stb add] $e\n$st');
        rethrow;
      }
    }
    _studentTimeBlocks.add(block);
    studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
    await AcademyDbService.instance.addStudentTimeBlock(block);
    if (block.setId != null) {
      await _recalculateWeeklyOrderForStudent(block.studentId);
    }
  }

  Future<void> removeStudentTimeBlock(String id) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        await Supabase.instance.client.from('student_time_blocks').delete().eq('id', id);
        _studentTimeBlocks.removeWhere((b) => b.id == id);
        studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
        return;
      } catch (e, st) {
        print('[SUPA][stb delete] $e\n$st');
        rethrow;
      }
    }
    _studentTimeBlocks.removeWhere((b) => b.id == id);
    studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
    await AcademyDbService.instance.deleteStudentTimeBlock(id);
    await loadStudentTimeBlocks();
  }

  Timer? _uiUpdateTimer;
  
  Future<void> bulkAddStudentTimeBlocks(List<StudentTimeBlock> blocks, {bool immediate = false}) async {
    // 중복 및 시간 겹침 방어: 모든 블록에 대해 검사
    for (final newBlock in blocks) {
      final overlap = _studentTimeBlocks.any((b) =>
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
    
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final rows = blocks.map((b) => <String, dynamic>{
          'id': b.id,
          'academy_id': academyId,
          'student_id': b.studentId,
          'day_index': b.dayIndex,
          'start_hour': b.startHour,
          'start_minute': b.startMinute,
          'duration': b.duration.inMinutes,
          'block_created_at': b.createdAt.toIso8601String(),
          'set_id': b.setId,
          'number': b.number,
          'session_type_id': b.sessionTypeId,
          'weekly_order': b.weeklyOrder,
        }..removeWhere((k, v) => v == null)).toList();
        await Supabase.instance.client.from('student_time_blocks').upsert(rows, onConflict: 'id');
        _studentTimeBlocks.addAll(blocks);
      } catch (e, st) {
        print('[SUPA][stb bulk add] $e\n$st');
        rethrow;
      }
    } else {
    _studentTimeBlocks.addAll(blocks);
    await AcademyDbService.instance.bulkAddStudentTimeBlocks(blocks);
    }
    
    if (immediate || blocks.length == 1) {
      // 단일 블록이나 즉시 반영 요청 시 바로 업데이트
      studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
    } else {
      // 다중 블록은 debouncing으로 지연 (150ms 후 한 번에 반영)
      _uiUpdateTimer?.cancel();
      _uiUpdateTimer = Timer(const Duration(milliseconds: 150), () {
        studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
      });
    }
    // 블록 추가 후 주간 순번 재계산 (대상 학생들만)
    final affectedStudentIds = blocks.map((b) => b.studentId).toSet();
    for (final studentId in affectedStudentIds) {
      await _recalculateWeeklyOrderForStudent(studentId);
    }
  }

  Future<void> bulkDeleteStudentTimeBlocks(List<String> blockIds, {bool immediate = false}) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        await Supabase.instance.client
            .from('student_time_blocks')
            .delete()
            .filter('id', 'in', '(${blockIds.map((e) => '"$e"').join(',')})');
        _studentTimeBlocks.removeWhere((b) => blockIds.contains(b.id));
      } catch (e, st) {
        print('[SUPA][stb bulk delete] $e\n$st');
        rethrow;
      }
    } else {
    _studentTimeBlocks.removeWhere((b) => blockIds.contains(b.id));
    await AcademyDbService.instance.bulkDeleteStudentTimeBlocks(blockIds);
    }
    
    if (immediate || blockIds.length == 1) {
      // 단일 삭제나 즉시 반영 요청 시 바로 업데이트
      studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
    } else {
      // 다중 삭제는 debouncing으로 지연 (100ms 후 한 번에 반영)
      _uiUpdateTimer?.cancel();
      _uiUpdateTimer = Timer(const Duration(milliseconds: 100), () {
        studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
      });
    }
    if (!TagPresetService.preferSupabaseRead) {
    await loadStudentTimeBlocks();
    }
  }

  // 특정 학생의 set_id 목록에 해당하는 모든 수업 블록 삭제
  Future<void> removeStudentTimeBlocksBySetIds(String studentId, Set<String> setIds) async {
    if (setIds.isEmpty) return;
    final targets = _studentTimeBlocks.where((b) => b.studentId == studentId && b.setId != null && setIds.contains(b.setId!)).map((b) => b.id).toList();
    if (targets.isEmpty) return;
    await bulkDeleteStudentTimeBlocks(targets, immediate: true);
  }

  Future<void> updateStudentTimeBlock(String id, StudentTimeBlock newBlock) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final row = <String, dynamic>{
          'id': newBlock.id,
          'academy_id': academyId,
          'student_id': newBlock.studentId,
          'day_index': newBlock.dayIndex,
          'start_hour': newBlock.startHour,
          'start_minute': newBlock.startMinute,
          'duration': newBlock.duration.inMinutes,
          'block_created_at': newBlock.createdAt.toIso8601String(),
          'set_id': newBlock.setId,
          'number': newBlock.number,
          'session_type_id': newBlock.sessionTypeId,
          'weekly_order': newBlock.weeklyOrder,
        }..removeWhere((k, v) => v == null);
        await Supabase.instance.client.from('student_time_blocks').upsert(row, onConflict: 'id');
        final index = _studentTimeBlocks.indexWhere((b) => b.id == id);
        if (index != -1) _studentTimeBlocks[index] = newBlock; else _studentTimeBlocks.add(newBlock);
        studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
        if (newBlock.setId != null) {
          await _recalculateWeeklyOrderForStudent(newBlock.studentId);
        }
        return;
      } catch (e, st) {
        print('[SUPA][stb update] $e\n$st');
        rethrow;
      }
    }
    final index = _studentTimeBlocks.indexWhere((b) => b.id == id);
    if (index != -1) {
      _studentTimeBlocks[index] = newBlock;
      studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
      await AcademyDbService.instance.updateStudentTimeBlock(id, newBlock);
      await loadStudentTimeBlocks();
      if (newBlock.setId != null) {
        await _recalculateWeeklyOrderForStudent(newBlock.studentId);
      }
    }
  }

  // 주간 순번 재계산: 학생의 모든 set_id를 대표시간(가장 이른 요일/시간) 기준으로 정렬하여 weekly_order=1..N 부여
  Future<void> _recalculateWeeklyOrderForStudent(String studentId) async {
    // 대상 학생 블록만 수집
    final blocks = _studentTimeBlocks.where((b) => b.studentId == studentId).toList();
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
    studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
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
      );
      _studentTimeBlocks.add(block);
    }
    _notifyListeners();
    await saveStudentTimeBlocks();
  }

  Future<void> loadTeachers() async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final data = await Supabase.instance.client
            .from('teachers')
            .select('name,role,contact,email,description')
            .eq('academy_id', academyId)
            .order('name');
        _teachers = (data as List).map((t) => Teacher(
          name: t['name'] as String? ?? '',
          role: TeacherRole.values[(t['role'] as int?) ?? 0],
          contact: t['contact'] as String? ?? '',
          email: t['email'] as String? ?? '',
          description: t['description'] as String? ?? '',
        )).toList();
        _notifyListeners();
        return;
      } catch (e, st) { print('[SUPA][classes delete] $e\n$st'); }
    }
    final teacherMaps = await AcademyDbService.instance.getTeachers();
    _teachers = teacherMaps.map((t) => Teacher(
      name: t['name'],
      role: TeacherRole.values[t['role']],
      contact: t['contact'],
      email: t['email'],
      description: t['description'],
    )).toList();
    _notifyListeners();
  }

  Future<void> saveTeachers() async {
    try {
      print('[DEBUG] saveTeachers 시작: \${_teachers.length}명');
      final dbClient = await AcademyDbService.instance.db;
      print('[DEBUG] saveTeachers: \${_teachers.length}명');
      await dbClient.delete('teachers');
      for (final t in _teachers) {
        print('[DB] insert teacher: $t');
        await dbClient.insert('teachers', {
          'name': t.name,
          'role': t.role.index,
          'contact': t.contact,
          'email': t.email,
          'description': t.description,
        });
      }
      if (TagPresetService.dualWrite) {
        try {
          final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
          final supa = Supabase.instance.client;
          await supa.from('teachers').delete().eq('academy_id', academyId);
          if (_teachers.isNotEmpty) {
            final rows = _teachers.map((t) => {
              'academy_id': academyId,
              'name': t.name,
              'role': t.role.index,
              'contact': t.contact,
              'email': t.email,
              'description': t.description,
            }).toList();
            await supa.from('teachers').insert(rows);
          }
        } catch (_) {}
      }
      print('[DEBUG] saveTeachers 완료');
    } catch (e, st) {
      print('[DB][ERROR] saveTeachers: $e\n$st');
      rethrow;
    }
  }

  void addTeacher(Teacher teacher) {
    print('[DEBUG] addTeacher 호출: $teacher');
    _teachers.add(teacher);
    print('[DEBUG] saveTeachers 호출 전 teachers.length: ${_teachers.length}');
    saveTeachers();
    teachersNotifier.value = List.unmodifiable(_teachers);
    print('[DEBUG] teachersNotifier.value 갱신: ${teachersNotifier.value.length}');
  }

  void deleteTeacher(int idx) {
    if (idx >= 0 && idx < _teachers.length) {
      _teachers.removeAt(idx);
      saveTeachers();
      teachersNotifier.value = List.unmodifiable(_teachers);
    }
  }

  void updateTeacher(int idx, Teacher updated) {
    if (idx >= 0 && idx < _teachers.length) {
      _teachers[idx] = updated;
      saveTeachers();
      teachersNotifier.value = List.unmodifiable(_teachers);
    }
  }

  void setGroupsOrder(List<GroupInfo> newOrder) {
    _groups = newOrder.where((g) => g != null).toList();
    _groupsById = {for (var g in _groups) g.id: g};
    _notifyListeners();
    saveGroups();
  }

  void setTeachersOrder(List<Teacher> newOrder) {
    _teachers = List<Teacher>.from(newOrder);
    teachersNotifier.value = List.unmodifiable(_teachers);
    saveTeachers();
  }

  /// 학생별 수업블록(setId 기준) 개수 반환
  int getStudentLessonSetCount(String studentId) {
    final blocks = _studentTimeBlocks.where((b) => b.studentId == studentId && b.setId != null).toList();
    final setCount = blocks.map((b) => b.setId).toSet().length;
    print('[DEBUG][DataManager] getStudentLessonSetCount($studentId) = $setCount');
    return setCount;
  }

  /// 수업 등록 가능 학생 리스트 반환 (수업이 등록되지 않은 학생들)
  List<StudentWithInfo> getLessonEligibleStudents() {
    // 기존 함수는 더 이상 사용하지 않음. 주석 유지하되, 추천 로직을 사용하도록 변경
    return getRecommendedStudentsForWeeklyClassCount();
  }

  int getStudentWeeklyClassCount(String studentId) {
    final info = getStudentPaymentInfo(studentId);
    return info?.weeklyClassCount ?? 1;
  }

  // 추천 학생: weekly_class_count 대비 현재 set_id 개수가 미만인 학생 목록
  List<StudentWithInfo> getRecommendedStudentsForWeeklyClassCount() {
    final result = students.where((s) {
      final setCount = getStudentLessonSetCount(s.student.id);
      final weekly = getStudentWeeklyClassCount(s.student.id);
      return setCount < weekly;
    }).toList();
    // 차이(remaining) 큰 순 또는 이름순 정렬 등 정책 선택 가능; 여기서는 remaining 내림차순→이름
    result.sort((a, b) {
      final ra = getStudentWeeklyClassCount(a.student.id) - getStudentLessonSetCount(a.student.id);
      final rb = getStudentWeeklyClassCount(b.student.id) - getStudentLessonSetCount(b.student.id);
      if (rb != ra) return rb.compareTo(ra);
      return a.student.name.compareTo(b.student.name);
    });
    return result;
  }

  /// 자습 등록 가능 학생 리스트 반환 (weeklyClassCount - setId 개수 <= 0)
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
  int getStudentCountForClass(String classId) {
    // print('[DEBUG][getStudentCountForClass] 전체 studentTimeBlocks.length=${_studentTimeBlocks.length}');
    final blocks = _studentTimeBlocks.where((b) => b.sessionTypeId == classId).toList();
    //print('[DEBUG][getStudentCountForClass] classId=$classId, blocks=' + blocks.map((b) => '${b.studentId}:${b.setId}:${b.number}').toList().toString());
    final studentIds = blocks.map((b) => b.studentId).toSet();
    //print('[DEBUG][getStudentCountForClass] studentIds=$studentIds');
    return studentIds.length;
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

  Future<void> loadClasses() async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
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
        // Fallback/backfill: dualWrite가 켜진 경우에만 로컬을 참고
        if (_classes.isEmpty && TagPresetService.dualWrite) {
          final local = await AcademyDbService.instance.getClasses();
          if (local.isNotEmpty) {
            _classes = local;
            if (TagPresetService.dualWrite) {
              try {
                final rows = _classes.map((c) => {
                  'id': c.id,
                  'academy_id': academyId,
                  'name': c.name,
                  'capacity': c.capacity,
                  'description': c.description,
                  'color': c.color?.value.toSigned(32),
                }).toList();
                if (rows.isNotEmpty) {
                  await Supabase.instance.client.from('classes').insert(rows);
                }
              } catch (_) {}
            }
          }
        }
        classesNotifier.value = List.unmodifiable(_classes);
        return;
      } catch (e, st) { print('[SUPA][classes reorder insert] $e\n$st'); }
    }
    _classes = await AcademyDbService.instance.getClasses();
    classesNotifier.value = List.unmodifiable(_classes);
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
        return;
      } catch (e, st) {
        print('[SUPA][classes upsert(add)] $e\n$st');
        return; // server-only: 실패 시 로컬 저장하지 않음
      }
    }
    _classes.add(c);
    await AcademyDbService.instance.addClass(c);
    classesNotifier.value = List.unmodifiable(_classes);
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
  }
  Future<void> deleteClass(String id) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        await Supabase.instance.client.from('classes').delete().eq('id', id);
        _classes.removeWhere((c) => c.id == id);
        classesNotifier.value = List.unmodifiable(_classes);
        return;
      } catch (e, st) {
        print('[SUPA][classes delete] $e\n$st');
        return; // server-only: 실패 시 로컬 삭제하지 않음
      }
    }
    _classes.removeWhere((c) => c.id == id);
    await AcademyDbService.instance.deleteClass(id);
    classesNotifier.value = List.unmodifiable(_classes);
  }

  Future<void> saveClassesOrder(List<ClassInfo> newOrder) async {
    print('[DEBUG][DataManager.saveClassesOrder] 시작: ${newOrder.map((c) => c.name).toList()}');
    _classes = List<ClassInfo>.from(newOrder);
    print('[DEBUG][DataManager.saveClassesOrder] _classes 업데이트: ${_classes.map((c) => c.name).toList()}');
    
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        await supa.from('classes').delete().eq('academy_id', academyId);
        if (_classes.isNotEmpty) {
          final rows = _classes.map((c) => {
            'id': c.id,
            'academy_id': academyId,
            'name': c.name,
            'capacity': c.capacity,
            'description': c.description,
            'color': c.color?.value.toSigned(32),
          }).toList();
          await supa.from('classes').insert(rows);
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
    
    classesNotifier.value = List.unmodifiable(_classes);
    print('[DEBUG][DataManager.saveClassesOrder] classesNotifier 업데이트 완료');
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
  
  Future<void> forceMigration() async {
    try {
      print('[DEBUG] 강제 마이그레이션 시작...');
      await AcademyDbService.instance.ensureAttendanceRecordsTable();
      await loadAttendanceRecords();
      print('[DEBUG] 강제 마이그레이션 완료');
    } catch (e) {
      print('[ERROR] 강제 마이그레이션 실패: $e');
    }
  }
  
  Future<void> loadAttendanceRecords() async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final rows = await supa
          .from('attendance_records')
          .select('id,student_id,class_date_time,class_end_time,class_name,is_present,arrival_time,departure_time,notes,created_at,updated_at,version')
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

  Future<void> _subscribeAttendanceRealtime() async {
    try {
      _attendanceRealtimeChannel?.unsubscribe();
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      final chan = Supabase.instance.client.channel('public:attendance_records:$academyId');
      _attendanceRealtimeChannel = chan
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'attendance_records',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
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
                isPresent: (m['is_present'] is bool) ? m['is_present'] as bool : ((m['is_present'] is num) ? (m['is_present'] as num) == 1 : false),
                arrivalTime: (m['arrival_time'] != null) ? DateTime.parse(m['arrival_time'] as String).toLocal() : null,
                departureTime: (m['departure_time'] != null) ? DateTime.parse(m['departure_time'] as String).toLocal() : null,
                notes: m['notes'] as String?,
                createdAt: DateTime.parse(m['created_at'] as String).toLocal(),
                updatedAt: DateTime.parse(m['updated_at'] as String).toLocal(),
                version: (m['version'] is num) ? (m['version'] as num).toInt() : 1,
              );
              // 중복 체크 후 추가
              final exists = _attendanceRecords.any((r) => r.id == rec.id);
              if (!exists) {
                _attendanceRecords.add(rec);
                attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
              }
            } catch (_) {}
          },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'attendance_records',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
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
                className: (m['class_name'] as String?) ?? _attendanceRecords[idx].className,
                isPresent: (m['is_present'] is bool) ? m['is_present'] as bool : ((m['is_present'] is num) ? (m['is_present'] as num) == 1 : _attendanceRecords[idx].isPresent),
                arrivalTime: (m['arrival_time'] != null) ? DateTime.parse(m['arrival_time'] as String).toLocal() : null,
                departureTime: (m['departure_time'] != null) ? DateTime.parse(m['departure_time'] as String).toLocal() : null,
                notes: m['notes'] as String?,
                updatedAt: DateTime.parse(m['updated_at'] as String).toLocal(),
                version: (m['version'] is num) ? (m['version'] as num).toInt() : _attendanceRecords[idx].version,
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
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
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
    } catch (e) {
      // ignore
    }
  }

  Future<void> addAttendanceRecord(AttendanceRecord record) async {
    final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
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
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'updated_at': record.updatedAt.toUtc().toIso8601String(),
      'version': record.version,
    };
    final inserted = await supa.from('attendance_records').insert(row).select('id,version').maybeSingle();
    if (inserted != null) {
      final withId = record.copyWith(id: (inserted['id'] as String?), version: (inserted['version'] as num?)?.toInt() ?? 1);
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
        'updated_at': record.updatedAt.toUtc().toIso8601String(),
        // version은 트리거에서 +1 증가
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
        final newVersion = (updated['version'] as num?)?.toInt() ?? (record.version + 1);
        _attendanceRecords[index] = record.copyWith(version: newVersion);
        attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      }
      return;
    }

    // id가 없으면 동일 키(학생, 시간)로 업데이트 시도 후 없으면 추가
    final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
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
      // 원격에서 최신 버전 조회 후 버전 싱크
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
    try {
      return _attendanceRecords.firstWhere(
        (r) => r.studentId == studentId && 
               r.classDateTime.year == classDateTime.year &&
               r.classDateTime.month == classDateTime.month &&
               r.classDateTime.day == classDateTime.day &&
               r.classDateTime.hour == classDateTime.hour &&
               r.classDateTime.minute == classDateTime.minute,
      );
    } catch (e) {
      return null;
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
  }) async {
    print('[SUPA] saveOrUpdateAttendance 시작 - 학생ID: $studentId');
    final now = DateTime.now();
    final existing = getAttendanceRecord(studentId, classDateTime);
    if (existing != null) {
      final updated = existing.copyWith(
        classEndTime: classEndTime,
        className: className,
        isPresent: isPresent,
        arrivalTime: arrivalTime,
        departureTime: departureTime,
        notes: notes,
        updatedAt: now,
      );
      try {
        await updateAttendanceRecord(updated);
      } on StateError catch (e) {
        if (e.message == 'CONFLICT_ATTENDANCE_VERSION') {
          // 최신 데이터 재로딩 후 충돌 알림
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

  // replacementClassDateTime와 동일한 planned override(add/replace)를 completed로 전환
  Future<void> _completePlannedOverrideFor({
    required String studentId,
    required DateTime replacementDateTime,
    required String replacementAttendanceId,
  }) async {
    bool sameMinute(DateTime a, DateTime b) {
      return a.year == b.year && a.month == b.month && a.day == b.day && a.hour == b.hour && a.minute == b.minute;
    }

    SessionOverride? target;
    for (final o in _sessionOverrides) {
      if (o.studentId != studentId) continue;
      if (o.status != OverrideStatus.planned) continue;
      if (!(o.overrideType == OverrideType.add || o.overrideType == OverrideType.replace)) continue;
      if (o.replacementClassDateTime == null) continue;
      if (sameMinute(o.replacementClassDateTime!, replacementDateTime)) {
        target = o;
        break;
      }
    }

    if (target == null) {
      print('[DEBUG] matching planned override 없음: studentId=$studentId, time=$replacementDateTime');
      return;
    }

    final updated = target.copyWith(
      status: OverrideStatus.completed,
      replacementAttendanceId: replacementAttendanceId,
      updatedAt: DateTime.now(),
    );
    try {
      await updateSessionOverride(updated);
    } catch (_) {}

    final idx = _sessionOverrides.indexWhere((o) => o.id == updated.id);
    if (idx != -1) {
      _sessionOverrides[idx] = updated;
    } else {
      _sessionOverrides.add(updated);
    }
    sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);
    print('[DEBUG] planned→completed 링크 완료: overrideId=${updated.id}');
  }

  // 과거 수업 정리 로직 (등원시간만 있고 하원시간이 없는 경우 정상 출석 처리)
  Future<void> processPastClassesAttendance() async {
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    final yesterdayEndOfDay = DateTime(yesterday.year, yesterday.month, yesterday.day, 23, 59, 59);

    final recordsToUpdate = <AttendanceRecord>[];
    final recordsToCreate = <AttendanceRecord>[];

    // 모든 학생의 수업 시간 블록을 확인
    for (final student in _studentsWithInfo) {
      final studentId = student.student.id;
      // 백필 시작일: 학생 등록일(자정) 기준, 없으면 안전 기본값(30일 전)
      final DateTime todayStart = DateTime(now.year, now.month, now.day);
      final DateTime registrationStart = student.basicInfo.registrationDate != null
          ? DateTime(
              student.basicInfo.registrationDate!.year,
              student.basicInfo.registrationDate!.month,
              student.basicInfo.registrationDate!.day,
            )
          : todayStart.subtract(const Duration(days: 30));
      final DateTime registrationDate = registrationStart;

      // 해당 학생의 time blocks 가져오기
      final timeBlocks = studentTimeBlocks
          .where((block) => block.studentId == studentId)
          .toList();
      
      if (timeBlocks.isEmpty) continue;

      // SET_ID별로 timeBlocks 그룹화
      final Map<String?, List<StudentTimeBlock>> blocksBySetId = {};
      for (final block in timeBlocks) {
        blocksBySetId.putIfAbsent(block.setId, () => []).add(block);
      }

      // 등록일부터 어제까지의 모든 수업 일정 생성 (오늘 수업은 제외)
      for (DateTime date = registrationDate; date.isBefore(yesterdayEndOfDay); date = date.add(const Duration(days: 1))) {
        for (final entry in blocksBySetId.entries) {
          final blocks = entry.value;
          if (blocks.isEmpty) continue;
          
          final firstBlock = blocks.first;
          
          // 해당 날짜가 수업 요일인지 확인
          if (date.weekday - 1 != firstBlock.dayIndex) continue;
          
          final classDateTime = DateTime(
            date.year,
            date.month,
            date.day,
            firstBlock.startHour,
            firstBlock.startMinute,
          );
          
          final classEndTime = classDateTime.add(firstBlock.duration);

          // 기존 출석 기록 확인
          final existingRecord = getAttendanceRecord(studentId, classDateTime);
          
          if (existingRecord != null) {
            // 등원시간만 있고 하원시간이 없는 경우 정상 출석으로 처리
            if (existingRecord.arrivalTime != null && existingRecord.departureTime == null) {
              final updated = existingRecord.copyWith(
                isPresent: true,
                arrivalTime: existingRecord.arrivalTime, // 실제 등원시간 유지
                departureTime: classEndTime, // 수업 종료 시간으로 설정
              );
              recordsToUpdate.add(updated);
            }
          } else {
            // 출석 기록이 없는 경우 무단결석으로 기록
            String className = '수업';
            try {
              final classInfo = classes.firstWhere((c) => c.id == firstBlock.sessionTypeId);
              className = classInfo.name;
            } catch (e) {
              // 클래스 정보를 찾지 못한 경우 기본값 사용
            }

            final newRecord = AttendanceRecord.create(
              studentId: studentId,
              classDateTime: classDateTime,
              classEndTime: classEndTime,
              className: className,
              isPresent: false, // 무단결석
              arrivalTime: null,
              departureTime: null,
            );
            recordsToCreate.add(newRecord);
          }
        }
      }
    }

    // 업데이트 실행
    for (final record in recordsToUpdate) {
      await updateAttendanceRecord(record);
    }

    // 생성 실행
    for (final record in recordsToCreate) {
      await addAttendanceRecord(record);
    }

    print('[DEBUG] 과거 수업 정리 완료: ${recordsToUpdate.length}개 업데이트, ${recordsToCreate.length}개 생성');
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
              .select('id,student_id,registration_date,payment_method,weekly_class_count,tuition_fee,lateness_threshold,'
                      'schedule_notification,attendance_notification,departure_notification,lateness_notification,'
                      'created_at,updated_at')
              .eq('academy_id', academyId);
          _studentPaymentInfos = (rows as List).map((m) => StudentPaymentInfo(
            id: (m['id'] as String?),
            studentId: (m['student_id'] as String),
            registrationDate: DateTime.tryParse((m['registration_date'] as String?) ?? '') ?? DateTime.now(),
            paymentMethod: (m['payment_method'] as String?) ?? 'monthly',
            weeklyClassCount: (m['weekly_class_count'] as int?) ?? 1,
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
            'weekly_class_count': paymentInfo.weeklyClassCount,
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
            'weekly_class_count': paymentInfo.weeklyClassCount,
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
            'weekly_class_count': updatedPaymentInfo.weeklyClassCount,
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

  // 주간 수업 횟수 설정(증가/감소 모두 포함)
  Future<void> setStudentWeeklyClassCount(String studentId, int newWeeklyCount) async {
    // 기존 PaymentInfo 조회
    final existing = getStudentPaymentInfo(studentId);
    final now = DateTime.now();
    if (existing != null) {
      final updated = existing.copyWith(weeklyClassCount: newWeeklyCount, updatedAt: now);
      await updateStudentPaymentInfo(updated);
    } else {
      // 존재하지 않으면 기본값으로 새로 생성
      final info = StudentPaymentInfo(
        id: const Uuid().v4(),
        studentId: studentId,
        registrationDate: now,
        paymentMethod: 'monthly',
        weeklyClassCount: newWeeklyCount,
        tuitionFee: 0,
        createdAt: now,
        updatedAt: now,
      );
      await addStudentPaymentInfo(info);
    }
    await loadStudentPaymentInfos();
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
  Future<void> saveResourceFolders(List<Map<String, dynamic>> rows) async {
    await AcademyDbService.instance.saveResourceFolders(rows);
    if (TagPresetService.dualWrite) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        await supa.from('resource_folders').delete().eq('academy_id', academyId);
        if (rows.isNotEmpty) {
          final up = rows.map((r) => {
            'id': r['id'],
            'academy_id': academyId,
            'name': r['name'],
            'parent_id': r['parent_id'],
            'order_index': r['order_index'],
            'category': r['category'],
          }).toList();
          await supa.from('resource_folders').insert(up);
        }
      } catch (_) {}
    }
  }

  Future<void> saveResourceFoldersForCategory(String category, List<Map<String, dynamic>> rows) async {
    await AcademyDbService.instance.saveResourceFoldersForCategory(category, rows);
    if (TagPresetService.dualWrite) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        await supa.from('resource_folders').delete().match({'academy_id': academyId, 'category': category});
        if (rows.isNotEmpty) {
          final up = rows.map((raw) {
            final r = Map<String, dynamic>.from(raw);
            return {
              'id': r['id'],
              'academy_id': academyId,
              'name': r['name'],
              'parent_id': r['parent_id'],
              'order_index': r['order_index'],
              'category': category,
            };
          }).toList();
          await supa.from('resource_folders').insert(up);
        }
      } catch (_) {}
    }
  }

  Future<List<Map<String, dynamic>>> loadResourceFolders() async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final data = await supa.from('resource_folders').select('id,name,parent_id,order_index,category').eq('academy_id', academyId).order('order_index');
        return (data as List).cast<Map<String, dynamic>>();
      } catch (_) {}
    }
    return await AcademyDbService.instance.loadResourceFolders();
  }

  Future<List<Map<String, dynamic>>> loadResourceFoldersForCategory(String category) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final data = await supa.from('resource_folders').select('id,name,parent_id,order_index,category').match({'academy_id': academyId, 'category': category}).order('order_index');
        return (data as List).cast<Map<String, dynamic>>();
      } catch (_) {}
    }
    return await AcademyDbService.instance.loadResourceFoldersForCategory(category);
  }

  Future<void> saveResourceFile(Map<String, dynamic> row) async {
    await AcademyDbService.instance.saveResourceFile(row);
    if (TagPresetService.dualWrite) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final up = {
          'id': row['id'],
          'academy_id': academyId,
          'folder_id': row['parent_id'],
          'name': row['name'],
          'url': row['url'],
          'category': row['category'],
          'order_index': row['order_index'],
        };
        await supa.from('resource_files').upsert(up, onConflict: 'id');
      } catch (_) {}
    }
  }

  Future<void> saveResourceFileWithCategory(Map<String, dynamic> row, String category) async {
    final copy = Map<String, dynamic>.from(row);
    copy['category'] = category;
    await saveResourceFile(copy);
  }

  Future<List<Map<String, dynamic>>> loadResourceFiles() async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final data = await supa.from('resource_files').select('id,folder_id as parent_id,name,url,category,order_index').eq('academy_id', academyId).order('order_index');
        return (data as List).cast<Map<String, dynamic>>();
      } catch (_) {}
    }
    return await AcademyDbService.instance.loadResourceFiles();
  }

  Future<List<Map<String, dynamic>>> loadResourceFilesForCategory(String category) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final data = await supa.from('resource_files').select('id,folder_id as parent_id,name,url,category,order_index').match({'academy_id': academyId, 'category': category}).order('order_index');
        return (data as List).cast<Map<String, dynamic>>();
      } catch (_) {}
    }
    return await AcademyDbService.instance.loadResourceFilesForCategory(category);
  }

  Future<void> saveResourceFileLinks(String fileId, Map<String, String> links) async {
    await AcademyDbService.instance.saveResourceFileLinks(fileId, links);
    // 링크 테이블은 Supabase에 아직 스키마가 없으므로 로컬 유지(필요 시 확장)
  }

  Future<Map<String, String>> loadResourceFileLinks(String fileId) async {
    // 링크 테이블은 현 단계 로컬 우선
    return await AcademyDbService.instance.loadResourceFileLinks(fileId);
  }

  Future<void> deleteResourceFile(String fileId) async {
    await AcademyDbService.instance.deleteResourceFileLinksByFileId(fileId);
    await AcademyDbService.instance.deleteResourceFile(fileId);
    if (TagPresetService.dualWrite) {
      try {
        final supa = Supabase.instance.client;
        await supa.from('resource_files').delete().eq('id', fileId);
      } catch (_) {}
    }
  }

  // ======== RESOURCE FAVORITES ========
  Future<Set<String>> loadResourceFavorites() async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final userId = Supabase.instance.client.auth.currentUser?.id;
        if (userId != null) {
          final data = await Supabase.instance.client
              .from('resource_favorites')
              .select('file_id')
              .match({'academy_id': academyId, 'user_id': userId});
          final set = (data as List).map((r) => (r['file_id'] as String)).toSet();
          return set;
        }
      } catch (_) {}
    }
    final dbClient = await AcademyDbService.instance.db;
    await AcademyDbService.instance.ensureResourceTables();
    final rows = await dbClient.query('resource_favorites');
    return rows.map((r) => (r['file_id'] as String)).toSet();
  }

  Future<void> addResourceFavorite(String fileId) async {
    final dbClient = await AcademyDbService.instance.db;
    await AcademyDbService.instance.ensureResourceTables();
    await dbClient.insert('resource_favorites', {'file_id': fileId}, conflictAlgorithm: ConflictAlgorithm.replace);
    if (TagPresetService.dualWrite) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final userId = Supabase.instance.client.auth.currentUser?.id;
        if (userId != null) {
          await Supabase.instance.client.from('resource_favorites').upsert({
            'academy_id': academyId,
            'file_id': fileId,
            'user_id': userId,
          });
        }
      } catch (_) {}
    }
  }

  Future<void> removeResourceFavorite(String fileId) async {
    final dbClient = await AcademyDbService.instance.db;
    await AcademyDbService.instance.ensureResourceTables();
    await dbClient.delete('resource_favorites', where: 'file_id = ?', whereArgs: [fileId]);
    if (TagPresetService.dualWrite) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final userId = Supabase.instance.client.auth.currentUser?.id;
        if (userId != null) {
          await Supabase.instance.client.from('resource_favorites').delete().match({
            'academy_id': academyId,
            'file_id': fileId,
            'user_id': userId,
          });
        }
      } catch (_) {}
    }
  }

  // ======== RESOURCE FILE BOOKMARKS ========
  Future<List<Map<String, dynamic>>> loadResourceFileBookmarks(String fileId) async {
    final dbClient = await AcademyDbService.instance.db;
    await AcademyDbService.instance.ensureResourceTables();
    return await dbClient.query('resource_file_bookmarks', where: 'file_id = ?', whereArgs: [fileId], orderBy: 'order_index ASC');
  }

  Future<void> saveResourceFileBookmarks(String fileId, List<Map<String, dynamic>> items) async {
    final dbClient = await AcademyDbService.instance.db;
    await AcademyDbService.instance.ensureResourceTables();
    await dbClient.transaction((txn) async {
      await txn.delete('resource_file_bookmarks', where: 'file_id = ?', whereArgs: [fileId]);
      for (int i = 0; i < items.length; i++) {
        final it = Map<String, dynamic>.from(items[i]);
        it['file_id'] = fileId;
        it['order_index'] = i;
        await txn.insert('resource_file_bookmarks', it);
      }
    });
  }

  // ======== RESOURCE GRADES (학년 목록/순서) ========
  Future<List<Map<String, dynamic>>> getResourceGrades() async {
    return await AcademyDbService.instance.getResourceGrades();
  }

  Future<void> saveResourceGrades(List<String> names) async {
    await AcademyDbService.instance.saveResourceGrades(names);
  }

  // ======== RESOURCE GRADE ICONS ========
  Future<Map<String, int>> getResourceGradeIcons() async {
    return await AcademyDbService.instance.getResourceGradeIcons();
  }

  Future<void> setResourceGradeIcon(String name, int icon) async {
    await AcademyDbService.instance.setResourceGradeIcon(name, icon);
  }

  Future<void> deleteResourceGradeIcon(String name) async {
    await AcademyDbService.instance.deleteResourceGradeIcon(name);
  }

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