import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../models/student.dart';
import '../models/class_info.dart';
import 'data_manager_base.dart';

class DataManager extends DataManagerBase {
  static final DataManager _singleton = DataManager._internal();
  factory DataManager() => _singleton;
  
  DataManager._internal() {
    initInstance();
  }

  final Map<String, ClassInfo> classesById = {};
  final List<Student> studentsList = [];

  final ValueNotifier<List<ClassInfo>> classesNotifier = ValueNotifier<List<ClassInfo>>([]);
  final ValueNotifier<List<Student>> studentsNotifier = ValueNotifier<List<Student>>([]);

  List<ClassInfo> get classes => classesNotifier.value;
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
        'classes': classesById.values.map((c) => c.toJson()).toList(),
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
        'classes': classesById.values.map((c) => c.toJson()).toList(),
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
        
        classesById.clear();
        final classesList = (data['classes'] as List).cast<Map<String, dynamic>>();
        for (final classData in classesList) {
          final classInfo = ClassInfo.fromJson(classData);
          classesById[classInfo.id] = classInfo;
        }
      } else {
        // 기본 클래스 생성
        final defaultClass = ClassInfo(
          id: '1',
          name: '기본반',
          description: '기본 학습반',
          color: const Color(0xFF1976D2),
          capacity: 10,
        );
        classesById[defaultClass.id] = defaultClass;
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
          final student = Student.fromJson(studentData, classesById);
          studentsList.add(student);
        }
      }

      notifyListeners();
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

  void _notifyListeners() {
    classesNotifier.value = _classesById.values.toList();
    studentsNotifier.value = List.unmodifiable(_studentsList);
  }
} 