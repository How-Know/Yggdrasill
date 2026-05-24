import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/student_flow.dart';
import 'tenant_service.dart';

class StudentFlowStore {
  StudentFlowStore._internal();
  static final StudentFlowStore instance = StudentFlowStore._internal();
  static const String _testFlowName = '테스트';

  final Map<String, List<StudentFlow>> _byStudentId =
      <String, List<StudentFlow>>{};
  final Map<String, Completer<void>> _loading = <String, Completer<void>>{};
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  List<StudentFlow> _withDefaultFlows(List<StudentFlow> input) {
    // 현재 정책: 모든 학생은 동일한 기본 플로우만 사용한다.
    // 기존 데이터에 중복/커스텀이 있어도 기본 이름별 대표 1개만 남겨 UI와 저장을 수렴시킨다.
    final byName = <String, StudentFlow>{};
    for (final flow in input) {
      final name = StudentFlow.normalizeName(flow.name).trim();
      if (!StudentFlow.isDefaultName(name)) continue;
      byName.putIfAbsent(name, () => flow.copyWith(name: name));
    }
    final normalized = <StudentFlow>[];
    for (final defaultName in StudentFlow.defaultNames) {
      normalized.add(
        (byName[defaultName] ??
                StudentFlow(
                  id: const Uuid().v4(),
                  name: defaultName,
                  enabled: true,
                  orderIndex: StudentFlow.defaultPriority(defaultName),
                ))
            .copyWith(
          name: defaultName,
          enabled: true,
          orderIndex: StudentFlow.defaultPriority(defaultName),
        ),
      );
    }
    return normalized
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
  }

  List<StudentFlow> _normalizeForSave(List<StudentFlow> flows) {
    final byName = <String, StudentFlow>{};
    for (final flow in flows) {
      final name = StudentFlow.normalizeName(flow.name).trim();
      if (!StudentFlow.isDefaultName(name)) continue;
      byName.putIfAbsent(name, () => flow.copyWith(name: name));
    }
    return [
      for (var i = 0; i < StudentFlow.defaultNames.length; i++)
        (byName[StudentFlow.defaultNames[i]] ??
                StudentFlow(
                  id: const Uuid().v4(),
                  name: StudentFlow.defaultNames[i],
                  enabled: true,
                  orderIndex: i,
                ))
            .copyWith(
          name: StudentFlow.defaultNames[i],
          enabled: true,
          orderIndex: i,
        ),
    ];
  }

  List<Map<String, dynamic>> _defaultRowsForStudent({
    required String academyId,
    required String studentId,
    required List<StudentFlow> flows,
  }) {
    final normalized = _normalizeForSave(flows);
    return normalized.map((flow) {
      return {
        'id': flow.id,
        'academy_id': academyId,
        'student_id': studentId,
        'name': flow.name,
        'enabled': true,
        'order_index': StudentFlow.defaultPriority(flow.name),
      };
    }).toList(growable: false);
  }

  List<StudentFlow> _syntheticDefaults() {
    return [
      for (var i = 0; i < StudentFlow.defaultNames.length; i++)
        StudentFlow(
          id: const Uuid().v4(),
          name: StudentFlow.defaultNames[i],
          enabled: true,
          orderIndex: i,
        ),
    ];
  }

  Future<void> _persistMissingDefaultRows(
    SupabaseClient supa,
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return;
    await supa
        .from('student_flows')
        .upsert(
          rows,
          onConflict: 'academy_id,student_id,name',
          ignoreDuplicates: true,
        );
  }

  List<StudentFlow> cached(String studentId) {
    return List<StudentFlow>.from(
        _byStudentId[studentId] ?? const <StudentFlow>[]);
  }

