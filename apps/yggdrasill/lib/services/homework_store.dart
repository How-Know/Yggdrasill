import 'package:flutter/material.dart';
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel, PostgresChangeEvent, PostgresChangeFilter, PostgresChangeFilterType;
import 'package:uuid/uuid.dart';
import 'tenant_service.dart';

enum HomeworkStatus { inProgress, completed, homework }

class HomeworkItem {
  final String id;
  String title;
  String body;
  Color color;
  HomeworkStatus status;
  int accumulatedMs; // 누적 시간(ms)
  DateTime? runStart; // 진행 중이면 시작 시각
  DateTime? completedAt;
  DateTime? firstStartedAt; // 처음 시작한 시간
  int version; // OCC 버전
  HomeworkItem({
    required this.id,
    required this.title,
    required this.body,
    this.color = const Color(0xFF1976D2),
    this.status = HomeworkStatus.inProgress,
    this.accumulatedMs = 0,
    this.runStart,
    this.completedAt,
    this.firstStartedAt,
    this.version = 1,
  });
}

class HomeworkStore {
  HomeworkStore._internal();
  static final HomeworkStore instance = HomeworkStore._internal();

  final Map<String, List<HomeworkItem>> _byStudentId = {};
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  // 간단 영속화 캐시 (앱 시작 시 한번 로드, 변경 시 저장)
  bool _loaded = false;
  RealtimeChannel? _rt;

  List<HomeworkItem> items(String studentId) {
    final list = _byStudentId[studentId] ?? const <HomeworkItem>[];
    return List<HomeworkItem>.from(list);
  }

  Future<void> loadAll() async {
    if (_loaded) return;
    try {
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final data = await supa
          .from('homework_items')
          .select('id,student_id,title,body,color,status,accumulated_ms,run_start,completed_at,first_started_at,created_at,updated_at,version')
          .eq('academy_id', academyId)
          .order('updated_at', ascending: false);
      _byStudentId.clear();
      for (final r in (data as List<dynamic>).cast<Map<String, dynamic>>()) {
        final sid = (r['student_id'] as String?) ?? '';
        if (sid.isEmpty) continue;
        DateTime? parseTsOpt(dynamic v) {
          if (v == null) return null;
          final s = v as String?;
          if (s == null || s.isEmpty) return null;
          return DateTime.parse(s).toLocal();
        }
        int? parseInt(dynamic v) {
          if (v == null) return null;
          if (v is int) return v;
          if (v is num) return v.toInt();
          if (v is String) return int.tryParse(v);
          return null;
        }
        final item = HomeworkItem(
          id: (r['id'] as String?) ?? const Uuid().v4(),
          title: (r['title'] as String?) ?? '',
          body: (r['body'] as String?) ?? '',
          color: Color(parseInt(r['color']) ?? 0xFF1976D2),
          status: HomeworkStatus.values[((r['status'] as int?) ?? 0).clamp(0, HomeworkStatus.values.length - 1)],
          accumulatedMs: (r['accumulated_ms'] as int?) ?? (r['accumulated_ms'] is num ? (r['accumulated_ms'] as num).toInt() : 0),
          runStart: parseTsOpt(r['run_start']),
          completedAt: parseTsOpt(r['completed_at']),
          firstStartedAt: parseTsOpt(r['first_started_at']),
          version: parseInt(r['version']) ?? 1,
        );
        _byStudentId.putIfAbsent(sid, () => <HomeworkItem>[]).add(item);
      }
      _loaded = true;
      _bump();
      _subscribeRealtime(academyId);
    } catch (e, st) {
      // ignore: avoid_print
      print('[HW][loadAll][ERROR] $e\n$st');
    }
  }

