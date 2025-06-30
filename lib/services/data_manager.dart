import '../models/student.dart';
import '../models/group_info.dart';
import '../models/operating_hours.dart';
import '../models/academy_settings.dart';
import '../models/payment_type.dart';
import '../models/education_level.dart';
import '../models/student_time_block.dart';
import '../models/group_schedule.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'storage_service.dart';
import 'academy_db.dart';
import 'academy_hive.dart';

// Platform-specific imports
import 'storage_service.dart'
    if (dart.library.io) 'storage_service_io.dart'
    if (dart.library.html) 'storage_service_web.dart';

class DataManager {
  static final DataManager instance = DataManager._internal();
  DataManager._internal();

  List<Student> _students = [];
  List<GroupInfo> _groups = [];
  List<OperatingHours> _operatingHours = [];
  Map<String, GroupInfo> _groupsById = {};
  late final StorageService _storage;
  bool _isInitialized = false;

  final ValueNotifier<List<GroupInfo>> groupsNotifier = ValueNotifier<List<GroupInfo>>([]);
  final ValueNotifier<List<Student>> studentsNotifier = ValueNotifier<List<Student>>([]);

  List<GroupInfo> get groups => List.unmodifiable(_groups);
  List<Student> get students => List.unmodifiable(_students);

  AcademySettings _academySettings = AcademySettings.defaults();
  PaymentType _paymentType = PaymentType.monthly;

  AcademySettings get academySettings => _academySettings;
  PaymentType get paymentType => _paymentType;

  List<StudentTimeBlock> _studentTimeBlocks = [];
  final ValueNotifier<List<StudentTimeBlock>> studentTimeBlocksNotifier = ValueNotifier<List<StudentTimeBlock>>([]);
  
  List<GroupSchedule> _groupSchedules = [];
  final ValueNotifier<List<GroupSchedule>> groupSchedulesNotifier = ValueNotifier<List<GroupSchedule>>([]);

  List<StudentTimeBlock> get studentTimeBlocks => List.unmodifiable(_studentTimeBlocks);
  List<GroupSchedule> get groupSchedules => List.unmodifiable(_groupSchedules);

