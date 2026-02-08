import 'package:flutter/material.dart';
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel, PostgresChangeEvent, PostgresChangeFilter, PostgresChangeFilterType;
import 'package:uuid/uuid.dart';
import 'tenant_service.dart';
import 'homework_assignment_store.dart';

enum HomeworkStatus { inProgress, completed, homework }

class HomeworkItem {
  final String id;
  String title;
  String body;
  Color color;
  String? flowId;
  String? type;
  String? page;
  int? count;
  String? content;
  int checkCount;
  DateTime? createdAt;
  DateTime? updatedAt;
  HomeworkStatus status;
  int phase; // 0: 종료, 1: 대기, 2: 수행, 3: 제출, 4: 확인
  int accumulatedMs; // 누적 시간(ms)
  DateTime? runStart; // 진행 중이면 시작 시각
  DateTime? completedAt;
  DateTime? firstStartedAt; // 처음 시작한 시간
  DateTime? submittedAt;
  DateTime? confirmedAt;
  DateTime? waitingAt;
  int version; // OCC 버전
  HomeworkItem({
    required this.id,
    required this.title,
    required this.body,
    this.color = const Color(0xFF1976D2),
    this.flowId,
    this.type,
    this.page,
    this.count,
    this.content,
    this.checkCount = 0,
    this.createdAt,
    this.updatedAt,
    this.status = HomeworkStatus.inProgress,
    this.phase = 1,
    this.accumulatedMs = 0,
    this.runStart,
    this.completedAt,
    this.firstStartedAt,
    this.submittedAt,
    this.confirmedAt,
    this.waitingAt,
    this.version = 1,
  });
}

class HomeworkStore {
  HomeworkStore._internal();
  static final HomeworkStore instance = HomeworkStore._internal();

  final Map<String, List<HomeworkItem>> _byStudentId = {};
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  // 확인 단계 이후, 다음 '대기' 진입 시 자동 완료 처리할 항목 ID들
  final Set<String> _autoCompleteOnNextWaiting = <String>{};
  // 간단 영속화 캐시 (앱 시작 시 한번 로드, 변경 시 저장)
  bool _loaded = false;
  RealtimeChannel? _rt;

  List<HomeworkItem> items(String studentId) {
    final list = _byStudentId[studentId] ?? const <HomeworkItem>[];
    return List<HomeworkItem>.from(list);
  }

  Future<List<HomeworkItem>> itemsForStats(
    String studentId, {
    bool excludeAssigned = false,
  }) async {
    final list = items(studentId);
    if (!excludeAssigned) return list;
    final assignedIds =
        await HomeworkAssignmentStore.instance.loadAssignedItemIds(studentId);
    if (assignedIds.isEmpty) return list;
    return list.where((e) => !assignedIds.contains(e.id)).toList();
  }

