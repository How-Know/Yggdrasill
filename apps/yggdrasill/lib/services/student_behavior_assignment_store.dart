import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/behavior_card_drag_payload.dart';
import 'learning_behavior_card_service.dart';
import 'tenant_service.dart';

class StudentBehaviorAssignment {
  final String id;
  final String studentId;
  final String? sourceBehaviorCardId;
  final String name;
  final int repeatDays;
  final bool isIrregular;
  final List<String> levelContents;
  final int selectedLevelIndex;
  final int orderIndex;

  const StudentBehaviorAssignment({
    required this.id,
    required this.studentId,
    required this.sourceBehaviorCardId,
    required this.name,
    required this.repeatDays,
    required this.isIrregular,
    required this.levelContents,
    required this.selectedLevelIndex,
    required this.orderIndex,
  });

  List<String> get safeLevelContents =>
      levelContents.isEmpty ? const <String>[''] : levelContents;

  int get safeSelectedLevelIndex =>
      selectedLevelIndex.clamp(0, safeLevelContents.length - 1).toInt();

  String get selectedLevelText => safeLevelContents[safeSelectedLevelIndex];

  StudentBehaviorAssignment copyWith({
    String? id,
    String? studentId,
    String? sourceBehaviorCardId,
    String? name,
    int? repeatDays,
    bool? isIrregular,
    List<String>? levelContents,
    int? selectedLevelIndex,
    int? orderIndex,
  }) {
    return StudentBehaviorAssignment(
      id: id ?? this.id,
      studentId: studentId ?? this.studentId,
      sourceBehaviorCardId: sourceBehaviorCardId ?? this.sourceBehaviorCardId,
      name: name ?? this.name,
      repeatDays: repeatDays ?? this.repeatDays,
      isIrregular: isIrregular ?? this.isIrregular,
      levelContents: levelContents ?? this.levelContents,
      selectedLevelIndex: selectedLevelIndex ?? this.selectedLevelIndex,
      orderIndex: orderIndex ?? this.orderIndex,
    );
  }
}

class StudentBehaviorAssignmentStore {
  StudentBehaviorAssignmentStore._internal();
  static final StudentBehaviorAssignmentStore instance =
      StudentBehaviorAssignmentStore._internal();

  final Map<String, List<StudentBehaviorAssignment>> _byStudentId =
      <String, List<StudentBehaviorAssignment>>{};
  final Map<String, Completer<void>> _loading = <String, Completer<void>>{};
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final Uuid _uuid = const Uuid();

  void _bump() {
    revision.value++;
  }

  List<StudentBehaviorAssignment> cached(String studentId) {
    return List<StudentBehaviorAssignment>.from(
      _byStudentId[studentId] ?? const <StudentBehaviorAssignment>[],
    )..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
  }

