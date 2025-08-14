import 'dart:async';
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
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../models/memo.dart';

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

  final ValueNotifier<List<GroupInfo>> groupsNotifier = ValueNotifier<List<GroupInfo>>([]);
  final ValueNotifier<List<StudentWithInfo>> studentsNotifier = ValueNotifier<List<StudentWithInfo>>([]);
  final ValueNotifier<List<PaymentRecord>> paymentRecordsNotifier = ValueNotifier<List<PaymentRecord>>([]);
  final ValueNotifier<List<AttendanceRecord>> attendanceRecordsNotifier = ValueNotifier<List<AttendanceRecord>>([]);
  final ValueNotifier<List<StudentPaymentInfo>> studentPaymentInfosNotifier = ValueNotifier<List<StudentPaymentInfo>>([]);
  
  // Session Overrides (보강/예외)
  List<SessionOverride> _sessionOverrides = [];
  final ValueNotifier<List<SessionOverride>> sessionOverridesNotifier = ValueNotifier<List<SessionOverride>>([]);

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
      await loadSelfStudyTimeBlocks(); // 자습 블록도 반드시 불러오기
      await loadGroupSchedules();
      await loadTeachers();
      await loadClasses(); // 수업 정보 로딩 추가
      await loadPaymentRecords(); // 수강료 납부 기록 로딩 추가
      await loadAttendanceRecords(); // 출석 기록 로딩 추가
      await loadMemos();
      _isInitialized = true;
    } catch (e) {
      print('Error initializing data: $e');
      _initializeDefaults();
    }
  }

  // ======== MEMOS ========
  List<Memo> _memos = [];
  final ValueNotifier<List<Memo>> memosNotifier = ValueNotifier<List<Memo>>([]);

  Future<void> loadMemos() async {
    final rows = await AcademyDbService.instance.getMemos();
    _memos = rows.map((m) => Memo.fromMap(m)).toList();
    memosNotifier.value = List.unmodifiable(_memos);
  }

  Future<void> addMemo(Memo memo) async {
    _memos.insert(0, memo);
    memosNotifier.value = List.unmodifiable(_memos);
    await AcademyDbService.instance.addMemo(memo.toMap());
  }

  Future<void> updateMemo(Memo memo) async {
    final idx = _memos.indexWhere((m) => m.id == memo.id);
    if (idx != -1) {
      _memos[idx] = memo;
      memosNotifier.value = List.unmodifiable(_memos);
      await AcademyDbService.instance.updateMemo(memo.id, memo.toMap());
    }
  }

  Future<void> deleteMemo(String id) async {
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
      _groups = (await AcademyDbService.instance.getGroups()).where((g) => g != null).toList();
      _groupsById = {for (var g in _groups) g.id: g};
    } catch (e) {
      print('Error loading groups: $e');
      _groups = [];
      _groupsById = {};
    }
    _notifyListeners();
  }

  Future<void> loadStudents() async {
    print('[DEBUG][loadStudents] 진입');
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
      await AcademyDbService.instance.saveGroups(_groups);
    } catch (e) {
      print('Error saving groups: $e');
      throw Exception('Failed to save groups data');
    }
  }

  Future<void> loadAcademySettings() async {
    try {
      final dbData = await AcademyDbService.instance.getAcademySettings();
      if (dbData != null) {
        print('[DataManager] loadAcademySettings: logo type=\x1B[33m${dbData['logo']?.runtimeType}\x1B[0m, length=\x1B[33m${(dbData['logo'] as Uint8List?)?.length}\x1B[0m, isNull=\x1B[33m${dbData['logo'] == null}\x1B[0m');
        _academySettings = AcademySettings(
          name: dbData['name'] as String? ?? '',
          slogan: dbData['slogan'] as String? ?? '',
          defaultCapacity: dbData['default_capacity'] as int? ?? 30,
          lessonDuration: dbData['lesson_duration'] as int? ?? 50,
          logo: dbData['logo'] is Uint8List
              ? dbData['logo'] as Uint8List
              : dbData['logo'] is List<int>
                  ? Uint8List.fromList(List<int>.from(dbData['logo']))
                  : null,
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
      final maps = await AcademyDbService.instance.getSessionOverridesAll();
      _sessionOverrides = maps.map((m) => SessionOverride.fromMap(m)).toList();
      sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);
      print('[DEBUG] session_overrides 로드 완료: ${_sessionOverrides.length}개');
    } catch (e) {
      print('[ERROR] loadSessionOverrides 실패: $e');
      _sessionOverrides = [];
      sessionOverridesNotifier.value = [];
    }
  }

  Future<void> addSessionOverride(SessionOverride overrideData) async {
    try {
      await AcademyDbService.instance.addSessionOverride(overrideData.toMap());
      _sessionOverrides.removeWhere((o) => o.id == overrideData.id);
      _sessionOverrides.add(overrideData);
      sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);
      print('[DEBUG] session_override 추가: id=${overrideData.id}, type=${overrideData.overrideType}, status=${overrideData.status}');
    } catch (e) {
      print('[ERROR] addSessionOverride 실패: $e');
      rethrow;
    }
  }

  Future<void> updateSessionOverride(SessionOverride newData) async {
    try {
      // 저장 전 검증: 운영시간 및 충돌 방지
      _validateOverride(newData);
      await AcademyDbService.instance.updateSessionOverride(newData.id, newData.toMap());
      final idx = _sessionOverrides.indexWhere((o) => o.id == newData.id);
      if (idx != -1) {
        _sessionOverrides[idx] = newData;
      } else {
        _sessionOverrides.add(newData);
      }
      sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);
      print('[DEBUG] session_override 업데이트: id=${newData.id}, status=${newData.status}');
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
      final canceled = _sessionOverrides[idx].copyWith(status: OverrideStatus.canceled);
      await AcademyDbService.instance.updateSessionOverride(id, canceled.toMap());
      _sessionOverrides[idx] = canceled;
      sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);
      print('[DEBUG] session_override 취소: id=$id');
    } catch (e) {
      print('[ERROR] cancelSessionOverride 실패: $e');
      rethrow;
    }
  }

  Future<void> deleteSessionOverride(String id) async {
    try {
      await AcademyDbService.instance.deleteSessionOverride(id);
      _sessionOverrides.removeWhere((o) => o.id == id);
      sessionOverridesNotifier.value = List.unmodifiable(_sessionOverrides);
      print('[DEBUG] session_override 삭제: id=$id');
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
    await AcademyDbService.instance.addStudent(student);
    await AcademyDbService.instance.insertStudentBasicInfo(basicInfo.toDb());
    print('[DEBUG][addStudent] DB 저장 완료');
    await loadStudents();
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
    await AcademyDbService.instance.updateStudent(student);
    await AcademyDbService.instance.updateStudentBasicInfo(student.id, basicInfo.toDb());
    print('[DEBUG][updateStudent] DB 저장 완료');
    await loadStudents();
  }

  Future<void> deleteStudent(String id) async {
    print('[DEBUG][deleteStudent] 진입: id=$id');
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
  }

  // StudentBasicInfo만 업데이트하는 메소드
  Future<void> updateStudentBasicInfo(String studentId, StudentBasicInfo basicInfo) async {
    print('[DEBUG][updateStudentBasicInfo] studentId: $studentId');
    print('[DEBUG][updateStudentBasicInfo] basicInfo: ${basicInfo.toString()}');
    
    try {
      // DB에 basicInfo 저장
      await AcademyDbService.instance.updateStudentBasicInfo(studentId, basicInfo.toDb());
      print('[DEBUG][updateStudentBasicInfo] DB 저장 완료');
      
      // 메모리 상태 최신화
      await loadStudents();
      print('[DEBUG][updateStudentBasicInfo] 메모리 상태 최신화 완료');
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
      final raw = await AcademyDbService.instance.getOperatingHours();
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
    final rawBlocks = await AcademyDbService.instance.getStudentTimeBlocks();
    for (final block in rawBlocks) {
      // print('[DEBUG][loadStudentTimeBlocks] block: $block');
      // print('[DEBUG][loadStudentTimeBlocks] setId: ${block.setId}, number: ${block.number}');
    }
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
    _studentTimeBlocks.add(block);
    studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
    await AcademyDbService.instance.addStudentTimeBlock(block);
    // 새 set_id 생성 시 주간 순번 재계산
    if (block.setId != null) {
      await _recalculateWeeklyOrderForStudent(block.studentId);
    }
  }

  Future<void> removeStudentTimeBlock(String id) async {
    _studentTimeBlocks.removeWhere((b) => b.id == id);
    studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
    await AcademyDbService.instance.deleteStudentTimeBlock(id);
    await loadStudentTimeBlocks(); // DB 삭제 후 메모리/상태 최신화
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
    
    // 백엔드 처리는 즉시 실행
    _studentTimeBlocks.addAll(blocks);
    await AcademyDbService.instance.bulkAddStudentTimeBlocks(blocks);
    
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
    _studentTimeBlocks.removeWhere((b) => blockIds.contains(b.id));
    await AcademyDbService.instance.bulkDeleteStudentTimeBlocks(blockIds);
    
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
    await loadStudentTimeBlocks();
  }

  // 특정 학생의 set_id 목록에 해당하는 모든 수업 블록 삭제
  Future<void> removeStudentTimeBlocksBySetIds(String studentId, Set<String> setIds) async {
    if (setIds.isEmpty) return;
    final targets = _studentTimeBlocks.where((b) => b.studentId == studentId && b.setId != null && setIds.contains(b.setId!)).map((b) => b.id).toList();
    if (targets.isEmpty) return;
    await bulkDeleteStudentTimeBlocks(targets, immediate: true);
  }

  Future<void> updateStudentTimeBlock(String id, StudentTimeBlock newBlock) async {
    final index = _studentTimeBlocks.indexWhere((b) => b.id == id);
    if (index != -1) {
      _studentTimeBlocks[index] = newBlock;
      studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
      await AcademyDbService.instance.updateStudentTimeBlock(id, newBlock);
      await loadStudentTimeBlocks(); // DB 업데이트 후 메모리/상태 최신화
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
      print('[DEBUG] saveTeachers 시작: \\${_teachers.length}명');
      final dbClient = await AcademyDbService.instance.db;
      print('[DEBUG] saveTeachers: \\${_teachers.length}명');
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
      print('[DEBUG] saveTeachers 완료');
    } catch (e, st) {
      print('[DB][ERROR] saveTeachers: $e\\n$st');
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
    _classes = await AcademyDbService.instance.getClasses();
    classesNotifier.value = List.unmodifiable(_classes);
  }
  Future<void> saveClasses() async {
    for (final c in _classes) {
      await AcademyDbService.instance.addClass(c);
    }
    classesNotifier.value = List.unmodifiable(_classes);
  }
  Future<void> addClass(ClassInfo c) async {
    _classes.add(c);
    await AcademyDbService.instance.addClass(c);
    classesNotifier.value = List.unmodifiable(_classes);
  }
  Future<void> updateClass(ClassInfo c) async {
    final idx = _classes.indexWhere((e) => e.id == c.id);
    if (idx != -1) _classes[idx] = c;
    await AcademyDbService.instance.updateClass(c);
    classesNotifier.value = List.unmodifiable(_classes);
  }
  Future<void> deleteClass(String id) async {
    _classes.removeWhere((c) => c.id == id);
    await AcademyDbService.instance.deleteClass(id);
    classesNotifier.value = List.unmodifiable(_classes);
  }

  Future<void> saveClassesOrder(List<ClassInfo> newOrder) async {
    print('[DEBUG][DataManager.saveClassesOrder] 시작: ${newOrder.map((c) => c.name).toList()}');
    _classes = List<ClassInfo>.from(newOrder);
    print('[DEBUG][DataManager.saveClassesOrder] _classes 업데이트: ${_classes.map((c) => c.name).toList()}');
    
    await AcademyDbService.instance.deleteAllClasses();
    print('[DEBUG][DataManager.saveClassesOrder] deleteAllClasses 완료');
    
    for (final c in _classes) {
      await AcademyDbService.instance.addClass(c);
    }
    print('[DEBUG][DataManager.saveClassesOrder] 모든 클래스 재저장 완료');
    
    classesNotifier.value = List.unmodifiable(_classes);
    print('[DEBUG][DataManager.saveClassesOrder] classesNotifier 업데이트 완료');
  }

  // Payment Records 관련 메소드들
  Future<void> loadPaymentRecords() async {
    _paymentRecords = await AcademyDbService.instance.getPaymentRecords();
    paymentRecordsNotifier.value = List.unmodifiable(_paymentRecords);
  }

  Future<void> addPaymentRecord(PaymentRecord record) async {
    final newRecord = await AcademyDbService.instance.addPaymentRecord(record);
    _paymentRecords.add(newRecord);
    paymentRecordsNotifier.value = List.unmodifiable(_paymentRecords);
  }

  Future<void> updatePaymentRecord(PaymentRecord record) async {
    final index = _paymentRecords.indexWhere((r) => r.id == record.id);
    if (index != -1) {
      _paymentRecords[index] = record;
      await AcademyDbService.instance.updatePaymentRecord(record);
      paymentRecordsNotifier.value = List.unmodifiable(_paymentRecords);
    }
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
      await AcademyDbService.instance.ensureAttendanceRecordsTable();
      final recordMaps = await AcademyDbService.instance.getAttendanceRecords();
      _attendanceRecords = recordMaps.map((map) => AttendanceRecord.fromMap(map)).toList();
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
      print('[DEBUG] 출석 기록 로드 완료: ${_attendanceRecords.length}개');
      
      // 디버깅: 오늘 날짜 출석 기록 확인
      final today = DateTime.now();
      final todayRecords = _attendanceRecords.where((r) => 
        r.classDateTime.year == today.year &&
        r.classDateTime.month == today.month &&
        r.classDateTime.day == today.day
      ).toList();
      
      print('[DEBUG] 오늘(${today.year}-${today.month}-${today.day}) 출석 기록: ${todayRecords.length}개');
      for (final record in todayRecords) {
        print('[DEBUG] - 학생ID: ${record.studentId}, 수업시간: ${record.classDateTime}, 등원: ${record.arrivalTime}, 하원: ${record.departureTime}, isPresent: ${record.isPresent}');
      }
    } catch (e) {
      print('[ERROR] 출석 기록 로드 실패: $e');
      _attendanceRecords = [];
      attendanceRecordsNotifier.value = [];
    }
  }

  Future<void> addAttendanceRecord(AttendanceRecord record) async {
    final recordData = record.toMap();
    await AcademyDbService.instance.addAttendanceRecord(recordData);
    _attendanceRecords.add(record);
    attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
  }

  Future<void> updateAttendanceRecord(AttendanceRecord record) async {
    if (record.id == null) return;
    
    final recordData = record.toMap();
    await AcademyDbService.instance.updateAttendanceRecord(record.id!, recordData);
    
    final index = _attendanceRecords.indexWhere((r) => r.id == record.id);
    if (index != -1) {
      _attendanceRecords[index] = record;
      attendanceRecordsNotifier.value = List.unmodifiable(_attendanceRecords);
    }
  }

  Future<void> deleteAttendanceRecord(String id) async {
    _attendanceRecords.removeWhere((r) => r.id == id);
    await AcademyDbService.instance.deleteAttendanceRecord(id);
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
    print('[DEBUG] saveOrUpdateAttendance 시작 - 학생ID: $studentId, 등원: $arrivalTime, 하원: $departureTime');
    
    // 기존 출석 기록 확인
    final existing = getAttendanceRecord(studentId, classDateTime);
    
    if (existing != null) {
      print('[DEBUG] 기존 출석 기록 업데이트 - ID: ${existing.id}');
      // copyWith는 null로 덮어쓰지 못하므로 명시적으로 새 레코드를 구성한다
      final updated = AttendanceRecord(
        id: existing.id,
        studentId: existing.studentId,
        classDateTime: existing.classDateTime,
        classEndTime: classEndTime,
        className: className,
        isPresent: isPresent,
        arrivalTime: arrivalTime, // null 허용(명시적 클리어)
        departureTime: departureTime, // null 허용(명시적 클리어)
        notes: notes,
        createdAt: existing.createdAt,
        updatedAt: DateTime.now(),
      );
      await updateAttendanceRecord(updated);
      // 보강 planned → completed 자동 연결 시도 (replace/add 대상)
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
      print('[DEBUG] 출석 기록 업데이트 완료');
    } else {
      print('[DEBUG] 새 출석 기록 추가');
      // 새로 생성
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
      // 보강 planned → completed 자동 연결 시도
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
      print('[DEBUG] 출석 기록 추가 완료 - ID: ${newRecord.id}');
    }
    
    // DB에 실제로 저장되었는지 확인
    await loadAttendanceRecords(); // 메모리 새로고침
    final saved = getAttendanceRecord(studentId, classDateTime);
    if (saved != null) {
      print('[DEBUG] DB 저장 확인 성공 - 등원: ${saved.arrivalTime}, 하원: ${saved.departureTime}');
    } else {
      print('[ERROR] DB 저장 확인 실패!');
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
    await AcademyDbService.instance.updateSessionOverride(updated.id, updated.toMap());

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
      await AcademyDbService.instance.ensureStudentPaymentInfoTable();
      final paymentInfoMaps = await AcademyDbService.instance.getAllStudentPaymentInfo();
      
      _studentPaymentInfos = paymentInfoMaps.map((map) => StudentPaymentInfo.fromJson(map)).toList();
      studentPaymentInfosNotifier.value = List.unmodifiable(_studentPaymentInfos);
      
      print('[DEBUG] 학생 결제 정보 로드 완료: ${_studentPaymentInfos.length}개');
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
    } catch (e) {
      print('[ERROR] 학생 결제 정보 삭제 실패: $e');
      rethrow;
    }
  }

  // ======== RESOURCES (FOLDERS/FILES) ========
  Future<void> saveResourceFolders(List<Map<String, dynamic>> rows) async {
    await AcademyDbService.instance.saveResourceFolders(rows);
  }

  Future<List<Map<String, dynamic>>> loadResourceFolders() async {
    return await AcademyDbService.instance.loadResourceFolders();
  }

  Future<void> saveResourceFile(Map<String, dynamic> row) async {
    await AcademyDbService.instance.saveResourceFile(row);
  }

  Future<List<Map<String, dynamic>>> loadResourceFiles() async {
    return await AcademyDbService.instance.loadResourceFiles();
  }

  Future<void> saveResourceFileLinks(String fileId, Map<String, String> links) async {
    await AcademyDbService.instance.saveResourceFileLinks(fileId, links);
  }

  Future<Map<String, String>> loadResourceFileLinks(String fileId) async {
    return await AcademyDbService.instance.loadResourceFileLinks(fileId);
  }

  Future<void> deleteResourceFile(String fileId) async {
    await AcademyDbService.instance.deleteResourceFileLinksByFileId(fileId);
    await AcademyDbService.instance.deleteResourceFile(fileId);
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
} 