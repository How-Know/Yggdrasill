import 'dart:async';

import 'package:flutter/foundation.dart';

import 'learning_problem_bank_service.dart';

/// 과제 저장 직후 정답 PNG 미리 굽기를 요청한다.
///
/// 그룹 과제는 학생마다 하위 과제가 따로 저장되므로 잠깐 모았다가 한 번에
/// 보낸다. 저장 흐름은 기다리지 않으며, 실패해도 게이트웨이 주기 스캔이
/// 같은 과제를 다시 찾는다.
class HomeworkAnswerPrebakeService {
  HomeworkAnswerPrebakeService._({LearningProblemBankService? problemBank})
      : _problemBank = problemBank ?? LearningProblemBankService();

  static final HomeworkAnswerPrebakeService instance =
      HomeworkAnswerPrebakeService._();

  @visibleForTesting
  factory HomeworkAnswerPrebakeService.forTesting(
    LearningProblemBankService problemBank,
  ) =>
      HomeworkAnswerPrebakeService._(problemBank: problemBank);

  static const Duration _debounce = Duration(seconds: 2);
  static const int _maxIdsPerRequest = 200;

  final LearningProblemBankService _problemBank;
  final Map<String, Set<String>> _pendingByAcademy = <String, Set<String>>{};
  Timer? _timer;

  void request({
    required String academyId,
    required Iterable<String> homeworkItemIds,
  }) {
    final safeAcademyId = academyId.trim();
    if (safeAcademyId.isEmpty || !_problemBank.hasGateway) return;
    final pending =
        _pendingByAcademy.putIfAbsent(safeAcademyId, () => <String>{});
    for (final id in homeworkItemIds) {
      final safeId = id.trim();
      if (safeId.isNotEmpty) pending.add(safeId);
    }
    if (pending.isEmpty) {
      _pendingByAcademy.remove(safeAcademyId);
      return;
    }
    _timer?.cancel();
    _timer = Timer(_debounce, () => unawaited(flush()));
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final batches = Map<String, Set<String>>.from(_pendingByAcademy);
    _pendingByAcademy.clear();
    for (final entry in batches.entries) {
      final ids = entry.value.toList(growable: false);
      for (var i = 0; i < ids.length; i += _maxIdsPerRequest) {
        final end = (i + _maxIdsPerRequest).clamp(0, ids.length);
        try {
          await _problemBank.requestHomeworkAnswerPrebake(
            academyId: entry.key,
            homeworkItemIds: ids.sublist(i, end),
          );
        } catch (e) {
          debugPrint('[HW][answer_prebake] request failed: $e');
        }
      }
    }
  }
}
