import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show protected;
import '../models/student.dart';
import '../models/group_info.dart';

abstract class DataManagerBase {
  static DataManagerBase? instance;
  static bool _initialized = false;

  final Map<String, GroupInfo> groupsById = {};
  final List<Student> studentsList = [];

  final ValueNotifier<List<GroupInfo>> groupsNotifier = ValueNotifier<List<GroupInfo>>([]);
  final ValueNotifier<List<Student>> studentsNotifier = ValueNotifier<List<Student>>([]);

  List<GroupInfo> get groups => groupsNotifier.value;
  List<Student> get students => studentsNotifier.value;

  @protected
  void initInstance() {
    if (instance != null) {
      throw StateError('DataManager instance already initialized');
    }
    instance = this;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    await loadData();
    _initialized = true;
  }

  Future<void> saveData();
  Future<void> loadData();

  void addGroup(GroupInfo groupInfo) {
    groupsById[groupInfo.id] = groupInfo;
    notifyListeners();
    saveData();
  }

  void updateGroup(GroupInfo groupInfo) {
    groupsById[groupInfo.id] = groupInfo;
    notifyListeners();
    saveData();
  }

  void deleteGroup(String groupId) {
    groupsById.remove(groupId);
    for (final student in studentsList) {
      if (student.groupInfo?.id == groupId) {
        student.groupInfo = null;
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

  void moveStudent(Student student, GroupInfo? newGroup) {
    final index = studentsList.indexOf(student);
    if (index != -1) {
      studentsList[index] = student.copyWith(groupInfo: newGroup);
      notifyListeners();
      saveData();
    }
  }

  void notifyListeners() {
    groupsNotifier.value = groupsById.values.toList();
    studentsNotifier.value = List.unmodifiable(studentsList);
  }
} 