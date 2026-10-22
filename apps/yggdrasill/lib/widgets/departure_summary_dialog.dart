import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/homework_assignment_store.dart';
import '../services/homework_session_plan_service.dart';
import '../services/homework_store.dart';
import '../services/next_class_start_resolver.dart';
import '../services/student_behavior_assignment_store.dart';
import '../utils/homework_page_text.dart';
import 'app_dialog_action_button.dart';
import 'dialog_tokens.dart';
import 'homework_assign_dialog.dart';
import 'utility_glass_dialog_shell.dart';

/// 하원 요약에서 확정한 값. 숙제 선택은 하지 않고 수업 계획을 그대로 따른다.
class DepartureSummaryResult {
  const DepartureSummaryResult({
    required this.homeworkItemIds,
    required this.rolloverItemIds,
    required this.pendingPlanHomeworkItemIds,
    required this.dueDate,
    required this.dueDateChanged,
    required this.printNotice,
    required this.selectedBehaviorIds,
    required this.irregularBehaviorCounts,
  });

  /// 이미 숙제로 정해진 과제(계획의 숙제, 오늘 낸 숙제).
  final List<String> homeworkItemIds;

  /// '오늘' 계획이라 하원하면 숙제로 넘어가는 과제.
  final List<String> rolloverItemIds;

  /// 하원 때 확정해야 하는 '숙제' 계획.
  final List<String> pendingPlanHomeworkItemIds;

  /// [rolloverItemIds]의 검사일.
  final DateTime? dueDate;
  final bool dueDateChanged;
  final bool printNotice;
  final List<String> selectedBehaviorIds;
  final Map<String, int> irregularBehaviorCounts;

  List<String> get allHomeworkItemIds => <String>{
        ...homeworkItemIds,
        ...rolloverItemIds,
      }.toList(growable: false);
}

/// 하원 처리 직후 요약 결과를 서버에 반영한다. 출석 하원 저장 뒤에 호출한다.
Future<void> applyDepartureSummaryAfterSave({
  required String studentId,
  required String attendanceId,
  required DepartureSummaryResult result,
}) async {
  final key = attendanceId.trim();
  if (key.isNotEmpty && result.pendingPlanHomeworkItemIds.isNotEmpty) {
    await HomeworkSessionPlanService.instance.confirmDepartureHomework(
      attendanceId: key,
      homeworkItemIds: result.pendingPlanHomeworkItemIds,
    );
  }
  final dueDate = result.dueDate;
  if (key.isNotEmpty &&
      result.dueDateChanged &&
      dueDate != null &&
      result.rolloverItemIds.isNotEmpty) {
    await HomeworkSessionPlanService.instance.updateDueDate(
      attendanceId: key,
      homeworkItemIds: result.rolloverItemIds,
      dueDate: dueDate,
    );
  }
  HomeworkAssignmentStore.instance.invalidateActiveAssignments(studentId);
  await HomeworkStore.instance.reloadStudentHomework(studentId);
}

Future<void> finalizeDepartureTodoSheetSnapshot({
  required String attendanceId,
  required String studentId,
  required String studentName,
  required DateTime classDateTime,
  required DateTime departureTime,
  required DepartureSummaryResult result,
  DateTime? arrivalTime,
  DateTime? classEndTime,
  String? className,
  String? setId,
}) {
  return finalizeHomeworkTodoSheetSnapshot(
    attendanceId: attendanceId,
    studentId: studentId,
    studentName: studentName,
    classDateTime: classDateTime,
    arrivalTime: arrivalTime,
    departureTime: departureTime,
    selectedHomeworkIds: result.homeworkItemIds,
    additionalHomeworkIds: result.rolloverItemIds,
    selectedBehaviorIds: result.selectedBehaviorIds,
    irregularBehaviorCounts: result.irregularBehaviorCounts,
    dueDate: result.dueDate,
    className: className,
    classEndTime: classEndTime,
    setId: setId,
  );
}

