import 'package:flutter/material.dart';
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'tenant_service.dart';
import 'homework_assignment_store.dart';

enum HomeworkStatus { inProgress, completed, homework }

class HomeworkItem {
  final String id;
  String title;
  String body;
  Color color;
  String? flowId;
  String? type;
  String? page;
  int? count;
  String? memo;
  String? content;
  String? bookId;
  String? gradeLabel;
  String? sourceUnitLevel;
  String? sourceUnitPath;
  List<Map<String, dynamic>>? unitMappings;
  int defaultSplitParts;
  int checkCount;
  int orderIndex;
  DateTime? createdAt;
  DateTime? updatedAt;
  HomeworkStatus status;
  int phase; // 0: 종료, 1: 대기, 2: 수행, 3: 제출, 4: 확인
  int accumulatedMs; // 누적 시간(ms)
  int? _cycleBaseAccumulatedMs; // hot-reload/legacy 안전용 nullable backing
  int get cycleBaseAccumulatedMs => _cycleBaseAccumulatedMs ?? 0;
  set cycleBaseAccumulatedMs(int? value) {
    _cycleBaseAccumulatedMs = value ?? 0;
  }

  DateTime? runStart; // 진행 중이면 시작 시각
  DateTime? completedAt;
  DateTime? firstStartedAt; // 처음 시작한 시간
  DateTime? submittedAt;
  DateTime? confirmedAt;
  DateTime? waitingAt;
  int version; // OCC 버전
  HomeworkItem({
    required this.id,
    required this.title,
    required this.body,
    this.color = const Color(0xFF1976D2),
    this.flowId,
    this.type,
    this.page,
    this.count,
    this.memo,
    this.content,
    this.bookId,
    this.gradeLabel,
    this.sourceUnitLevel,
    this.sourceUnitPath,
    this.unitMappings,
    this.defaultSplitParts = 1,
    this.checkCount = 0,
    this.orderIndex = 0,
    this.createdAt,
    this.updatedAt,
    this.status = HomeworkStatus.inProgress,
    this.phase = 1,
    this.accumulatedMs = 0,
    int? cycleBaseAccumulatedMs = 0,
    this.runStart,
    this.completedAt,
    this.firstStartedAt,
    this.submittedAt,
    this.confirmedAt,
    this.waitingAt,
    this.version = 1,
  }) : _cycleBaseAccumulatedMs = (cycleBaseAccumulatedMs ?? 0);
}

class HomeworkGroup {
  final String id;
  final String studentId;
  String title;
  String? flowId;
  int orderIndex;
  String status;
  String? sourceHomeworkItemId;
  DateTime? cycleStartedAt; // 현재 사이클에서 처음 수행 진입한 시각
  DateTime? createdAt;
  DateTime? updatedAt;
  int version;
  HomeworkGroup({
    required this.id,
    required this.studentId,
    required this.title,
    this.flowId,
    this.orderIndex = 0,
    this.status = 'active',
    this.sourceHomeworkItemId,
    this.cycleStartedAt,
    this.createdAt,
    this.updatedAt,
    this.version = 1,
  });
}

class HomeworkGroupItem {
  final String id;
  final String groupId;
  final String studentId;
  final String homeworkItemId;
  int itemOrderIndex;
  DateTime? createdAt;
  DateTime? updatedAt;
  int version;
  HomeworkGroupItem({
    required this.id,
    required this.groupId,
    required this.studentId,
    required this.homeworkItemId,
    this.itemOrderIndex = 0,
    this.createdAt,
    this.updatedAt,
    this.version = 1,
  });
}

class HomeworkSplitPartInput {
  final String title;
  final String page;
  final int? count;
  final String? type;
  final String? memo;
  final String? content;
  const HomeworkSplitPartInput({
    required this.title,
    required this.page,
    this.count,
    this.type,
    this.memo,
    this.content,
  });

  Map<String, dynamic> toJson() => {
        'title': title.trim(),
        'page': page.trim(),
        if (count != null) 'count': count,
        if (type != null && type!.trim().isNotEmpty) 'type': type!.trim(),
        if (memo != null && memo!.trim().isNotEmpty) 'memo': memo!.trim(),
        if (content != null && content!.trim().isNotEmpty)
          'content': content!.trim(),
      };
}

class HomeworkStore {
  HomeworkStore._internal();
  static final HomeworkStore instance = HomeworkStore._internal();
  static const String _homeworkItemSelectWithSplit =
      'id,student_id,title,body,color,flow_id,type,page,count,memo,content,book_id,grade_label,source_unit_level,source_unit_path,default_split_parts,order_index,check_count,status,phase,accumulated_ms,cycle_base_accumulated_ms,run_start,completed_at,first_started_at,submitted_at,confirmed_at,waiting_at,created_at,updated_at,version';
  static const String _homeworkItemSelectLegacy =
      'id,student_id,title,body,color,flow_id,type,page,count,memo,content,book_id,grade_label,source_unit_level,source_unit_path,order_index,check_count,status,phase,accumulated_ms,cycle_base_accumulated_ms,run_start,completed_at,first_started_at,submitted_at,confirmed_at,waiting_at,created_at,updated_at,version';
  static const String _homeworkItemSelectWithSplitNoMemo =
      'id,student_id,title,body,color,flow_id,type,page,count,content,book_id,grade_label,source_unit_level,source_unit_path,default_split_parts,order_index,check_count,status,phase,accumulated_ms,cycle_base_accumulated_ms,run_start,completed_at,first_started_at,submitted_at,confirmed_at,waiting_at,created_at,updated_at,version';
  static const String _homeworkItemSelectLegacyNoMemo =
      'id,student_id,title,body,color,flow_id,type,page,count,content,book_id,grade_label,source_unit_level,source_unit_path,order_index,check_count,status,phase,accumulated_ms,cycle_base_accumulated_ms,run_start,completed_at,first_started_at,submitted_at,confirmed_at,waiting_at,created_at,updated_at,version';
  static const String _homeworkItemSelectWithSplitNoCycleBase =
      'id,student_id,title,body,color,flow_id,type,page,count,memo,content,book_id,grade_label,source_unit_level,source_unit_path,default_split_parts,order_index,check_count,status,phase,accumulated_ms,run_start,completed_at,first_started_at,submitted_at,confirmed_at,waiting_at,created_at,updated_at,version';
  static const String _homeworkItemSelectLegacyNoCycleBase =
      'id,student_id,title,body,color,flow_id,type,page,count,memo,content,book_id,grade_label,source_unit_level,source_unit_path,order_index,check_count,status,phase,accumulated_ms,run_start,completed_at,first_started_at,submitted_at,confirmed_at,waiting_at,created_at,updated_at,version';
  static const String _homeworkItemSelectWithSplitNoMemoNoCycleBase =
      'id,student_id,title,body,color,flow_id,type,page,count,content,book_id,grade_label,source_unit_level,source_unit_path,default_split_parts,order_index,check_count,status,phase,accumulated_ms,run_start,completed_at,first_started_at,submitted_at,confirmed_at,waiting_at,created_at,updated_at,version';
  static const String _homeworkItemSelectLegacyNoMemoNoCycleBase =
      'id,student_id,title,body,color,flow_id,type,page,count,content,book_id,grade_label,source_unit_level,source_unit_path,order_index,check_count,status,phase,accumulated_ms,run_start,completed_at,first_started_at,submitted_at,confirmed_at,waiting_at,created_at,updated_at,version';
  static const String _homeworkGroupSelect =
      'id,student_id,title,flow_id,order_index,status,source_homework_item_id,cycle_started_at,created_at,updated_at,version';
  static const String _homeworkGroupSelectNoCycleStarted =
      'id,student_id,title,flow_id,order_index,status,source_homework_item_id,created_at,updated_at,version';
  static const String _homeworkGroupItemSelect =
      'id,group_id,student_id,homework_item_id,item_order_index,created_at,updated_at,version';

  final Map<String, List<HomeworkItem>> _byStudentId = {};
  final Map<String, List<HomeworkGroup>> _groupsByStudentId = {};
  final Map<String, List<HomeworkGroupItem>> _groupItemsByGroupId = {};
  final Map<String, String> _groupIdByItemId = {};
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  // 확인 단계 이후, 다음 '대기' 진입 시 자동 완료 처리할 항목 ID들
  final Set<String> _autoCompleteOnNextWaiting = <String>{};
  // 간단 영속화 캐시 (앱 시작 시 한번 로드, 변경 시 저장)
  bool _loaded = false;
  RealtimeChannel? _rt;
  String? _rtAcademyId;
  final Map<String, Timer> _rtReloadDebounce = {};
  Timer? _rtFallbackPollTimer;
  DateTime? _rtPollCursorUtc;
  bool _rtPollInFlight = false;

