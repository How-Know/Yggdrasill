import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import '../models/academy_settings.dart';
import '../models/group_info.dart';
import '../models/operating_hours.dart';
import '../models/student.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'dart:convert';
import '../models/student_time_block.dart';

class AcademyDbService {
  static final AcademyDbService instance = AcademyDbService._internal();
  AcademyDbService._internal();

  static Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = join(documentsDirectory.path, 'academy.db');
    return await openDatabase(
      path,
      version: 4,
      onCreate: (Database db, int version) async {
        await db.execute('''
          CREATE TABLE academy_settings (
            id INTEGER PRIMARY KEY,
            name TEXT,
            slogan TEXT,
            default_capacity INTEGER,
            lesson_duration INTEGER,
            payment_type TEXT,
            logo BLOB
          )
        ''');
        await db.execute('''
          CREATE TABLE groups (
            id TEXT PRIMARY KEY,
            name TEXT,
            description TEXT,
            capacity INTEGER,
            duration INTEGER,
            color INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE students (
            id TEXT PRIMARY KEY,
            name TEXT,
            school TEXT,
            education_level INTEGER,
            grade INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE students_basic_info (
            student_id TEXT PRIMARY KEY,
            phone_number TEXT,
            parent_phone_number TEXT,
            registration_date TEXT,
            weekly_class_count INTEGER,
            group_id TEXT,
            FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE
          )
        ''');
        await db.execute('''
          CREATE TABLE operating_hours (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            day_of_week INTEGER,
            start_time TEXT,
            end_time TEXT,
            break_times TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS teachers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            role INTEGER,
            contact TEXT,
            email TEXT,
            description TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE student_time_blocks (
            id TEXT PRIMARY KEY,
            student_id TEXT,
            day_index INTEGER,
            start_time TEXT,
            duration INTEGER,
            created_at TEXT
          )
        ''');
      },
      onUpgrade: (Database db, int oldVersion, int newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS groups (
              id TEXT PRIMARY KEY,
              name TEXT,
              description TEXT,
              capacity INTEGER,
              duration INTEGER,
              color INTEGER
            )
          ''');
        }
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS students_basic_info (
              student_id TEXT PRIMARY KEY,
              phone_number TEXT,
              parent_phone_number TEXT,
              registration_date TEXT,
              weekly_class_count INTEGER,
              group_id TEXT,
              FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE
            )
          ''');
          final columns = await db.rawQuery("PRAGMA table_info(students)");
          final hasPhone = columns.any((col) => col['name'] == 'phone_number');
          if (hasPhone) {
            await db.execute('''
              INSERT OR IGNORE INTO students_basic_info (student_id, phone_number, parent_phone_number, registration_date, weekly_class_count, group_id)
              SELECT id, phone_number, parent_phone_number, registration_date, weekly_class_count, group_id FROM students
            ''');
          }
        }
        if (oldVersion < 4) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS student_time_blocks (
              id TEXT PRIMARY KEY,
              student_id TEXT,
              day_index INTEGER,
              start_time TEXT,
              duration INTEGER,
              created_at TEXT
            )
          ''');
        }
        final columns = await db.rawQuery("PRAGMA table_info(students)");
        final hasGroupId = columns.any((col) => col['name'] == 'group_id');
        if (!hasGroupId) {
          await db.execute("ALTER TABLE students ADD COLUMN group_id TEXT");
        }
        await db.execute('''
          CREATE TABLE IF NOT EXISTS teachers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            role INTEGER,
            contact TEXT,
            email TEXT,
            description TEXT
          )
        ''');
      },
    );
  }

  Future<void> saveAcademySettings(AcademySettings settings, String paymentType) async {
    try {
      final dbClient = await db;
      print('[DB] saveAcademySettings: $settings, paymentType: $paymentType');
      await dbClient.insert(
        'academy_settings',
        {
          'id': 1,
          'name': settings.name,
          'slogan': settings.slogan,
          'default_capacity': settings.defaultCapacity,
          'lesson_duration': settings.lessonDuration,
          'payment_type': paymentType,
          'logo': settings.logo,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e, st) {
      print('[DB][ERROR] saveAcademySettings: $e\n$st');
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> getAcademySettings() async {
    final dbClient = await db;
    final result = await dbClient.query('academy_settings', where: 'id = ?', whereArgs: [1]);
    if (result.isNotEmpty) {
      return result.first;
    }
    return null;
  }

  Future<void> saveTeachers(List teachers) async {
    try {
      final dbClient = await db;
      print('[DB] saveTeachers: ${teachers.length}명');
      await dbClient.delete('teachers');
      for (final t in teachers) {
        print('[DB] insert teacher: $t');
        await dbClient.insert('teachers', {
          'name': t.name,
          'role': t.role.index,
          'contact': t.contact,
          'email': t.email,
          'description': t.description,
        });
      }
    } catch (e, st) {
      print('[DB][ERROR] saveTeachers: $e\n$st');
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> getTeachers() async {
    final dbClient = await db;
    return await dbClient.query('teachers');
  }

  Future<void> saveGroups(List<GroupInfo> groups) async {
    final dbClient = await db;
    await dbClient.delete('groups');
    for (final g in groups) {
      await dbClient.insert('groups', {
        'id': g.id,
        'name': g.name,
        'description': g.description,
        'capacity': g.capacity,
        'duration': g.duration,
        'color': g.color.value,
      });
    }
  }

  Future<List<GroupInfo>> getGroups() async {
    final dbClient = await db;
    final result = await dbClient.query('groups');
    return result.map((row) => GroupInfo(
      id: row['id'] as String,
      name: row['name'] as String,
      description: row['description'] as String,
      capacity: row['capacity'] as int,
      duration: row['duration'] as int,
      color: Color(row['color'] as int),
    )).toList();
  }

  Future<void> addGroup(GroupInfo group) async {
    final dbClient = await db;
    await dbClient.insert('groups', {
      'id': group.id,
      'name': group.name,
      'description': group.description,
      'capacity': group.capacity,
      'duration': group.duration,
      'color': group.color.value,
    });
  }

  Future<void> updateGroup(GroupInfo group) async {
    final dbClient = await db;
    await dbClient.update('groups', {
      'name': group.name,
      'description': group.description,
      'capacity': group.capacity,
      'duration': group.duration,
      'color': group.color.value,
    }, where: 'id = ?', whereArgs: [group.id]);
  }

  Future<void> deleteGroup(String groupId) async {
    final dbClient = await db;
    await dbClient.delete('groups', where: 'id = ?', whereArgs: [groupId]);
  }

  Future<void> saveOperatingHours(List<OperatingHours> hours) async {
    try {
      final dbClient = await db;
      print('[DB] saveOperatingHours: ${hours.length}개');
      await dbClient.delete('operating_hours');
      for (final h in hours) {
        final breakTimesJson = h.breakTimes.isNotEmpty ? jsonEncode(h.breakTimes.map((b) => b.toJson()).toList()) : '[]';
        print('[DB] insert operating hour: day=${h.dayOfWeek}, start=${h.startTime}, end=${h.endTime}, breakTimes=$breakTimesJson');
        await dbClient.insert('operating_hours', {
          'day_of_week': h.dayOfWeek,
          'start_time': h.startTime.toIso8601String(),
          'end_time': h.endTime.toIso8601String(),
          'break_times': breakTimesJson,
        });
      }
    } catch (e, st) {
      print('[DB][ERROR] saveOperatingHours: $e\n$st');
      rethrow;
    }
  }

  Future<List<OperatingHours>> getOperatingHours() async {
    final dbClient = await db;
    final result = await dbClient.query('operating_hours');
    print('[DB] getOperatingHours: ${result.length}개');
    for (final row in result) {
      print('[DB] row: $row');
    }
    return result.map((row) => OperatingHours(
      startTime: DateTime.parse(row['start_time'] as String),
      endTime: DateTime.parse(row['end_time'] as String),
      breakTimes: (jsonDecode(row['break_times'] as String) as List)
        .map((b) => BreakTime.fromJson(b)).toList(),
      dayOfWeek: row['day_of_week'] as int,
    )).toList();
  }

  Future<void> addStudent(Student student) async {
    try {
      final dbClient = await db;
      print('[DB] addStudent: ' + student.toDb().toString());
      await dbClient.insert('students', student.toDb(), conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e, st) {
      print('[DB][ERROR] addStudent: $e\n$st');
      rethrow;
    }
  }

  Future<void> updateStudent(Student student) async {
    print('[DB] updateStudent:  [33m${student.name} [0m, id= [36m${student.id} [0m');
    final dbClient = await db;
    await dbClient.update('students', student.toDb(), where: 'id = ?', whereArgs: [student.id]);
  }

  Future<void> deleteStudent(String id) async {
    final dbClient = await db;
    await dbClient.delete('students', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Student>> getStudents() async {
    final dbClient = await db;
    final result = await dbClient.query('students');
    print('DB에서 학생 불러오기: ' + result.toString());
    return result.map((row) => Student.fromDb(row)).toList();
  }

  Future<void> saveStudents(List<Student> students) async {
    final dbClient = await db;
    await dbClient.delete('students');
    for (final s in students) {
      await dbClient.insert('students', s.toDb());
    }
  }

  Future<void> insertStudentBasicInfo(Map<String, dynamic> info) async {
    final dbClient = await db;
    await dbClient.insert('students_basic_info', info, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getStudentBasicInfo(String studentId) async {
    final dbClient = await db;
    final result = await dbClient.query('students_basic_info', where: 'student_id = ?', whereArgs: [studentId]);
    if (result.isNotEmpty) return result.first;
    return null;
  }

  Future<void> updateStudentBasicInfo(String studentId, Map<String, dynamic> info) async {
    print('[DB] updateStudentBasicInfo:  [33mstudentId=$studentId [0m, groupId= [36m${info['group_id']} [0m');
    final dbClient = await db;
    await dbClient.update('students_basic_info', info, where: 'student_id = ?', whereArgs: [studentId]);
  }

  Future<void> deleteStudentBasicInfo(String studentId) async {
    final dbClient = await db;
    await dbClient.delete('students_basic_info', where: 'student_id = ?', whereArgs: [studentId]);
  }

  Future<void> addStudentTimeBlock(StudentTimeBlock block) async {
    final dbClient = await db;
    print('[DB] addStudentTimeBlock: ${block.toJson()}');
    await dbClient.insert(
      'student_time_blocks',
      block.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<StudentTimeBlock>> getStudentTimeBlocks() async {
    final dbClient = await db;
    final result = await dbClient.query('student_time_blocks');
    return result.map((row) => StudentTimeBlock(
      id: row['id'] as String,
      studentId: row['student_id'] as String,
      dayIndex: row['day_index'] as int,
      startTime: DateTime.parse(row['start_time'] as String),
      duration: Duration(minutes: row['duration'] as int),
      createdAt: DateTime.parse(row['created_at'] as String),
      setId: row['set_id'] as String?, // 추가
      number: row['number'] as int?,   // 추가
    )).toList();
  }

  Future<void> saveStudentTimeBlocks(List<StudentTimeBlock> blocks) async {
    final dbClient = await db;
    await dbClient.delete('student_time_blocks');
    for (final block in blocks) {
      await dbClient.insert('student_time_blocks', {
        'id': block.id,
        'student_id': block.studentId,
        'day_index': block.dayIndex,
        'start_time': block.startTime.toIso8601String(),
        'duration': block.duration.inMinutes,
        'created_at': block.createdAt.toIso8601String(),
      });
    }
  }

  Future<void> deleteStudentTimeBlock(String id) async {
    final dbClient = await db;
    await dbClient.delete('student_time_blocks', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteStudentTimeBlocksByStudentId(String studentId) async {
    final dbClient = await db;
    await dbClient.delete('student_time_blocks', where: 'student_id = ?', whereArgs: [studentId]);
  }

  Future<void> bulkAddStudentTimeBlocks(List<StudentTimeBlock> blocks) async {
    final dbClient = await db;
    await dbClient.transaction((txn) async {
      for (final block in blocks) {
        await txn.insert(
          'student_time_blocks',
          block.toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<void> bulkDeleteStudentTimeBlocks(List<String> blockIds) async {
    final dbClient = await db;
    await dbClient.transaction((txn) async {
      for (final id in blockIds) {
        await txn.delete('student_time_blocks', where: 'id = ?', whereArgs: [id]);
      }
    });
  }
} 