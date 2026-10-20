import 'package:flutter/material.dart';

import '../app_overlays.dart';
import '../widgets/app_snackbar.dart';
import 'homework_assignment_store.dart';
import 'homework_grading_lock_service.dart';
import 'homework_grading_return_outbox_service.dart';
import 'homework_store.dart';

typedef HomeworkBatchConfirmKey = ({String studentId, String itemId});

class HomeworkBatchConfirmService {
  HomeworkBatchConfirmService._();

  static final HomeworkBatchConfirmService instance =
      HomeworkBatchConfirmService._();

  final Map<HomeworkBatchConfirmKey, bool> _pending = {};
  final Map<HomeworkBatchConfirmKey, int> _savingDraftCounts =
      <HomeworkBatchConfirmKey, int>{};

  /// 홈 완료 버튼으로 서버에 반영 중인 과제.
  final ValueNotifier<Set<HomeworkBatchConfirmKey>> confirmingKeys =
      ValueNotifier<Set<HomeworkBatchConfirmKey>>(<HomeworkBatchConfirmKey>{});

  Map<HomeworkBatchConfirmKey, bool> get pending => _pending;

  int get pendingCount => _pending.length;

  Future<Set<HomeworkBatchConfirmKey>> restoreStructuredDrafts() async {
    await HomeworkGradingReturnOutboxService.instance.initialize();
    await HomeworkGradingLockService.instance.restoreDraftLeases();
    final restored =
        HomeworkGradingReturnOutboxService.instance.pendingValues();
    _pending.addAll(restored);
    syncPendingCount();
    return HomeworkGradingReturnOutboxService.instance.structuredKeys();
  }

  void syncPendingCount() {
    final count = _pending.length;
    if (homeBatchConfirmPendingCount.value != count) {
      homeBatchConfirmPendingCount.value = count;
    }
    final savingCount = _savingDraftCounts.length;
    if (homeBatchConfirmDraftSavingCount.value != savingCount) {
      homeBatchConfirmDraftSavingCount.value = savingCount;
    }
  }

  void beginStructuredDraftSave(Iterable<HomeworkBatchConfirmKey> keys) {
    for (final key in keys) {
      _savingDraftCounts[key] = (_savingDraftCounts[key] ?? 0) + 1;
      _pending.remove(key);
    }
    syncPendingCount();
  }

  void endStructuredDraftSave(Iterable<HomeworkBatchConfirmKey> keys) {
    for (final key in keys) {
      final next = (_savingDraftCounts[key] ?? 1) - 1;
      if (next <= 0) {
        _savingDraftCounts.remove(key);
      } else {
        _savingDraftCounts[key] = next;
      }
    }
    syncPendingCount();
  }

  Map<HomeworkBatchConfirmKey, bool> _withoutSavingDrafts(
    Map<HomeworkBatchConfirmKey, bool> pending,
  ) {
    return <HomeworkBatchConfirmKey, bool>{
      for (final entry in pending.entries)
        if ((_savingDraftCounts[entry.key] ?? 0) <= 0) entry.key: entry.value,
    };
  }

  void clearPending() {
    final durable = HomeworkGradingReturnOutboxService.instance.pendingValues();
    _pending
      ..clear()
      ..addAll(durable);
    syncPendingCount();
  }

  Future<void> enqueueStructuredDraft(Map<String, dynamic> payload) async {
    final lockedPayload =
        HomeworkGradingLockService.instance.attachOwnedLockToken(payload);
    await HomeworkGradingReturnOutboxService.instance.enqueue(lockedPayload);
    _pending.addAll(
      HomeworkGradingReturnOutboxService.instance.pendingValues(),
    );
    syncPendingCount();
  }

  Future<bool> removeStructuredDrafts(
    Iterable<HomeworkBatchConfirmKey> keys,
  ) async {
    final list = keys.toList(growable: false);
    if (!HomeworkGradingReturnOutboxService.instance.containsAny(list)) {
      return false;
    }
    await HomeworkGradingReturnOutboxService.instance.removeForKeys(list);
    await HomeworkGradingLockService.instance.releaseForKeys(list);
    for (final key in list) {
      _pending.remove(key);
    }
    syncPendingCount();
    return true;
  }

  Future<void> executePendingBatchConfirm({
    required BuildContext context,
  }) async {
    await restoreStructuredDrafts();
    if (_pending.isEmpty) {
      syncPendingCount();
      return;
    }
    final pending = _withoutSavingDrafts(
      Map<HomeworkBatchConfirmKey, bool>.from(_pending),
    );
    if (pending.isEmpty) {
      syncPendingCount();
      return;
    }

    // 버튼을 누른 즉시 체크를 화면에서 치운다. 실패한 항목만 아래에서 복원한다.
    for (final key in pending.keys) {
      _pending.remove(key);
    }
    syncPendingCount();
    _markConfirming(pending.keys);
    try {
      await _executePendingBatchConfirmBody(context: context, pending: pending);
    } finally {
      _unmarkConfirming(pending.keys);
    }
  }

