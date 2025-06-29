import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/student.dart';
import '../models/group_info.dart';
import 'data_manager_base.dart';

class DataManager extends DataManagerBase {
  static final DataManager _singleton = DataManager._internal();
  factory DataManager() => _singleton;
  
  DataManager._internal() {
    initInstance();
  }

  final Map<String, GroupInfo> groupsById = {};
  final List<Student> studentsList = [];

  final ValueNotifier<List<GroupInfo>> groupsNotifier = ValueNotifier<List<GroupInfo>>([]);
  final ValueNotifier<List<Student>> studentsNotifier = ValueNotifier<List<Student>>([]);

  List<GroupInfo> get groups => groupsNotifier.value;
  List<Student> get students => studentsNotifier.value;

  @override
  Future<void> saveData() async {
    try {
      // 클래스 정보 저장
      final groupsData = {
        'groups': groupsById.values.map((c) => c.toJson()).toList(),
      };
      html.window.localStorage['groups'] = jsonEncode(groupsData);

      // 학생 정보 저장
      final studentsData = {
        'students': studentsList.map((s) => s.toJson()).toList(),
      };
      html.window.localStorage['students'] = jsonEncode(studentsData);
    } catch (e) {
      print('Error saving data: $e');
    }
  }

  @override
  Future<void> loadData() async {
    try {
      // 클래스 정보 로드
      final groupsJson = html.window.localStorage['groups'];
      if (groupsJson != null) {
        final data = jsonDecode(groupsJson) as Map<String, dynamic>;
        
        groupsById.clear();
        final groupsList = (data['groups'] as List).cast<Map<String, dynamic>>();
        for (final groupData in groupsList) {
          final groupInfo = GroupInfo.fromJson(groupData);
          groupsById[groupInfo.id] = groupInfo;
        }
      } else {
        // 기본 클래스 생성
        final defaultGroup = GroupInfo(
          id: '1',
          name: '기본반',
          description: '기본 학습반',
          color: const Color(0xFF1976D2),
          capacity: 10,
        );
        groupsById[defaultGroup.id] = defaultGroup;
        await saveData();
      }

      // 학생 정보 로드
      final studentsJson = html.window.localStorage['students'];
      if (studentsJson != null) {
        final data = jsonDecode(studentsJson) as Map<String, dynamic>;
        
        studentsList.clear();
        final students = (data['students'] as List).cast<Map<String, dynamic>>();
        for (final studentData in students) {
          final student = Student.fromJson(studentData, groupsById);
          studentsList.add(student);
        }
      }

      notifyListeners();
    } catch (e) {
      print('Error loading data: $e');
    }
  }

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