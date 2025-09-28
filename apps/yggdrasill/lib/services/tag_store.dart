import 'package:flutter/material.dart';
import 'academy_db.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'tenant_service.dart';
import 'package:uuid/uuid.dart';

class TagEvent {
  final String tagName;
  final int colorValue;
  final int iconCodePoint;
  final DateTime timestamp;
  final String? note;
  const TagEvent({required this.tagName, required this.colorValue, required this.iconCodePoint, required this.timestamp, this.note});
}

class TagStore {
  TagStore._internal();
  static final TagStore instance = TagStore._internal();

  // 듀얼라이트/서버우선 읽기 플래그(W1 범주)
  static bool dualWrite = true;
  static bool preferSupabaseRead = true;
  static void configure({bool? dualWriteOn, bool? preferSupabase}) {
    if (dualWriteOn != null) dualWrite = dualWriteOn;
    if (preferSupabase != null) preferSupabaseRead = preferSupabase;
  }

  final Map<String, List<TagEvent>> _eventsBySetId = {};
  final ValueNotifier<bool> isSaving = ValueNotifier<bool>(false);
  final ValueNotifier<bool> reachedEnd = ValueNotifier<bool>(false);

  List<TagEvent> getEventsForSet(String setId) {
    return List<TagEvent>.from(_eventsBySetId[setId] ?? const []);
  }

  Future<void> _syncSetToSupabase(String setId, List<TagEvent> events) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      // 전체 교체: 해당 set_id 레코드 삭제 후 일괄 insert
      await supa.from('tag_events').delete().match({'academy_id': academyId, 'set_id': setId});
      if (events.isNotEmpty) {
        final rows = events.map((e) => {
          // id는 서버 기본 생성 사용. 필요 시 UUID 부여 가능
          'academy_id': academyId,
          'set_id': setId,
          'tag_name': e.tagName,
          'color_value': e.colorValue,
          'icon_code': e.iconCodePoint,
          'occurred_at': e.timestamp.toIso8601String(),
          'note': e.note,
        }).toList();
        await supa.from('tag_events').insert(rows);
      }
      // ignore: avoid_print
      print('[TagEvents] sync set_id=' + setId + ' count=' + events.length.toString());
    } catch (_) {}
  }

  void setEventsForSet(String setId, List<TagEvent> events) {
    _eventsBySetId[setId] = List<TagEvent>.from(events);
    // DB 반영
    AcademyDbService.instance.setTagEventsForSet(setId, events.map((e) => {
      'id': '${setId}_${e.timestamp.millisecondsSinceEpoch}_${e.tagName}',
      'tag_name': e.tagName,
      'color_value': e.colorValue,
      'icon_code': e.iconCodePoint,
      'timestamp': e.timestamp.toIso8601String(),
      'note': e.note,
    }).toList());
    if (dualWrite) {
      _syncSetToSupabase(setId, events);
    }
  }

  Future<void> _appendToSupabase(String setId, TagEvent event) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      await supa.from('tag_events').insert({
        'academy_id': academyId,
        'set_id': setId,
        'tag_name': event.tagName,
        'color_value': event.colorValue,
        'icon_code': event.iconCodePoint,
        'occurred_at': event.timestamp.toIso8601String(),
        'note': event.note,
      });
      // ignore: avoid_print
      print('[TagEvents] append set_id=' + setId + ' tag=' + event.tagName);
    } catch (_) {}
  }

  void appendEvent(String setId, TagEvent event) {
    final list = _eventsBySetId.putIfAbsent(setId, () => <TagEvent>[]);
    list.add(event);
    AcademyDbService.instance.appendTagEvent({
      'id': '${setId}_${event.timestamp.millisecondsSinceEpoch}_${event.tagName}',
      'set_id': setId,
      'tag_name': event.tagName,
      'color_value': event.colorValue,
      'icon_code': event.iconCodePoint,
      'timestamp': event.timestamp.toIso8601String(),
      'note': event.note,
    });
    if (dualWrite) {
      _appendToSupabase(setId, event);
    }
  }

  Future<void> loadAllFromDb() async {
    _eventsBySetId.clear();
    if (preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final data = await supa
            .from('tag_events')
            .select('set_id, tag_name, color_value, icon_code, occurred_at, note')
            .eq('academy_id', academyId)
            .order('occurred_at');
        for (final r in (data as List<dynamic>).cast<Map<String, dynamic>>()) {
          final setId = (r['set_id'] as String?) ?? '';
          if (setId.isEmpty) continue;
          final list = _eventsBySetId.putIfAbsent(setId, () => <TagEvent>[]);
          list.add(TagEvent(
            tagName: (r['tag_name'] as String?) ?? '',
            colorValue: (r['color_value'] as int?) ?? 0xFF1976D2,
            iconCodePoint: (r['icon_code'] as int?) ?? 0,
            timestamp: DateTime.tryParse((r['occurred_at'] as String?) ?? '') ?? DateTime.now(),
            note: r['note'] as String?,
          ));
        }
        // ignore: avoid_print
        print('[TagEvents] loaded from Supabase sets=' + _eventsBySetId.length.toString());
        return;
      } catch (_) {
        // fallback below
      }
    }
    final rows = await AcademyDbService.instance.getAllTagEvents();
    for (final r in rows) {
      final setId = (r['set_id'] as String?) ?? '';
      if (setId.isEmpty) continue;
      final list = _eventsBySetId.putIfAbsent(setId, () => <TagEvent>[]);
      list.add(TagEvent(
        tagName: (r['tag_name'] as String?) ?? '',
        colorValue: (r['color_value'] as int?) ?? 0xFF1976D2,
        iconCodePoint: (r['icon_code'] as int?) ?? 0,
        timestamp: DateTime.tryParse((r['timestamp'] as String?) ?? '') ?? DateTime.now(),
        note: r['note'] as String?,
      ));
    }
    // ignore: avoid_print
    print('[TagEvents] loaded from SQLite sets=' + _eventsBySetId.length.toString());
  }
}


