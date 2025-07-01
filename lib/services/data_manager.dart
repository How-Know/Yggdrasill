import '../models/student.dart';
import '../models/group_info.dart';
import '../models/operating_hours.dart';
import '../models/academy_settings.dart';
import '../models/payment_type.dart';
import '../models/education_level.dart';
import '../models/student_time_block.dart';
import '../models/group_schedule.dart';
import '../models/teacher.dart';
import 'package:flutter/foundation.dart';
import 'academy_db.dart';
import 'dart:convert';

class DataManager {
  static final DataManager instance = DataManager._internal();
  DataManager._internal();

  List<Student> _students = [];
  List<GroupInfo> _groups = [];
  List<OperatingHours> _operatingHours = [];
  Map<String, GroupInfo> _groupsById = {};
  bool _isInitialized = false;

  final ValueNotifier<List<GroupInfo>> groupsNotifier = ValueNotifier<List<GroupInfo>>([]);
  final ValueNotifier<List<Student>> studentsNotifier = ValueNotifier<List<Student>>([]);

  List<GroupInfo> get groups => List.unmodifiable(_groups);
  List<Student> get students => List.unmodifiable(_students);

  AcademySettings _academySettings = AcademySettings(name: '', slogan: '', defaultCapacity: 30, lessonDuration: 50, logo: null);
  PaymentType _paymentType = PaymentType.monthly;

  AcademySettings get academySettings => _academySettings;
  PaymentType get paymentType => _paymentType;

  List<StudentTimeBlock> _studentTimeBlocks = [];
  final ValueNotifier<List<StudentTimeBlock>> studentTimeBlocksNotifier = ValueNotifier<List<StudentTimeBlock>>([]);
  
  List<GroupSchedule> _groupSchedules = [];
  final ValueNotifier<List<GroupSchedule>> groupSchedulesNotifier = ValueNotifier<List<GroupSchedule>>([]);

  List<StudentTimeBlock> get studentTimeBlocks => List.unmodifiable(_studentTimeBlocks);
  List<GroupSchedule> get groupSchedules => List.unmodifiable(_groupSchedules);

