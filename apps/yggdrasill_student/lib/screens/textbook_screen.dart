import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/homework_session.dart';
import '../services/student_api.dart';
import '../services/textbook_api.dart';
import '../services/textbook_catalog_organizer.dart';
import '../services/textbook_study_session.dart';
import '../widgets/student_confirm_sheet.dart';
import '../widgets/student_page_title.dart';
import '../widgets/student_progress_summary_card.dart';
import 'homework_solve_launcher.dart';
import 'textbook_solve_screen.dart';

const double _coverA4Ratio = 1.414;
const double _cardMaxWidth = 240;
const double _cardGap = 20;
const double _coverToMetaSpacing = 14;
const double _cardMetaHeight = 77;
const double _cardRadius = 28;

/// 채점 과제카드가 제목 32·본문 22·배지 17인 기준 너비.
const double _coverTypeReferenceWidth = 288;

/// "교재 풀기" 탭 — 정답 DB가 준비된 교재 목록 + 풀이 현황.
class TextbookScreen extends StatefulWidget {
  const TextbookScreen({super.key});

  @override
  State<TextbookScreen> createState() => _TextbookScreenState();
}

class _TextbookScreenState extends State<TextbookScreen> {
  List<StudentTextbook>? _books;
  String? _error;
  Timer? _syncDebounce;
  bool _pausedExpanded = false;
  bool _endedExpanded = false;
  bool _completedExpanded = false;

  @override
  void initState() {
    super.initState();
    TextbookStudySession.instance.addListener(_onStudySessionChanged);
    HomeworkSession.instance.textbookSyncTick.addListener(_onRemoteTextbookSync);
    _refresh();
  }

  @override
  void dispose() {
    _syncDebounce?.cancel();
    TextbookStudySession.instance.removeListener(_onStudySessionChanged);
    HomeworkSession.instance.textbookSyncTick
        .removeListener(_onRemoteTextbookSync);
    super.dispose();
  }

