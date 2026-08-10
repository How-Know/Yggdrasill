import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'homework_session_plan_service.dart';
import 'tenant_service.dart';

class HomeworkDepartureDraft {
  const HomeworkDepartureDraft({
    required this.attendanceId,
    required this.groupIds,
    required this.dueDateByGroupId,
    required this.savedAt,
    this.planHomeworkItemIds = const <String>{},
    this.autoManagedPlanItemIds = const <String>{},
    this.autoRolloverToHomeworkItemIds = const <String>{},
    this.todayAndHomeworkGroupIds = const <String>{},
    this.hasPlanClassification = false,
    this.planSnapshotItemIds = const <String>{},
    this.planSnapshotAt,
  });

  final String attendanceId;
  final Set<String> groupIds;
  final Map<String, DateTime> dueDateByGroupId;
  final DateTime? savedAt;
  final Set<String> planHomeworkItemIds;

  /// 하원 RPC가 자동으로 숙제 전환 또는 일시정지 이월할 계획 항목.
  final Set<String> autoManagedPlanItemIds;

  /// '오늘' 계획 중 하원 시 자동으로 다음 수업까지 숙제로 넘길 항목
  /// (`in_class` + `to_homework`). 알림장 숙제 리스트에 포함한다.
  final Set<String> autoRolloverToHomeworkItemIds;

  /// 오늘 계획 UI 기준 숙제+오늘 그룹 id 집합 (`다음` 제외).
  final Set<String> todayAndHomeworkGroupIds;
  final bool hasPlanClassification;

  /// 목표 제시 시점에 고정한 오늘+다음 item id.
  final Set<String> planSnapshotItemIds;
  final DateTime? planSnapshotAt;

  bool get isSaved => savedAt != null;
  bool get hasGoalSnapshot => planSnapshotAt != null;

  /// 수업계획 버튼 뱃지용: 숙제+오늘 그룹 수 (계획 없으면 저장 초안 그룹 수).
  int get planBadgeGroupCount {
    if (hasPlanClassification) return todayAndHomeworkGroupIds.length;
    return groupIds.length;
  }

  factory HomeworkDepartureDraft.fromRow(Map<String, dynamic> row) {
    final rawGroupIds = row['homework_draft_group_ids'];
    final groupIds = <String>{};
    if (rawGroupIds is List) {
      for (final value in rawGroupIds) {
        final id = '$value'.trim();
        if (id.isNotEmpty) groupIds.add(id);
      }
    }
    final dueDateByGroupId = <String, DateTime>{};
    final rawDueDates = row['homework_draft_group_due_dates'];
    if (rawDueDates is Map) {
      for (final entry in rawDueDates.entries) {
        final groupId = '${entry.key}'.trim();
        final dueDate = DateTime.tryParse('${entry.value}')?.toLocal();
        if (groupId.isNotEmpty && dueDate != null) {
          dueDateByGroupId[groupId] = dueDate;
        }
      }
    }
    final rawSavedAt = row['homework_draft_saved_at'];
    final planSnapshotItemIds = <String>{};
    final rawSnapshotIds = row['homework_plan_snapshot_item_ids'];
    if (rawSnapshotIds is List) {
      for (final value in rawSnapshotIds) {
        final id = '$value'.trim();
        if (id.isNotEmpty) planSnapshotItemIds.add(id);
      }
    }
    final rawSnapshotAt = row['homework_plan_snapshot_at'];
    return HomeworkDepartureDraft(
      attendanceId: '${row['id'] ?? ''}'.trim(),
      groupIds: groupIds,
      dueDateByGroupId: dueDateByGroupId,
      savedAt: rawSavedAt == null
          ? null
          : DateTime.tryParse('$rawSavedAt')?.toLocal(),
      planSnapshotItemIds: planSnapshotItemIds,
      planSnapshotAt: rawSnapshotAt == null
          ? null
          : DateTime.tryParse('$rawSnapshotAt')?.toLocal(),
    );
  }
}

class HomeworkDepartureDraftService {
  HomeworkDepartureDraftService._();

  static final HomeworkDepartureDraftService instance =
      HomeworkDepartureDraftService._();

  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final Map<String, HomeworkDepartureDraft> _cache =
      <String, HomeworkDepartureDraft>{};

  static const _attendanceDraftSelect =
      'id,student_id,homework_draft_group_ids,homework_draft_group_due_dates,'
      'homework_draft_saved_at,homework_plan_snapshot_item_ids,'
      'homework_plan_snapshot_at';

  HomeworkDepartureDraft? peek(String attendanceId) {
    final key = attendanceId.trim();
    if (key.isEmpty) return null;
    return _cache[key];
  }

