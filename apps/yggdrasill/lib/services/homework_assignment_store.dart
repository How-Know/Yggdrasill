import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'tenant_service.dart';
import 'homework_store.dart';

class HomeworkAssignmentDetail {
  final String id;
  final String homeworkItemId;
  final DateTime assignedAt;
  final DateTime? dueDate;
  final String status;
  final int progress;
  final String? issueType;
  final String? issueNote;
  final String title;
  final String? type;
  final String? page;
  final int? count;
  final String? content;
  final String? flowId;

  const HomeworkAssignmentDetail({
    required this.id,
    required this.homeworkItemId,
    required this.assignedAt,
    required this.dueDate,
    required this.status,
    required this.progress,
    required this.issueType,
    required this.issueNote,
    required this.title,
    required this.type,
    required this.page,
    required this.count,
    required this.content,
    required this.flowId,
  });
}

class HomeworkAssignmentBrief {
  final String id;
  final String homeworkItemId;
  final DateTime assignedAt;
  final DateTime? dueDate;
  final String status;
  final int progress;

  const HomeworkAssignmentBrief({
    required this.id,
    required this.homeworkItemId,
    required this.assignedAt,
    required this.dueDate,
    required this.status,
    required this.progress,
  });
}

class HomeworkAssignmentCheck {
  final String id;
  final String homeworkItemId;
  final String? assignmentId;
  final DateTime checkedAt;
  final int progress;

  const HomeworkAssignmentCheck({
    required this.id,
    required this.homeworkItemId,
    required this.assignmentId,
    required this.checkedAt,
    required this.progress,
  });
}

class HomeworkAssignmentStore {
  HomeworkAssignmentStore._internal();
  static final HomeworkAssignmentStore instance =
      HomeworkAssignmentStore._internal();
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void _bump() {
    revision.value++;
  }

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

  Future<Set<String>> loadActiveAssignedItemIds(String studentId) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final rows = await supa
          .from('homework_assignments')
          .select('homework_item_id')
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .eq('status', 'assigned');
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

