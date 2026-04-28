import 'package:flutter/material.dart';

import '../app_overlays.dart';
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

    await Future.wait(
      checkTargetKeys.map((key) async {
        final target = await _resolveHomeworkCheckTarget(
          key.studentId,
          key.itemId,
          includeHistory: false,
        );
        if (target == null) return;
        await HomeworkAssignmentStore.instance.saveAssignmentCheck(
          assignmentId: target.assignmentId,
          studentId: key.studentId,
          homeworkItemId: key.itemId,
          progress: target.progress,
          issueType: null,
          issueNote: null,
          markCompleted: false,
        );
      }),
    );

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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${pending.length}건의 과제를 일괄 처리했어요.')),
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
