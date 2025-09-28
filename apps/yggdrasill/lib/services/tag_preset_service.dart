import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'academy_db.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'tenant_service.dart';

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
  // 듀얼라이트/읽기 전환 플래그
  // - dualWrite: true면 SQLite와 Supabase에 동시에 저장합니다.
  // - preferSupabaseRead: Supabase에서 레코드가 있으면 우선 사용하고, 없으면 SQLite로 폴백합니다.
  static bool dualWrite = true;
  static bool preferSupabaseRead = true;

  static void configure({bool? dualWriteOn, bool? preferSupabase}) {
    if (dualWriteOn != null) dualWrite = dualWriteOn;
    if (preferSupabase != null) preferSupabaseRead = preferSupabase;
  }

  Future<List<TagPreset>> loadPresets() async {
    // 1) Supabase에서 우선 조회(레코드가 있으면 그쪽 사용)
    if (preferSupabaseRead) {
      try {
        // ignore: avoid_print
        print('[TagPreset] loadPresets: source=Supabase preferSupabaseRead=true');
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final data = await supa
            .from('tag_presets')
            .select('id,name,color,icon_code,order_index')
            .eq('academy_id', academyId)
            .order('order_index');
        final list = (data as List<dynamic>).map((r) => TagPreset(
          id: r['id'] as String,
          name: (r['name'] as String?) ?? '',
          color: Color((r['color'] as int?) ?? 0xFF1976D2),
          icon: IconData((r['icon_code'] as int?) ?? Icons.label.codePoint, fontFamily: 'MaterialIcons'),
          orderIndex: (r['order_index'] as int?) ?? 0,
        )).toList();
        if (list.isNotEmpty) return list;
      } catch (_) {
        // 폴백
      }
    }

    // 2) SQLite 기본 동작
    // ignore: avoid_print
    print('[TagPreset] loadPresets: source=SQLite (fallback or preferSupabaseRead=false)');
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
    final list = rows.map(TagPreset.fromRow).toList();
    // 서버 백필(초기 1회): 서버가 비어있고 로컬에 데이터가 있으면 업로드
    if (dualWrite && preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final exists = await supa.from('tag_presets').select('id').eq('academy_id', academyId).limit(1);
        if ((exists as List).isEmpty && list.isNotEmpty) {
          // ignore: avoid_print
          print('[TagPreset] backfill local->supabase count=' + list.length.toString());
          final rowsUp = list.map((p) => {
            'id': p.id,
            'academy_id': academyId,
            'name': p.name,
            'color': p.color.value,
            'icon_code': p.icon.codePoint,
            'order_index': p.orderIndex,
          }).toList();
          await supa.from('tag_presets').upsert(rowsUp, onConflict: 'id');
        }
      } catch (_) {}
    }
    return list;
  }

  // 로컬(SQLite)에서만 강제 로드하여 즉시 반영할 때 사용
  Future<List<TagPreset>> loadPresetsLocalOnly() async {
    final db = await AcademyDbService.instance.db;
    final rows = await db.query('tag_presets', orderBy: 'order_index ASC');
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

    if (dualWrite) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final rows = presets.map((p) => {
          'id': p.id,
          'academy_id': academyId,
          'name': p.name,
          'color': p.color.value,
          'icon_code': p.icon.codePoint,
          'order_index': p.orderIndex,
        }).toList();
        // ignore: avoid_print
        print('[TagPreset] saveAll dualWrite -> supabase upsert count=' + rows.length.toString());
        await supa.from('tag_presets').upsert(rows, onConflict: 'id');
      } catch (_) {}
    }
  }

  Future<void> upsert(TagPreset preset) async {
    final db = await AcademyDbService.instance.db;
    await db.insert('tag_presets', preset.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

    if (dualWrite) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        // ignore: avoid_print
        print('[TagPreset] upsert dualWrite -> supabase id=' + preset.id);
        await supa.from('tag_presets').upsert({
          'id': preset.id,
          'academy_id': academyId,
          'name': preset.name,
          'color': preset.color.value,
          'icon_code': preset.icon.codePoint,
          'order_index': preset.orderIndex,
        }, onConflict: 'id');
      } catch (_) {}
    }
  }

  Future<void> delete(String id) async {
    final db = await AcademyDbService.instance.db;
    await db.delete('tag_presets', where: 'id = ?', whereArgs: [id]);

    if (dualWrite) {
      try {
        final supa = Supabase.instance.client;
        // ignore: avoid_print
        print('[TagPreset] delete dualWrite -> supabase id=' + id);
        await supa.from('tag_presets').delete().eq('id', id);
      } catch (_) {}
    }
  }
}


