import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'academy_db.dart';
import 'package:sqflite/sqflite.dart';

class TagPreset {
  final String id;
  final String name;
  final Color color;
  final IconData icon;
  final int orderIndex;
  const TagPreset({required this.id, required this.name, required this.color, required this.icon, required this.orderIndex});

  Map<String, dynamic> toRow() => {
    'id': id,
    'name': name,
    'color': color.value,
    'icon_code': icon.codePoint,
    'order_index': orderIndex,
  };

  static TagPreset fromRow(Map<String, dynamic> r) => TagPreset(
    id: r['id'] as String,
    name: r['name'] as String,
    color: Color(r['color'] as int),
    icon: IconData(r['icon_code'] as int, fontFamily: 'MaterialIcons'),
    orderIndex: (r['order_index'] as int?) ?? 0,
  );
}

class TagPresetService {
  TagPresetService._();
  static final TagPresetService instance = TagPresetService._();

  Future<List<TagPreset>> loadPresets() async {
    final db = await AcademyDbService.instance.db;
    final rows = await db.query('tag_presets', orderBy: 'order_index ASC');
    if (rows.isEmpty) {
      // seed defaults if empty
      final defaults = [
        TagPreset(id: const Uuid().v4(), name: '졸음', color: const Color(0xFF7E57C2), icon: Icons.bedtime, orderIndex: 0),
        TagPreset(id: const Uuid().v4(), name: '스마트폰', color: const Color(0xFFF57C00), icon: Icons.phone_iphone, orderIndex: 1),
        TagPreset(id: const Uuid().v4(), name: '떠듬', color: const Color(0xFFEF5350), icon: Icons.record_voice_over, orderIndex: 2),
        TagPreset(id: const Uuid().v4(), name: '딴짓', color: const Color(0xFF90A4AE), icon: Icons.gesture, orderIndex: 3),
        TagPreset(id: const Uuid().v4(), name: '기록', color: const Color(0xFF1976D2), icon: Icons.edit_note, orderIndex: 4),
      ];
      await saveAll(defaults);
      return defaults;
    }
    return rows.map(TagPreset.fromRow).toList();
  }

  Future<void> saveAll(List<TagPreset> presets) async {
    final db = await AcademyDbService.instance.db;
    await db.transaction((txn) async {
      await txn.delete('tag_presets');
      for (final p in presets) {
        await txn.insert('tag_presets', p.toRow());
      }
    });
  }

  Future<void> upsert(TagPreset preset) async {
    final db = await AcademyDbService.instance.db;
    await db.insert('tag_presets', preset.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> delete(String id) async {
    final db = await AcademyDbService.instance.db;
    await db.delete('tag_presets', where: 'id = ?', whereArgs: [id]);
  }
}


