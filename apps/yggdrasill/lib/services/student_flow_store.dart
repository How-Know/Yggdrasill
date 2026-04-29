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
    final normalized = input
        .map(
            (flow) => flow.copyWith(name: StudentFlow.normalizeName(flow.name)))
        .toList(growable: true);
    final names = normalized.map((flow) => flow.name.trim()).toSet();
    for (final defaultName in StudentFlow.defaultNames) {
      if (names.contains(defaultName)) continue;
      normalized.add(
        StudentFlow(
          id: const Uuid().v4(),
          name: defaultName,
          enabled: true,
          orderIndex: StudentFlow.defaultPriority(defaultName),
        ),
      );
      names.add(defaultName);
    }
    return normalized.asMap().entries.map((entry) {
      final flow = entry.value;
      final priority = StudentFlow.defaultPriority(flow.name);
      return flow.copyWith(
        enabled:
            priority < StudentFlow.defaultNames.length ? true : flow.enabled,
        orderIndex: priority < StudentFlow.defaultNames.length
            ? priority
            : flow.orderIndex,
      );
    }).toList(growable: false)
      ..sort((a, b) {
        final pa = StudentFlow.defaultPriority(a.name);
        final pb = StudentFlow.defaultPriority(b.name);
        if (pa != pb) return pa.compareTo(pb);
        final order = a.orderIndex.compareTo(b.orderIndex);
        if (order != 0) return order;
        return a.name.compareTo(b.name);
      });
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
      _byStudentId[studentId] = _withDefaultFlows(flows);
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
      for (final sid in studentIds) {
        _byStudentId[sid] =
            _withDefaultFlows(List<StudentFlow>.from(map[sid] ?? const []));
      }
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
      final normalizedFlows = _withDefaultFlows(flows);
      final rows = normalizedFlows.asMap().entries.map((e) {
        final flow = e.value;
        final isDefault = StudentFlow.isDefaultName(flow.name);
        return {
          'id': flow.id,
          'academy_id': academyId,
          'student_id': studentId,
          'name': StudentFlow.normalizeName(flow.name),
          'enabled': isDefault ? true : flow.enabled,
          'order_index': e.key,
        };
      }).toList();
      if (rows.isNotEmpty) {
        await supa.from('student_flows').upsert(rows, onConflict: 'id');
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
      if (existing.enabled) return existing;
      final updated = existing.copyWith(enabled: true);
      final next = List<StudentFlow>.from(flows);
      next[idx] = updated;
      await saveFlows(studentId, next);
      return updated.copyWith(orderIndex: idx);
    }
    final created = StudentFlow(
      id: const Uuid().v4(),
      name: _testFlowName,
      enabled: true,
      orderIndex: flows.length,
    );
    final next = List<StudentFlow>.from(flows)..add(created);
    await saveFlows(studentId, next);
    return created.copyWith(orderIndex: next.length - 1);
  }
}
