import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import '../models/academy_settings.dart';
import 'dart:io';

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
      version: 1,
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
      },
    );
  }

  Future<void> saveAcademySettings(AcademySettings settings, String paymentType) async {
    final dbClient = await db;
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
    final dbClient = await db;
    await dbClient.delete('teachers');
    for (final t in teachers) {
      await dbClient.insert('teachers', {
        'name': t.name,
        'role': t.role.index,
        'contact': t.contact,
        'email': t.email,
        'description': t.description,
      });
    }
  }

  Future<List<Map<String, dynamic>>> getTeachers() async {
    final dbClient = await db;
    return await dbClient.query('teachers');
  }
} 