  bool _isMissingDefaultSplitPartsError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('default_split_parts') &&
        (message.contains('does not exist') || message.contains('42703'));
  }

  bool _isMissingMemoColumnError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('memo') &&
        (message.contains('does not exist') || message.contains('42703'));
  }

  bool _isMissingCycleBaseColumnError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('cycle_base_accumulated_ms') &&
        (message.contains('does not exist') || message.contains('42703'));
  }

  bool _isMissingGroupCycleStartedColumnError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('cycle_started_at') &&
        (message.contains('does not exist') || message.contains('42703'));
  }

  bool _isMissingGroupTableError(Object error) {
    final message = error.toString().toLowerCase();
    if (message.contains('42p01') || message.contains('does not exist')) {
      return message.contains('homework_groups') ||
          message.contains('homework_group_items');
    }
    return false;
  }

  Future<List<Map<String, dynamic>>> _fetchHomeworkRows({
    required SupabaseClient supa,
    required String academyId,
    String? studentId,
  }) async {
    dynamic buildQuery(String selectColumns) {
      dynamic query = supa
          .from('homework_items')
          .select(selectColumns)
          .eq('academy_id', academyId);
      if (studentId != null && studentId.trim().isNotEmpty) {
        query = query.eq('student_id', studentId.trim());
      }
      return query
          .order('order_index', ascending: true)
          .order('updated_at', ascending: false);
    }

    Future<List<Map<String, dynamic>>> runSelect(String columns) async {
      final data = await buildQuery(columns);
      return (data as List<dynamic>).cast<Map<String, dynamic>>();
    }

    Future<List<Map<String, dynamic>>> runSelectWithCycleFallback({
      required String withCycleBase,
      required String withoutCycleBase,
    }) async {
      try {
        return await runSelect(withCycleBase);
      } catch (e) {
        if (_isMissingCycleBaseColumnError(e)) {
          return await runSelect(withoutCycleBase);
        }
        rethrow;
      }
    }

    try {
      return await runSelectWithCycleFallback(
        withCycleBase: _homeworkItemSelectWithSplit,
        withoutCycleBase: _homeworkItemSelectWithSplitNoCycleBase,
      );
    } catch (e) {
      if (_isMissingDefaultSplitPartsError(e)) {
        try {
          return await runSelectWithCycleFallback(
            withCycleBase: _homeworkItemSelectLegacy,
            withoutCycleBase: _homeworkItemSelectLegacyNoCycleBase,
          );
        } catch (legacyError) {
          if (_isMissingMemoColumnError(legacyError)) {
            return await runSelectWithCycleFallback(
              withCycleBase: _homeworkItemSelectLegacyNoMemo,
              withoutCycleBase: _homeworkItemSelectLegacyNoMemoNoCycleBase,
            );
          }
          rethrow;
        }
      }
      if (_isMissingMemoColumnError(e)) {
        try {
          return await runSelectWithCycleFallback(
            withCycleBase: _homeworkItemSelectWithSplitNoMemo,
            withoutCycleBase: _homeworkItemSelectWithSplitNoMemoNoCycleBase,
          );
        } catch (memoFallbackError) {
          if (_isMissingDefaultSplitPartsError(memoFallbackError)) {
            return await runSelectWithCycleFallback(
              withCycleBase: _homeworkItemSelectLegacyNoMemo,
              withoutCycleBase: _homeworkItemSelectLegacyNoMemoNoCycleBase,
            );
          }
          rethrow;
        }
      }
      rethrow;
    }
  }

  DateTime? _parseTsOpt(dynamic v) {
    if (v == null) return null;
    final s = (v is String) ? v : '$v';
    if (s.trim().isEmpty) return null;
    return DateTime.tryParse(s)?.toLocal();
  }

  int? _parseIntOpt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return int.tryParse('$v');
  }

  int _parseInt(dynamic v, {int fallback = 0}) {
    return _parseIntOpt(v) ?? fallback;
  }

  HomeworkItem _parseHomeworkItemRow(Map<String, dynamic> r) {
    return HomeworkItem(
      id: (r['id'] as String?) ?? const Uuid().v4(),
      title: (r['title'] as String?) ?? '',
      body: (r['body'] as String?) ?? '',
      color: Color(_parseInt(r['color'], fallback: 0xFF1976D2)),
      flowId: r['flow_id'] as String?,
      type: (r['type'] as String?)?.trim(),
      page: (r['page'] as String?)?.trim(),
      count: _parseIntOpt(r['count']),
      memo: (r['memo'] as String?)?.trim(),
      content: (r['content'] as String?)?.trim(),
      bookId: (r['book_id'] as String?)?.trim(),
      gradeLabel: (r['grade_label'] as String?)?.trim(),
      sourceUnitLevel: (r['source_unit_level'] as String?)?.trim(),
      sourceUnitPath: (r['source_unit_path'] as String?)?.trim(),
      defaultSplitParts:
          (_parseIntOpt(r['default_split_parts']) ?? 1).clamp(1, 4).toInt(),
      orderIndex: _parseInt(r['order_index']),
      checkCount: _parseInt(r['check_count']),
      createdAt: _parseTsOpt(r['created_at']),
      updatedAt: _parseTsOpt(r['updated_at']),
      status: HomeworkStatus.values[
          (_parseInt(r['status'])).clamp(0, HomeworkStatus.values.length - 1)],
      phase: (_parseInt(r['phase'], fallback: 1)).clamp(0, 4),
      accumulatedMs: _parseInt(r['accumulated_ms']),
      cycleBaseAccumulatedMs: _parseInt(r['cycle_base_accumulated_ms']),
      runStart: _parseTsOpt(r['run_start']),
      completedAt: _parseTsOpt(r['completed_at']),
      firstStartedAt: _parseTsOpt(r['first_started_at']),
      submittedAt: _parseTsOpt(r['submitted_at']),
      confirmedAt: _parseTsOpt(r['confirmed_at']),
      waitingAt: _parseTsOpt(r['waiting_at']),
      version: _parseInt(r['version'], fallback: 1),
    );
  }

  HomeworkGroup _parseHomeworkGroupRow(Map<String, dynamic> r) {
    return HomeworkGroup(
      id: (r['id'] as String?) ?? const Uuid().v4(),
      studentId: (r['student_id'] as String?) ?? '',
      title: ((r['title'] as String?) ?? '').trim(),
      flowId: (r['flow_id'] as String?)?.trim(),
      orderIndex: _parseInt(r['order_index']),
      status: ((r['status'] as String?) ?? 'active').trim(),
      sourceHomeworkItemId: (r['source_homework_item_id'] as String?)?.trim(),
      cycleStartedAt: _parseTsOpt(r['cycle_started_at']),
      createdAt: _parseTsOpt(r['created_at']),
      updatedAt: _parseTsOpt(r['updated_at']),
      version: _parseInt(r['version'], fallback: 1),
    );
  }

  HomeworkGroupItem _parseHomeworkGroupItemRow(Map<String, dynamic> r) {
    return HomeworkGroupItem(
      id: (r['id'] as String?) ?? const Uuid().v4(),
      groupId: (r['group_id'] as String?) ?? '',
      studentId: (r['student_id'] as String?) ?? '',
      homeworkItemId: (r['homework_item_id'] as String?) ?? '',
      itemOrderIndex: _parseInt(r['item_order_index']),
      createdAt: _parseTsOpt(r['created_at']),
      updatedAt: _parseTsOpt(r['updated_at']),
      version: _parseInt(r['version'], fallback: 1),
    );
  }

  int _compareGroupByOrder(HomeworkGroup a, HomeworkGroup b) {
    final orderCmp = a.orderIndex.compareTo(b.orderIndex);
    if (orderCmp != 0) return orderCmp;
    final aCreated = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bCreated = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final createdCmp = aCreated.compareTo(bCreated);
    if (createdCmp != 0) return createdCmp;
    return a.id.compareTo(b.id);
  }

  int _compareGroupItemByOrder(HomeworkGroupItem a, HomeworkGroupItem b) {
    final orderCmp = a.itemOrderIndex.compareTo(b.itemOrderIndex);
    if (orderCmp != 0) return orderCmp;
    final aCreated = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bCreated = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final createdCmp = aCreated.compareTo(bCreated);
    if (createdCmp != 0) return createdCmp;
    return a.id.compareTo(b.id);
  }

  bool _isLegacyGroupId(String id) => id.startsWith('legacy_');

  void _clearGroupCacheForStudent(String studentId) {
    final existingGroups = _groupsByStudentId.remove(studentId) ?? const [];
    final groupIds = existingGroups.map((g) => g.id).toSet();
    for (final gid in groupIds) {
      _groupItemsByGroupId.remove(gid);
    }
    _groupIdByItemId.removeWhere((_, gid) => groupIds.contains(gid));
  }

  void _applyFallbackGroupsForStudent(String studentId) {
    final list = _byStudentId[studentId] ?? const <HomeworkItem>[];
    if (list.isEmpty) return;
    final groups = _groupsByStudentId.putIfAbsent(studentId, () => []);

    final removedGroupIds = groups
        .where((g) => _isLegacyGroupId(g.id))
        .map((g) => g.id)
        .toList(growable: false);
    groups.removeWhere((g) => removedGroupIds.contains(g.id));
    for (final gid in removedGroupIds) {
      _groupItemsByGroupId.remove(gid);
    }
    _groupIdByItemId.removeWhere(
        (itemId, gid) => _isLegacyGroupId(gid) || !_containsItemId(itemId));

    for (final item in list) {
      if (item.status == HomeworkStatus.completed) continue;
      if (_groupIdByItemId.containsKey(item.id)) continue;
      final gid = 'legacy_${item.id}';
      groups.add(
        HomeworkGroup(
          id: gid,
          studentId: studentId,
          title: item.title,
          flowId: item.flowId,
          orderIndex: item.orderIndex,
          sourceHomeworkItemId: item.id,
          status: 'active',
          createdAt: item.createdAt,
          updatedAt: item.updatedAt,
        ),
      );
      _groupItemsByGroupId[gid] = [
        HomeworkGroupItem(
          id: 'legacy_link_${item.id}',
          groupId: gid,
          studentId: studentId,
          homeworkItemId: item.id,
          itemOrderIndex: 0,
          createdAt: item.createdAt,
          updatedAt: item.updatedAt,
        ),
      ];
      _groupIdByItemId[item.id] = gid;
    }
    groups.sort(_compareGroupByOrder);
  }

  bool _containsItemId(String itemId) {
    for (final list in _byStudentId.values) {
      if (list.any((e) => e.id == itemId)) return true;
    }
    return false;
  }

  Future<void> _reloadGroups({
    required String academyId,
    String? studentId,
    bool bump = true,
  }) async {
    final sid = studentId?.trim() ?? '';
    final targetStudent = sid.isEmpty ? null : sid;
    final supa = Supabase.instance.client;
    try {
      Future<List<Map<String, dynamic>>> runGroupQuery(
        String selectColumns,
      ) async {
        dynamic query = supa
            .from('homework_groups')
            .select(selectColumns)
            .eq('academy_id', academyId);
        if (targetStudent != null) {
          query = query.eq('student_id', targetStudent);
        }
        query = query
            .order('order_index', ascending: true)
            .order('updated_at', ascending: false);
        final rowsRaw = await query;
        return (rowsRaw as List<dynamic>).cast<Map<String, dynamic>>();
      }

      dynamic groupItemQuery = supa
          .from('homework_group_items')
          .select(_homeworkGroupItemSelect)
          .eq('academy_id', academyId);
      if (targetStudent != null) {
        groupItemQuery = groupItemQuery.eq('student_id', targetStudent);
      }
      groupItemQuery = groupItemQuery
          .order('item_order_index', ascending: true)
          .order('updated_at', ascending: false);

      List<Map<String, dynamic>> groupRows;
      try {
        groupRows = await runGroupQuery(_homeworkGroupSelect);
      } catch (e) {
        if (_isMissingGroupCycleStartedColumnError(e)) {
          groupRows = await runGroupQuery(_homeworkGroupSelectNoCycleStarted);
        } else {
          rethrow;
        }
      }
      final groupItemRowsRaw = await groupItemQuery;
      final groupItemRows =
          (groupItemRowsRaw as List<dynamic>).cast<Map<String, dynamic>>();

      if (targetStudent != null) {
        _clearGroupCacheForStudent(targetStudent);
      } else {
        _groupsByStudentId.clear();
        _groupItemsByGroupId.clear();
        _groupIdByItemId.clear();
      }

      final groupIds = <String>{};
      for (final row in groupRows) {
        final g = _parseHomeworkGroupRow(row);
        if (g.studentId.isEmpty) continue;
        _groupsByStudentId.putIfAbsent(g.studentId, () => []).add(g);
        groupIds.add(g.id);
      }
      for (final groups in _groupsByStudentId.values) {
        groups.sort(_compareGroupByOrder);
      }

      for (final row in groupItemRows) {
        final gi = _parseHomeworkGroupItemRow(row);
        if (gi.groupId.isEmpty ||
            gi.studentId.isEmpty ||
            gi.homeworkItemId.isEmpty ||
            !groupIds.contains(gi.groupId)) {
          continue;
        }
        _groupItemsByGroupId.putIfAbsent(gi.groupId, () => []).add(gi);
        _groupIdByItemId[gi.homeworkItemId] = gi.groupId;
      }
      for (final links in _groupItemsByGroupId.values) {
        links.sort(_compareGroupItemByOrder);
      }

      if (targetStudent != null) {
        _applyFallbackGroupsForStudent(targetStudent);
      } else {
        for (final sid in _byStudentId.keys) {
          _applyFallbackGroupsForStudent(sid);
        }
      }
      if (bump) _bump();
    } catch (e, st) {
      if (!_isMissingGroupTableError(e)) {
        // ignore: avoid_print
        print('[HW][groups][ERROR] $e\n$st');
      }
      if (targetStudent != null) {
        _clearGroupCacheForStudent(targetStudent);
        _applyFallbackGroupsForStudent(targetStudent);
      } else {
        _groupsByStudentId.clear();
        _groupItemsByGroupId.clear();
        _groupIdByItemId.clear();
        for (final sid in _byStudentId.keys) {
          _applyFallbackGroupsForStudent(sid);
        }
      }
      if (bump) _bump();
    }
  }

  Future<void> _reloadGroupsForStudentByAcademy({
    required String academyId,
    required String studentId,
  }) async {
    if (studentId.trim().isEmpty) return;
    await _reloadGroups(
      academyId: academyId,
      studentId: studentId,
    );
  }

  int _compareByOrder(HomeworkItem a, HomeworkItem b) {
    final orderCmp = a.orderIndex.compareTo(b.orderIndex);
    if (orderCmp != 0) return orderCmp;
    final aCreated = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bCreated = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final createdCmp = aCreated.compareTo(bCreated);
    if (createdCmp != 0) return createdCmp;
    return a.id.compareTo(b.id);
  }

  void _sortStudentList(List<HomeworkItem> list) {
    list.sort(_compareByOrder);
  }

  int _nextActiveOrderIndex(String studentId) {
    final list = _byStudentId[studentId] ?? const <HomeworkItem>[];
    var maxOrder = -1;
    for (final item in list) {
      if (item.status == HomeworkStatus.completed) continue;
      if (item.orderIndex > maxOrder) {
        maxOrder = item.orderIndex;
      }
    }
    return maxOrder + 1;
  }

  int _nextActiveOrderIndexExcluding(String studentId, {String? excludeId}) {
    final list = _byStudentId[studentId] ?? const <HomeworkItem>[];
    var maxOrder = -1;
    for (final item in list) {
      if (item.status == HomeworkStatus.completed) continue;
      if (excludeId != null && item.id == excludeId) continue;
      if (item.orderIndex > maxOrder) {
        maxOrder = item.orderIndex;
      }
    }
    return maxOrder + 1;
  }

  int _nextGroupOrderIndex(String studentId) {
    final list = _groupsByStudentId[studentId] ?? const <HomeworkGroup>[];
    var maxOrder = -1;
    for (final group in list) {
      if (group.status == 'archived') continue;
      if (group.orderIndex > maxOrder) {
        maxOrder = group.orderIndex;
      }
    }
    return maxOrder + 1;
  }

  List<HomeworkItem> items(String studentId) {
    final list = _byStudentId[studentId] ?? const <HomeworkItem>[];
    final copied = List<HomeworkItem>.from(list);
    copied.sort(_compareByOrder);
    return copied;
  }

  List<HomeworkGroup> groups(
    String studentId, {
    bool includeArchived = false,
  }) {
    final groups = _groupsByStudentId[studentId] ?? const <HomeworkGroup>[];
    final copied = List<HomeworkGroup>.from(groups);
    copied.sort(_compareGroupByOrder);
    if (includeArchived) return copied;
    return copied.where((g) => g.status != 'archived').toList();
  }

  HomeworkGroup? groupById(String studentId, String groupId) {
    final groups = _groupsByStudentId[studentId];
    if (groups == null || groups.isEmpty) return null;
    for (final g in groups) {
      if (g.id == groupId) return g;
    }
    return null;
  }

  String? groupIdOfItem(String itemId) => _groupIdByItemId[itemId];

  List<HomeworkGroupItem> groupLinks(String groupId) {
    final links = _groupItemsByGroupId[groupId] ?? const <HomeworkGroupItem>[];
    final copied = List<HomeworkGroupItem>.from(links);
    copied.sort(_compareGroupItemByOrder);
    return copied;
  }

  List<HomeworkItem> itemsInGroup(
    String studentId,
    String groupId, {
    bool includeCompleted = false,
  }) {
    final list = _byStudentId[studentId] ?? const <HomeworkItem>[];
    if (list.isEmpty) return const [];
    final byId = <String, HomeworkItem>{for (final item in list) item.id: item};
    final links = groupLinks(groupId);
    final out = <HomeworkItem>[];
    for (final link in links) {
      final item = byId[link.homeworkItemId];
      if (item == null) continue;
      if (!includeCompleted && item.status == HomeworkStatus.completed)
        continue;
      out.add(item);
    }
    if (out.isNotEmpty) return out;
    // fallback: group 매핑이 없는 레거시/이행 중 상태에서도 최소 1개 보장
    final group = groupById(studentId, groupId);
    final sourceItemId = group?.sourceHomeworkItemId?.trim() ?? '';
    if (sourceItemId.isNotEmpty) {
      final item = byId[sourceItemId];
      if (item != null &&
          (includeCompleted || item.status != HomeworkStatus.completed)) {
        return [item];
      }
    }
    return const [];
  }

  Future<List<HomeworkItem>> itemsForStats(
    String studentId, {
    bool excludeAssigned = false,
  }) async {
    final list = items(studentId);
    if (!excludeAssigned) return list;
    final assignedIds =
        await HomeworkAssignmentStore.instance.loadAssignedItemIds(studentId);
    if (assignedIds.isEmpty) return list;
    return list.where((e) => !assignedIds.contains(e.id)).toList();
  }

  Future<void> loadAll() async {
    if (_loaded) {
      try {
        final String academyId =
            (await TenantService.instance.getActiveAcademyId()) ??
                await TenantService.instance.ensureActiveAcademy();
        _subscribeRealtime(academyId);
        _startRealtimeFallbackPoll(academyId);
      } catch (_) {}
      return;
    }
    try {
      final String academyId =
          (await TenantService.instance.getActiveAcademyId()) ??
              await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final data = await _fetchHomeworkRows(
        supa: supa,
        academyId: academyId,
      );
      _byStudentId.clear();
      for (final r in data) {
        final sid = (r['student_id'] as String?) ?? '';
        if (sid.isEmpty) continue;
        final item = _parseHomeworkItemRow(r);
        _byStudentId.putIfAbsent(sid, () => <HomeworkItem>[]).add(item);
      }
      for (final entry in _byStudentId.values) {
        _sortStudentList(entry);
      }
      await _reloadGroups(academyId: academyId, bump: false);
      _loaded = true;
      _bump();
      _subscribeRealtime(academyId);
      _startRealtimeFallbackPoll(academyId);
    } catch (e, st) {
      // ignore: avoid_print
      print('[HW][loadAll][ERROR] $e\n$st');
    }
  }

  DateTime _nowUtc() => DateTime.now().toUtc();

  DateTime? _parseUtcOpt(dynamic v) {
    if (v == null) return null;
    final s = (v is String) ? v : '$v';
    final parsed = DateTime.tryParse(s);
    return parsed?.toUtc();
  }

  void _startRealtimeFallbackPoll(String academyId) {
    final targetAcademyId = academyId.trim();
    if (targetAcademyId.isEmpty) return;
    _rtFallbackPollTimer?.cancel();
    // 최근 2초 window부터 시작해 경계 타이밍 업데이트 유실을 줄인다.
    _rtPollCursorUtc = _nowUtc().subtract(const Duration(seconds: 2));
    _rtFallbackPollTimer = Timer.periodic(
      const Duration(milliseconds: 1200),
      (_) => unawaited(_pollRecentHomeworkUpdates(targetAcademyId)),
    );
  }

  Future<void> _pollRecentHomeworkUpdates(String academyId) async {
    if (_rtPollInFlight) return;
    _rtPollInFlight = true;
    try {
      final since =
          _rtPollCursorUtc ?? _nowUtc().subtract(const Duration(seconds: 2));
      final rowsRaw = await Supabase.instance.client
          .from('homework_items')
          .select('id,student_id,updated_at')
          .eq('academy_id', academyId)
          .gt('updated_at', since.toIso8601String())
          .order('updated_at', ascending: true)
          .limit(300);
      final rows = (rowsRaw as List<dynamic>).cast<Map<String, dynamic>>();
      if (rows.isEmpty) return;

      final changedStudentIds = <String>{};
      DateTime maxUpdated = since;
      for (final row in rows) {
        final sid = _strOpt(row['student_id']);
        if (sid.isNotEmpty) changedStudentIds.add(sid);
        final ts = _parseUtcOpt(row['updated_at']);
        if (ts != null && ts.isAfter(maxUpdated)) {
          maxUpdated = ts;
        }
      }
      _rtPollCursorUtc = maxUpdated.add(const Duration(milliseconds: 1));
      for (final sid in changedStudentIds) {
        _scheduleRealtimeReload(sid);
      }
      if (changedStudentIds.isNotEmpty) {
        debugPrint(
          '[HW][poll] changed students=${changedStudentIds.length} since=${since.toIso8601String()}',
        );
      }
    } catch (e, st) {
      debugPrint('[HW][poll] error: $e\n$st');
    } finally {
      _rtPollInFlight = false;
    }
  }

  Map<String, dynamic> _safePayloadRecord(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) {
      return raw.map((k, v) => MapEntry('$k', v));
    }
    return const <String, dynamic>{};
  }

  String _strOpt(dynamic v) {
    if (v == null) return '';
    if (v is String) return v.trim();
    final s = '$v'.trim();
    if (s.toLowerCase() == 'null') return '';
    return s;
  }

  bool _payloadMatchesAcademy(dynamic payload, String academyId) {
    final target = academyId.trim();
    if (target.isEmpty) return true;
    final newRec = _safePayloadRecord(payload.newRecord);
    final oldRec = _safePayloadRecord(payload.oldRecord);
    final newAcademy = _strOpt(newRec['academy_id']);
    final oldAcademy = _strOpt(oldRec['academy_id']);
    if (newAcademy.isEmpty && oldAcademy.isEmpty) return true;
    return newAcademy == target || oldAcademy == target;
  }

  String _resolveStudentIdFromPayload(dynamic payload) {
    final newRec = _safePayloadRecord(payload.newRecord);
    final oldRec = _safePayloadRecord(payload.oldRecord);
    var sid = _strOpt(newRec['student_id']);
    if (sid.isEmpty) sid = _strOpt(oldRec['student_id']);
    if (sid.isNotEmpty) return sid;

    final itemId = _strOpt(newRec['id']).isNotEmpty
        ? _strOpt(newRec['id'])
        : _strOpt(oldRec['id']);
    if (itemId.isEmpty) return '';
    for (final entry in _byStudentId.entries) {
      if (entry.value.any((e) => e.id == itemId)) {
        return entry.key;
      }
    }
    return '';
  }

  void _scheduleRealtimeReload(String studentId) {
    final sid = studentId.trim();
    if (sid.isEmpty) return;
    _rtReloadDebounce[sid]?.cancel();
    _rtReloadDebounce[sid] = Timer(const Duration(milliseconds: 120), () {
      _rtReloadDebounce.remove(sid);
      unawaited(_reloadStudent(sid));
    });
  }

  void _subscribeRealtime(String academyId) {
    try {
      final targetAcademyId = academyId.trim();
      if (targetAcademyId.isEmpty) return;
      if (_rt != null && _rtAcademyId == targetAcademyId) return;
      if (_rt != null) {
        final prev = _rt!;
        _rt = null;
        _rtAcademyId = null;
        unawaited(prev.unsubscribe());
      }
      final channelName =
          'public:homework_items:$targetAcademyId:${DateTime.now().millisecondsSinceEpoch}';
      _rt = Supabase.instance.client.channel(channelName)
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'homework_items',
          callback: (payload) {
            try {
              if (!_payloadMatchesAcademy(payload, targetAcademyId)) return;
              final sid = _resolveStudentIdFromPayload(payload);
              if (sid.isEmpty) {
                debugPrint('[HW][rt][INSERT] skip: student_id empty');
                return;
              }
              _scheduleRealtimeReload(sid);
              debugPrint('[HW][rt][INSERT] student=$sid');
            } catch (e, st) {
              debugPrint('[HW][rt][INSERT] error: $e\n$st');
            }
          },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'homework_items',
          callback: (payload) {
            try {
              if (!_payloadMatchesAcademy(payload, targetAcademyId)) return;
              final sid = _resolveStudentIdFromPayload(payload);
              if (sid.isEmpty) {
                final keys =
                    _safePayloadRecord(payload.newRecord).keys.toList();
                debugPrint(
                    '[HW][rt][UPDATE] skip: student_id empty, keys=$keys');
                return;
              }
              _scheduleRealtimeReload(sid);
              debugPrint('[HW][rt][UPDATE] student=$sid');
            } catch (e, st) {
              debugPrint('[HW][rt][UPDATE] error: $e\n$st');
            }
          },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'homework_items',
          callback: (payload) {
            if (!_payloadMatchesAcademy(payload, targetAcademyId)) return;
            final sid = _resolveStudentIdFromPayload(payload);
            if (sid.isEmpty) return;
            _scheduleRealtimeReload(sid);
            debugPrint('[HW][rt][DELETE] student=$sid');
          },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'homework_groups',
          callback: (payload) {
            if (!_payloadMatchesAcademy(payload, targetAcademyId)) return;
            String sid = (payload.newRecord['student_id'] as String?) ?? '';
            if (sid.isEmpty) {
              sid = (payload.oldRecord['student_id'] as String?) ?? '';
            }
            if (sid.isEmpty) return;
            unawaited(_reloadGroupsForStudentByAcademy(
              academyId: targetAcademyId,
              studentId: sid,
            ));
          },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'homework_group_items',
          callback: (payload) {
            if (!_payloadMatchesAcademy(payload, targetAcademyId)) return;
            String sid = (payload.newRecord['student_id'] as String?) ?? '';
            if (sid.isEmpty) {
              sid = (payload.oldRecord['student_id'] as String?) ?? '';
            }
            if (sid.isEmpty) return;
            unawaited(_reloadGroupsForStudentByAcademy(
              academyId: targetAcademyId,
              studentId: sid,
            ));
          },
        )
        ..subscribe((status, [error]) {
          debugPrint('[HW][rt] status=$status error=$error');
        });
      _rtAcademyId = targetAcademyId;
      debugPrint('[HW][rt] subscribed: $channelName');
    } catch (e, st) {
      debugPrint('[HW][rt] subscribe failed: $e\n$st');
    }
  }

  Future<void> _ensureGroupForItem({
    required String academyId,
    required String studentId,
    required HomeworkItem item,
  }) async {
    if (item.status == HomeworkStatus.completed) return;
    final existingGroupId = _groupIdByItemId[item.id];
    if (existingGroupId != null && !_isLegacyGroupId(existingGroupId)) return;
    try {
      final supa = Supabase.instance.client;
      await supa.from('homework_groups').upsert({
        'academy_id': academyId,
        'student_id': studentId,
        'title': item.title.trim().isEmpty ? '과제 그룹' : item.title.trim(),
        'flow_id': item.flowId,
        'order_index': item.orderIndex,
        'status': 'active',
        'source_homework_item_id': item.id,
      }, onConflict: 'academy_id,source_homework_item_id');

      final groupRows = await supa
          .from('homework_groups')
          .select('id')
          .eq('academy_id', academyId)
          .eq('source_homework_item_id', item.id)
          .limit(1);
      final typedGroupRows =
          (groupRows as List<dynamic>).cast<Map<String, dynamic>>();
      final groupId = typedGroupRows.isNotEmpty
          ? (typedGroupRows.first['id'] as String? ?? '')
          : '';
      if (groupId.isEmpty) return;

      await supa.from('homework_group_items').upsert({
        'academy_id': academyId,
        'group_id': groupId,
        'student_id': studentId,
        'homework_item_id': item.id,
        'item_order_index': 0,
      }, onConflict: 'academy_id,homework_item_id');

      await _reloadGroups(
        academyId: academyId,
        studentId: studentId,
        bump: false,
      );
    } catch (e) {
      if (_isMissingGroupTableError(e)) {
        _applyFallbackGroupsForStudent(studentId);
      }
    }
  }

  Future<void> _upsertItem(String studentId, HomeworkItem it) async {
    try {
      final String academyId =
          (await TenantService.instance.getActiveAcademyId()) ??
              await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final base = {
        'student_id': studentId,
        'title': it.title,
        'body': it.body,
        'color': it.color.value,
        'flow_id': it.flowId,
        'type': it.type,
        'page': it.page,
        'count': it.count,
        if (it.memo != null) 'memo': it.memo,
        'content': it.content,
        'book_id': it.bookId,
        'grade_label': it.gradeLabel,
        'source_unit_level': it.sourceUnitLevel,
        'source_unit_path': it.sourceUnitPath,
        'default_split_parts': it.defaultSplitParts.clamp(1, 4).toInt(),
        'order_index': it.orderIndex,
        'check_count': it.checkCount,
        'status': it.status.index,
        'phase': it.phase,
        'accumulated_ms': it.accumulatedMs,
        'run_start': it.runStart?.toUtc().toIso8601String(),
        'completed_at': it.completedAt?.toUtc().toIso8601String(),
        'first_started_at': it.firstStartedAt?.toUtc().toIso8601String(),
        'submitted_at': it.submittedAt?.toUtc().toIso8601String(),
        'confirmed_at': it.confirmedAt?.toUtc().toIso8601String(),
        'waiting_at': it.waitingAt?.toUtc().toIso8601String(),
      };
      // OCC update: 0행이면 예외 없이 빈 배열을 받도록 select() (list)로 처리
      final updatedRows = await supa
          .from('homework_items')
          .update(base)
          .eq('id', it.id)
          .eq('version', it.version)
          .select('version');
      final typedUpdatedRows =
          (updatedRows as List<dynamic>).cast<Map<String, dynamic>>();
      if (typedUpdatedRows.isNotEmpty) {
        final row = typedUpdatedRows.first;
        it.version = (row['version'] as num?)?.toInt() ?? (it.version + 1);
        await _syncUnitMappings(
          academyId: academyId,
          studentId: studentId,
          item: it,
        );
        await _syncPageMappings(
          academyId: academyId,
          studentId: studentId,
          item: it,
        );
        await _ensureGroupForItem(
          academyId: academyId,
          studentId: studentId,
          item: it,
        );
        return;
      }
      // Insert if not exists
      final insertRow = {
        'id': it.id,
        'academy_id': academyId,
        ...base,
        'version': it.version,
      };
      final insRows =
          await supa.from('homework_items').insert(insertRow).select('version');
      final typedInsertRows =
          (insRows as List<dynamic>).cast<Map<String, dynamic>>();
      if (typedInsertRows.isNotEmpty) {
        final row = typedInsertRows.first;
        it.version = (row['version'] as num?)?.toInt() ?? 1;
        await _syncUnitMappings(
          academyId: academyId,
          studentId: studentId,
          item: it,
        );
        await _syncPageMappings(
          academyId: academyId,
          studentId: studentId,
          item: it,
        );
        await _ensureGroupForItem(
          academyId: academyId,
          studentId: studentId,
          item: it,
        );
        return;
      }
      // Conflict fallback
      await _reloadStudent(studentId);
      throw StateError('CONFLICT_HOMEWORK_VERSION');
    } catch (e, st) {
      // ignore: avoid_print
      print('[HW][upsert][ERROR] ' + e.toString() + '\n' + st.toString());
    }
  }

  Future<void> _syncUnitMappings({
    required String academyId,
    required String studentId,
    required HomeworkItem item,
  }) async {
    final mappings = item.unitMappings;
    if (mappings == null) return;
    final supa = Supabase.instance.client;
    try {
      await supa.from('homework_item_units').delete().match({
        'academy_id': academyId,
        'homework_item_id': item.id,
      });
      final bookId = (item.bookId ?? '').trim();
      final gradeLabel = (item.gradeLabel ?? '').trim();
      if (bookId.isEmpty || gradeLabel.isEmpty || mappings.isEmpty) return;

      int? asIntOpt(dynamic v) {
        if (v == null) return null;
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v);
        return null;
      }

      double asDouble(dynamic v, {required double fallback}) {
        if (v == null) return fallback;
        if (v is num) return v.toDouble();
        if (v is String) return double.tryParse(v) ?? fallback;
        return fallback;
      }

      String asString(dynamic v, {required String fallback}) {
        final s = (v == null) ? '' : v.toString().trim();
        return s.isEmpty ? fallback : s;
      }

      final rows = <Map<String, dynamic>>[];
      final seenKeys = <String>{};
      for (final raw in mappings) {
        final m = Map<String, dynamic>.from(raw);
        final bigOrder = asIntOpt(m['bigOrder']);
        final midOrder = asIntOpt(m['midOrder']);
        final smallOrder = asIntOpt(m['smallOrder']);
        if (bigOrder == null || midOrder == null || smallOrder == null)
          continue;
        final startPage = asIntOpt(m['startPage']);
        final endPage = asIntOpt(m['endPage']);
        final pageCount = asIntOpt(m['pageCount']);
        final key = '$bigOrder|$midOrder|$smallOrder';
        if (!seenKeys.add(key)) continue;
        rows.add({
          'academy_id': academyId,
          'homework_item_id': item.id,
          'student_id': studentId,
          'book_id': bookId,
          'grade_label': gradeLabel,
          'big_order': bigOrder,
          'mid_order': midOrder,
          'small_order': smallOrder,
          'big_name': asString(m['bigName'], fallback: '대단원'),
          'mid_name': asString(m['midName'], fallback: '중단원'),
          'small_name': asString(m['smallName'], fallback: '소단원'),
          'start_page': startPage,
          'end_page': endPage,
          'page_count': pageCount,
          'weight': asDouble(m['weight'], fallback: 1),
          'source_scope': asString(
            m['sourceScope'],
            fallback: 'direct_small',
          ),
        });
      }
      if (rows.isNotEmpty) {
        await supa.from('homework_item_units').insert(rows);
      }
    } catch (e, st) {
      print('[HW][unitMappings][ERROR] $e\n$st');
    }
  }

  List<int> _parsePagesFromRawPageText(String rawPageText) {
    final raw = rawPageText.trim();
    if (raw.isEmpty) return const <int>[];
    var normalized = raw
        .replaceAll(RegExp(r'p\.', caseSensitive: false), '')
        .replaceAll('페이지', '')
        .replaceAll('쪽', '')
        .replaceAll('~', '-')
        .replaceAll('–', '-')
        .replaceAll('—', '-');
    normalized = normalized.replaceAll(RegExp(r'[^0-9,\-]+'), ',');
    normalized = normalized.replaceAll(RegExp(r',+'), ',');
    normalized = normalized.replaceAll(RegExp(r'^,+|,+$'), '');
    if (normalized.isEmpty) return const <int>[];
    final pages = <int>{};
    final tokens = normalized.split(',');
    for (final token in tokens) {
      final t = token.trim();
      if (t.isEmpty) continue;
      if (t.contains('-')) {
        final parts = t.split('-');
        if (parts.length != 2) continue;
        final start = int.tryParse(parts[0]);
        final end = int.tryParse(parts[1]);
        if (start == null || end == null) continue;
        var a = start;
        var b = end;
        if (a > b) {
          final temp = a;
          a = b;
          b = temp;
        }
        for (int p = a; p <= b; p++) {
          if (p > 0) pages.add(p);
        }
        continue;
      }
      final page = int.tryParse(t);
      if (page == null || page <= 0) continue;
      pages.add(page);
    }
    final out = pages.toList()..sort();
    return out;
  }

  List<Map<String, dynamic>> _buildManualPageRows({
    required String academyId,
    required String studentId,
    required HomeworkItem item,
    required String bookId,
    required String gradeLabel,
  }) {
    final pages = _parsePagesFromRawPageText(item.page ?? '');
    if (pages.isEmpty) return const <Map<String, dynamic>>[];
    final int totalCount = item.count ?? 0;
    final int n = pages.length;
    final rows = <Map<String, dynamic>>[];
    if (totalCount > 0 && totalCount >= n) {
      final base = totalCount ~/ n;
      final rem = totalCount % n;
      for (int i = 0; i < n; i++) {
        rows.add({
          'academy_id': academyId,
          'homework_item_id': item.id,
          'student_id': studentId,
          'book_id': bookId,
          'grade_label': gradeLabel,
          'page_number': pages[i],
          'problem_count': base + (i < rem ? 1 : 0),
        });
      }
      return rows;
    }
    for (final page in pages) {
      rows.add({
        'academy_id': academyId,
        'homework_item_id': item.id,
        'student_id': studentId,
        'book_id': bookId,
        'grade_label': gradeLabel,
        'page_number': page,
        'problem_count': 1,
      });
    }
    return rows;
  }

  Future<void> _syncPageMappings({
    required String academyId,
    required String studentId,
    required HomeworkItem item,
  }) async {
    final mappings = item.unitMappings ?? const <Map<String, dynamic>>[];
    final bookId = (item.bookId ?? '').trim();
    final gradeLabel = (item.gradeLabel ?? '').trim();
    if (bookId.isEmpty || gradeLabel.isEmpty) return;
    final supa = Supabase.instance.client;
    try {
      await supa.from('homework_item_pages').delete().match({
        'academy_id': academyId,
        'homework_item_id': item.id,
      });

      int? asIntOpt(dynamic v) {
        if (v == null) return null;
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v);
        return null;
      }

      final pageRows = <Map<String, dynamic>>[];
      final seenPages = <int>{};

      for (final raw in mappings) {
        final m = Map<String, dynamic>.from(raw);
        final pageCounts = m['pageCounts'];
        final startPage = asIntOpt(m['startPage']);
        final endPage = asIntOpt(m['endPage']);

        if (pageCounts is Map && pageCounts.isNotEmpty) {
          for (final entry in pageCounts.entries) {
            final page = asIntOpt(entry.key);
            final count = asIntOpt(entry.value) ?? 0;
            if (page == null || page <= 0 || !seenPages.add(page)) continue;
            pageRows.add({
              'academy_id': academyId,
              'homework_item_id': item.id,
              'student_id': studentId,
              'book_id': bookId,
              'grade_label': gradeLabel,
              'page_number': page,
              'problem_count': count,
            });
          }
        } else if (startPage != null &&
            endPage != null &&
            endPage >= startPage) {
          for (int p = startPage; p <= endPage; p++) {
            if (!seenPages.add(p)) continue;
            pageRows.add({
              'academy_id': academyId,
              'homework_item_id': item.id,
              'student_id': studentId,
              'book_id': bookId,
              'grade_label': gradeLabel,
              'page_number': p,
              'problem_count': 1,
            });
          }
        }
      }

      if (pageRows.isEmpty) {
        pageRows.addAll(
          _buildManualPageRows(
            academyId: academyId,
            studentId: studentId,
            item: item,
            bookId: bookId,
            gradeLabel: gradeLabel,
          ),
        );
      }

      if (pageRows.isNotEmpty) {
        await supa.from('homework_item_pages').insert(pageRows);
      }
    } catch (e, st) {
      print('[HW][pageMappings][ERROR] $e\n$st');
    }
  }

  Future<void> _distributeStatsToPages(
    String academyId,
    HomeworkItem item,
  ) async {
    if (item.accumulatedMs <= 0 && item.checkCount <= 0) return;
    final supa = Supabase.instance.client;
    try {
      final rows = await supa
          .from('homework_item_pages')
          .select('id,problem_count')
          .eq('academy_id', academyId)
          .eq('homework_item_id', item.id);
      final pages = (rows as List<dynamic>).cast<Map<String, dynamic>>();
      if (pages.isEmpty) return;

      int totalWeight = 0;
      for (final p in pages) {
        totalWeight += ((p['problem_count'] as num?)?.toInt() ?? 0);
      }
      if (totalWeight <= 0) {
        totalWeight = pages.length;
        for (final p in pages) {
          p['problem_count'] = 1;
        }
      }

      for (final p in pages) {
        final w = ((p['problem_count'] as num?)?.toInt() ?? 1);
        final ratio = w / totalWeight;
        await supa.from('homework_item_pages').update({
          'allocated_ms': (item.accumulatedMs * ratio).round(),
          'allocated_checks':
              double.parse((item.checkCount * ratio).toStringAsFixed(4)),
        }).eq('id', p['id'] as String);
      }
    } catch (e, st) {
      print('[HW][distributePages][ERROR] $e\n$st');
    }
  }

  HomeworkItem add(
    String studentId, {
    required String title,
    required String body,
    Color color = const Color(0xFF1976D2),
    String? flowId,
    String? type,
    String? page,
    int? count,
    String? memo,
    String? content,
    String? bookId,
    String? gradeLabel,
    String? sourceUnitLevel,
    String? sourceUnitPath,
    List<Map<String, dynamic>>? unitMappings,
    int defaultSplitParts = 1,
  }) {
    final id = const Uuid().v4();
    final orderIndex = _nextActiveOrderIndex(studentId);
    final item = HomeworkItem(
      id: id,
      title: title,
      body: body,
      color: color,
      flowId: flowId,
      type: type,
      page: page,
      count: count,
      memo: memo,
      content: content,
      bookId: bookId,
      gradeLabel: gradeLabel,
      sourceUnitLevel: sourceUnitLevel,
      sourceUnitPath: sourceUnitPath,
      unitMappings: unitMappings == null
          ? null
          : List<Map<String, dynamic>>.from(
              unitMappings.map((e) => Map<String, dynamic>.from(e)),
            ),
      defaultSplitParts: defaultSplitParts.clamp(1, 4).toInt(),
      checkCount: 0,
      orderIndex: orderIndex,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      version: 1,
    );
    final list = _byStudentId.putIfAbsent(studentId, () => <HomeworkItem>[]);
    list.add(item);
    _sortStudentList(list);
    _applyFallbackGroupsForStudent(studentId);
    _bump();
    unawaited(_upsertItem(studentId, item));
    return item;
  }

  void edit(String studentId, HomeworkItem updated) {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == updated.id);
    if (idx != -1) {
      list[idx] = updated;
      _applyFallbackGroupsForStudent(studentId);
      _bump();
      unawaited(_upsertItem(studentId, updated));
    }
  }

  void remove(String studentId, String id) {
    final list = _byStudentId[studentId];
    if (list == null) return;
    list.removeWhere((e) => e.id == id);
    final gid = _groupIdByItemId.remove(id);
    if (gid != null) {
      _groupItemsByGroupId[gid]?.removeWhere((e) => e.homeworkItemId == id);
      if (_isLegacyGroupId(gid)) {
        _groupItemsByGroupId.remove(gid);
        _groupsByStudentId[studentId]?.removeWhere((g) => g.id == gid);
      }
    }
    _applyFallbackGroupsForStudent(studentId);
    _sortStudentList(list);
    _bump();
    unawaited(() async {
      try {
        final supa = Supabase.instance.client;
        await supa.from('homework_items').delete().eq('id', id);
      } catch (e) {}
      await _normalizeActiveOrderIndices(studentId);
    }());
  }

  Future<void> reorderActiveItems(
    String studentId,
    List<String> orderedIds,
  ) async {
    final list = _byStudentId[studentId];
    if (list == null || list.isEmpty) return;
    final active =
        list.where((e) => e.status != HomeworkStatus.completed).toList();
    if (active.isEmpty) return;
    final activeById = <String, HomeworkItem>{
      for (final item in active) item.id: item
    };
    final used = <String>{};
    final reordered = <HomeworkItem>[];
    for (final id in orderedIds) {
      final item = activeById[id];
      if (item == null || !used.add(id)) continue;
      reordered.add(item);
    }
    final remaining = active.where((e) => !used.contains(e.id)).toList()
      ..sort(_compareByOrder);
    reordered.addAll(remaining);

    final changed = <HomeworkItem>[];
    for (int i = 0; i < reordered.length; i++) {
      final item = reordered[i];
      if (item.orderIndex != i) {
        item.orderIndex = i;
        changed.add(item);
      }
    }
    if (changed.isEmpty) return;
    _sortStudentList(list);
    _applyFallbackGroupsForStudent(studentId);
    _bump();
    for (final item in changed) {
      await _upsertItem(studentId, item);
    }
  }

  Future<void> reorderGroups(
    String studentId,
    List<String> orderedGroupIds,
  ) async {
    final groups = _groupsByStudentId[studentId];
    if (groups == null || groups.isEmpty) return;
    final byId = <String, HomeworkGroup>{for (final g in groups) g.id: g};
    final used = <String>{};
    final reordered = <HomeworkGroup>[];
    for (final gid in orderedGroupIds) {
      final g = byId[gid];
      if (g == null || !used.add(gid)) continue;
      reordered.add(g);
    }
    final remaining = groups.where((g) => !used.contains(g.id)).toList()
      ..sort(_compareGroupByOrder);
    reordered.addAll(remaining);

    final changed = <HomeworkGroup>[];
    for (int i = 0; i < reordered.length; i++) {
      final g = reordered[i];
      if (g.orderIndex != i) {
        g.orderIndex = i;
        changed.add(g);
      }
    }
    if (changed.isEmpty) return;
    _groupsByStudentId[studentId] = reordered;
    _bump();

    try {
      final academyId = (await TenantService.instance.getActiveAcademyId()) ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      for (final g in changed) {
        if (_isLegacyGroupId(g.id)) continue;
        await supa
            .from('homework_groups')
            .update({'order_index': g.orderIndex})
            .eq('academy_id', academyId)
            .eq('id', g.id);
      }
    } catch (_) {}
  }

  Future<void> moveToBottom(String studentId, String id) async {
    await placeItemAtActiveTail(studentId, id);
  }

  Future<void> _normalizeActiveOrderIndices(String studentId) async {
    final list = _byStudentId[studentId];
    if (list == null || list.isEmpty) return;
    final active = list
        .where((e) => e.status != HomeworkStatus.completed)
        .toList()
      ..sort(_compareByOrder);
    final changed = <HomeworkItem>[];
    for (int i = 0; i < active.length; i++) {
      final item = active[i];
      if (item.orderIndex != i) {
        item.orderIndex = i;
        changed.add(item);
      }
    }
    if (changed.isEmpty) return;
    _sortStudentList(list);
    _applyFallbackGroupsForStudent(studentId);
    _bump();
    for (final item in changed) {
      await _upsertItem(studentId, item);
    }
  }

  /// 숙제(homework) → 진행중(inProgress)으로 status를 전환하고 서버에도 반영한다.
  Future<void> restoreStatusFromHomework(String studentId, String id) async {
    await placeItemAtActiveTail(
      studentId,
      id,
      activateFromHomework: true,
    );
  }

  /// 활성 목록의 "맨 끝 순번"으로 재배치한다.
  /// activateFromHomework=true면 숙제 상태를 진행중으로 함께 복귀시킨다.
  Future<void> placeItemAtActiveTail(
    String studentId,
    String id, {
    bool activateFromHomework = false,
  }) async {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    final item = list[idx];
    if (item.status == HomeworkStatus.completed) return;

    bool changed = false;
    if (activateFromHomework && item.status == HomeworkStatus.homework) {
      item.status = HomeworkStatus.inProgress;
      changed = true;
    }
    final nextOrder = _nextActiveOrderIndexExcluding(studentId, excludeId: id);
    if (item.orderIndex != nextOrder) {
      item.orderIndex = nextOrder;
      changed = true;
    }
    if (!changed) return;

    _sortStudentList(list);
    _applyFallbackGroupsForStudent(studentId);
    _bump();
    await _upsertItem(studentId, item);
  }

  HomeworkItem? getById(String studentId, String id) {
    final list = _byStudentId[studentId];
    if (list == null) return null;
    final idx = list.indexWhere((e) => e.id == id);
    return idx == -1 ? null : list[idx];
  }

  HomeworkItem? runningOf(String studentId) {
    final list = _byStudentId[studentId];
    if (list == null) return null;
    final idx = list.indexWhere((e) => e.runStart != null);
    return idx == -1 ? null : list[idx];
  }

  Future<void> start(String studentId, String id) async {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    try {
      final String academyId =
          (await TenantService.instance.getActiveAcademyId()) ??
              await TenantService.instance.ensureActiveAcademy();
      final String? updatedBy = Supabase.instance.client.auth.currentUser?.id;
      await Supabase.instance.client.rpc('homework_start', params: {
        'p_item_id': id,
        'p_student_id': studentId,
        'p_academy_id': academyId,
        'p_updated_by': updatedBy,
      });
    } catch (e) {
      // ignore
    }
  }

  Future<void> pause(String studentId, String id) async {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    try {
      final String academyId =
          (await TenantService.instance.getActiveAcademyId()) ??
              await TenantService.instance.ensureActiveAcademy();
      final String? updatedBy = Supabase.instance.client.auth.currentUser?.id;
      await Supabase.instance.client.rpc('homework_pause', params: {
        'p_item_id': id,
        'p_academy_id': academyId,
        'p_updated_by': updatedBy,
      });
    } catch (_) {}
  }

  Future<void> complete(String studentId, String id) async {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    try {
      final String academyId =
          (await TenantService.instance.getActiveAcademyId()) ??
              await TenantService.instance.ensureActiveAcademy();
      await Supabase.instance.client.rpc('homework_complete', params: {
        'p_item_id': id,
        'p_academy_id': academyId,
      });
      await _reloadStudent(studentId);
      unawaited(_normalizeActiveOrderIndices(studentId));
      final completed = getById(studentId, id);
      if (completed != null) {
        unawaited(_distributeStatsToPages(academyId, completed));
      }
    } catch (_) {}
  }

  Future<void> submit(String studentId, String id) async {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    final item = list[idx];
    // UI 반응성을 위해 즉시 로컬 phase를 제출(3)로 반영한다.
    final now = DateTime.now();
    if (item.runStart != null) {
      item.accumulatedMs += now.difference(item.runStart!).inMilliseconds;
      item.runStart = null;
    }
    item.phase = 3;
    item.submittedAt = now;
    item.updatedAt = now;
    _bump();
    try {
      final String academyId =
          (await TenantService.instance.getActiveAcademyId()) ??
              await TenantService.instance.ensureActiveAcademy();
      final String? updatedBy = Supabase.instance.client.auth.currentUser?.id;
      await Supabase.instance.client.rpc('homework_submit', params: {
        'p_item_id': id,
        'p_academy_id': academyId,
        'p_updated_by': updatedBy,
      });
      // 비동기 보정: 리얼타임 지연 시 강제 재로드
      unawaited(_reloadStudent(studentId));
    } catch (e) {
      // ignore: avoid_print
      print('[HW][submit][ERROR] ' + e.toString());
      // 서버 반영 실패 시 로컬 낙관적 업데이트를 정합 상태로 복구한다.
      unawaited(_reloadStudent(studentId));
    }
  }

  Future<void> confirm(
    String studentId,
    String id, {
    bool recordAssignmentCheck = true,
  }) async {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    final item = list[idx];
    // 제출 카운트가 즉시 내려가도록 로컬 phase를 먼저 확인(4)으로 반영한다.
    item.phase = 4;
    item.confirmedAt = DateTime.now();
    item.runStart = null;
    item.updatedAt = item.confirmedAt;
    _bump();
    try {
      final String academyId =
          (await TenantService.instance.getActiveAcademyId()) ??
              await TenantService.instance.ensureActiveAcademy();
      final String? updatedBy = Supabase.instance.client.auth.currentUser?.id;
      await Supabase.instance.client.rpc('homework_confirm', params: {
        'p_item_id': id,
        'p_academy_id': academyId,
        'p_updated_by': updatedBy,
      });
      unawaited(_reloadStudent(studentId));
      if (recordAssignmentCheck) {
        unawaited(
            HomeworkAssignmentStore.instance.recordAssignmentCheckForConfirm(
          studentId: studentId,
          homeworkItemId: id,
        ));
      }
    } catch (e) {
      // ignore: avoid_print
      print('[HW][confirm][ERROR] ' + e.toString());
      // 서버 반영 실패 시 로컬 낙관적 업데이트를 정합 상태로 복구한다.
      unawaited(_reloadStudent(studentId));
    }
  }

  Future<void> waitPhase(String studentId, String id) async {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    try {
      final String academyId =
          (await TenantService.instance.getActiveAcademyId()) ??
              await TenantService.instance.ensureActiveAcademy();
      final String? updatedBy = Supabase.instance.client.auth.currentUser?.id;
      await Supabase.instance.client.rpc('homework_wait', params: {
        'p_item_id': id,
        'p_academy_id': academyId,
        'p_updated_by': updatedBy,
      });
      unawaited(_reloadStudent(studentId).then((_) {
        final item = getById(studentId, id);
        if (item != null) {
          _maybeAutoCompleteOnWaiting(studentId, item);
        }
      }));
    } catch (e) {
      // ignore: avoid_print
      print('[HW][wait][ERROR] ' + e.toString());
    }
  }

  Future<void> abandon(
    String studentId,
    String id,
    String reason,
  ) async {
    if (reason.trim().isEmpty) return;
    try {
      final String academyId =
          (await TenantService.instance.getActiveAcademyId()) ??
              await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      await supa.from('homework_item_phase_events').insert({
        'academy_id': academyId,
        'item_id': id,
        'phase': 4,
        'note': '포기: ${reason.trim()}',
      });
      await complete(studentId, id);
    } catch (e) {
      // ignore: avoid_print
      print('[HW][abandon][ERROR] ' + e.toString());
    }
  }

  void _maybeAutoCompleteOnWaiting(String studentId, HomeworkItem item) {
    if (item.phase == 1 /* waiting */ &&
        _autoCompleteOnNextWaiting.remove(item.id)) {
      // 확인 → 대기로 전이된 첫 타이밍에 자동 완료
      unawaited(complete(studentId, item.id));
    }
  }

  // 제출 상태에서 더블클릭 시, 다음 '대기' 진입에 자동 완료되도록 표시
  void markAutoCompleteOnNextWaiting(String id) {
    _autoCompleteOnNextWaiting.add(id);
  }

  HomeworkItem continueAdd(
    String studentId,
    String sourceId, {
    required String body,
    String? flowId,
    String? type,
    String? page,
    int? count,
    String? memo,
    String? content,
    int? defaultSplitParts,
  }) {
    final list = _byStudentId[studentId];
    if (list == null) {
      return add(
        studentId,
        title: '과제',
        body: body,
        flowId: flowId,
        type: type,
        page: page,
        count: count,
        memo: memo,
        content: content ?? body,
        defaultSplitParts: defaultSplitParts ?? 1,
      );
    }
    final idx = list.indexWhere((e) => e.id == sourceId);
    if (idx == -1) {
      return add(
        studentId,
        title: '과제',
        body: body,
        flowId: flowId,
        type: type,
        page: page,
        count: count,
        memo: memo,
        content: content ?? body,
        defaultSplitParts: defaultSplitParts ?? 1,
      );
    }
    final src = list[idx];
    final created = add(
      studentId,
      title: src.title,
      body: body,
      color: src.color,
      flowId: flowId ?? src.flowId,
      type: type ?? src.type,
      page: page ?? src.page,
      count: count ?? src.count,
      memo: memo ?? src.memo,
      content: content ?? src.content ?? body,
      bookId: src.bookId,
      gradeLabel: src.gradeLabel,
      sourceUnitLevel: src.sourceUnitLevel,
      sourceUnitPath: src.sourceUnitPath,
      unitMappings: src.unitMappings == null
          ? null
          : List<Map<String, dynamic>>.from(
              src.unitMappings!.map((e) => Map<String, dynamic>.from(e)),
            ),
      defaultSplitParts:
          (defaultSplitParts ?? src.defaultSplitParts).clamp(1, 4).toInt(),
    );
    // add()가 서버 upsert를 처리함
    return created;
  }

  // 하원 시 미완료 과제들을 숙제로 표시
  void markIncompleteAsHomework(String studentId) {
    final list = _byStudentId[studentId];
    if (list == null) return;
    bool changed = false;
    final now = DateTime.now();
    final List<HomeworkItem> toAssign = [];
    for (final e in list) {
      if (e.status != HomeworkStatus.completed) {
        bool updated = false;
        if (e.runStart != null) {
          // 진행 중이면 일시정지 후 숙제로 전환
          e.accumulatedMs += now.difference(e.runStart!).inMilliseconds;
          e.runStart = null;
          updated = true;
        }
        if (e.phase != 1) {
          e.phase = 1;
          e.waitingAt = now;
          e.submittedAt = null;
          e.confirmedAt = null;
          updated = true;
        }
        if (e.status != HomeworkStatus.homework) {
          e.status = HomeworkStatus.homework;
          updated = true;
          toAssign.add(e);
        }
        if (updated) changed = true;
      }
    }
    if (changed) {
      _bump();
      for (final e in list.where((e) => e.status == HomeworkStatus.homework)) {
        unawaited(_upsertItem(studentId, e));
      }
      if (toAssign.isNotEmpty) {
        final splitPartsByItem = <String, int>{
          for (final item in toAssign)
            item.id: item.defaultSplitParts.clamp(1, 4).toInt(),
        };
        unawaited(HomeworkAssignmentStore.instance.recordAssignments(
          studentId,
          toAssign,
          splitPartsByItem: splitPartsByItem,
        ));
      }
    }
  }

  // 선택된 과제들을 숙제로 표시
  void markItemsAsHomework(
    String studentId,
    List<String> itemIds, {
    DateTime? dueDate,
    int splitParts = 1,
    bool cloneCompletedItems = false,
  }) {
    if (itemIds.isEmpty) return;
    final list = _byStudentId[studentId];
    if (list == null) return;
    final Set<String> idSet = itemIds.toSet();
    final Map<String, HomeworkItem> byId = <String, HomeworkItem>{
      for (final item in list) item.id: item,
    };
    bool changed = false;
    final now = DateTime.now();
    final List<HomeworkItem> toAssign = [];
    final Map<String, int> splitPartsByItem = <String, int>{};
    final Map<String, HomeworkItem> toUpsert = {};
    for (final id in idSet) {
      HomeworkItem? e = byId[id];
      if (e == null) continue;
      if (e.status == HomeworkStatus.completed) {
        if (!cloneCompletedItems) continue;
        e = continueAdd(
          studentId,
          e.id,
          body: e.body,
          flowId: e.flowId,
          type: e.type,
          page: e.page,
          count: e.count,
          content: e.content,
        );
        byId[e.id] = e;
      }
      bool updated = false;
      if (e.runStart != null) {
        e.accumulatedMs += now.difference(e.runStart!).inMilliseconds;
        e.runStart = null;
        updated = true;
      }
      if (e.phase != 1) {
        e.phase = 1;
        e.waitingAt = now;
        e.submittedAt = null;
        e.confirmedAt = null;
        updated = true;
      }
      if (e.status != HomeworkStatus.homework) {
        e.status = HomeworkStatus.homework;
        updated = true;
      }
      toAssign.add(e);
      final int itemSplitParts = splitParts > 1
          ? splitParts.clamp(1, 4).toInt()
          : e.defaultSplitParts.clamp(1, 4).toInt();
      splitPartsByItem[e.id] = itemSplitParts;
      if (updated) {
        changed = true;
        toUpsert[e.id] = e;
      }
    }
    if (changed) {
      _bump();
      for (final e in toUpsert.values) {
        unawaited(_upsertItem(studentId, e));
      }
    }
    if (toAssign.isNotEmpty) {
      unawaited(HomeworkAssignmentStore.instance.recordAssignments(
        studentId,
        toAssign,
        dueDate: dueDate,
        splitParts: splitParts,
        splitPartsByItem: splitPartsByItem,
      ));
    }
  }

  // 하원 시 선택하지 않은 과제를 즉시 "대기(진행중)"로 복귀시키고
  // 홈 메뉴 숨김 기준(active assigned)에서도 해제한다.
  void restoreItemsToWaiting(
    String studentId,
    List<String> itemIds,
  ) {
    if (itemIds.isEmpty) return;
    final list = _byStudentId[studentId];
    if (list == null) {
      unawaited(
        HomeworkAssignmentStore.instance.clearActiveAssignmentsForItems(
          studentId,
          itemIds,
        ),
      );
      return;
    }

    final idSet = itemIds.toSet();
    bool changed = false;
    final now = DateTime.now();
    final Map<String, HomeworkItem> toUpsert = {};
    for (final e in list) {
      if (!idSet.contains(e.id)) continue;
      if (e.status == HomeworkStatus.completed) continue;
      bool updated = false;
      if (e.runStart != null) {
        e.accumulatedMs += now.difference(e.runStart!).inMilliseconds;
        e.runStart = null;
        updated = true;
      }
      if (e.phase != 1) {
        e.phase = 1;
        e.waitingAt = now;
        e.submittedAt = null;
        e.confirmedAt = null;
        updated = true;
      }
      if (e.status != HomeworkStatus.inProgress) {
        e.status = HomeworkStatus.inProgress;
        updated = true;
      }
      if (updated) {
        changed = true;
        toUpsert[e.id] = e;
      }
    }

    if (changed) {
      _bump();
      for (final e in toUpsert.values) {
        unawaited(_upsertItem(studentId, e));
      }
    }

    unawaited(
      HomeworkAssignmentStore.instance.clearActiveAssignmentsForItems(
        studentId,
        itemIds,
      ),
    );
  }

  List<String> _stringListFromDynamic(dynamic raw) {
    if (raw is List) {
      return raw
          .map((e) => '$e'.trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    }
    return const <String>[];
  }

  Future<bool> _hasActiveAssignmentForAny(
    String studentId,
    Iterable<String> itemIds,
  ) async {
    final idSet =
        itemIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (idSet.isEmpty) return false;
    return HomeworkAssignmentStore.instance.hasActiveAssignmentForAnyItems(
      studentId,
      idSet,
    );
  }

  Future<void> _applyGroupCycleDistributionByCount({
    required String studentId,
    required List<String> childIds,
    required Map<String, int> cycleBaseById,
    required Map<String, int> weightById,
    required int cycleDeltaMs,
  }) async {
    if (cycleDeltaMs <= 0 || childIds.isEmpty) return;
    final rows = <HomeworkItem>[];
    for (final id in childIds) {
      final item = getById(studentId, id);
      if (item == null || item.status == HomeworkStatus.completed) continue;
      rows.add(item);
    }
    if (rows.isEmpty) return;

    final weights = <String, int>{};
    int totalWeight = 0;
    for (final item in rows) {
      final fallbackWeight =
          (item.count != null && item.count! > 0) ? item.count! : 1;
      final weight = (weightById[item.id] ?? fallbackWeight);
      final safeWeight = weight > 0 ? weight : 1;
      weights[item.id] = safeWeight;
      totalWeight += safeWeight;
    }
    if (totalWeight <= 0) return;

    final allocated = <String, int>{};
    int allocatedSum = 0;
    for (final item in rows) {
      final w = weights[item.id] ?? 1;
      final ms = (cycleDeltaMs * w) ~/ totalWeight;
      allocated[item.id] = ms;
      allocatedSum += ms;
    }
    int remainder = cycleDeltaMs - allocatedSum;
    if (remainder > 0) {
      final ordered = rows.toList(growable: false)
        ..sort((a, b) {
          final byWeight = (weights[b.id] ?? 1).compareTo(weights[a.id] ?? 1);
          if (byWeight != 0) return byWeight;
          return a.id.compareTo(b.id);
        });
      int idx = 0;
      while (remainder > 0 && ordered.isNotEmpty) {
        final item = ordered[idx % ordered.length];
        allocated[item.id] = (allocated[item.id] ?? 0) + 1;
        remainder -= 1;
        idx += 1;
      }
    }

    final now = DateTime.now();
    bool changed = false;
    for (final item in rows) {
      final base = cycleBaseById[item.id] ?? item.cycleBaseAccumulatedMs;
      final targetAccumulated = base + (allocated[item.id] ?? 0);
      if (item.accumulatedMs == targetAccumulated) continue;
      item.accumulatedMs = targetAccumulated;
      item.updatedAt = now;
      changed = true;
    }
    if (!changed) return;
    _bump();
    for (final item in rows) {
      await _upsertItem(studentId, item);
    }
  }

  Future<int> bulkTransitionGroup(String studentId, String groupId,
      {int? fromPhase}) async {
    final cleanedGroupId = groupId.trim();
    if (cleanedGroupId.isEmpty) return 0;
    final normalizedFromPhase = fromPhase;
    final now = DateTime.now();
    final beforeChildren = (normalizedFromPhase == 4)
        ? itemsInGroup(studentId, cleanedGroupId, includeCompleted: true)
            .where((e) => e.status != HomeworkStatus.completed)
            .toList(growable: false)
        : const <HomeworkItem>[];
    final beforeIds = <String>[
      for (final child in beforeChildren) child.id,
    ];
    final beforeCycleBaseById = <String, int>{
      for (final child in beforeChildren)
        child.id: (child.cycleBaseAccumulatedMs <= 0 &&
                child.phase == 1 &&
                child.accumulatedMs > 0)
            ? child.accumulatedMs
            : child.cycleBaseAccumulatedMs,
    };
    final beforeWeightById = <String, int>{
      for (final child in beforeChildren)
        child.id: (child.count != null && child.count! > 0) ? child.count! : 1,
    };
    int groupCycleDeltaMs = 0;
    for (final child in beforeChildren) {
      final childRunningMs = child.runStart != null
          ? now.difference(child.runStart!).inMilliseconds
          : 0;
      final childCurrent = child.accumulatedMs + childRunningMs;
      final base = beforeCycleBaseById[child.id] ?? 0;
      final delta = childCurrent - base;
      if (delta > groupCycleDeltaMs) {
        groupCycleDeltaMs = delta;
      }
    }
    try {
      final academyId = (await TenantService.instance.getActiveAcademyId()) ??
          await TenantService.instance.ensureActiveAcademy();
      final raw = await Supabase.instance.client.rpc(
        'homework_group_bulk_transition',
        params: {
          'p_group_id': cleanedGroupId,
          'p_academy_id': academyId,
          'p_from_phase': normalizedFromPhase,
        },
      );
      await _reloadStudent(studentId);
      if (normalizedFromPhase == 4 &&
          groupCycleDeltaMs > 0 &&
          beforeIds.isNotEmpty) {
        await _applyGroupCycleDistributionByCount(
          studentId: studentId,
          childIds: beforeIds,
          cycleBaseById: beforeCycleBaseById,
          weightById: beforeWeightById,
          cycleDeltaMs: groupCycleDeltaMs,
        );
      }
      return _parseInt(raw);
    } catch (_) {
      return 0;
    }
  }

  Future<List<String>> splitWaitingItemInGroup({
    required String studentId,
    required String groupId,
    required String sourceItemId,
    required List<HomeworkSplitPartInput> parts,
  }) async {
    final cleanedGroupId = groupId.trim();
    final cleanedSourceId = sourceItemId.trim();
    if (cleanedGroupId.isEmpty || cleanedSourceId.isEmpty || parts.isEmpty) {
      return const <String>[];
    }
    if (await _hasActiveAssignmentForAny(studentId, [cleanedSourceId])) {
      throw StateError('ASSIGNMENT_EXISTS_FOR_SPLIT_ITEM');
    }
    try {
      final academyId = (await TenantService.instance.getActiveAcademyId()) ??
          await TenantService.instance.ensureActiveAcademy();
      final payload = parts
          .map((part) => part.toJson())
          .where((part) => (part['page'] as String? ?? '').trim().isNotEmpty)
          .toList(growable: false);
      if (payload.isEmpty) return const <String>[];
      final raw = await Supabase.instance.client.rpc(
        'homework_group_split_waiting',
        params: {
          'p_group_id': cleanedGroupId,
          'p_source_item_id': cleanedSourceId,
          'p_parts': payload,
          'p_academy_id': academyId,
        },
      );
      final result = (raw is Map<String, dynamic>) ? raw : <String, dynamic>{};
      final createdIds = _stringListFromDynamic(result['created_item_ids']);
      await _reloadStudent(studentId);
      for (int i = 0; i < createdIds.length && i < payload.length; i++) {
        final memo = (payload[i]['memo'] as String?)?.trim() ?? '';
        if (memo.isEmpty) continue;
        final item = getById(studentId, createdIds[i]);
        if (item == null || (item.memo ?? '').trim() == memo) continue;
        item.memo = memo;
        item.updatedAt = DateTime.now();
        await _upsertItem(studentId, item);
      }
      for (final id in createdIds) {
        final item = getById(studentId, id);
        if (item == null) continue;
        await _syncPageMappings(
          academyId: academyId,
          studentId: studentId,
          item: item,
        );
      }
      await _normalizeActiveOrderIndices(studentId);
      return createdIds;
    } catch (e) {
      throw StateError(e.toString());
    }
  }

  Future<String?> mergeWaitingItemsInGroup({
    required String studentId,
    required String groupId,
    required List<String> itemIds,
    required String mergedTitle,
    required String mergedPage,
    int? mergedCount,
    String? mergedType,
    String? mergedMemo,
    String? mergedContent,
  }) async {
    final cleanedGroupId = groupId.trim();
    final cleanedIds = itemIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (cleanedGroupId.isEmpty || cleanedIds.length < 2) return null;
    if (await _hasActiveAssignmentForAny(studentId, cleanedIds)) {
      throw StateError('ASSIGNMENT_EXISTS_FOR_MERGE_ITEMS');
    }
    try {
      final academyId = (await TenantService.instance.getActiveAcademyId()) ??
          await TenantService.instance.ensureActiveAcademy();
      final mergedPayload = <String, dynamic>{
        'title': mergedTitle.trim(),
        'page': mergedPage.trim(),
        if (mergedCount != null) 'count': mergedCount,
        if (mergedType != null && mergedType.trim().isNotEmpty)
          'type': mergedType.trim(),
        if (mergedMemo != null && mergedMemo.trim().isNotEmpty)
          'memo': mergedMemo.trim(),
        if (mergedContent != null && mergedContent.trim().isNotEmpty)
          'content': mergedContent.trim(),
      };
      final raw = await Supabase.instance.client.rpc(
        'homework_group_merge_waiting',
        params: {
          'p_group_id': cleanedGroupId,
          'p_item_ids': cleanedIds,
          'p_merged_payload': mergedPayload,
          'p_academy_id': academyId,
        },
      );
      final result = (raw is Map<String, dynamic>) ? raw : <String, dynamic>{};
      final mergedId = (result['merged_item_id'] as String?)?.trim();
      await _reloadStudent(studentId);
      final normalizedMergedMemo = (mergedMemo ?? '').trim();
      if (mergedId != null && mergedId.isNotEmpty) {
        final mergedItem = getById(studentId, mergedId);
        if (mergedItem != null) {
          if (normalizedMergedMemo.isNotEmpty &&
              (mergedItem.memo ?? '').trim() != normalizedMergedMemo) {
            mergedItem.memo = normalizedMergedMemo;
            mergedItem.updatedAt = DateTime.now();
            await _upsertItem(studentId, mergedItem);
          }
          await _syncPageMappings(
            academyId: academyId,
            studentId: studentId,
            item: mergedItem,
          );
        }
      }
      await _normalizeActiveOrderIndices(studentId);
      return (mergedId == null || mergedId.isEmpty) ? null : mergedId;
    } catch (e) {
      throw StateError(e.toString());
    }
  }

  Future<String?> addWaitingItemToGroup({
    required String studentId,
    required String groupId,
    required String title,
    String? body,
    String? page,
    int? count,
    String? type,
    String? memo,
    String? content,
    String? templateItemId,
    String? flowId,
    Color? color,
    int? defaultSplitParts,
  }) async {
    final cleanedGroupId = groupId.trim();
    if (cleanedGroupId.isEmpty) return null;

    HomeworkItem? template;
    final cleanedTemplateId = (templateItemId ?? '').trim();
    if (cleanedTemplateId.isNotEmpty) {
      template = getById(studentId, cleanedTemplateId);
    }
    template ??= () {
      final children =
          itemsInGroup(studentId, cleanedGroupId, includeCompleted: true);
      return children.isEmpty ? null : children.first;
    }();

    final group = groupById(studentId, cleanedGroupId);
    final now = DateTime.now();
    final resolvedTitle = title.trim().isNotEmpty
        ? title.trim()
        : ((template?.title ?? '').trim().isNotEmpty
            ? template!.title.trim()
            : '과제');
    final resolvedBody = (body ?? '').trim().isNotEmpty
        ? body!.trim()
        : ((template?.body ?? '').trim().isNotEmpty
            ? template!.body.trim()
            : resolvedTitle);
    final resolvedPage = (page ?? '').trim();
    final resolvedType = (type ?? '').trim();
    final resolvedMemo = (memo ?? '').trim();
    final resolvedContent = (content ?? '').trim();
    final resolvedFlowId = (flowId ?? '').trim();
    final int? resolvedCount = (count != null && count > 0) ? count : null;
    final resolvedColor = color ?? template?.color ?? const Color(0xFF1976D2);
    final resolvedSplitParts =
        (defaultSplitParts ?? template?.defaultSplitParts ?? 1)
            .clamp(1, 4)
            .toInt();

    final item = HomeworkItem(
      id: const Uuid().v4(),
      title: resolvedTitle,
      body: resolvedBody,
      color: resolvedColor,
      flowId: resolvedFlowId.isNotEmpty
          ? resolvedFlowId
          : (template?.flowId ?? group?.flowId),
      type: resolvedType.isEmpty ? template?.type : resolvedType,
      page: resolvedPage.isEmpty ? template?.page : resolvedPage,
      count: resolvedCount,
      memo: resolvedMemo.isEmpty ? template?.memo : resolvedMemo,
      content: resolvedContent.isEmpty ? template?.content : resolvedContent,
      bookId: template?.bookId,
      gradeLabel: template?.gradeLabel,
      sourceUnitLevel: template?.sourceUnitLevel,
      sourceUnitPath: template?.sourceUnitPath,
      unitMappings: null,
      defaultSplitParts: resolvedSplitParts,
      checkCount: 0,
      orderIndex: _nextActiveOrderIndex(studentId),
      createdAt: now,
      updatedAt: now,
      status: HomeworkStatus.inProgress,
      phase: 1,
      accumulatedMs: 0,
      runStart: null,
      completedAt: null,
      firstStartedAt: null,
      submittedAt: null,
      confirmedAt: null,
      waitingAt: now,
      version: 1,
    );

    final list = _byStudentId.putIfAbsent(studentId, () => <HomeworkItem>[]);
    list.add(item);
    _sortStudentList(list);
    _bump();

    try {
      final academyId = (await TenantService.instance.getActiveAcademyId()) ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final base = {
        'student_id': studentId,
        'title': item.title,
        'body': item.body,
        'color': item.color.value,
        'flow_id': item.flowId,
        'type': item.type,
        'page': item.page,
        'count': item.count,
        if (item.memo != null) 'memo': item.memo,
        'content': item.content,
        'book_id': item.bookId,
        'grade_label': item.gradeLabel,
        'source_unit_level': item.sourceUnitLevel,
        'source_unit_path': item.sourceUnitPath,
        'default_split_parts': item.defaultSplitParts.clamp(1, 4).toInt(),
        'order_index': item.orderIndex,
        'check_count': item.checkCount,
        'status': item.status.index,
        'phase': item.phase,
        'accumulated_ms': item.accumulatedMs,
        'run_start': item.runStart?.toUtc().toIso8601String(),
        'completed_at': item.completedAt?.toUtc().toIso8601String(),
        'first_started_at': item.firstStartedAt?.toUtc().toIso8601String(),
        'submitted_at': item.submittedAt?.toUtc().toIso8601String(),
        'confirmed_at': item.confirmedAt?.toUtc().toIso8601String(),
        'waiting_at': item.waitingAt?.toUtc().toIso8601String(),
      };

      final insRows = await supa.from('homework_items').insert({
        'id': item.id,
        'academy_id': academyId,
        ...base,
        'version': item.version,
      }).select('version');
      final typedInsertRows =
          (insRows as List<dynamic>).cast<Map<String, dynamic>>();
      if (typedInsertRows.isNotEmpty) {
        item.version = (typedInsertRows.first['version'] as num?)?.toInt() ?? 1;
      }

      final links = groupLinks(cleanedGroupId);
      var nextItemOrder = 0;
      for (final link in links) {
        if (link.itemOrderIndex >= nextItemOrder) {
          nextItemOrder = link.itemOrderIndex + 1;
        }
      }
      await supa.from('homework_group_items').upsert({
        'academy_id': academyId,
        'group_id': cleanedGroupId,
        'student_id': studentId,
        'homework_item_id': item.id,
        'item_order_index': nextItemOrder,
      }, onConflict: 'academy_id,homework_item_id');

      await _syncUnitMappings(
        academyId: academyId,
        studentId: studentId,
        item: item,
      );
      await _syncPageMappings(
        academyId: academyId,
        studentId: studentId,
        item: item,
      );
      await _reloadStudent(studentId);
      return item.id;
    } catch (e, st) {
      print('[HW][addWaitingItemToGroup][ERROR] $e\n$st');
      await _reloadStudent(studentId);
      return null;
    }
  }

  Future<List<HomeworkItem>> createGroupWithWaitingItems({
    required String studentId,
    required String groupTitle,
    String? flowId,
    required List<Map<String, dynamic>> items,
  }) async {
    if (items.isEmpty) return const <HomeworkItem>[];
    String asText(dynamic value) => (value as String?)?.trim() ?? '';
    int? asPositiveInt(dynamic value) {
      if (value is int) return value > 0 ? value : null;
      if (value is num) {
        final parsed = value.toInt();
        return parsed > 0 ? parsed : null;
      }
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        return (parsed != null && parsed > 0) ? parsed : null;
      }
      return null;
    }

    Color? asColor(dynamic value) {
      if (value is Color) return value;
      if (value is int) return Color(value);
      if (value is num) return Color(value.toInt());
      return null;
    }

    int asSplitParts(dynamic value) {
      final parsed = asPositiveInt(value) ?? 1;
      return parsed.clamp(1, 4).toInt();
    }

    final normalized = <Map<String, dynamic>>[];
    for (final raw in items) {
      final entry = Map<String, dynamic>.from(raw);
      final titleRaw = asText(entry['title']);
      final page = asText(entry['page']);
      final countText = asText(entry['count']);
      final content = asText(entry['content']);
      final title = titleRaw.isEmpty ? '과제' : titleRaw;
      var body = asText(entry['body']);
      if (body.isEmpty) {
        final parts = <String>[];
        if (page.isNotEmpty) parts.add('p.$page');
        if (countText.isNotEmpty) parts.add('${countText}문항');
        if (parts.isEmpty) {
          body = content.isEmpty ? title : content;
        } else {
          body = content.isEmpty
              ? parts.join(' / ')
              : '${parts.join(' / ')}\n$content';
        }
      }
      normalized.add({
        ...entry,
        'title': title,
        'body': body,
      });
    }
    if (normalized.isEmpty) return const <HomeworkItem>[];

    final cleanedFlowId = (flowId ?? '').trim();
    final cleanedGroupTitle =
        groupTitle.trim().isEmpty ? '그룹 과제' : groupTitle.trim();
    final now = DateTime.now();
    final groupId = const Uuid().v4();
    final group = HomeworkGroup(
      id: groupId,
      studentId: studentId,
      title: cleanedGroupTitle,
      flowId: cleanedFlowId.isEmpty ? null : cleanedFlowId,
      orderIndex: _nextGroupOrderIndex(studentId),
      status: 'active',
      sourceHomeworkItemId: null,
      createdAt: now,
      updatedAt: now,
      version: 1,
    );
    final studentGroups =
        _groupsByStudentId.putIfAbsent(studentId, () => <HomeworkGroup>[]);
    studentGroups.add(group);
    studentGroups.sort(_compareGroupByOrder);
    _bump();

    try {
      final academyId = (await TenantService.instance.getActiveAcademyId()) ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      await supa.from('homework_groups').insert({
        'id': groupId,
        'academy_id': academyId,
        'student_id': studentId,
        'title': cleanedGroupTitle,
        'flow_id': cleanedFlowId.isEmpty ? null : cleanedFlowId,
        'order_index': group.orderIndex,
        'status': 'active',
        'version': 1,
      });

      final createdIds = <String>[];
      for (final entry in normalized) {
        final createdId = await addWaitingItemToGroup(
          studentId: studentId,
          groupId: groupId,
          title: asText(entry['title']),
          body: asText(entry['body']),
          page: asText(entry['page']),
          count: asPositiveInt(entry['count']),
          type: asText(entry['type']),
          memo: asText(entry['memo']),
          content: asText(entry['content']),
          flowId: cleanedFlowId.isEmpty ? null : cleanedFlowId,
          color: asColor(entry['color']),
          defaultSplitParts: asSplitParts(entry['splitParts']),
        );
        if (createdId != null && createdId.isNotEmpty) {
          createdIds.add(createdId);
        }
      }

      await _reloadStudent(studentId);
      final createdItems = <HomeworkItem>[];
      for (final id in createdIds) {
        final item = getById(studentId, id);
        if (item != null) createdItems.add(item);
      }
      return createdItems;
    } catch (e, st) {
      print('[HW][createGroupWithWaitingItems][ERROR] $e\n$st');
      await _reloadStudent(studentId);
      return const <HomeworkItem>[];
    }
  }

  void _bump() {
    revision.value++;
  }

  Future<void> _reloadStudent(String studentId) async {
    try {
      final String academyId =
          (await TenantService.instance.getActiveAcademyId()) ??
              await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final data = await _fetchHomeworkRows(
        supa: supa,
        academyId: academyId,
        studentId: studentId,
      );
      final List<HomeworkItem> list = [];
      for (final r in data) {
        list.add(_parseHomeworkItemRow(r));
      }
      _sortStudentList(list);
      _byStudentId[studentId] = list;
      await _reloadGroups(
        academyId: academyId,
        studentId: studentId,
        bump: false,
      );
      _bump();
    } catch (_) {}
  }
}
