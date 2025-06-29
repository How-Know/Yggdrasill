import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
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

  Future<String> get _localPath async {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  Future<File> get _localFile async {
    final path = await _localPath;
    return File('$path/academy_data.json');
  }

  @override
  Future<void> saveData() async {
    if (Platform.isWindows) {
      // Windows에서는 실행 파일과 같은 디렉토리에 저장
      final exePath = Platform.resolvedExecutable;
      final dirPath = path.dirname(exePath);
      final dataPath = path.join(dirPath, 'data');
      
      // data 디렉토리가 없으면 생성
      final dataDir = Directory(dataPath);
      if (!await dataDir.exists()) {
        await dataDir.create();
      }

      // 클래스 정보 저장
      final classesFile = File(path.join(dataPath, 'classes.json'));
      final classesData = {
        'classes': groupsById.values.map((c) => c.toJson()).toList(),
      };
      await classesFile.writeAsString(jsonEncode(classesData));

      // 학생 정보 저장
      final studentsFile = File(path.join(dataPath, 'students.json'));
      final studentsData = {
        'students': studentsList.map((s) => s.toJson()).toList(),
      };
      await studentsFile.writeAsString(jsonEncode(studentsData));
    } else {
      // 다른 플랫폼에서는 기존 방식 사용
      final directory = await getApplicationDocumentsDirectory();
      
      // 클래스 정보 저장
      final classesFile = File('${directory.path}/classes.json');
      final classesData = {
        'classes': groupsById.values.map((c) => c.toJson()).toList(),
      };
      await classesFile.writeAsString(jsonEncode(classesData));

      // 학생 정보 저장
      final studentsFile = File('${directory.path}/students.json');
      final studentsData = {
        'students': studentsList.map((s) => s.toJson()).toList(),
      };
      await studentsFile.writeAsString(jsonEncode(studentsData));
    }
  }

  @override
  Future<void> loadData() async {
    try {
      late final Directory directory;
      if (Platform.isWindows) {
        final exePath = Platform.resolvedExecutable;
        final dirPath = path.dirname(exePath);
        directory = Directory(path.join(dirPath, 'data'));
        
        // data 디렉토리가 없으면 생성
        if (!await directory.exists()) {
          await directory.create();
        }
      } else {
        directory = await getApplicationDocumentsDirectory();
      }

      // 클래스 정보 로드
      final classesFile = File('${directory.path}/classes.json');
      if (await classesFile.exists()) {
        final jsonString = await classesFile.readAsString();
        final data = jsonDecode(jsonString) as Map<String, dynamic>;
        
        groupsById.clear();
        final groupsList = (data['classes'] as List).cast<Map<String, dynamic>>();
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
      final studentsFile = File('${directory.path}/students.json');
      if (await studentsFile.exists()) {
        final jsonString = await studentsFile.readAsString();
        final data = jsonDecode(jsonString) as Map<String, dynamic>;
        
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

  void _notifyListeners() {
    groupsNotifier.value = _groupsById.values.toList();
    studentsNotifier.value = List.unmodifiable(_studentsList);
  }
} 