  Future<HomeworkDepartureDraft?> load(
    String attendanceId, {
    bool force = false,
  }) async {
    final key = attendanceId.trim();
    if (key.isEmpty) return null;
    if (!force && _cache.containsKey(key)) return _cache[key];

    final academyId = (await TenantService.instance.getActiveAcademyId()) ??
        await TenantService.instance.ensureActiveAcademy();
    final row = await Supabase.instance.client
        .from('attendance_records')
        .select(_attendanceDraftSelect)
        .eq('academy_id', academyId)
        .eq('id', key)
        .maybeSingle();
    if (row == null) {
      _cache.remove(key);
      return null;
    }
    final baseDraft = HomeworkDepartureDraft.fromRow(row);
    final studentId = '${row['student_id'] ?? ''}'.trim();
    final plans = studentId.isEmpty
        ? const <HomeworkSessionPlanItem>[]
        : await HomeworkSessionPlanService.instance.load(
            key,
            studentId: studentId,
            force: force,
          );
    final todayAndHomeworkGroupIds = <String>{};
    for (final plan in plans) {
      final ui = plan.uiDestination;
      if (ui != HomeworkPlanDestination.homework &&
          ui != HomeworkPlanDestination.inClass) {
        continue;
      }
      final groupId = plan.groupId.trim();
      if (groupId.isNotEmpty) todayAndHomeworkGroupIds.add(groupId);
    }
    final draft = HomeworkDepartureDraft(
      attendanceId: baseDraft.attendanceId,
      groupIds: baseDraft.groupIds,
      dueDateByGroupId: baseDraft.dueDateByGroupId,
      savedAt: baseDraft.savedAt,
      planSnapshotItemIds: baseDraft.planSnapshotItemIds,
      planSnapshotAt: baseDraft.planSnapshotAt,
      planHomeworkItemIds: plans
          .where((plan) =>
              plan.destination == HomeworkPlanDestination.homework &&
              plan.isPendingHomework)
          .map((plan) => plan.homeworkItemId)
          .where((id) => id.isNotEmpty)
          .toSet(),
      autoManagedPlanItemIds: plans
          .where(
              (plan) => plan.uiDestination != HomeworkPlanDestination.homework)
          .map((plan) => plan.homeworkItemId)
          .where((id) => id.isNotEmpty)
          .toSet(),
      autoRolloverToHomeworkItemIds: plans
          .where((plan) =>
              plan.destination == HomeworkPlanDestination.inClass &&
              plan.rolloverPolicy == HomeworkPlanRolloverPolicy.toHomework)
          .map((plan) => plan.homeworkItemId)
          .where((id) => id.isNotEmpty)
          .toSet(),
      todayAndHomeworkGroupIds: todayAndHomeworkGroupIds,
      hasPlanClassification: plans.isNotEmpty,
    );
    _cache[key] = draft;
    return draft;
  }

  /// 세션 계획 destination 변경 후 뱃지/캐시를 다시 읽게 한다.
  /// 목표 스냅샷이 사라져 + 표시가 빠지지 않도록 즉시 재로드한다.
  void invalidate(String attendanceId) {
    final key = attendanceId.trim();
    if (key.isEmpty) return;
    _cache.remove(key);
    revision.value = revision.value + 1;
    load(key, force: true).catchError((Object error) {
      debugPrint('[HW][draft] reload after invalidate failed: $error');
      return null;
    });
  }

  /// [presentGoalSnapshot]이 true이면 오늘+다음 item 스냅샷을 함께 기록한다.
  Future<HomeworkDepartureDraft> save({
    required String attendanceId,
    required Iterable<String> groupIds,
    required Map<String, DateTime> dueDateByGroupId,
    Iterable<String> planSnapshotItemIds = const <String>[],
    bool presentGoalSnapshot = false,
  }) async {
    final key = attendanceId.trim();
    if (key.isEmpty) {
      throw StateError('ATTENDANCE_ID_REQUIRED');
    }
    final normalizedGroupIds =
        groupIds.map((id) => id.trim()).where((id) => id.isNotEmpty).toSet();
    final academyId = (await TenantService.instance.getActiveAcademyId()) ??
        await TenantService.instance.ensureActiveAcademy();
    final savedAt = DateTime.now();
    final normalizedDueDates = <String, String>{
      for (final groupId in normalizedGroupIds)
        if (dueDateByGroupId[groupId] != null)
          groupId: dueDateByGroupId[groupId]!.toUtc().toIso8601String(),
    };
    final normalizedSnapshotIds = planSnapshotItemIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final payload = <String, dynamic>{
      'homework_draft_group_ids':
          normalizedGroupIds.toList(growable: false),
      'homework_draft_group_due_dates': normalizedDueDates,
      'homework_draft_saved_at': savedAt.toUtc().toIso8601String(),
    };
    if (presentGoalSnapshot) {
      payload['homework_plan_snapshot_item_ids'] = normalizedSnapshotIds;
      payload['homework_plan_snapshot_at'] =
          savedAt.toUtc().toIso8601String();
    }
    final rows = await Supabase.instance.client
        .from('attendance_records')
        .update(payload)
        .eq('academy_id', academyId)
        .eq('id', key)
        .isFilter('departure_time', null)
        .select(_attendanceDraftSelect);
    final typedRows = (rows as List<dynamic>).cast<Map<String, dynamic>>();
    if (typedRows.isEmpty) {
      throw StateError('ATTENDANCE_SESSION_CLOSED');
    }
    // 저장 직후 세션 계획 기준으로 숙제+오늘 그룹 수를 다시 계산한다.
    _cache.remove(key);
    final draft = await load(key, force: true);
    if (draft == null) {
      throw StateError('ATTENDANCE_DRAFT_RELOAD_FAILED');
    }
    revision.value = revision.value + 1;
    return draft;
  }

  void cacheFromAttendanceRow(Map<String, dynamic> row) {
    final draft = HomeworkDepartureDraft.fromRow(row);
    if (draft.attendanceId.isEmpty) return;
    _cache[draft.attendanceId] = draft;
    revision.value = revision.value + 1;
  }

  void clearCache() {
    _cache.clear();
    revision.value = revision.value + 1;
  }
}
