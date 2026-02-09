import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'tenant_service.dart';
import 'homework_store.dart';

class HomeworkAssignmentStore {
  HomeworkAssignmentStore._internal();
  static final HomeworkAssignmentStore instance =
      HomeworkAssignmentStore._internal();

  Future<Set<String>> loadAssignedItemIds(String studentId) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final rows = await supa
          .from('homework_assignments')
          .select('homework_item_id')
          .eq('academy_id', academyId)
          .eq('student_id', studentId);
      final Set<String> ids = {};
      for (final r in (rows as List<dynamic>).cast<Map<String, dynamic>>()) {
        final id = (r['homework_item_id'] as String?) ?? '';
        if (id.isNotEmpty) ids.add(id);
      }
      return ids;
    } catch (_) {
      return <String>{};
    }
  }

  Future<Map<String, int>> loadAssignmentCounts(String studentId) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final rows = await supa
          .from('homework_assignments')
          .select('homework_item_id')
          .eq('academy_id', academyId)
          .eq('student_id', studentId);
      final Map<String, int> counts = {};
      for (final r in (rows as List<dynamic>).cast<Map<String, dynamic>>()) {
        final id = (r['homework_item_id'] as String?) ?? '';
        if (id.isEmpty) continue;
        counts[id] = (counts[id] ?? 0) + 1;
      }
      return counts;
    } catch (_) {
      return <String, int>{};
    }
  }

  Future<void> recordAssignments(
    String studentId,
    List<HomeworkItem> items, {
    DateTime? assignedAt,
    DateTime? dueDate,
  }) async {
    if (items.isEmpty) return;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final itemIds = items.map((e) => e.id).toSet().toList();

      final existingRows = await supa
          .from('homework_assignments')
          .select('id,homework_item_id,status,assigned_at')
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .inFilter('homework_item_id', itemIds)
          .order('assigned_at', ascending: false);

      final Map<String, Map<String, dynamic>> latestByItem = {};
      for (final r in (existingRows as List<dynamic>)
          .cast<Map<String, dynamic>>()) {
        final itemId = (r['homework_item_id'] as String?) ?? '';
        if (itemId.isEmpty || latestByItem.containsKey(itemId)) continue;
        latestByItem[itemId] = r;
      }

      final List<String> carriedOverIds = [];
      final List<Map<String, dynamic>> rows = [];
      final now = assignedAt ?? DateTime.now();
      for (final item in items) {
        final last = latestByItem[item.id];
        final String? lastId = last?['id'] as String?;
        final String? lastStatus = last?['status'] as String?;
        if (lastId != null && lastStatus != 'completed') {
          carriedOverIds.add(lastId);
        }
        rows.add({
          'id': const Uuid().v4(),
          'academy_id': academyId,
          'student_id': studentId,
          'homework_item_id': item.id,
          'assigned_at': now.toUtc().toIso8601String(),
          'due_date': dueDate?.toIso8601String().substring(0, 10),
          'status': 'assigned',
          'carry_over_from_id': (lastId != null && lastStatus != 'completed')
              ? lastId
              : null,
        });
      }

      if (carriedOverIds.isNotEmpty) {
        await supa
            .from('homework_assignments')
            .update({'status': 'carried_over'})
            .inFilter('id', carriedOverIds);
      }

      await supa.from('homework_assignments').insert(rows);
    } catch (e, st) {
      // ignore: avoid_print
      print('[HW_ASSIGN][record][ERROR] $e\n$st');
    }
  }
}