  Future<List<HomeworkAssignmentDetail>> loadActiveAssignments(
    String studentId,
  ) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final rows = await supa
          .from('homework_assignments')
          .select(
              'id,homework_item_id,assigned_at,due_date,status,progress,issue_type,issue_note,homework_items(id,title,type,page,count,content,flow_id)')
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .eq('status', 'assigned')
          .order('assigned_at', ascending: false);
      final List<HomeworkAssignmentDetail> list = [];
      DateTime? parseTs(dynamic v) {
        if (v == null) return null;
        final s = v as String?;
        if (s == null || s.isEmpty) return null;
        return DateTime.tryParse(s)?.toLocal();
      }
      int parseInt(dynamic v) {
        if (v == null) return 0;
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v) ?? 0;
        return 0;
      }
      for (final r in (rows as List<dynamic>).cast<Map<String, dynamic>>()) {
        final hw = r['homework_items'] as Map<String, dynamic>?;
        list.add(
          HomeworkAssignmentDetail(
            id: (r['id'] as String?) ?? '',
            homeworkItemId: (r['homework_item_id'] as String?) ?? '',
            assignedAt: parseTs(r['assigned_at']) ?? DateTime.now(),
            dueDate: parseTs(r['due_date']),
            status: (r['status'] as String?) ?? 'assigned',
            progress: parseInt(r['progress']),
            issueType: r['issue_type'] as String?,
            issueNote: r['issue_note'] as String?,
            title: (hw?['title'] as String?) ?? '',
            type: (hw?['type'] as String?)?.trim(),
            page: (hw?['page'] as String?)?.trim(),
            count: hw?['count'] is num ? (hw?['count'] as num).toInt() : int.tryParse('${hw?['count'] ?? ''}'),
            content: (hw?['content'] as String?)?.trim(),
            flowId: hw?['flow_id'] as String?,
          ),
        );
      }
      return list;
    } catch (_) {
      return <HomeworkAssignmentDetail>[];
    }
  }

  Future<bool> updateAssignment(
    String assignmentId, {
    required int progress,
    String? issueType,
    String? issueNote,
    String? status,
  }) async {
    try {
      final supa = Supabase.instance.client;
      final data = <String, dynamic>{
        'progress': progress.clamp(0, 150),
        'issue_type': issueType,
        'issue_note': issueNote,
      };
      if (status != null) {
        data['status'] = status;
      }
      await supa.from('homework_assignments').update(data).eq('id', assignmentId);
      _bump();
      return true;
    } catch (e, st) {
      debugPrint('[HW_ASSIGN][update][ERROR] $e\n$st');
      return false;
    }
  }

  Future<bool> saveAssignmentCheck({
    required String assignmentId,
    required String studentId,
    required String homeworkItemId,
    required int progress,
    String? issueType,
    String? issueNote,
    bool markCompleted = false,
  }) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final String? updatedBy = supa.auth.currentUser?.id;
      await supa.rpc('homework_assignment_check', params: {
        'p_assignment_id': assignmentId,
        'p_academy_id': academyId,
        'p_progress': progress.clamp(0, 150),
        'p_issue_type': issueType,
        'p_issue_note': issueNote,
        'p_status': markCompleted ? 'completed' : null,
        'p_updated_by': updatedBy,
      });
      _bump();
      return true;
    } catch (e, st) {
      debugPrint('[HW_ASSIGN][rpc][ERROR] $e\n$st');
      // Fall back to client-side update + check insert.
    }

    final updateOk = await updateAssignment(
      assignmentId,
      progress: progress,
      issueType: issueType,
      issueNote: issueNote,
      status: markCompleted ? 'completed' : null,
    );
    final checkOk = await recordAssignmentCheck(
      studentId: studentId,
      homeworkItemId: homeworkItemId,
      assignmentId: assignmentId,
      progress: progress,
    );
    return updateOk && checkOk;
  }

  Future<bool> recordAssignmentCheck({
    required String studentId,
    required String homeworkItemId,
    required String assignmentId,
    required int progress,
    bool incrementCheckCount = true,
  }) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      await supa.from('homework_assignment_checks').insert({
        'id': const Uuid().v4(),
        'academy_id': academyId,
        'student_id': studentId,
        'homework_item_id': homeworkItemId,
        'assignment_id': assignmentId,
        'checked_at': DateTime.now().toUtc().toIso8601String(),
        'progress': progress.clamp(0, 150),
      });
      if (incrementCheckCount) {
        final row = await supa
            .from('homework_items')
            .select('check_count')
            .eq('academy_id', academyId)
            .eq('id', homeworkItemId)
            .maybeSingle();
        final current = (row?['check_count'] as num?)?.toInt() ?? 0;
        await supa
            .from('homework_items')
            .update({'check_count': current + 1})
            .eq('academy_id', academyId)
            .eq('id', homeworkItemId);
      }
      _bump();
      return true;
    } catch (e, st) {
      debugPrint('[HW_ASSIGN][check][ERROR] $e\n$st');
      return false;
    }
  }

  Future<void> recordAssignmentCheckForConfirm({
    required String studentId,
    required String homeworkItemId,
  }) async {
    try {
      final assignments =
          await loadAssignmentsForItem(studentId, homeworkItemId);
      if (assignments.isEmpty) return;
      bool sameDay(DateTime a, DateTime b) =>
          a.year == b.year && a.month == b.month && a.day == b.day;
      final now = DateTime.now();
      final todayAssignments = assignments
          .where((a) => a.dueDate != null && sameDay(a.dueDate!, now))
          .toList();
      HomeworkAssignmentBrief target;
      if (todayAssignments.isNotEmpty) {
        todayAssignments.sort((a, b) => a.assignedAt.compareTo(b.assignedAt));
        target = todayAssignments.last;
      } else {
        assignments.sort((a, b) => a.assignedAt.compareTo(b.assignedAt));
        target = assignments.last;
      }
      await recordAssignmentCheck(
        studentId: studentId,
        homeworkItemId: homeworkItemId,
        assignmentId: target.id,
        progress: target.progress,
        incrementCheckCount: false,
      );
    } catch (_) {}
  }

  Future<Map<String, List<HomeworkAssignmentBrief>>> loadAssignmentsForStudent(
    String studentId,
  ) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final rows = await supa
          .from('homework_assignments')
          .select('id,homework_item_id,assigned_at,due_date,status,progress')
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .order('assigned_at', ascending: true);
      DateTime parseTs(dynamic v) {
        final s = v as String?;
        return DateTime.tryParse(s ?? '')?.toLocal() ?? DateTime.now();
      }

      DateTime? parseDate(dynamic v) {
        final s = v as String?;
        if (s == null || s.isEmpty) return null;
        return DateTime.tryParse(s)?.toLocal();
      }

      int parseInt(dynamic v) {
        if (v == null) return 0;
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v) ?? 0;
        return 0;
      }

      final Map<String, List<HomeworkAssignmentBrief>> map = {};
      for (final r in (rows as List<dynamic>).cast<Map<String, dynamic>>()) {
        final itemId = (r['homework_item_id'] as String?) ?? '';
        if (itemId.isEmpty) continue;
        map.putIfAbsent(itemId, () => <HomeworkAssignmentBrief>[]).add(
              HomeworkAssignmentBrief(
                id: (r['id'] as String?) ?? '',
                homeworkItemId: itemId,
                assignedAt: parseTs(r['assigned_at']),
                dueDate: parseDate(r['due_date']),
                status: (r['status'] as String?) ?? 'assigned',
                progress: parseInt(r['progress']),
              ),
            );
      }
      return map;
    } catch (_) {
      return <String, List<HomeworkAssignmentBrief>>{};
    }
  }

  Future<List<HomeworkAssignmentBrief>> loadAssignmentsForItem(
    String studentId,
    String homeworkItemId,
  ) async {
    final map = await loadAssignmentsForStudent(studentId);
    return List<HomeworkAssignmentBrief>.from(map[homeworkItemId] ?? const []);
  }

  Future<Map<String, List<HomeworkAssignmentCheck>>> loadChecksForStudent(
    String studentId,
  ) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final rows = await supa
          .from('homework_assignment_checks')
          .select('id,homework_item_id,assignment_id,checked_at,progress')
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .order('checked_at', ascending: true);
      DateTime parseTs(dynamic v) {
        final s = v as String?;
        return DateTime.tryParse(s ?? '')?.toLocal() ?? DateTime.now();
      }

      int parseInt(dynamic v) {
        if (v == null) return 0;
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v) ?? 0;
        return 0;
      }

      final Map<String, List<HomeworkAssignmentCheck>> map = {};
      for (final r in (rows as List<dynamic>).cast<Map<String, dynamic>>()) {
        final itemId = (r['homework_item_id'] as String?) ?? '';
        if (itemId.isEmpty) continue;
        map.putIfAbsent(itemId, () => <HomeworkAssignmentCheck>[]).add(
              HomeworkAssignmentCheck(
                id: (r['id'] as String?) ?? '',
                homeworkItemId: itemId,
                assignmentId: r['assignment_id'] as String?,
                checkedAt: parseTs(r['checked_at']),
                progress: parseInt(r['progress']),
              ),
            );
      }
      return map;
    } catch (_) {
      return <String, List<HomeworkAssignmentCheck>>{};
    }
  }

  Future<List<HomeworkAssignmentCheck>> loadChecksForItem(
    String studentId,
    String homeworkItemId,
  ) async {
    final map = await loadChecksForStudent(studentId);
    return List<HomeworkAssignmentCheck>.from(map[homeworkItemId] ?? const []);
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
      _bump();
    } catch (e, st) {
      // ignore: avoid_print
      print('[HW_ASSIGN][record][ERROR] $e\n$st');
    }
  }

  Future<void> clearActiveAssignmentsForItems(
    String studentId,
    List<String> itemIds, {
    String nextStatus = 'carried_over',
  }) async {
    if (itemIds.isEmpty) return;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      await supa
          .from('homework_assignments')
          .update({'status': nextStatus})
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .eq('status', 'assigned')
          .inFilter('homework_item_id', itemIds);
      _bump();
    } catch (e, st) {
      debugPrint('[HW_ASSIGN][clear_active][ERROR] $e\n$st');
    }
  }
}