  Future<List<StudentBehaviorAssignment>> loadForStudent(
    String studentId, {
    bool force = false,
  }) async {
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
          .from('student_behavior_assignments')
          .select(
              'id,student_id,source_behavior_card_id,name,repeat_days,is_irregular,level_contents,selected_level_index,order_index')
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .order('order_index');

      int asInt(dynamic value, int fallback) {
        if (value is int) return value;
        if (value is num) return value.toInt();
        return fallback;
      }

      bool asBool(dynamic value, bool fallback) {
        if (value is bool) return value;
        if (value is num) return value != 0;
        if (value is String) {
          final v = value.trim().toLowerCase();
          if (v == 'true' || v == 't' || v == '1') return true;
          if (v == 'false' || v == 'f' || v == '0') return false;
        }
        return fallback;
      }

      List<String> parseLevels(dynamic raw) {
        final out = <String>[];
        if (raw is List) {
          for (final v in raw) {
            final text = v?.toString().trim() ?? '';
            if (text.isNotEmpty) out.add(text);
          }
        }
        return out.isEmpty ? <String>[''] : out;
      }

      final list = <StudentBehaviorAssignment>[];
      for (final raw in (data as List<dynamic>)) {
        final row = raw is Map<String, dynamic>
            ? raw
            : Map<String, dynamic>.from(raw as Map);
        final id = (row['id'] as String?)?.trim() ?? '';
        if (id.isEmpty) continue;
        final levels = parseLevels(row['level_contents']);
        final selected = asInt(row['selected_level_index'], 0)
            .clamp(0, levels.length - 1)
            .toInt();
        list.add(
          StudentBehaviorAssignment(
            id: id,
            studentId: (row['student_id'] as String?)?.trim() ?? studentId,
            sourceBehaviorCardId:
                (row['source_behavior_card_id'] as String?)?.trim(),
            name: ((row['name'] as String?) ?? '').trim(),
            repeatDays: asInt(row['repeat_days'], 1).clamp(1, 9999).toInt(),
            isIrregular: asBool(row['is_irregular'], false),
            levelContents: levels,
            selectedLevelIndex: selected,
            orderIndex: asInt(row['order_index'], 0),
          ),
        );
      }
      list.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
      _byStudentId[studentId] = list;
      _bump();
      return cached(studentId);
    } catch (e, st) {
      // ignore: avoid_print
      print('[StudentBehaviorAssignment][loadForStudent] $e\n$st');
      return cached(studentId);
    } finally {
      completer.complete();
      _loading.remove(studentId);
    }
  }

  Future<void> saveAll(
    String studentId,
    List<StudentBehaviorAssignment> assignments,
  ) async {
    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    final supa = Supabase.instance.client;
    final normalized = assignments
        .asMap()
        .entries
        .map((entry) => entry.value.copyWith(orderIndex: entry.key))
        .toList();
    final rows = normalized.map((item) {
      return {
        'id': item.id,
        'academy_id': academyId,
        'student_id': studentId,
        'source_behavior_card_id': item.sourceBehaviorCardId,
        'name': item.name,
        'repeat_days': item.repeatDays,
        'is_irregular': item.isIrregular,
        'level_contents': item.safeLevelContents,
        'selected_level_index': item.safeSelectedLevelIndex,
        'order_index': item.orderIndex,
      };
    }).toList();
    if (rows.isNotEmpty) {
      await supa
          .from('student_behavior_assignments')
          .upsert(rows, onConflict: 'id');
    }
    _byStudentId[studentId] = normalized;
    _bump();
  }

  Future<void> saveOrder(
    String studentId,
    List<StudentBehaviorAssignment> ordered,
  ) async {
    await saveAll(studentId, ordered);
  }

  Future<void> upsertFromDrop({
    required String studentId,
    required BehaviorCardDragPayload payload,
  }) async {
    final current = await loadForStudent(studentId, force: true);
    final idx = current.indexWhere((x) {
      final sourceId = (x.sourceBehaviorCardId ?? '').trim();
      return sourceId.isNotEmpty && sourceId == payload.cardId;
    });

    final levels =
        payload.levelContents.isEmpty ? const <String>[''] : payload.levelContents;
    final selected = payload.dragStartLevelIndex
        .clamp(0, levels.length - 1)
        .toInt();

    final next = List<StudentBehaviorAssignment>.from(current);
    if (idx != -1) {
      next[idx] = next[idx].copyWith(
        name: payload.name,
        repeatDays: payload.repeatDays,
        isIrregular: payload.isIrregular,
        levelContents: levels,
        selectedLevelIndex: selected,
      );
    } else {
      next.add(
        StudentBehaviorAssignment(
          id: _uuid.v4(),
          studentId: studentId,
          sourceBehaviorCardId: payload.cardId,
          name: payload.name,
          repeatDays: payload.repeatDays,
          isIrregular: payload.isIrregular,
          levelContents: levels,
          selectedLevelIndex: selected,
          orderIndex: next.length,
        ),
      );
    }
    await saveAll(studentId, next);
  }

  Future<void> addFromCard({
    required String studentId,
    required LearningBehaviorCardRecord card,
  }) async {
    final payload = BehaviorCardDragPayload(
      cardId: card.id,
      name: card.name,
      repeatDays: card.repeatDays,
      isIrregular: card.isIrregular,
      levelContents:
          card.levelContents.isEmpty ? const <String>[''] : card.levelContents,
      dragStartLevelIndex: card.selectedLevelIndex,
      dragStartLevelText: card.safeLevels[card.safeSelectedLevelIndex],
    );
    await upsertFromDrop(studentId: studentId, payload: payload);
  }

  Future<void> delete({
    required String studentId,
    required String assignmentId,
  }) async {
    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    final supa = Supabase.instance.client;
    await supa
        .from('student_behavior_assignments')
        .delete()
        .eq('academy_id', academyId)
        .eq('student_id', studentId)
        .eq('id', assignmentId);
    final next = cached(studentId)..removeWhere((x) => x.id == assignmentId);
    await saveAll(studentId, next);
  }

  Future<void> changeLevel({
    required String studentId,
    required String assignmentId,
    required int delta,
  }) async {
    final current = await loadForStudent(studentId, force: true);
    final idx = current.indexWhere((x) => x.id == assignmentId);
    if (idx == -1) return;
    final item = current[idx];
    if (item.safeLevelContents.isEmpty) return;
    final nextLevel = (item.selectedLevelIndex + delta)
        .clamp(0, item.safeLevelContents.length - 1)
        .toInt();
    if (nextLevel == item.selectedLevelIndex) return;
    final next = List<StudentBehaviorAssignment>.from(current);
    next[idx] = item.copyWith(selectedLevelIndex: nextLevel);
    await saveAll(studentId, next);
  }
}
