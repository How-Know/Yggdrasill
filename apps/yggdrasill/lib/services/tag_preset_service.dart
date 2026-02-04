import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'academy_db.dart';
import 'runtime_flags.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'tenant_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TagPreset {
  final String id;
  final String name;
  final Color color;
  final IconData icon;
  final int orderIndex;
  const TagPreset({required this.id, required this.name, required this.color, required this.icon, required this.orderIndex});

  static int encodeColorValue(Color color) => color.value.toSigned(32);
  static Color decodeColorValue(int value) => Color(value.toUnsigned(32));

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
    color: decodeColorValue((r['color'] as int?) ?? 0xFF1976D2),
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
  static const String _pendingSyncKey = 'tag_presets_pending_sync';
  bool _syncInFlight = false;

  static void configure({bool? dualWriteOn, bool? preferSupabase}) {
    if (dualWriteOn != null) dualWrite = dualWriteOn;
    if (preferSupabase != null) preferSupabaseRead = preferSupabase;
  }

  Future<void> _setPendingSync(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_pendingSyncKey, value);
    } catch (_) {}
  }

  Future<bool> _isPendingSync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_pendingSyncKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _pushToServer(List<TagPreset> presets) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final rows = presets.map((p) => {
        'id': p.id,
        'academy_id': academyId,
        'name': p.name,
        'color': TagPreset.encodeColorValue(p.color),
        'icon_code': p.icon.codePoint,
        'order_index': p.orderIndex,
      }).toList();
      // ignore: avoid_print
      print('[TagPreset] pushToServer upsert count=' + rows.length.toString());
      await supa.from('tag_presets').upsert(rows, onConflict: 'id');
      return true;
    } catch (e, st) {
      // ignore: avoid_print
      print('[TagPreset][ERROR] pushToServer failed: $e\n$st');
      return false;
    }
  }

  Future<void> _trySyncPending(List<TagPreset> local) async {
    if (_syncInFlight) return;
    _syncInFlight = true;
    try {
      if (local.isEmpty) {
        await _setPendingSync(false);
        return;
      }
      final ok = await _pushToServer(local);
      await _setPendingSync(!ok);
    } finally {
      _syncInFlight = false;
    }
  }

  Future<List<TagPreset>> loadPresets() async {
    // 1) Supabase에서 우선 조회(레코드가 있으면 그쪽 사용)
    final hasPending = await _isPendingSync();
    if (preferSupabaseRead && !hasPending) {
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
          color: TagPreset.decodeColorValue((r['color'] as int?) ?? 0xFF1976D2),
          icon: IconData((r['icon_code'] as int?) ?? Icons.label.codePoint, fontFamily: 'MaterialIcons'),
          orderIndex: (r['order_index'] as int?) ?? 0,
        )).toList();
        if (list.isNotEmpty) {
          list.sort(_comparePresets);
          return list;
        }
      } catch (_) {
        // 폴백
      }
    }

    // 2) SQLite 기본 동작 (serverOnly면 빈 목록)
    // ignore: avoid_print
    print('[TagPreset] loadPresets: source=SQLite (fallback or preferSupabaseRead=false)');
    if (RuntimeFlags.serverOnly) {
      return <TagPreset>[];
    }
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
    list.sort(_comparePresets);
    if (dualWrite && preferSupabaseRead && hasPending) {
      await _trySyncPending(list);
    }
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
            'color': TagPreset.encodeColorValue(p.color),
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
    final list = rows.map(TagPreset.fromRow).toList();
    list.sort(_comparePresets);
    return list;
  }

  int _comparePresets(TagPreset a, TagPreset b) {
    final diff = a.orderIndex.compareTo(b.orderIndex);
    if (diff != 0) return diff;
    return a.name.compareTo(b.name);
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
      final ok = await _pushToServer(presets);
      await _setPendingSync(!ok);
    }
  }

  Future<void> upsert(TagPreset preset) async {
    final db = await AcademyDbService.instance.db;
    await db.insert('tag_presets', preset.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

    if (dualWrite) {
      final ok = await _pushToServer([preset]);
      await _setPendingSync(!ok);
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
        await _setPendingSync(false);
      } catch (e, st) {
        // ignore: avoid_print
        print('[TagPreset][ERROR] delete failed: $e\n$st');
        await _setPendingSync(true);
      }
    }
  }
}


