import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/foundation.dart';
import '../models/student.dart';
import '../models/class_info.dart';
import 'data_manager_base.dart';

class DataManager extends DataManagerBase {
  static final DataManager _instance = DataManager._internal();
  factory DataManager() => _instance;
  DataManager._internal();

  final Map<String, ClassInfo> classesById = {};
  final List<Student> studentsList = [];

  final ValueNotifier<List<ClassInfo>> classesNotifier = ValueNotifier<List<ClassInfo>>([]);
  final ValueNotifier<List<Student>> studentsNotifier = ValueNotifier<List<Student>>([]);

  List<ClassInfo> get classes => classesNotifier.value;
  List<Student> get students => studentsNotifier.value;

  @override
  Future<void> saveData() async {
    final data = {
      'classes': classesById.values.map((c) => c.toJson()).toList(),
      'students': studentsList.map((s) => s.toJson()).toList(),
    };
    html.window.localStorage['academy_data'] = jsonEncode(data);
  }

  @override
  Future<void> loadData() async {
    try {
      final jsonString = html.window.localStorage['academy_data'];
      if (jsonString != null) {
        final data = jsonDecode(jsonString) as Map<String, dynamic>;
        
        classesById.clear();
        final classesList = (data['classes'] as List).cast<Map<String, dynamic>>();
        for (final classData in classesList) {
          final classInfo = ClassInfo.fromJson(classData);
          classesById[classInfo.id] = classInfo;
        }

        studentsList.clear();
        final students = (data['students'] as List).cast<Map<String, dynamic>>();
        for (final studentData in students) {
          final student = Student.fromJson(studentData, classesById);
          studentsList.add(student);
        }
        notifyListeners();
      }
    } catch (e) {
      print('Error loading data: $e');
    }
  }

  void addClass(ClassInfo classInfo) {
    classesById[classInfo.id] = classInfo;
    notifyListeners();
    saveData();
  }

  void updateClass(ClassInfo classInfo) {
    classesById[classInfo.id] = classInfo;
    notifyListeners();
    saveData();
  }

  void deleteClass(String classId) {
    classesById.remove(classId);
    for (final student in studentsList) {
      if (student.classInfo?.id == classId) {
        student.classInfo = null;
      }
    }
    notifyListeners();
    saveData();
  }

  void addStudent(Student student) {
    studentsList.add(student);
    notifyListeners();
    saveData();
  }

  void updateStudent(Student oldStudent, Student newStudent) {
    final index = studentsList.indexOf(oldStudent);
    if (index != -1) {
      studentsList[index] = newStudent;
      notifyListeners();
      saveData();
    }
  }

  void deleteStudent(Student student) {
    studentsList.remove(student);
    notifyListeners();
    saveData();
  }

  void moveStudent(Student student, ClassInfo? newClass) {
    final index = studentsList.indexOf(student);
    if (index != -1) {
      studentsList[index] = student.copyWith(classInfo: newClass);
      notifyListeners();
      saveData();
    }
  }

  void notifyListeners() {
    classesNotifier.value = classesById.values.toList();
    studentsNotifier.value = List.unmodifiable(studentsList);
  }
} 