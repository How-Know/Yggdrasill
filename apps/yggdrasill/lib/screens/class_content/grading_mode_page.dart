import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../app_overlays.dart';
import '../../services/data_manager.dart';
import '../../services/homework_assignment_store.dart';
import '../../services/homework_store.dart';
import '../../services/right_sheet_answer_preload_service.dart';
import '../../utils/homework_page_text.dart';
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
const EdgeInsets _kGradingPagePadding = EdgeInsets.fromLTRB(24, 0, 24, 24);
const String _kGradingAnswerBookCategory = 'textbook';
const List<String> _kGradingAnswerGradeOrder = [
  '초1',
  '초2',
  '초3',
  '초4',
  '초5',
  '초6',
  '중1',
  '중2',
  '중3',
  '고1',
  '고2',
  '고3',
  'N수',
];

/// 채점 카드 하단: 과제 코드(ABCD1234) 우선, 없으면 순번(orderIndex+1).
String _gradingCardAssignmentNumberLabel(HomeworkItem hw) {
  final raw = (hw.assignmentCode ?? '').trim().toUpperCase();
  if (RegExp(r'^[A-Z]{4}[0-9]{4}$').hasMatch(raw)) {
    return raw;
  }
  return '과제 ${hw.orderIndex + 1}';
}

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
  Future<List<_GradingAnswerBook>>? _answerBooksFuture;
  int _activeAssignmentsRevision = -1;
  String _activeAssignmentsStudentsKey = '';

  @override
  void initState() {
    super.initState();
    _answerBooksFuture = _loadAnswerBooks();
  }

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
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final railWidth = _resolveAnswerRailWidth(constraints);
                    return Padding(
                      padding: _kGradingPagePadding,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: railWidth,
                            child: _buildAnswerBookRail(),
                          ),
                          const SizedBox(width: 22),
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, contentConstraints) {
                                final cardLayout = _resolveCardLayoutHorizontal(
                                  contentConstraints,
                                  MediaQuery.of(context).size.height,
                                );
                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: submittedEntries.isNotEmpty
                                            ? SizedBox(
                                                height: cardLayout.height,
                                                child:
                                                    _buildHorizontalEntryStrip(
                                                  submittedEntries,
                                                  cardLayout: cardLayout,
                                                  onCardTap:
                                                      widget.onSubmittedCardTap,
                                                  canTapEntry: (entry) =>
                                                      entry.hasSubmittedChild,
                                                ),
                                              )
                                            : _buildEmptyRowSpacer(
                                                cardLayout: cardLayout,
                                              ),
                                      ),
                                    ),
                                    const SizedBox(
                                        height: _kGradingSectionGapTop),
                                    const Divider(
                                        height: 1, color: Color(0xFF2A3A3A)),
                                    const SizedBox(
                                        height: _kGradingSectionGapBottom),
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: homeworkEntries.isNotEmpty
                                            ? SizedBox(
                                                height: cardLayout.height,
                                                child:
                                                    _buildHorizontalEntryStrip(
                                                  homeworkEntries,
                                                  cardLayout: cardLayout,
                                                  onCardTap:
                                                      widget.onHomeworkCardTap,
                                                ),
                                              )
                                            : _buildEmptyRowSpacer(
                                                cardLayout: cardLayout,
                                              ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ],
                      ),
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

  double _resolveAnswerRailWidth(BoxConstraints constraints) {
    final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 1200.0;
    if (width < 820) return 168.0;
    return (width * 0.2).clamp(190.0, 280.0).toDouble();
  }

  /// 세로 스크롤 없이, 제출 행·숙제 행에 동일한 카드 높이를 배분한다.
  _GradingCardLayout _resolveCardLayoutHorizontal(
    BoxConstraints constraints,
    double fallbackViewportHeight,
  ) {
    final viewportHeight =
        constraints.maxHeight.isFinite && constraints.maxHeight > 0
            ? constraints.maxHeight
            : fallbackViewportHeight;
    final inner = math.max(_kGradingCardMinHeight, viewportHeight);

    const middleOverhead =
        _kGradingSectionGapTop + 1 + _kGradingSectionGapBottom;
    final rowHeight = ((inner - middleOverhead) / 2)
        .clamp(_kGradingCardMinHeight, _kGradingCardMaxHeight)
        .toDouble();

    final baseByViewport = (viewportHeight * _kGradingCardHeightByViewport)
        .clamp(_kGradingCardMinHeight, _kGradingCardMaxHeight)
        .toDouble();
    return _layoutFromCardHeight(math.min(baseByViewport, rowHeight));
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

  Widget _buildEmptyRowSpacer({
    required _GradingCardLayout cardLayout,
  }) {
    return SizedBox(
      width: double.infinity,
      height: cardLayout.height,
    );
  }

  Widget _buildAnswerBookRail() {
    return FutureBuilder<List<_GradingAnswerBook>>(
      future: _answerBooksFuture,
      builder: (context, snapshot) {
        final books = snapshot.data ?? const <_GradingAnswerBook>[];
        return _GradingAnswerBookRail(
          books: books,
          isLoading: snapshot.connectionState != ConnectionState.done,
          onOpenBook: _openAnswerBook,
        );
      },
    );
  }

  Future<List<_GradingAnswerBook>> _loadAnswerBooks() async {
    try {
      final rows = await DataManager.instance.loadResourceFilesForCategory(
        _kGradingAnswerBookCategory,
      );
      final books = <_GradingAnswerBook>[];
      for (final row in rows) {
        final id = '${row['id'] ?? ''}'.trim();
        if (id.isEmpty) continue;
        final links = await DataManager.instance.loadResourceFileLinks(id);
        final answerLinks = _answerLinksFromResourceLinks(links);
        if (answerLinks.isEmpty) continue;

        final grades = _answerGradesFromLinks(
          answerLinks: answerLinks,
          resourceLinks: links,
        );
        if (grades.isEmpty) continue;

        books.add(
          _GradingAnswerBook(
            id: id,
            name: '${row['name'] ?? row['title'] ?? ''}'.trim(),
            description: '${row['description'] ?? ''}'.trim(),
            grades: grades,
            sortOrder: _intFromRow(row['order_index']) ??
                _intFromRow(row['order']) ??
                _intFromRow(row['sort_order']) ??
                0,
          ),
        );
      }
      books.sort((a, b) {
        final rankCmp = _bookTypeRank(a).compareTo(_bookTypeRank(b));
        if (rankCmp != 0) return rankCmp;
        final orderCmp = a.sortOrder.compareTo(b.sortOrder);
        if (orderCmp != 0) return orderCmp;
        return a.name.compareTo(b.name);
      });
      return books;
    } catch (_) {
      return const <_GradingAnswerBook>[];
    }
  }

  int _bookTypeRank(_GradingAnswerBook book) {
    final haystack =
        '${book.name} ${book.description}'.replaceAll(RegExp(r'\s+'), '');
    if (haystack.contains('개념서') || haystack.contains('개념')) return 0;
    if (haystack.contains('연산서') || haystack.contains('연산')) return 1;
    if (haystack.contains('기본유형서') || haystack.contains('기본유형')) {
      return 2;
    }
    if (haystack.contains('심화문제집') || haystack.contains('심화')) return 3;
    return 4;
  }

  Map<String, String> _answerLinksFromResourceLinks(
    Map<String, String> links,
  ) {
    final out = <String, String>{};
    for (final entry in links.entries) {
      final key = entry.key.trim();
      if (!key.endsWith('#ans')) continue;
      final path = entry.value.trim();
      if (path.isEmpty) continue;
      final gradeKey = key.substring(0, key.length - '#ans'.length).trim();
      if (gradeKey.isEmpty) continue;
      out[gradeKey] = path;
    }
    return out;
  }

  List<_GradingAnswerBookGrade> _answerGradesFromLinks({
    required Map<String, String> answerLinks,
    required Map<String, String> resourceLinks,
  }) {
    final gradeKeys = answerLinks.keys
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    gradeKeys.sort(_compareGradeKeys);
    return <_GradingAnswerBookGrade>[
      for (final gradeKey in gradeKeys)
        if ((answerLinks[gradeKey] ?? '').trim().isNotEmpty)
          _GradingAnswerBookGrade(
            gradeKey: gradeKey,
            gradeLabel: _gradeLabelForKey(gradeKey),
            answerPath: (answerLinks[gradeKey] ?? '').trim(),
            solutionPath: _resolveSolutionPathFromLinks(
              links: resourceLinks,
              gradeKey: gradeKey,
              gradeLabel: _gradeLabelForKey(gradeKey),
            ),
            coverPath: _resolveCoverPathFromLinks(
              links: resourceLinks,
              gradeKey: gradeKey,
              gradeLabel: _gradeLabelForKey(gradeKey),
            ),
          ),
    ];
  }

  int _compareGradeKeys(String a, String b) {
    final ai = _kGradingAnswerGradeOrder.indexOf(a);
    final bi = _kGradingAnswerGradeOrder.indexOf(b);
    if (ai != -1 && bi != -1) return ai.compareTo(bi);
    if (ai != -1) return -1;
    if (bi != -1) return 1;
    return a.compareTo(b);
  }

  String _gradeLabelForKey(String key) {
    final cleaned = key.trim();
    return cleaned.isEmpty ? '과정' : cleaned;
  }

  String _resolveCoverPathFromLinks({
    required Map<String, String> links,
    required String gradeKey,
    required String gradeLabel,
  }) {
    final exact = (links['$gradeLabel#cover'] ??
            links['$gradeKey#cover'] ??
            links['cover'] ??
            links['grade#cover'] ??
            '')
        .trim();
    if (exact.isNotEmpty) return exact;
    for (final entry in links.entries) {
      if (!entry.key.endsWith('#cover')) continue;
      final path = entry.value.trim();
      if (path.isNotEmpty) return path;
    }
    return '';
  }

  String _resolveSolutionPathFromLinks({
    required Map<String, String> links,
    required String gradeKey,
    required String gradeLabel,
  }) {
    return (links['$gradeLabel#sol'] ?? links['$gradeKey#sol'] ?? '').trim();
  }

  int? _intFromRow(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse('${raw ?? ''}'.trim());
  }

  Future<void> _openAnswerBook(
    _GradingAnswerBook book,
    _GradingAnswerBookGrade grade,
  ) async {
    final answerPath = grade.answerPath.trim();
    if (answerPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('연결된 PDF가 없습니다.')),
      );
      return;
    }
    final titleBase = book.name.trim().isEmpty ? '답지 확인' : book.name.trim();
    final title = grade.gradeLabel.trim().isEmpty
        ? titleBase
        : '$titleBase · ${grade.gradeLabel.trim()}';
    final cacheKey =
        'answerkey|$_kGradingAnswerBookCategory|${book.id}|${grade.gradeKey}|$answerPath';
    RightSheetAnswerPreloadService.instance.putPdfLinks(
      cacheKey: cacheKey,
      answerPath: answerPath,
      solutionPath: grade.solutionPath,
    );
    rightSideSheetPdfPanelSession.value = RightSideSheetPdfPanelSession(
      sessionId: 'grading-answer-book:${book.id}:${grade.gradeKey}',
      title: title,
      answerPath: answerPath,
      solutionPath: grade.solutionPath,
      cacheKey: cacheKey,
    );
  }

  Widget _buildHorizontalEntryStrip(
    List<_GradingGroupEntry> entries, {
    required _GradingCardLayout cardLayout,
    GradingGroupTapCallback? onCardTap,
    bool Function(_GradingGroupEntry entry)? canTapEntry,
  }) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      reverse: true,
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: entries.length,
      separatorBuilder: (_, __) => SizedBox(width: cardLayout.spacing),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return SizedBox(
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
                flowId: coverSource.disableFlowFallback
                    ? ''
                    : (entry.summary.flowId ?? '').trim(),
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
        );
      },
    );
  }

  ({String bookId, String gradeLabel, bool disableFlowFallback})
      _resolveEntryCoverSource(
    _GradingGroupEntry entry,
  ) {
    if (_isPrintCoverEntry(entry)) {
      return (bookId: '', gradeLabel: '', disableFlowFallback: true);
    }
    final summaryBookId = (entry.summary.bookId ?? '').trim();
    final summaryGrade = (entry.summary.gradeLabel ?? '').trim();
    if (summaryBookId.isNotEmpty) {
      return (
        bookId: summaryBookId,
        gradeLabel: summaryGrade,
        disableFlowFallback: false,
      );
    }
    for (final child in entry.children) {
      final bookId = (child.bookId ?? '').trim();
      if (bookId.isEmpty) continue;
      return (
        bookId: bookId,
        gradeLabel: (child.gradeLabel ?? '').trim(),
        disableFlowFallback: false,
      );
    }
    return (
      bookId: '',
      gradeLabel: summaryGrade,
      disableFlowFallback: false,
    );
  }

  String _normalizedTypeLabel(HomeworkItem item) {
    return (item.type ?? '').trim();
  }

  bool _isPrintCoverEntry(_GradingGroupEntry entry) {
    const printLikeTypes = <String>{'프린트', '테스트'};
    if (printLikeTypes.contains(_normalizedTypeLabel(entry.summary))) {
      return true;
    }
    var hasTypedChild = false;
    for (final child in entry.children) {
      final type = _normalizedTypeLabel(child);
      if (type.isEmpty) continue;
      hasTypedChild = true;
      if (!printLikeTypes.contains(type)) return false;
    }
    return hasTypedChild;
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
    final normalizedChildTypes = <String>{
      for (final child in children)
        if ((child.type ?? '').trim().isNotEmpty) (child.type ?? '').trim(),
    };
    final summaryType = normalizedChildTypes.length == 1
        ? normalizedChildTypes.first
        : '${children.length}개 과제';

    return HomeworkItem(
      id: (runningChild ?? first).id,
      assignmentCode: (runningChild ?? first).assignmentCode,
      learningTrackCode: group.learningTrackCode,
      title: title.trim().isEmpty ? '(제목 없음)' : title.trim(),
      body: displaySeed.body,
      color: first.color,
      flowId: group.flowId ?? first.flowId,
      testOriginFlowId: displaySeed.testOriginFlowId ?? first.testOriginFlowId,
      type: summaryType,
      page: pageSummary.isEmpty ? null : pageSummary,
      count: totalCount > 0 ? totalCount : first.count,
      timeLimitMinutes: displaySeed.timeLimitMinutes ?? first.timeLimitMinutes,
      memo: displaySeed.memo,
      content: displaySeed.content,
      pbPresetId: displaySeed.pbPresetId ?? first.pbPresetId,
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

class _GradingAnswerBook {
  final String id;
  final String name;
  final String description;
  final List<_GradingAnswerBookGrade> grades;
  final int sortOrder;

  const _GradingAnswerBook({
    required this.id,
    required this.name,
    required this.description,
    required this.grades,
    required this.sortOrder,
  });

  String get displayName => name.trim().isEmpty ? '제목 없음' : name.trim();

  String get displayDescription {
    final cleaned = description.trim();
    return cleaned.isEmpty ? '정답 PDF 바로가기' : cleaned;
  }

  bool get hasGrades => grades.isNotEmpty;
}

class _GradingAnswerBookGrade {
  final String gradeKey;
  final String gradeLabel;
  final String answerPath;
  final String solutionPath;
  final String coverPath;

  const _GradingAnswerBookGrade({
    required this.gradeKey,
    required this.gradeLabel,
    required this.answerPath,
    required this.solutionPath,
    required this.coverPath,
  });

  String get displayLabel {
    final label =
        gradeLabel.trim().isEmpty ? gradeKey.trim() : gradeLabel.trim();
    return label.isEmpty ? '과정' : label;
  }
}

class _GradingAnswerBookRail extends StatefulWidget {
  final List<_GradingAnswerBook> books;
  final bool isLoading;
  final Future<void> Function(
    _GradingAnswerBook book,
    _GradingAnswerBookGrade grade,
  ) onOpenBook;

  const _GradingAnswerBookRail({
    required this.books,
    required this.isLoading,
    required this.onOpenBook,
  });

  @override
  State<_GradingAnswerBookRail> createState() => _GradingAnswerBookRailState();
}

class _GradingAnswerBookRailState extends State<_GradingAnswerBookRail> {
  static const double _bookSwipeDistanceThreshold = 42.0;
  static const double _bookSwipeVelocityThreshold = 260.0;
  static const Duration _revolvingTransitionDuration =
      Duration(milliseconds: 360);
  static const Duration _bookTransitionInputGap = Duration(milliseconds: 180);

  int _selectedIndex = 0;
  double _bookDragDy = 0.0;
  bool _bookDragMovedByDistance = false;
  DateTime _lastBookTransitionAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void didUpdateWidget(covariant _GradingAnswerBookRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.books.length != oldWidget.books.length) {
      _selectedIndex = _selectedIndex.clamp(
        0,
        math.max(0, widget.books.length - 1),
      );
    }
  }

  void _resetBookDrag() {
    _bookDragDy = 0.0;
    _bookDragMovedByDistance = false;
  }

  void _changeBookBy(int delta) {
    final length = widget.books.length;
    if (delta == 0 || length <= 1) return;
    final now = DateTime.now();
    if (now.difference(_lastBookTransitionAt) < _bookTransitionInputGap) {
      return;
    }
    _lastBookTransitionAt = now;
    _bookDragMovedByDistance = true;
    final step = delta.isNegative ? -1 : 1;
    setState(() {
      _selectedIndex = (_selectedIndex + step) % length;
      if (_selectedIndex < 0) _selectedIndex += length;
    });
  }

  void _selectBookIndex(int index) {
    if (index == _selectedIndex) return;
    _lastBookTransitionAt = DateTime.now();
    setState(() => _selectedIndex = index);
  }

  void _handleBookDragStart(DragStartDetails _) {
    _resetBookDrag();
  }

  void _handleBookDragUpdate(DragUpdateDetails d) {
    _bookDragDy += d.delta.dy;
    if (_bookDragDy <= -_bookSwipeDistanceThreshold) {
      final steps = (_bookDragDy.abs() / _bookSwipeDistanceThreshold).floor();
      _bookDragDy += _bookSwipeDistanceThreshold * steps;
      _changeBookBy(steps);
    } else if (_bookDragDy >= _bookSwipeDistanceThreshold) {
      final steps = (_bookDragDy.abs() / _bookSwipeDistanceThreshold).floor();
      _bookDragDy -= _bookSwipeDistanceThreshold * steps;
      _changeBookBy(-steps);
    }
  }

  void _handleBookDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0.0;
    if (!_bookDragMovedByDistance && v.abs() >= _bookSwipeVelocityThreshold) {
      _changeBookBy(v < 0 ? 1 : -1);
    }
    _resetBookDrag();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: widget.isLoading && widget.books.isEmpty
                ? const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : widget.books.isEmpty
                    ? const Center(
                        child: Text(
                          '연결된 정답 PDF가 없습니다.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Color(0xFF7F8C8C),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            height: 1.3,
                          ),
                        ),
                      )
                    : Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerSignal: (signal) {
                          if (signal is PointerScrollEvent) {
                            final dx = signal.scrollDelta.dx;
                            final dy = signal.scrollDelta.dy;
                            if (dy != 0 && dy.abs() > dx.abs()) {
                              _changeBookBy(dy > 0 ? 1 : -1);
                            }
                          }
                        },
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onVerticalDragStart: _handleBookDragStart,
                          onVerticalDragUpdate: _handleBookDragUpdate,
                          onVerticalDragEnd: _handleBookDragEnd,
                          onVerticalDragCancel: _resetBookDrag,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              return _buildRevolvingStack(constraints);
                            },
                          ),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildRevolvingStack(BoxConstraints constraints) {
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    final cardHeight = math.min(width / 0.72, height * 0.72);
    final centerTop = (height - cardHeight) / 2;
    final slotGap = cardHeight * 0.31;
    final visibleSlots = _visibleBookSlots();

    return ClipRect(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final entry in visibleSlots)
            _buildRevolvingSlot(
              slot: entry.slot,
              bookIndex: entry.bookIndex,
              cardHeight: cardHeight,
              top: centerTop + entry.slot * slotGap,
            ),
        ],
      ),
    );
  }

  List<({int slot, int bookIndex})> _visibleBookSlots() {
    final maxRadius = math.min(3, widget.books.length - 1);
    final slots = <({int slot, int bookIndex})>[];
    final seen = <int>{};
    for (var radius = maxRadius; radius >= 1; radius--) {
      final upperIndex = _wrappedBookIndex(_selectedIndex - radius);
      if (seen.add(upperIndex)) {
        slots.add((slot: -radius, bookIndex: upperIndex));
      }
      final lowerIndex = _wrappedBookIndex(_selectedIndex + radius);
      if (seen.add(lowerIndex)) {
        slots.add((slot: radius, bookIndex: lowerIndex));
      }
    }
    slots.add((slot: 0, bookIndex: _selectedIndex));
    return slots;
  }

  Widget _buildRevolvingSlot({
    required int slot,
    required int bookIndex,
    required double cardHeight,
    required double top,
  }) {
    final book = widget.books[bookIndex];
    final distance = slot.abs();
    final isCurrent = slot == 0;
    final scale = isCurrent ? 1.0 : (1.0 - distance * 0.02).clamp(0.94, 0.98);
    final card = _GradingAnswerBookCard(
      key: ValueKey<String>('rail-card:${book.id}'),
      book: book,
      onOpen: widget.onOpenBook,
    );

    return AnimatedPositioned(
      key: ValueKey<String>('rail-slot:${book.id}'),
      duration: _revolvingTransitionDuration,
      curve: Curves.easeInOutCubic,
      left: 0,
      right: 0,
      top: top,
      height: cardHeight,
      child: AnimatedScale(
        duration: _revolvingTransitionDuration,
        curve: Curves.easeInOutCubic,
        scale: scale.toDouble(),
        alignment: Alignment.center,
        child: isCurrent
            ? card
            : MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _selectBookIndex(bookIndex),
                  child: IgnorePointer(child: card),
                ),
              ),
      ),
    );
  }

  int _wrappedBookIndex(int rawIndex) {
    final length = widget.books.length;
    if (length <= 1) return 0;
    var index = rawIndex % length;
    if (index < 0) index += length;
    return index;
  }
}

