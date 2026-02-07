import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/student_flow.dart';
import 'tenant_service.dart';

class StudentFlowStore {
  StudentFlowStore._internal();
  static final StudentFlowStore instance = StudentFlowStore._internal();

  final Map<String, List<StudentFlow>> _byStudentId = <String, List<StudentFlow>>{};
  final Map<String, Completer<void>> _loading = <String, Completer<void>>{};
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  List<StudentFlow> cached(String studentId) {
    return List<StudentFlow>.from(_byStudentId[studentId] ?? const <StudentFlow>[]);
  }

  Future<List<StudentFlow>> loadForStudent(String studentId, {bool force = false}) async {
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
      final academyId = await TenantService.instance.getActiveAcademyId()
          ?? await TenantService.instance.ensureActiveAcademy();
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
          name: (row['name'] as String?) ?? '',
          enabled: (row['enabled'] as bool?) ?? false,
          orderIndex: (row['order_index'] as int?) ?? 0,
        ));
      }
      _byStudentId[studentId] = flows;
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
      final academyId = await TenantService.instance.getActiveAcademyId()
          ?? await TenantService.instance.ensureActiveAcademy();
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
          name: (row['name'] as String?) ?? '',
          enabled: (row['enabled'] as bool?) ?? false,
          orderIndex: (row['order_index'] as int?) ?? 0,
        ));
      }
      for (final sid in studentIds) {
        _byStudentId[sid] = List<StudentFlow>.from(map[sid] ?? const <StudentFlow>[]);
      }
      revision.value++;
    } catch (e, st) {
      // ignore: avoid_print
      print('[StudentFlow][loadForStudents] $e\n$st');
    }
  }

  Future<void> saveFlows(String studentId, List<StudentFlow> flows) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId()
          ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final rows = flows.asMap().entries.map((e) {
        final flow = e.value;
        return {
          'id': flow.id,
          'academy_id': academyId,
          'student_id': studentId,
          'name': flow.name,
          'enabled': flow.enabled,
          'order_index': e.key,
        };
      }).toList();
      if (rows.isNotEmpty) {
        await supa.from('student_flows').upsert(rows, onConflict: 'id');
      }
      _byStudentId[studentId] = flows
          .asMap()
          .entries
          .map((e) => e.value.copyWith(orderIndex: e.key))
          .toList();
      revision.value++;
    } catch (e, st) {
      // ignore: avoid_print
      print('[StudentFlow][saveFlows] $e\n$st');
      rethrow;
    }
  }
}
