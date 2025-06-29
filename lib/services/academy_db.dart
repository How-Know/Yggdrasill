import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import '../models/academy_settings.dart';
import '../models/group_info.dart';
import 'dart:io';
import 'package:flutter/material.dart';

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
      version: 2,
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
} 