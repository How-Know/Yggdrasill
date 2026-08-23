import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/homework_session.dart';
import '../services/student_api.dart';
import '../services/textbook_api.dart';
import '../widgets/student_confirm_sheet.dart';
import 'textbook_solve_screen.dart';

/// 문항 스냅샷이 있는 교재 숙제를 배정 범위만 교재 풀이 화면에서 연다.
///
/// 과제 목록 카드와 재생(Now Playing) 시트 양쪽에서 같은 경로를 쓴다.
/// 문항이 없거나 출력물/미마이그레이션 과제면 false를 반환해 기존 공용
/// phase 타이머 경로로 이어 간다.
Future<bool> openDigitalHomeworkSolve(
  BuildContext context,
  HomeworkGroup group, {
  String? coverRef,
}) async {
  // 시간제한 테스트는 초기 V0에서 `프린트` 유형으로 잘못 저장된 기존 과제도
  // 문항 스냅샷이 있으면 전용 시험 화면으로 복구해 연다.
  if (!group.isTimedTest && (!group.digitalSolvable || group.isPrintSource)) {
    return false;
  }

  try {
    final problems =
        await StudentApi.instance.listHomeworkProblems(group.groupId);
    final usable = problems
        .where((problem) =>
            problem.cropId.trim().isNotEmpty && problem.rawPage != null)
        .toList(growable: false);
    if (usable.isEmpty) return false;

    if (group.isTimedTest) {
      if (!context.mounted) return true;
      final start = await showStudentConfirmSheet(
        context: context,
        title: '시간제한 테스트',
        message: '제한시간은 ${group.timeLimitMinutes}분이에요.\n'
            '첫 문항이 준비된 뒤 시간이 시작되며, 앱을 나가도 시간은 계속 흘러요.\n\n'
            '제출하거나 다음 문제로 넘어가면 이전 문제로 돌아갈 수 없고, '
            '답 없이 넘어간 문제는 오답으로 처리돼요.',
        confirmLabel: '테스트 시작',
        cancelLabel: '취소',
        confirmIcon: Icons.timer_outlined,
      );
      if (!start || !context.mounted) return true;
    }

    final books = await TextbookApi.instance.listTextbooks();
    final first = usable.first;
    StudentTextbook? book;
    for (final candidate in books) {
      if (candidate.bookId == first.bookId &&
          candidate.gradeLabel == first.gradeLabel) {
        book = candidate;
        break;
      }
    }
    if (book == null) {
      // 표지: 호출부가 준 값 → 같은 책의 다른 판(grade_label) → 없음.
      var resolvedCover = coverRef ?? '';
      if (resolvedCover.isEmpty) {
        for (final candidate in books) {
          if (candidate.bookId == first.bookId &&
              candidate.coverRef.isNotEmpty) {
            resolvedCover = candidate.coverRef;
            break;
          }
        }
      }
      book = StudentTextbook(
        bookId: first.bookId,
        gradeLabel: first.gradeLabel,
        name: group.sourceLabel.isEmpty ? group.title : group.sourceLabel,
        description: '',
        colorValue: group.color,
        series: '',
        coverRef: resolvedCover,
        totalProblems: usable.length,
        gradedCount: 0,
        correctCount: 0,
        completedCount: 0,
        firstWrongCount: 0,
        correctedCount: 0,
        stageProgress: const {},
      );
    }

    final scope = HomeworkSolveScope(
      groupId: group.groupId,
      title: group.title,
      cropIds: usable.map((problem) => problem.cropId).toSet(),
      rawPages: usable.map((problem) => problem.rawPage!).toSet(),
    );
    if (!context.mounted) return true;
    if (group.isTimedTest) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => TextbookSolveScreen(
            book: book!,
            homework: scope,
            timedTest: TimedTestSolveConfig(
              group: group,
              problems: usable,
            ),
          ),
        ),
      );
      await HomeworkSession.instance.refresh();
      return true;
    }
    if (!group.running && (group.phase == 1 || group.phase == 2)) {
      final result = await StudentApi.instance.groupTransition(
        groupId: group.groupId,
        fromPhase: 1,
      );
      if (result['ok'] != true && result['error'] != 'phase_mismatch') {
        if (context.mounted) {
          TopGlassSnackBar.show(
            context,
            message: '숙제 수행을 시작하지 못했어요.',
            icon: Icons.error_outline_rounded,
          );
        }
        return true;
      }
      await HomeworkSession.instance.refresh();
    }
    if (!context.mounted) return true;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TextbookSolveScreen(
          book: book!,
          homework: scope,
        ),
      ),
    );
    await HomeworkSession.instance.refresh();
    return true;
  } catch (_) {
    if (group.isTimedTest) {
      if (context.mounted) {
        TopGlassSnackBar.show(
          context,
          message: '시간제한 테스트를 열지 못했어요. 잠시 후 다시 시도해 주세요.',
          icon: Icons.error_outline_rounded,
        );
      }
      return true;
    }
    // 문항 RPC가 없거나 legacy 과제면 기존 phase 타이머로 폴백한다.
    return false;
  }
}