Future<DepartureSummaryResult?> showDepartureSummaryDialog({
  required BuildContext context,
  required String studentId,
  required String studentName,
  required String attendanceId,
  required DateTime classDateTime,
  DateTime? arrivalTime,
  DateTime? classEndTime,
  String? className,
  String? setId,
}) {
  return showDialog<DepartureSummaryResult>(
    context: context,
    barrierColor: Colors.black54,
    builder: (dialogContext) {
      final media = MediaQuery.of(dialogContext);
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(24),
        child: UtilityGlassDialogShell(
          title: '$studentName 하원',
          icon: Icons.logout_rounded,
          preferredWidth: math.min(media.size.width - 48, 680),
          maxHeight: math.min(media.size.height - 48, 760),
          onClose: () => Navigator.of(dialogContext).pop(),
          child: _DepartureSummaryBody(
            studentId: studentId,
            studentName: studentName,
            attendanceId: attendanceId,
            classDateTime: classDateTime,
            arrivalTime: arrivalTime,
            classEndTime: classEndTime,
            className: className,
            setId: setId,
          ),
        ),
      );
    },
  );
}

enum _SummaryKind { rollover, homework, nextSession }

class _SummaryGroup {
  _SummaryGroup({
    required this.groupId,
    required this.kind,
    required this.title,
  });

  final String groupId;
  final _SummaryKind kind;
  final String title;
  final List<HomeworkItem> children = <HomeworkItem>[];
  DateTime? dueAt;

  String get meta {
    final pages = mergeHomeworkItemPageRanges(
      children.map(
        (item) => (page: item.page, unitMappings: item.unitMappings),
      ),
    );
    final count = children.fold<int>(
      0,
      (sum, item) =>
          sum +
          homeworkItemProblemCount(
            count: item.count,
            unitMappings: item.unitMappings,
          ),
    );
    return [
      if (children.length > 1) '하위 ${children.length}개',
      if (pages.isNotEmpty) 'p.$pages',
      if (count > 0) '$count문항',
    ].join(' · ');
  }
}

class _DepartureSummaryPlan {
  final List<_SummaryGroup> homeworkGroups = <_SummaryGroup>[];
  final List<_SummaryGroup> nextGroups = <_SummaryGroup>[];
  final Set<String> pendingPlanHomeworkItemIds = <String>{};

  List<String> itemIdsOf(_SummaryKind kind) => [
        for (final group in homeworkGroups)
          if (group.kind == kind)
            for (final item in group.children) item.id,
      ];
}

/// 하원 전후 어느 시점에 불러도 같은 결과가 나온다. 하원 전에는 계획의 '오늘'이
/// rollover로, 하원 뒤에는 트리거가 넘긴 '숙제' 계획으로 잡힌다.
Future<_DepartureSummaryPlan> _loadDepartureSummaryPlan({
  required String studentId,
  required String attendanceId,
  required DateTime classDateTime,
  DateTime? arrivalTime,
}) async {
  final key = attendanceId.trim();
  var plans = const <HomeworkSessionPlanItem>[];
  if (key.isNotEmpty) {
    await HomeworkSessionPlanService.instance
        .seedTodayDefaults(attendanceId: key);
    plans = await HomeworkSessionPlanService.instance.load(
      key,
      studentId: studentId,
      force: true,
    );
  }
  HomeworkAssignmentStore.instance.invalidateActiveAssignments(studentId);
  final assignments =
      await HomeworkAssignmentStore.instance.loadActiveAssignments(studentId);

  final summary = _DepartureSummaryPlan();
  final groups = <String, _SummaryGroup>{};
  final assignmentByItem = <String, HomeworkAssignmentDetail>{
    for (final a in assignments)
      if (a.note != HomeworkAssignmentStore.reservationNote &&
          a.note != HomeworkAssignmentStore.selfExtraNote)
        a.homeworkItemId: a,
  };

  void add(String itemId, _SummaryKind kind, {DateTime? dueAt}) {
    final item = HomeworkStore.instance.getById(studentId, itemId);
    if (item == null || item.status == HomeworkStatus.completed) return;
    final groupId =
        (HomeworkStore.instance.groupIdOfItem(itemId) ?? itemId).trim();
    final entry = groups.putIfAbsent('$groupId|${kind.name}', () {
      final group = HomeworkStore.instance.groupById(studentId, groupId);
      final title = (group?.title ?? '').trim();
      return _SummaryGroup(
        groupId: groupId,
        kind: kind,
        title: title.isNotEmpty
            ? title
            : (item.title.trim().isEmpty ? '그룹 과제' : item.title.trim()),
      );
    });
    entry.children.add(item);
    if (dueAt != null &&
        (entry.dueAt == null || dueAt.isBefore(entry.dueAt!))) {
      entry.dueAt = dueAt;
    }
  }

  final plannedItemIds = <String>{};
  for (final plan in plans) {
    final itemId = plan.homeworkItemId.trim();
    if (itemId.isEmpty) continue;
    plannedItemIds.add(itemId);
    final resolution = plan.resolution ?? 'pending';
    if (resolution != 'pending' && resolution != 'confirmed') continue;
    if (plan.destination == HomeworkPlanDestination.homework) {
      if (resolution == 'pending') {
        summary.pendingPlanHomeworkItemIds.add(itemId);
      }
      add(
        itemId,
        _SummaryKind.homework,
        dueAt: assignmentByItem[itemId]?.dueDate ?? plan.targetClassAt,
      );
    } else if (plan.destination == HomeworkPlanDestination.inClass &&
        plan.rolloverPolicy == HomeworkPlanRolloverPolicy.toHomework) {
      add(itemId, _SummaryKind.rollover);
    } else {
      add(itemId, _SummaryKind.nextSession);
    }
  }

  final since = arrivalTime ?? classDateTime;
  for (final assignment in assignmentByItem.values) {
    final itemId = assignment.homeworkItemId.trim();
    if (plannedItemIds.contains(itemId)) continue;
    if (assignment.assignedAt.isBefore(since)) continue;
    add(itemId, _SummaryKind.homework, dueAt: assignment.dueDate);
  }

  final sorted = groups.values.toList()
    ..sort((a, b) => a.kind.index.compareTo(b.kind.index));
  summary.homeworkGroups
      .addAll(sorted.where((g) => g.kind != _SummaryKind.nextSession));
  summary.nextGroups
      .addAll(sorted.where((g) => g.kind == _SummaryKind.nextSession));
  return summary;
}