class _GradingAnswerBookCard extends StatefulWidget {
  final _GradingAnswerBook book;
  final Future<void> Function(
    _GradingAnswerBook book,
    _GradingAnswerBookGrade grade,
  ) onOpen;

  const _GradingAnswerBookCard({
    super.key,
    required this.book,
    required this.onOpen,
  });

  @override
  State<_GradingAnswerBookCard> createState() => _GradingAnswerBookCardState();
}

class _GradingAnswerBookCardState extends State<_GradingAnswerBookCard> {
  static const double _gradeSwipeDistanceThreshold = 30.0;
  static const double _gradeSwipeVelocityThreshold = 240.0;

  int _gradeIndex = 0;
  double _gradeDragDx = 0.0;
  bool _gradeDragMovedByDistance = false;

  _GradingAnswerBookGrade get _grade {
    final grades = widget.book.grades;
    return grades[_gradeIndex.clamp(0, grades.length - 1)];
  }

  @override
  void didUpdateWidget(covariant _GradingAnswerBookCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.book.id != oldWidget.book.id ||
        widget.book.grades.length != oldWidget.book.grades.length) {
      _gradeIndex = _gradeIndex.clamp(
        0,
        math.max(0, widget.book.grades.length - 1),
      );
    }
  }

  void _resetGradeDrag() {
    _gradeDragDx = 0.0;
    _gradeDragMovedByDistance = false;
  }

  void _changeGradeBy(int delta) {
    final length = widget.book.grades.length;
    if (delta == 0 || length <= 1) return;
    _gradeDragMovedByDistance = true;
    setState(() {
      _gradeIndex = (_gradeIndex + delta).clamp(0, length - 1);
    });
  }

  void _handleGradeDragStart(DragStartDetails _) {
    _resetGradeDrag();
  }

  void _handleGradeDragUpdate(DragUpdateDetails d) {
    _gradeDragDx += d.delta.dx;
    if (_gradeDragDx <= -_gradeSwipeDistanceThreshold) {
      final steps = (_gradeDragDx.abs() / _gradeSwipeDistanceThreshold).floor();
      _gradeDragDx += _gradeSwipeDistanceThreshold * steps;
      _changeGradeBy(steps);
    } else if (_gradeDragDx >= _gradeSwipeDistanceThreshold) {
      final steps = (_gradeDragDx.abs() / _gradeSwipeDistanceThreshold).floor();
      _gradeDragDx -= _gradeSwipeDistanceThreshold * steps;
      _changeGradeBy(-steps);
    }
  }

  void _handleGradeDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0.0;
    if (!_gradeDragMovedByDistance && v.abs() >= _gradeSwipeVelocityThreshold) {
      _changeGradeBy(v < 0 ? 1 : -1);
    }
    _resetGradeDrag();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.book.hasGrades) return const SizedBox.shrink();
    final grade = _grade;
    final provider = _gradingAnswerCoverImageProvider(grade.coverPath);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerSignal: (signal) {
          if (signal is PointerScrollEvent) {
            final dx = signal.scrollDelta.dx;
            final dy = signal.scrollDelta.dy;
            if (dx != 0 && dx.abs() >= dy.abs()) {
              _changeGradeBy(dx < 0 ? 1 : -1);
            }
          }
        },
        child: Material(
          color: const Color(0xFF10171A),
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => unawaited(widget.onOpen(widget.book, grade)),
            splashFactory: NoSplash.splashFactory,
            hoverColor: Colors.white.withValues(alpha: 0.04),
            highlightColor: Colors.white.withValues(alpha: 0.05),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: _handleGradeDragStart,
              onHorizontalDragUpdate: _handleGradeDragUpdate,
              onHorizontalDragEnd: _handleGradeDragEnd,
              onHorizontalDragCancel: _resetGradeDrag,
              child: AspectRatio(
                aspectRatio: 0.72,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF223131)),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xFF1D2A2D),
                          image: provider == null
                              ? null
                              : DecorationImage(
                                  image: provider,
                                  fit: BoxFit.cover,
                                ),
                        ),
                        child: provider == null
                            ? const Center(
                                child: Icon(
                                  Icons.auto_stories_outlined,
                                  color: Colors.white30,
                                  size: 52,
                                ),
                              )
                            : null,
                      ),
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withValues(alpha: 0.10),
                                Colors.black.withValues(alpha: 0.12),
                                Colors.black.withValues(alpha: 0.72),
                              ],
                              stops: const [0.0, 0.46, 1.0],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 12,
                        top: 12,
                        child:
                            _GradingAnswerGradeBadge(label: grade.displayLabel),
                      ),
                      Positioned(
                        left: 14,
                        right: 14,
                        bottom: 16,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.book.displayName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.w900,
                                height: 1.05,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              widget.book.displayDescription,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.86),
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                height: 1.18,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GradingAnswerGradeBadge extends StatelessWidget {
  final String label;

  const _GradingAnswerGradeBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xDD0B1112),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Color(0xFFEAF2F2),
          fontSize: 20,
          fontWeight: FontWeight.w900,
          letterSpacing: -0.2,
        ),
      ),
    );
  }
}

