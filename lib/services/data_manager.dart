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
import 'package:flutter/foundation.dart';
import 'academy_db.dart';
import 'dart:convert';

class StudentWithInfo {
  final Student student;
  final StudentBasicInfo basicInfo;
  StudentWithInfo({required this.student, required this.basicInfo});
  // UI 호환용 getter (임시)
  GroupInfo? get groupInfo => student.groupInfo;
  String? get phoneNumber => student.phoneNumber;
  String? get parentPhoneNumber => student.parentPhoneNumber;
  DateTime? get registrationDate => student.registrationDate;
  // 반드시 basicInfo.weeklyClassCount만 사용해야 함
  int get weeklyClassCount => basicInfo.weeklyClassCount;
}

class DataManager {
  static final DataManager instance = DataManager._internal();
  DataManager._internal();

  List<StudentWithInfo> _studentsWithInfo = [];
  List<GroupInfo> _groups = [];
  List<OperatingHours> _operatingHours = [];
  Map<String, GroupInfo> _groupsById = {};
  bool _isInitialized = false;

  final ValueNotifier<List<GroupInfo>> groupsNotifier = ValueNotifier<List<GroupInfo>>([]);
  final ValueNotifier<List<StudentWithInfo>> studentsNotifier = ValueNotifier<List<StudentWithInfo>>([]);

  List<GroupInfo> get groups {
    // print('[DEBUG] DataManager.groups: $_groups');
    return List.unmodifiable(_groups);
  }
  List<StudentWithInfo> get students => List.unmodifiable(_studentsWithInfo);

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
      await loadStudents();
      await loadAcademySettings();
      await loadPaymentType();
      await _loadOperatingHours();
      await loadStudentTimeBlocks();
      await loadSelfStudyTimeBlocks(); // 자습 블록도 반드시 불러오기
      await loadGroupSchedules();
      await loadTeachers();
      _isInitialized = true;
    } catch (e) {
      print('Error initializing data: $e');
      _initializeDefaults();
    }
  }

  void _initializeDefaults() {
    _groups = [];
    _groupsById = {};
    _studentsWithInfo = [];
    _operatingHours = [];
    _studentTimeBlocks = [];
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
    // 2. students_basic_info 테이블에서 부가 정보 불러오기
    List<StudentBasicInfo> basicInfos = [];
    for (final s in studentsRaw) {
      final info = await AcademyDbService.instance.getStudentBasicInfo(s.id);
      if (info != null) {
        basicInfos.add(StudentBasicInfo.fromDb(info));
      } else {
        // 부가 정보가 없으면 기본값으로 생성
        basicInfos.add(StudentBasicInfo(
          studentId: s.id,
          registrationDate: DateTime.now(),
        ));
      }
    }
    // 3. groupId로 groupInfo를 찾아서 Student에 할당 (students_basic_info 기준)
    final students = [
      for (int i = 0; i < studentsRaw.length; i++)
        Student(
          id: studentsRaw[i].id,
          name: studentsRaw[i].name,
          school: studentsRaw[i].school,
          grade: studentsRaw[i].grade,
          educationLevel: studentsRaw[i].educationLevel,
          phoneNumber: studentsRaw[i].phoneNumber,
          parentPhoneNumber: studentsRaw[i].parentPhoneNumber,
          registrationDate: studentsRaw[i].registrationDate,
          weeklyClassCount: studentsRaw[i].weeklyClassCount,
          groupId: basicInfos[i].groupId,
          groupInfo: basicInfos[i].groupId != null ? _groupsById[basicInfos[i].groupId] : null,
        )
    ];
    // 4. 매칭해서 StudentWithInfo 리스트 생성
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
  }

  Future<void> removeStudentTimeBlock(String id) async {
    _studentTimeBlocks.removeWhere((b) => b.id == id);
    studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
    await AcademyDbService.instance.deleteStudentTimeBlock(id);
    await loadStudentTimeBlocks(); // DB 삭제 후 메모리/상태 최신화
  }

  Future<void> bulkAddStudentTimeBlocks(List<StudentTimeBlock> blocks) async {
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
    _studentTimeBlocks.addAll(blocks);
    studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
    await AcademyDbService.instance.bulkAddStudentTimeBlocks(blocks);
  }

  Future<void> bulkDeleteStudentTimeBlocks(List<String> blockIds) async {
    _studentTimeBlocks.removeWhere((b) => blockIds.contains(b.id));
    studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
    await AcademyDbService.instance.bulkDeleteStudentTimeBlocks(blockIds);
    await loadStudentTimeBlocks();
  }

  Future<void> updateStudentTimeBlock(String id, StudentTimeBlock newBlock) async {
    final index = _studentTimeBlocks.indexWhere((b) => b.id == id);
    if (index != -1) {
      _studentTimeBlocks[index] = newBlock;
      studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
      await AcademyDbService.instance.updateStudentTimeBlock(id, newBlock);
      await loadStudentTimeBlocks(); // DB 업데이트 후 메모리/상태 최신화
    }
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

  /// 수업 등록 가능 학생 리스트 반환 (weeklyClassCount - setId 개수 > 0)
  List<StudentWithInfo> getLessonEligibleStudents() {
    final eligible = students.where((s) {
      final setCount = getStudentLessonSetCount(s.student.id);
      final remain = (s.basicInfo.weeklyClassCount) - setCount;
      print('[DEBUG][DataManager] getLessonEligibleStudents: ${s.student.name}, remain=$remain');
      return remain > 0;
    }).toList();
    print('[DEBUG][DataManager] getLessonEligibleStudents: ${eligible.map((s) => s.student.name).toList()}');
    return eligible;
  }

  /// 자습 등록 가능 학생 리스트 반환 (weeklyClassCount - setId 개수 <= 0)
  List<StudentWithInfo> getSelfStudyEligibleStudents() {
    final eligible = students.where((s) {
      final setCount = getStudentLessonSetCount(s.student.id);
      final remain = (s.basicInfo.weeklyClassCount) - setCount;
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
} 