  Future<void> loadAll() async {
    if (_loaded) return;
    try {
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final data = await supa
          .from('homework_items')
          .select('id,student_id,title,body,color,flow_id,type,page,count,content,check_count,status,phase,accumulated_ms,run_start,completed_at,first_started_at,submitted_at,confirmed_at,waiting_at,created_at,updated_at,version')
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
          flowId: r['flow_id'] as String?,
          type: (r['type'] as String?)?.trim(),
          page: (r['page'] as String?)?.trim(),
          count: parseInt(r['count']),
          content: (r['content'] as String?)?.trim(),
          checkCount: parseInt(r['check_count']) ?? 0,
          createdAt: parseTsOpt(r['created_at']),
          updatedAt: parseTsOpt(r['updated_at']),
          status: HomeworkStatus.values[((r['status'] as int?) ?? 0).clamp(0, HomeworkStatus.values.length - 1)],
          phase: (parseInt(r['phase']) ?? 1).clamp(0, 4),
          accumulatedMs: (r['accumulated_ms'] as int?) ?? (r['accumulated_ms'] is num ? (r['accumulated_ms'] as num).toInt() : 0),
          runStart: parseTsOpt(r['run_start']),
          completedAt: parseTsOpt(r['completed_at']),
          firstStartedAt: parseTsOpt(r['first_started_at']),
          submittedAt: parseTsOpt(r['submitted_at']),
          confirmedAt: parseTsOpt(r['confirmed_at']),
          waitingAt: parseTsOpt(r['waiting_at']),
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
              int? _asIntOpt(dynamic v) {
                if (v == null) return null;
                if (v is num) return v.toInt();
                return int.tryParse('$v');
              }
              DateTime? _parse(dynamic v) => (v == null) ? null : DateTime.tryParse(v as String)?.toLocal();
              return HomeworkItem(
                id: (r['id'] as String?) ?? const Uuid().v4(),
                title: (r['title'] as String?) ?? '',
                body: (r['body'] as String?) ?? '',
                color: Color(_asInt(r['color'])),
                flowId: r['flow_id'] as String?,
                type: (r['type'] as String?)?.trim(),
                page: (r['page'] as String?)?.trim(),
                count: _asIntOpt(r['count']),
                content: (r['content'] as String?)?.trim(),
                checkCount: _asIntOpt(r['check_count']) ?? 0,
                createdAt: _parse(r['created_at']),
                updatedAt: _parse(r['updated_at']),
                status: HomeworkStatus.values[(_asInt(r['status'])).clamp(0, HomeworkStatus.values.length - 1)],
                phase: (_asInt(r['phase'])).clamp(0, 4),
                accumulatedMs: _asInt(r['accumulated_ms']),
                runStart: _parse(r['run_start']),
                completedAt: _parse(r['completed_at']),
                firstStartedAt: _parse(r['first_started_at']),
                submittedAt: _parse(r['submitted_at']),
                confirmedAt: _parse(r['confirmed_at']),
                waitingAt: _parse(r['waiting_at']),
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
            // '확인→대기' 진입 시 자동 완료 플래그가 있으면 즉시 완료 처리
            _maybeAutoCompleteOnWaiting(sid, it);
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
              flowId: m['flow_id'] as String?,
              type: (m['type'] as String?)?.trim(),
              page: (m['page'] as String?)?.trim(),
              count: m['count'] is num ? (m['count'] as num).toInt() : int.tryParse('${m['count']}'),
              content: (m['content'] as String?)?.trim(),
              checkCount: m['check_count'] is num
                  ? (m['check_count'] as num).toInt()
                  : int.tryParse('${m['check_count']}') ?? 0,
              createdAt: _parse(m['created_at']),
              updatedAt: _parse(m['updated_at']),
              status: HomeworkStatus.values[(_asInt(m['status'])).clamp(0, HomeworkStatus.values.length - 1)],
              phase: (_asInt(m['phase'])).clamp(0, 4),
              accumulatedMs: _asInt(m['accumulated_ms']),
              runStart: _parse(m['run_start']),
              completedAt: _parse(m['completed_at']),
              firstStartedAt: _parse(m['first_started_at']),
              submittedAt: _parse(m['submitted_at']),
              confirmedAt: _parse(m['confirmed_at']),
              waitingAt: _parse(m['waiting_at']),
              version: _asInt(m['version']),
            );
            final list = _byStudentId.putIfAbsent(sid, () => <HomeworkItem>[]);
            final idx = list.indexWhere((e) => e.id == updated.id);
            if (idx != -1) {
              list[idx] = updated;
              // '확인→대기' 진입 시 자동 완료 플래그가 있으면 즉시 완료 처리
              _maybeAutoCompleteOnWaiting(sid, updated);
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
        'flow_id': it.flowId,
        'type': it.type,
        'page': it.page,
        'count': it.count,
        'content': it.content,
        'check_count': it.checkCount,
        'status': it.status.index,
        'phase': it.phase,
        'accumulated_ms': it.accumulatedMs,
        'run_start': it.runStart?.toUtc().toIso8601String(),
        'completed_at': it.completedAt?.toUtc().toIso8601String(),
        'first_started_at': it.firstStartedAt?.toUtc().toIso8601String(),
        'submitted_at': it.submittedAt?.toUtc().toIso8601String(),
        'confirmed_at': it.confirmedAt?.toUtc().toIso8601String(),
        'waiting_at': it.waitingAt?.toUtc().toIso8601String(),
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

  HomeworkItem add(
    String studentId, {
    required String title,
    required String body,
    Color color = const Color(0xFF1976D2),
    String? flowId,
    String? type,
    String? page,
    int? count,
    String? content,
  }) {
    final id = const Uuid().v4();
    final item = HomeworkItem(
      id: id,
      title: title,
      body: body,
      color: color,
      flowId: flowId,
      type: type,
      page: page,
      count: count,
      content: content,
      checkCount: 0,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      version: 1,
    );
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

  Future<void> submit(String studentId, String id) async {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    try {
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      await Supabase.instance.client.rpc('homework_submit', params: {
        'p_item_id': id,
        'p_academy_id': academyId,
      });
      // 비동기 보정: 리얼타임 지연 시 강제 재로드
      unawaited(_reloadStudent(studentId));
    } catch (e) {
      // ignore: avoid_print
      print('[HW][submit][ERROR] ' + e.toString());
    }
  }

  Future<void> confirm(String studentId, String id) async {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    try {
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      await Supabase.instance.client.rpc('homework_confirm', params: {
        'p_item_id': id,
        'p_academy_id': academyId,
      });
      unawaited(_reloadStudent(studentId));
    } catch (e) {
      // ignore: avoid_print
      print('[HW][confirm][ERROR] ' + e.toString());
    }
  }

  Future<void> waitPhase(String studentId, String id) async {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    try {
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      await Supabase.instance.client.rpc('homework_wait', params: {
        'p_item_id': id,
        'p_academy_id': academyId,
      });
      unawaited(_reloadStudent(studentId));
    } catch (e) {
      // ignore: avoid_print
      print('[HW][wait][ERROR] ' + e.toString());
    }
  }

  void _maybeAutoCompleteOnWaiting(String studentId, HomeworkItem item) {
    if (item.phase == 1 /* waiting */ && _autoCompleteOnNextWaiting.remove(item.id)) {
      // 확인 → 대기로 전이된 첫 타이밍에 자동 완료
      unawaited(complete(studentId, item.id));
    }
  }

  // 제출 상태에서 더블클릭 시, 다음 '대기' 진입에 자동 완료되도록 표시
  void markAutoCompleteOnNextWaiting(String id) {
    _autoCompleteOnNextWaiting.add(id);
  }

  HomeworkItem continueAdd(
    String studentId,
    String sourceId, {
    required String body,
    String? flowId,
    String? type,
    String? page,
    int? count,
    String? content,
  }) {
    final list = _byStudentId[studentId];
    if (list == null) {
      return add(
        studentId,
        title: '과제',
        body: body,
        flowId: flowId,
        type: type,
        page: page,
        count: count,
        content: content ?? body,
      );
    }
    final idx = list.indexWhere((e) => e.id == sourceId);
    if (idx == -1) {
      return add(
        studentId,
        title: '과제',
        body: body,
        flowId: flowId,
        type: type,
        page: page,
        count: count,
        content: content ?? body,
      );
    }
    final src = list[idx];
    final created = add(
      studentId,
      title: src.title,
      body: body,
      color: src.color,
      flowId: flowId ?? src.flowId,
      type: type ?? src.type,
      page: page ?? src.page,
      count: count ?? src.count,
      content: content ?? src.content ?? body,
    );
    // add()가 서버 upsert를 처리함
    return created;
  }

  // 하원 시 미완료 과제들을 숙제로 표시
  void markIncompleteAsHomework(String studentId) {
    final list = _byStudentId[studentId];
    if (list == null) return;
    bool changed = false;
    final List<HomeworkItem> newlyAssigned = [];
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
          newlyAssigned.add(e);
        }
      }
    }
    if (changed) {
      _bump();
      for (final e in list.where((e) => e.status == HomeworkStatus.homework)) {
        unawaited(_upsertItem(studentId, e));
      }
      if (newlyAssigned.isNotEmpty) {
        unawaited(HomeworkAssignmentStore.instance
            .recordAssignments(studentId, newlyAssigned));
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
          .select('id,student_id,title,body,color,flow_id,type,page,count,content,check_count,status,phase,accumulated_ms,run_start,completed_at,first_started_at,submitted_at,confirmed_at,waiting_at,created_at,updated_at,version')
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
          flowId: r['flow_id'] as String?,
          type: (r['type'] as String?)?.trim(),
          page: (r['page'] as String?)?.trim(),
          count: _asInt(r['count']),
          content: (r['content'] as String?)?.trim(),
          checkCount: _asInt(r['check_count']),
          createdAt: _parse(r['created_at']),
          updatedAt: _parse(r['updated_at']),
          status: HomeworkStatus.values[(_asInt(r['status'])).clamp(0, HomeworkStatus.values.length - 1)],
          phase: (_asInt(r['phase'])).clamp(0, 4),
          accumulatedMs: _asInt(r['accumulated_ms']),
          runStart: _parse(r['run_start']),
          completedAt: _parse(r['completed_at']),
          firstStartedAt: _parse(r['first_started_at']),
          submittedAt: _parse(r['submitted_at']),
          confirmedAt: _parse(r['confirmed_at']),
          waitingAt: _parse(r['waiting_at']),
          version: _asInt(r['version']),
        ));
      }
      _byStudentId[studentId] = list;
      _bump();
    } catch (_) {}
  }
}
