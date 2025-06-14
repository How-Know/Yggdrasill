import '../models/student.dart';
import '../models/class_info.dart';
import '../models/operating_hours.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';

// Web-specific imports
import 'web_stub.dart'
    if (dart.library.io) 'desktop.dart'
    if (dart.library.html) 'web_stub.dart';

class DataManager {
  static final DataManager instance = DataManager._internal();
  DataManager._internal();

  List<Student> _students = [];
  List<ClassInfo> _classes = [];
  List<OperatingHours> _operatingHours = [];
  Map<String, ClassInfo> _classesById = {};

  final ValueNotifier<List<ClassInfo>> classesNotifier = ValueNotifier<List<ClassInfo>>([]);
  final ValueNotifier<List<Student>> studentsNotifier = ValueNotifier<List<Student>>([]);

  List<ClassInfo> get classes => List.unmodifiable(_classes);
  List<Student> get students => List.unmodifiable(_students);

  Future<void> initialize() async {
    try {
      await loadClasses();
      await loadStudents();
    } catch (e) {
      print('Error initializing data: $e');
    }
  }

  Future<void> loadClasses() async {
    try {
      final jsonData = await loadData('classes.json') as List;
      _classes = jsonData.map((json) => ClassInfo.fromJson(json)).toList();
      _classesById = {for (var c in _classes) c.id: c};
      _notifyListeners();
    } catch (e) {
      print('Error loading classes: $e');
      _classes = [];
      _classesById = {};
      _notifyListeners();
    }
  }

  Future<void> loadStudents() async {
    try {
      final jsonData = await loadData('students.json') as List;
      _students = jsonData.map((json) => Student.fromJson(json as Map<String, dynamic>, _classesById)).toList();
      _notifyListeners();
    } catch (e) {
      print('Error loading students: $e');
      _students = [];
      _notifyListeners();
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
    saveData('classes.json', _classes.map((c) => c.toJson()).toList());
  }

  void updateClass(ClassInfo classInfo) {
    _classesById[classInfo.id] = classInfo;
    _classes = _classesById.values.toList();
    _notifyListeners();
    saveData('classes.json', _classes.map((c) => c.toJson()).toList());
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
      saveData('classes.json', _classes.map((c) => c.toJson()).toList());
      saveData('students.json', _students.map((s) => s.toJson()).toList());
    }
  }

  void addStudent(Student student) {
    _students.add(student);
    _notifyListeners();
    saveData('students.json', _students.map((s) => s.toJson()).toList());
  }

  void updateStudent(Student oldStudent, Student newStudent) {
    final index = _students.indexOf(oldStudent);
    if (index != -1) {
      _students[index] = newStudent;
      _notifyListeners();
      saveData('students.json', _students.map((s) => s.toJson()).toList());
    }
  }

  void deleteStudent(Student student) {
    _students.remove(student);
    _notifyListeners();
    saveData('students.json', _students.map((s) => s.toJson()).toList());
  }

  void updateStudentClass(Student student, ClassInfo? newClass) {
    final index = _students.indexOf(student);
    if (index != -1) {
      _students[index] = student.copyWith(classInfo: newClass);
      _notifyListeners();
      saveData('students.json', _students.map((s) => s.toJson()).toList());
    }
  }

  Future<void> saveOperatingHours(List<OperatingHours> hours) async {
    _operatingHours = hours;
    final jsonData = hours.map((hour) => hour.toJson()).toList();
    await saveData('operating_hours.json', jsonData);
  }

  Future<List<OperatingHours>> getOperatingHours() async {
    if (_operatingHours.isNotEmpty) {
      return _operatingHours;
    }

    try {
      final jsonData = await loadData('operating_hours.json') as List;
      _operatingHours = jsonData.map((json) => OperatingHours.fromJson(json)).toList();
    } catch (e) {
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

    return _operatingHours;
  }
} 