  void _subscribeRealtime(String academyId) {
    try {
      if (_rt != null) return;
      _rt = Supabase.instance.client.channel('public:homework_items:' + academyId)
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'homework_items',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (payload) {
            final m = payload.newRecord;
            if (m == null) return;
            final String sid = (m['student_id'] as String?) ?? '';
            if (sid.isEmpty) return;
            HomeworkItem parse(Map<String, dynamic> r) {
              int _asInt(dynamic v) => (v is num) ? v.toInt() : int.tryParse('$v') ?? 0;
              DateTime? _parse(dynamic v) => (v == null) ? null : DateTime.tryParse(v as String)?.toLocal();
              return HomeworkItem(
                id: (r['id'] as String?) ?? const Uuid().v4(),
                title: (r['title'] as String?) ?? '',
                body: (r['body'] as String?) ?? '',
                color: Color(_asInt(r['color'])),
                status: HomeworkStatus.values[(_asInt(r['status'])).clamp(0, HomeworkStatus.values.length - 1)],
                accumulatedMs: _asInt(r['accumulated_ms']),
                runStart: _parse(r['run_start']),
                completedAt: _parse(r['completed_at']),
                firstStartedAt: _parse(r['first_started_at']),
                version: _asInt(r['version']),
              );
            }
            final it = parse(m);
            final list = _byStudentId.putIfAbsent(sid, () => <HomeworkItem>[]);
            final idx = list.indexWhere((e) => e.id == it.id);
            if (idx == -1) {
              list.insert(0, it);
            } else {
              list[idx] = it;
            }
            _bump();
          },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'homework_items',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (payload) {
            final m = payload.newRecord;
            if (m == null) return;
            final String sid = (m['student_id'] as String?) ?? '';
            if (sid.isEmpty) return;
            int _asInt(dynamic v) => (v is num) ? v.toInt() : int.tryParse('$v') ?? 0;
            DateTime? _parse(dynamic v) => (v == null) ? null : DateTime.tryParse(v as String)?.toLocal();
            final updated = HomeworkItem(
              id: (m['id'] as String?) ?? const Uuid().v4(),
              title: (m['title'] as String?) ?? '',
              body: (m['body'] as String?) ?? '',
              color: Color(_asInt(m['color'])),
              status: HomeworkStatus.values[(_asInt(m['status'])).clamp(0, HomeworkStatus.values.length - 1)],
              accumulatedMs: _asInt(m['accumulated_ms']),
              runStart: _parse(m['run_start']),
              completedAt: _parse(m['completed_at']),
              firstStartedAt: _parse(m['first_started_at']),
              version: _asInt(m['version']),
            );
            final list = _byStudentId.putIfAbsent(sid, () => <HomeworkItem>[]);
            final idx = list.indexWhere((e) => e.id == updated.id);
            if (idx != -1) {
              list[idx] = updated;
              _bump();
            }
          },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'homework_items',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'academy_id', value: academyId),
          callback: (payload) {
            final old = payload.oldRecord;
            if (old == null) return;
            final String id = (old['id'] as String?) ?? '';
            if (id.isEmpty) return;
            for (final entry in _byStudentId.entries) {
              final int before = entry.value.length;
              entry.value.removeWhere((e) => e.id == id);
              final bool removed = entry.value.length < before;
              if (removed) {
                _bump();
                break;
              }
            }
          },
        )
        ..subscribe();
    } catch (_) {}
  }

  Future<void> _upsertItem(String studentId, HomeworkItem it) async {
    try {
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final base = {
        'student_id': studentId,
        'title': it.title,
        'body': it.body,
        'color': it.color.value,
        'status': it.status.index,
        'accumulated_ms': it.accumulatedMs,
        'run_start': it.runStart?.toUtc().toIso8601String(),
        'completed_at': it.completedAt?.toUtc().toIso8601String(),
        'first_started_at': it.firstStartedAt?.toUtc().toIso8601String(),
      };
      // OCC update: 0행이면 예외 없이 빈 배열을 받도록 select() (list)로 처리
      final updatedRows = await supa
          .from('homework_items')
          .update(base)
          .eq('id', it.id)
          .eq('version', it.version)
          .select('version');
      if (updatedRows is List && updatedRows.isNotEmpty) {
        final row = (updatedRows.first as Map<String, dynamic>);
        it.version = (row['version'] as num?)?.toInt() ?? (it.version + 1);
        return;
      }
      // Insert if not exists
      final insertRow = {
        'id': it.id,
        'academy_id': academyId,
        ...base,
        'version': it.version,
      };
      final insRows = await supa
          .from('homework_items')
          .insert(insertRow)
          .select('version');
      if (insRows is List && insRows.isNotEmpty) {
        final row = (insRows.first as Map<String, dynamic>);
        it.version = (row['version'] as num?)?.toInt() ?? 1;
        return;
      }
      // Conflict fallback
      await _reloadStudent(studentId);
      throw StateError('CONFLICT_HOMEWORK_VERSION');
    } catch (e, st) {
      // ignore: avoid_print
      print('[HW][upsert][ERROR] ' + e.toString() + '\n' + st.toString());
    }
  }

  HomeworkItem add(String studentId, {required String title, required String body, Color color = const Color(0xFF1976D2)}) {
    final id = const Uuid().v4();
    final item = HomeworkItem(id: id, title: title, body: body, color: color, version: 1);
    final list = _byStudentId.putIfAbsent(studentId, () => <HomeworkItem>[]);
    list.insert(0, item);
    _bump();
    unawaited(_upsertItem(studentId, item));
    return item;
  }

  void edit(String studentId, HomeworkItem updated) {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == updated.id);
    if (idx != -1) {
      list[idx] = updated;
      _bump();
      unawaited(_upsertItem(studentId, updated));
    }
  }

  void remove(String studentId, String id) {
    final list = _byStudentId[studentId];
    if (list == null) return;
    list.removeWhere((e) => e.id == id);
    _bump();
    unawaited(() async {
      try {
        final supa = Supabase.instance.client;
        await supa.from('homework_items').delete().eq('id', id);
      } catch (e) {}
    }());
  }

  HomeworkItem? getById(String studentId, String id) {
    final list = _byStudentId[studentId];
    if (list == null) return null;
    final idx = list.indexWhere((e) => e.id == id);
    return idx == -1 ? null : list[idx];
  }

  HomeworkItem? runningOf(String studentId) {
    final list = _byStudentId[studentId];
    if (list == null) return null;
    final idx = list.indexWhere((e) => e.runStart != null);
    return idx == -1 ? null : list[idx];
  }

  Future<void> start(String studentId, String id) async {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    try {
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      await Supabase.instance.client.rpc('homework_start', params: {
        'p_item_id': id,
        'p_student_id': studentId,
        'p_academy_id': academyId,
      });
    } catch (e) {
      // ignore
    }
  }

  Future<void> pause(String studentId, String id) async {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    try {
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      await Supabase.instance.client.rpc('homework_pause', params: {
        'p_item_id': id,
        'p_academy_id': academyId,
      });
    } catch (_) {}
  }

  Future<void> complete(String studentId, String id) async {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    try {
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      await Supabase.instance.client.rpc('homework_complete', params: {
        'p_item_id': id,
        'p_academy_id': academyId,
      });
    } catch (_) {}
  }

  HomeworkItem continueAdd(String studentId, String sourceId, {required String body}) {
    final list = _byStudentId[studentId];
    if (list == null) return add(studentId, title: '과제', body: body);
    final idx = list.indexWhere((e) => e.id == sourceId);
    if (idx == -1) return add(studentId, title: '과제', body: body);
    final src = list[idx];
    final created = add(studentId, title: src.title, body: body, color: src.color);
    // add()가 서버 upsert를 처리함
    return created;
  }

  // 하원 시 미완료 과제들을 숙제로 표시
  void markIncompleteAsHomework(String studentId) {
    final list = _byStudentId[studentId];
    if (list == null) return;
    bool changed = false;
    for (final e in list) {
      if (e.status != HomeworkStatus.completed) {
        if (e.runStart != null) {
          // 진행 중이면 일시정지 후 숙제로 전환
          final now = DateTime.now();
          e.accumulatedMs += now.difference(e.runStart!).inMilliseconds;
          e.runStart = null;
        }
        if (e.status != HomeworkStatus.homework) {
          e.status = HomeworkStatus.homework;
          changed = true;
        }
      }
    }
    if (changed) {
      _bump();
      for (final e in list.where((e) => e.status == HomeworkStatus.homework)) {
        unawaited(_upsertItem(studentId, e));
      }
    }
  }

  void _bump() { revision.value++; }

  Future<void> _reloadStudent(String studentId) async {
    try {
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final data = await supa
          .from('homework_items')
          .select('id,student_id,title,body,color,status,accumulated_ms,run_start,completed_at,first_started_at,created_at,updated_at,version')
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .order('updated_at', ascending: false);
      final List<HomeworkItem> list = [];
      for (final r in (data as List<dynamic>).cast<Map<String, dynamic>>()) {
        int _asInt(dynamic v) => (v is num) ? v.toInt() : int.tryParse('$v') ?? 0;
        DateTime? _parse(dynamic v) => (v == null) ? null : DateTime.tryParse(v as String)?.toLocal();
        list.add(HomeworkItem(
          id: (r['id'] as String?) ?? const Uuid().v4(),
          title: (r['title'] as String?) ?? '',
          body: (r['body'] as String?) ?? '',
          color: Color(_asInt(r['color'])),
          status: HomeworkStatus.values[(_asInt(r['status'])).clamp(0, HomeworkStatus.values.length - 1)],
          accumulatedMs: _asInt(r['accumulated_ms']),
          runStart: _parse(r['run_start']),
          completedAt: _parse(r['completed_at']),
          firstStartedAt: _parse(r['first_started_at']),
          version: _asInt(r['version']),
        ));
      }
      _byStudentId[studentId] = list;
      _bump();
    } catch (_) {}
  }
}