  List<Teacher> _teachers = [];
  final ValueNotifier<List<Teacher>> teachersNotifier = ValueNotifier<List<Teacher>>([]);
  List<Teacher> get teachers => List.unmodifiable(_teachers);

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
    _students = [];
    _operatingHours = [];
    _studentTimeBlocks = [];
    _academySettings = AcademySettings(name: '', slogan: '', defaultCapacity: 30, lessonDuration: 50, logo: null);
    _paymentType = PaymentType.monthly;
    _notifyListeners();
  }

  Future<void> loadGroups() async {
    try {
      _groups = await AcademyDbService.instance.getGroups();
      _groupsById = {for (var g in _groups) g.id: g};
    } catch (e) {
      print('Error loading groups: $e');
      _groups = [];
      _groupsById = {};
    }
    _notifyListeners();
  }

  Future<void> loadStudents() async {
    _students = await AcademyDbService.instance.getStudents();
    print('loadStudents 결과: ' + _students.toString());
    // groupInfo 복원
    for (var i = 0; i < _students.length; i++) {
      final s = _students[i];
      final groupId = s.groupId;
      if (groupId != null && _groupsById.containsKey(groupId)) {
        _students[i] = s.copyWith(groupInfo: _groupsById[groupId]);
      }
    }
    _notifyListeners();
  }

  Future<void> saveStudents() async {
    await AcademyDbService.instance.saveStudents(_students);
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
        print('[DataManager] loadAcademySettings: logo type=[33m${dbData['logo']?.runtimeType}[0m, length=[33m${(dbData['logo'] as Uint8List?)?.length}[0m, isNull=[33m${dbData['logo'] == null}[0m');
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
        );
      } else {
        _academySettings = AcademySettings(name: '', slogan: '', defaultCapacity: 30, lessonDuration: 50, logo: null);
      }
    } catch (e) {
      print('Error loading settings: $e');
      _academySettings = AcademySettings(name: '', slogan: '', defaultCapacity: 30, lessonDuration: 50, logo: null);
    }
  }

  Future<void> saveAcademySettings(AcademySettings settings) async {
    try {
      print('[DataManager] saveAcademySettings: logo type=[32m${settings.logo?.runtimeType}[0m, length=[32m${settings.logo?.length}[0m, isNull=[32m${settings.logo == null}[0m');
      _academySettings = settings;
      await AcademyDbService.instance.saveAcademySettings(settings, _paymentType == PaymentType.monthly ? 'monthly' : 'perClass');
    } catch (e) {
      print('Error saving settings: $e');
      throw Exception('Failed to save academy settings');
    }
  }

  void _notifyListeners() {
    groupsNotifier.value = List.unmodifiable(_groups);
    studentsNotifier.value = List.unmodifiable(_students);
    studentTimeBlocksNotifier.value = List.unmodifiable(_studentTimeBlocks);
    groupSchedulesNotifier.value = List.unmodifiable(_groupSchedules);
    teachersNotifier.value = List.unmodifiable(_teachers);
  }

  void addGroup(GroupInfo groupInfo) {
    _groups.add(groupInfo);
    _groupsById[groupInfo.id] = groupInfo;
    _notifyListeners();
    saveGroups();
  }

  void updateGroup(GroupInfo groupInfo) {
    _groupsById[groupInfo.id] = groupInfo;
    _groups = _groupsById.values.toList();
    _notifyListeners();
    saveGroups();
  }

  void deleteGroup(GroupInfo groupInfo) {
    if (_groupsById.containsKey(groupInfo.id)) {
      _groupsById.remove(groupInfo.id);
      _groups = _groupsById.values.toList();
      
      // Remove group from students
      for (var i = 0; i < _students.length; i++) {
        if (_students[i].groupInfo?.id == groupInfo.id) {
          _students[i] = _students[i].copyWith(groupInfo: null);
        }
      }
      
      _notifyListeners();
      Future.wait([
        saveGroups(),
        saveStudents(),
      ]);
    }
  }

  Future<void> addStudent(Student student) async {
    print('addStudent 호출: ' + student.toString());
    await AcademyDbService.instance.addStudent(student);
    await loadStudents();
  }

  Future<void> updateStudent(Student student) async {
    await loadStudents();
    await AcademyDbService.instance.updateStudent(student);
    await loadStudents();
  }

  Future<void> deleteStudent(String id) async {
    await loadStudents();
    _students.removeWhere((s) => s.id == id);
    await AcademyDbService.instance.deleteStudent(id);
    await loadStudents();
  }

  void updateStudentGroup(Student student, GroupInfo? newGroup) {
    final index = _students.indexOf(student);
    if (index != -1) {
      _students[index] = student.copyWith(groupInfo: newGroup);
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
      _operatingHours = await AcademyDbService.instance.getOperatingHours();
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
    // _storage 관련 코드와 json/hive 기반 메서드 전체를 완전히 삭제
  }

  Future<void> saveStudentTimeBlocks() async {
    // _storage 관련 코드와 json/hive 기반 메서드 전체를 완전히 삭제
  }

  Future<void> addStudentTimeBlock(StudentTimeBlock block) async {
    // _storage 관련 코드와 json/hive 기반 메서드 전체를 완전히 삭제
  }

  Future<void> removeStudentTimeBlock(String id) async {
    // _storage 관련 코드와 json/hive 기반 메서드 전체를 완전히 삭제
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
    final groupStudents = _students.where((s) => s.groupInfo?.id == schedule.groupId).toList();
    
    // 각 학생에 대한 시간 블록 생성
    for (final student in groupStudents) {
      final block = StudentTimeBlock(
        id: '${DateTime.now().millisecondsSinceEpoch}_${student.id}',
        studentId: student.id,
        groupId: schedule.groupId,
        dayIndex: schedule.dayIndex,
        startTime: schedule.startTime,
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
    await AcademyDbService.instance.saveTeachers(_teachers);
    await loadTeachers();
  }

  void addTeacher(Teacher teacher) {
    _teachers.add(teacher);
    saveTeachers();
  }

  void deleteTeacher(int idx) {
    if (idx >= 0 && idx < _teachers.length) {
      _teachers.removeAt(idx);
      saveTeachers();
    }
  }
} 