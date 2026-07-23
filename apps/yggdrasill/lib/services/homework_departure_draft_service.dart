import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'tenant_service.dart';

class HomeworkDepartureDraft {
  const HomeworkDepartureDraft({
    required this.attendanceId,
    required this.groupIds,
    required this.dueDateByGroupId,
    required this.savedAt,
  });

  final String attendanceId;
  final Set<String> groupIds;
  final Map<String, DateTime> dueDateByGroupId;
  final DateTime? savedAt;

  bool get isSaved => savedAt != null;

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
    return HomeworkDepartureDraft(
      attendanceId: '${row['id'] ?? ''}'.trim(),
      groupIds: groupIds,
      dueDateByGroupId: dueDateByGroupId,
      savedAt: rawSavedAt == null
          ? null
          : DateTime.tryParse('$rawSavedAt')?.toLocal(),
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
        .select(
          'id,homework_draft_group_ids,homework_draft_group_due_dates,homework_draft_saved_at',
        )
        .eq('academy_id', academyId)
        .eq('id', key)
        .maybeSingle();
    if (row == null) {
      _cache.remove(key);
      return null;
    }
    final draft = HomeworkDepartureDraft.fromRow(row);
    _cache[key] = draft;
    return draft;
  }

  Future<HomeworkDepartureDraft> save({
    required String attendanceId,
    required Iterable<String> groupIds,
    required Map<String, DateTime> dueDateByGroupId,
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
    final rows = await Supabase.instance.client
        .from('attendance_records')
        .update({
          'homework_draft_group_ids':
              normalizedGroupIds.toList(growable: false),
          'homework_draft_group_due_dates': normalizedDueDates,
          'homework_draft_saved_at': savedAt.toUtc().toIso8601String(),
        })
        .eq('academy_id', academyId)
        .eq('id', key)
        .isFilter('departure_time', null)
        .select(
          'id,homework_draft_group_ids,homework_draft_group_due_dates,homework_draft_saved_at',
        );
    final typedRows = (rows as List<dynamic>).cast<Map<String, dynamic>>();
    if (typedRows.isEmpty) {
      throw StateError('ATTENDANCE_SESSION_CLOSED');
    }
    final draft = HomeworkDepartureDraft.fromRow(typedRows.first);
    _cache[key] = draft;
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
