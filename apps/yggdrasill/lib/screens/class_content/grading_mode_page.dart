import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../app_overlays.dart';
import '../../services/data_manager.dart';
import '../../services/homework_assignment_store.dart';
import '../../services/homework_departure_draft_service.dart';
import '../../services/homework_batch_confirm_service.dart';
import '../../services/homework_grading_lock_service.dart';
import '../../services/homework_store.dart';
import '../../services/right_sheet_answer_preload_service.dart';
import '../../services/tenant_service.dart';
import '../../services/textbook_download_progress_service.dart';
import '../../services/textbook_pdf_service.dart';
import '../../utils/homework_page_text.dart';
import '../../widgets/app_dialog_action_button.dart';
import '../../widgets/app_snackbar.dart';
import '../../widgets/bottom_dialog.dart';
import '../../widgets/cover_overlay.dart';
import '../../widgets/dialog_tokens.dart';
import '../../widgets/home_grading_edit_icon.dart';
import '../../widgets/home_grading_history_icon.dart';
import '../../widgets/home_header_weather_icon.dart';
import '../../widgets/navigation_rail.dart';
import '../../widgets/resource_textbook_card.dart';
import '../../widgets/solid_capsule_action_bar.dart';
import '../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import 'grading_queue_order.dart';

const double _kGradingBaseCardWidth = 288.0;
const double _kGradingBaseCardMetaHeight = 140.0;
const double _kGradingBaseCardMetaDisplayHeight = 108.0;
const double _kGradingBaseCardHeight =
    _kGradingBaseCardWidth * 1.414 * 0.9 + _kGradingBaseCardMetaHeight;
const double _kGradingWidthScale = 0.9;
const double _kGradingCardAspectRatio =
    (_kGradingBaseCardWidth * _kGradingWidthScale) / _kGradingBaseCardHeight;
const double _kGradingCardMetaRatio =
    _kGradingBaseCardMetaHeight / _kGradingBaseCardHeight;
const double _kGradingCardMetaDisplayRatio =
    _kGradingBaseCardMetaDisplayHeight / _kGradingBaseCardHeight;
const double _kGradingCardHeightByViewport = 0.52;
const double _kGradingCardMinHeight = 140.0;
const double _kGradingCardMaxHeight = 620.0;
const double _kGradingCardMinWidth = 108.0;
const double _kGradingCardMaxWidth = 396.0;
const double _kGradingHomeworkRowTopInset = 24.0;

/// 같은 학생·같은 교재로 세로 스택될 때만 쓰는 카드 간격(리스트 inset과 별개).
const double _kGradingStackedCardGap = 12.0;
const double _kGradingHomeworkCardMetaFontSize = 22.0;
const double _kGradingHomeworkCardMetaLineHeightMax = 0.92;
const double _kGradingHomeworkCardMetaLineHeightMin = 0.72;
const double _kGradingHomeworkCardCoverDetailFontSize = 22.0;
const double _kGradingHomeworkCardCoverDetailLineHeight = 1.1;
const double _kGradingAnswerRailHorizontalPadding = 24.0;
const double _kGradingPageTitleIconSize = 32;

/// 수업 현황 헤더와 같은 시작점. SafeArea 아래 `topInset - 12`.
double _gradingTitleTop(BuildContext context) {
  return MediaQuery.paddingOf(context).top +
      (FabTabBarTokens.previewAcademyTopInset - 12);
}

/// 수업 현황 헤더 줄 높이. 오른쪽 도구 캡슐(세로 패딩 8 + 터치 40)이 56이다.
const double _kGradingHeaderBandHeight = 56;

/// 제목 줄 아래 간격. 카드·정답 리스트 상단이 왼쪽 시트 버튼 아이콘(84)과 맞는다.
const double _kGradingPageTitleGap = 16;

double _gradingCardListTop(BuildContext context) {
  return _gradingTitleTop(context) +
      _kGradingHeaderBandHeight +
      _kGradingPageTitleGap;
}

const String _kGradingAnswerBookCategory = 'textbook';
const List<String> _kGradingAnswerGradeOrder = [
  '\uCD081',
  '\uCD082',
  '\uCD083',
  '\uCD084',
  '\uCD085',
  '\uCD086',
  '\uC9111',
  '\uC9112',
  '\uC9113',
  '\uACE01',
  '\uACE02',
  '\uACE03',
  'N\uC218',
];

/// ?? ?? ???: ?? ??(ABCD1234) ???, ????????(orderIndex+1).
String _gradingCardAssignmentNumberLabel(HomeworkItem hw) {
  final raw = (hw.assignmentCode ?? '').trim().toUpperCase();
  if (RegExp(r'^[A-Z]{4}[0-9]{4}$').hasMatch(raw)) {
    return raw;
  }
  return '\uACFC\uC81C ${hw.orderIndex + 1}';
}

