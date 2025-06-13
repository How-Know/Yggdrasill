import 'package:flutter/foundation.dart';
import '../models/student.dart';
import '../models/class_info.dart';

abstract class DataManagerBase {
  static DataManagerBase? _instance;
  static bool _initialized = false;

  final Map<String, ClassInfo> classesById = {};
  final List<Student> studentsList = [];

  final ValueNotifier<List<ClassInfo>> classesNotifier = ValueNotifier<List<ClassInfo>>([]);
  final ValueNotifier<List<Student>> studentsNotifier = ValueNotifier<List<Student>>([]);

  List<ClassInfo> get classes => classesNotifier.value;
  List<Student> get students => studentsNotifier.value;

  Future<void> initialize() async {
    if (_initialized) return;
    await loadData();
    _initialized = true;
  }

  Future<void> saveData();
  Future<void> loadData();

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