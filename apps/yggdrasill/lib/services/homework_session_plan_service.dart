import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'homework_assignment_store.dart';
import 'tenant_service.dart';

enum HomeworkPlanOrigin {
  plannedToday('planned_today'),
  directHomework('direct_homework'),
  carriedFromPrevious('carried_from_previous');

  const HomeworkPlanOrigin(this.dbValue);
  final String dbValue;

  static HomeworkPlanOrigin fromDb(Object? value) {
    return HomeworkPlanOrigin.values.firstWhere(
      (entry) => entry.dbValue == '$value',
      orElse: () => HomeworkPlanOrigin.plannedToday,
    );
  }
}

enum HomeworkPlanDestination {
  inClass('in_class'),
  homework('homework'),
  nextSession('next_session');

  const HomeworkPlanDestination(this.dbValue);
  final String dbValue;

  static HomeworkPlanDestination fromDb(Object? value) {
    return HomeworkPlanDestination.values.firstWhere(
      (entry) => entry.dbValue == '$value',
      orElse: () => HomeworkPlanDestination.inClass,
    );
  }
}

enum HomeworkPlanRolloverPolicy {
  toHomework('to_homework'),
  carryPaused('carry_paused'),
  none('none');

  const HomeworkPlanRolloverPolicy(this.dbValue);
  final String dbValue;

  static HomeworkPlanRolloverPolicy fromDb(Object? value) {
    return HomeworkPlanRolloverPolicy.values.firstWhere(
      (entry) => entry.dbValue == '$value',
      orElse: () => HomeworkPlanRolloverPolicy.toHomework,
    );
  }
}

class HomeworkSessionPlanItem {
  const HomeworkSessionPlanItem({
    required this.id,
    required this.studentId,
    required this.sourceAttendanceId,
    required this.groupId,
    required this.homeworkItemId,
    required this.origin,
    required this.destination,
    required this.rolloverPolicy,
    required this.resolution,
    required this.recommendedMinutesSnapshot,
    required this.targetClassAt,
    required this.assignmentId,
  });

  final String id;
  final String studentId;
  final String sourceAttendanceId;
  final String groupId;
  final String homeworkItemId;
  final HomeworkPlanOrigin origin;
  final HomeworkPlanDestination destination;
  final HomeworkPlanRolloverPolicy rolloverPolicy;
  final String? resolution;
  final int? recommendedMinutesSnapshot;
  final DateTime? targetClassAt;
  final String? assignmentId;

  bool get isPendingHomework =>
      destination == HomeworkPlanDestination.homework &&
      (resolution == null || resolution == 'pending');

  HomeworkPlanDestination get uiDestination {
    if (destination == HomeworkPlanDestination.nextSession ||
        (destination == HomeworkPlanDestination.inClass &&
            rolloverPolicy == HomeworkPlanRolloverPolicy.carryPaused)) {
      return HomeworkPlanDestination.nextSession;
    }
    return destination;
  }

  factory HomeworkSessionPlanItem.fromRow(Map<String, dynamic> row) {
    int? positiveInt(Object? value) {
      final parsed = value is num ? value.toInt() : int.tryParse('$value');
      return parsed != null && parsed > 0 ? parsed : null;
    }

    String? optionalString(Object? value) {
      final text = '${value ?? ''}'.trim();
      return text.isEmpty ? null : text;
    }

    return HomeworkSessionPlanItem(
      id: '${row['id'] ?? ''}'.trim(),
      studentId: '${row['student_id'] ?? ''}'.trim(),
      sourceAttendanceId: '${row['source_attendance_id'] ?? ''}'.trim(),
      groupId: '${row['group_id'] ?? ''}'.trim(),
      homeworkItemId: '${row['homework_item_id'] ?? ''}'.trim(),
      origin: HomeworkPlanOrigin.fromDb(row['origin']),
      destination: HomeworkPlanDestination.fromDb(row['destination']),
      rolloverPolicy: HomeworkPlanRolloverPolicy.fromDb(row['rollover_policy']),
      resolution: optionalString(row['resolution']),
      recommendedMinutesSnapshot:
          positiveInt(row['recommended_minutes_snapshot']),
      targetClassAt:
          DateTime.tryParse('${row['target_class_at'] ?? ''}')?.toLocal(),
      assignmentId: optionalString(row['assignment_id']),
    );
  }
}

class HomeworkSessionPlanService {
  HomeworkSessionPlanService._();

  static final HomeworkSessionPlanService instance =
      HomeworkSessionPlanService._();

  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final Map<String, List<HomeworkSessionPlanItem>> _cacheByAttendanceId =
      <String, List<HomeworkSessionPlanItem>>{};

  List<HomeworkSessionPlanItem> peek(String attendanceId) {
    return List<HomeworkSessionPlanItem>.unmodifiable(
      _cacheByAttendanceId[attendanceId.trim()] ??
          const <HomeworkSessionPlanItem>[],
    );
  }

