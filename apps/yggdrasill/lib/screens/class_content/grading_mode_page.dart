import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/data_manager.dart';
import '../../services/homework_assignment_store.dart';
import '../../services/homework_store.dart';
import '../../widgets/dialog_tokens.dart';

const double _kGradingBaseCardWidth = 288.0;
const double _kGradingBaseCardMetaHeight = 128.0;
const double _kGradingBaseCardHeight =
    _kGradingBaseCardWidth * 1.414 * 0.9 + _kGradingBaseCardMetaHeight;
const double _kGradingWidthScale = 0.9;
const double _kGradingCardAspectRatio =
    (_kGradingBaseCardWidth * _kGradingWidthScale) / _kGradingBaseCardHeight;
const double _kGradingCardMetaRatio =
    _kGradingBaseCardMetaHeight / _kGradingBaseCardHeight;
const double _kGradingCardHeightByViewport = 0.52;
const double _kGradingCardMinHeight = 140.0;
const double _kGradingCardMaxHeight = 620.0;
const double _kGradingCardMinWidth = 108.0;
const double _kGradingCardMaxWidth = 396.0;
const double _kGradingSectionGapTop = 22.0;
const double _kGradingSectionGapBottom = 18.0;
const double _kGradingSectionHeaderGap = 12.0;
const EdgeInsets _kGradingPagePadding = EdgeInsets.fromLTRB(24, 0, 24, 24);

typedef GradingGroupTapCallback = Future<void> Function(
  String studentId,
  HomeworkGroup? group,
  HomeworkItem summary,
  List<HomeworkItem> children,
);

class GradingModePage extends StatefulWidget {
  final List<String> attendingStudentIds;
  final Map<String, String> studentNamesById;
  final GradingGroupTapCallback? onSubmittedCardTap;
  final GradingGroupTapCallback? onHomeworkCardTap;
  final Map<({String studentId, String itemId}), bool> pendingConfirms;
  final void Function(String studentId, String itemId)? onTogglePending;

  const GradingModePage({
    super.key,
    required this.attendingStudentIds,
    required this.studentNamesById,
    this.onSubmittedCardTap,
    this.onHomeworkCardTap,
    this.pendingConfirms = const <({String studentId, String itemId}), bool>{},
    this.onTogglePending,
  });

  @override
  State<GradingModePage> createState() => _GradingModePageState();
}

