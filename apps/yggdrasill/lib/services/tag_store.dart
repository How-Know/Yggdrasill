import 'package:flutter/material.dart';
import 'academy_db.dart';
import 'runtime_flags.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel, PostgresChangeEvent, PostgresChangeFilter, PostgresChangeFilterType;
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
  RealtimeChannel? _rt;
  // UI 갱신용 개정 카운터
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  void _bump(){ revision.value++; }

  List<TagEvent> getEventsForSet(String setId) {
    return List<TagEvent>.from(_eventsBySetId[setId] ?? const []);
  }

  Future<void> _syncSetToSupabase(String setId, String studentId, List<TagEvent> events) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      // 전체 교체: 해당 set_id 레코드 삭제 후 일괄 insert
      await supa.from('tag_events').delete().match({'academy_id': academyId, 'set_id': setId, 'student_id': studentId});
      if (events.isNotEmpty) {
        final rows = events.map((e) => {
          // id는 서버 기본 생성 사용. 필요 시 UUID 부여 가능
          'academy_id': academyId,
          'set_id': setId,
          'student_id': studentId,
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

  void setEventsForSet(String setId, String studentId, List<TagEvent> events) {
    // 즉시 저장으로 전환했기 때문에 닫기 시점에는 메모리만 최신화
    _eventsBySetId[setId] = List<TagEvent>.from(events);
  }

  Future<void> _appendToSupabase(String setId, String studentId, TagEvent event) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final String id = _eventId(studentId, event);
      final int colorSigned = (event.colorValue).toSigned(32);
      await supa.from('tag_events').upsert({
        'id': id,
        'academy_id': academyId,
        'set_id': setId,
        'student_id': studentId,
        'tag_name': event.tagName,
        'color_value': colorSigned,
        'icon_code': event.iconCodePoint,
        'occurred_at': event.timestamp.toUtc().toIso8601String(),
        'note': event.note,
      }, onConflict: 'id');
      // ignore: avoid_print
      print('[TagEvents] upsert ok id=' + id + ' student=' + studentId + ' set=' + setId + ' tag=' + event.tagName);
    } catch (e, st) {
      // ignore: avoid_print
      print('[TagEvents][ERROR] upsert failed: ' + e.toString() + '\n' + st.toString());
    }
  }

  String _eventId(String studentId, TagEvent event) {
    final int epochMsUtc = event.timestamp.toUtc().millisecondsSinceEpoch;
    return const Uuid().v5(
      Uuid.NAMESPACE_URL,
      '$studentId|$epochMsUtc|${event.tagName}',
    );
  }

  Future<void> _deleteFromSupabase(String studentId, TagEvent event) async {
    try {
      final supa = Supabase.instance.client;
      final String id = _eventId(studentId, event);
      await supa.from('tag_events').delete().eq('id', id);
      // ignore: avoid_print
      print('[TagEvents] delete ok id=' + id + ' student=' + studentId + ' tag=' + event.tagName);
    } catch (e, st) {
      // ignore: avoid_print
      print('[TagEvents][ERROR] delete failed: ' + e.toString() + '\n' + st.toString());
    }
  }

  void appendEvent(String setId, String studentId, TagEvent event) {
    final list = _eventsBySetId.putIfAbsent(setId, () => <TagEvent>[]);
    list.add(event);
    // 서버 즉시 저장만 수행 (로컬 DB 비사용)
    _appendToSupabase(setId, studentId, event);
  }

  void updateEvent(String setId, String studentId, TagEvent event) {
    final list = _eventsBySetId.putIfAbsent(setId, () => <TagEvent>[]);
    final targetEpoch = event.timestamp.toUtc().millisecondsSinceEpoch;
    final idx = list.indexWhere((e) =>
        e.tagName == event.tagName &&
        e.timestamp.toUtc().millisecondsSinceEpoch == targetEpoch);
    if (idx == -1) {
      list.add(event);
    } else {
      list[idx] = event;
    }
    _bump();
    _appendToSupabase(setId, studentId, event);
  }

  void deleteEvent(String setId, String studentId, TagEvent event) {
    final list = _eventsBySetId[setId];
    if (list == null) return;
    final targetEpoch = event.timestamp.toUtc().millisecondsSinceEpoch;
    list.removeWhere((e) =>
        e.tagName == event.tagName &&
        e.timestamp.toUtc().millisecondsSinceEpoch == targetEpoch);
    _bump();
    _deleteFromSupabase(studentId, event);
  }

  Future<void> loadAllFromDb() async {
    _eventsBySetId.clear();
    if (preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ?? await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final data = await supa
            .from('tag_events')
            .select('set_id, student_id, tag_name, color_value, icon_code, occurred_at, note')
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
        _subscribeRealtime(academyId);
        _bump();
        return;
      } catch (_) {
        // fallback below
      }
    }
    // 서버우선만 사용. 로컬 DB는 사용하지 않음.
  }

  void _subscribeRealtime(String academyId) {
    try {
      if (_rt != null) return;
      _rt = Supabase.instance.client.channel('public:tag_events:$academyId')
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'tag_events',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (payload) {
            final m = payload.newRecord;
            if (m == null) return;
            final setId = (m['set_id'] as String?) ?? '';
            if (setId.isEmpty) return;
            final list = _eventsBySetId.putIfAbsent(setId, () => <TagEvent>[]);
            list.add(TagEvent(
              tagName: (m['tag_name'] as String?) ?? '',
              colorValue: (m['color_value'] as int?) ?? 0xFF1976D2,
              iconCodePoint: (m['icon_code'] as int?) ?? 0,
              timestamp: DateTime.tryParse((m['occurred_at'] as String?) ?? '') ?? DateTime.now(),
              note: m['note'] as String?,
            ));
            _bump();
          },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'tag_events',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (payload) {
            // 태그 이벤트는 보통 삭제를 거의 안하지만, 대응
            final m = payload.oldRecord;
            if (m == null) return;
            final setId = (m['set_id'] as String?) ?? '';
            if (setId.isEmpty) return;
            final list = _eventsBySetId[setId];
            if (list == null) return;
            list.removeWhere((e) => e.tagName == m['tag_name'] && e.timestamp.toIso8601String() == (m['occurred_at'] as String?));
            _bump();
          },
        )
        ..subscribe();
    } catch (_) {}
  }
}


