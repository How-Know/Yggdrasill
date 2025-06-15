import '../models/student.dart';
import '../models/class_info.dart';
import '../models/operating_hours.dart';
import '../models/academy_settings.dart';
import '../models/payment_type.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'storage_service.dart';

// Platform-specific imports
import 'storage_service.dart'
    if (dart.library.io) 'storage_service_io.dart'
    if (dart.library.html) 'storage_service_web.dart';

class DataManager {
  static final DataManager instance = DataManager._internal();
  DataManager._internal();

  List<Student> _students = [];
  List<ClassInfo> _classes = [];
  List<OperatingHours> _operatingHours = [];
  Map<String, ClassInfo> _classesById = {};
  late final StorageService _storage;
  bool _isInitialized = false;

  final ValueNotifier<List<ClassInfo>> classesNotifier = ValueNotifier<List<ClassInfo>>([]);
  final ValueNotifier<List<Student>> studentsNotifier = ValueNotifier<List<Student>>([]);

  List<ClassInfo> get classes => List.unmodifiable(_classes);
  List<Student> get students => List.unmodifiable(_students);

  AcademySettings _academySettings = AcademySettings.defaults();
  PaymentType _paymentType = PaymentType.monthly;

  AcademySettings get academySettings => _academySettings;
  PaymentType get paymentType => _paymentType;

  Future<void> initialize() async {
    if (_isInitialized) {
      return;
    }

    try {
      _storage = await createStorageService();
      await loadClasses();
      await loadStudents();
      await loadAcademySettings();
      await loadPaymentType();
      await _loadOperatingHours();
      _isInitialized = true;
    } catch (e) {
      print('Error initializing data: $e');
      _initializeDefaults();
    }
  }

  void _initializeDefaults() {
    _classes = [];
    _classesById = {};
    _students = [];
    _operatingHours = [];
    _academySettings = AcademySettings.defaults();
    _paymentType = PaymentType.monthly;
    _notifyListeners();
  }

  Future<void> loadClasses() async {
    try {
      final jsonData = await _storage.load('classes');
      if (jsonData != null) {
        final List<dynamic> classesList = jsonDecode(jsonData);
        _classes = classesList.map((json) => ClassInfo.fromJson(json as Map<String, dynamic>)).toList();
        _classesById = {for (var c in _classes) c.id: c};
      }
    } catch (e) {
      print('Error loading classes: $e');
      _classes = [];
      _classesById = {};
    }
    _notifyListeners();
  }

  Future<void> loadStudents() async {
    try {
      final jsonData = await _storage.load('students');
      if (jsonData != null) {
        final List<dynamic> studentsList = jsonDecode(jsonData);
        _students = studentsList.map((json) => Student.fromJson(json as Map<String, dynamic>, _classesById)).toList();
      }
    } catch (e) {
      print('Error loading students: $e');
      _students = [];
    }
    _notifyListeners();
  }

  Future<void> saveStudents() async {
    try {
      final jsonString = jsonEncode(_students.map((s) => s.toJson()).toList());
      await _storage.save('students', jsonString);
    } catch (e) {
      print('Error saving students: $e');
      throw Exception('Failed to save students data');
    }
  }

  Future<void> saveClasses() async {
    try {
      final jsonString = jsonEncode(_classes.map((c) => c.toJson()).toList());
      await _storage.save('classes', jsonString);
    } catch (e) {
      print('Error saving classes: $e');
      throw Exception('Failed to save classes data');
    }
  }

  Future<void> loadAcademySettings() async {
    try {
      final jsonData = await _storage.load('settings');
      if (jsonData != null) {
        final Map<String, dynamic> settingsMap = jsonDecode(jsonData);
        _academySettings = AcademySettings.fromJson(settingsMap);
      }
    } catch (e) {
      print('Error loading settings: $e');
      _academySettings = AcademySettings.defaults();
    }
  }

  Future<void> saveAcademySettings(AcademySettings settings) async {
    try {
      _academySettings = settings;
      final jsonString = jsonEncode(settings.toJson());
      await _storage.save('settings', jsonString);
    } catch (e) {
      print('Error saving settings: $e');
      throw Exception('Failed to save academy settings');
    }
  }

  void _notifyListeners() {
    classesNotifier.value = List.unmodifiable(_classes);
    studentsNotifier.value = List.unmodifiable(_students);
  }

  void addClass(ClassInfo classInfo) {
    _classes.add(classInfo);
    _classesById[classInfo.id] = classInfo;
    _notifyListeners();
    saveClasses();
  }

  void updateClass(ClassInfo classInfo) {
    _classesById[classInfo.id] = classInfo;
    _classes = _classesById.values.toList();
    _notifyListeners();
    saveClasses();
  }

  void deleteClass(ClassInfo classInfo) {
    if (_classesById.containsKey(classInfo.id)) {
      _classesById.remove(classInfo.id);
      _classes = _classesById.values.toList();
      
      // Remove class from students
      for (var i = 0; i < _students.length; i++) {
        if (_students[i].classInfo?.id == classInfo.id) {
          _students[i] = _students[i].copyWith(classInfo: null);
        }
      }
      
      _notifyListeners();
      Future.wait([
        saveClasses(),
        saveStudents(),
      ]);
    }
  }

  Future<void> addStudent(Student student) async {
    _students.add(student);
    _notifyListeners();
    await saveStudents();
  }

  Future<void> updateStudent(Student student) async {
    final index = _students.indexWhere((s) => s.id == student.id);
    if (index != -1) {
      _students[index] = student;
      _notifyListeners();
      await saveStudents();
    }
  }

  Future<void> deleteStudent(String id) async {
    _students.removeWhere((s) => s.id == id);
    _notifyListeners();
    await saveStudents();
  }

  void updateStudentClass(Student student, ClassInfo? newClass) {
    final index = _students.indexOf(student);
    if (index != -1) {
      _students[index] = student.copyWith(classInfo: newClass);
      _notifyListeners();
      saveStudents();
    }
  }

  Future<void> saveOperatingHours(List<OperatingHours> hours) async {
    try {
      _operatingHours = hours;
      final jsonString = jsonEncode(hours.map((h) => h.toJson()).toList());
      await _storage.save('operating_hours', jsonString);
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
      final jsonData = await _storage.load('operating_hours');
      if (jsonData != null) {
        final List<dynamic> hoursList = jsonDecode(jsonData);
        _operatingHours = hoursList.map((json) => OperatingHours.fromJson(json as Map<String, dynamic>)).toList();
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
} 