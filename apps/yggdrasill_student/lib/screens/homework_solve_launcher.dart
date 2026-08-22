import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/homework_session.dart';
import '../services/student_api.dart';
import '../services/textbook_api.dart';
import 'timed_test_solve_screen.dart';
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
  if (!group.digitalSolvable || group.isPrintSource) return false;

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
      final start = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('시간제한 테스트'),
          content: Text(
            '제한시간은 ${group.timeLimitMinutes}분이에요.\n'
            '시작하면 앱을 나가도 시간이 계속 흐르고, 이 과제는 한 번만 응시할 수 있어요.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('시작'),
            ),
          ],
        ),
      );
      if (start != true || !context.mounted) return true;
      final session =
          await StudentApi.instance.startOrResumeTimedTest(group.groupId);
      if (!context.mounted) return true;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => TimedTestSolveScreen(
            group: group,
            problems: usable,
            session: session,
          ),
        ),
      );
      await HomeworkSession.instance.refresh();
      return true;
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