  void _onRemoteTextbookSync() {
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) unawaited(_refresh());
    });
  }

  void _onStudySessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    try {
      final results = await Future.wait([
        TextbookApi.instance.listTextbooks(),
        TextbookStudySession.instance.refresh(),
      ]);
      final books = results[0] as List<StudentTextbook>;
      if (!mounted) return;
      setState(() {
        _books = books;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '교재 목록을 불러오지 못했어요.\n$e');
    }
  }

  Future<void> _openBook(StudentTextbook book) async {
    final existingSolve = TextbookStudySession.instance
        .solveSessionFor(book.bookId, book.gradeLabel);
    final TextbookEntryMode? chosenMode;
    if (existingSolve != null && book.isActiveSeason) {
      // 중단(또는 열려 있는) 바로풀기 세션이 있으면 묻지 않고 바로 이어 푼다.
      chosenMode = TextbookEntryMode.solve;
    } else {
      final offers = await _homeworkOffersFor(book);
      if (!mounted) return;
      if (offers.isNotEmpty) {
        final picked = await _showHomeworkFirstSheet(book, offers);
        if (!mounted || picked == null) return;
        if (picked is HomeworkGroup) {
          await _openHomeworkInstead(book, picked);
          return;
        }
      }
      if (!mounted) return;
      chosenMode = await _showEntryModeSheet(book);
    }
    if (chosenMode == null || !mounted) return;

    // 시작 전 또는 보류 상태인 교재를 직접 열면 현재 시즌을 자동으로 시작/재개한다.
    if (book.isNotStarted) {
      unawaited(
        TextbookApi.instance
            .setTextbookSeasonState(
              bookId: book.bookId,
              gradeLabel: book.gradeLabel,
              action: TextbookSeasonAction.start,
            )
            .catchError((Object _) => null),
      );
    } else if (book.isPausedSeason) {
      unawaited(
        TextbookApi.instance
            .setTextbookSeasonState(
              bookId: book.bookId,
              gradeLabel: book.gradeLabel,
              action: TextbookSeasonAction.resume,
            )
            .catchError((Object _) => null),
      );
    }

    final session = await TextbookStudySession.instance.startSession(
      bookId: book.bookId,
      gradeLabel: book.gradeLabel,
      entryMode: chosenMode,
    );
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TextbookSolveScreen(
          book: book,
          entryMode: chosenMode,
          studySessionId: session?.sessionId,
        ),
      ),
    );
    // 풀고 돌아오면 현황 갱신
    _refresh();
  }

  /// 이 교재의 대기·수행 중 그룹과제. 시간제한 테스트와 제출·확인 단계는 뺀다.
  Future<List<({HomeworkGroup group, int remaining})>> _homeworkOffersFor(
    StudentTextbook book,
  ) async {
    List<HomeworkGroup> groups;
    try {
      groups = await StudentApi.instance.listHomeworkGroups();
    } catch (_) {
      return const [];
    }
    final matched = <HomeworkGroup>[
      for (final group in groups)
        if (_isOpenHomeworkForBook(group, book)) group,
    ];
    if (matched.isEmpty) return const [];

    final counted = await Future.wait(matched.map((group) async {
      try {
        final problems =
            await StudentApi.instance.listHomeworkProblems(group.groupId);
        final usable = problems
            .where((problem) => problem.cropId.trim().isNotEmpty)
            .toList(growable: false);
        final remaining = usable
            .where((problem) => problem.attemptCount <= 0)
            .length;
        return (group: group, remaining: remaining, known: true);
      } catch (_) {
        return (
          group: group,
          remaining: group.totalCount,
          known: false,
        );
      }
    }));
    return [
      for (final row in counted)
        if (!row.known || row.remaining > 0)
          (group: row.group, remaining: row.remaining),
    ];
  }

  bool _isOpenHomeworkForBook(HomeworkGroup group, StudentTextbook book) {
    if (group.bookId.isEmpty || group.bookId != book.bookId) return false;
    final groupGrade = group.gradeLabel.trim();
    final bookGrade = book.gradeLabel.trim();
    if (groupGrade.isNotEmpty &&
        bookGrade.isNotEmpty &&
        groupGrade != bookGrade) {
      return false;
    }
    if (group.isTimedTest) return false;
    if (group.pendingComplete && group.phase == 1) return false;
    return group.phase == 1 || group.phase == 2;
  }

  Future<void> _openHomeworkInstead(
    StudentTextbook book,
    HomeworkGroup group,
  ) async {
    final opened = await openDigitalHomeworkSolve(
      context,
      group,
      coverRef: book.coverRef,
    );
    if (!mounted) return;
    if (!opened && !group.running && (group.phase == 1 || group.phase == 2)) {
      try {
        final result = await StudentApi.instance.groupTransition(
          groupId: group.groupId,
          fromPhase: 1,
        );
        if (mounted &&
            result['ok'] != true &&
            result['error'] != 'phase_mismatch') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('과제를 시작하지 못했어요.')),
          );
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('과제를 시작하지 못했어요.')),
          );
        }
      }
    }
    await _refresh();
  }

  /// 과제를 먼저 할지, 교재로 바로 풀지. null 은 닫기.
  /// 반환이 [HomeworkGroup]이면 그 과제, 그 외 non-null 이면 그냥 풀기.
  Future<Object?> _showHomeworkFirstSheet(
    StudentTextbook book,
    List<({HomeworkGroup group, int remaining})> offers,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
    final card = isDark ? const Color(0xFF2C2C2E) : Colors.white;
    final text = isDark ? Colors.white : Colors.black;
    final sub = text.withValues(alpha: 0.48);
    final divider = text.withValues(alpha: 0.08);
    const accent = YggGlassTokens.confirmActionColor;
    final optionCount = offers.length + 1;

    Widget option({
      required String label,
      required String subtitle,
      required IconData icon,
      required Color iconColor,
      required BorderRadius inkRadius,
      required VoidCallback onTap,
    }) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: inkRadius,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Row(
              children: [
                Icon(icon, size: 26, color: iconColor),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: sub,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    BorderRadius radiusFor(int index) {
      final top = index == 0;
      final bottom = index == optionCount - 1;
      if (top && bottom) return BorderRadius.circular(22);
      if (top) {
        return const BorderRadius.vertical(top: Radius.circular(22));
      }
      if (bottom) {
        return const BorderRadius.vertical(bottom: Radius.circular(22));
      }
      return BorderRadius.zero;
    }

    return showModalBottomSheet<Object>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    book.name,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '이 교재에 풀 과제가 있어요.\n먼저 하시겠어요?',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 1.35,
                      color: sub,
                    ),
                  ),
                  const SizedBox(height: 14),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: card,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: Column(
                        children: [
                          for (var i = 0; i < offers.length; i++) ...[
                            if (i > 0)
                              Divider(
                                height: 1,
                                indent: 18,
                                endIndent: 18,
                                color: divider,
                              ),
                            option(
                              label: offers[i].group.title.isEmpty
                                  ? '과제'
                                  : offers[i].group.title,
                              subtitle: offers[i].remaining > 0
                                  ? '남은 ${offers[i].remaining}문항'
                                  : '이어서 풀 수 있어요',
                              icon: Icons.assignment_outlined,
                              iconColor: accent,
                              inkRadius: radiusFor(i),
                              onTap: () =>
                                  Navigator.of(ctx).pop(offers[i].group),
                            ),
                          ],
                          Divider(
                            height: 1,
                            indent: 18,
                            endIndent: 18,
                            color: divider,
                          ),
                          option(
                            label: '그냥 풀기',
                            subtitle: '교재 화면에서 이어서 풀어요',
                            icon: Icons.menu_book_outlined,
                            iconColor: sub,
                            inkRadius: radiusFor(optionCount - 1),
                            onTap: () => Navigator.of(ctx).pop(false),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<TextbookEntryMode?> _showEntryModeSheet(StudentTextbook book) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
    final card = isDark ? const Color(0xFF2C2C2E) : Colors.white;
    final text = isDark ? Colors.white : Colors.black;
    final sub = text.withValues(alpha: 0.48);
    final divider = text.withValues(alpha: 0.08);
    final accent = YggGlassTokens.confirmActionColor;

    Widget option({
      required String label,
      required String subtitle,
      required IconData icon,
      required Color iconColor,
      required BorderRadius inkRadius,
      required VoidCallback onTap,
    }) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: inkRadius,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Row(
              children: [
                Icon(icon, size: 26, color: iconColor),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: sub,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return showModalBottomSheet<TextbookEntryMode>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    book.name,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '어떻게 시작할까요?',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: sub,
                    ),
                  ),
                  const SizedBox(height: 14),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: card,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: Column(
                        children: [
                          option(
                            label: '바로풀기',
                            subtitle: '시간을 기록하며 지금 바로 풀어요',
                            icon: Icons.play_arrow_rounded,
                            iconColor: accent,
                            inkRadius: const BorderRadius.vertical(
                              top: Radius.circular(22),
                            ),
                            onTap: () => Navigator.of(ctx)
                                .pop(TextbookEntryMode.solve),
                          ),
                          Divider(
                            height: 1,
                            indent: 18,
                            endIndent: 18,
                            color: divider,
                          ),
                          option(
                            label: '정답입력하기',
                            subtitle: '종이로 미리 풀어 온 답을 입력해요',
                            icon: Icons.edit_note_rounded,
                            iconColor: sub,
                            inkRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(22),
                            ),
                            onTap: () => Navigator.of(ctx)
                                .pop(TextbookEntryMode.answerEntry),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleBookLongPress(StudentTextbook book) async {
    final gradeSuffix =
        book.gradeLabel.trim().isEmpty ? '' : ' (${book.gradeLabel.trim()})';

    if (book.isNotStarted) {
      final confirmed = await showStudentConfirmSheet(
        context: context,
        title: '시즌 1 시작',
        message: '${book.name}$gradeSuffix 풀이를 시작할까요?\n'
            '활성 교재 목록 위로 올라갑니다.',
        confirmLabel: '시즌 1 시작',
        cancelLabel: '취소',
        confirmIcon: Icons.play_arrow_rounded,
        cancelIcon: Icons.close_rounded,
      );
      if (confirmed != true || !mounted) return;
      await _applySeasonAction(
        book,
        TextbookSeasonAction.start,
        failureMessage: '시즌을 시작하지 못했어요.',
      );
      return;
    }

    if (book.isClosedSeason) {
      final nextSeason = book.seasonNo + 1;
      final confirmed = await showStudentConfirmSheet(
        context: context,
        title: '시즌 $nextSeason 시작',
        message: '${book.name}$gradeSuffix의 이전 답 표시를 비우고 '
            '시즌 $nextSeason을 새로 시작합니다.\n'
            '지난 시즌 기록은 그대로 보관돼요.',
        confirmLabel: '시즌 $nextSeason 시작',
        cancelLabel: '취소',
        confirmIcon: Icons.refresh_rounded,
        cancelIcon: Icons.close_rounded,
      );
      if (confirmed != true || !mounted) return;
      final ok = await _applySeasonAction(
        book,
        TextbookSeasonAction.start,
        failureMessage: '새 시즌을 시작하지 못했어요.',
      );
      if (ok) {
        await TextbookStudySession.instance
            .finishForBook(book.bookId, book.gradeLabel);
      }
      return;
    }

    final chosen = await _showActiveOrPausedSeasonSheet(book);
    if (chosen == null || !mounted) return;

    if (chosen == TextbookSeasonAction.pause) {
      final activeSession = TextbookStudySession.instance
          .sessionFor(book.bookId, book.gradeLabel);
      if (activeSession != null && activeSession.isOpen) {
        await TextbookStudySession.instance
            .pauseSession(activeSession.sessionId);
      }
      await _applySeasonAction(
        book,
        TextbookSeasonAction.pause,
        failureMessage: '보류 상태로 바꾸지 못했어요.',
      );
      return;
    }

    if (chosen == TextbookSeasonAction.resume) {
      await _applySeasonAction(
        book,
        TextbookSeasonAction.resume,
        failureMessage: '시즌을 다시 이어가지 못했어요.',
      );
      return;
    }

    if (chosen == TextbookSeasonAction.end) {
      final targetBucket = book.everCompleted ? '완료됨' : '종료됨';
      final confirmed = await showStudentConfirmSheet(
        context: context,
        title: '시즌 ${book.seasonNo} 종료',
        message: '${book.name}$gradeSuffix의 시즌 ${book.seasonNo} 기록을 마감하고 '
            '$targetBucket 목록으로 옮깁니다.\n'
            '답안 표시는 다음 시즌을 시작할 때까지 그대로 남아 있어요.',
        confirmLabel: '시즌 종료',
        cancelLabel: '취소',
        confirmIcon: Icons.check_rounded,
        cancelIcon: Icons.close_rounded,
      );
      if (confirmed != true || !mounted) return;
      final ok = await _applySeasonAction(
        book,
        TextbookSeasonAction.end,
        failureMessage: '시즌을 종료하지 못했어요.',
      );
      if (ok) {
        await TextbookStudySession.instance
            .finishForBook(book.bookId, book.gradeLabel);
      }
    }
  }

  Future<bool> _applySeasonAction(
    StudentTextbook book,
    TextbookSeasonAction action, {
    required String failureMessage,
  }) async {
    String? error;
    try {
      error = await TextbookApi.instance.setTextbookSeasonState(
        bookId: book.bookId,
        gradeLabel: book.gradeLabel,
        action: action,
      );
    } catch (_) {
      error = 'unknown';
    }
    if (!mounted) return false;

    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error == 'under_review'
                ? '선생님이 검사 중인 교재예요. 검사가 끝나면 다시 시도해 주세요.'
                : failureMessage,
          ),
        ),
      );
      return false;
    }
    await _refresh();
    return true;
  }

  Future<TextbookSeasonAction?> _showActiveOrPausedSeasonSheet(
    StudentTextbook book,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
    final card = isDark ? const Color(0xFF2C2C2E) : Colors.white;
    final text = isDark ? Colors.white : Colors.black;
    final sub = text.withValues(alpha: 0.48);
    final divider = text.withValues(alpha: 0.08);
    const accent = YggGlassTokens.confirmActionColor;
    final isPaused = book.isPausedSeason;
    final targetEndLabel = book.everCompleted ? '완료됨' : '종료됨';

    Widget option({
      required String label,
      required String subtitle,
      required IconData icon,
      required Color iconColor,
      required BorderRadius inkRadius,
      required VoidCallback onTap,
    }) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: inkRadius,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Row(
              children: [
                Icon(icon, size: 26, color: iconColor),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: sub,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return showModalBottomSheet<TextbookSeasonAction>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    book.gradeLabel.trim().isEmpty
                        ? book.name
                        : '${book.name} · ${book.gradeLabel.trim()}',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isPaused
                        ? '시즌 ${book.seasonNo} · 현재 보류 중이에요'
                        : '시즌 ${book.seasonNo} 진행 중',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: sub,
                    ),
                  ),
                  const SizedBox(height: 14),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: card,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: Column(
                        children: [
                          if (isPaused)
                            option(
                              label: '시즌 이어하기',
                              subtitle:
                                  '보류를 풀고 시즌 ${book.seasonNo} 풀이를 계속해요',
                              icon: Icons.play_arrow_rounded,
                              iconColor: accent,
                              inkRadius: const BorderRadius.vertical(
                                top: Radius.circular(22),
                              ),
                              onTap: () => Navigator.of(ctx)
                                  .pop(TextbookSeasonAction.resume),
                            )
                          else
                            option(
                              label: '보류하기',
                              subtitle: '답과 기록을 남긴 채 보류 목록으로 내려요',
                              icon: Icons.pause_circle_outline_rounded,
                              iconColor: text.withValues(alpha: 0.78),
                              inkRadius: const BorderRadius.vertical(
                                top: Radius.circular(22),
                              ),
                              onTap: () => Navigator.of(ctx)
                                  .pop(TextbookSeasonAction.pause),
                            ),
                          Divider(
                            height: 1,
                            indent: 18,
                            endIndent: 18,
                            color: divider,
                          ),
                          option(
                            label: '시즌 종료',
                            subtitle:
                                '시즌 ${book.seasonNo} 기록을 마감하고 $targetEndLabel으로 옮겨요',
                            icon: book.everCompleted
                                ? Icons.check_circle_outline_rounded
                                : Icons.flag_outlined,
                            iconColor: book.everCompleted ? accent : sub,
                            inkRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(22),
                            ),
                            onTap: () => Navigator.of(ctx)
                                .pop(TextbookSeasonAction.end),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openAddTextbook() async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const _AddTextbookSheet(),
    );
    if (added == true && mounted) {
      await _refresh();
    }
  }

  ({int percent, String subtitle}) _progressSummary(
      List<StudentTextbook>? books, OrganizedTextbooks? organized) {
    if (books == null || books.isEmpty) {
      return (percent: 0, subtitle: '등록된 교재가 없어요');
    }
    final active = organized?.activeBooks ?? const <StudentTextbook>[];
    if (active.isEmpty) {
      return (
        percent: 0,
        subtitle: '진행 중인 교재가 없어요 · 교재를 길게 눌러 시즌을 시작해요',
      );
    }
    final total = active.fold<int>(0, (s, b) => s + b.totalProblems);
    final done = active.fold<int>(0, (s, b) => s + b.completedCount);
    if (total <= 0) {
      return (percent: 0, subtitle: '진행 중 ${active.length}권 · 문제 집계 대기');
    }
    final percent = ((done * 100) / total).round().clamp(0, 100);
    return (percent: percent, subtitle: '전체 $total문제 중 $done문제 완료');
  }

  Widget _bookCard(StudentTextbook book, double cardWidth) {
    return _BookCard(
      key: ValueKey<String>(
        '${book.bookId}|${book.gradeLabel}|${book.seasonState.name}|${book.seasonNo}',
      ),
      book: book,
      width: cardWidth,
      activeSolveSession: TextbookStudySession.instance.solveSessionFor(
        book.bookId,
        book.gradeLabel,
      ),
      onOpen: () => _openBook(book),
      onLongPress: () => _handleBookLongPress(book),
    );
  }

  Widget _buildSeriesHorizontalRow(TextbookSeriesRow row, double cardWidth) {
    final baseBehavior = ScrollConfiguration.of(context);
    return ScrollConfiguration(
      behavior: baseBehavior.copyWith(
        scrollbars: false,
        dragDevices: {
          ...baseBehavior.dragDevices,
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
        },
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        physics: const BouncingScrollPhysics(),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < row.books.length; i++) ...[
              if (i > 0) const SizedBox(width: _cardGap),
              SizedBox(
                width: cardWidth,
                child: _bookCard(row.books[i], cardWidth),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSeriesStack(
    List<TextbookSeriesRow> seriesRows,
    double cardWidth,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < seriesRows.length; i++) ...[
          if (i > 0) const SizedBox(height: _cardGap),
          _buildSeriesHorizontalRow(seriesRows[i], cardWidth),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final books = _books;
    final organized = books == null ? null : organizeTextbooks(books);
    final summary = _progressSummary(books, organized);

    return StudentCollapsingTitlePage(
      title: '교재 풀기',
      onRefresh: _refresh,
      bodyBuilder: (context, topInset, bottomInset) {
        if (_error != null) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(24, topInset + 20, 24, bottomInset),
            children: [
              StudentProgressSummaryCard(
                percent: summary.percent,
                subtitle: summary.subtitle,
                showInfoIcon: false,
              ),
              const SizedBox(height: 36),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Center(
                child: OutlinedButton(
                  onPressed: _refresh,
                  child: const Text('다시 시도'),
                ),
              ),
            ],
          );
        }
        if (books == null || organized == null) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(24, topInset + 20, 24, bottomInset),
            children: [
              StudentProgressSummaryCard(
                percent: summary.percent,
                subtitle: summary.subtitle,
                showInfoIcon: false,
              ),
              const SizedBox(height: 48),
              const Center(child: YggLoadingIndicator()),
            ],
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            const horizontalPadding = 24.0;
            final availableWidth =
                math.max(1.0, constraints.maxWidth - horizontalPadding * 2);
            final crossAxisCount = math.max(
              1,
              ((availableWidth + _cardGap) / (_cardMaxWidth + _cardGap)).ceil(),
            );
            final cardWidth =
                (availableWidth - _cardGap * (crossAxisCount - 1)) /
                    crossAxisCount;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final dividerColor = isDark
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.black.withValues(alpha: 0.08);

            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                topInset + 20,
                horizontalPadding,
                bottomInset + 24,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  StudentProgressSummaryCard(
                    percent: summary.percent,
                    subtitle: summary.subtitle,
                    showInfoIcon: false,
                  ),
                  const SizedBox(height: 36),
                  Wrap(
                    spacing: _cardGap,
                    runSpacing: _cardGap,
                    children: [
                      for (final book in sortActiveTextbooks([
                        ...organized.activeBooks,
                        ...organized.notStartedBooks,
                      ]))
                        SizedBox(
                          width: cardWidth,
                          child: _bookCard(book, cardWidth),
                        ),
                      SizedBox(
                        width: cardWidth,
                        child: _AddTextbookCard(
                          onTap: _openAddTextbook,
                          includeMetaSpacer: organized.activeBooks.isNotEmpty ||
                              organized.notStartedBooks.isNotEmpty,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 36),
                  Divider(height: 1, thickness: 0.6, color: dividerColor),
                  _TextbookBucketSectionRow(
                    title: '보류',
                    count: organized.pausedBooks.length,
                    expanded: _pausedExpanded,
                    emptyLabel: '보류 중인 문제집이 없어요.',
                    onToggle: () =>
                        setState(() => _pausedExpanded = !_pausedExpanded),
                    child: organized.pausedSeries.isEmpty
                        ? null
                        : _buildSeriesStack(organized.pausedSeries, cardWidth),
                  ),
                  Divider(height: 1, thickness: 0.6, color: dividerColor),
                  _TextbookBucketSectionRow(
                    title: '종료됨',
                    count: organized.endedBooks.length,
                    expanded: _endedExpanded,
                    emptyLabel: '종료된 문제집이 없어요.',
                    onToggle: () =>
                        setState(() => _endedExpanded = !_endedExpanded),
                    child: organized.endedSeries.isEmpty
                        ? null
                        : _buildSeriesStack(organized.endedSeries, cardWidth),
                  ),
                  Divider(height: 1, thickness: 0.6, color: dividerColor),
                  _TextbookBucketSectionRow(
                    title: '완료됨',
                    count: organized.completedBooks.length,
                    expanded: _completedExpanded,
                    emptyLabel: '모두 다 푼 문제집이 아직 없어요.',
                    onToggle: () => setState(
                      () => _completedExpanded = !_completedExpanded,
                    ),
                    child: organized.completedSeries.isEmpty
                        ? null
                        : _buildSeriesStack(
                            organized.completedSeries,
                            cardWidth,
                          ),
                  ),
                  Divider(height: 1, thickness: 0.6, color: dividerColor),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// iOS 사진 앱 스타일의 접이식 분류 행 (`보류`, `종료됨`, `완료됨`).
class _TextbookBucketSectionRow extends StatelessWidget {
  const _TextbookBucketSectionRow({
    required this.title,
    required this.count,
    required this.expanded,
    required this.emptyLabel,
    required this.onToggle,
    this.child,
  });

  final String title;
  final int count;
  final bool expanded;
  final String emptyLabel;
  final VoidCallback onToggle;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final pillBg = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.055);
    final iconColor = count > 0
        ? YggGlassTokens.confirmActionColor
        : theme.hintColor.withValues(alpha: 0.55);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 15),
              child: Row(
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.35,
                    ),
                  ),
                  if (count > 0) ...[
                    const SizedBox(width: 8),
                    Text(
                      '$count',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: theme.hintColor,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                  const Spacer(),
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: pillBg,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      expanded
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.chevron_right_rounded,
                      size: 20,
                      color: iconColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !expanded
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 22),
                  child: child ??
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 8,
                        ),
                        child: Text(
                          emptyLabel,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.hintColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                ),
        ),
      ],
    );
  }
}

class _BookCard extends StatefulWidget {
  const _BookCard({
    super.key,
    required this.book,
    required this.width,
    this.activeSolveSession,
    required this.onOpen,
    required this.onLongPress,
  });

  final StudentTextbook book;
  final double width;
  final ActiveTextbookSession? activeSolveSession;
  final VoidCallback onOpen;
  final VoidCallback onLongPress;

  @override
  State<_BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<_BookCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final book = widget.book;
    final isNotStarted = book.isNotStarted;
    // 진행률(회색) ≥ 완료율(초록) 시각 보장.
    final advance = book.advanceRate.clamp(0.0, 1.0);
    final completion = book.completionRate.clamp(0.0, advance);
    final accuracy = book.accuracyPercent;
    final coverUri = Uri.tryParse(book.coverRef);
    final hasNetworkCover = coverUri != null &&
        (coverUri.scheme == 'http' || coverUri.scheme == 'https');
    final coverColor = book.colorValue == null
        ? const Color(0xFF2B2B2B)
        : Color(book.colorValue!);
    final onDark = hasNetworkCover || coverColor.computeLuminance() <= 0.6;
    final typeScale =
        (widget.width / _coverTypeReferenceWidth).clamp(0.68, 1.0);
    final overlay = CoverOverlayStyle(
      onDark: onDark,
      hasImage: hasNetworkCover,
      typeScale: typeScale,
    );
    const scale = 1.0;
    final pad = CoverOverlayStyle.padFor(scale);
    final gap = CoverOverlayStyle.gapFor(scale);
    final daysLabel = book.isActiveSeason
        ? _daysSinceStartLabel(book.seasonOpenedAt ?? book.startedAt)
        : null;
    final daysPill = daysLabel == null
        ? null
        : CoverPill(
            style: overlay,
            icon: Icons.schedule_rounded,
            label: daysLabel,
            shrinkWrap: true,
          );
    final activeSolve = widget.activeSolveSession;
    final Widget? topLeftPill;
    if (isNotStarted) {
      topLeftPill = CoverPill(
        style: overlay,
        icon: Icons.play_circle_outline_rounded,
        label: '시작 전',
        shrinkWrap: true,
      );
    } else if (book.isPausedSeason) {
      topLeftPill = CoverPill(
        style: overlay,
        icon: Icons.pause_circle_outline_rounded,
        label: '보류',
        shrinkWrap: true,
      );
    } else if (book.isClosedSeason) {
      topLeftPill = book.everCompleted
          ? CoverPill(
              style: overlay,
              tone: CoverPillTone.accent,
              icon: Icons.check_circle_outline_rounded,
              label: '완료됨',
              shrinkWrap: true,
            )
          : CoverPill(
              style: overlay,
              icon: Icons.flag_outlined,
              label: '종료됨',
              shrinkWrap: true,
            );
    } else if (activeSolve != null) {
      topLeftPill = CoverPill(
        style: overlay,
        icon: activeSolve.isPaused
            ? Icons.pause_circle_outline_rounded
            : Icons.play_circle_outline_rounded,
        label: activeSolve.isPaused ? '중단' : '풀이중',
        shrinkWrap: true,
      );
    } else {
      topLeftPill = null;
    }

    Widget coverSurface = hasNetworkCover
        ? Image.network(
            book.coverRef,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _CoverFallback(color: coverColor),
          )
        : _CoverFallback(color: coverColor);

    if (isNotStarted) {
      coverSurface = Stack(
        fit: StackFit.expand,
        children: [
          coverSurface,
          const ColoredBox(color: Color(0x24FFFFFF)),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 커버 탭 → 교재 열기, 길게 누르기 → 시즌 시작/보류/재개/종료
        Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onOpen,
              onLongPress: widget.onLongPress,
              borderRadius: BorderRadius.circular(_cardRadius),
              child: AspectRatio(
                aspectRatio: 1 / _coverA4Ratio,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(_cardRadius),
                    boxShadow: const [
                      BoxShadow(color: Color(0x1A000000), blurRadius: 14),
                      BoxShadow(
                        color: Color(0x29000000),
                        blurRadius: 18,
                        spreadRadius: -2,
                        offset: Offset(3, 7),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(_cardRadius),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        coverSurface,
                        Positioned.fill(
                          child: CoverScrim(style: overlay, showTop: false),
                        ),
                        Positioned.fill(
                          child: CoverHairline(
                            style: overlay,
                            radius: _cardRadius,
                          ),
                        ),
                        if (topLeftPill != null)
                          Positioned(
                            left: pad,
                            top: pad,
                            child: topLeftPill,
                          ),
                        if (daysPill != null)
                          Positioned(
                            right: pad,
                            top: pad,
                            child: daysPill,
                          ),
                        Positioned(
                          left: pad,
                          right: pad,
                          bottom: pad,
                          child: _CoverFactBlock(
                            overlay: overlay,
                            advance: advance,
                            completion: completion,
                            gradeLabel: book.gradeLabel.trim(),
                            seasonLabel:
                                isNotStarted ? '시작 전' : '시즌 ${book.seasonNo}',
                            gap: gap,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: _coverToMetaSpacing),
        // 메타 탭 → 상세 시트 펼침/접기 (커버와 분리)
        Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(14),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: _cardMetaHeight),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final grade = book.gradeLabel.trim();
                        return Row(
                          children: [
                            Expanded(
                              child: Text(
                                book.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.2,
                                ),
                              ),
                            ),
                            if (grade.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: math.max(
                                    0,
                                    constraints.maxWidth * 0.46,
                                  ),
                                ),
                                child: _GradePill(label: grade),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text.rich(
                          TextSpan(
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 14.5,
                              color: theme.hintColor,
                              fontWeight: FontWeight.w600,
                            ),
                            children: [
                              const TextSpan(text: '정답률 '),
                              TextSpan(
                                text: accuracy == null ? '-' : '$accuracy%',
                                style: const TextStyle(letterSpacing: -1.0),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),
                        AnimatedRotation(
                          turns: _expanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 26,
                            color: theme.hintColor,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _expanded
              ? _BookDetailSheet(book: book, completion: completion)
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

class _CoverFallback extends StatelessWidget {
  const _CoverFallback({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(color: color);
  }
}

String? _daysSinceStartLabel(DateTime? startedAt) {
  if (startedAt == null) return null;
  final startDate = DateTime(startedAt.year, startedAt.month, startedAt.day);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final days = math.max(1, today.difference(startDate).inDays + 1);
  return '$days일째';
}

/// 표지 아래쪽: 학년·시즌 배지, 그 아래 완료율 막대.
class _CoverFactBlock extends StatelessWidget {
  const _CoverFactBlock({
    required this.overlay,
    required this.advance,
    required this.completion,
    required this.gradeLabel,
    required this.seasonLabel,
    required this.gap,
  });

  final CoverOverlayStyle overlay;
  final double advance;
  final double completion;
  final String gradeLabel;
  final String seasonLabel;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (gradeLabel.isNotEmpty)
              Flexible(
                child: CoverPill(
                  style: overlay,
                  label: gradeLabel,
                  loose: true,
                ),
              ),
            if (gradeLabel.isNotEmpty) SizedBox(width: gap),
            Flexible(
              child: CoverPill(
                style: overlay,
                label: seasonLabel,
                loose: true,
              ),
            ),
          ],
        ),
        SizedBox(height: gap + 2),
        _CoverCompletionBar(
          overlay: overlay,
          advance: advance,
          completion: completion,
        ),
      ],
    );
  }
}

/// 표지 위 완료율. 회색 진행 위에 초록 완료를 겹친다.
class _CoverCompletionBar extends StatelessWidget {
  const _CoverCompletionBar({
    required this.overlay,
    required this.advance,
    required this.completion,
  });

  final CoverOverlayStyle overlay;
  final double advance;
  final double completion;

  @override
  Widget build(BuildContext context) {
    final scale = overlay.typeScale;
    final a = advance.clamp(0.0, 1.0);
    final c = completion.clamp(0.0, a);
    final onDark = overlay.onDark;
    final labelStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontWeight: FontWeight.w700,
      fontSize: (14 * scale).clamp(12.0, 14.0),
      height: 1.0,
      letterSpacing: -0.2 * scale,
      color: overlay.ink,
      shadows: overlay.textShadows,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Row(
      children: [
        Text('완료', style: labelStyle),
        SizedBox(width: 8 * scale),
        Expanded(
          child: _LayeredProgressBar(
            advance: a,
            completion: c,
            height: (6 * scale).clamp(4.0, 6.0),
            trackColor: onDark ? Colors.white24 : Colors.black12,
            advanceColor: onDark ? const Color(0x99FFFFFF) : Colors.black26,
            completionColor: YggGlassTokens.confirmActionColor,
          ),
        ),
        SizedBox(width: 8 * scale),
        Text('${(c * 100).round()}%', style: labelStyle),
      ],
    );
  }
}

class _GradePill extends StatelessWidget {
  const _GradePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.black.withValues(alpha: 0.08),
          width: 0.5,
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface,
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          height: 1.0,
        ),
      ),
    );
  }
}

String _completionEstimateLabel(StudentTextbook book, double completion) {
  if (completion >= 1) return '완주 완료';
  final startedAt = book.startedAt;
  if (startedAt == null || book.correctCount < 5 || completion <= 0) {
    return '예상 약 6개월';
  }

  final elapsedDays =
      math.max(1, DateTime.now().difference(startedAt).inDays + 1);
  final observedTotalDays = elapsedDays / completion;
  final evidenceWeight = (book.correctCount / 30).clamp(0.0, 1.0);
  final estimatedDays =
      (180 * (1 - evidenceWeight) + observedTotalDays * evidenceWeight)
          .clamp(14.0, 730.0);
  final months = estimatedDays / 30.4375;
  final differenceWeeks = ((180 - estimatedDays) / 7).round();
  final comparison = differenceWeeks == 0
      ? '6개월 기준과 비슷'
      : differenceWeeks > 0
          ? '기준보다 $differenceWeeks주 빠름'
          : '기준보다 ${differenceWeeks.abs()}주 느림';
  return '예상 ${months.toStringAsFixed(1)}개월 · $comparison';
}

/// 단계별 진행률을 따로 보여 줄 단계형 문제집의 슬롯 글자.
///
/// 쎈·고쟁이 고등은 A/B/C 세 단계이고, 고쟁이는 STEP 셋에 창의융합(D)이 더 붙는다. 워크북
/// TEST(E·F)는 교재에 따라 없기도 해서, 실제로 문항이 잡힌 슬롯만 덧붙인다.
List<String> _stageProgressLetters(StudentTextbook book) {
  switch (book.series) {
    case 'ssen':
    case 'gojaengi_high':
      return const ['A', 'B', 'C'];
    case 'gojaengi':
      return <String>[
        'A',
        'B',
        'C',
        'D',
        for (final slot in const ['E', 'F'])
          if ((book.stageProgress[slot]?.total ?? 0) > 0) slot,
      ];
    default:
      return const <String>[];
  }
}

/// 메타 아래 펼침 — 4지표 + 예상 개월수 + 단계별 진행률.
class _BookDetailSheet extends StatelessWidget {
  const _BookDetailSheet({
    required this.book,
    required this.completion,
  });

  final StudentTextbook book;
  final double completion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final advancePct = (book.advanceRate * 100).round();
    final completionPct = (book.completionRate * 100).round();
    final accuracy =
        book.accuracyPercent == null ? '-' : '${book.accuracyPercent}%';
    final revision =
        book.revisionPercent == null ? '-' : '${book.revisionPercent}%';
    final stageLetters = _stageProgressLetters(book);

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _RateChip(label: '진행률', value: '$advancePct%'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _RateChip(label: '완료율', value: '$completionPct%'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _RateChip(label: '정답률', value: accuracy),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _RateChip(label: '수정률', value: revision),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _completionEstimateLabel(book, completion),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontSize: 13.5,
            ),
          ),
          if (stageLetters.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final stage in stageLetters) ...[
              _SheetProgressRow(
                label: stage,
                advance: () {
                  final s = book.stageProgress[stage];
                  if (s == null || s.total <= 0) return 0.0;
                  return (s.graded / s.total).clamp(0.0, 1.0);
                }(),
                completion: book.stageProgress[stage]?.progress ?? 0,
              ),
              if (stage != stageLetters.last) const SizedBox(height: 6),
            ],
          ],
        ],
      ),
    );
  }
}

class _RateChip extends StatelessWidget {
  const _RateChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text.rich(
        TextSpan(
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: theme.hintColor,
          ),
          children: [
            TextSpan(text: '$label '),
            TextSpan(
              text: value,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: theme.colorScheme.onSurface,
                letterSpacing: -1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetProgressRow extends StatelessWidget {
  const _SheetProgressRow({
    required this.label,
    required this.advance,
    required this.completion,
  });

  final String label;
  final double advance;
  final double completion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = advance.clamp(0.0, 1.0);
    final c = completion.clamp(0.0, a);
    return Row(
      children: [
        SizedBox(
          width: 22,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
            ),
          ),
        ),
        Expanded(
          child: _LayeredProgressBar(
            advance: a,
            completion: c,
            height: 6,
            trackColor: theme.brightness == Brightness.dark
                ? Colors.white12
                : Colors.black12,
            advanceColor: theme.brightness == Brightness.dark
                ? Colors.white38
                : Colors.black26,
            completionColor: YggGlassTokens.confirmActionColor,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 36,
          child: Text(
            '${(c * 100).round()}%',
            textAlign: TextAlign.right,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: -0.8,
            ),
          ),
        ),
      ],
    );
  }
}

/// 회색(진행률) 위에 초록(완료율)을 겹친 바.
class _LayeredProgressBar extends StatelessWidget {
  const _LayeredProgressBar({
    required this.advance,
    required this.completion,
    required this.height,
    required this.trackColor,
    required this.advanceColor,
    required this.completionColor,
  });

  final double advance;
  final double completion;
  final double height;
  final Color trackColor;
  final Color advanceColor;
  final Color completionColor;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: trackColor),
            FractionallySizedBox(
              widthFactor: advance.clamp(0.0, 1.0),
              alignment: Alignment.centerLeft,
              child: ColoredBox(color: advanceColor),
            ),
            FractionallySizedBox(
              widthFactor: completion.clamp(0.0, 1.0),
              alignment: Alignment.centerLeft,
              child: ColoredBox(color: completionColor),
            ),
          ],
        ),
      ),
    );
  }
}

