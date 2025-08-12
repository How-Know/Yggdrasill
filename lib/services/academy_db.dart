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
        version: 19,
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
          CREATE TABLE student_basic_info (
            student_id TEXT PRIMARY KEY,
            phone_number TEXT,
            parent_phone_number TEXT,
            group_id TEXT,
            memo TEXT,
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
            start_hour INTEGER,
            start_minute INTEGER,
            duration INTEGER,
            created_at TEXT,
            set_id TEXT,
            number INTEGER,
            session_type_id TEXT,
            weekly_order INTEGER
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
        await db.execute('''
          CREATE TABLE IF NOT EXISTS student_payment_info (
            id TEXT PRIMARY KEY,
            student_id TEXT UNIQUE,
            registration_date INTEGER,
            payment_method TEXT,
            weekly_class_count INTEGER DEFAULT 1,
            tuition_fee INTEGER,
            lateness_threshold INTEGER DEFAULT 10,
            schedule_notification INTEGER DEFAULT 0,
            attendance_notification INTEGER DEFAULT 0,
            departure_notification INTEGER DEFAULT 0,
            lateness_notification INTEGER DEFAULT 0,
            created_at INTEGER,
            updated_at INTEGER,
            FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE
          )
        ''');
        // v14: session_overrides
        await db.execute('''
          CREATE TABLE session_overrides (
            id TEXT PRIMARY KEY,
            student_id TEXT NOT NULL,
            session_type_id TEXT,
            set_id TEXT,
            override_type TEXT NOT NULL,
            original_class_datetime TEXT,
            replacement_class_datetime TEXT,
            duration_minutes INTEGER,
            reason TEXT,
            original_attendance_id TEXT,
            replacement_attendance_id TEXT,
            status TEXT NOT NULL,
            created_at TEXT,
            updated_at TEXT,
            FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE
          )
        ''');
        await db.execute('''
          CREATE UNIQUE INDEX idx_session_overrides_unique
          ON session_overrides(student_id, original_class_datetime, override_type)
        ''');
        await db.execute('''
          CREATE INDEX idx_session_overrides_lookup
          ON session_overrides(student_id, replacement_class_datetime)
        ''');
        await db.execute('''
          CREATE TABLE memos (
            id TEXT PRIMARY KEY,
            original TEXT,
            summary TEXT,
            scheduled_at TEXT,
            dismissed INTEGER,
            created_at TEXT,
            updated_at TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE schedule_events (
            id TEXT PRIMARY KEY,
            group_id TEXT, -- 같은 등록 묶음 식별자(범위 등록 시 동일)
            date TEXT,
            title TEXT,
            note TEXT,
            start_hour INTEGER,
            start_minute INTEGER,
            end_hour INTEGER,
            end_minute INTEGER,
            color INTEGER,
            tags TEXT, -- JSON 배열 문자열
            icon_key TEXT,
            created_at TEXT,
            updated_at TEXT
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
            CREATE TABLE IF NOT EXISTS student_basic_info (
              student_id TEXT PRIMARY KEY,
              phone_number TEXT,
              parent_phone_number TEXT,
              group_id TEXT,
              memo TEXT,
              FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE
            )
          ''');
          final columns = await db.rawQuery("PRAGMA table_info(students)");
          final hasPhone = columns.any((col) => col['name'] == 'phone_number');
          if (hasPhone) {
            await db.execute('''
              INSERT OR IGNORE INTO student_basic_info (student_id, phone_number, parent_phone_number, group_id)
              SELECT id, phone_number, parent_phone_number, group_id FROM students
            ''');
          }
        }
        if (oldVersion < 4) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS student_time_blocks (
              id TEXT PRIMARY KEY,
              student_id TEXT,
              group_id TEXT,
              day_index INTEGER,
              start_hour INTEGER,
              start_minute INTEGER,
              duration INTEGER,
              created_at TEXT,
              set_id TEXT,
              number INTEGER,
              session_type_id TEXT
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
          // 이전 버전 호환성을 위한 코드 (삭제됨 - 더 이상 해당 컬럼을 사용하지 않음)
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
        if (oldVersion < 11) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS student_payment_info (
              id TEXT PRIMARY KEY,
              student_id TEXT UNIQUE,
              registration_date INTEGER,
              payment_method TEXT,
              weekly_class_count INTEGER DEFAULT 1,
              tuition_fee INTEGER,
              lateness_threshold INTEGER DEFAULT 10,
              schedule_notification INTEGER DEFAULT 0,
              attendance_notification INTEGER DEFAULT 0,
              departure_notification INTEGER DEFAULT 0,
              lateness_notification INTEGER DEFAULT 0,
              created_at INTEGER,
              updated_at INTEGER,
              FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE
            )
          ''');
        }
        
        // 버전 12: students_basic_info -> student_basic_info 마이그레이션 및 컬럼 정리
        if (oldVersion < 12) {
          print('[DB] 버전 12 마이그레이션 시작: students_basic_info -> student_basic_info');
          
          // 1. 기존 students_basic_info 테이블 존재 확인
          final tableExists = await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='students_basic_info'"
          );
          
          if (tableExists.isNotEmpty) {
            print('[DB] 기존 students_basic_info 테이블 발견, 마이그레이션 진행');
            
            // 2. 새 student_basic_info 테이블 생성
            await db.execute('''
              CREATE TABLE IF NOT EXISTS student_basic_info (
                student_id TEXT PRIMARY KEY,
                phone_number TEXT,
                parent_phone_number TEXT,
                group_id TEXT,
                memo TEXT,
                FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE
              )
            ''');
            
            // 3. 기존 데이터를 새 테이블로 마이그레이션 (필요한 컬럼만)
            await db.execute('''
              INSERT OR REPLACE INTO student_basic_info (student_id, phone_number, parent_phone_number, group_id)
              SELECT student_id, phone_number, parent_phone_number, group_id 
              FROM students_basic_info
            ''');
            
            // 4. 기존 테이블 삭제
            await db.execute('DROP TABLE students_basic_info');
            
            print('[DB] students_basic_info -> student_basic_info 마이그레이션 완료');
          } else {
            print('[DB] students_basic_info 테이블이 없음, 새로 생성');
            // 테이블이 없다면 새로 생성
            await db.execute('''
              CREATE TABLE IF NOT EXISTS student_basic_info (
                student_id TEXT PRIMARY KEY,
                phone_number TEXT,
                parent_phone_number TEXT,
                group_id TEXT,
                memo TEXT,
                FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE
              )
            ''');
          }
        }
        // 버전 17: student_basic_info에 memo 컬럼 추가
        if (oldVersion < 17) {
          final columns = await db.rawQuery("PRAGMA table_info(student_basic_info)");
          final hasMemo = columns.any((col) => col['name'] == 'memo');
          if (!hasMemo) {
            await db.execute('ALTER TABLE student_basic_info ADD COLUMN memo TEXT');
          }
        }
        if (oldVersion < 18) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS memos (
              id TEXT PRIMARY KEY,
              original TEXT,
              summary TEXT,
              scheduled_at TEXT,
              dismissed INTEGER,
              created_at TEXT,
              updated_at TEXT
            )
          ''');
        }
        if (oldVersion < 19) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS schedule_events (
              id TEXT PRIMARY KEY,
              group_id TEXT,
              date TEXT,
              title TEXT,
              note TEXT,
              start_hour INTEGER,
              start_minute INTEGER,
              end_hour INTEGER,
              end_minute INTEGER,
              color INTEGER,
              tags TEXT,
              icon_key TEXT,
              created_at TEXT,
              updated_at TEXT
            )
          ''');
        }
        
        // 버전 13: student_time_blocks 테이블 컬럼 구조 수정
        if (oldVersion < 13) {
          print('[DB] 버전 13 마이그레이션 시작: student_time_blocks 컬럼 구조 수정');
          
          // 1. 기존 student_time_blocks 테이블 백업
          await db.execute('''
            CREATE TABLE student_time_blocks_backup AS 
            SELECT * FROM student_time_blocks
          ''');
          
          // 2. 기존 테이블 삭제
          await db.execute('DROP TABLE student_time_blocks');
          
          // 3. 새로운 구조로 테이블 재생성
          await db.execute('''
            CREATE TABLE student_time_blocks (
              id TEXT PRIMARY KEY,
              student_id TEXT,
              day_index INTEGER,
              start_hour INTEGER,
              start_minute INTEGER,
              duration INTEGER,
              created_at TEXT,
              set_id TEXT,
              number INTEGER,
              session_type_id TEXT,
              weekly_order INTEGER
            )
          ''');
          
          // 4. 백업 데이터를 새 구조로 변환하여 복원 (start_time을 start_hour, start_minute로 분리)
          final backupData = await db.rawQuery('SELECT * FROM student_time_blocks_backup');
          for (final row in backupData) {
            String? startTime = row['start_time'] as String?;
            int startHour = 0;
            int startMinute = 0;
            
            if (startTime != null && startTime.contains(':')) {
              final parts = startTime.split(':');
              if (parts.length >= 2) {
                startHour = int.tryParse(parts[0]) ?? 0;
                startMinute = int.tryParse(parts[1]) ?? 0;
              }
            }
            
            await db.insert('student_time_blocks', {
              'id': row['id'],
              'student_id': row['student_id'],
              'day_index': row['day_index'],
              'start_hour': startHour,
              'start_minute': startMinute,
              'duration': row['duration'],
              'created_at': row['created_at'],
              'set_id': row['set_id'],
              'number': row['number'],
              'session_type_id': row['session_type_id'],
              'weekly_order': row['weekly_order'],
            });
          }
          
          // 5. 백업 테이블 삭제
          await db.execute('DROP TABLE student_time_blocks_backup');
          
          print('[DB] 버전 13 마이그레이션 완료: student_time_blocks 컬럼 구조 수정');
        }
        // 버전 14: session_overrides 테이블 생성 및 인덱스 추가
        if (oldVersion < 14) {
          print('[DB] 버전 14 마이그레이션 시작: session_overrides 테이블 생성');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS session_overrides (
              id TEXT PRIMARY KEY,
              student_id TEXT NOT NULL,
              session_type_id TEXT,
              set_id TEXT,
              override_type TEXT NOT NULL,
              original_class_datetime TEXT,
              replacement_class_datetime TEXT,
              duration_minutes INTEGER,
              reason TEXT,
              original_attendance_id TEXT,
              replacement_attendance_id TEXT,
              status TEXT NOT NULL,
              created_at TEXT,
              updated_at TEXT,
              FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE
            )
          ''');
          await db.execute('''
            CREATE UNIQUE INDEX IF NOT EXISTS idx_session_overrides_unique
            ON session_overrides(student_id, original_class_datetime, override_type)
          ''');
          await db.execute('''
            CREATE INDEX IF NOT EXISTS idx_session_overrides_lookup
            ON session_overrides(student_id, replacement_class_datetime)
          ''');
          print('[DB] 버전 14 마이그레이션 완료: session_overrides 테이블 생성');
        }
        // 버전 16: student_time_blocks에서 group_id 제거 및 weekly_order 컬럼 추가
        if (oldVersion < 16) {
          print('[DB] 버전 16 마이그레이션 시작: student_time_blocks 테이블 재구성 (group_id 제거, weekly_order 추가)');
          // 1) 백업 테이블 생성
          await db.execute('''
            CREATE TABLE student_time_blocks_v16_backup AS
            SELECT * FROM student_time_blocks
          ''');
          // 2) 기존 테이블 삭제
          await db.execute('DROP TABLE student_time_blocks');
          // 3) 새 구조로 테이블 생성 (group_id 제거, weekly_order 추가)
          await db.execute('''
            CREATE TABLE student_time_blocks (
              id TEXT PRIMARY KEY,
              student_id TEXT,
              day_index INTEGER,
              start_hour INTEGER,
              start_minute INTEGER,
              duration INTEGER,
              created_at TEXT,
              set_id TEXT,
              number INTEGER,
              session_type_id TEXT,
              weekly_order INTEGER
            )
          ''');
          // 4) 백업 데이터 읽어서 변환 삽입
          final backupRows = await db.rawQuery('SELECT * FROM student_time_blocks_v16_backup');
          for (final row in backupRows) {
            // start_time -> start_hour/start_minute 변환은 v13에서 처리됨, 여기서는 그대로 사용
            await db.insert('student_time_blocks', {
              'id': row['id'],
              'student_id': row['student_id'],
              'day_index': row['day_index'],
              'start_hour': row['start_hour'],
              'start_minute': row['start_minute'],
              'duration': row['duration'],
              'created_at': row['created_at'],
              'set_id': row['set_id'],
              'number': row['number'],
              'session_type_id': row['session_type_id'],
              'weekly_order': null,
            });
          }
          // 5) 백업 테이블 삭제
          await db.execute('DROP TABLE student_time_blocks_v16_backup');
          print('[DB] 버전 16 마이그레이션 완료: student_time_blocks 재구성');
        }
        // 버전 15: student_payment_info 테이블에 weekly_class_count 컬럼 추가
        if (oldVersion < 15) {
          print('[DB] 버전 15 마이그레이션 시작: student_payment_info.weekly_class_count 컬럼 추가');
          final columns = await db.rawQuery("PRAGMA table_info(student_payment_info)");
          final hasWeekly = columns.any((col) => col['name'] == 'weekly_class_count');
          if (!hasWeekly) {
            await db.execute('ALTER TABLE student_payment_info ADD COLUMN weekly_class_count INTEGER DEFAULT 1');
          }
          print('[DB] 버전 15 마이그레이션 완료: weekly_class_count 컬럼 추가');
        }
      },
    );
  }

  Future<Database> openDatabaseWithLog(String path, {int version = 1, OnDatabaseCreateFn? onCreate, OnDatabaseVersionChangeFn? onUpgrade}) async {
    print('[DB][경로] 실제 사용 DB 파일 경로: $path');
    
    // 파일 존재 여부 확인
    final file = File(path);
    final exists = await file.exists();
    print('[DB][파일] DB 파일 존재 여부: $exists');
    
    if (exists) {
      final stat = await file.stat();
      print('[DB][파일] DB 파일 크기: ${stat.size} bytes, 수정일: ${stat.modified}');
    }
    
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

  // ======== MEMO CRUD ========
  Future<void> addMemo(Map<String, dynamic> map) async {
    final dbClient = await db;
    await ensureMemosTable();
    await dbClient.insert('memos', map, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  Future<void> updateMemo(String id, Map<String, dynamic> map) async {
    final dbClient = await db;
    await ensureMemosTable();
    await dbClient.update('memos', map, where: 'id = ?', whereArgs: [id]);
  }
  Future<void> deleteMemo(String id) async {
    final dbClient = await db;
    await ensureMemosTable();
    await dbClient.delete('memos', where: 'id = ?', whereArgs: [id]);
  }
  Future<List<Map<String, dynamic>>> getMemos() async {
    final dbClient = await db;
    await ensureMemosTable();
    return await dbClient.query('memos', orderBy: 'updated_at DESC');
  }

  Future<void> ensureMemosTable() async {
    final dbClient = await db;
    final result = await dbClient.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='memos'");
    if (result.isEmpty) {
      await dbClient.execute('''
        CREATE TABLE IF NOT EXISTS memos (
          id TEXT PRIMARY KEY,
          original TEXT,
          summary TEXT,
          scheduled_at TEXT,
          dismissed INTEGER,
          created_at TEXT,
          updated_at TEXT
        )
      ''');
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
    await dbClient.insert('student_basic_info', info, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getStudentBasicInfo(String studentId) async {
    final dbClient = await db;
    final result = await dbClient.query('student_basic_info', where: 'student_id = ?', whereArgs: [studentId]);
    if (result.isNotEmpty) return result.first;
    return null;
  }

  Future<void> updateStudentBasicInfo(String studentId, Map<String, dynamic> info) async {
    print('[DB] updateStudentBasicInfo:  [33mstudentId=$studentId [0m, groupId= [36m${info['group_id']} [0m');
    final dbClient = await db;
    await dbClient.update('student_basic_info', info, where: 'student_id = ?', whereArgs: [studentId]);
  }

  Future<void> deleteStudentBasicInfo(String studentId) async {
    final dbClient = await db;
    await dbClient.delete('student_basic_info', where: 'student_id = ?', whereArgs: [studentId]);
  }

  Future<void> addStudentTimeBlock(StudentTimeBlock block) async {
    final dbClient = await db;
    print('[DB] addStudentTimeBlock: ${block.toJson()}');
    await dbClient.insert(
      'student_time_blocks',
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
        'session_type_id': block.sessionTypeId,
        'weekly_order': block.weeklyOrder,
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
      dayIndex: row['day_index'] as int? ?? 0,
      startHour: row['start_hour'] as int? ?? 0,
      startMinute: row['start_minute'] as int? ?? 0,
      duration: Duration(minutes: row['duration'] as int? ?? 0),
      createdAt: DateTime.parse(row['created_at'] as String),
      setId: row['set_id'] as String?,
      number: row['number'] as int?,
      sessionTypeId: row['session_type_id'] as String?,
      weeklyOrder: row['weekly_order'] as int?,
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
        'start_hour': block.startHour,
        'start_minute': block.startMinute,
        'duration': block.duration.inMinutes,
        'created_at': block.createdAt.toIso8601String(),
        'set_id': block.setId,
        'number': block.number,
        'session_type_id': block.sessionTypeId,
        'weekly_order': block.weeklyOrder,
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
           
            'day_index': block.dayIndex,
            'start_hour': block.startHour,
            'start_minute': block.startMinute,
            'duration': block.duration.inMinutes,
            'created_at': block.createdAt.toIso8601String(),
            'set_id': block.setId,
            'number': block.number,
            'session_type_id': block.sessionTypeId,
            'weekly_order': block.weeklyOrder,
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

  // =================== STUDENT PAYMENT INFO ===================
  
  // student_payment_info 테이블 존재 여부 확인 및 생성
  Future<void> ensureStudentPaymentInfoTable() async {
    final dbClient = await db;
    
    try {
      // 테이블 존재 여부 확인
      final result = await dbClient.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='student_payment_info'"
      );
      
      if (result.isEmpty) {
        print('[DEBUG] student_payment_info 테이블이 존재하지 않음. 생성 중...');
        
        // 테이블 생성
        await dbClient.execute('''
          CREATE TABLE student_payment_info (
            id TEXT PRIMARY KEY,
            student_id TEXT UNIQUE,
            registration_date INTEGER,
            payment_method TEXT,
            tuition_fee INTEGER,
            lateness_threshold INTEGER DEFAULT 10,
            schedule_notification INTEGER DEFAULT 0,
            attendance_notification INTEGER DEFAULT 0,
            departure_notification INTEGER DEFAULT 0,
            lateness_notification INTEGER DEFAULT 0,
            created_at INTEGER,
            updated_at INTEGER,
            FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE
          )
        ''');
        
        print('[DEBUG] student_payment_info 테이블 생성 완료');
      } else {
        print('[DEBUG] student_payment_info 테이블이 이미 존재함');
      }
    } catch (e) {
      print('[ERROR] student_payment_info 테이블 확인/생성 중 오류: $e');
      rethrow;
    }
  }

  // 학생 결제 정보 추가
  Future<void> addStudentPaymentInfo(Map<String, dynamic> paymentInfoData) async {
    final dbClient = await db;
    await dbClient.insert(
      'student_payment_info', 
      paymentInfoData,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    print('[DEBUG] 학생 결제 정보 추가: ${paymentInfoData['student_id']}');
  }

  // 학생 결제 정보 업데이트
  Future<void> updateStudentPaymentInfo(String studentId, Map<String, dynamic> paymentInfoData) async {
    final dbClient = await db;
    await dbClient.update(
      'student_payment_info',
      paymentInfoData,
      where: 'student_id = ?',
      whereArgs: [studentId],
    );
    print('[DEBUG] 학생 결제 정보 업데이트: $studentId');
  }

  // 특정 학생의 결제 정보 조회
  Future<Map<String, dynamic>?> getStudentPaymentInfo(String studentId) async {
    final dbClient = await db;
    final result = await dbClient.query(
      'student_payment_info',
      where: 'student_id = ?',
      whereArgs: [studentId],
    );
    
    if (result.isNotEmpty) {
      return result.first;
    }
    return null;
  }

  // 모든 학생 결제 정보 조회
  Future<List<Map<String, dynamic>>> getAllStudentPaymentInfo() async {
    final dbClient = await db;
    return await dbClient.query('student_payment_info');
  }

  // 학생 결제 정보 삭제
  Future<void> deleteStudentPaymentInfo(String studentId) async {
    final dbClient = await db;
    await dbClient.delete(
      'student_payment_info',
      where: 'student_id = ?',
      whereArgs: [studentId],
    );
    print('[DEBUG] 학생 결제 정보 삭제: $studentId');
  }

  // =================== ATTENDANCE RECORDS ===================
  
  Future<void> addAttendanceRecord(Map<String, dynamic> attendanceData) async {
    final dbClient = await db;
    await dbClient.insert('attendance_records', attendanceData);
    print('[DEBUG] 출석 기록 추가: ${attendanceData['student_id']} - ${attendanceData['class_date_time']}');
  }

  Future<List<Map<String, dynamic>>> getAttendanceRecords() async {
    final dbClient = await db;
    return await dbClient.query('attendance_records', orderBy: 'class_date_time DESC');
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
      orderBy: 'class_date_time DESC',
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
        // 하지만 이 마이그레이션은 한 번만 실행되어야 함
        if (columnNames.contains('date')) {
          print('[DEBUG] date 컬럼 제거를 위해 테이블 재생성 중...');
          print('[WARNING] 이 작업은 한 번만 실행되어야 합니다. 프로그램 재시작 시 데이터 손실 방지를 위해 주의깊게 진행합니다.');
          
          // 기존 데이터 백업 (더 안전한 방식)
          final existingData = await dbClient.query('attendance_records');
          print('[DEBUG] 백업된 기존 데이터: ${existingData.length}개 레코드');
          
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
          
          // 데이터 복원 (date 컬럼 제외, 더 안전한 방식)
          int restoredCount = 0;
          for (final row in existingData) {
            try {
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
              restoredCount++;
            } catch (e) {
              print('[ERROR] 데이터 복원 실패: $e, 레코드: $row');
            }
          }
          
          print('[DEBUG] 테이블 재생성 및 데이터 복원 완료: $restoredCount/${existingData.length}개 복원됨');
        }
      }
    } catch (e) {
      print('[ERROR] attendance_records 테이블 확인/생성 중 오류: $e');
      rethrow;
    }
  }

  // =================== SESSION OVERRIDES ===================

  Future<void> addSessionOverride(Map<String, dynamic> data) async {
    final dbClient = await db;
    await dbClient.insert('session_overrides', data, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateSessionOverride(String id, Map<String, dynamic> data) async {
    final dbClient = await db;
    await dbClient.update('session_overrides', data, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteSessionOverride(String id) async {
    final dbClient = await db;
    await dbClient.delete('session_overrides', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteSessionOverridesByStudentId(String studentId) async {
    final dbClient = await db;
    await dbClient.delete('session_overrides', where: 'student_id = ?', whereArgs: [studentId]);
  }

  Future<List<Map<String, dynamic>>> getSessionOverridesForStudent(String studentId) async {
    final dbClient = await db;
    return await dbClient.query('session_overrides', where: 'student_id = ?', whereArgs: [studentId], orderBy: 'replacement_class_datetime ASC, original_class_datetime ASC');
  }

  Future<List<Map<String, dynamic>>> getSessionOverridesAll() async {
    final dbClient = await db;
    return await dbClient.query('session_overrides', orderBy: 'replacement_class_datetime ASC, original_class_datetime ASC');
  }
} 