/// 다이얼로그 없이 하원 요약을 만든다(키오스크·M5 알림장 인쇄용).
/// 숙제는 고르지 않고 수업 계획 그대로이며, 행동은 정기 항목만 기본 선택한다.
Future<DepartureSummaryResult> buildAutoDepartureSummary({
  required String studentId,
  required String attendanceId,
  required DateTime classDateTime,
  DateTime? arrivalTime,
}) async {
  final plan = await _loadDepartureSummaryPlan(
    studentId: studentId,
    attendanceId: attendanceId,
    classDateTime: classDateTime,
    arrivalTime: arrivalTime,
  );
  final behaviors = await StudentBehaviorAssignmentStore.instance
      .loadForStudent(studentId, force: true);
  final dueOptions =
      NextClassStartResolver.upcoming(studentId, after: classDateTime);
  return DepartureSummaryResult(
    homeworkItemIds: plan.itemIdsOf(_SummaryKind.homework),
    rolloverItemIds: plan.itemIdsOf(_SummaryKind.rollover),
    pendingPlanHomeworkItemIds: plan.pendingPlanHomeworkItemIds.toList(),
    dueDate: dueOptions.isEmpty ? null : dueOptions.first,
    dueDateChanged: false,
    printNotice: true,
    selectedBehaviorIds: [
      for (final behavior in behaviors)
        if (!behavior.isIrregular) behavior.id,
    ],
    irregularBehaviorCounts: {
      for (final behavior in behaviors)
        if (behavior.isIrregular) behavior.id: 1,
    },
  );
}

class _DepartureSummaryBody extends StatefulWidget {
  const _DepartureSummaryBody({
    required this.studentId,
    required this.studentName,
    required this.attendanceId,
    required this.classDateTime,
    this.arrivalTime,
    this.classEndTime,
    this.className,
    this.setId,
  });

  final String studentId;
  final String studentName;
  final String attendanceId;
  final DateTime classDateTime;
  final DateTime? arrivalTime;
  final DateTime? classEndTime;
  final String? className;
  final String? setId;

  @override
  State<_DepartureSummaryBody> createState() => _DepartureSummaryBodyState();
}

class _DepartureSummaryBodyState extends State<_DepartureSummaryBody> {
  static const _week = ['월', '화', '수', '목', '금', '토', '일'];

  bool _loading = true;
  String? _error;
  bool _previewing = false;
  bool _printNotice = false;

