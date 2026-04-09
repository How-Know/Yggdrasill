import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'tenant_service.dart';
import 'homework_store.dart';
import 'learning_problem_bank_service.dart';

class HomeworkAssignmentDetail {
  final String id;
  final String homeworkItemId;
  final String? groupId;
  final String? groupTitleSnapshot;
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
  final int repeatIndex;
  final int splitParts;
  final int splitRound;
  final String? liveReleaseId;
  final String? releaseExportJobId;
  final DateTime? liveReleaseLockedAt;
  final String? liveReleaseSignedUrl;

  const HomeworkAssignmentDetail({
    required this.id,
    required this.homeworkItemId,
    required this.groupId,
    required this.groupTitleSnapshot,
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
    required this.repeatIndex,
    required this.splitParts,
    required this.splitRound,
    this.liveReleaseId,
    this.releaseExportJobId,
    this.liveReleaseLockedAt,
    this.liveReleaseSignedUrl,
  });
}

class HomeworkAssignmentGroupMeta {
  final String groupId;
  final String groupTitleSnapshot;

  const HomeworkAssignmentGroupMeta({
    required this.groupId,
    required this.groupTitleSnapshot,
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
  final int repeatIndex;
  final int splitParts;
  final int splitRound;

  const HomeworkAssignmentBrief({
    required this.id,
    required this.homeworkItemId,
    required this.assignedAt,
    required this.dueDate,
    required this.orderIndex,
    required this.status,
    required this.progress,
    required this.repeatIndex,
    required this.splitParts,
    required this.splitRound,
  });
}

class HomeworkAssignmentCycleMeta {
  final String assignmentId;
  final String homeworkItemId;
  final int repeatIndex;
  final int splitParts;
  final int splitRound;

  const HomeworkAssignmentCycleMeta({
    required this.assignmentId,
    required this.homeworkItemId,
    required this.repeatIndex,
    required this.splitParts,
    required this.splitRound,
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
  final LearningProblemBankService _problemBankService =
      LearningProblemBankService();
  static const String reservationNote = '__reserved_homework__';
  /// Synthetic assignment ids merged into [loadActiveAssignments] until the server row exists.
  static const String optimisticReservedAssignmentIdPrefix = '__opt_resv__:';
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  /// Stale-while-revalidate: last successful [loadActiveAssignments] per student.
  final Map<String, List<HomeworkAssignmentDetail>> _activeAssignmentsCacheByStudent =
      {};
  /// Students for whom [loadActiveAssignments] has finished at least once (success or handled error).
  /// Used so UI does not paint "current" chips from [HomeworkStore] alone before assignment rows are known.
  final Set<String> _activeAssignmentsLoadCompletedForStudent = <String>{};
  /// Item ids that must stay off "current" chip rows until server reservation row is seen.
  final Map<String, Set<String>> _pendingReservedHomeworkItemIdsByStudent = {};
  RealtimeChannel? _rtAssignments;
  RealtimeChannel? _rtChecks;
  String? _rtAcademyId;

  void _bump() {
    revision.value++;
  }

  /// For [FutureBuilder.initialData] / first paint before the network returns.
  /// Empty list is a valid cache entry; missing key returns null.
  List<HomeworkAssignmentDetail>? peekCachedActiveAssignments(String studentId) {
    final key = studentId.trim();
    if (key.isEmpty) return null;
    return _activeAssignmentsCacheByStudent[key];
  }

  bool hasCompletedActiveAssignmentLoad(String studentId) {
    final key = studentId.trim();
    if (key.isEmpty) return false;
    return _activeAssignmentsLoadCompletedForStudent.contains(key);
  }

  void clearActiveAssignmentsCache() {
    _activeAssignmentsCacheByStudent.clear();
    _pendingReservedHomeworkItemIdsByStudent.clear();
    _activeAssignmentsLoadCompletedForStudent.clear();
  }

  Set<String> peekPendingReservedHomeworkItemIds(String studentId) {
    final key = studentId.trim();
    if (key.isEmpty) return const <String>{};
    final s = _pendingReservedHomeworkItemIdsByStudent[key];
    if (s == null || s.isEmpty) return const <String>{};
    return Set<String>.unmodifiable(s);
  }

  void _addPendingReservedHomeworkItemIds(String studentId, Set<String> ids) {
    final key = studentId.trim();
    if (key.isEmpty || ids.isEmpty) return;
    final bucket =
        _pendingReservedHomeworkItemIdsByStudent.putIfAbsent(key, () => <String>{});
    bucket.addAll(ids);
  }

  void _removePendingReservedHomeworkItemIds(String studentId, Iterable<String> ids) {
    final key = studentId.trim();
    if (key.isEmpty) return;
    final bucket = _pendingReservedHomeworkItemIdsByStudent[key];
    if (bucket == null || bucket.isEmpty) return;
    for (final raw in ids) {
      final id = raw.trim();
      if (id.isNotEmpty) bucket.remove(id);
    }
    if (bucket.isEmpty) {
      _pendingReservedHomeworkItemIdsByStudent.remove(key);
    }
  }

  /// Drops pending ids once [mergedAssignments] includes a reservation row for that item.
  bool _prunePendingReservedAfterLoad(
    String studentId,
    List<HomeworkAssignmentDetail> mergedAssignments,
  ) {
    final key = studentId.trim();
    if (key.isEmpty) return false;
    final bucket = _pendingReservedHomeworkItemIdsByStudent[key];
    if (bucket == null || bucket.isEmpty) return false;
    var changed = false;
    for (final a in mergedAssignments) {
      if ((a.note ?? '').trim() != reservationNote) continue;
      final hid = a.homeworkItemId.trim();
      if (hid.isEmpty) continue;
      if (bucket.remove(hid)) {
        changed = true;
      }
    }
    if (bucket.isEmpty) {
      _pendingReservedHomeworkItemIdsByStudent.remove(key);
    }
    if (changed) {
      _bump();
    }
    return changed;
  }

  List<HomeworkAssignmentDetail> _mergeServerActiveWithOptimisticReservations(
    String studentId,
    List<HomeworkAssignmentDetail> server,
  ) {
    final key = studentId.trim();
    if (key.isEmpty) return server;
    final prev = _activeAssignmentsCacheByStudent[key];
    if (prev == null || prev.isEmpty) return server;
    final optimistic = prev
        .where(
          (a) => a.id.startsWith(optimisticReservedAssignmentIdPrefix),
        )
        .toList(growable: false);
    if (optimistic.isEmpty) return server;
    final serverItemIds = <String>{
      for (final a in server)
        a.homeworkItemId.trim(),
    };
    final kept = optimistic
        .where((o) => !serverItemIds.contains(o.homeworkItemId.trim()))
        .toList(growable: false);
    if (kept.isEmpty) return server;
    return <HomeworkAssignmentDetail>[...server, ...kept];
  }

  void applyOptimisticReservedAssignments(
    String studentId,
    List<HomeworkItem> items, {
    String? groupId,
    String? groupTitleSnapshot,
  }) {
    final key = studentId.trim();
    if (key.isEmpty || items.isEmpty) return;
    final idSet = items.map((e) => e.id.trim()).where((e) => e.isNotEmpty).toSet();
    if (idSet.isEmpty) return;
    _addPendingReservedHomeworkItemIds(key, idSet);
    final now = DateTime.now();
    final gid = (groupId ?? '').trim();
    final snap = (groupTitleSnapshot ?? '').trim();
    final base = List<HomeworkAssignmentDetail>.from(
      peekCachedActiveAssignments(key) ?? const <HomeworkAssignmentDetail>[],
    );
    base.removeWhere(
      (a) =>
          a.id.startsWith(optimisticReservedAssignmentIdPrefix) &&
          idSet.contains(a.homeworkItemId.trim()),
    );
    for (final item in items) {
      final iid = item.id.trim();
      if (iid.isEmpty) continue;
      final sp = item.defaultSplitParts.clamp(1, 4).toInt();
      base.add(
        HomeworkAssignmentDetail(
          id: '$optimisticReservedAssignmentIdPrefix$item.id',
          homeworkItemId: item.id,
          groupId: gid.isEmpty ? null : gid,
          groupTitleSnapshot: snap.isEmpty ? null : snap,
          assignedAt: now,
          dueDate: null,
          orderIndex: 0,
          status: 'assigned',
          note: reservationNote,
          progress: 0,
          issueType: null,
          issueNote: null,
          title: item.title,
          type: item.type,
          page: item.page,
          count: item.count,
          content: item.content,
          flowId: item.flowId,
          repeatIndex: 1,
          splitParts: sp,
          splitRound: 1,
        ),
      );
    }
    _activeAssignmentsCacheByStudent[key] =
        List<HomeworkAssignmentDetail>.unmodifiable(base);
    _bump();
  }

  void revertOptimisticReservedAssignmentsForItems(
    String studentId,
    Iterable<String> homeworkItemIds,
  ) {
    final key = studentId.trim();
    final idSet = homeworkItemIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (key.isEmpty || idSet.isEmpty) return;
    final cur = peekCachedActiveAssignments(key);
    if (cur == null || cur.isEmpty) return;
    final next = cur
        .where(
          (a) =>
              !a.id.startsWith(optimisticReservedAssignmentIdPrefix) ||
              !idSet.contains(a.homeworkItemId.trim()),
        )
        .toList(growable: false);
    _activeAssignmentsCacheByStudent[key] =
        List<HomeworkAssignmentDetail>.unmodifiable(next);
    _removePendingReservedHomeworkItemIds(key, idSet);
    _bump();
  }

  Future<void> normalizeActiveAssignedOrderForNullDue(String studentId) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      await _normalizeAssignedOrderForDueDateIso(
        academyId: academyId,
        studentId: studentId.trim(),
        dueDateIso: _dueDateIso(null),
      );
    } catch (_) {}
  }

  void _ensureRealtimeForAcademy(String academyId) {
    if (academyId.trim().isEmpty) return;
    if (_rtAcademyId == academyId &&
        _rtAssignments != null &&
        _rtChecks != null) {
      return;
    }
    try {
      if (_rtAcademyId != academyId) {
        _rtAssignments?.unsubscribe();
        _rtChecks?.unsubscribe();
        _rtAssignments = null;
        _rtChecks = null;
      }
      _rtAssignments ??= Supabase.instance.client
          .channel('public:homework_assignments:$academyId')
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'homework_assignments',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'academy_id',
            value: academyId,
          ),
          callback: (_) => _bump(),
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'homework_assignments',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'academy_id',
            value: academyId,
          ),
          callback: (_) => _bump(),
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'homework_assignments',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'academy_id',
            value: academyId,
          ),
          callback: (_) => _bump(),
        )
        ..subscribe();
      _rtChecks ??= Supabase.instance.client
          .channel('public:homework_assignment_checks:$academyId')
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'homework_assignment_checks',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'academy_id',
            value: academyId,
          ),
          callback: (_) => _bump(),
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'homework_assignment_checks',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'academy_id',
            value: academyId,
          ),
          callback: (_) => _bump(),
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'homework_assignment_checks',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'academy_id',
            value: academyId,
          ),
          callback: (_) => _bump(),
        )
        ..subscribe();
      _rtAcademyId = academyId;
    } catch (e, st) {
      debugPrint('[HW_ASSIGN][realtime][ERROR] $e\n$st');
    }
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

  int _normalizeRepeatIndex(dynamic value) {
    final parsed = _asInt(value, 1);
    return parsed < 1 ? 1 : parsed;
  }

  int _normalizeSplitParts(dynamic value) {
    final parsed = _asInt(value, 1);
    return parsed < 1 ? 1 : parsed;
  }

  int _normalizeSplitRound(dynamic value, int splitParts) {
    final parsed = _asInt(value, 1);
    if (parsed < 1) return 1;
    if (parsed > splitParts) return splitParts;
    return parsed;
  }

  int? _asIntOpt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  String _asTrimmed(dynamic value) {
    return (value ?? '').toString().trim();
  }

  bool _isMissingAssignmentGroupColumnsError(Object error) {
    final msg = error.toString().toLowerCase();
    if (!msg.contains('column')) return false;
    return msg.contains('homework_assignments.group_id') ||
        msg.contains('homework_assignments.group_title_snapshot') ||
        msg.contains('group_id') ||
        msg.contains('group_title_snapshot');
  }

  bool _isMissingLiveReleaseColumnsError(Object error) {
    final msg = error.toString().toLowerCase();
    if (!msg.contains('column')) return false;
    return msg.contains('homework_assignments.live_release_id') ||
        msg.contains('homework_assignments.release_export_job_id') ||
        msg.contains('homework_assignments.live_release_locked_at') ||
        msg.contains('live_release_id') ||
        msg.contains('release_export_job_id') ||
        msg.contains('live_release_locked_at');
  }

  Map<String, dynamic>? _extractJoinedMap(dynamic raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is List && raw.isNotEmpty && raw.first is Map) {
      return Map<String, dynamic>.from(raw.first as Map);
    }
    return null;
  }

  String _resolveLiveReleaseExportJobId(Map<String, dynamic> assignmentRow) {
    final status = _asTrimmed(assignmentRow['status']).toLowerCase();
    final liveReleaseId = _asTrimmed(assignmentRow['live_release_id']);
    if (liveReleaseId.isEmpty) return '';
    final releaseExportJobId = _asTrimmed(assignmentRow['release_export_job_id']);
    final releaseRow = _extractJoinedMap(assignmentRow['pb_live_releases']);
    final activeExportJobId = _asTrimmed(releaseRow?['active_export_job_id']);
    final frozenExportJobId = _asTrimmed(releaseRow?['frozen_export_job_id']);
    if (status == 'completed') {
      if (releaseExportJobId.isNotEmpty) return releaseExportJobId;
      return frozenExportJobId;
    }
    if (status == 'assigned' || status == 'in_progress') {
      return activeExportJobId;
    }
    return '';
  }

  Future<Map<String, String>> _loadLiveReleaseSignedUrlByExportJobId({
    required String academyId,
    required Set<String> exportJobIds,
  }) async {
    final out = <String, String>{};
    if (academyId.trim().isEmpty || exportJobIds.isEmpty) return out;
    for (final exportJobId in exportJobIds) {
      final safeId = exportJobId.trim();
      if (safeId.isEmpty) continue;
      try {
        final signedUrl = await _problemBankService.regenerateExportSignedUrl(
          academyId: academyId,
          exportJobId: safeId,
        );
        if (signedUrl.trim().isNotEmpty) {
          out[safeId] = signedUrl.trim();
        }
      } catch (_) {
        // keep best-effort behavior
      }
    }
    return out;
  }

  Future<Map<String, HomeworkAssignmentGroupMeta>> _loadGroupMetaByItemIds({
    required String academyId,
    required Iterable<String> itemIds,
  }) async {
    final ids = itemIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (ids.isEmpty) return <String, HomeworkAssignmentGroupMeta>{};
    final supa = Supabase.instance.client;
    final rows = await supa
        .from('homework_group_items')
        .select('homework_item_id,group_id,homework_groups(title)')
        .eq('academy_id', academyId)
        .inFilter('homework_item_id', ids.toList());
    final out = <String, HomeworkAssignmentGroupMeta>{};
    for (final raw in (rows as List<dynamic>)) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final itemId = _asTrimmed(row['homework_item_id']);
      final groupId = _asTrimmed(row['group_id']);
      if (itemId.isEmpty || groupId.isEmpty) continue;
      String title = '';
      final groupRaw = row['homework_groups'];
      if (groupRaw is Map) {
        title = _asTrimmed(groupRaw['title']);
      } else if (groupRaw is List && groupRaw.isNotEmpty) {
        final first = groupRaw.first;
        if (first is Map) {
          title = _asTrimmed(first['title']);
        }
      }
      out[itemId] = HomeworkAssignmentGroupMeta(
        groupId: groupId,
        groupTitleSnapshot: title.isEmpty ? '그룹 과제' : title,
      );
    }
    return out;
  }

  void _addPageRange(Set<int> out, int? a, int? b) {
    if (a == null && b == null) return;
    if (a != null && b != null) {
      int start = a;
      int end = b;
      if (start > end) {
        final t = start;
        start = end;
        end = t;
      }
      if (end - start > 1600) {
        if (start > 0) out.add(start);
        if (end > 0) out.add(end);
        return;
      }
      for (int p = start; p <= end; p++) {
        if (p > 0) out.add(p);
      }
      return;
    }
    final one = a ?? b;
    if (one != null && one > 0) out.add(one);
  }

  String _normalizePageSignature(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final normalized = trimmed
        .replaceAll(RegExp(r'p\.', caseSensitive: false), '')
        .replaceAll('페이지', '')
        .replaceAll('쪽', '')
        .replaceAll('~', '-')
        .replaceAll('–', '-')
        .replaceAll('—', '-');
    final tokens = normalized
        .split(RegExp(r'[,/\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty);
    final pages = <int>{};
    for (final token in tokens) {
      if (token.contains('-')) {
        final parts = token
            .split('-')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        if (parts.length != 2) continue;
        _addPageRange(pages, _asIntOpt(parts[0]), _asIntOpt(parts[1]));
      } else {
        final value = _asIntOpt(token);
        if (value != null && value > 0) pages.add(value);
      }
    }
    if (pages.isEmpty) return '';
    final sorted = pages.toList()..sort();
    return sorted.join(',');
  }

  String _unitSignatureFromMappings(List<Map<String, dynamic>>? mappings) {
    if (mappings == null || mappings.isEmpty) return '';
    final tuples = <String>{};
    for (final raw in mappings) {
      final m = Map<String, dynamic>.from(raw);
      final big = _asIntOpt(m['bigOrder'] ?? m['big_order']);
      final mid = _asIntOpt(m['midOrder'] ?? m['mid_order']);
      final small = _asIntOpt(m['smallOrder'] ?? m['small_order']);
      if (big == null || mid == null || small == null) continue;
      tuples.add('$big.$mid.$small');
    }
    if (tuples.isEmpty) return '';
    final list = tuples.toList()..sort();
    return list.join(';');
  }

  Map<String, String> _buildUnitSignatureByItemFromRows(List<dynamic> rows) {
    final tuplesByItem = <String, Set<String>>{};
    for (final raw in rows) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final itemId = _asTrimmed(row['homework_item_id']);
      if (itemId.isEmpty) continue;
      final big = _asIntOpt(row['big_order']);
      final mid = _asIntOpt(row['mid_order']);
      final small = _asIntOpt(row['small_order']);
      if (big == null || mid == null || small == null) continue;
      tuplesByItem
          .putIfAbsent(itemId, () => <String>{})
          .add('$big.$mid.$small');
    }
    final out = <String, String>{};
    for (final entry in tuplesByItem.entries) {
      final list = entry.value.toList()..sort();
      if (list.isEmpty) continue;
      out[entry.key] = list.join(';');
    }
    return out;
  }

  Set<String> _unitSmallKeysFromMappings(List<Map<String, dynamic>>? mappings) {
    if (mappings == null || mappings.isEmpty) return <String>{};
    final keys = <String>{};
    for (final raw in mappings) {
      final m = Map<String, dynamic>.from(raw);
      final big = _asIntOpt(m['bigOrder'] ?? m['big_order']);
      final mid = _asIntOpt(m['midOrder'] ?? m['mid_order']);
      final small = _asIntOpt(m['smallOrder'] ?? m['small_order']);
      if (big == null || mid == null || small == null) continue;
      keys.add('$big|$mid|$small');
    }
    return keys;
  }

  bool _hasStringOverlap(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return false;
    final small = a.length <= b.length ? a : b;
    final large = identical(small, a) ? b : a;
    for (final v in small) {
      if (large.contains(v)) return true;
    }
    return false;
  }

  String _ackPrefsKeyForItem({
    required String studentId,
    required HomeworkItem item,
  }) {
    final flowId = (item.flowId ?? '').trim();
    final bookId = (item.bookId ?? '').trim();
    final gradeLabel = (item.gradeLabel ?? '').trim();
    if (flowId.isEmpty || bookId.isEmpty || gradeLabel.isEmpty) return '';
    final bookKey = '$bookId|$gradeLabel';
    return 'flow_textbook_ack_units_v1:$studentId|$flowId|$bookKey';
  }

  Future<Map<String, int>> _loadAcknowledgedRepeatSeedByItem(
    String studentId,
    List<HomeworkItem> items,
  ) async {
    if (items.isEmpty) return const <String, int>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final ackKeysByPref = <String, Set<String>>{};
      final out = <String, int>{};
      for (final item in items) {
        final itemId = item.id.trim();
        if (itemId.isEmpty) continue;
        final prefKey = _ackPrefsKeyForItem(studentId: studentId, item: item);
        if (prefKey.isEmpty) continue;
        final acknowledged = ackKeysByPref.putIfAbsent(prefKey, () {
          final values = prefs.getStringList(prefKey) ?? const <String>[];
          return values.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
        });
        if (acknowledged.isEmpty) continue;
        final unitKeys = _unitSmallKeysFromMappings(item.unitMappings);
        if (unitKeys.isEmpty) continue;
        if (_hasStringOverlap(unitKeys, acknowledged)) {
          // 인정 진도를 1회차 완료로 간주해 첫 재출제 시 2회차부터 시작한다.
          out[itemId] = 1;
        }
      }
      return out;
    } catch (_) {
      return const <String, int>{};
    }
  }

  String _composeCycleKey({
    required String itemId,
    required String bookId,
    required String gradeLabel,
    required String unitSignature,
    required String pageSignature,
  }) {
    final b = bookId.trim();
    final g = gradeLabel.trim();
    if (b.isEmpty || g.isEmpty) return 'item:$itemId';
    final base = '$b|$g';
    if (unitSignature.isNotEmpty) return '$base|u:$unitSignature';
    if (pageSignature.isNotEmpty) return '$base|p:$pageSignature';
    return '$base|item:$itemId';
  }

  String _buildCycleKeyFromHistoryRow(
    Map<String, dynamic> row,
    Map<String, String> unitSignatureByItemId,
  ) {
    final itemId = _asTrimmed(row['homework_item_id']);
    if (itemId.isEmpty) return '';
    Map<String, dynamic>? hw;
    final hwRaw = row['homework_items'];
    if (hwRaw is Map) {
      hw = Map<String, dynamic>.from(hwRaw);
    } else if (hwRaw is List && hwRaw.isNotEmpty && hwRaw.first is Map) {
      hw = Map<String, dynamic>.from(hwRaw.first as Map);
    }
    final bookId = _asTrimmed(hw?['book_id']);
    final gradeLabel = _asTrimmed(hw?['grade_label']);
    final page = _asTrimmed(hw?['page']);
    final unitSig = unitSignatureByItemId[itemId] ?? '';
    final pageSig = _normalizePageSignature(page);
    return _composeCycleKey(
      itemId: itemId,
      bookId: bookId,
      gradeLabel: gradeLabel,
      unitSignature: unitSig,
      pageSignature: pageSig,
    );
  }

  String buildCycleKeyForItem(HomeworkItem item) {
    final bookId = (item.bookId ?? '').trim();
    final gradeLabel = (item.gradeLabel ?? '').trim();
    final unitSig = _unitSignatureFromMappings(item.unitMappings);
    final pageSig = _normalizePageSignature((item.page ?? '').trim());
    return _composeCycleKey(
      itemId: item.id,
      bookId: bookId,
      gradeLabel: gradeLabel,
      unitSignature: unitSig,
      pageSignature: pageSig,
    );
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
      _ensureRealtimeForAcademy(academyId);
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

  Future<Set<String>> loadAssignedCycleKeys(String studentId) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      _ensureRealtimeForAcademy(academyId);
      final supa = Supabase.instance.client;
      final rows = await supa
          .from('homework_assignments')
          .select(
            'homework_item_id,homework_items(book_id,grade_label,page)',
          )
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .order('assigned_at', ascending: false);
      final typedRows = (rows as List<dynamic>).cast<Map<String, dynamic>>();
      if (typedRows.isEmpty) return <String>{};

      final itemIds = <String>{};
      for (final row in typedRows) {
        final id = _asTrimmed(row['homework_item_id']);
        if (id.isNotEmpty) itemIds.add(id);
      }
      final unitSignatureByItemId = <String, String>{};
      if (itemIds.isNotEmpty) {
        final unitRows = await supa
            .from('homework_item_units')
            .select('homework_item_id,big_order,mid_order,small_order')
            .eq('academy_id', academyId)
            .inFilter('homework_item_id', itemIds.toList());
        unitSignatureByItemId.addAll(
          _buildUnitSignatureByItemFromRows(unitRows as List<dynamic>),
        );
      }

      final keys = <String>{};
      for (final row in typedRows) {
        final key = _buildCycleKeyFromHistoryRow(row, unitSignatureByItemId);
        if (key.isNotEmpty) keys.add(key);
      }
      return keys;
    } catch (e, st) {
      debugPrint('[HW_ASSIGN][load_cycle_keys][ERROR] $e\n$st');
      return <String>{};
    }
  }

  Future<Set<String>> loadActiveAssignedItemIds(String studentId) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      _ensureRealtimeForAcademy(academyId);
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

  Future<bool> hasActiveAssignmentForItem(
    String studentId,
    String homeworkItemId,
  ) async {
    final itemId = homeworkItemId.trim();
    if (itemId.isEmpty) return false;
    final activeIds = await loadActiveAssignedItemIds(studentId);
    return activeIds.contains(itemId);
  }

  Future<bool> hasActiveAssignmentForAnyItems(
    String studentId,
    Iterable<String> homeworkItemIds,
  ) async {
    final targets =
        homeworkItemIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (targets.isEmpty) return false;
    final activeIds = await loadActiveAssignedItemIds(studentId);
    for (final id in targets) {
      if (activeIds.contains(id)) return true;
    }
    return false;
  }

  Future<Map<String, int>> loadAssignmentCounts(String studentId) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      _ensureRealtimeForAcademy(academyId);
      final supa = Supabase.instance.client;
      final rows = await supa
          .from('homework_assignments')
          .select('homework_item_id,note')
          .eq('academy_id', academyId)
          .eq('student_id', studentId);
      final Map<String, int> counts = {};
      for (final r in (rows as List<dynamic>).cast<Map<String, dynamic>>()) {
        final id = (r['homework_item_id'] as String?) ?? '';
        final note = (r['note'] as String?)?.trim() ?? '';
        if (id.isEmpty) continue;
        if (note == reservationNote) continue;
        counts[id] = (counts[id] ?? 0) + 1;
      }
      return counts;
    } catch (_) {
      return <String, int>{};
    }
  }

  Future<Map<String, HomeworkAssignmentCycleMeta>> loadLatestCycleMetaByItem(
    String studentId, {
    bool excludeReservation = false,
  }) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      _ensureRealtimeForAcademy(academyId);
      final supa = Supabase.instance.client;
      final rows = await supa
          .from('homework_assignments')
          .select(
            'id,homework_item_id,repeat_index,split_parts,split_round,note,assigned_at,created_at',
          )
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .order('assigned_at', ascending: false)
          .order('created_at', ascending: false);
      final out = <String, HomeworkAssignmentCycleMeta>{};
      for (final r in (rows as List<dynamic>).cast<Map<String, dynamic>>()) {
        final itemId = (r['homework_item_id'] as String?)?.trim() ?? '';
        if (itemId.isEmpty || out.containsKey(itemId)) continue;
        final note = (r['note'] as String?)?.trim() ?? '';
        if (excludeReservation && note == reservationNote) continue;
        final splitParts = _normalizeSplitParts(r['split_parts']);
        out[itemId] = HomeworkAssignmentCycleMeta(
          assignmentId: (r['id'] as String?)?.trim() ?? '',
          homeworkItemId: itemId,
          repeatIndex: _normalizeRepeatIndex(r['repeat_index']),
          splitParts: splitParts,
          splitRound: _normalizeSplitRound(r['split_round'], splitParts),
        );
      }
      return out;
    } catch (_) {
      return <String, HomeworkAssignmentCycleMeta>{};
    }
  }

  Future<List<HomeworkAssignmentDetail>> loadActiveAssignments(
    String studentId,
  ) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      _ensureRealtimeForAcademy(academyId);
      final supa = Supabase.instance.client;
      Future<List<dynamic>> runSelect(String selectClause) async {
        final rows = await supa
            .from('homework_assignments')
            .select(selectClause)
            .eq('academy_id', academyId)
            .eq('student_id', studentId)
            .eq('status', 'assigned')
            .order('due_date', ascending: true)
            .order('order_index', ascending: true)
            .order('assigned_at', ascending: false);
        return rows as List<dynamic>;
      }

      const selectWithGroupAndLiveRelease =
          'id,homework_item_id,group_id,group_title_snapshot,assigned_at,due_date,order_index,status,note,progress,issue_type,issue_note,repeat_index,split_parts,split_round,live_release_id,release_export_job_id,live_release_locked_at,pb_live_releases(active_export_job_id,frozen_export_job_id),homework_items(id,title,type,page,count,content,flow_id)';
      const selectWithGroupLegacyLiveRelease =
          'id,homework_item_id,group_id,group_title_snapshot,assigned_at,due_date,order_index,status,note,progress,issue_type,issue_note,repeat_index,split_parts,split_round,homework_items(id,title,type,page,count,content,flow_id)';
      const selectLegacyWithLiveRelease =
          'id,homework_item_id,assigned_at,due_date,order_index,status,note,progress,issue_type,issue_note,repeat_index,split_parts,split_round,live_release_id,release_export_job_id,live_release_locked_at,pb_live_releases(active_export_job_id,frozen_export_job_id),homework_items(id,title,type,page,count,content,flow_id)';
      const selectLegacy =
          'id,homework_item_id,assigned_at,due_date,order_index,status,note,progress,issue_type,issue_note,repeat_index,split_parts,split_round,homework_items(id,title,type,page,count,content,flow_id)';

      late final List<dynamic> rows;
      try {
        rows = await runSelect(selectWithGroupAndLiveRelease);
      } catch (e) {
        if (_isMissingAssignmentGroupColumnsError(e)) {
          try {
            rows = await runSelect(selectLegacyWithLiveRelease);
          } catch (legacyErr) {
            if (_isMissingLiveReleaseColumnsError(legacyErr)) {
              rows = await runSelect(selectLegacy);
            } else {
              rethrow;
            }
          }
        } else if (_isMissingLiveReleaseColumnsError(e)) {
          rows = await runSelect(selectWithGroupLegacyLiveRelease);
        } else {
          rethrow;
        }
      }
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

      final typedRows = rows.cast<Map<String, dynamic>>();
      final liveReleaseExportJobIds = <String>{};
      for (final row in typedRows) {
        final exportJobId = _resolveLiveReleaseExportJobId(row);
        if (exportJobId.isNotEmpty) {
          liveReleaseExportJobIds.add(exportJobId);
        }
      }
      final signedUrlByExportJobId = await _loadLiveReleaseSignedUrlByExportJobId(
        academyId: academyId,
        exportJobIds: liveReleaseExportJobIds,
      );

      for (final r in typedRows) {
        final hw = r['homework_items'] as Map<String, dynamic>?;
        final groupId = _asTrimmed(r['group_id']);
        final groupTitleSnapshot = _asTrimmed(r['group_title_snapshot']);
        final splitParts = _normalizeSplitParts(r['split_parts']);
        final liveReleaseId = _asTrimmed(r['live_release_id']);
        final releaseExportJobId = _asTrimmed(r['release_export_job_id']);
        final resolvedExportJobId = _resolveLiveReleaseExportJobId(r);
        final signedUrl = signedUrlByExportJobId[resolvedExportJobId];
        list.add(
          HomeworkAssignmentDetail(
            id: (r['id'] as String?) ?? '',
            homeworkItemId: (r['homework_item_id'] as String?) ?? '',
            groupId: groupId.isEmpty ? null : groupId,
            groupTitleSnapshot:
                groupTitleSnapshot.isEmpty ? null : groupTitleSnapshot,
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
            repeatIndex: _normalizeRepeatIndex(r['repeat_index']),
            splitParts: splitParts,
            splitRound: _normalizeSplitRound(r['split_round'], splitParts),
            liveReleaseId: liveReleaseId.isEmpty ? null : liveReleaseId,
            releaseExportJobId:
                releaseExportJobId.isEmpty ? null : releaseExportJobId,
            liveReleaseLockedAt: parseTs(r['live_release_locked_at']),
            liveReleaseSignedUrl:
                signedUrl == null || signedUrl.trim().isEmpty
                    ? null
                    : signedUrl.trim(),
          ),
        );
      }
      final merged =
          _mergeServerActiveWithOptimisticReservations(studentId, list);
      _prunePendingReservedAfterLoad(studentId, merged);
      final key = studentId.trim();
      if (key.isNotEmpty) {
        _activeAssignmentsCacheByStudent[key] =
            List<HomeworkAssignmentDetail>.unmodifiable(
          List<HomeworkAssignmentDetail>.from(merged),
        );
        _activeAssignmentsLoadCompletedForStudent.add(key);
      }
      return List<HomeworkAssignmentDetail>.from(merged);
    } catch (_) {
      final key = studentId.trim();
      if (key.isNotEmpty) {
        _activeAssignmentsLoadCompletedForStudent.add(key);
        _activeAssignmentsCacheByStudent[key] =
            const <HomeworkAssignmentDetail>[];
      }
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
    _ensureRealtimeForAcademy(academyId);
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
      _ensureRealtimeForAcademy(academyId);
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
      _ensureRealtimeForAcademy(academyId);
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
      _ensureRealtimeForAcademy(academyId);
      final supa = Supabase.instance.client;
      final rows = await supa
          .from('homework_assignments')
          .select(
            'id,homework_item_id,assigned_at,due_date,order_index,status,progress,repeat_index,split_parts,split_round',
          )
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
        final splitParts = _normalizeSplitParts(r['split_parts']);
        map.putIfAbsent(itemId, () => <HomeworkAssignmentBrief>[]).add(
              HomeworkAssignmentBrief(
                id: (r['id'] as String?) ?? '',
                homeworkItemId: itemId,
                assignedAt: parseTs(r['assigned_at']),
                dueDate: parseDate(r['due_date']),
                orderIndex: parseInt(r['order_index']),
                status: (r['status'] as String?) ?? 'assigned',
                progress: parseInt(r['progress']),
                repeatIndex: _normalizeRepeatIndex(r['repeat_index']),
                splitParts: splitParts,
                splitRound: _normalizeSplitRound(r['split_round'], splitParts),
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
      _ensureRealtimeForAcademy(academyId);
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
    int splitParts = 1,
    Map<String, int>? splitPartsByItem,
    Map<String, HomeworkAssignmentGroupMeta>? groupMetaByItemId,
    String? liveReleaseId,
  }) async {
    if (items.isEmpty) return;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      _ensureRealtimeForAcademy(academyId);
      final supa = Supabase.instance.client;
      final dueDateIso = _dueDateIso(dueDate);
      final safeLiveReleaseId = (liveReleaseId ?? '').trim();
      final resolvedGroupMetaByItem = <String, HomeworkAssignmentGroupMeta>{};
      if (groupMetaByItemId != null && groupMetaByItemId.isNotEmpty) {
        for (final entry in groupMetaByItemId.entries) {
          final itemId = entry.key.trim();
          final groupId = entry.value.groupId.trim();
          final title = entry.value.groupTitleSnapshot.trim();
          if (itemId.isEmpty || groupId.isEmpty) continue;
          resolvedGroupMetaByItem[itemId] = HomeworkAssignmentGroupMeta(
            groupId: groupId,
            groupTitleSnapshot: title.isEmpty ? '그룹 과제' : title,
          );
        }
      }
      final unresolvedItemIds = items
          .map((e) => e.id.trim())
          .where((e) => e.isNotEmpty && !resolvedGroupMetaByItem.containsKey(e))
          .toSet();
      if (unresolvedItemIds.isNotEmpty) {
        try {
          resolvedGroupMetaByItem.addAll(
            await _loadGroupMetaByItemIds(
              academyId: academyId,
              itemIds: unresolvedItemIds,
            ),
          );
        } catch (_) {}
      }

      final existingRows = await supa
          .from('homework_assignments')
          .select(
            'id,homework_item_id,status,assigned_at,due_date,repeat_index,split_parts,split_round,homework_items(book_id,grade_label,page)',
          )
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .order('assigned_at', ascending: false);
      final typedExistingRows =
          (existingRows as List<dynamic>).cast<Map<String, dynamic>>();

      final allItemIds = <String>{for (final item in items) item.id};
      for (final row in typedExistingRows) {
        final itemId = _asTrimmed(row['homework_item_id']);
        if (itemId.isNotEmpty) allItemIds.add(itemId);
      }
      final unitSignatureByItemId = <String, String>{};
      if (allItemIds.isNotEmpty) {
        final unitRows = await supa
            .from('homework_item_units')
            .select('homework_item_id,big_order,mid_order,small_order')
            .eq('academy_id', academyId)
            .inFilter('homework_item_id', allItemIds.toList());
        unitSignatureByItemId.addAll(
          _buildUnitSignatureByItemFromRows(unitRows as List<dynamic>),
        );
      }

      final Map<String, Map<String, dynamic>> latestByItem = {};
      final Map<String, Map<String, dynamic>> latestByCycleKey = {};
      for (final r in typedExistingRows) {
        final itemId = (r['homework_item_id'] as String?) ?? '';
        if (itemId.isEmpty || latestByItem.containsKey(itemId)) continue;
        latestByItem[itemId] = r;
      }
      for (final r in typedExistingRows) {
        final key = _buildCycleKeyFromHistoryRow(r, unitSignatureByItemId);
        if (key.isEmpty || latestByCycleKey.containsKey(key)) continue;
        latestByCycleKey[key] = r;
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
      final existingOrderRows =
          await orderBaseQuery.order('order_index', ascending: false).limit(1);
      int nextOrder = 0;
      if (existingOrderRows is List && existingOrderRows.isNotEmpty) {
        final row = existingOrderRows.first as Map<String, dynamic>;
        nextOrder = _asInt(row['order_index']) + 1;
      }
      final acknowledgedRepeatSeedByItem =
          await _loadAcknowledgedRepeatSeedByItem(studentId, items);
      final affectedDueDates = <String?>{dueDateIso};
      for (final item in items) {
        final int requestedSplitParts =
            (splitPartsByItem?[item.id] ?? splitParts).clamp(1, 4).toInt();
        final cycleKey = buildCycleKeyForItem(item);
        final last = latestByCycleKey[cycleKey] ?? latestByItem[item.id];
        final String? lastId = last?['id'] as String?;
        final String? lastStatus = last?['status'] as String?;
        int repeatIndex = 1;
        int nextSplitParts = requestedSplitParts;
        int nextSplitRound = 1;
        if (last != null) {
          final lastRepeat = _normalizeRepeatIndex(last['repeat_index']);
          final lastSplitParts = _normalizeSplitParts(last['split_parts']);
          final lastSplitRound =
              _normalizeSplitRound(last['split_round'], lastSplitParts);
          final bool lastSplitCompleted = lastSplitRound >= lastSplitParts;

          repeatIndex = lastSplitCompleted ? lastRepeat + 1 : lastRepeat;
          if (nextSplitParts > 1) {
            if (!lastSplitCompleted && lastSplitParts == nextSplitParts) {
              repeatIndex = lastRepeat;
              nextSplitRound = (lastSplitRound + 1).clamp(1, nextSplitParts);
            } else if (!lastSplitCompleted) {
              // 분할 회차가 끝나기 전에는 반복 카운트를 올리지 않는다.
              repeatIndex = lastRepeat;
            }
          } else {
            nextSplitParts = 1;
            nextSplitRound = 1;
            if (!lastSplitCompleted) {
              repeatIndex = lastRepeat;
            }
          }
        } else {
          repeatIndex = 1 + (acknowledgedRepeatSeedByItem[item.id] ?? 0);
          nextSplitParts = nextSplitParts < 1 ? 1 : nextSplitParts;
          nextSplitRound = 1;
        }
        if (lastId != null && lastStatus != 'completed') {
          carriedOverIds.add(lastId);
          affectedDueDates.add((last?['due_date'] as String?)?.trim());
        }
        final groupMeta = resolvedGroupMetaByItem[item.id];
        final titleSnapshot = groupMeta?.groupTitleSnapshot.trim() ?? '';
        final fallbackTitle =
            item.title.trim().isEmpty ? '그룹 과제' : item.title.trim();
        rows.add({
          'id': const Uuid().v4(),
          'academy_id': academyId,
          'student_id': studentId,
          'homework_item_id': item.id,
          'group_id': groupMeta?.groupId,
          'group_title_snapshot':
              titleSnapshot.isEmpty ? fallbackTitle : titleSnapshot,
          'assigned_at': now.toUtc().toIso8601String(),
          'due_date': dueDateIso,
          'order_index': nextOrder++,
          'status': 'assigned',
          'note': note,
          'live_release_id':
              safeLiveReleaseId.isEmpty ? null : safeLiveReleaseId,
          'release_export_job_id': null,
          'live_release_locked_at': null,
          'repeat_index': repeatIndex,
          'split_parts': nextSplitParts,
          'split_round': nextSplitRound,
          'carry_over_from_id':
              (lastId != null && lastStatus != 'completed') ? lastId : null,
        });
      }

      if (carriedOverIds.isNotEmpty) {
        await supa
            .from('homework_assignments')
            .update({'status': 'carried_over'}).inFilter('id', carriedOverIds);
      }

      try {
        await supa.from('homework_assignments').insert(rows);
      } catch (e) {
        final missingGroupColumns = _isMissingAssignmentGroupColumnsError(e);
        final missingLiveReleaseColumns = _isMissingLiveReleaseColumnsError(e);
        if (!missingGroupColumns && !missingLiveReleaseColumns) rethrow;
        final fallbackRows = rows.map((row) {
          final copy = Map<String, dynamic>.from(row);
          if (missingGroupColumns) {
            copy.remove('group_id');
            copy.remove('group_title_snapshot');
          }
          if (missingLiveReleaseColumns) {
            copy.remove('live_release_id');
            copy.remove('release_export_job_id');
            copy.remove('live_release_locked_at');
          }
          return copy;
        }).toList(growable: false);
        await supa.from('homework_assignments').insert(fallbackRows);
      }
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
      _ensureRealtimeForAcademy(academyId);
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
      _ensureRealtimeForAcademy(academyId);
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
      _ensureRealtimeForAcademy(academyId);
      final supa = Supabase.instance.client;
      final rowsToClear = await supa
          .from('homework_assignments')
          .select('id,due_date')
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .eq('status', 'assigned')
          .inFilter('homework_item_id', itemIds);
      final affectedDueDates = <String?>{};
      for (final row
          in (rowsToClear as List<dynamic>).cast<Map<String, dynamic>>()) {
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

  Future<void> attachLiveReleaseToAssignments({
    required String studentId,
    required List<String> assignmentIds,
    required String liveReleaseId,
    bool onlyUncompleted = true,
  }) async {
    final safeAssignmentIds = assignmentIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final safeLiveReleaseId = liveReleaseId.trim();
    if (safeAssignmentIds.isEmpty || safeLiveReleaseId.isEmpty) return;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      _ensureRealtimeForAcademy(academyId);
      dynamic query = Supabase.instance.client
          .from('homework_assignments')
          .update(<String, dynamic>{
        'live_release_id': safeLiveReleaseId,
        'release_export_job_id': null,
        'live_release_locked_at': null,
      })
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .inFilter('id', safeAssignmentIds);
      if (onlyUncompleted) {
        query = query.inFilter('status', const <String>['assigned', 'in_progress']);
      }
      await query;
      _bump();
    } catch (e, st) {
      debugPrint('[HW_ASSIGN][attach_live_release][ERROR] $e\n$st');
    }
  }

  Future<void> detachLiveReleaseFromAssignments({
    required String studentId,
    required List<String> assignmentIds,
    bool onlyUncompleted = true,
  }) async {
    final safeAssignmentIds = assignmentIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (safeAssignmentIds.isEmpty) return;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      _ensureRealtimeForAcademy(academyId);
      dynamic query = Supabase.instance.client
          .from('homework_assignments')
          .update(<String, dynamic>{
        'live_release_id': null,
      })
          .eq('academy_id', academyId)
          .eq('student_id', studentId)
          .inFilter('id', safeAssignmentIds);
      if (onlyUncompleted) {
        query = query.inFilter('status', const <String>['assigned', 'in_progress']);
      }
      await query;
      _bump();
    } catch (e, st) {
      debugPrint('[HW_ASSIGN][detach_live_release][ERROR] $e\n$st');
    }
  }
}