ImageProvider? _gradingAnswerCoverImageProvider(String rawPath) {
  final path = rawPath.trim();
  if (path.isEmpty) return null;
  if (path.startsWith('http://') || path.startsWith('https://')) {
    return NetworkImage(path);
  }
  final localPath = _gradingNormalizeLocalPath(path);
  if (localPath.isEmpty) return null;
  final file = File(localPath);
  if (!file.existsSync()) return null;
  return FileImage(file);
}

String _gradingNormalizeLocalPath(String path) {
  if (!path.startsWith('file://')) return path;
  final uri = Uri.tryParse(path);
  if (uri == null) return path;
  return uri.toFilePath(windows: Platform.isWindows);
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
    final assignmentNumText = _gradingCardAssignmentNumberLabel(hw);
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
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.06), width: 0.8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: (18.0 * scale).clamp(9.0, 18.0).toDouble(),
            offset: Offset(0, (12.0 * scale).clamp(5.0, 12.0).toDouble()),
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.03),
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
                        childCountText: childCountText,
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
                                ? (line2.trim().isEmpty ? '-' : line2)
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
                                          assignmentNumText,
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
    required String childCountText,
  }) {
    return FutureBuilder<String?>(
      future: coverPathFuture,
      builder: (context, snapshot) {
        final hw = entry.summary;
        final provider = _coverImageProvider(snapshot.data ?? '');
        final hasImage = provider != null;
        final fallbackCoverColor = _coverColorForType(hw);
        final isPrintCover = _isPrintCoverEntry(entry);
        final useDarkOverlayText = isPrintCover ||
            (!hasImage && fallbackCoverColor.computeLuminance() > 0.6);
        final overlayNameSize = (41.0 * scale).clamp(22.0, 41.0).toDouble();
        final overlayHorizontalPad = (14.0 * scale).clamp(8.0, 14.0).toDouble();
        final overlayNameColor = useDarkOverlayText
            ? Colors.black.withValues(alpha: 0.82)
            : Colors.white;
        final overlayTimeGap = (6.0 * scale).clamp(3.0, 6.0).toDouble();
        final overlayTimeSize = (overlayNameSize * 0.7).clamp(10.0, 29.0);
        final overlayTextShadows = useDarkOverlayText
            ? const <Shadow>[]
            : <Shadow>[
                Shadow(
                  color: Colors.black.withValues(alpha: 0.6),
                  blurRadius: (4.0 * scale).clamp(2.0, 4.0).toDouble(),
                  offset: Offset(0, (1.0 * scale).clamp(0.5, 1.0).toDouble()),
                ),
              ];
        final overlayNameShadows = useDarkOverlayText
            ? const <Shadow>[]
            : <Shadow>[
                Shadow(
                  color: hasImage
                      ? Colors.black87
                      : Colors.black.withValues(alpha: 0.26),
                  blurRadius: (8.0 * scale).clamp(4.0, 8.0).toDouble(),
                  offset: Offset(0, (2.0 * scale).clamp(1.0, 2.0).toDouble()),
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
                      Colors.black.withValues(alpha: hasImage ? 0.05 : 0.0),
                      Colors.black.withValues(alpha: hasImage ? 0.22 : 0.12),
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
                          shadows: overlayNameShadows,
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
                              height: (overlayTimeGap * 0.58).clamp(2.0, 4.0),
                            ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ),
            IgnorePointer(
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    overlayHorizontalPad,
                    0,
                    overlayHorizontalPad,
                    (8.0 * scale).clamp(4.0, 10.0).toDouble(),
                  ),
                  child: Text(
                    childCountText,
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
    if (totalMinutes < 60) return '$totalMinutes분';
    final hours = totalMinutes ~/ 60;
    final mins = totalMinutes % 60;
    if (mins == 0) return '$hours시간';
    return '$hours시간 $mins분';
  }

  List<String> _buildOverlayPageLines(_GradingGroupEntry entry) {
    final lines = <String>[];
    final seenLine = <String>{};
    for (final child in entry.children) {
      final raw = (child.page ?? '').trim();
      if (raw.isEmpty) continue;
      var normalized = raw;
      final parsed = parseHomeworkPageNumbers(raw);
      if (parsed.isNotEmpty) {
        final compressed = compressHomeworkPageNumbers(parsed);
        if (compressed.isNotEmpty) {
          normalized = compressed;
        }
      }
      final line = 'p.$normalized';
      if (seenLine.add(line)) {
        lines.add(line);
      }
    }
    if (lines.isNotEmpty) {
      if (lines.length <= 4) return lines;
      return <String>[...lines.take(4), '...'];
    }
    final fallback = (entry.summary.page ?? '').trim();
    if (fallback.isEmpty) return const <String>[];
    final fp = parseHomeworkPageNumbers(fallback);
    if (fp.isNotEmpty) {
      final c = compressHomeworkPageNumbers(fp);
      if (c.isNotEmpty) {
        return <String>['p.$c'];
      }
    }
    return <String>['p.$fallback'];
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

  bool _isPrintCoverEntry(_GradingGroupEntry entry) {
    const printLikeTypes = <String>{'프린트', '테스트'};
    if (printLikeTypes.contains(_normalizedTypeLabel(entry.summary))) {
      return true;
    }
    var hasTypedChild = false;
    for (final child in entry.children) {
      final type = _normalizedTypeLabel(child);
      if (type.isEmpty) continue;
      hasTypedChild = true;
      if (!printLikeTypes.contains(type)) return false;
    }
    return hasTypedChild;
  }

  Color _coverColorForType(HomeworkItem hw) {
    switch (_normalizedTypeLabel(hw)) {
      case '프린트':
      case '테스트':
        return Colors.white;
      case '교재':
      case '문제집':
        return const Color(0xFF2E7D32);
      case '학습':
        return const Color(0xFF6A1B9A);
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