  Future<List<HomeworkSessionPlanItem>> load(
    String attendanceId, {
    required String studentId,
    bool force = false,
  }) async {
    final attendanceKey = attendanceId.trim();
    final studentKey = studentId.trim();
    if (attendanceKey.isEmpty || studentKey.isEmpty) {
      return const <HomeworkSessionPlanItem>[];
    }
    if (!force && _cacheByAttendanceId.containsKey(attendanceKey)) {
      return peek(attendanceKey);
    }
    final academyId = (await TenantService.instance.getActiveAcademyId()) ??
        await TenantService.instance.ensureActiveAcademy();
    final rows = await Supabase.instance.client
        .from('homework_session_plan_items')
        .select(
          'id,student_id,source_attendance_id,group_id,homework_item_id,'
          'origin,destination,rollover_policy,resolution,recommended_minutes_snapshot,'
          'target_class_at,assignment_id',
        )
        .eq('academy_id', academyId)
        .eq('student_id', studentKey)
        .eq('source_attendance_id', attendanceKey)
        .order('order_index')
        .order('created_at');
    final plans = (rows as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(HomeworkSessionPlanItem.fromRow)
        .toList(growable: false);
    _cacheByAttendanceId[attendanceKey] = plans;
    revision.value++;
    return plans;
  }

  Future<void> setGroupDestination({
    required String attendanceId,
    required String studentId,
    required String groupId,
    required Iterable<String> itemIds,
    required HomeworkPlanDestination destination,
    required HomeworkPlanOrigin origin,
    Map<String, HomeworkPlanDestination> childOverrides =
        const <String, HomeworkPlanDestination>{},
    DateTime? targetClassAt,
  }) async {
    final normalizedItemIds =
        itemIds.map((id) => id.trim()).where((id) => id.isNotEmpty).toList();
    if (attendanceId.trim().isEmpty ||
        studentId.trim().isEmpty ||
        groupId.trim().isEmpty ||
        normalizedItemIds.isEmpty) {
      return;
    }
    final overridePayload = <String, String>{
      for (final entry in childOverrides.entries)
        if (entry.key.trim().isNotEmpty) entry.key.trim(): entry.value.dbValue,
    };
    await Supabase.instance.client.rpc(
      'homework_set_session_plan_classification_v2',
      params: <String, dynamic>{
        'p_source_attendance_id': attendanceId.trim(),
        'p_student_id': studentId.trim(),
        'p_group_id': groupId.trim(),
        'p_homework_item_ids': normalizedItemIds,
        'p_kind': _uiKind(destination),
        'p_item_kind_overrides': overridePayload.map(
          (itemId, value) => MapEntry(
            itemId,
            _uiKind(HomeworkPlanDestination.fromDb(value)),
          ),
        ),
        'p_target_class_at': targetClassAt?.toUtc().toIso8601String(),
      },
    );
    // RPC가 homework_assignments 를 직접 만들므로, 숙제 칩과 검사 대상이 곧바로
    // 보이도록 활성 assignment 캐시를 무효화한다.
    HomeworkAssignmentStore.instance.invalidateActiveAssignments(studentId);
    await load(attendanceId, studentId: studentId, force: true);
  }

  static String _uiKind(HomeworkPlanDestination destination) {
    return switch (destination) {
      HomeworkPlanDestination.inClass => 'today',
      HomeworkPlanDestination.homework => 'homework',
      HomeworkPlanDestination.nextSession => 'next',
    };
  }

  Future<void> updateDueDate({
    required String attendanceId,
    required Iterable<String> homeworkItemIds,
    required DateTime dueDate,
  }) async {
    final ids = homeworkItemIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (attendanceId.trim().isEmpty || ids.isEmpty) return;
    await Supabase.instance.client.rpc(
      'homework_update_session_plan_due_date',
      params: <String, dynamic>{
        'p_source_attendance_id': attendanceId.trim(),
        'p_homework_item_ids': ids,
        'p_due_at': dueDate.toUtc().toIso8601String(),
      },
    );
    _cacheByAttendanceId.remove(attendanceId.trim());
    HomeworkAssignmentStore.instance.invalidateActiveAssignments();
    revision.value++;
  }

  Future<void> finalizeDeparture({required String attendanceId}) async {
    final key = attendanceId.trim();
    if (key.isEmpty) return;
    await Supabase.instance.client.rpc(
      'homework_finalize_session_plan_departure',
      params: <String, dynamic>{'p_attendance_id': key},
    );
    _cacheByAttendanceId.remove(key);
    HomeworkAssignmentStore.instance.invalidateActiveAssignments();
    revision.value++;
  }

  Future<void> splitGroupByDestination({
    required String attendanceId,
    required String studentId,
    required String groupId,
    required HomeworkPlanDestination groupDestination,
    required Map<String, HomeworkPlanDestination> childDestinations,
    HomeworkPlanOrigin origin = HomeworkPlanOrigin.plannedToday,
  }) async {
    if (childDestinations.isEmpty) return;
    await setGroupDestination(
      attendanceId: attendanceId,
      studentId: studentId,
      groupId: groupId,
      itemIds: childDestinations.keys,
      destination: groupDestination,
      origin: origin,
      childOverrides: childDestinations,
    );
  }

  Future<void> confirmDepartureHomework({
    required String attendanceId,
    required Iterable<String> homeworkItemIds,
  }) async {
    final ids = homeworkItemIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (attendanceId.trim().isEmpty) return;
    await Supabase.instance.client.rpc(
      'homework_confirm_session_plan_homework',
      params: <String, dynamic>{
        'p_source_attendance_id': attendanceId.trim(),
        'p_homework_item_ids': ids,
      },
    );
    _cacheByAttendanceId.remove(attendanceId.trim());
    HomeworkAssignmentStore.instance.invalidateActiveAssignments();
    revision.value++;
  }

  void clearCache() {
    _cacheByAttendanceId.clear();
    revision.value++;
  }
}