class _GradingModePageState extends State<GradingModePage> {
  final Map<String, Future<String?>> _coverPathFutureByKey =
      <String, Future<String?>>{};
  Future<Map<String, List<HomeworkAssignmentDetail>>>? _activeAssignmentsFuture;
  int _activeAssignmentsRevision = -1;
  String _activeAssignmentsStudentsKey = '';

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: HomeworkStore.instance.revision,
      builder: (context, _, __) {
        return ValueListenableBuilder<int>(
          valueListenable: HomeworkAssignmentStore.instance.revision,
          builder: (context, assignmentRevision, __) {
            return FutureBuilder<Map<String, List<HomeworkAssignmentDetail>>>(
              future: _activeAssignmentsForAttending(assignmentRevision),
              builder: (context, assignmentSnapshot) {
                final activeAssignmentsByStudent = assignmentSnapshot.data ??
                    const <String, List<HomeworkAssignmentDetail>>{};
                final submittedEntries =
                    _buildSubmittedEntries(activeAssignmentsByStudent);
                final homeworkEntries = _buildHomeworkEntries(
                  activeAssignmentsByStudent,
                );
                if (submittedEntries.isEmpty && homeworkEntries.isEmpty) {
                  return const _GradingEmptyState();
                }
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final cardLayout = _resolveCardLayout(
                      constraints,
                      MediaQuery.of(context).size.height,
                      submittedCount: submittedEntries.length,
                      homeworkCount: homeworkEntries.length,
                    );
                    return CustomScrollView(
                      physics: const NeverScrollableScrollPhysics(),
                      slivers: [
                        SliverPadding(
                          padding: _kGradingPagePadding,
                          sliver: SliverList(
                            delegate: SliverChildListDelegate(
                              [
                                if (submittedEntries.isNotEmpty)
                                  _buildEntryWrap(
                                    submittedEntries,
                                    cardLayout: cardLayout,
                                    onCardTap: widget.onSubmittedCardTap,
                                    canTapEntry: (entry) =>
                                        entry.hasSubmittedChild,
                                  )
                                else if (homeworkEntries.isNotEmpty)
                                  _buildSubmittedEmptyPlaceholder(
                                    cardLayout: cardLayout,
                                  ),
                                if (homeworkEntries.isNotEmpty) ...[
                                  const SizedBox(
                                      height: _kGradingSectionGapTop),
                                  const Divider(
                                      height: 1, color: Color(0xFF2A3A3A)),
                                  const SizedBox(
                                      height: _kGradingSectionGapBottom),
                                  _buildSectionHeader(
                                    title: '숙제 과제',
                                    count: homeworkEntries.length,
                                  ),
                                  const SizedBox(
                                      height: _kGradingSectionHeaderGap),
                                  _buildEntryWrap(
                                    homeworkEntries,
                                    cardLayout: cardLayout,
                                    onCardTap: widget.onHomeworkCardTap,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  _GradingCardLayout _resolveCardLayout(
    BoxConstraints constraints,
    double fallbackViewportHeight, {
    required int submittedCount,
    required int homeworkCount,
  }) {
    final viewportWidth =
        constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width;
    final viewportHeight =
        constraints.maxHeight.isFinite && constraints.maxHeight > 0
            ? constraints.maxHeight
            : fallbackViewportHeight;
    final baseCardHeight = (viewportHeight * _kGradingCardHeightByViewport)
        .clamp(_kGradingCardMinHeight, _kGradingCardMaxHeight)
        .toDouble();
    final availableWidth =
        (viewportWidth - _kGradingPagePadding.left - _kGradingPagePadding.right)
            .clamp(140.0, viewportWidth)
            .toDouble();
    final fitLimit = math.max(0.0, viewportHeight - 8.0);

    // 숙제 섹션이 잠시 비어도 카드가 과도하게 커지지 않도록 최소 1행 기준으로 안정화.
    final effectiveHomeworkCount =
        (homeworkCount == 0 && submittedCount > 0) ? 1 : homeworkCount;

    final baseLayout = _layoutFromCardHeight(baseCardHeight);
    final baseNeededHeight = _estimateTotalContentHeight(
      cardLayout: baseLayout,
      availableWidth: availableWidth,
      submittedCount: submittedCount,
      homeworkCount: effectiveHomeworkCount,
    );
    if (baseNeededHeight <= fitLimit) return baseLayout;

    double low = _kGradingCardMinHeight;
    double high = baseCardHeight;
    var best = _layoutFromCardHeight(low);
    for (int i = 0; i < 24; i++) {
      final mid = (low + high) / 2;
      final candidate = _layoutFromCardHeight(mid);
      final neededHeight = _estimateTotalContentHeight(
        cardLayout: candidate,
        availableWidth: availableWidth,
        submittedCount: submittedCount,
        homeworkCount: effectiveHomeworkCount,
      );
      if (neededHeight <= fitLimit) {
        best = candidate;
        low = mid;
      } else {
        high = mid;
      }
    }
    return best;
  }

  _GradingCardLayout _layoutFromCardHeight(double cardHeight) {
    final height = cardHeight
        .clamp(_kGradingCardMinHeight, _kGradingCardMaxHeight)
        .toDouble();
    final width = (height * _kGradingCardAspectRatio)
        .clamp(_kGradingCardMinWidth, _kGradingCardMaxWidth)
        .toDouble();
    final spacing = (width * 0.08).clamp(8.0, 24.0).toDouble();
    final maxMetaHeight = math.min(
      height * 0.55,
      math.max(64.0, height * 0.42),
    );
    final minMetaHeight = math.min(90.0, maxMetaHeight);
    final metaHeight = (height * _kGradingCardMetaRatio)
        .clamp(minMetaHeight, maxMetaHeight)
        .toDouble();
    return _GradingCardLayout(
      width: width,
      height: height,
      metaHeight: metaHeight,
      spacing: spacing,
    );
  }

  double _estimateWrapHeight({
    required int itemCount,
    required _GradingCardLayout cardLayout,
    required double availableWidth,
  }) {
    if (itemCount <= 0) return 0;
    final rawCols = ((availableWidth + cardLayout.spacing) /
            (cardLayout.width + cardLayout.spacing))
        .floor();
    final cols = math.max(1, rawCols);
    final rows = (itemCount + cols - 1) ~/ cols;
    if (rows <= 0) return 0;
    return rows * cardLayout.height + (rows - 1) * cardLayout.spacing;
  }

  double _estimateTotalContentHeight({
    required _GradingCardLayout cardLayout,
    required double availableWidth,
    required int submittedCount,
    required int homeworkCount,
  }) {
    double total = _kGradingPagePadding.top + _kGradingPagePadding.bottom;
    if (submittedCount > 0) {
      total += _estimateWrapHeight(
        itemCount: submittedCount,
        cardLayout: cardLayout,
        availableWidth: availableWidth,
      );
    } else if (homeworkCount > 0) {
      // 제출 섹션이 비어도 상단 공간을 유지해 숙제 섹션 위치를 고정한다.
      total += _estimateWrapHeight(
        itemCount: 1,
        cardLayout: cardLayout,
        availableWidth: availableWidth,
      );
    }
    if (homeworkCount > 0) {
      total += _kGradingSectionGapTop + 1 + _kGradingSectionGapBottom;
      total += 24 + _kGradingSectionHeaderGap; // section header + gap
      total += _estimateWrapHeight(
        itemCount: homeworkCount,
        cardLayout: cardLayout,
        availableWidth: availableWidth,
      );
    }
    return total;
  }

  Future<Map<String, List<HomeworkAssignmentDetail>>>
      _activeAssignmentsForAttending(
    int assignmentRevision,
  ) {
    final studentsKey = widget.attendingStudentIds.join('|');
    if (_activeAssignmentsFuture == null ||
        _activeAssignmentsRevision != assignmentRevision ||
        _activeAssignmentsStudentsKey != studentsKey) {
      _activeAssignmentsRevision = assignmentRevision;
      _activeAssignmentsStudentsKey = studentsKey;
      _activeAssignmentsFuture =
          _loadActiveAssignmentsMap(widget.attendingStudentIds);
    }
    return _activeAssignmentsFuture!;
  }

  Future<Map<String, List<HomeworkAssignmentDetail>>> _loadActiveAssignmentsMap(
    List<String> studentIds,
  ) async {
    final out = <String, List<HomeworkAssignmentDetail>>{};
    for (final studentId in studentIds) {
      final assignments = await HomeworkAssignmentStore.instance
          .loadActiveAssignments(studentId);
      final filtered = assignments.where((assignment) {
        final note = (assignment.note ?? '').trim();
        return note != HomeworkAssignmentStore.reservationNote;
      }).toList(growable: false);
      out[studentId] = filtered;
    }
    return out;
  }

  Widget _buildSectionHeader({
    required String title,
    required int count,
  }) {
    return Row(
      children: [
        Text(
          '$title $count개',
          style: const TextStyle(
            color: kDlgText,
            fontSize: 20,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.2,
          ),
        ),
      ],
    );
  }

  Widget _buildSubmittedEmptyPlaceholder({
    required _GradingCardLayout cardLayout,
  }) {
    return SizedBox(
      width: double.infinity,
      height: cardLayout.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF0F1718),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF2A3A3A)),
        ),
        child: const Center(
          child: Text(
            '활성 제출 과제가 없습니다.',
            style: TextStyle(
              color: Color(0xFF7F8C8C),
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEntryWrap(
    List<_GradingGroupEntry> entries, {
    required _GradingCardLayout cardLayout,
    GradingGroupTapCallback? onCardTap,
    bool Function(_GradingGroupEntry entry)? canTapEntry,
  }) {
    return Wrap(
      alignment: WrapAlignment.start,
      textDirection: TextDirection.rtl,
      spacing: cardLayout.spacing,
      runSpacing: cardLayout.spacing,
      children: [
        for (final entry in entries)
          SizedBox(
            width: cardLayout.width,
            height: cardLayout.height,
            child: _SubmittedHomeworkCard(
              entry: entry,
              cardHeight: cardLayout.height,
              metaHeight: cardLayout.metaHeight,
              isPendingConfirm: _isEntryPending(entry),
              isCompleteCheckbox: _isEntryPendingComplete(entry),
              coverPathFuture: (() {
                final coverSource = _resolveEntryCoverSource(entry);
                return _resolveCoverPath(
                  bookId: coverSource.bookId,
                  gradeLabel: coverSource.gradeLabel,
                  flowId: (entry.summary.flowId ?? '').trim(),
                );
              })(),
              onTap: onCardTap == null
                  ? null
                  : () async {
                      if (canTapEntry != null && !canTapEntry(entry)) return;
                      await onCardTap(
                        entry.studentId,
                        entry.group,
                        entry.summary,
                        entry.children,
                      );
                    },
            ),
          ),
      ],
    );
  }

  ({String bookId, String gradeLabel}) _resolveEntryCoverSource(
    _GradingGroupEntry entry,
  ) {
    final summaryBookId = (entry.summary.bookId ?? '').trim();
    final summaryGrade = (entry.summary.gradeLabel ?? '').trim();
    if (summaryBookId.isNotEmpty) {
      return (bookId: summaryBookId, gradeLabel: summaryGrade);
    }
    for (final child in entry.children) {
      final bookId = (child.bookId ?? '').trim();
      if (bookId.isEmpty) continue;
      return (bookId: bookId, gradeLabel: (child.gradeLabel ?? '').trim());
    }
    return (bookId: '', gradeLabel: summaryGrade);
  }

  List<_GradingGroupEntry> _buildSubmittedEntries(
    Map<String, List<HomeworkAssignmentDetail>> activeAssignmentsByStudent,
  ) {
    final out = <_GradingGroupEntry>[];
    for (final studentId in widget.attendingStudentIds) {
      final studentName = widget.studentNamesById[studentId] ?? '학생';
      out.addAll(
        _buildEntriesForStudent(
          studentId: studentId,
          studentName: studentName,
          assignments: activeAssignmentsByStudent[studentId] ?? const [],
          section: _GradingSection.submitted,
        ),
      );
    }
    out.sort((a, b) {
      final t = a.submittedTime.compareTo(b.submittedTime);
      if (t != 0) return t;
      final nameCmp = a.studentName.compareTo(b.studentName);
      if (nameCmp != 0) return nameCmp;
      return a.summary.id.compareTo(b.summary.id);
    });
    return out;
  }

  List<_GradingGroupEntry> _buildHomeworkEntries(
    Map<String, List<HomeworkAssignmentDetail>> activeAssignmentsByStudent,
  ) {
    final out = <_GradingGroupEntry>[];
    for (final studentId in widget.attendingStudentIds) {
      final studentName = widget.studentNamesById[studentId] ?? '학생';
      out.addAll(
        _buildEntriesForStudent(
          studentId: studentId,
          studentName: studentName,
          assignments: activeAssignmentsByStudent[studentId] ?? const [],
          section: _GradingSection.homework,
        ),
      );
    }
    out.sort((a, b) {
      final ad = a.dueDate;
      final bd = b.dueDate;
      if (ad == null && bd != null) return 1;
      if (ad != null && bd == null) return -1;
      if (ad != null && bd != null) {
        final dueCmp = ad.compareTo(bd);
        if (dueCmp != 0) return dueCmp;
      }
      final t = a.homeworkTime.compareTo(b.homeworkTime);
      if (t != 0) return t;
      final nameCmp = a.studentName.compareTo(b.studentName);
      if (nameCmp != 0) return nameCmp;
      return a.summary.id.compareTo(b.summary.id);
    });
    return out;
  }

  bool _isSubmittedVisible(HomeworkItem item) {
    return item.status != HomeworkStatus.completed &&
        item.completedAt == null &&
        item.phase == 3;
  }

  DateTime _submittedSortTimeOfItem(HomeworkItem item) {
    return item.submittedAt ??
        item.updatedAt ??
        item.createdAt ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  DateTime _homeworkSortTimeOfItem(HomeworkItem item) {
    return item.waitingAt ??
        item.updatedAt ??
        item.createdAt ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  DateTime _submittedSortTimeOfChildren(List<HomeworkItem> children) {
    DateTime? earliest;
    for (final child in children) {
      if (!_isSubmittedVisible(child)) continue;
      final ts = _submittedSortTimeOfItem(child);
      if (earliest == null || ts.isBefore(earliest)) {
        earliest = ts;
      }
    }
    return earliest ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  DateTime _homeworkSortTimeOfChildren(List<HomeworkItem> children) {
    DateTime? earliest;
    for (final child in children) {
      final ts = _homeworkSortTimeOfItem(child);
      if (earliest == null || ts.isBefore(earliest)) {
        earliest = ts;
      }
    }
    return earliest ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  DateTime? _dateOnly(DateTime? dt) {
    if (dt == null) return null;
    return DateTime(dt.year, dt.month, dt.day);
  }

  DateTime? _mergeDueDate(DateTime? current, DateTime? candidate) {
    if (current == null) return candidate;
    if (candidate == null) return current;
    return candidate.isBefore(current) ? candidate : current;
  }

  DateTime? _latestDate(DateTime? current, DateTime? candidate) {
    if (current == null) return candidate;
    if (candidate == null) return current;
    return candidate.isAfter(current) ? candidate : current;
  }

  List<({String studentId, String itemId})> _entryPendingKeys(
    _GradingGroupEntry entry,
  ) {
    final out = <({String studentId, String itemId})>[];
    for (final child in entry.children) {
      if (!_isSubmittedVisible(child)) continue;
      out.add((studentId: entry.studentId, itemId: child.id));
    }
    return out;
  }

  bool _isEntryPending(_GradingGroupEntry entry) {
    final keys = _entryPendingKeys(entry);
    if (keys.isEmpty) return false;
    return keys.any(widget.pendingConfirms.containsKey);
  }

  bool _isEntryPendingComplete(_GradingGroupEntry entry) {
    final keys = _entryPendingKeys(entry);
    if (keys.isEmpty) return false;
    return keys.any((key) => widget.pendingConfirms[key] == true);
  }

  List<_GradingGroupEntry> _buildEntriesForStudent({
    required String studentId,
    required String studentName,
    required List<HomeworkAssignmentDetail> assignments,
    required _GradingSection section,
  }) {
    final out = <_GradingGroupEntry>[];
    final assignmentByItemId = <String, List<HomeworkAssignmentDetail>>{};
    for (final assignment in assignments) {
      final itemId = assignment.homeworkItemId.trim();
      if (itemId.isEmpty) continue;
      assignmentByItemId
          .putIfAbsent(itemId, () => <HomeworkAssignmentDetail>[])
          .add(assignment);
    }

    final coveredItemIds = <String>{};
    final groups = HomeworkStore.instance.groups(studentId);
    for (final group in groups) {
      final children = HomeworkStore.instance
          .itemsInGroup(studentId, group.id)
          .where((e) => e.status != HomeworkStatus.completed)
          .toList(growable: false);
      if (children.isEmpty) continue;
      coveredItemIds.addAll(children.map((e) => e.id));

      final submittedChildren =
          children.where(_isSubmittedVisible).toList(growable: false);
      final assignedChildren = children
          .where(
            (child) =>
                assignmentByItemId.containsKey(child.id) && child.phase != 0,
          )
          .toList(growable: false);
      final hasSubmitted = submittedChildren.isNotEmpty;
      final hasHomeworkAssignment = assignedChildren.isNotEmpty;

      final include = section == _GradingSection.submitted
          ? hasSubmitted
          : (!hasSubmitted && hasHomeworkAssignment);
      if (!include) continue;

      DateTime? dueDate;
      String groupTitleSnapshot = '';
      for (final child in assignedChildren) {
        final childAssignments = assignmentByItemId[child.id] ?? const [];
        for (final assignment in childAssignments) {
          dueDate = _mergeDueDate(dueDate, _dateOnly(assignment.dueDate));
          if (groupTitleSnapshot.isEmpty) {
            final snapshot = (assignment.groupTitleSnapshot ?? '').trim();
            if (snapshot.isNotEmpty) groupTitleSnapshot = snapshot;
          }
        }
      }

      final summary = _buildGroupSummaryItem(
        group: group,
        children: children,
        titleSnapshot: groupTitleSnapshot,
      );
      final displayTitle = groupTitleSnapshot.isNotEmpty
          ? groupTitleSnapshot
          : (group.title.trim().isNotEmpty
              ? group.title.trim()
              : summary.title);
      out.add(
        _GradingGroupEntry(
          studentId: studentId,
          studentName: studentName,
          group: group,
          summary: summary,
          children: children,
          displayTitle: displayTitle.trim().isEmpty ? '그룹 과제' : displayTitle,
          dueDate: dueDate,
          submittedTime: _submittedSortTimeOfChildren(children),
          homeworkTime: _homeworkSortTimeOfChildren(children),
        ),
      );
    }

    final looseItems = HomeworkStore.instance
        .items(studentId)
        .where((e) => e.status != HomeworkStatus.completed)
        .where((e) => !coveredItemIds.contains(e.id))
        .toList(growable: false);
    for (final item in looseItems) {
      final hasSubmitted = _isSubmittedVisible(item);
      final hasHomeworkAssignment =
          assignmentByItemId.containsKey(item.id) && item.phase != 0;
      final include = section == _GradingSection.submitted
          ? hasSubmitted
          : (!hasSubmitted && hasHomeworkAssignment);
      if (!include) continue;

      DateTime? dueDate;
      String titleSnapshot = '';
      for (final assignment in assignmentByItemId[item.id] ?? const []) {
        dueDate = _mergeDueDate(dueDate, _dateOnly(assignment.dueDate));
        if (titleSnapshot.isEmpty) {
          final snapshot = (assignment.groupTitleSnapshot ?? '').trim();
          if (snapshot.isNotEmpty) titleSnapshot = snapshot;
        }
      }
      final displayTitle =
          titleSnapshot.isNotEmpty ? titleSnapshot : item.title.trim();
      out.add(
        _GradingGroupEntry(
          studentId: studentId,
          studentName: studentName,
          group: null,
          summary: item,
          children: <HomeworkItem>[item],
          displayTitle: displayTitle.isEmpty ? '(제목 없음)' : displayTitle,
          dueDate: dueDate,
          submittedTime: _submittedSortTimeOfItem(item),
          homeworkTime: _homeworkSortTimeOfItem(item),
        ),
      );
    }

    return out;
  }

  HomeworkItem _buildGroupSummaryItem({
    required HomeworkGroup group,
    required List<HomeworkItem> children,
    required String titleSnapshot,
  }) {
    final first = children.first;
    final displaySeed = children.firstWhere(
      (child) => (child.bookId ?? '').trim().isNotEmpty,
      orElse: () => first,
    );
    HomeworkItem? runningChild;
    bool hasSubmitted = false;
    bool hasConfirmed = false;
    int maxPhase = 1;
    int totalCount = 0;
    int maxCheckCount = 0;
    int totalAccumulatedMs = 0;
    int totalCycleBaseMs = 0;
    DateTime? latestUpdated;
    DateTime? latestSubmitted;
    DateTime? latestConfirmed;
    DateTime? latestWaiting;
    final pages = <String>[];

    for (final child in children) {
      if (runningChild == null &&
          (child.runStart != null || child.phase == 2)) {
        runningChild = child;
      }
      if (_isSubmittedVisible(child)) hasSubmitted = true;
      if (child.phase == 4) hasConfirmed = true;
      if (child.phase > maxPhase) maxPhase = child.phase;
      final count = child.count ?? 0;
      if (count > 0) totalCount += count;
      if (child.checkCount > maxCheckCount) maxCheckCount = child.checkCount;
      totalAccumulatedMs += child.accumulatedMs;
      totalCycleBaseMs += child.cycleBaseAccumulatedMs;
      final page = (child.page ?? '').trim();
      if (page.isNotEmpty && pages.length < 4) pages.add(page);
      latestUpdated = _latestDate(latestUpdated, child.updatedAt);
      latestSubmitted = _latestDate(latestSubmitted, child.submittedAt);
      latestConfirmed = _latestDate(latestConfirmed, child.confirmedAt);
      latestWaiting = _latestDate(latestWaiting, child.waitingAt);
    }

    final phase = runningChild != null
        ? 2
        : (hasSubmitted ? 3 : (hasConfirmed ? 4 : maxPhase.clamp(1, 4)));
    final title = titleSnapshot.isNotEmpty
        ? titleSnapshot
        : (group.title.trim().isNotEmpty ? group.title.trim() : first.title);
    final pageSummary = () {
      if (pages.isEmpty) return (first.page ?? '').trim();
      if (pages.length <= 3) return pages.join(', ');
      return '${pages.take(3).join(', ')}, ...';
    }();

    return HomeworkItem(
      id: (runningChild ?? first).id,
      title: title.trim().isEmpty ? '(제목 없음)' : title.trim(),
      body: displaySeed.body,
      color: first.color,
      flowId: group.flowId ?? first.flowId,
      type: '${children.length}개 과제',
      page: pageSummary.isEmpty ? null : pageSummary,
      count: totalCount > 0 ? totalCount : first.count,
      memo: displaySeed.memo,
      content: displaySeed.content,
      bookId: displaySeed.bookId,
      gradeLabel: displaySeed.gradeLabel,
      sourceUnitLevel: displaySeed.sourceUnitLevel,
      sourceUnitPath: displaySeed.sourceUnitPath,
      unitMappings: displaySeed.unitMappings,
      defaultSplitParts: displaySeed.defaultSplitParts,
      checkCount: maxCheckCount,
      orderIndex: group.orderIndex,
      createdAt: first.createdAt,
      updatedAt: latestUpdated ?? first.updatedAt,
      status: HomeworkStatus.inProgress,
      phase: phase,
      accumulatedMs: totalAccumulatedMs,
      cycleBaseAccumulatedMs: totalCycleBaseMs,
      runStart: runningChild?.runStart,
      completedAt: null,
      firstStartedAt: group.cycleStartedAt ??
          runningChild?.runStart ??
          first.firstStartedAt,
      submittedAt: latestSubmitted,
      confirmedAt: latestConfirmed,
      waitingAt: latestWaiting,
      version: first.version,
    );
  }

  Future<String?> _resolveCoverPath({
    required String bookId,
    required String gradeLabel,
    String flowId = '',
  }) {
    final cleanedBookId = bookId.trim();
    final cleanedGradeLabel = gradeLabel.trim();
    final cleanedFlowId = flowId.trim();
    if (cleanedBookId.isEmpty && cleanedFlowId.isEmpty) {
      return Future<String?>.value(null);
    }
    final key = '$cleanedBookId|$cleanedGradeLabel|$cleanedFlowId';
    return _coverPathFutureByKey.putIfAbsent(key, () async {
      var resolvedBookId = cleanedBookId;
      var resolvedGradeLabel = cleanedGradeLabel;
      if (resolvedBookId.isEmpty && cleanedFlowId.isNotEmpty) {
        try {
          final rows = await DataManager.instance.loadFlowTextbookLinks(
            cleanedFlowId,
          );
          if (rows.isNotEmpty) {
            Map<String, dynamic>? matched;
            if (resolvedGradeLabel.isNotEmpty) {
              for (final row in rows) {
                final rowGrade = '${row['grade_label'] ?? ''}'.trim();
                if (rowGrade == resolvedGradeLabel) {
                  matched = row;
                  break;
                }
              }
            }
            final selected = matched ?? rows.first;
            resolvedBookId = '${selected['book_id'] ?? ''}'.trim();
            if (resolvedGradeLabel.isEmpty) {
              resolvedGradeLabel = '${selected['grade_label'] ?? ''}'.trim();
            }
          }
        } catch (_) {}
      }
      if (resolvedBookId.isEmpty) return null;
      try {
        final links =
            await DataManager.instance.loadResourceFileLinks(resolvedBookId);
        if (links.isEmpty) return null;
        if (resolvedGradeLabel.isNotEmpty) {
          final byGrade = (links['$resolvedGradeLabel#cover'] ?? '').trim();
          if (byGrade.isNotEmpty) return byGrade;
        }
        for (final e in links.entries) {
          if (!e.key.endsWith('#cover')) continue;
          final v = e.value.trim();
          if (v.isNotEmpty) return v;
        }
      } catch (_) {}
      return null;
    });
  }
}

enum _GradingSection { submitted, homework }

class _GradingGroupEntry {
  final String studentId;
  final String studentName;
  final HomeworkGroup? group;
  final HomeworkItem summary;
  final List<HomeworkItem> children;
  final String displayTitle;
  final DateTime? dueDate;
  final DateTime submittedTime;
  final DateTime homeworkTime;

  const _GradingGroupEntry({
    required this.studentId,
    required this.studentName,
    required this.group,
    required this.summary,
    required this.children,
    required this.displayTitle,
    required this.dueDate,
    required this.submittedTime,
    required this.homeworkTime,
  });

  bool get hasSubmittedChild => children.any(
      (child) => child.phase == 3 && child.status != HomeworkStatus.completed);
}

class _GradingCardLayout {
  final double width;
  final double height;
  final double metaHeight;
  final double spacing;

  const _GradingCardLayout({
    required this.width,
    required this.height,
    required this.metaHeight,
    required this.spacing,
  });
}

class _SubmittedHomeworkCard extends StatelessWidget {
  final _GradingGroupEntry entry;
  final double cardHeight;
  final double metaHeight;
  final Future<String?> coverPathFuture;
  final Future<void> Function()? onTap;
  final bool isPendingConfirm;
  final bool isCompleteCheckbox;

  const _SubmittedHomeworkCard({
    required this.entry,
    required this.cardHeight,
    required this.metaHeight,
    required this.coverPathFuture,
    this.onTap,
    this.isPendingConfirm = false,
    this.isCompleteCheckbox = false,
  });

  @override
  Widget build(BuildContext context) {
    final hw = entry.summary;
    final line2 = entry.displayTitle.trim().isEmpty
        ? '(제목 없음)'
        : entry.displayTitle.trim();
    final bookStr = _extractBookName(hw).isEmpty ? '-' : _extractBookName(hw);
    final courseStr =
        _extractCourseName(hw).isEmpty ? '-' : _extractCourseName(hw);
    final pageStr =
        (hw.page ?? '').trim().isEmpty ? '-' : (hw.page ?? '').trim();
    final countStr = hw.count == null ? '-' : hw.count.toString();
    final scale =
        (cardHeight / _kGradingBaseCardHeight).clamp(0.5, 1.15).toDouble();
    final radius = (14.0 * scale).clamp(10.0, 14.0).toDouble();
    final contentPadH = (16.0 * scale).clamp(8.0, 16.0).toDouble();
    final contentPadTop = (12.0 * scale).clamp(6.0, 12.0).toDouble();
    final contentPadBottom = (14.0 * scale).clamp(7.0, 14.0).toDouble();
    final line4 = _buildLine4MinutesSinceSubmitted(entry);
    final pageLines = _buildOverlayPageLines(entry);
    final childCountText = '하위 ${entry.children.length}개';

    final card = Container(
      decoration: BoxDecoration(
        color: kDlgBg,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withOpacity(0.06), width: 0.8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            blurRadius: (18.0 * scale).clamp(9.0, 18.0).toDouble(),
            offset: Offset(0, (12.0 * scale).clamp(5.0, 12.0).toDouble()),
          ),
          BoxShadow(
            color: Colors.white.withOpacity(0.03),
            blurRadius: (2.0 * scale).clamp(1.0, 2.0).toDouble(),
            offset: Offset(0, (1.0 * scale).clamp(0.6, 1.0).toDouble()),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final coverHeight = (constraints.maxHeight - metaHeight)
                .clamp(0.0, constraints.maxHeight);
            return Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: coverHeight,
                      width: double.infinity,
                      child: _buildCoverArea(
                        scale,
                        line4: line4,
                        pageLines: pageLines,
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          contentPadH,
                          contentPadTop,
                          contentPadH,
                          contentPadBottom,
                        ),
                        child: LayoutBuilder(
                          builder: (context, _) {
                            final metaScale =
                                (metaHeight / _kGradingBaseCardMetaHeight)
                                    .clamp(0.5, 1.2)
                                    .toDouble();
                            final cellFontSize =
                                (14.0 * metaScale).clamp(9.0, 17.0).toDouble();
                            final line1FontSize = (cellFontSize * 2.0)
                                .clamp(18.0, 34.0)
                                .toDouble();
                            final line23FontSize = (cellFontSize * 1.2)
                                .clamp(10.8, 20.4)
                                .toDouble();
                            final line1Text = bookStr == '-' && courseStr == '-'
                                ? '-'
                                : (bookStr != '-' && courseStr != '-'
                                    ? '$bookStr · $courseStr'
                                    : (bookStr != '-' ? bookStr : courseStr));

                            final cellStyle1 = TextStyle(
                              color: kDlgText,
                              fontSize: line1FontSize,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                            );
                            final cellStyle2 = TextStyle(
                              color: kDlgTextSub,
                              fontSize: line23FontSize,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.1,
                            );
                            final cellStyle3 = TextStyle(
                              color: const Color(0xFF7F8C8C),
                              fontSize: line23FontSize,
                              fontWeight: FontWeight.w700,
                            );
                            return SizedBox.expand(
                              child: Column(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    line1Text,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: cellStyle1,
                                  ),
                                  Text(
                                    line2,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: cellStyle2,
                                  ),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          childCountText,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: cellStyle3,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'p.$pageStr · ${countStr}문항',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.right,
                                          style: cellStyle3,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
                if (isPendingConfirm)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        color: const Color(0xCC0B1112),
                        child: Center(
                          child: Icon(
                            isCompleteCheckbox
                                ? Icons.check_circle
                                : Icons.check_circle_outline,
                            color: isCompleteCheckbox
                                ? const Color(0xFF4CAF50)
                                : const Color(0xFF1B6B63),
                            size: (67.0 * scale).clamp(38.0, 67.0),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );

    if (onTap == null) return card;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          unawaited(onTap!());
        },
        child: card,
      ),
    );
  }

  Widget _buildCoverArea(
    double scale, {
    required String line4,
    required List<String> pageLines,
  }) {
    return FutureBuilder<String?>(
      future: coverPathFuture,
      builder: (context, snapshot) {
        final hw = entry.summary;
        final provider = _coverImageProvider(snapshot.data ?? '');
        final hasImage = provider != null;
        final fallbackCoverColor = _coverColorForType(hw);
        final overlayNameSize = (41.0 * scale).clamp(22.0, 41.0).toDouble();
        final overlayHorizontalPad = (14.0 * scale).clamp(8.0, 14.0).toDouble();
        final overlayNameColor =
            !hasImage && fallbackCoverColor.computeLuminance() > 0.6
                ? Colors.black.withOpacity(0.82)
                : Colors.white;
        final overlayTimeGap = (6.0 * scale).clamp(3.0, 6.0).toDouble();
        final overlayTimeSize = (overlayNameSize * 0.7).clamp(10.0, 29.0);
        final overlayTextShadows = <Shadow>[
          Shadow(
            color: Colors.black.withOpacity(0.6),
            blurRadius: (4.0 * scale).clamp(2.0, 4.0).toDouble(),
            offset: Offset(0, (1.0 * scale).clamp(0.5, 1.0).toDouble()),
          ),
        ];
        return Stack(
          fit: StackFit.expand,
          children: [
            Container(
              decoration: BoxDecoration(
                color: hasImage ? const Color(0xFF2B2B2B) : fallbackCoverColor,
                image: provider == null
                    ? null
                    : DecorationImage(
                        image: provider,
                        fit: BoxFit.cover,
                      ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withOpacity(hasImage ? 0.05 : 0.0),
                      Colors.black.withOpacity(hasImage ? 0.22 : 0.12),
                    ],
                  ),
                ),
              ),
            ),
            IgnorePointer(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    overlayHorizontalPad,
                    (12.0 * scale).clamp(6.0, 12.0).toDouble(),
                    overlayHorizontalPad,
                    0,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        entry.studentName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: overlayNameColor,
                          fontSize: overlayNameSize,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.3,
                          shadows: [
                            Shadow(
                              color: hasImage
                                  ? Colors.black87
                                  : Colors.black.withOpacity(0.26),
                              blurRadius:
                                  (8.0 * scale).clamp(4.0, 8.0).toDouble(),
                              offset: Offset(
                                  0, (2.0 * scale).clamp(1.0, 2.0).toDouble()),
                            ),
                          ],
                        ),
                      ),
                      if (line4 != '-') ...[
                        SizedBox(height: overlayTimeGap),
                        Text(
                          line4,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: overlayNameColor,
                            fontSize: overlayTimeSize.toDouble(),
                            fontWeight: FontWeight.w700,
                            shadows: overlayTextShadows,
                          ),
                        ),
                      ],
                      if (pageLines.isNotEmpty) ...[
                        SizedBox(height: overlayTimeGap),
                        for (int i = 0; i < pageLines.length; i++) ...[
                          Text(
                            pageLines[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.left,
                            style: TextStyle(
                              color: overlayNameColor,
                              fontSize: overlayTimeSize.toDouble(),
                              fontWeight: FontWeight.w700,
                              shadows: overlayTextShadows,
                            ),
                          ),
                          if (i != pageLines.length - 1)
                            SizedBox(
                              height:
                                  (overlayTimeGap * 0.58).clamp(2.0, 4.0),
                            ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  String _buildLine4MinutesSinceSubmitted(_GradingGroupEntry entry) {
    if (!entry.hasSubmittedChild) return '-';
    final submitted = entry.submittedTime;
    final totalMinutes = DateTime.now().difference(submitted).inMinutes;
    if (totalMinutes < 0) return '0분';
    if (totalMinutes < 60) return '${totalMinutes}분';
    final hours = totalMinutes ~/ 60;
    final mins = totalMinutes % 60;
    if (mins == 0) return '${hours}시간';
    return '${hours}시간 ${mins}분';
  }

  List<String> _buildOverlayPageLines(_GradingGroupEntry entry) {
    final seen = <String>{};
    final out = <String>[];
    for (final child in entry.children) {
      final raw = (child.page ?? '').trim();
      if (raw.isEmpty) continue;
      final pageLabel = 'p.$raw';
      if (!seen.add(pageLabel)) continue;
      out.add(pageLabel);
    }
    if (out.isEmpty) {
      final fallback = (entry.summary.page ?? '').trim();
      if (fallback.isNotEmpty) {
        out.add('p.$fallback');
      }
    }
    if (out.length <= 4) return out;
    return <String>[...out.take(4), '...'];
  }

  String _extractBookName(HomeworkItem hw) {
    final contentRaw = (hw.content ?? '').trim();
    final fromContent =
        RegExp(r'(?:^|\n)\s*교재:\s*([^\n]+)').firstMatch(contentRaw)?.group(1);
    if (fromContent != null && fromContent.trim().isNotEmpty) {
      return fromContent.trim();
    }

    final hasLinkedTextbook = (hw.bookId ?? '').trim().isNotEmpty &&
        (hw.gradeLabel ?? '').trim().isNotEmpty;
    if (hasLinkedTextbook) {
      final stripped = _stripUnitPrefix(hw.title.trim());
      if (stripped.isNotEmpty) {
        final idx = stripped.indexOf('·');
        if (idx == -1) return stripped;
        final candidate = stripped.substring(0, idx).trim();
        if (candidate.isNotEmpty) return candidate;
      }
    }

    final typeLabel = _normalizedTypeLabel(hw);
    if (typeLabel.isNotEmpty) return typeLabel;
    return '';
  }

  String _extractCourseName(HomeworkItem hw) {
    final contentRaw = (hw.content ?? '').trim();
    final fromContent =
        RegExp(r'(?:^|\n)\s*과정:\s*([^\n]+)').firstMatch(contentRaw)?.group(1);
    return (fromContent ?? '').trim();
  }

  String _stripUnitPrefix(String raw) {
    return raw.replaceFirst(RegExp(r'^\s*\d+\.\d+\.\(\d+\)\s+'), '').trim();
  }

  String _normalizedTypeLabel(HomeworkItem hw) {
    return (hw.type ?? '').trim();
  }

  Color _coverColorForType(HomeworkItem hw) {
    switch (_normalizedTypeLabel(hw)) {
      case '프린트':
        return Colors.white;
      case '교재':
        return const Color(0xFF2E7D32);
      case '문제집':
        return const Color(0xFFF9A825);
      case '학습':
        return const Color(0xFF6A1B9A);
      case '테스트':
        return const Color(0xFFC62828);
      default:
        return const Color(0xFF2B2B2B);
    }
  }

  ImageProvider? _coverImageProvider(String rawPath) {
    final path = rawPath.trim();
    if (path.isEmpty) return null;
    if (_isRemoteUrl(path)) return NetworkImage(path);
    final localPath = _normalizeLocalPath(path);
    if (localPath.isEmpty) return null;
    final file = File(localPath);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  bool _isRemoteUrl(String path) {
    return path.startsWith('http://') || path.startsWith('https://');
  }

  String _normalizeLocalPath(String path) {
    if (!path.startsWith('file://')) return path;
    final uri = Uri.tryParse(path);
    if (uri == null) return path;
    return uri.toFilePath(windows: Platform.isWindows);
  }
}

class _GradingEmptyState extends StatelessWidget {
  const _GradingEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 360,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        decoration: BoxDecoration(
          color: kDlgBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kDlgBorder),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.assignment_turned_in_outlined,
                color: Colors.white24, size: 28),
            SizedBox(height: 10),
            Text(
              '표시할 제출/숙제 과제가 없습니다.',
              style: TextStyle(
                color: kDlgTextSub,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
