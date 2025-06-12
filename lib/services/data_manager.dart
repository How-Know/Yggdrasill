import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' if (dart.library.io) 'dart:io' as platform;
import 'package:path_provider/path_provider.dart';
import '../models/student.dart';
import '../models/class_info.dart';

class DataManager {
  static final DataManager instance = DataManager._internal();
  static bool _initialized = false;

  final Map<String, ClassInfo> _classesById = {};
  final List<Student> _students = [];

  // 외부에서 변경 사항을 감지할 수 있도록 ValueNotifier 추가
  final ValueNotifier<List<ClassInfo>> classesNotifier = ValueNotifier<List<ClassInfo>>([]);
  final ValueNotifier<List<Student>> studentsNotifier = ValueNotifier<List<Student>>([]);

  factory DataManager() {
    return instance;
  }

  DataManager._internal();

  List<ClassInfo> get classes => classesNotifier.value;
  List<Student> get students => studentsNotifier.value;

  Future<String> get _localPath async {
    if (kIsWeb) {
      return '';
    }
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  Future<File> get _localFile async {
    final path = await _localPath;
    return File('$path/academy_data.json');
  }

  Future<void> initialize() async {
    if (_initialized) return;
    await loadData();
    _initialized = true;
  }

  Future<void> saveData() async {
    if (kIsWeb) {
      // 웹에서는 localStorage 사용
      final data = {
        'classes': _classesById.values.map((c) => c.toJson()).toList(),
        'students': _students.map((s) => s.toJson()).toList(),
      };
      platform.window.localStorage['academy_data'] = jsonEncode(data);
      return;
    }

    final file = await _localFile;
    final data = {
      'classes': _classesById.values.map((c) => c.toJson()).toList(),
      'students': _students.map((s) => s.toJson()).toList(),
    };
    await file.writeAsString(jsonEncode(data));
  }

  Future<void> loadData() async {
    try {
      Map<String, dynamic>? data;
      
      if (kIsWeb) {
        // 웹에서는 localStorage에서 데이터 로드
        final jsonString = platform.window.localStorage['academy_data'];
        if (jsonString != null) {
          data = jsonDecode(jsonString) as Map<String, dynamic>;
        }
      } else {
        // 파일에서 데이터 로드
        final file = await _localFile;
        if (await file.exists()) {
          final jsonString = await file.readAsString();
          data = jsonDecode(jsonString) as Map<String, dynamic>;
        }
      }

      if (data != null) {
        // 먼저 클래스 로드
        _classesById.clear();
        final classesList = (data['classes'] as List).cast<Map<String, dynamic>>();
        for (final classData in classesList) {
          final classInfo = ClassInfo.fromJson(classData);
          _classesById[classInfo.id] = classInfo;
        }

        // 학생 로드
        _students.clear();
        final studentsList = (data['students'] as List).cast<Map<String, dynamic>>();
        for (final studentData in studentsList) {
          final student = Student.fromJson(studentData, _classesById);
          _students.add(student);
        }

        // 알림 업데이트
        _notifyListeners();
      }
    } catch (e) {
      print('Error loading data: $e');
    }
  }

  void addClass(ClassInfo classInfo) {
    _classesById[classInfo.id] = classInfo;
    _notifyListeners();
    saveData();
  }

  void updateClass(ClassInfo classInfo) {
    _classesById[classInfo.id] = classInfo;
    _notifyListeners();
    saveData();
  }

  void deleteClass(String classId) {
    _classesById.remove(classId);
    // 해당 클래스에 속한 학생들의 클래스 정보를 null로 설정
    for (final student in _students) {
      if (student.classInfo?.id == classId) {
        student.classInfo = null;
      }
    }
    _notifyListeners();
    saveData();
  }

  void addStudent(Student student) {
    _students.add(student);
    _notifyListeners();
    saveData();
  }

  void updateStudent(Student oldStudent, Student newStudent) {
    final index = _students.indexOf(oldStudent);
    if (index != -1) {
      _students[index] = newStudent;
      _notifyListeners();
      saveData();
    }
  }

  void deleteStudent(Student student) {
    _students.remove(student);
    _notifyListeners();
    saveData();
  }

  void moveStudent(Student student, ClassInfo? newClass) {
    final index = _students.indexOf(student);
    if (index != -1) {
      _students[index] = student.copyWith(classInfo: newClass);
      _notifyListeners();
      saveData();
    }
  }

  void _notifyListeners() {
    classesNotifier.value = _classesById.values.toList();
    studentsNotifier.value = List.unmodifiable(_students);
  }
} 