  Future<void> initialize() async {
    if (_isInitialized) {
      return;
    }

    try {
      _storage = await createStorageService();
      await loadGroups();
      await loadStudents();
      await loadAcademySettings();
      await loadPaymentType();
      await _loadOperatingHours();
      await loadStudentTimeBlocks();
      await loadGroupSchedules();
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
    _academySettings = AcademySettings.defaults();
    _paymentType = PaymentType.monthly;
    _notifyListeners();
  }

  Future<void> loadGroups() async {
    try {
      final jsonData = await _storage.load('groups');
      if (jsonData != null) {
        final List<dynamic> groupsList = jsonDecode(jsonData);
        _groups = groupsList.map((json) => GroupInfo.fromJson(json as Map<String, dynamic>)).toList();
        _groupsById = {for (var g in _groups) g.id: g};
      }
    } catch (e) {
      print('Error loading groups: $e');
      _groups = [];
      _groupsById = {};
    }
    _notifyListeners();
  }

  Future<void> loadStudents() async {
    try {
      if (kIsWeb) {
        _students = await AcademyHiveService.getStudents();
      } else {
        _students = await AcademyDbService.instance.getStudents();
      }
      // groupInfo 복원
      for (var i = 0; i < _students.length; i++) {
        final s = _students[i];
        final groupId = s.groupId;
        if (groupId != null && _groupsById.containsKey(groupId)) {
          _students[i] = s.copyWith(groupInfo: _groupsById[groupId]);
        }
      }
    } catch (e) {
      print('Error loading students: $e');
      _students = [];
    }
    _notifyListeners();
  }

  Future<void> saveStudents() async {
    // 더 이상 사용하지 않음 (sqlite 직접 사용)
    return;
  }

  Future<void> saveGroups() async {
    try {
      final jsonString = jsonEncode(_groups.map((g) => g.toJson()).toList());
      await _storage.save('groups', jsonString);
    } catch (e) {
      print('Error saving groups: $e');
      throw Exception('Failed to save groups data');
    }
  }

  Future<void> loadAcademySettings() async {
    try {
      if (!kIsWeb) {
        // sqlite에서 불러오기
        final dbData = await AcademyDbService.instance.getAcademySettings();
        if (dbData != null) {
          _academySettings = AcademySettings(
            name: dbData['name'] as String? ?? '',
            slogan: dbData['slogan'] as String? ?? '',
            defaultCapacity: dbData['default_capacity'] as int? ?? 30,
            lessonDuration: dbData['lesson_duration'] as int? ?? 50,
            logo: dbData['logo'] is Uint8List
                ? dbData['logo'] as Uint8List
                : dbData['logo'] is List<int>
                    ? Uint8List.fromList(List<int>.from(dbData['logo']))
                    : dbData['logo'] is String && (dbData['logo'] as String).isNotEmpty
                        ? base64Decode(dbData['logo'] as String)
                        : null,
          );
        } else {
          _academySettings = AcademySettings.defaults();
        }
      } else {
        // 기존 웹 방식
        final jsonData = await _storage.load('settings');
        if (jsonData != null) {
          final Map<String, dynamic> settingsMap = jsonDecode(jsonData);
          _academySettings = AcademySettings.fromJson(settingsMap);
        }
      }
    } catch (e) {
      print('Error loading settings: $e');
      _academySettings = AcademySettings.defaults();
    }
  }

  Future<void> saveAcademySettings(AcademySettings settings) async {
    try {
      _academySettings = settings;
      if (!kIsWeb) {
        // sqlite에 저장
        await AcademyDbService.instance.saveAcademySettings(settings, _paymentType == PaymentType.monthly ? 'monthly' : 'perClass');
      } else {
        // 기존 웹 방식
        final jsonString = jsonEncode(settings.toJson());
        await _storage.save('settings', jsonString);
      }
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
    if (kIsWeb) {
      _students.add(student);
      await AcademyHiveService.saveStudents(_students);
      await loadStudents();
    } else {
      await AcademyDbService.instance.addStudent(student);
      await loadStudents();
    }
  }

  Future<void> updateStudent(Student student) async {
    if (kIsWeb) {
      final idx = _students.indexWhere((s) => s.id == student.id);
      if (idx != -1) {
        _students[idx] = student;
        await AcademyHiveService.saveStudents(_students);
      }
      await loadStudents();
    } else {
      await AcademyDbService.instance.updateStudent(student);
      await loadStudents();
    }
  }

  Future<void> deleteStudent(String id) async {
    if (kIsWeb) {
      _students.removeWhere((s) => s.id == id);
      await AcademyHiveService.saveStudents(_students);
      await loadStudents();
    } else {
      await AcademyDbService.instance.deleteStudent(id);
      await loadStudents();
    }
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
      if (kIsWeb) {
        // Hive
        await AcademyHiveService.saveOperatingHours(hours);
      } else {
        // sqlite
        await AcademyDbService.instance.saveOperatingHours(hours);
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
      if (kIsWeb) {
        // Hive
        _operatingHours = AcademyHiveService.getOperatingHours();
      } else {
        // sqlite
        _operatingHours = await AcademyDbService.instance.getOperatingHours();
      }
    } catch (e) {
      print('Error loading operating hours: $e');
      _operatingHours = [];
    }

    return _operatingHours;
  }

  Future<void> savePaymentType(PaymentType type) async {
    try {
      _paymentType = type;
      final jsonString = jsonEncode({'type': type.index});
      await _storage.save('payment_type', jsonString);
    } catch (e) {
      print('Error saving payment type: $e');
      throw Exception('Failed to save payment type');
    }
  }

  Future<void> loadPaymentType() async {
    try {
      final jsonData = await _storage.load('payment_type');
      if (jsonData != null) {
        final data = jsonDecode(jsonData) as Map<String, dynamic>;
        _paymentType = PaymentType.values[data['type'] as int];
      }
    } catch (e) {
      print('Error loading payment type: $e');
      _paymentType = PaymentType.monthly;
    }
  }

  Future<void> _loadOperatingHours() async {
    try {
      final jsonData = await _storage.load('operating_hours');
      if (jsonData != null) {
        final List<dynamic> hoursList = jsonDecode(jsonData);
        _operatingHours = hoursList.map((json) => OperatingHours.fromJson(json)).toList();
      } else {
        // 기본 운영 시간 설정 (오전 9시 ~ 오후 6시)
        final now = DateTime.now();
        final startTime = DateTime(now.year, now.month, now.day, 9, 0);
        final endTime = DateTime(now.year, now.month, now.day, 18, 0);
        
        _operatingHours = [
          OperatingHours(
            startTime: startTime,
            endTime: endTime,
            breakTimes: [
              BreakTime(
                startTime: DateTime(now.year, now.month, now.day, 12, 0),
                endTime: DateTime(now.year, now.month, now.day, 13, 0),
              ),
            ],
          ),
        ];
        
        await saveOperatingHours(_operatingHours);
      }
    } catch (e) {
      print('Error loading operating hours: $e');
      _operatingHours = [];
    }
  }

  Future<void> loadStudentTimeBlocks() async {
    try {
      final jsonData = await _storage.load('student_time_blocks');
      if (jsonData != null) {
        final List<dynamic> blocksList = jsonDecode(jsonData);
        _studentTimeBlocks = blocksList.map((json) => StudentTimeBlock.fromJson(json as Map<String, dynamic>)).toList();
      }
    } catch (e) {
      print('Error loading student time blocks: $e');
      _studentTimeBlocks = [];
    }
    _notifyListeners();
  }

  Future<void> saveStudentTimeBlocks() async {
    try {
      final jsonString = jsonEncode(_studentTimeBlocks.map((b) => b.toJson()).toList());
      await _storage.save('student_time_blocks', jsonString);
    } catch (e) {
      print('Error saving student time blocks: $e');
      throw Exception('Failed to save student time blocks');
    }
  }

  Future<void> addStudentTimeBlock(StudentTimeBlock block) async {
    _studentTimeBlocks.add(block);
    _notifyListeners();
    await saveStudentTimeBlocks();
  }

  Future<void> removeStudentTimeBlock(String id) async {
    _studentTimeBlocks.removeWhere((b) => b.id == id);
    _notifyListeners();
    await saveStudentTimeBlocks();
  }

  // GroupSchedule 관련 메서드들
  Future<void> loadGroupSchedules() async {
    try {
      final jsonData = await _storage.load('group_schedules');
      if (jsonData != null) {
        final List<dynamic> schedulesList = jsonDecode(jsonData);
        _groupSchedules = schedulesList.map((json) => GroupSchedule.fromJson(json as Map<String, dynamic>)).toList();
      }
    } catch (e) {
      print('Error loading group schedules: $e');
      _groupSchedules = [];
    }
    _notifyListeners();
  }

  Future<void> saveGroupSchedules() async {
    try {
      final jsonString = jsonEncode(_groupSchedules.map((s) => s.toJson()).toList());
      await _storage.save('group_schedules', jsonString);
    } catch (e) {
      print('Error saving group schedules: $e');
      throw Exception('Failed to save group schedules');
    }
  }

  Future<List<GroupSchedule>> getGroupSchedules(String groupId) async {
    return _groupSchedules.where((schedule) => schedule.groupId == groupId).toList();
  }

  Future<void> addGroupSchedule(GroupSchedule schedule) async {
    _groupSchedules.add(schedule);
    _notifyListeners();
    await saveGroupSchedules();
  }

  Future<void> updateGroupSchedule(GroupSchedule schedule) async {
    final index = _groupSchedules.indexWhere((s) => s.id == schedule.id);
    if (index != -1) {
      _groupSchedules[index] = schedule;
      _notifyListeners();
      await saveGroupSchedules();
    }
  }

  Future<void> deleteGroupSchedule(String id) async {
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
} 