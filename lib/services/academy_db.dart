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
import '../models/self_study_time_block.dart';
import '../models/class_info.dart';
import '../models/payment_record.dart';

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
    return await openDatabaseWithLog(
      path,
      version: 10,
      onCreate: (Database db, int version) async {
        await db.execute('''
          CREATE TABLE academy_settings (
            id INTEGER PRIMARY KEY,
            name TEXT,
            slogan TEXT,
            default_capacity INTEGER,
            lesson_duration INTEGER,
            payment_type TEXT,
            logo BLOB,
            session_cycle INTEGER DEFAULT 1 -- [추가] 수강 횟수
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
            student_payment_type TEXT,
            student_session_cycle INTEGER,
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
            group_id TEXT,
            day_index INTEGER,
            start_time TEXT,
            duration INTEGER,
            created_at TEXT,
            set_id TEXT,
            number INTEGER,
            session_type_id TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE self_study_time_blocks (
            id TEXT PRIMARY KEY,
            student_id TEXT,
            day_index INTEGER,
            start_time TEXT,
            duration INTEGER,
            created_at TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE classes (
            id TEXT PRIMARY KEY,
            name TEXT,
            capacity INTEGER,
            description TEXT,
            color INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE payment_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            student_id TEXT,
            cycle INTEGER,
            due_date INTEGER,
            paid_date INTEGER,
            FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE
          )
        ''');
        await db.execute('''
          CREATE TABLE attendance_records (
            id TEXT PRIMARY KEY,
            student_id TEXT,
            date TEXT,
            class_date_time TEXT,
            class_name TEXT,
            is_present INTEGER,
            arrival_time TEXT,
            departure_time TEXT,
            notes TEXT,
            created_at TEXT,
            updated_at TEXT,
            FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE
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
        if (oldVersion < 5) {
          // [추가] session_cycle 컬럼이 없으면 추가
          final columns = await db.rawQuery("PRAGMA table_info(academy_settings)");
          final hasSessionCycle = columns.any((col) => col['name'] == 'session_cycle');
          if (!hasSessionCycle) {
            await db.execute("ALTER TABLE academy_settings ADD COLUMN session_cycle INTEGER DEFAULT 1");
          }
        }
        if (oldVersion < 6) {
          await db.execute("ALTER TABLE students_basic_info ADD COLUMN student_payment_type TEXT;");
          await db.execute("ALTER TABLE students_basic_info ADD COLUMN student_session_cycle INTEGER;");
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
        await db.execute('''
          CREATE TABLE IF NOT EXISTS self_study_time_blocks (
            id TEXT PRIMARY KEY,
            student_id TEXT,
            day_index INTEGER,
            start_time TEXT,
            duration INTEGER,
            created_at TEXT
          )
        ''');
        if (oldVersion < 7) {
          // v7: student_time_blocks에 session_type_id 컬럼 추가
          await db.execute('''
            ALTER TABLE student_time_blocks ADD COLUMN session_type_id TEXT
          ''');
        }
        if (oldVersion < 8) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS classes (
              id TEXT PRIMARY KEY,
              name TEXT,
              capacity INTEGER,
              description TEXT,
              color INTEGER
            )
          ''');
        }
        if (oldVersion < 9) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS payment_records (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              student_id TEXT,
              cycle INTEGER,
              due_date INTEGER,
              paid_date INTEGER,
              FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE
            )
          ''');
        }
        if (oldVersion < 10) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS attendance_records (
              id TEXT PRIMARY KEY,
              student_id TEXT,
              date TEXT,
              class_date_time TEXT,
              class_name TEXT,
              is_present INTEGER,
              arrival_time TEXT,
              departure_time TEXT,
              notes TEXT,
              created_at TEXT,
              updated_at TEXT,
              FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE
            )
          ''');
        }
      },
    );
  }

  Future<Database> openDatabaseWithLog(String path, {int version = 1, OnDatabaseCreateFn? onCreate, OnDatabaseVersionChangeFn? onUpgrade}) async {
    print('[DB][경로] 실제 사용 DB 파일 경로: $path');
    return await openDatabase(path, version: version, onCreate: onCreate, onUpgrade: onUpgrade);
  }

  Future<void> saveAcademySettings(AcademySettings settings, String paymentType) async {
    try {
      final dbClient = await db;
      // paymentType 문자열 변환
      String paymentTypeStr = paymentType;
      if (paymentType == 'perClass' || paymentType == 'session') paymentTypeStr = 'session';
      if (paymentType == 'monthly') paymentTypeStr = 'monthly';
      print('[DB] saveAcademySettings: $settings, paymentType: $paymentTypeStr');
      await dbClient.insert(
        'academy_settings',
        {
          'id': 1,
          'name': settings.name,
          'slogan': settings.slogan,
          'default_capacity': settings.defaultCapacity,
          'lesson_duration': settings.lessonDuration,
          'payment_type': paymentTypeStr,
          'logo': settings.logo,
          'session_cycle': settings.sessionCycle, // [추가]
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

  Future<void> saveOperatingHours(List<OperatingHours> hoursList) async {
    final dbClient = await db;
    await dbClient.delete('operating_hours');
    await dbClient.delete('break_times');
    for (final h in hoursList) {
      // operating_hours 저장
      final opId = await dbClient.insert('operating_hours', {
        'day_of_week': h.dayOfWeek,
        'start_hour': h.startHour,
        'start_minute': h.startMinute,
        'end_hour': h.endHour,
        'end_minute': h.endMinute,
      });
      // break_times 저장
      for (final b in h.breakTimes) {
        await dbClient.insert('break_times', {
          'operating_hour_id': opId,
          'start_hour': b.startHour,
          'start_minute': b.startMinute,
          'end_hour': b.endHour,
          'end_minute': b.endMinute,
        });
      }
    }
  }

  Future<List<OperatingHours>> getOperatingHours() async {
    final dbClient = await db;
    final opRows = await dbClient.query('operating_hours');
    List<OperatingHours> result = [];
    for (final row in opRows) {
      final opId = row['id'] as int;
      final breakRows = await dbClient.query('break_times', where: 'operating_hour_id = ?', whereArgs: [opId]);
      final breakTimes = breakRows.map((b) => BreakTime(
        startHour: b['start_hour'] as int,
        startMinute: b['start_minute'] as int,
        endHour: b['end_hour'] as int,
        endMinute: b['end_minute'] as int,
      )).toList();
      result.add(OperatingHours(
        id: opId,
        dayOfWeek: row['day_of_week'] as int,
        startHour: row['start_hour'] as int,
        startMinute: row['start_minute'] as int,
        endHour: row['end_hour'] as int,
        endMinute: row['end_minute'] as int,
        breakTimes: breakTimes,
      ));
    }
    return result;
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
      {
        'id': block.id,
        'student_id': block.studentId,
        'group_id': block.groupId,
        'day_index': block.dayIndex,
        'start_hour': block.startHour,
        'start_minute': block.startMinute,
        'duration': block.duration.inMinutes,
        'created_at': block.createdAt.toIso8601String(),
        'set_id': block.setId,
        'number': block.number,
        'session_type_id': block.sessionTypeId,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<StudentTimeBlock>> getStudentTimeBlocks() async {
    final dbClient = await db;
    final result = await dbClient.query('student_time_blocks');
    return result.map((row) => StudentTimeBlock(
      id: row['id'] as String,
      studentId: row['student_id'] as String,
      groupId: row['group_id'] as String?,
      dayIndex: row['day_index'] as int? ?? 0,
      startHour: row['start_hour'] as int? ?? 0,
      startMinute: row['start_minute'] as int? ?? 0,
      duration: Duration(minutes: row['duration'] as int? ?? 0),
      createdAt: DateTime.parse(row['created_at'] as String),
      setId: row['set_id'] as String?,
      number: row['number'] as int?,
      sessionTypeId: row['session_type_id'] as String?,
    )).toList();
  }

  Future<void> saveStudentTimeBlocks(List<StudentTimeBlock> blocks) async {
    final dbClient = await db;
    await dbClient.delete('student_time_blocks');
    for (final block in blocks) {
      await dbClient.insert('student_time_blocks', {
        'id': block.id,
        'student_id': block.studentId,
        'group_id': block.groupId,
        'day_index': block.dayIndex,
        'start_hour': block.startHour,
        'start_minute': block.startMinute,
        'duration': block.duration.inMinutes,
        'created_at': block.createdAt.toIso8601String(),
        'set_id': block.setId,
        'number': block.number,
        'session_type_id': block.sessionTypeId,
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
          {
            'id': block.id,
            'student_id': block.studentId,
            'group_id': block.groupId,
            'day_index': block.dayIndex,
            'start_hour': block.startHour,
            'start_minute': block.startMinute,
            'duration': block.duration.inMinutes,
            'created_at': block.createdAt.toIso8601String(),
            'set_id': block.setId,
            'number': block.number,
            'session_type_id': block.sessionTypeId,
          },
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

  Future<void> addSelfStudyTimeBlock(SelfStudyTimeBlock block) async {
    final dbClient = await db;
    await dbClient.insert('self_study_time_blocks', {
      'id': block.id,
      'student_id': block.studentId,
      'day_index': block.dayIndex,
      'start_hour': block.startHour,
      'start_minute': block.startMinute,
      'duration': block.duration.inMinutes,
      'created_at': block.createdAt.toIso8601String(),
      'set_id': block.setId,
      'number': block.number,
    });
  }

  Future<List<SelfStudyTimeBlock>> getSelfStudyTimeBlocks() async {
    final dbClient = await db;
    final result = await dbClient.query('self_study_time_blocks');
    return result.map((row) => SelfStudyTimeBlock(
      id: row['id'] as String,
      studentId: row['student_id'] as String,
      dayIndex: row['day_index'] as int,
      startHour: row['start_hour'] as int,
      startMinute: row['start_minute'] as int,
      duration: Duration(minutes: row['duration'] as int),
      createdAt: DateTime.parse(row['created_at'] as String),
      setId: row['set_id'] as String?,
      number: row['number'] as int?,
    )).toList();
  }

  Future<void> saveSelfStudyTimeBlocks(List<SelfStudyTimeBlock> blocks) async {
    final dbClient = await db;
    await dbClient.delete('self_study_time_blocks');
    for (final block in blocks) {
      await dbClient.insert('self_study_time_blocks', {
        'id': block.id,
        'student_id': block.studentId,
        'day_index': block.dayIndex,
        'start_hour': block.startHour,
        'start_minute': block.startMinute,
        'duration': block.duration.inMinutes,
        'created_at': block.createdAt.toIso8601String(),
        'set_id': block.setId,
        'number': block.number,
      });
    }
  }

  Future<void> deleteSelfStudyTimeBlock(String id) async {
    final dbClient = await db;
    await dbClient.delete('self_study_time_blocks', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateSelfStudyTimeBlock(String id, SelfStudyTimeBlock newBlock) async {
    final dbClient = await db;
    await dbClient.update(
      'self_study_time_blocks',
      newBlock.toDb(),
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteSelfStudyTimeBlocksByStudentId(String studentId) async {
    final dbClient = await db;
    await dbClient.delete('self_study_time_blocks', where: 'student_id = ?', whereArgs: [studentId]);
  }

  Future<void> bulkAddSelfStudyTimeBlocks(List<SelfStudyTimeBlock> blocks) async {
    final dbClient = await db;
    await dbClient.transaction((txn) async {
      for (final block in blocks) {
        await txn.insert(
          'self_study_time_blocks',
          {
            'id': block.id,
            'student_id': block.studentId,
            'day_index': block.dayIndex,
            'start_hour': block.startHour,
            'start_minute': block.startMinute,
            'duration': block.duration.inMinutes,
            'created_at': block.createdAt.toIso8601String(),
            'set_id': block.setId,
            'number': block.number,
          },
        );
      }
    });
  }

  Future<void> bulkDeleteSelfStudyTimeBlocks(List<String> blockIds) async {
    final dbClient = await db;
    await dbClient.transaction((txn) async {
      for (final id in blockIds) {
        await txn.delete('self_study_time_blocks', where: 'id = ?', whereArgs: [id]);
      }
    });
  }

  Future<void> updateStudentTimeBlock(String id, StudentTimeBlock newBlock) async {
    final dbClient = await db;
    // print('[DEBUG][AcademyDbService.updateStudentTimeBlock] id=$id, newBlock=${newBlock.toJson()}');
    final result = await dbClient.update(
      'student_time_blocks',
      newBlock.toJson(),
      where: 'id = ?',
      whereArgs: [id],
    );
    // print('[DEBUG][AcademyDbService.updateStudentTimeBlock] update result: $result');
  }

  // ClassInfo CRUD
  Future<void> addClass(ClassInfo c) async {
    final dbClient = await db;
    await dbClient.insert('classes', c.toJson(), conflictAlgorithm: ConflictAlgorithm.replace);
  }
  Future<void> updateClass(ClassInfo c) async {
    final dbClient = await db;
    await dbClient.update('classes', c.toJson(), where: 'id = ?', whereArgs: [c.id]);
  }
  Future<void> deleteClass(String id) async {
    final dbClient = await db;
    await dbClient.delete('classes', where: 'id = ?', whereArgs: [id]);
  }
  Future<List<ClassInfo>> getClasses() async {
    final dbClient = await db;
    final result = await dbClient.query('classes');
    return result.map((row) => ClassInfo.fromJson(row)).toList();
  }
  Future<void> deleteAllClasses() async {
    final dbClient = await db;
    await dbClient.delete('classes');
  }

  // Payment Records 관련 메소드들
  Future<List<PaymentRecord>> getPaymentRecords() async {
    final dbClient = await db;
    final result = await dbClient.query('payment_records');
    return result.map((map) => PaymentRecord.fromMap(map)).toList();
  }

  Future<PaymentRecord> addPaymentRecord(PaymentRecord record) async {
    final dbClient = await db;
    final id = await dbClient.insert(
      'payment_records',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return record.copyWith(id: id);
  }

  Future<void> updatePaymentRecord(PaymentRecord record) async {
    final dbClient = await db;
    await dbClient.update(
      'payment_records',
      record.toMap(),
      where: 'id = ?',
      whereArgs: [record.id],
    );
  }

  Future<void> deletePaymentRecord(int id) async {
    final dbClient = await db;
    await dbClient.delete(
      'payment_records',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<PaymentRecord>> getPaymentRecordsForStudent(String studentId) async {
    final dbClient = await db;
    final result = await dbClient.query(
      'payment_records',
      where: 'student_id = ?',
      whereArgs: [studentId],
    );
    return result.map((map) => PaymentRecord.fromMap(map)).toList();
  }

  // payment_records 테이블 존재 여부 확인 및 생성
  Future<void> ensurePaymentRecordsTable() async {
    final dbClient = await db;
    
    try {
      // 테이블 존재 여부 확인
      final result = await dbClient.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='payment_records'"
      );
      
      if (result.isEmpty) {
        print('[DEBUG] payment_records 테이블이 존재하지 않음. 생성 중...');
        
        // 테이블 생성
        await dbClient.execute('''
          CREATE TABLE payment_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            student_id TEXT,
            cycle INTEGER,
            due_date INTEGER,
            paid_date INTEGER,
            FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE
          )
        ''');
        
        print('[DEBUG] payment_records 테이블 생성 완료');
      } else {
        print('[DEBUG] payment_records 테이블이 이미 존재함');
      }
    } catch (e) {
      print('[ERROR] payment_records 테이블 확인/생성 중 오류: $e');
      rethrow;
    }
  }

  // =================== ATTENDANCE RECORDS ===================
  
  Future<void> addAttendanceRecord(Map<String, dynamic> attendanceData) async {
    final dbClient = await db;
    await dbClient.insert('attendance_records', attendanceData);
    print('[DEBUG] 출석 기록 추가: ${attendanceData['student_id']} - ${attendanceData['date']}');
  }

  Future<List<Map<String, dynamic>>> getAttendanceRecords() async {
    final dbClient = await db;
    return await dbClient.query('attendance_records', orderBy: 'date DESC, class_date_time DESC');
  }

  Future<void> updateAttendanceRecord(String id, Map<String, dynamic> attendanceData) async {
    final dbClient = await db;
    await dbClient.update(
      'attendance_records',
      attendanceData,
      where: 'id = ?',
      whereArgs: [id],
    );
    print('[DEBUG] 출석 기록 수정: $id');
  }

  Future<void> deleteAttendanceRecord(String id) async {
    final dbClient = await db;
    await dbClient.delete(
      'attendance_records',
      where: 'id = ?',
      whereArgs: [id],
    );
    print('[DEBUG] 출석 기록 삭제: $id');
  }

  Future<List<Map<String, dynamic>>> getAttendanceRecordsForStudent(String studentId) async {
    final dbClient = await db;
    final result = await dbClient.query(
      'attendance_records',
      where: 'student_id = ?',
      whereArgs: [studentId],
      orderBy: 'date DESC, class_date_time DESC',
    );
    return result;
  }

  Future<Map<String, dynamic>?> getAttendanceRecord(String studentId, String classDateTime) async {
    final dbClient = await db;
    final result = await dbClient.query(
      'attendance_records',
      where: 'student_id = ? AND class_date_time = ?',
      whereArgs: [studentId, classDateTime],
      limit: 1,
    );
    return result.isNotEmpty ? result.first : null;
  }

  Future<void> ensureAttendanceRecordsTable() async {
    final dbClient = await db;
    
    try {
      // 테이블 존재 여부 확인
      final result = await dbClient.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='attendance_records'"
      );
      
      if (result.isEmpty) {
        print('[DEBUG] attendance_records 테이블이 존재하지 않음. 생성 중...');
        
        // 테이블 생성
        await dbClient.execute('''
          CREATE TABLE attendance_records (
            id TEXT PRIMARY KEY,
            student_id TEXT,
            class_date_time TEXT,
            class_end_time TEXT,
            class_name TEXT,
            is_present INTEGER,
            arrival_time TEXT,
            departure_time TEXT,
            notes TEXT,
            created_at TEXT,
            updated_at TEXT,
            FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE
          )
        ''');
        
        print('[DEBUG] attendance_records 테이블 생성 완료');
      } else {
        print('[DEBUG] attendance_records 테이블이 이미 존재함');
        
        // 기존 테이블이 있으면 스키마 업데이트 확인
        final tableInfo = await dbClient.rawQuery("PRAGMA table_info(attendance_records)");
        final columnNames = tableInfo.map((col) => col['name'] as String).toList();
        
        // class_end_time 컬럼이 없으면 추가
        if (!columnNames.contains('class_end_time')) {
          print('[DEBUG] class_end_time 컬럼 추가 중...');
          await dbClient.execute('ALTER TABLE attendance_records ADD COLUMN class_end_time TEXT');
        }
        
        // date 컬럼이 있으면 삭제 (SQLite는 DROP COLUMN을 지원하지 않으므로 테이블 재생성)
        if (columnNames.contains('date')) {
          print('[DEBUG] date 컬럼 제거를 위해 테이블 재생성 중...');
          
          // 기존 데이터 백업
          final existingData = await dbClient.query('attendance_records');
          
          // 기존 테이블 삭제
          await dbClient.execute('DROP TABLE attendance_records');
          
          // 새 테이블 생성
          await dbClient.execute('''
            CREATE TABLE attendance_records (
              id TEXT PRIMARY KEY,
              student_id TEXT,
              class_date_time TEXT,
              class_end_time TEXT,
              class_name TEXT,
              is_present INTEGER,
              arrival_time TEXT,
              departure_time TEXT,
              notes TEXT,
              created_at TEXT,
              updated_at TEXT,
              FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE
            )
          ''');
          
          // 데이터 복원 (date 컬럼 제외)
          for (final row in existingData) {
            final newRow = Map<String, dynamic>.from(row);
            newRow.remove('date');
            
            // class_end_time 계산 (기존 로직에서 duration 사용)
            if (newRow['class_date_time'] != null) {
              try {
                final classDateTime = DateTime.parse(newRow['class_date_time']);
                final classEndTime = classDateTime.add(const Duration(minutes: 50)); // 기본 50분
                newRow['class_end_time'] = classEndTime.toIso8601String();
              } catch (e) {
                print('[WARNING] class_end_time 계산 실패: $e');
              }
            }
            
            await dbClient.insert('attendance_records', newRow);
          }
          
          print('[DEBUG] 테이블 재생성 및 데이터 복원 완료');
        }
      }
    } catch (e) {
      print('[ERROR] attendance_records 테이블 확인/생성 중 오류: $e');
      rethrow;
    }
  }
} 