  void _markConfirming(Iterable<HomeworkBatchConfirmKey> keys) {
    confirmingKeys.value = <HomeworkBatchConfirmKey>{
      ...confirmingKeys.value,
      ...keys,
    };
  }

  void _unmarkConfirming(Iterable<HomeworkBatchConfirmKey> keys) {
    confirmingKeys.value = <HomeworkBatchConfirmKey>{
      ...confirmingKeys.value,
    }..removeAll(keys);
  }

  Future<void> _executePendingBatchConfirmBody({
    required BuildContext context,
    required Map<HomeworkBatchConfirmKey, bool> pending,
  }) async {
    late final HomeworkGradingReturnProcessResult structuredResult;
    try {
      structuredResult =
          await HomeworkGradingReturnOutboxService.instance.processForKeys(
        pending.keys,
      );
    } catch (error, stackTrace) {
      debugPrint('[HW][batch_confirm:outbox][ERROR] $error\n$stackTrace');
      _pending.addAll(pending);
      syncPendingCount();
      if (context.mounted) {
        showAppSnackBar(
          context,
          '채점 반환을 시작하지 못했습니다. 기록은 보관되어 다시 시도할 수 있어요.',
        );
      }
      return;
    }
    for (final key in structuredResult.failedKeys) {
      final value = pending[key];
      if (value != null) _pending[key] = value;
    }
    HomeworkGradingLockService.instance
        .forgetKeys(structuredResult.succeededKeys);
    final legacyPending = <HomeworkBatchConfirmKey, bool>{
      for (final entry in pending.entries)
        if (!structuredResult.succeededKeys.contains(entry.key) &&
            !structuredResult.failedKeys.contains(entry.key))
          entry.key: entry.value,
    };
    var legacySucceededCount = 0;
    if (legacyPending.isNotEmpty) {
      if (!context.mounted) {
        _pending.addAll(legacyPending);
        syncPendingCount();
        return;
      }
      try {
        await _processBatchConfirmInBackground(
          context: context,
          pending: legacyPending,
        );
        legacySucceededCount = legacyPending.length;
      } catch (error, stackTrace) {
        debugPrint('[HW][batch_confirm][ERROR] $error\n$stackTrace');
        _pending.addAll(legacyPending);
      }
    }
    syncPendingCount();
    if (structuredResult.succeededKeys.isNotEmpty) {
      HomeworkAssignmentStore.instance.invalidateActiveAssignments();
      final studentIds =
          structuredResult.succeededKeys.map((key) => key.studentId).toSet();
      await Future.wait(
        studentIds.map(HomeworkStore.instance.reloadStudentHomework),
      );
    }
    if (context.mounted) {
      final succeededCount =
          structuredResult.succeededKeys.length + legacySucceededCount;
      final failedCount = pending.length - succeededCount;
      if (failedCount > 0) {
        showAppSnackBar(
          context,
          succeededCount > 0
              ? '$succeededCount건을 처리했고, $failedCount건은 실패해 다시 시도할 수 있어요.'
              : '채점 반환에 실패했습니다. 기록은 이 PC에 보관되어 다시 시도할 수 있어요.',
        );
      } else {
        showAppSnackBar(context, '$succeededCount건의 채점을 완료했습니다.');
      }
    }
  }

  Future<void> executeBatchConfirmNow({
    required BuildContext context,
    required Map<HomeworkBatchConfirmKey, bool> pending,
  }) async {
    final readyPending = _withoutSavingDrafts(pending);
    if (readyPending.isEmpty) return;
    await restoreStructuredDrafts();
    final structuredResult =
        await HomeworkGradingReturnOutboxService.instance.processForKeys(
      readyPending.keys,
    );
    for (final key in structuredResult.succeededKeys) {
      _pending.remove(key);
    }
    HomeworkGradingLockService.instance
        .forgetKeys(structuredResult.succeededKeys);
    final legacyPending = <HomeworkBatchConfirmKey, bool>{
      for (final entry in readyPending.entries)
        if (!structuredResult.succeededKeys.contains(entry.key) &&
            !structuredResult.failedKeys.contains(entry.key))
          entry.key: entry.value,
    };
    if (legacyPending.isNotEmpty) {
      if (!context.mounted) return;
      await _processBatchConfirmInBackground(
        context: context,
        pending: legacyPending,
      );
    }
    if (structuredResult.succeededKeys.isNotEmpty) {
      HomeworkAssignmentStore.instance.invalidateActiveAssignments();
      final studentIds =
          structuredResult.succeededKeys.map((key) => key.studentId).toSet();
      await Future.wait(
        studentIds.map(HomeworkStore.instance.reloadStudentHomework),
      );
    }
    syncPendingCount();
    if (structuredResult.failedKeys.isNotEmpty && context.mounted) {
      showAppSnackBar(
        context,
        '채점 반환에 실패했습니다. 기록은 이 PC에 보관되어 다시 시도할 수 있어요.',
      );
    } else if (context.mounted && readyPending.isNotEmpty) {
      showAppSnackBar(context, '${readyPending.length}건의 채점을 완료했습니다.');
    }
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
