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
  final int orderIndex;
  final String status;
  final String? note;
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
    required this.orderIndex,
    required this.status,
    this.note,
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
  final int orderIndex;
  final String status;
  final int progress;

  const HomeworkAssignmentBrief({
    required this.id,
    required this.homeworkItemId,
    required this.assignedAt,
    required this.dueDate,
    required this.orderIndex,
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
  static const String reservationNote = '__reserved_homework__';
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void _bump() {
    revision.value++;
  }

  String? _dueDateIso(DateTime? dueDate) {
    if (dueDate == null) return null;
    final y = dueDate.year.toString().padLeft(4, '0');
    final m = dueDate.month.toString().padLeft(2, '0');
    final d = dueDate.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  int _asInt(dynamic value, [int fallback = 0]) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  Future<List<Map<String, dynamic>>> _loadActiveRowsForDueGroup({
    required String academyId,
    required String studentId,
    required String? dueDateIso,
  }) async {
    final supa = Supabase.instance.client;
    dynamic query = supa
        .from('homework_assignments')
        .select('id,order_index,assigned_at,created_at')
        .eq('academy_id', academyId)
        .eq('student_id', studentId)
        .eq('status', 'assigned');
    if (dueDateIso == null) {
      query = query.isFilter('due_date', null);
    } else {
      query = query.eq('due_date', dueDateIso);
    }
    final rows = await query
        .order('order_index', ascending: true)
        .order('assigned_at', ascending: false)
        .order('created_at', ascending: false);
    return (rows as List<dynamic>).cast<Map<String, dynamic>>();
  }

  Future<void> _normalizeAssignedOrderForDueDateIso({
    required String academyId,
    required String studentId,
    required String? dueDateIso,
  }) async {
    final rows = await _loadActiveRowsForDueGroup(
      academyId: academyId,
      studentId: studentId,
      dueDateIso: dueDateIso,
    );
    if (rows.isEmpty) return;
    final supa = Supabase.instance.client;
    bool changed = false;
    for (int i = 0; i < rows.length; i++) {
      final row = rows[i];
      final id = (row['id'] as String?) ?? '';
      if (id.isEmpty) continue;
      if (_asInt(row['order_index']) == i) continue;
      await supa
          .from('homework_assignments')
          .update({'order_index': i})
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .eq('id', id);
      changed = true;
    }
    if (changed) {
      _bump();
    }
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
              'id,homework_item_id,assigned_at,due_date,order_index,status,note,progress,issue_type,issue_note,homework_items(id,title,type,page,count,content,flow_id)')
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .eq('status', 'assigned')
          .order('due_date', ascending: true)
          .order('order_index', ascending: true)
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
            orderIndex: parseInt(r['order_index']),
            status: (r['status'] as String?) ?? 'assigned',
            note: (r['note'] as String?)?.trim(),
            progress: parseInt(r['progress']),
            issueType: r['issue_type'] as String?,
            issueNote: r['issue_note'] as String?,
            title: (hw?['title'] as String?) ?? '',
            type: (hw?['type'] as String?)?.trim(),
            page: (hw?['page'] as String?)?.trim(),
            count: hw?['count'] is num
                ? (hw?['count'] as num).toInt()
                : int.tryParse('${hw?['count'] ?? ''}'),
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
      await supa
          .from('homework_assignments')
          .update(data)
          .eq('id', assignmentId);
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
    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    final supa = Supabase.instance.client;
    String? dueDateIso;
    try {
      final assignmentMeta = await supa
          .from('homework_assignments')
          .select('due_date')
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .eq('id', assignmentId)
          .maybeSingle();
      dueDateIso = (assignmentMeta?['due_date'] as String?)?.trim();
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
      if (markCompleted) {
        await _normalizeAssignedOrderForDueDateIso(
          academyId: academyId,
          studentId: studentId,
          dueDateIso: dueDateIso,
        );
      }
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
    if (markCompleted && updateOk) {
      await _normalizeAssignedOrderForDueDateIso(
        academyId: academyId,
        studentId: studentId,
        dueDateIso: dueDateIso,
      );
    }
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

  Future<int?> rollbackLatestCheckForItem({
    required String studentId,
    required String homeworkItemId,
    bool decrementCheckCount = true,
    bool includeConfirmIncrement = true,
  }) async {
    final itemId = homeworkItemId.trim();
    if (itemId.isEmpty) return null;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final latest = await supa
          .from('homework_assignment_checks')
          .select('id')
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .eq('homework_item_id', itemId)
          .order('checked_at', ascending: false)
          .limit(1)
          .maybeSingle();
      final checkId = (latest?['id'] as String?)?.trim() ?? '';
      final hasLatestCheck = checkId.isNotEmpty;

      if (hasLatestCheck) {
        await supa
            .from('homework_assignment_checks')
            .delete()
            .eq('academy_id', academyId)
            .eq('student_id', studentId)
            .eq('homework_item_id', itemId)
            .eq('id', checkId);
      }

      int decrementedCount = 0;
      if (decrementCheckCount) {
        // 확인 전환에서 올라간 +1을 기본 롤백하고,
        // assignment_check가 남아있다면 해당 +1도 함께 롤백한다.
        final expectedDecrement =
            (includeConfirmIncrement ? 1 : 0) + (hasLatestCheck ? 1 : 0);
        final row = await supa
            .from('homework_items')
            .select('check_count')
            .eq('academy_id', academyId)
            .eq('id', itemId)
            .maybeSingle();
        final current = (row?['check_count'] as num?)?.toInt() ?? 0;
        final next = (current - expectedDecrement).clamp(0, 1 << 30);
        decrementedCount = current - next;
        if (next != current) {
          await supa
              .from('homework_items')
              .update({'check_count': next})
              .eq('academy_id', academyId)
              .eq('id', itemId);
        }
      }
      _bump();
      return decrementedCount;
    } catch (e, st) {
      debugPrint('[HW_ASSIGN][rollback_check][ERROR] $e\n$st');
      return null;
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
          .select('id,homework_item_id,assigned_at,due_date,order_index,status,progress')
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .order('due_date', ascending: true)
          .order('order_index', ascending: true)
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
                orderIndex: parseInt(r['order_index']),
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
    String? note,
  }) async {
    if (items.isEmpty) return;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final itemIds = items.map((e) => e.id).toSet().toList();
      final dueDateIso = _dueDateIso(dueDate);

      final existingRows = await supa
          .from('homework_assignments')
          .select('id,homework_item_id,status,assigned_at,due_date')
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .inFilter('homework_item_id', itemIds)
          .order('assigned_at', ascending: false);

      final Map<String, Map<String, dynamic>> latestByItem = {};
      for (final r
          in (existingRows as List<dynamic>).cast<Map<String, dynamic>>()) {
        final itemId = (r['homework_item_id'] as String?) ?? '';
        if (itemId.isEmpty || latestByItem.containsKey(itemId)) continue;
        latestByItem[itemId] = r;
      }

      final List<String> carriedOverIds = [];
      final List<Map<String, dynamic>> rows = [];
      final now = assignedAt ?? DateTime.now();
      dynamic orderBaseQuery = supa
          .from('homework_assignments')
          .select('order_index')
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .eq('status', 'assigned');
      if (dueDateIso == null) {
        orderBaseQuery = orderBaseQuery.isFilter('due_date', null);
      } else {
        orderBaseQuery = orderBaseQuery.eq('due_date', dueDateIso);
      }
      final existingOrderRows = await orderBaseQuery
          .order('order_index', ascending: false)
          .limit(1);
      int nextOrder = 0;
      if (existingOrderRows is List && existingOrderRows.isNotEmpty) {
        final row = existingOrderRows.first as Map<String, dynamic>;
        nextOrder = _asInt(row['order_index']) + 1;
      }
      final affectedDueDates = <String?>{dueDateIso};
      for (final item in items) {
        final last = latestByItem[item.id];
        final String? lastId = last?['id'] as String?;
        final String? lastStatus = last?['status'] as String?;
        if (lastId != null && lastStatus != 'completed') {
          carriedOverIds.add(lastId);
          affectedDueDates.add((last?['due_date'] as String?)?.trim());
        }
        rows.add({
          'id': const Uuid().v4(),
          'academy_id': academyId,
          'student_id': studentId,
          'homework_item_id': item.id,
          'assigned_at': now.toUtc().toIso8601String(),
          'due_date': dueDateIso,
          'order_index': nextOrder++,
          'status': 'assigned',
          'note': note,
          'carry_over_from_id':
              (lastId != null && lastStatus != 'completed') ? lastId : null,
        });
      }

      if (carriedOverIds.isNotEmpty) {
        await supa
            .from('homework_assignments')
            .update({'status': 'carried_over'}).inFilter('id', carriedOverIds);
      }

      await supa.from('homework_assignments').insert(rows);
      for (final due in affectedDueDates) {
        await _normalizeAssignedOrderForDueDateIso(
          academyId: academyId,
          studentId: studentId,
          dueDateIso: due,
        );
      }
      _bump();
    } catch (e, st) {
      // ignore: avoid_print
      print('[HW_ASSIGN][record][ERROR] $e\n$st');
    }
  }

  Future<void> reorderAssignedInDueGroup({
    required String studentId,
    required DateTime? dueDate,
    required List<String> orderedAssignmentIds,
  }) async {
    if (orderedAssignmentIds.isEmpty) return;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final dueDateIso = _dueDateIso(dueDate);
      final rows = await _loadActiveRowsForDueGroup(
        academyId: academyId,
        studentId: studentId,
        dueDateIso: dueDateIso,
      );
      if (rows.isEmpty) return;
      final rowsById = <String, Map<String, dynamic>>{};
      for (final row in rows) {
        final id = (row['id'] as String?) ?? '';
        if (id.isEmpty) continue;
        rowsById[id] = row;
      }

      final used = <String>{};
      final reorderedIds = <String>[];
      for (final id in orderedAssignmentIds) {
        if (!rowsById.containsKey(id)) continue;
        if (!used.add(id)) continue;
        reorderedIds.add(id);
      }
      for (final row in rows) {
        final id = (row['id'] as String?) ?? '';
        if (id.isEmpty || used.contains(id)) continue;
        reorderedIds.add(id);
      }

      final supa = Supabase.instance.client;
      bool changed = false;
      for (int i = 0; i < reorderedIds.length; i++) {
        final id = reorderedIds[i];
        final currentOrder = _asInt(rowsById[id]?['order_index']);
        if (currentOrder == i) continue;
        await supa
            .from('homework_assignments')
            .update({'order_index': i})
            .eq('academy_id', academyId)
            .eq('student_id', studentId)
            .eq('id', id);
        changed = true;
      }
      if (changed) {
        _bump();
      }
    } catch (e, st) {
      debugPrint('[HW_ASSIGN][reorder][ERROR] $e\n$st');
    }
  }

  Future<void> normalizeAssignedOrderForDueGroup({
    required String studentId,
    required DateTime? dueDate,
  }) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      await _normalizeAssignedOrderForDueDateIso(
        academyId: academyId,
        studentId: studentId,
        dueDateIso: _dueDateIso(dueDate),
      );
    } catch (e, st) {
      debugPrint('[HW_ASSIGN][normalize][ERROR] $e\n$st');
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
      final rowsToClear = await supa
          .from('homework_assignments')
          .select('id,due_date')
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .eq('status', 'assigned')
          .inFilter('homework_item_id', itemIds);
      final affectedDueDates = <String?>{};
      for (final row in (rowsToClear as List<dynamic>).cast<Map<String, dynamic>>()) {
        affectedDueDates.add((row['due_date'] as String?)?.trim());
      }
      await supa
          .from('homework_assignments')
          .update({'status': nextStatus})
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .eq('status', 'assigned')
          .inFilter('homework_item_id', itemIds);
      for (final due in affectedDueDates) {
        await _normalizeAssignedOrderForDueDateIso(
          academyId: academyId,
          studentId: studentId,
          dueDateIso: due,
        );
      }
      _bump();
    } catch (e, st) {
      debugPrint('[HW_ASSIGN][clear_active][ERROR] $e\n$st');
    }
  }
}