  Future<List<StudentFlow>> loadForStudent(String studentId,
      {bool force = false}) async {
    if (!force && _byStudentId.containsKey(studentId)) {
      return cached(studentId);
    }
    final existing = _loading[studentId];
    if (existing != null) {
      await existing.future;
      return cached(studentId);
    }
    final completer = Completer<void>();
    _loading[studentId] = completer;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final data = await supa
          .from('student_flows')
          .select('id,student_id,name,enabled,order_index')
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .order('order_index');
      final List<StudentFlow> flows = [];
      for (final row in (data as List<dynamic>).cast<Map<String, dynamic>>()) {
        final id = (row['id'] as String?) ?? '';
        if (id.isEmpty) continue;
        flows.add(StudentFlow(
          id: id,
          name: StudentFlow.normalizeName((row['name'] as String?) ?? ''),
          enabled: (row['enabled'] as bool?) ?? false,
          orderIndex: (row['order_index'] as int?) ?? 0,
        ));
      }
      final normalizedFlows = _withDefaultFlows(flows);
      await _persistMissingDefaultRows(
        supa,
        _defaultRowsForStudent(
          academyId: academyId,
          studentId: studentId,
          flows: normalizedFlows,
        ),
      );
      _byStudentId[studentId] = normalizedFlows;
      revision.value++;
      return cached(studentId);
    } catch (e, st) {
      // ignore: avoid_print
      print('[StudentFlow][loadForStudent] $e\n$st');
      return cached(studentId);
    } finally {
      completer.complete();
      _loading.remove(studentId);
    }
  }

  Future<void> loadForStudents(List<String> studentIds) async {
    if (studentIds.isEmpty) return;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final data = await supa
          .from('student_flows')
          .select('id,student_id,name,enabled,order_index')
          .eq('academy_id', academyId)
          .inFilter('student_id', studentIds)
          .order('student_id')
          .order('order_index');
      final Map<String, List<StudentFlow>> map = <String, List<StudentFlow>>{};
      for (final row in (data as List<dynamic>).cast<Map<String, dynamic>>()) {
        final id = (row['id'] as String?) ?? '';
        final sid = (row['student_id'] as String?) ?? '';
        if (id.isEmpty || sid.isEmpty) continue;
        map.putIfAbsent(sid, () => <StudentFlow>[]).add(StudentFlow(
              id: id,
              name: StudentFlow.normalizeName((row['name'] as String?) ?? ''),
              enabled: (row['enabled'] as bool?) ?? false,
              orderIndex: (row['order_index'] as int?) ?? 0,
            ));
      }
      final missingRows = <Map<String, dynamic>>[];
      final nextByStudentId = <String, List<StudentFlow>>{};
      for (final sid in studentIds) {
        final persistedFlows =
            List<StudentFlow>.from(map[sid] ?? const <StudentFlow>[]);
        final normalizedFlows = _withDefaultFlows(persistedFlows);
        missingRows.addAll(_defaultRowsForStudent(
          academyId: academyId,
          studentId: sid,
          flows: normalizedFlows,
        ));
        nextByStudentId[sid] = normalizedFlows;
      }
      await _persistMissingDefaultRows(supa, missingRows);
      _byStudentId.addAll(nextByStudentId);
      revision.value++;
    } catch (e, st) {
      // ignore: avoid_print
      print('[StudentFlow][loadForStudents] $e\n$st');
    }
  }

  Future<void> saveFlows(String studentId, List<StudentFlow> flows) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final normalizedFlows = _normalizeForSave(flows);
      final rows = normalizedFlows.asMap().entries.map((e) {
        final flow = e.value;
        return {
          'id': flow.id,
          'academy_id': academyId,
          'student_id': studentId,
          'name': StudentFlow.normalizeName(flow.name),
          'enabled': true,
          'order_index': e.key,
        };
      }).toList();
      if (rows.isNotEmpty) {
        await supa
            .from('student_flows')
            .upsert(
              rows,
              onConflict: 'academy_id,student_id,name',
              ignoreDuplicates: true,
            );
      }
      _byStudentId[studentId] = _withDefaultFlows(normalizedFlows);
      revision.value++;
    } catch (e, st) {
      // ignore: avoid_print
      print('[StudentFlow][saveFlows] $e\n$st');
      rethrow;
    }
  }

  Future<StudentFlow?> ensureTestFlowForStudent(String studentId) async {
    final flows = await loadForStudent(studentId);
    final idx = flows.indexWhere((flow) => flow.name.trim() == _testFlowName);
    if (idx >= 0) {
      final existing = flows[idx];
      return existing.copyWith(enabled: true, orderIndex: idx);
    }
    final next = _withDefaultFlows(flows.isEmpty ? _syntheticDefaults() : flows);
    await saveFlows(studentId, next);
    return next.firstWhere(
      (flow) => flow.name.trim() == _testFlowName,
      orElse: () => next[StudentFlow.defaultPriority(_testFlowName)],
    );
  }
}