  final List<_SummaryGroup> _homeworkGroups = <_SummaryGroup>[];
  final List<_SummaryGroup> _nextGroups = <_SummaryGroup>[];
  final Set<String> _pendingPlanHomeworkItemIds = <String>{};
  List<DateTime> _dueOptions = const <DateTime>[];
  DateTime? _dueDate;
  bool _dueDateChanged = false;
  List<StudentBehaviorAssignment> _behaviors =
      const <StudentBehaviorAssignment>[];
  final Map<String, bool> _selectedBehaviors = <String, bool>{};
  final Map<String, int> _irregularCounts = <String, int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final plan = await _loadDepartureSummaryPlan(
        studentId: widget.studentId,
        attendanceId: widget.attendanceId,
        classDateTime: widget.classDateTime,
        arrivalTime: widget.arrivalTime,
      );
      final behaviors = await StudentBehaviorAssignmentStore.instance
          .loadForStudent(widget.studentId, force: true);
      behaviors.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
      if (!mounted) return;
      _homeworkGroups
        ..clear()
        ..addAll(plan.homeworkGroups);
      _nextGroups
        ..clear()
        ..addAll(plan.nextGroups);
      _pendingPlanHomeworkItemIds
        ..clear()
        ..addAll(plan.pendingPlanHomeworkItemIds);
      _dueOptions = NextClassStartResolver.upcoming(
        widget.studentId,
        after: widget.classDateTime,
      );
      _dueDate = _dueOptions.isEmpty ? null : _dueOptions.first;
      _behaviors = behaviors;
      for (final behavior in behaviors) {
        _selectedBehaviors[behavior.id] = !behavior.isIrregular;
        if (behavior.isIrregular) _irregularCounts[behavior.id] = 1;
      }
      setState(() => _loading = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '하원 요약을 불러오지 못했습니다. 다시 시도해 주세요.';
      });
    }
  }

  List<String> _itemIdsOf(_SummaryKind kind) => [
        for (final group in _homeworkGroups)
          if (group.kind == kind)
            for (final item in group.children) item.id,
      ];

  List<String> get _selectedBehaviorIds => [
        for (final behavior in _behaviors)
          if (_selectedBehaviors[behavior.id] ?? false) behavior.id,
      ];

  Map<String, int> get _selectedIrregularCounts => {
        for (final behavior in _behaviors)
          if (behavior.isIrregular &&
              (_selectedBehaviors[behavior.id] ?? false))
            behavior.id:
                (_irregularCounts[behavior.id] ?? 1).clamp(1, 20).toInt(),
      };

  DepartureSummaryResult _buildResult() {
    return DepartureSummaryResult(
      homeworkItemIds: _itemIdsOf(_SummaryKind.homework),
      rolloverItemIds: _itemIdsOf(_SummaryKind.rollover),
      pendingPlanHomeworkItemIds: _pendingPlanHomeworkItemIds.toList(),
      dueDate: _dueDate,
      dueDateChanged: _dueDateChanged,
      printNotice: _printNotice,
      selectedBehaviorIds: _selectedBehaviorIds,
      irregularBehaviorCounts: _selectedIrregularCounts,
    );
  }

  Future<void> _preview() async {
    if (_previewing) return;
    setState(() => _previewing = true);
    try {
      final result = _buildResult();
      await previewHomeworkTodoSheet(
        studentId: widget.studentId,
        studentName: widget.studentName,
        classDateTime: widget.classDateTime,
        arrivalTime: widget.arrivalTime,
        departureTime: DateTime.now(),
        selectedHomeworkIds: result.homeworkItemIds,
        additionalHomeworkIds: result.rolloverItemIds,
        selectedBehaviorIds: result.selectedBehaviorIds,
        irregularBehaviorCounts: result.irregularBehaviorCounts,
        dueDate: _dueDate,
        className: widget.className,
        classEndTime: widget.classEndTime,
        setId: widget.setId,
      );
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  String _two(int v) => v.toString().padLeft(2, '0');

  String _dateLabel(DateTime value) {
    final local = value.toLocal();
    return '${local.month}/${local.day} (${_week[local.weekday - 1]})';
  }

  String _sessionLabel(DateTime value) {
    final local = value.toLocal();
    return '${_dateLabel(local)} ${_two(local.hour)}:${_two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = YggDialogColors.of(context);
    if (_loading) {
      return const SizedBox(
        height: 220,
        child: Center(child: YggLoadingIndicator()),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null)
                    _message(colors, _error!, isError: true)
                  else ...[
                    _summaryLine(colors),
                    const SizedBox(height: 16),
                    _homeworkSection(colors),
                    if (_nextGroups.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _nextSection(colors),
                    ],
                    const SizedBox(height: 16),
                    _noticeSection(colors),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _actions(),
        ],
      ),
    );
  }

  Widget _summaryLine(YggDialogColors colors) {
    final homeworkCount = _homeworkGroups.length;
    final text = homeworkCount == 0
        ? '지금 하원하면 숙제로 나가는 과제가 없습니다.'
        : '지금 하원하면 $homeworkCount개 과제가 숙제로 나갑니다.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          style: TextStyle(
            color: colors.text,
            fontSize: 15,
            fontWeight: FontWeight.w800,
            decoration: TextDecoration.none,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '수업 계획의 오늘은 숙제로, 다음은 다음 수업으로 넘어갑니다. 바꾸려면 수업 계획에서 바꿔 주세요.',
          style: TextStyle(
            color: colors.textSub,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            height: 1.45,
            decoration: TextDecoration.none,
          ),
        ),
      ],
    );
  }

  Widget _homeworkSection(YggDialogColors colors) {
    final hasRollover =
        _homeworkGroups.any((group) => group.kind == _SummaryKind.rollover);
    return _section(
      colors,
      title: '숙제로 나감',
      count: _homeworkGroups.length,
      trailing: hasRollover ? _dueDatePicker(colors) : null,
      child: _homeworkGroups.isEmpty
          ? _message(colors, '숙제로 나갈 과제가 없습니다.')
          : _groupList(colors, _homeworkGroups),
    );
  }

  Widget _nextSection(YggDialogColors colors) {
    return _section(
      colors,
      title: '다음 수업으로',
      count: _nextGroups.length,
      child: _groupList(colors, _nextGroups, dimmed: true),
    );
  }

  Widget _section(
    YggDialogColors colors, {
    required String title,
    int? count,
    Widget? trailing,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 36,
          child: Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  decoration: TextDecoration.none,
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: 8),
                Text(
                  '$count',
                  style: TextStyle(
                    color: colors.textSub,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
              const Spacer(),
              if (trailing != null) trailing,
            ],
          ),
        ),
        const SizedBox(height: 4),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colors.cardBorder, width: 0.5),
          ),
          child: child,
        ),
      ],
    );
  }

  Widget _groupList(
    YggDialogColors colors,
    List<_SummaryGroup> groups, {
    bool dimmed = false,
  }) {
    return Column(
      children: [
        for (int i = 0; i < groups.length; i++) ...[
          if (i > 0)
            Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: colors.divider,
            ),
          _groupRow(colors, groups[i], dimmed: dimmed),
        ],
      ],
    );
  }

  Widget _groupRow(
    YggDialogColors colors,
    _SummaryGroup group, {
    required bool dimmed,
  }) {
    final source = switch (group.kind) {
      _SummaryKind.rollover => '오늘 과제',
      _SummaryKind.homework => '숙제',
      _SummaryKind.nextSession => '다음 수업',
    };
    final meta = group.meta;
    final DateTime? due = switch (group.kind) {
      _SummaryKind.rollover => _dueDate,
      _SummaryKind.homework => group.dueAt,
      _SummaryKind.nextSession => null,
    };
    final iconColor = dimmed ? colors.hint : kDlgAccent;
    return Opacity(
      opacity: dimmed ? 0.72 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              dimmed ? Icons.redo_rounded : Icons.assignment_outlined,
              size: 18,
              color: iconColor,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    meta.isEmpty ? source : '$source · $meta',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textSub,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
            if (due != null) ...[
              const SizedBox(width: 12),
              Text(
                '${_dateLabel(due)} 검사',
                style: TextStyle(
                  color: colors.textSub,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _dueDatePicker(YggDialogColors colors) {
    if (_dueOptions.isEmpty) {
      return Text(
        '예정 수업 없음',
        style: TextStyle(
          color: colors.hint,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          decoration: TextDecoration.none,
        ),
      );
    }
    final options = _dueOptions.take(12).toList(growable: false);
    return PopupMenuButton<DateTime>(
      tooltip: '오늘 과제의 검사일',
      color: colors.bg,
      initialValue: _dueDate,
      onSelected: (value) => setState(() {
        _dueDate = value;
        _dueDateChanged = true;
      }),
      itemBuilder: (context) => [
        for (final option in options)
          PopupMenuItem<DateTime>(
            value: option,
            child: Text(
              _sessionLabel(option),
              style: TextStyle(
                color: colors.text,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: colors.chipBg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.event_rounded, size: 16, color: colors.textSub),
            const SizedBox(width: 8),
            Text(
              _dueDate == null ? '검사일' : '${_dateLabel(_dueDate!)} 검사',
              style: TextStyle(
                color: colors.chipText,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.expand_more_rounded, size: 16, color: colors.textSub),
          ],
        ),
      ),
    );
  }

  Widget _noticeSection(YggDialogColors colors) {
    return _section(
      colors,
      title: '알림장',
      trailing: TextButton.icon(
        onPressed: _previewing ? null : _preview,
        icon: Icon(
          _previewing ? Icons.hourglass_bottom_rounded : Icons.preview_outlined,
          size: 16,
        ),
        label: Text(_previewing ? '준비 중' : '미리보기'),
        style: TextButton.styleFrom(
          foregroundColor: colors.textSub,
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ),
      child: Column(
        children: [
          SwitchListTile.adaptive(
            value: _printNotice,
            onChanged: (value) => setState(() => _printNotice = value),
            activeThumbColor: Colors.white,
            activeTrackColor: kDlgAccent,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: Text(
              '하원하면서 알림장 인쇄',
              style: TextStyle(
                color: colors.text,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text(
              '학습 리포트와 숙제·행동 리스트를 인쇄합니다.',
              style: TextStyle(
                color: colors.textSub,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final behavior in _behaviors) ...[
            Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: colors.divider,
            ),
            _behaviorRow(colors, behavior),
          ],
        ],
      ),
    );
  }

  Widget _behaviorRow(
    YggDialogColors colors,
    StudentBehaviorAssignment behavior,
  ) {
    final selected = _selectedBehaviors[behavior.id] ?? false;
    final count = _irregularCounts[behavior.id] ?? 1;
    final levelText = behavior.selectedLevelText.trim();
    final detail = [
      behavior.isIrregular ? '비정기' : '${behavior.repeatDays}일 주기',
      'lv.${behavior.safeSelectedLevelIndex + 1}',
      if (levelText.isNotEmpty) levelText,
    ].join(' · ');
    return InkWell(
      onTap: () => setState(() => _selectedBehaviors[behavior.id] = !selected),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
        child: Row(
          children: [
            Checkbox(
              value: selected,
              onChanged: (value) => setState(
                () => _selectedBehaviors[behavior.id] = value ?? false,
              ),
              activeColor: kDlgAccent,
              checkColor: Colors.white,
              side: BorderSide(color: colors.textSub),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    behavior.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textSub,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
            if (behavior.isIrregular) ...[
              _stepButton(
                colors,
                Icons.remove_rounded,
                selected && count > 1
                    ? () => setState(
                          () => _irregularCounts[behavior.id] = count - 1,
                        )
                    : null,
              ),
              SizedBox(
                width: 36,
                child: Text(
                  '$count회',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selected ? colors.text : colors.textSub,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              _stepButton(
                colors,
                Icons.add_rounded,
                selected && count < 20
                    ? () => setState(
                          () => _irregularCounts[behavior.id] = count + 1,
                        )
                    : null,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stepButton(
    YggDialogColors colors,
    IconData icon,
    VoidCallback? onPressed,
  ) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      color: colors.textSub,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _message(
    YggDialogColors colors,
    String text, {
    bool isError = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Text(
        text,
        style: TextStyle(
          color: isError ? const Color(0xFFFFB4B4) : colors.textSub,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }

  Widget _actions() {
    final canConfirm = !_loading && _error == null;
    return Row(
      children: [
        AppDialogCloseButton(
          label: '취소',
          onPressed: () => Navigator.of(context).pop(),
        ),
        const Spacer(),
        AppDialogConfirmButton(
          label: _printNotice ? '하원 · 알림장 인쇄' : '하원',
          onPressed: canConfirm
              ? () => Navigator.of(context).pop(_buildResult())
              : null,
        ),
      ],
    );
  }
}