/// 교재 카드와 같은 A4·radius 슬롯 — 배경 투명 + 점선 테두리.
class _AddTextbookCard extends StatelessWidget {
  const _AddTextbookCard({
    required this.onTap,
    this.includeMetaSpacer = true,
  });

  final VoidCallback onTap;
  final bool includeMetaSpacer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.28)
        : Colors.black.withValues(alpha: 0.22);
    final fg = isDark ? Colors.white70 : Colors.black54;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 하이라이트는 커버(점선 카드)만 — 아래 메타 자리 여백은 제외.
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(_cardRadius),
            child: AspectRatio(
              aspectRatio: 1 / _coverA4Ratio,
              child: CustomPaint(
                painter: _DashedRRectPainter(
                  color: borderColor,
                  radius: _cardRadius,
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_rounded, size: 40, color: fg),
                      const SizedBox(height: 8),
                      Text(
                        '교재 추가',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: fg,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (includeMetaSpacer) ...[
          const SizedBox(height: _coverToMetaSpacing),
          const SizedBox(height: _cardMetaHeight),
        ],
      ],
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({
    required this.color,
    required this.radius,
  });

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(1, 1, size.width - 2, size.height - 2),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      const dash = 7.0;
      const gap = 5.0;
      while (distance < metric.length) {
        final next = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}

/// 마이그레이션된 교재 목록에서 셀프 등록.
class _AddTextbookSheet extends StatefulWidget {
  const _AddTextbookSheet();

  @override
  State<_AddTextbookSheet> createState() => _AddTextbookSheetState();
}

class _AddTextbookSheetState extends State<_AddTextbookSheet> {
  List<AvailableTextbook>? _available;
  String? _error;
  String? _enrollingKey;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _available = null;
    });
    try {
      final list = await TextbookApi.instance.listAvailableTextbooks();
      if (!mounted) return;
      setState(() => _available = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '추가할 교재를 불러오지 못했어요.\n$e');
    }
  }

  Future<void> _enroll(AvailableTextbook book) async {
    final key = '${book.bookId}|${book.gradeLabel}';
    if (_enrollingKey != null) return;
    setState(() => _enrollingKey = key);
    try {
      await TextbookApi.instance.enrollTextbook(
        bookId: book.bookId,
        gradeLabel: book.gradeLabel,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _enrollingKey = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('교재를 추가하지 못했어요.\n$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final height = MediaQuery.sizeOf(context).height * 0.78;

    return Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: height,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.28)
                      : Colors.black.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '교재 추가',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '닫기',
                      onPressed: () => Navigator.of(context).pop(false),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  '정답이 준비된 교재를 골라 내 목록에 넣어요. 추가한 날부터 시작일이 계산돼요.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _buildBody(theme)),
              SizedBox(height: bottom + 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final list = _available;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('다시 시도')),
            ],
          ),
        ),
      );
    }
    if (list == null) {
      return const Center(child: YggLoadingIndicator());
    }
    if (list.isEmpty) {
      return Center(
        child: Text(
          '추가할 수 있는 교재가 없어요.\n이미 모두 추가했거나, 아직 준비된 교재가 없어요.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(color: theme.hintColor),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final book = list[i];
        final key = '${book.bookId}|${book.gradeLabel}';
        final busy = _enrollingKey == key;
        final coverUri = Uri.tryParse(book.coverRef);
        final hasCover = coverUri != null &&
            (coverUri.scheme == 'http' || coverUri.scheme == 'https');
        final coverColor = book.colorValue == null
            ? const Color(0xFF2B2B2B)
            : Color(book.colorValue!);

        return Material(
          color: theme.brightness == Brightness.dark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: busy || _enrollingKey != null ? null : () => _enroll(book),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 52,
                      height: 52 * _coverA4Ratio,
                      child: hasCover
                          ? Image.network(
                              book.coverRef,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  ColoredBox(color: coverColor),
                            )
                          : ColoredBox(color: coverColor),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          book.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          [
                            if (book.gradeLabel.trim().isNotEmpty)
                              book.gradeLabel.trim(),
                            '문항 ${book.totalProblems}',
                          ].join(' · '),
                          style: TextStyle(
                            color: theme.hintColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (busy)
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  else
                    const Icon(
                      Icons.add_circle_outline_rounded,
                      color: YggGlassTokens.confirmActionColor,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