({String line1, String line2}) _splitGradingCardTitleLines(
  String text, {
  required double maxWidth,
  required TextStyle style,
}) {
  final normalized = text.trim();
  if (normalized.isEmpty) {
    return (line1: '', line2: '');
  }

  bool fitsOneLine(String candidate) {
    final painter = TextPainter(
      text: TextSpan(text: candidate, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: maxWidth);
    return !painter.didExceedMaxLines && painter.width <= maxWidth + 0.5;
  }

  if (fitsOneLine(normalized)) {
    return (line1: normalized, line2: '');
  }

  var breakAt = 1;
  var low = 1;
  var high = normalized.length;
  while (low <= high) {
    final mid = (low + high) >> 1;
    final prefix = normalized.substring(0, mid);
    if (fitsOneLine(prefix)) {
      breakAt = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }

  final spaceIdx = normalized.lastIndexOf(' ', breakAt);
  if (spaceIdx > 0) {
    breakAt = spaceIdx;
  }

  final first = normalized.substring(0, breakAt).trimRight();
  final second = normalized.substring(breakAt).trimLeft();
  if (second.isEmpty) {
    return (line1: normalized, line2: '');
  }
  return (line1: first, line2: second);
}

typedef GradingGroupTapCallback = Future<void> Function(
  String studentId,
  HomeworkGroup? group,
  HomeworkItem summary,
  List<HomeworkItem> children, {
  AsyncUiAction? openNext,
});

class GradingModePage extends StatefulWidget {
  final List<String> attendingStudentIds;
  final Map<String, String> studentNamesById;
  final Map<String, DateTime> arrivalTimesByStudentId;
  final GradingGroupTapCallback? onSubmittedCardTap;
  final GradingGroupTapCallback? onHomeworkCardTap;
  final Map<({String studentId, String itemId}), bool> pendingConfirms;
  final Set<({String studentId, String itemId})> savingConfirms;
  final void Function(String studentId, String itemId)? onTogglePending;
  final String headerDateText;
  final String headerTimeText;
  final bool showAnchorDateHint;

  const GradingModePage({
    super.key,
    required this.attendingStudentIds,
    required this.studentNamesById,
    required this.arrivalTimesByStudentId,
    required this.headerDateText,
    required this.headerTimeText,
    this.showAnchorDateHint = false,
    this.onSubmittedCardTap,
    this.onHomeworkCardTap,
    this.pendingConfirms = const <({String studentId, String itemId}), bool>{},
    this.savingConfirms = const <({String studentId, String itemId})>{},
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
  Map<String, List<HomeworkAssignmentDetail>> _lastActiveAssignmentsByStudent =
      const <String, List<HomeworkAssignmentDetail>>{};
  final Map<String, DateTime> _retainedQueueTimeByEntry = <String, DateTime>{};
  bool _clearingVisibleHomework = false;

  @override
  void initState() {
    super.initState();
    _answerBooksFuture = _loadAnswerBooks();
  }

  @override
  void didUpdateWidget(covariant GradingModePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.headerDateText != widget.headerDateText) {
      _retainedQueueTimeByEntry.clear();
      _lastActiveAssignmentsByStudent =
          const <String, List<HomeworkAssignmentDetail>>{};
      return;
    }
    final attendingNow = widget.attendingStudentIds.toSet();
    final departedStudentIds = oldWidget.attendingStudentIds
        .where((studentId) => !attendingNow.contains(studentId))
        .toSet();
    if (departedStudentIds.isEmpty) return;
    _retainedQueueTimeByEntry.removeWhere(
      (key, _) => departedStudentIds.any((id) => key.startsWith('$id|')),
    );
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
                if (assignmentSnapshot.hasData) {
                  _lastActiveAssignmentsByStudent = assignmentSnapshot.data!;
                }
                final activeAssignmentsByStudent =
                    assignmentSnapshot.data ?? _lastActiveAssignmentsByStudent;
                final submittedEntries =
                    _buildSubmittedEntries(activeAssignmentsByStudent);
                final homeworkEntries = _buildHomeworkEntries(
                  activeAssignmentsByStudent,
                );
                final entryStacks = _buildEntryStacks(
                  submittedEntries: submittedEntries,
                  homeworkEntries: homeworkEntries,
                );
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final railWidth = _resolveAnswerRailWidth(context);
                    final titleTop = _gradingTitleTop(context);
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            0,
                            _gradingCardListTop(context),
                            24,
                            24,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(width: railWidth + 22),
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, contentConstraints) {
                                    final cardLayout =
                                        _resolveCardLayoutHorizontal(
                                      contentConstraints,
                                      MediaQuery.of(context).size.height,
                                    );
                                    return Align(
                                      alignment: Alignment.topLeft,
                                      child: entryStacks.isEmpty
                                          ? _buildEmptyRowSpacer(
                                              cardLayout: cardLayout,
                                            )
                                          : _buildStackedEntryStrip(
                                              entryStacks,
                                              cardLayout: cardLayout,
                                            ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                        Positioned(
                          top: titleTop,
                          left: 0,
                          right: 24,
                          height: _kGradingHeaderBandHeight,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: railWidth,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 24),
                                  child: Row(
                                    children: [
                                      SvgPicture.string(
                                        homeGradingEditOutlineSvg,
                                        width: _kGradingPageTitleIconSize,
                                        height: _kGradingPageTitleIconSize,
                                        colorFilter: ColorFilter.mode(
                                          FabTabBarTokens
                                              .previewAcademyPanelStyleFor(
                                            Theme.of(context).brightness,
                                          ).title,
                                          BlendMode.srcIn,
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      const FabStyleScreenMainTitle(
                                        title: '채점',
                                        overlay: true,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 22),
                              Expanded(
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _buildGradingStatusLine(),
                                      const SizedBox(width: 12),
                                      SolidCapsuleActionBar(
                                        children: [
                                          SolidCapsuleActionButton(
                                            tooltip: '이전 채점',
                                            iconBuilder: (color, size) =>
                                                SvgPicture.string(
                                              homeGradingHistorySvg,
                                              width: size,
                                              height: size,
                                              colorFilter: ColorFilter.mode(
                                                color,
                                                BlendMode.srcIn,
                                              ),
                                            ),
                                            onPressed: () {
                                              final action =
                                                  homeGradingHistoryAction;
                                              if (action != null) {
                                                unawaited(action());
                                              }
                                            },
                                          ),
                                          SolidCapsuleActionButton(
                                            tooltip: homeworkEntries.isEmpty
                                                ? '정리할 숙제가 없습니다'
                                                : '숙제 정리',
                                            icon: Icons
                                                .cleaning_services_outlined,
                                            onPressed:
                                                homeworkEntries.isEmpty ||
                                                        _clearingVisibleHomework
                                                    ? null
                                                    : () => unawaited(
                                                          _confirmClearVisibleHomework(
                                                            homeworkEntries,
                                                          ),
                                                        ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Positioned(
                          left: 0,
                          top: _gradingCardListTop(context),
                          bottom: FabTabBarTokens.fabBarBottomInset,
                          width: railWidth,
                          child: _buildAnswerBookRail(),
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

  /// 왼쪽 시트 개폐로 부모 폭이 변해도 레일/책카드가 리플로우되지 않도록
  /// 화면 폭(네비 레일 제외) 기준으로 고정한다.
  /// 248~280(화면의 20%)에 1.1을 곱한 값. 책 카드는 레일 안쪽을 채운다.
  double _resolveAnswerRailWidth(BuildContext context) {
    const scale = 1.1;
    const minWidth = 248.0 * scale;
    const maxWidth = 280.0 * scale;
    final width =
        (MediaQuery.sizeOf(context).width - navRailMinWidth).clamp(0.0, 4000.0);
    if (width < 820) return minWidth;
    return (width * 0.2 * scale).clamp(minWidth, maxWidth).toDouble();
  }

  /// ??? ?????? ??? ???(???)????(???) ???? ??????????.
  _GradingCardLayout _resolveCardLayoutHorizontal(
    BoxConstraints constraints,
    double fallbackViewportHeight,
  ) {
    final viewportHeight =
        constraints.maxHeight.isFinite && constraints.maxHeight > 0
            ? constraints.maxHeight
            : fallbackViewportHeight;
    final inner = math.max(
      _kGradingCardMinHeight * 2 + _kGradingHomeworkRowTopInset,
      viewportHeight,
    );

    final rowHeight = ((inner - _kGradingHomeworkRowTopInset) / 2)
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
    final minMetaDisplayHeight = math.min(
      72.0,
      metaHeight *
          (_kGradingBaseCardMetaDisplayHeight / _kGradingBaseCardMetaHeight),
    );
    final metaDisplayHeight = (height * _kGradingCardMetaDisplayRatio)
        .clamp(minMetaDisplayHeight, metaHeight)
        .toDouble();
    return _GradingCardLayout(
      width: width,
      height: height,
      metaHeight: metaHeight,
      metaDisplayHeight: metaDisplayHeight,
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

  Widget _buildGradingStatusLine() {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final dateStyle = FabTabBarTokens.previewAcademyMainTitleStyle(panelStyle);
    const textHeightBehavior = TextHeightBehavior(
      applyHeightToFirstAscent: false,
      applyHeightToLastDescent: false,
    );

    return FabStyleGlassPanel(
      useTopButtonCapsuleBackground: brightness == Brightness.light,
      useFabTabBarBackground: brightness == Brightness.dark,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          HomeHeaderWeatherIcon(
            iconSize: 40,
            color: panelStyle.icon,
          ),
          const SizedBox(width: 18),
          Text(
            widget.headerTimeText,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: dateStyle,
            textHeightBehavior: textHeightBehavior,
          ),
          const SizedBox(width: 12),
          Text(
            widget.headerDateText,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: dateStyle,
            textHeightBehavior: textHeightBehavior,
          ),
          if (widget.showAnchorDateHint) ...[
            const SizedBox(width: 12),
            Text(
              '슬라이드시트 기준일',
              maxLines: 1,
              style: FabTabBarTokens.previewAcademyValueStyle(panelStyle)
                  .copyWith(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmClearVisibleHomework(
    List<_GradingGroupEntry> entries,
  ) async {
    if (entries.isEmpty || _clearingVisibleHomework || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierLabel: '숙제 정리',
      barrierColor: Colors.black.withValues(
        alpha: BottomDialogMetrics.barrierOpacity,
      ),
      builder: (dialogContext) {
        return BottomDialog(
          icon: Icons.cleaning_services_outlined,
          title: '숙제 정리',
          shrinkWrap: true,
          onClose: () => Navigator.of(dialogContext).pop(false),
          footer: Row(
            children: [
              AppDialogCloseButton(
                label: '취소',
                onPressed: () => Navigator.of(dialogContext).pop(false),
              ),
              const Spacer(),
              AppDialogConfirmButton(
                label: '정리',
                showIcon: false,
                onPressed: () => Navigator.of(dialogContext).pop(true),
              ),
            ],
          ),
          child: BottomDialogPrompt(
            large:
                '지금 보이는 숙제 ${entries.length}개를 모두 숙제 안 함으로 처리합니다.',
            medium: '0%로 기록되고 오늘 과제로 전환됩니다.',
          ),
        );
      },
    );
    if (confirmed != true || !mounted) return;
    await _markVisibleHomeworkNotDone(entries);
  }

  Future<void> _markVisibleHomeworkNotDone(
    List<_GradingGroupEntry> entries,
  ) async {
    if (_clearingVisibleHomework) return;
    setState(() => _clearingVisibleHomework = true);
    var done = 0;
    var failed = 0;
    try {
      for (final entry in entries) {
        final activeChildren = entry.children
            .where((item) => item.status != HomeworkStatus.completed)
            .toList(growable: false);
        if (activeChildren.isEmpty) continue;
        final groupId = (entry.group?.id ??
                HomeworkStore.instance.groupIdOfItem(activeChildren.first.id) ??
                '')
            .trim();
        if (groupId.isEmpty) {
          failed++;
          continue;
        }
        final result =
            await HomeworkAssignmentStore.instance.recordGroupOutcome(
          studentId: entry.studentId,
          groupId: groupId,
          homeworkItemIds: activeChildren.map((item) => item.id),
          outcome: HomeworkAssignmentOutcome.notDone,
        );
        if (!mounted) return;
        if (result == null) {
          failed++;
          continue;
        }
        for (final item in activeChildren) {
          item.status = result.returnedToClass
              ? HomeworkStatus.inProgress
              : HomeworkStatus.homework;
          item.phase = 1;
          item.runStart = null;
        }
        final attendanceId = result.attendanceId;
        if (attendanceId != null) {
          HomeworkDepartureDraftService.instance.invalidate(attendanceId);
        }
        done++;
      }
      HomeworkStore.instance.bumpRevision();
    } finally {
      if (mounted) setState(() => _clearingVisibleHomework = false);
    }
    if (!mounted) return;
    showAppSnackBar(
      context,
      failed == 0
          ? '숙제 $done개를 안 함으로 처리했습니다.'
          : '숙제 $done개를 처리했고 $failed개는 실패했습니다.',
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
    if (haystack.contains('\uAC1C\uB150') || haystack.contains('\uAE30\uBCF8'))
      return 0;
    if (haystack.contains('\uC720\uD615') || haystack.contains('\uC751\uC6A9'))
      return 1;
    if (haystack.contains('\uC2EC\uD654') ||
        haystack.contains('\uCD5C\uC0C1\uC704')) {
      return 2;
    }
    if (haystack.contains('\uC2E4\uC804') || haystack.contains('\uAE30\uCD9C'))
      return 3;
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

  Map<String, String> _solutionLinksFromResourceLinks(
    Map<String, String> links,
  ) {
    final out = <String, String>{};
    for (final entry in links.entries) {
      final key = entry.key.trim();
      if (!key.endsWith('#sol')) continue;
      final path = entry.value.trim();
      if (path.isEmpty) continue;
      final gradeKey = key.substring(0, key.length - '#sol'.length).trim();
      if (gradeKey.isEmpty) continue;
      out[gradeKey] = path;
    }
    return out;
  }

  bool _isMigratedTextbookStoragePath(String raw) {
    return raw.trim().startsWith('storage://textbook/');
  }

  List<_GradingAnswerBookGrade> _answerGradesFromLinks({
    required Map<String, String> answerLinks,
    required Map<String, String> resourceLinks,
  }) {
    final solutionLinks = _solutionLinksFromResourceLinks(resourceLinks);
    final gradeKeys = <String>{
      ...answerLinks.keys.map((e) => e.trim()).where((e) => e.isNotEmpty),
      // 마이그레이션된 교재는 정답 파일이 없어도 서버 해설 파일로
      // 정답 바로가기를 제공한다. legacy URL에는 이 폴백을 적용하지 않는다.
      for (final entry in solutionLinks.entries)
        if (_isMigratedTextbookStoragePath(entry.value)) entry.key.trim(),
    }.where((e) => e.isNotEmpty).toList();
    gradeKeys.sort(_compareGradeKeys);
    return <_GradingAnswerBookGrade>[
      for (final gradeKey in gradeKeys)
        if ((answerLinks[gradeKey] ?? '').trim().isNotEmpty ||
            _isMigratedTextbookStoragePath(solutionLinks[gradeKey] ?? ''))
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
    return cleaned.isEmpty ? '\uACFC\uC815' : cleaned;
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

  String? _storageKeyFromTextbookPath(String raw) {
    const prefix = 'storage://textbook/';
    final path = raw.trim();
    if (!path.startsWith(prefix)) return null;
    final key = path.substring(prefix.length).trim();
    return key.isEmpty ? null : key;
  }

  Future<String> _resolveAnswerBookPdfPath({
    required String bookId,
    required String gradeLabel,
    required String kind,
    required String rawPath,
  }) async {
    final normalizedKind = kind.trim().toLowerCase() == 'sol' ? 'sol' : 'ans';
    final raw = rawPath.trim();
    if (raw.isEmpty) return '';
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return raw;
    }
    try {
      final source = await TextbookPdfService.instance.resolve(
        TextbookPdfRef(
          fileId: bookId,
          gradeLabel: gradeLabel,
          kind: normalizedKind,
          storageKey: _storageKeyFromTextbookPath(raw),
        ),
      );
      final resolved = (source.localPath ?? source.url ?? '').trim();
      if (resolved.isNotEmpty) return resolved;
    } catch (_) {
      // fall through to raw path for legacy Dropbox URLs
    }
    if (raw.startsWith('storage://')) return '';
    return raw;
  }

  bool _isRemoteWebPdfPath(String raw) {
    final path = raw.trim().toLowerCase();
    return path.startsWith('http://') || path.startsWith('https://');
  }

  Future<TextbookPdfRef?> _answerBookPdfRef({
    required String academyId,
    required _GradingAnswerBook book,
    required String gradeLabel,
    required String kind,
    required String rawPath,
  }) async {
    final storageKey = _storageKeyFromTextbookPath(rawPath);
    if (storageKey == null) return null;
    final label = kind == 'sol' ? '해설' : '정답';
    return TextbookPdfRef(
      academyId: academyId,
      fileId: book.id,
      gradeLabel: gradeLabel,
      kind: kind,
      storageKey: storageKey,
      displayName: '${book.displayName} · $label',
    );
  }

  Future<bool> _enqueueAnswerBookPdfIfMissing({
    required TextbookPdfRef ref,
    required String title,
    VoidCallback? onCompleted,
  }) async {
    final cached = await TextbookPdfService.instance.isCached(ref);
    if (cached) return false;
    await TextbookDownloadProgressService.instance.enqueue(
      ref: ref,
      title: title,
      onCompleted: onCompleted,
    );
    return true;
  }

  /// 해설은 오픈을 막지 않고 우하단 안내창으로만 데운다.
  Future<void> _warmAnswerBookSolutionDownload({
    required String academyId,
    required _GradingAnswerBook book,
    required String gradeLabel,
    required String solutionPathRaw,
  }) async {
    final ref = await _answerBookPdfRef(
      academyId: academyId,
      book: book,
      gradeLabel: gradeLabel,
      kind: 'sol',
      rawPath: solutionPathRaw,
    );
    if (ref == null) return;
    await _enqueueAnswerBookPdfIfMissing(
      ref: ref,
      title: '${book.displayName} · $gradeLabel · 해설',
    );
  }

  Future<void> _openAnswerBook(
    _GradingAnswerBook book,
    _GradingAnswerBookGrade grade,
  ) async {
    final answerPathRaw = grade.answerPath.trim();
    final solutionPathRaw = grade.solutionPath.trim();
    if (answerPathRaw.isEmpty && solutionPathRaw.isEmpty) {
      showAppSnackBar(context, '정답 또는 해설 PDF가 없습니다.');
      return;
    }
    final gradeLabel = grade.gradeLabel.trim().isNotEmpty
        ? grade.gradeLabel.trim()
        : grade.gradeKey.trim();
    final academyId =
        (await TenantService.instance.getActiveAcademyId())?.trim() ?? '';
    if (!mounted) return;

    // 정답이 있으면 정답만 게이트로 쓰고, 해설은 백그라운드 다운로드만 한다.
    // (이전에는 둘 다 끝나야 열려서, 해설이 길면 정답이 준비돼도 재시도가 막혔다.)
    final primaryIsAnswer = answerPathRaw.isNotEmpty;
    final primaryRaw = primaryIsAnswer ? answerPathRaw : solutionPathRaw;
    final primaryKind = primaryIsAnswer ? 'ans' : 'sol';
    final primaryLabel = primaryIsAnswer ? '정답' : '해설';

    if (academyId.isNotEmpty &&
        primaryIsAnswer &&
        solutionPathRaw.isNotEmpty &&
        !_isRemoteWebPdfPath(solutionPathRaw)) {
      unawaited(
        _warmAnswerBookSolutionDownload(
          academyId: academyId,
          book: book,
          gradeLabel: gradeLabel,
          solutionPathRaw: solutionPathRaw,
        ),
      );
    }

    if (academyId.isNotEmpty && !_isRemoteWebPdfPath(primaryRaw)) {
      final primaryRef = await _answerBookPdfRef(
        academyId: academyId,
        book: book,
        gradeLabel: gradeLabel,
        kind: primaryKind,
        rawPath: primaryRaw,
      );
      if (primaryRef != null) {
        final downloadStarted = await _enqueueAnswerBookPdfIfMissing(
          ref: primaryRef,
          title: '${book.displayName} · $gradeLabel · $primaryLabel',
          onCompleted: () {
            if (!mounted) return;
            unawaited(_openAnswerBook(book, grade));
          },
        );
        if (!mounted || downloadStarted) return;
      }
    }

    // 기본 문서는 정답. 해설은 이미 캐시된 경우에만 같이 넣고, 아니면 빈 채로 연다.
    var answerPath = '';
    var solutionPath = '';
    if (primaryIsAnswer) {
      answerPath = await _resolveAnswerBookPdfPath(
        bookId: book.id,
        gradeLabel: gradeLabel,
        kind: 'ans',
        rawPath: answerPathRaw,
      );
      if (solutionPathRaw.isNotEmpty) {
        final solRef = academyId.isEmpty
            ? null
            : await _answerBookPdfRef(
                academyId: academyId,
                book: book,
                gradeLabel: gradeLabel,
                kind: 'sol',
                rawPath: solutionPathRaw,
              );
        final solReady = _isRemoteWebPdfPath(solutionPathRaw) ||
            (solRef != null &&
                await TextbookPdfService.instance.isCached(solRef));
        if (solReady) {
          solutionPath = await _resolveAnswerBookPdfPath(
            bookId: book.id,
            gradeLabel: gradeLabel,
            kind: 'sol',
            rawPath: solutionPathRaw,
          );
        }
      }
    } else {
      answerPath = await _resolveAnswerBookPdfPath(
        bookId: book.id,
        gradeLabel: gradeLabel,
        kind: 'sol',
        rawPath: solutionPathRaw,
      );
    }
    if (!mounted) return;
    if (answerPath.isEmpty) {
      showAppSnackBar(context, '정답 또는 해설 PDF를 열 수 없습니다.');
      return;
    }
    final titleBase = book.name.trim().isEmpty
        ? '\uC815\uB2F5 \uBC14\uB85C\uAC00\uAE30'
        : book.name.trim();
    final title = gradeLabel.isEmpty ? titleBase : '$titleBase · $gradeLabel';
    final cacheKey =
        'answerkey|$_kGradingAnswerBookCategory|${book.id}|${grade.gradeKey}|$answerPath';
    RightSheetAnswerPreloadService.instance.putPdfLinks(
      cacheKey: cacheKey,
      answerPath: answerPath,
      solutionPath: solutionPath,
    );
    rightSideSheetPdfPanelSession.value = RightSideSheetPdfPanelSession(
      sessionId: 'grading-answer-book:${book.id}:${grade.gradeKey}',
      title: title,
      answerPath: answerPath,
      solutionPath: solutionPath,
      cacheKey: cacheKey,
    );

    // 해설이 나중에 끝나면 열린 패널에 경로만 보강한다.
    if (primaryIsAnswer &&
        solutionPath.isEmpty &&
        solutionPathRaw.isNotEmpty &&
        academyId.isNotEmpty) {
      final solRef = await _answerBookPdfRef(
        academyId: academyId,
        book: book,
        gradeLabel: gradeLabel,
        kind: 'sol',
        rawPath: solutionPathRaw,
      );
      if (solRef != null) {
        unawaited(
          _enqueueAnswerBookPdfIfMissing(
            ref: solRef,
            title: '${book.displayName} · $gradeLabel · 해설',
            onCompleted: () async {
              if (!mounted) return;
              final warmed = await _resolveAnswerBookPdfPath(
                bookId: book.id,
                gradeLabel: gradeLabel,
                kind: 'sol',
                rawPath: solutionPathRaw,
              );
              if (!mounted || warmed.isEmpty) return;
              final current = rightSideSheetPdfPanelSession.value;
              if (current == null ||
                  current.sessionId !=
                      'grading-answer-book:${book.id}:${grade.gradeKey}') {
                return;
              }
              if (current.solutionPath.trim().isNotEmpty) return;
              RightSheetAnswerPreloadService.instance.putPdfLinks(
                cacheKey: cacheKey,
                answerPath: current.answerPath,
                solutionPath: warmed,
              );
              rightSideSheetPdfPanelSession.value =
                  current.copyWith(solutionPath: warmed);
            },
          ),
        );
      }
    }
  }

  Widget _buildStackedEntryStrip(
    List<_GradingEntryStack> stacks, {
    required _GradingCardLayout cardLayout,
  }) {
    // 카드가 적을 때도 오른쪽에 붙인다. 가로 ListView는 영역 밖 카드를
    // 통째로 지워서, 화면 왼쪽 끝에서 잘린 네모 대신 빈칸이 됐다.
    // 한 줄로 전부 두고, 화면 왼쪽 끝의 클립만 네모를 자르게 한다.
    // SingleChildScrollView는 제약이 느슨하면 내용 너비로 줄어든다.
    // 그러면 부모 Align(topLeft)에 붙어 왼쪽 정렬이 되므로, 가로를 꽉 채워
    // reverse가 오른쪽 끝을 기준으로 왼쪽으로 쌓이게 한다.
    final columns = <Widget>[];
    for (var index = stacks.length - 1; index >= 0; index--) {
      if (columns.isNotEmpty) {
        columns.add(SizedBox(width: cardLayout.spacing));
      }
      columns.add(
        _buildEntryStackColumn(
          stacks[index],
          index: index,
          cardLayout: cardLayout,
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        return SizedBox(
          width: constraints.maxWidth,
          child: ScrollConfiguration(
            behavior:
                ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              clipBehavior: Clip.none,
              physics: const BouncingScrollPhysics(),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: columns,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEntryStackColumn(
    _GradingEntryStack stack, {
    required int index,
    required _GradingCardLayout cardLayout,
  }) {
    AsyncUiAction? buildOpenNext(int currentIndex) {
      final nextIndex = currentIndex + 1;
      if (nextIndex >= stack.entries.length) return null;
      final nextEntry = stack.entries[nextIndex];
      final nextOnCardTap = nextEntry.section == _GradingSection.submitted
          ? widget.onSubmittedCardTap
          : widget.onHomeworkCardTap;
      if (nextOnCardTap == null ||
          (nextEntry.section == _GradingSection.submitted &&
              !nextEntry.hasSubmittedChild)) {
        return null;
      }
      return () => nextOnCardTap(
            nextEntry.studentId,
            nextEntry.group,
            nextEntry.summary,
            nextEntry.children,
            openNext: buildOpenNext(nextIndex),
          );
    }

    return SizedBox(
      key: ValueKey(
        stack.entries.isEmpty
            ? 'grading-stack:$index'
            : _entryStackKey(stack.entries.first),
      ),
      width: cardLayout.width,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: ListView.separated(
          padding: EdgeInsets.zero,
          physics: const BouncingScrollPhysics(),
          clipBehavior: Clip.none,
          itemCount: stack.entries.length,
          separatorBuilder: (_, __) =>
              const SizedBox(height: _kGradingStackedCardGap),
          itemBuilder: (context, stackIndex) {
            final entry = stack.entries[stackIndex];
            final onCardTap = entry.section == _GradingSection.submitted
                ? widget.onSubmittedCardTap
                : widget.onHomeworkCardTap;
            final openNext = buildOpenNext(stackIndex);
            return SizedBox(
              width: cardLayout.width,
              height: cardLayout.height,
              child: _SubmittedHomeworkCard(
                entry: entry,
                cardHeight: cardLayout.height,
                metaHeight: cardLayout.metaHeight,
                metaDisplayHeight: cardLayout.metaDisplayHeight,
                isPendingConfirm: _isEntryPending(entry),
                isCompleteCheckbox: _isEntryPendingComplete(entry),
                isSavingConfirm: _isEntrySaving(entry),
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
                        if (entry.section == _GradingSection.submitted &&
                            !entry.hasSubmittedChild) {
                          return;
                        }
                        await onCardTap(
                          entry.studentId,
                          entry.group,
                          entry.summary,
                          entry.children,
                          openNext: openNext,
                        );
                      },
              ),
            );
          },
        ),
      ),
    );
  }

  List<_GradingEntryStack> _buildEntryStacks({
    required List<_GradingGroupEntry> submittedEntries,
    required List<_GradingGroupEntry> homeworkEntries,
  }) {
    final all = <_GradingGroupEntry>[
      ...submittedEntries,
      ...homeworkEntries,
    ];
    final grouped = <String, List<_GradingGroupEntry>>{};
    for (final entry in all) {
      grouped.putIfAbsent(_entryStackKey(entry), () => []).add(entry);
    }
    final stacks = <_GradingEntryStack>[];
    for (final entries in grouped.values) {
      final sorted = List<_GradingGroupEntry>.from(entries)
        ..sort(_compareEntriesWithinStack);
      stacks.add(_GradingEntryStack(entries: List.unmodifiable(sorted)));
    }
    // reverse ListView 기준: 오래된 스택이 index 0(오른쪽).
    stacks.sort(_compareStacksOldestFirst);
    return stacks;
  }

  /// 가로 reverse 리스트용: 오래된 스택이 앞(오른쪽), 최신이 뒤(왼쪽).
  int _compareStacksOldestFirst(
    _GradingEntryStack a,
    _GradingEntryStack b,
  ) {
    final timeCmp = _stackSortTime(a).compareTo(_stackSortTime(b));
    if (timeCmp != 0) return timeCmp;
    final aName = a.entries.isEmpty ? '' : a.entries.first.studentName;
    final bName = b.entries.isEmpty ? '' : b.entries.first.studentName;
    final nameCmp = aName.compareTo(bName);
    if (nameCmp != 0) return nameCmp;
    final aId = a.entries.isEmpty ? '' : a.entries.first.summary.id;
    final bId = b.entries.isEmpty ? '' : b.entries.first.summary.id;
    return aId.compareTo(bId);
  }

  DateTime _stackSortTime(_GradingEntryStack stack) {
    DateTime? latest;
    for (final entry in stack.entries) {
      final time = _entrySortTime(entry);
      if (latest == null || time.isAfter(latest)) {
        latest = time;
      }
    }
    return latest ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  DateTime _entrySortTime(_GradingGroupEntry entry) {
    return entry.queueTime;
  }

  /// 세로(같은 학생·같은 교재): 앞쪽 페이지가 위, 그다음 제출/대기 시각.
  int _compareEntriesWithinStack(
    _GradingGroupEntry a,
    _GradingGroupEntry b,
  ) {
    final aPage = _entryEarliestPage(a);
    final bPage = _entryEarliestPage(b);
    if (aPage != null && bPage != null) {
      final pageCmp = aPage.compareTo(bPage);
      if (pageCmp != 0) return pageCmp;
    } else if (aPage != null) {
      return -1;
    } else if (bPage != null) {
      return 1;
    }
    final timeCmp = _entrySortTime(a).compareTo(_entrySortTime(b));
    if (timeCmp != 0) return timeCmp;
    final nameCmp = a.studentName.compareTo(b.studentName);
    if (nameCmp != 0) return nameCmp;
    return a.summary.id.compareTo(b.summary.id);
  }

  int? _entryEarliestPage(_GradingGroupEntry entry) {
    final pages = <int>{
      ...homeworkItemDisplayPages(
        page: entry.summary.page,
        unitMappings: entry.summary.unitMappings,
      ),
    };
    for (final child in entry.children) {
      pages.addAll(
        homeworkItemDisplayPages(
          page: child.page,
          unitMappings: child.unitMappings,
        ),
      );
    }
    if (pages.isEmpty) return null;
    return pages.reduce(math.min);
  }

  String _entryStackKey(_GradingGroupEntry entry) {
    String bookId = (entry.summary.bookId ?? '').trim().toLowerCase();
    String gradeLabel = (entry.summary.gradeLabel ?? '').trim().toLowerCase();
    if (bookId.isEmpty) {
      for (final child in entry.children) {
        bookId = (child.bookId ?? '').trim().toLowerCase();
        if (bookId.isEmpty) continue;
        gradeLabel = (child.gradeLabel ?? '').trim().toLowerCase();
        break;
      }
    }
    if (bookId.isNotEmpty) {
      return '${entry.studentId}|book:$bookId|grade:$gradeLabel';
    }
    final bookName = _entryBookNameFallback(entry.summary).trim().toLowerCase();
    if (bookName.isNotEmpty && bookName != '-') {
      return '${entry.studentId}|name:$bookName|grade:$gradeLabel';
    }
    // 교재 식별자가 없으면 서로 다른 출력물/문제은행 과제를 잘못 묶지 않는다.
    return '${entry.studentId}|entry:${entry.summary.id}';
  }

  String _entryBookNameFallback(HomeworkItem item) {
    final contentRaw = (item.content ?? '').trim();
    final fromContent = RegExp(r'(?:^|\n)\s*교재:\s*([^\n]+)')
        .firstMatch(contentRaw)
        ?.group(1)
        ?.trim();
    if (fromContent != null && fromContent.isNotEmpty) return fromContent;
    return _normalizedTypeLabel(item);
  }

  ({String bookId, String gradeLabel, bool disableFlowFallback})
      _resolveEntryCoverSource(
    _GradingGroupEntry entry,
  ) {
    if (_isPrintCoverEntry(entry) || _gradingEntryIsProblemBankSource(entry)) {
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
    const printLikeTypes = <String>{
      '\uCD9C\uB825\uBB3C',
      '\uD504\uB9B0\uD2B8',
    };
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
      final studentName = widget.studentNamesById[studentId] ?? '\uD559\uC0DD';
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
      final t = a.queueTime.compareTo(b.queueTime);
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
      final studentName = widget.studentNamesById[studentId] ?? '\uD559\uC0DD';
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
      final t = a.queueTime.compareTo(b.queueTime);
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
      if (child.status == HomeworkStatus.completed) continue;
      final key = (studentId: entry.studentId, itemId: child.id);
      // 숙제 검사에서 만든 채점 초안은 배치 확정 전까지 phase 1을 유지한다.
      // 실제 제출 카드뿐 아니라 명시적으로 pending인 숙제도 체크 표시 대상이다.
      if (!_isSubmittedVisible(child) &&
          !widget.pendingConfirms.containsKey(key)) {
        continue;
      }
      out.add(key);
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

  bool _isEntrySaving(_GradingGroupEntry entry) {
    return entry.children.any(
      (child) => widget.savingConfirms.contains(
        (studentId: entry.studentId, itemId: child.id),
      ),
    );
  }

  List<_GradingGroupEntry> _buildEntriesForStudent({
    required String studentId,
    required String studentName,
    required List<HomeworkAssignmentDetail> assignments,
    required _GradingSection section,
  }) {
    final out = <_GradingGroupEntry>[];
    final now = DateTime.now();
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
      final hasHomeworkAssignment = assignedChildren.isNotEmpty &&
          shouldShowUnsubmittedHomeworkInGradingMode(
            schedules: assignedChildren.expand(
              (child) => (assignmentByItemId[child.id] ?? const []).map(
                (assignment) => GradingHomeworkSchedule(
                  assignedAt: assignment.assignedAt,
                  dueForCheckAt: assignment.dueForCheckAt,
                  dueDate: assignment.dueDate,
                ),
              ),
            ),
            now: now,
          );

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
      final submittedTime = _submittedSortTimeOfChildren(children);
      final homeworkTime = widget.arrivalTimesByStudentId[studentId] ??
          _homeworkSortTimeOfChildren(children);
      final queueTime = retainGradingQueueTime(
        _retainedQueueTimeByEntry,
        entryIdentity: gradingQueueEntryIdentity(
          studentId: studentId,
          groupId: group.id,
          summaryId: summary.id,
        ),
        candidate:
            section == _GradingSection.submitted ? submittedTime : homeworkTime,
      );
      out.add(
        _GradingGroupEntry(
          studentId: studentId,
          studentName: studentName,
          section: section,
          group: group,
          summary: summary,
          children: children,
          displayTitle: displayTitle.trim().isEmpty
              ? '\uC81C\uBAA9 \uC5C6\uC74C'
              : displayTitle,
          dueDate: dueDate,
          submittedTime: submittedTime,
          homeworkTime: homeworkTime,
          queueTime: queueTime,
          inspectionArrival: section == _GradingSection.homework
              ? _inspectionArrivalFor(
                  studentId: studentId,
                  schedules: assignedChildren.expand(
                    (child) => (assignmentByItemId[child.id] ?? const []).map(
                      (assignment) => GradingHomeworkSchedule(
                        assignedAt: assignment.assignedAt,
                        dueForCheckAt: assignment.dueForCheckAt,
                        dueDate: assignment.dueDate,
                      ),
                    ),
                  ),
                  now: now,
                )
              : null,
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
      final itemAssignments = assignmentByItemId[item.id] ?? const [];
      final hasHomeworkAssignment = item.phase != 0 &&
          shouldShowUnsubmittedHomeworkInGradingMode(
            schedules: itemAssignments.map(
              (assignment) => GradingHomeworkSchedule(
                assignedAt: assignment.assignedAt,
                dueForCheckAt: assignment.dueForCheckAt,
                dueDate: assignment.dueDate,
              ),
            ),
            now: now,
          );
      final include = section == _GradingSection.submitted
          ? hasSubmitted
          : (!hasSubmitted && hasHomeworkAssignment);
      if (!include) continue;

      DateTime? dueDate;
      String titleSnapshot = '';
      for (final assignment in itemAssignments) {
        dueDate = _mergeDueDate(dueDate, _dateOnly(assignment.dueDate));
        if (titleSnapshot.isEmpty) {
          final snapshot = (assignment.groupTitleSnapshot ?? '').trim();
          if (snapshot.isNotEmpty) titleSnapshot = snapshot;
        }
      }
      final displayTitle =
          titleSnapshot.isNotEmpty ? titleSnapshot : item.title.trim();
      final submittedTime = _submittedSortTimeOfItem(item);
      final homeworkTime = widget.arrivalTimesByStudentId[studentId] ??
          _homeworkSortTimeOfItem(item);
      final queueTime = retainGradingQueueTime(
        _retainedQueueTimeByEntry,
        entryIdentity: gradingQueueEntryIdentity(
          studentId: studentId,
          summaryId: item.id,
        ),
        candidate:
            section == _GradingSection.submitted ? submittedTime : homeworkTime,
      );
      out.add(
        _GradingGroupEntry(
          studentId: studentId,
          studentName: studentName,
          section: section,
          group: null,
          summary: item,
          children: <HomeworkItem>[item],
          displayTitle: displayTitle.isEmpty
              ? '(\uC81C\uBAA9 \uC5C6\uC74C)'
              : displayTitle,
          dueDate: dueDate,
          submittedTime: submittedTime,
          homeworkTime: homeworkTime,
          queueTime: queueTime,
          inspectionArrival: section == _GradingSection.homework
              ? _inspectionArrivalFor(
                  studentId: studentId,
                  schedules: itemAssignments.map(
                    (assignment) => GradingHomeworkSchedule(
                      assignedAt: assignment.assignedAt,
                      dueForCheckAt: assignment.dueForCheckAt,
                      dueDate: assignment.dueDate,
                    ),
                  ),
                  now: now,
                )
              : null,
        ),
      );
    }

    return out;
  }

  /// 숙제 검사일과 같은 날의 가장 이른 등원. 아직 등원 전이면 null.
  DateTime? _inspectionArrivalFor({
    required String studentId,
    required Iterable<GradingHomeworkSchedule> schedules,
    required DateTime now,
  }) {
    final localNow = now.toLocal();
    final today = DateTime(localNow.year, localNow.month, localNow.day);
    DateTime? checkAt;
    for (final schedule in schedules) {
      final effective = schedule.effectiveCheckAt;
      if (effective == null) continue;
      final local = effective.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (day != today) continue;
      if (checkAt == null || effective.isBefore(checkAt)) {
        checkAt = effective;
      }
    }
    if (checkAt == null) return null;
    final arrivals = <DateTime>[
      for (final record in DataManager.instance.attendanceRecordsNotifier.value)
        if (record.studentId == studentId && record.arrivalTime != null)
          record.arrivalTime!,
      if (widget.arrivalTimesByStudentId[studentId] != null)
        widget.arrivalTimesByStudentId[studentId]!,
    ];
    return earliestLocalArrivalOnDay(arrivals, checkAt);
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
      if (page.isNotEmpty) pages.add(page);
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
      // ?? ????????? ???????????? ??? ????? ???????????.
      final merged = mergeHomeworkPageRawStrings(pages);
      return merged.isEmpty ? pages.join(', ') : merged;
    }();
    final normalizedChildTypes = <String>{
      for (final child in children)
        if ((child.type ?? '').trim().isNotEmpty) (child.type ?? '').trim(),
    };
    final summaryType = normalizedChildTypes.length == 1
        ? normalizedChildTypes.first
        : '${children.length}\uAC1C \uACFC\uC81C';

    return HomeworkItem(
      id: (runningChild ?? first).id,
      assignmentCode: (runningChild ?? first).assignmentCode,
      learningTrackCode: group.learningTrackCode,
      title:
          title.trim().isEmpty ? '(\uC81C\uBAA9 \uC5C6\uC74C)' : title.trim(),
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
  final _GradingSection section;
  final HomeworkGroup? group;
  final HomeworkItem summary;
  final List<HomeworkItem> children;
  final String displayTitle;
  final DateTime? dueDate;
  final DateTime submittedTime;
  final DateTime homeworkTime;
  final DateTime queueTime;

  /// 숙제 칩의 경과 기준. 검사일 당일 등원 시각이며, 등원 전이면 null.
  final DateTime? inspectionArrival;

  const _GradingGroupEntry({
    required this.studentId,
    required this.studentName,
    required this.section,
    required this.group,
    required this.summary,
    required this.children,
    required this.displayTitle,
    required this.dueDate,
    required this.submittedTime,
    required this.homeworkTime,
    required this.queueTime,
    this.inspectionArrival,
  });

  bool get hasSubmittedChild => children.any(
      (child) => child.phase == 3 && child.status != HomeworkStatus.completed);
}

class _GradingEntryStack {
  final List<_GradingGroupEntry> entries;

  const _GradingEntryStack({required this.entries});
}

/// ????????(?? ??) ?????? ??????.
/// ???? ?? ?? ?????? ?? ?????????? ??? ??????????? ???.
bool _gradingEntryIsProblemBankSource(_GradingGroupEntry entry) {
  if ((entry.summary.pbPresetId ?? '').trim().isNotEmpty) return true;
  for (final child in entry.children) {
    if ((child.pbPresetId ?? '').trim().isNotEmpty) return true;
  }
  return false;
}

class _GradingCardLayout {
  final double width;
  final double height;
  final double metaHeight;
  final double metaDisplayHeight;
  final double spacing;

  const _GradingCardLayout({
    required this.width,
    required this.height,
    required this.metaHeight,
    required this.metaDisplayHeight,
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

  String get displayName =>
      name.trim().isEmpty ? '\uC81C\uBAA9 \uC5C6\uC74C' : name.trim();

  String get displayDescription {
    final cleaned = description.trim();
    return cleaned.isEmpty
        ? '\uC815\uB2F5 PDF \uBC14\uB85C\uAC00\uAE30'
        : cleaned;
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
    return label.isEmpty ? '\uACFC\uC815' : label;
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
    final brightness = Theme.of(context).brightness;
    return FabStyleGlassPanel(
      useFabTabBarBackground: brightness == Brightness.dark,
      padding: const EdgeInsets.symmetric(
        horizontal: _kGradingAnswerRailHorizontalPadding,
      ),
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
                          '\uC5F0\uACB0\uB41C \uC815\uB2F5 PDF\uAC00 \uC5C6\uC2B5\uB2C8\uB2E4.',
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
    // 자료 메뉴 책카드 표지와 같은 A4 비율. 0.72는 레일 높이 안에서
    // 위아래 책이 보이게 남기는 상한이다.
    final cardHeight = math.min(
      width * resourceTextbookCardCoverA4Ratio,
      height * 0.72,
    );
    final centerTop = (height - cardHeight) / 2;
    final slotGap = cardHeight * 0.31;
    final visibleSlots = _visibleBookSlots();

    return Stack(
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
    final overlay = CoverOverlayStyle(onDark: true, hasImage: provider != null);
    const radius = FabTabBarTokens.previewAcademyGroupedCardRadius;
    const pad = 16.0;
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
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(radius),
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
                aspectRatio: 1 / resourceTextbookCardCoverA4Ratio,
                child: Stack(
                  clipBehavior: Clip.none,
                  fit: StackFit.expand,
                  children: [
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(radius),
                            boxShadow: resourceTextbookCoverBoxShadows(),
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(radius),
                        child: DecoratedBox(
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
                      ),
                    ),
                    // 아래 띠가 교재명 2줄 + 설명 3줄을 덮도록 일찍 시작.
                    Positioned.fill(
                      child: CoverScrim(
                        style: overlay,
                        topEnd: 0.30,
                        bottomStart: 0.42,
                        showTop: false,
                      ),
                    ),
                    Positioned.fill(
                      child: CoverHairline(style: overlay, radius: radius),
                    ),
                    Positioned(
                      left: pad,
                      top: pad,
                      right: pad,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: CoverPill(
                          style: overlay,
                          label: grade.displayLabel,
                          icon: widget.book.grades.length > 1
                              ? Icons.swap_horiz_rounded
                              : null,
                        ),
                      ),
                    ),
                    Positioned(
                      left: pad,
                      right: pad,
                      bottom: pad,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.book.displayName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: overlay.titleStyle(context),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            widget.book.displayDescription,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily:
                                  FabTabBarTokens.previewAcademyLabelFontFamily,
                              color: overlay.inkSecondary,
                              fontSize: 20,
                              fontWeight:
                                  FabTabBarTokens.previewAcademyLabelFontWeight,
                              height: 1.18,
                              shadows: overlay.textShadows,
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

class _SubmittedHomeworkCard extends StatefulWidget {
  final _GradingGroupEntry entry;
  final double cardHeight;
  final double metaHeight;
  final double metaDisplayHeight;
  final Future<String?> coverPathFuture;
  final Future<void> Function()? onTap;
  final bool isPendingConfirm;
  final bool isCompleteCheckbox;
  final bool isSavingConfirm;

  const _SubmittedHomeworkCard({
    required this.entry,
    required this.cardHeight,
    required this.metaHeight,
    required this.metaDisplayHeight,
    required this.coverPathFuture,
    this.onTap,
    this.isPendingConfirm = false,
    this.isCompleteCheckbox = false,
    this.isSavingConfirm = false,
  });

  @override
  State<_SubmittedHomeworkCard> createState() => _SubmittedHomeworkCardState();
}

class _SubmittedHomeworkCardState extends State<_SubmittedHomeworkCard> {
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    HomeworkGradingLockService.instance.releasingKeys.addListener(
      _onReleasingKeys,
    );
    HomeworkBatchConfirmService.instance.confirmingKeys.addListener(
      _onReleasingKeys,
    );
  }

  @override
  void dispose() {
    HomeworkGradingLockService.instance.releasingKeys.removeListener(
      _onReleasingKeys,
    );
    HomeworkBatchConfirmService.instance.confirmingKeys.removeListener(
      _onReleasingKeys,
    );
    super.dispose();
  }

  void _onReleasingKeys() {
    if (mounted) setState(() {});
  }

  bool get _isReleasing {
    final releasing = HomeworkGradingLockService.instance.releasingKeys.value;
    return entry.children.any(
      (child) => releasing.contains(
        (studentId: entry.studentId, itemId: child.id),
      ),
    );
  }

  bool get _isBatchConfirming {
    final confirming = HomeworkBatchConfirmService.instance.confirmingKeys.value;
    return entry.children.any(
      (child) => confirming.contains(
        (studentId: entry.studentId, itemId: child.id),
      ),
    );
  }

  bool get _showsOpenRing =>
      _opening || isSavingConfirm || _isReleasing || _isBatchConfirming;

  _GradingGroupEntry get entry => widget.entry;
  double get cardHeight => widget.cardHeight;
  double get metaHeight => widget.metaHeight;
  double get metaDisplayHeight => widget.metaDisplayHeight;
  Future<String?> get coverPathFuture => widget.coverPathFuture;
  Future<void> Function()? get onTap => widget.onTap;
  bool get isPendingConfirm => widget.isPendingConfirm;
  bool get isCompleteCheckbox => widget.isCompleteCheckbox;
  bool get isSavingConfirm => widget.isSavingConfirm;

  Future<void> _handleTap() async {
    final action = onTap;
    if (action == null || _showsOpenRing) return;
    setState(() => _opening = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hw = entry.summary;
    final line2 = entry.displayTitle.trim().isEmpty
        ? '(\uC81C\uBAA9 \uC5C6\uC74C)'
        : entry.displayTitle.trim();
    final bookStr = _extractBookName(hw).isEmpty ? '-' : _extractBookName(hw);
    final courseStr =
        _extractCourseName(hw).isEmpty ? '-' : _extractCourseName(hw);
    final assignmentNumText = _gradingCardAssignmentNumberLabel(hw);
    final scale =
        (cardHeight / _kGradingBaseCardHeight).clamp(0.5, 1.15).toDouble();
    final cardRadius = FabTabBarTokens.previewAcademyGroupedCardRadius;
    final coverMetaGap = (24.0 * scale).clamp(8.0, 24.0).toDouble();
    final contentPadH = (12.0 * scale).clamp(6.0, 12.0).toDouble();
    final line4 = _buildLine4MinutesSinceSubmitted(entry);
    final pageLines = _buildOverlayPageLines(entry);
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(
      Theme.of(context).brightness,
    );
    final coverHeight = (cardHeight - metaHeight).clamp(0.0, cardHeight);
    final metaBottomInset = math.max(0.0, metaHeight - metaDisplayHeight);
    final metaContentHeight = math.max(0.0, metaDisplayHeight - coverMetaGap);

    Widget buildCoverStack() {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(cardRadius),
                  boxShadow: resourceTextbookCoverBoxShadows(),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(cardRadius),
              child: _buildCoverArea(
                scale,
                line4: line4,
                pageLines: pageLines,
                assignmentNumText: assignmentNumText,
              ),
            ),
          ),
          if (isPendingConfirm && !_showsOpenRing)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(cardRadius),
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
            ),
          if (_showsOpenRing)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(cardRadius),
                child: IgnorePointer(
                  child: Container(
                    color: const Color(0x990B1112),
                    child: Center(
                      child: SizedBox(
                        width: (34.0 * scale).clamp(24.0, 38.0),
                        height: (34.0 * scale).clamp(24.0, 38.0),
                        child: const CircularProgressIndicator(
                          strokeWidth: 2.6,
                          color: kDlgAccent,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }

    Widget buildMetaSection() {
      const subFontSize = _kGradingHomeworkCardMetaFontSize;
      final lineHeight = (metaContentHeight / (subFontSize * 3))
          .clamp(
            _kGradingHomeworkCardMetaLineHeightMin,
            _kGradingHomeworkCardMetaLineHeightMax,
          )
          .toDouble();
      final sourceStyle =
          FabTabBarTokens.previewAcademyMainTitleStyle(panelStyle);
      final subtitleStyle = TextStyle(
        color: panelStyle.hint,
        fontSize: subFontSize,
        fontFamily: FabTabBarTokens.previewAcademyLabelFontFamily,
        fontWeight: FontWeight.w600,
        height: lineHeight,
      );
      final line1Text = bookStr == '-' && courseStr == '-'
          ? (line2.trim().isEmpty ? '-' : line2)
          : (bookStr != '-' && courseStr != '-'
              ? '$bookStr \u00B7 $courseStr'
              : (bookStr != '-' ? bookStr : courseStr));
      final lineRowHeight = subFontSize * lineHeight;
      const sourceRowHeight =
          FabTabBarTokens.previewAcademyMainTitleFontSize * 1.15;
      final metaLineGap = math.max(
        0.0,
        (metaContentHeight - sourceRowHeight - lineRowHeight * 2) / 2,
      );

      return SizedBox(
        height: metaContentHeight,
        width: double.infinity,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: contentPadH),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final titleForRows = line1Text == line2 ? '' : line2;
              final titleSplit = _splitGradingCardTitleLines(
                titleForRows,
                maxWidth: constraints.maxWidth,
                style: subtitleStyle,
              );

              Widget metaLineSlot({
                required String text,
                required TextStyle style,
                double? slotHeight,
                Alignment alignment = Alignment.centerLeft,
              }) {
                return SizedBox(
                  height: slotHeight ?? lineRowHeight,
                  width: double.infinity,
                  child: Align(
                    alignment: alignment,
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textScaler: TextScaler.noScaling,
                      style: style,
                    ),
                  ),
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  metaLineSlot(
                    text: line1Text,
                    style: sourceStyle,
                    slotHeight: sourceRowHeight,
                  ),
                  SizedBox(height: metaLineGap),
                  metaLineSlot(
                    text: titleSplit.line1,
                    style: subtitleStyle,
                  ),
                  SizedBox(height: metaLineGap),
                  metaLineSlot(
                    text: titleSplit.line2,
                    style: subtitleStyle,
                  ),
                ],
              );
            },
          ),
        ),
      );
    }

    final card = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: coverHeight,
          width: double.infinity,
          child: buildCoverStack(),
        ),
        SizedBox(height: coverMetaGap),
        buildMetaSection(),
        SizedBox(height: metaBottomInset),
      ],
    );

    if (onTap == null) return card;
    return MouseRegion(
      cursor: _showsOpenRing
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _showsOpenRing ? null : () => unawaited(_handleTap()),
        child: card,
      ),
    );
  }

  Widget _buildCoverArea(
    double scale, {
    required String line4,
    required List<String> pageLines,
    required String assignmentNumText,
  }) {
    return FutureBuilder<String?>(
      future: coverPathFuture,
      builder: (context, snapshot) {
        final hw = entry.summary;
        final provider = _coverImageProvider(snapshot.data ?? '');
        final hasImage = provider != null;
        final isProblemBankSource = _gradingEntryIsProblemBankSource(entry);
        final fallbackCoverColor = isProblemBankSource
            ? const Color(0xFF2B2B2B)
            : _coverColorForType(hw);
        final isPrintCover = _isPrintCoverEntry(entry);
        final useDarkOverlayText = !isProblemBankSource &&
            (isPrintCover ||
                (!hasImage && fallbackCoverColor.computeLuminance() > 0.6));
        final overlay = CoverOverlayStyle(
          onDark: !useDarkOverlayText,
          hasImage: hasImage,
        );
        final pad = CoverOverlayStyle.padFor(scale);
        final gap = CoverOverlayStyle.gapFor(scale);
        // 페이지 줄 ↔ 아래 과제번호 배지. 이름 ↔ 경과·숙제 배지도 같은 값.
        final chipGap = gap + 2;
        final pageGap = (2.0 * scale).clamp(1.0, 2.0).toDouble();
        final pageStyle = TextStyle(
          color: overlay.ink,
          fontSize: _kGradingHomeworkCardCoverDetailFontSize,
          fontFamily: FabTabBarTokens.previewAcademyLabelFontFamily,
          fontWeight: FontWeight.w700,
          height: _kGradingHomeworkCardCoverDetailLineHeight,
          letterSpacing: -0.2,
          fontFeatures: const [FontFeature.tabularFigures()],
          shadows: overlay.textShadows,
        );
        // 제출: 제출 시각부터 경과. 숙제: 같은 경과를 초록 테두리로, 등원 전이면 숙제 배지.
        final isHomeworkChip = entry.section == _GradingSection.homework;
        final CoverPill? statusPill = line4 != '-'
            ? CoverPill(
                style: overlay,
                tone: isHomeworkChip
                    ? CoverPillTone.accent
                    : CoverPillTone.neutral,
                icon: Icons.schedule_rounded,
                label: '$line4 \uC804',
              )
            : (isHomeworkChip
                ? CoverPill(
                    style: overlay,
                    tone: CoverPillTone.accent,
                    label: '\uC219\uC81C',
                  )
                : null);
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
              child: CoverScrim(style: overlay, showTop: false),
            ),
            Positioned.fill(
              child: CoverHairline(
                style: overlay,
                radius: FabTabBarTokens.previewAcademyGroupedCardRadius,
              ),
            ),
            Positioned(
              left: pad,
              right: pad,
              top: pad,
              child: IgnorePointer(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final nameStyle = overlay.titleStyle(context);
                    final name = Text(
                      entry.studentName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: nameStyle,
                    );
                    if (statusPill == null) return name;
                    final nameWidth = _singleLineTextWidth(
                      entry.studentName,
                      nameStyle,
                      textScaler: MediaQuery.textScalerOf(context),
                    );
                    final pillWidth = _coverStatusPillWidth(statusPill);
                    // 이름과 배지가 한 줄에 들어가면 배지는 오른쪽 끝.
                    // 모자라면 이름은 첫 줄 전체를 쓰고, 배지는 다음 줄 왼쪽.
                    if (nameWidth + chipGap + pillWidth > constraints.maxWidth) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          name,
                          SizedBox(height: gap),
                          ConstrainedBox(
                            constraints:
                                BoxConstraints(maxWidth: constraints.maxWidth),
                            child: statusPill,
                          ),
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(child: name),
                        SizedBox(width: chipGap),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: math.max(
                              0.0,
                              constraints.maxWidth - chipGap,
                            ),
                          ),
                          child: statusPill,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            Positioned(
              left: pad,
              right: pad,
              bottom: pad,
              child: IgnorePointer(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (int i = 0; i < pageLines.length; i++) ...[
                      Padding(
                        padding: const EdgeInsets.only(left: 2),
                        child: Text(
                          pageLines[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: pageStyle,
                        ),
                      ),
                      SizedBox(
                        height: i == pageLines.length - 1 ? chipGap : pageGap,
                      ),
                    ],
                    CoverPill(
                      style: overlay,
                      label: assignmentNumText,
                      emphasize: true,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  String _buildLine4MinutesSinceSubmitted(_GradingGroupEntry entry) {
    final DateTime? anchor;
    if (entry.section == _GradingSection.homework) {
      anchor = entry.inspectionArrival;
    } else if (entry.hasSubmittedChild) {
      anchor = entry.submittedTime;
    } else {
      anchor = null;
    }
    if (anchor == null) return '-';
    return formatGradingElapsedSince(anchor, DateTime.now());
  }

  List<String> _buildOverlayPageLines(_GradingGroupEntry entry) {
    // 그룹 과제는 하위 과제의 page뿐 아니라 unitMappings에 저장된 페이지도
    // 합쳐 한 줄로 표시한다. 마이그레이션된 과제는 page가 비어 있고
    // unitMappings에만 페이지 정보가 남아 있을 수 있다.
    final merged = mergeHomeworkItemPageRanges(
      entry.children.map(
        (child) => (
          page: child.page,
          unitMappings: child.unitMappings,
        ),
      ),
    );
    if (merged.isNotEmpty) return <String>['p.$merged'];

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
    final fromContent = RegExp(r'(?:^|\n)\s*\uAD50\uC7AC:\s*([^\n]+)')
        .firstMatch(contentRaw)
        ?.group(1);
    if (fromContent != null && fromContent.trim().isNotEmpty) {
      return fromContent.trim();
    }

    final hasLinkedTextbook = (hw.bookId ?? '').trim().isNotEmpty &&
        (hw.gradeLabel ?? '').trim().isNotEmpty;
    if (hasLinkedTextbook) {
      final stripped = _stripUnitPrefix(hw.title.trim());
      if (stripped.isNotEmpty) {
        final idx = stripped.indexOf('?');
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
    final fromContent = RegExp(r'(?:^|\n)\s*\uACFC\uC815:\s*([^\n]+)')
        .firstMatch(contentRaw)
        ?.group(1);
    return (fromContent ?? '').trim();
  }

  String _stripUnitPrefix(String raw) {
    return raw.replaceFirst(RegExp(r'^\s*\d+\.\d+\.\(\d+\)\s+'), '').trim();
  }

  String _normalizedTypeLabel(HomeworkItem hw) {
    return (hw.type ?? '').trim();
  }

  bool _isPrintCoverEntry(_GradingGroupEntry entry) {
    const printLikeTypes = <String>{
      '\uCD9C\uB825\uBB3C',
      '\uD504\uB9B0\uD2B8',
    };
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
      case '\uCD9C\uB825\uBB3C':
      case '\uD504\uB9B0\uD2B8':
        return Colors.white;
      case '\uAD50\uC7AC':
      case '\uBB38\uC81C\uC9D1':
        return const Color(0xFF2E7D32);
      case '\uBB38\uC81C\uC740\uD589':
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

double _singleLineTextWidth(
  String text,
  TextStyle style, {
  TextScaler textScaler = TextScaler.noScaling,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
  )..layout();
  return painter.width;
}

/// [CoverPill]이 글자를 줄이지 않을 때의 가로 너비.
double _coverStatusPillWidth(CoverPill pill) {
  final hasIcon = pill.icon != null;
  final hasDot = !hasIcon && pill.tone == CoverPillTone.accent;
  final hasLeading = hasIcon || hasDot;
  final leadingWidth =
      hasIcon ? CoverOverlayStyle.pillFontSize : (hasDot ? 7.0 : 0.0);
  final textWidth = _singleLineTextWidth(
    pill.label,
    pill.style.pillTextStyle.copyWith(
      fontWeight: pill.emphasize ? FontWeight.w700 : FontWeight.w600,
      letterSpacing: pill.emphasize ? 0.8 : null,
    ),
  );
  final leftPad = hasLeading ? 10.0 : 12.0;
  final leadingBlock = hasLeading ? leadingWidth + 6.0 : 0.0;
  return leftPad + leadingBlock + textWidth + 12.0;
}
