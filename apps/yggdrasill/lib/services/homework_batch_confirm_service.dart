import 'package:flutter/material.dart';

import '../app_overlays.dart';
import '../widgets/app_snackbar.dart';
import 'homework_assignment_store.dart';
import 'homework_store.dart';

typedef HomeworkBatchConfirmKey = ({String studentId, String itemId});

class HomeworkBatchConfirmService {
  HomeworkBatchConfirmService._();

  static final HomeworkBatchConfirmService instance =
      HomeworkBatchConfirmService._();

  final Map<HomeworkBatchConfirmKey, bool> _pending = {};

  Map<HomeworkBatchConfirmKey, bool> get pending => _pending;

  int get pendingCount => _pending.length;

  void syncPendingCount() {
    final count = _pending.length;
    if (homeBatchConfirmPendingCount.value != count) {
      homeBatchConfirmPendingCount.value = count;
    }
  }

  void clearPending() {
    if (_pending.isEmpty) {
      syncPendingCount();
      return;
    }
    _pending.clear();
    syncPendingCount();
  }

  Future<void> executePendingBatchConfirm({
    required BuildContext context,
  }) async {
    if (_pending.isEmpty) {
      syncPendingCount();
      return;
    }
    final pending = Map<HomeworkBatchConfirmKey, bool>.from(_pending);
    _pending.clear();
    syncPendingCount();
    await _processBatchConfirmInBackground(
      context: context,
      pending: pending,
    );
  }

  Future<void> executeBatchConfirmNow({
    required BuildContext context,
    required Map<HomeworkBatchConfirmKey, bool> pending,
  }) async {
    if (pending.isEmpty) return;
    await _processBatchConfirmInBackground(
      context: context,
      pending: Map<HomeworkBatchConfirmKey, bool>.from(pending),
    );
  }

  Future<void> _processBatchConfirmInBackground({
    required BuildContext context,
    required Map<HomeworkBatchConfirmKey, bool> pending,
  }) async {
    final confirmIdsByStudent = <String, Set<String>>{};
    final checkTargetKeys = <HomeworkBatchConfirmKey>{};
    final fallbackEntries = <MapEntry<HomeworkBatchConfirmKey, bool>>[];

    for (final entry in pending.entries) {
      final key = entry.key;
      final hw = HomeworkStore.instance.getById(key.studentId, key.itemId);
      if (hw == null) continue;
      // '완료'(value=true)면 완료 예정만 마킹한다.
      // confirmBatch가 pending_complete를 서버에 올리고 확인(phase 4)으로 보낸다.
      // 실제 완료는 학생이 확인 카드를 탭한 뒤 대기 진입 시 자동 처리한다.
      if (entry.value) {
        HomeworkStore.instance.markAutoCompleteOnNextWaiting(key.itemId);
      }
      checkTargetKeys.add(key);
      if (hw.phase == 3) {
        confirmIdsByStudent
            .putIfAbsent(key.studentId, () => <String>{})
            .add(key.itemId);
      } else {
        fallbackEntries.add(entry);
      }
    }

    // 활성 assignment가 confirm/outcome으로 먼저 사라지면 검사 기록이 누락된다.
    // 확인 RPC보다 먼저, 필요 시 history assignment까지 포함해 오늘 검사 이력을 남긴다.
    await Future.wait(
      checkTargetKeys.map((key) async {
        final markCompleted = pending[key] == true;
        final target = await _resolveHomeworkCheckTarget(
          key.studentId,
          key.itemId,
          includeHistory: true,
        );
        if (target == null) return;
        final hasActive = await _hasActiveAssignmentForItem(
          key.studentId,
          key.itemId,
          target.assignmentId,
        );
        if (hasActive) {
          await HomeworkAssignmentStore.instance.saveAssignmentCheck(
            assignmentId: target.assignmentId,
            studentId: key.studentId,
            homeworkItemId: key.itemId,
            progress: target.progress,
            issueType: null,
            issueNote: null,
            markCompleted: markCompleted,
          );
          return;
        }
        // 이미 완료/해제된 assignment라도 오늘 검사 진행률은 동기화한다.
        await HomeworkAssignmentStore.instance.syncCheckProgressFromGrading(
          studentId: key.studentId,
          homeworkItemId: key.itemId,
          assignmentId: target.assignmentId,
          progress: target.progress,
        );
      }),
    );

    if (confirmIdsByStudent.isNotEmpty) {
      await Future.wait(
        confirmIdsByStudent.entries.map(
          (entry) => HomeworkStore.instance.confirmBatch(
            entry.key,
            entry.value,
            recordAssignmentCheck: false,
          ),
        ),
      );
    }

    for (final entry in fallbackEntries) {
      final key = entry.key;
      HomeworkStore.instance.restoreItemsToWaiting(
        key.studentId,
        [key.itemId],
      );
      await HomeworkStore.instance.placeItemAtActiveTail(
        key.studentId,
        key.itemId,
        activateFromHomework: true,
      );
      await HomeworkAssignmentStore.instance.clearActiveAssignmentsForItems(
        key.studentId,
        [key.itemId],
      );
    }

    if (!context.mounted) return;
    showAppSnackBar(context, '${pending.length}건의 과제를 일괄 처리했어요.');
  }

  Future<bool> _hasActiveAssignmentForItem(
    String studentId,
    String homeworkItemId,
    String assignmentId,
  ) async {
    final active =
        await HomeworkAssignmentStore.instance.loadActiveAssignments(studentId);
    return active.any(
      (a) => a.id == assignmentId && a.homeworkItemId == homeworkItemId,
    );
  }

  Future<_HomeworkCheckTarget?> _resolveHomeworkCheckTarget(
    String studentId,
    String homeworkItemId, {
    bool includeHistory = true,
  }) async {
    final active =
        await HomeworkAssignmentStore.instance.loadActiveAssignments(studentId);
    final activeCandidates = active
        .where((a) => a.homeworkItemId == homeworkItemId)
        .toList(growable: false)
      ..sort((a, b) => a.assignedAt.compareTo(b.assignedAt));
    if (activeCandidates.isNotEmpty) {
      final target = activeCandidates.last;
      return _HomeworkCheckTarget(
        assignmentId: target.id,
        progress: target.progress,
      );
    }

    if (!includeHistory) return null;

    final history = await HomeworkAssignmentStore.instance
        .loadAssignmentsForItem(studentId, homeworkItemId);
    if (history.isEmpty) return null;
    history.sort((a, b) => a.assignedAt.compareTo(b.assignedAt));
    final target = history.last;
    return _HomeworkCheckTarget(
      assignmentId: target.id,
      progress: target.progress,
    );
  }
}

class _HomeworkCheckTarget {
  final String assignmentId;
  final int progress;

  const _HomeworkCheckTarget({
    required this.assignmentId,
    required this.progress,
  });
}
