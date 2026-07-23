import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../widgets/pdf/homework_answer_viewer_dialog.dart';
import 'homework_store.dart';
import 'tenant_service.dart';

class HomeworkTestLatestScore {
  final double scoreCorrect;
  final double scoreTotal;
  final DateTime gradedAt;

  const HomeworkTestLatestScore({
    required this.scoreCorrect,
    required this.scoreTotal,
    required this.gradedAt,
  });
}

class HomeworkTestGradingAttemptRecord {
  final String id;
  final String studentId;
  final String homeworkItemId;
  final String action;
  final String assignmentCodeSnapshot;
  final String groupHomeworkTitleSnapshot;
  final int solveElapsedMs;
  final int extraElapsedMs;
  final double scoreCorrect;
  final double scoreTotal;
  final int wrongCount;
  final int unsolvedCount;
  final DateTime gradedAt;

  const HomeworkTestGradingAttemptRecord({
    required this.id,
    required this.studentId,
    required this.homeworkItemId,
    required this.action,
    required this.assignmentCodeSnapshot,
    required this.groupHomeworkTitleSnapshot,
    required this.solveElapsedMs,
    required this.extraElapsedMs,
    required this.scoreCorrect,
    required this.scoreTotal,
    required this.wrongCount,
    required this.unsolvedCount,
    required this.gradedAt,
  });
}

class HomeworkTestSavedGradingSession {
  final HomeworkTestGradingAttemptRecord attempt;
  final Map<String, HomeworkAnswerCellState> states;
  final Map<String, String> correctionStates;
  final Map<String, int> correctionAttemptNumbers;

  const HomeworkTestSavedGradingSession({
    required this.attempt,
    required this.states,
    this.correctionStates = const <String, String>{},
    this.correctionAttemptNumbers = const <String, int>{},
  });
}

class HomeworkTestGradingStudentPeriodStats {
  final String studentId;
  final int attemptCount;
  final double scoreCorrectSum;
  final double scoreTotalSum;
  final int wrongCountSum;
  final int unsolvedCountSum;
  final double avgSolveElapsedMs;
  final double avgExtraElapsedMs;

  const HomeworkTestGradingStudentPeriodStats({
    required this.studentId,
    required this.attemptCount,
    required this.scoreCorrectSum,
    required this.scoreTotalSum,
    required this.wrongCountSum,
    required this.unsolvedCountSum,
    required this.avgSolveElapsedMs,
    required this.avgExtraElapsedMs,
  });

  double get scoreRate =>
      scoreTotalSum <= 0 ? 0 : (scoreCorrectSum / scoreTotalSum);
}

class HomeworkTestQuestionErrorRate {
  final String questionKey;
  final String questionUid;
  final int totalCount;
  final int wrongCount;
  final int unsolvedCount;

  const HomeworkTestQuestionErrorRate({
    required this.questionKey,
    required this.questionUid,
    required this.totalCount,
    required this.wrongCount,
    required this.unsolvedCount,
  });

  double get wrongRate => totalCount <= 0 ? 0 : (wrongCount / totalCount);
}

class HomeworkTestGradingResultService {
  HomeworkTestGradingResultService._();

  static final HomeworkTestGradingResultService instance =
      HomeworkTestGradingResultService._();

  static const _uuid = Uuid();
  static const int _idFilterBatchSize = 250;

  Future<bool> saveAttemptFromSession({
    required String studentId,
    required HomeworkItem homeworkItem,
    required String action,
    required Map<String, HomeworkAnswerCellState> states,
    required List<HomeworkAnswerGradingPage> gradingPages,
    required Map<String, double> scoreByQuestionKey,
    String groupHomeworkTitleSnapshot = '',
    String baselineAttemptId = '',
    Map<String, HomeworkAnswerCellState> baselineStates =
        const <String, HomeworkAnswerCellState>{},
    Map<String, String> correctionStates = const <String, String>{},
  }) async {
    final normalizedAction = action.trim().toLowerCase();
    if (normalizedAction != 'complete' && normalizedAction != 'confirm') {
      return false;
    }
    final trimmedStudentId = studentId.trim();
    final homeworkItemId = homeworkItem.id.trim();
    if (trimmedStudentId.isEmpty || homeworkItemId.isEmpty) return false;
    final academyId = await _resolveAcademyId();
    if (academyId.isEmpty) return false;

    final nextAttemptNumber =
        await _loadAttemptCountForHomework(academyId, homeworkItemId) + 1;
    final existingCorrectionAttemptNumbers =
        await _loadCorrectionAttemptNumbersForHomework(
      academyId: academyId,
      homeworkItemId: homeworkItemId,
    );
    final computed = _computeAttemptRows(
      states: states,
      gradingPages: gradingPages,
      scoreByQuestionKey: scoreByQuestionKey,
      baselineAttemptId: baselineAttemptId,
      baselineStates: baselineStates,
      correctionStates: correctionStates,
      nextAttemptNumber: nextAttemptNumber,
      existingCorrectionAttemptNumbers: existingCorrectionAttemptNumbers,
    );
    final solveElapsedMs = math.max(0, homeworkItem.accumulatedMs);
    final timeLimitMinutes = homeworkItem.timeLimitMinutes ?? 0;
    final extraElapsedMs = timeLimitMinutes > 0
        ? math.max(0, solveElapsedMs - (timeLimitMinutes * 60000))
        : 0;
    final assignmentCodeSnapshot =
        _normalizeAssignmentCode(homeworkItem.assignmentCode);
    final groupTitleSnapshot = groupHomeworkTitleSnapshot.trim();
    final attemptId = _uuid.v4();
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final uid = (Supabase.instance.client.auth.currentUser?.id ?? '').trim();

    final attemptRow = <String, dynamic>{
      'id': attemptId,
      'academy_id': academyId,
      'student_id': trimmedStudentId,
      'homework_item_id': homeworkItemId,
      'assignment_code_snapshot': assignmentCodeSnapshot,
      'group_homework_title_snapshot':
          groupTitleSnapshot.isEmpty ? null : groupTitleSnapshot,
      'graded_at': nowIso,
      'graded_by': uid.isEmpty ? null : uid,
      'action': normalizedAction,
      'solve_elapsed_ms': solveElapsedMs,
      'extra_elapsed_ms': extraElapsedMs,
      'score_correct': computed.scoreCorrect,
      'score_total': computed.scoreTotal,
      'wrong_count': computed.wrongCount,
      'unsolved_count': computed.unsolvedCount,
      'payload_version': 1,
      'version': 1,
    };
    final itemRows = computed.rows
        .map(
          (row) => <String, dynamic>{
            'id': _uuid.v4(),
            'attempt_id': attemptId,
            'academy_id': academyId,
            'student_id': trimmedStudentId,
            'homework_item_id': homeworkItemId,
            'question_key': row.questionKey,
            'question_uid': row.questionUid,
            'page_number': row.pageNumber,
            'question_index': row.questionIndex,
            'correct_answer_snapshot': row.correctAnswerSnapshot,
            'state': row.state,
            if (row.baselineAttemptId.isNotEmpty)
              'baseline_attempt_id': row.baselineAttemptId,
            if (row.baselineState.isNotEmpty)
              'baseline_state': row.baselineState,
            if (row.correctionState.isNotEmpty)
              'correction_state': row.correctionState,
            if (row.correctionAttemptNumber != null)
              'correction_attempt_number': row.correctionAttemptNumber,
            if (row.partStates.isNotEmpty) 'part_states': row.partStates,
            'point_value': row.pointValue,
            'earned_point': row.earnedPoint,
            'reserved_elapsed_ms': null,
            'version': 1,
          },
        )
        .toList(growable: false);

    final supa = Supabase.instance.client;
    try {
      await supa.from('homework_test_grading_attempts').insert(attemptRow);
      if (itemRows.isNotEmpty) {
        await supa.from('homework_test_grading_attempt_items').insert(itemRows);
      }
      return true;
    } catch (error, stackTrace) {
      try {
        await supa
            .from('homework_test_grading_attempts')
            .delete()
            .eq('id', attemptId);
      } catch (_) {}
      if (_isMissingRetryColumnError(error)) {
        final fallbackAttemptId = _uuid.v4();
        final fallbackAttemptRow = Map<String, dynamic>.from(attemptRow)
          ..['id'] = fallbackAttemptId;
        final fallbackItemRows = itemRows
            .map(
              (row) => Map<String, dynamic>.from(row)
                ..['id'] = _uuid.v4()
                ..['attempt_id'] = fallbackAttemptId
                ..remove('baseline_attempt_id')
                ..remove('baseline_state')
                ..remove('correction_state')
                ..remove('correction_attempt_number')
                ..remove('part_states'),
            )
            .toList(growable: false);
        try {
          await supa
              .from('homework_test_grading_attempts')
              .insert(fallbackAttemptRow);
          if (fallbackItemRows.isNotEmpty) {
            await supa
                .from('homework_test_grading_attempt_items')
                .insert(fallbackItemRows);
          }
          return true;
        } catch (fallbackError, fallbackStackTrace) {
          try {
            await supa
                .from('homework_test_grading_attempts')
                .delete()
                .eq('id', fallbackAttemptId);
          } catch (_) {}
          if (!_isMissingTableError(fallbackError)) {
            debugPrint(
                'saveAttemptFromSession fallback failed: $fallbackError');
            debugPrintStack(stackTrace: fallbackStackTrace);
          }
          return false;
        }
      }
      if (!_isMissingTableError(error)) {
        debugPrint('saveAttemptFromSession failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      return false;
    }
  }

  Future<List<HomeworkTestGradingAttemptRecord>> loadRecentAttemptsForHomework({
    required String homeworkItemId,
    int limit = 10,
  }) async {
    final academyId = await _resolveAcademyId();
    final itemId = homeworkItemId.trim();
    if (academyId.isEmpty || itemId.isEmpty) {
      return const <HomeworkTestGradingAttemptRecord>[];
    }
    final safeLimit = limit.clamp(1, 200);
    try {
      final rows = await Supabase.instance.client
          .from('homework_test_grading_attempts')
          .select(
            'id,student_id,homework_item_id,action,assignment_code_snapshot,'
            'group_homework_title_snapshot,solve_elapsed_ms,extra_elapsed_ms,'
            'score_correct,score_total,wrong_count,unsolved_count,graded_at',
          )
          .eq('academy_id', academyId)
          .eq('homework_item_id', itemId)
          .order('graded_at', ascending: false)
          .limit(safeLimit);
      return rows
          .whereType<Map<String, dynamic>>()
          .map((row) => _attemptFromRow(row))
          .toList(growable: false);
    } catch (error, stackTrace) {
      if (!_isMissingTableError(error)) {
        debugPrint('loadRecentAttemptsForHomework failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      return const <HomeworkTestGradingAttemptRecord>[];
    }
  }

  Future<HomeworkTestSavedGradingSession?> loadLatestSavedSessionForHomework({
    required String homeworkItemId,
  }) async {
    final academyId = await _resolveAcademyId();
    final itemId = homeworkItemId.trim();
    if (academyId.isEmpty || itemId.isEmpty) return null;
    try {
      final attemptRows = await Supabase.instance.client
          .from('homework_test_grading_attempts')
          .select(
            'id,student_id,homework_item_id,action,assignment_code_snapshot,'
            'group_homework_title_snapshot,solve_elapsed_ms,extra_elapsed_ms,'
            'score_correct,score_total,wrong_count,unsolved_count,graded_at',
          )
          .eq('academy_id', academyId)
          .eq('homework_item_id', itemId)
          .order('graded_at', ascending: false)
          .limit(1);
      if (attemptRows.isEmpty) return null;
      final attempt = _attemptFromRow(Map<String, dynamic>.from(
        attemptRows.first as Map,
      ));
      if (attempt.id.isEmpty) return null;

      final itemRows = await _loadSavedSessionItemRows(
        academyId: academyId,
        attemptId: attempt.id,
      );
      final states = <String, HomeworkAnswerCellState>{};
      final correctionStates = <String, String>{};
      final correctionAttemptNumbers = <String, int>{};
      for (final raw in itemRows) {
        final row = Map<String, dynamic>.from(raw as Map);
        _mergeSavedSessionItemRow(
          row: row,
          homeworkItemId: itemId,
          states: states,
          correctionStates: correctionStates,
          correctionAttemptNumbers: correctionAttemptNumbers,
        );
      }
      return HomeworkTestSavedGradingSession(
        attempt: attempt,
        states: states,
        correctionStates: correctionStates,
        correctionAttemptNumbers: correctionAttemptNumbers,
      );
    } catch (error, stackTrace) {
      if (!_isMissingTableError(error)) {
        debugPrint('loadLatestSavedSessionForHomework failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      return null;
    }
  }

  Future<HomeworkTestSavedGradingSession?> loadFirstSavedSessionForHomework({
    required String homeworkItemId,
  }) async {
    final academyId = await _resolveAcademyId();
    final itemId = homeworkItemId.trim();
    if (academyId.isEmpty || itemId.isEmpty) return null;
    try {
      final attemptRows = await Supabase.instance.client
          .from('homework_test_grading_attempts')
          .select(
            'id,student_id,homework_item_id,action,assignment_code_snapshot,'
            'group_homework_title_snapshot,solve_elapsed_ms,extra_elapsed_ms,'
            'score_correct,score_total,wrong_count,unsolved_count,graded_at',
          )
          .eq('academy_id', academyId)
          .eq('homework_item_id', itemId)
          .order('graded_at', ascending: true)
          .limit(1);
      if (attemptRows.isEmpty) return null;
      final attempt = _attemptFromRow(Map<String, dynamic>.from(
        attemptRows.first as Map,
      ));
      if (attempt.id.isEmpty) return null;

      final itemRows = await _loadSavedSessionItemRows(
        academyId: academyId,
        attemptId: attempt.id,
      );
      final states = <String, HomeworkAnswerCellState>{};
      final correctionStates = <String, String>{};
      final correctionAttemptNumbers = <String, int>{};
      for (final raw in itemRows) {
        final row = Map<String, dynamic>.from(raw as Map);
        _mergeSavedSessionItemRow(
          row: row,
          homeworkItemId: itemId,
          states: states,
          correctionStates: correctionStates,
          correctionAttemptNumbers: correctionAttemptNumbers,
        );
      }
      return HomeworkTestSavedGradingSession(
        attempt: attempt,
        states: states,
        correctionStates: correctionStates,
        correctionAttemptNumbers: correctionAttemptNumbers,
      );
    } catch (error, stackTrace) {
      if (!_isMissingTableError(error)) {
        debugPrint('loadFirstSavedSessionForHomework failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      return null;
    }
  }

  Future<bool> resetAttemptsForHomework({
    required String homeworkItemId,
  }) async {
    final academyId = await _resolveAcademyId();
    final itemId = homeworkItemId.trim();
    if (academyId.isEmpty || itemId.isEmpty) return false;
    try {
      final supa = Supabase.instance.client;
      await supa
          .from('homework_test_grading_attempt_items')
          .delete()
          .eq('academy_id', academyId)
          .eq('homework_item_id', itemId);
      await supa
          .from('homework_test_grading_attempts')
          .delete()
          .eq('academy_id', academyId)
          .eq('homework_item_id', itemId);
      return true;
    } catch (error, stackTrace) {
      if (!_isMissingTableError(error)) {
        debugPrint('resetAttemptsForHomework failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      return false;
    }
  }

  Future<HomeworkTestGradingStudentPeriodStats> loadStudentPeriodStats({
    required String studentId,
    required DateTime from,
    required DateTime to,
  }) async {
    final academyId = await _resolveAcademyId();
    final sid = studentId.trim();
    if (academyId.isEmpty || sid.isEmpty) {
      return HomeworkTestGradingStudentPeriodStats(
        studentId: sid,
        attemptCount: 0,
        scoreCorrectSum: 0,
        scoreTotalSum: 0,
        wrongCountSum: 0,
        unsolvedCountSum: 0,
        avgSolveElapsedMs: 0,
        avgExtraElapsedMs: 0,
      );
    }
    final fromIso = from.toUtc().toIso8601String();
    final toIso = to.toUtc().toIso8601String();
    try {
      final rows = await Supabase.instance.client
          .from('homework_test_grading_attempts')
          .select(
            'score_correct,score_total,wrong_count,unsolved_count,'
            'solve_elapsed_ms,extra_elapsed_ms',
          )
          .eq('academy_id', academyId)
          .eq('student_id', sid)
          .gte('graded_at', fromIso)
          .lte('graded_at', toIso);
      if (rows.isEmpty) {
        return HomeworkTestGradingStudentPeriodStats(
          studentId: sid,
          attemptCount: 0,
          scoreCorrectSum: 0,
          scoreTotalSum: 0,
          wrongCountSum: 0,
          unsolvedCountSum: 0,
          avgSolveElapsedMs: 0,
          avgExtraElapsedMs: 0,
        );
      }
      var scoreCorrectSum = 0.0;
      var scoreTotalSum = 0.0;
      var wrongCountSum = 0;
      var unsolvedCountSum = 0;
      var solveElapsedTotal = 0.0;
      var extraElapsedTotal = 0.0;
      var count = 0;
      for (final raw in rows) {
        final map = Map<String, dynamic>.from(raw);
        count += 1;
        scoreCorrectSum += _doubleOf(map['score_correct']);
        scoreTotalSum += _doubleOf(map['score_total']);
        wrongCountSum += _intOf(map['wrong_count']);
        unsolvedCountSum += _intOf(map['unsolved_count']);
        solveElapsedTotal += _doubleOf(map['solve_elapsed_ms']);
        extraElapsedTotal += _doubleOf(map['extra_elapsed_ms']);
      }
      if (count <= 0) {
        return HomeworkTestGradingStudentPeriodStats(
          studentId: sid,
          attemptCount: 0,
          scoreCorrectSum: 0,
          scoreTotalSum: 0,
          wrongCountSum: 0,
          unsolvedCountSum: 0,
          avgSolveElapsedMs: 0,
          avgExtraElapsedMs: 0,
        );
      }
      return HomeworkTestGradingStudentPeriodStats(
        studentId: sid,
        attemptCount: count,
        scoreCorrectSum: scoreCorrectSum,
        scoreTotalSum: scoreTotalSum,
        wrongCountSum: wrongCountSum,
        unsolvedCountSum: unsolvedCountSum,
        avgSolveElapsedMs: solveElapsedTotal / count,
        avgExtraElapsedMs: extraElapsedTotal / count,
      );
    } catch (error, stackTrace) {
      if (!_isMissingTableError(error)) {
        debugPrint('loadStudentPeriodStats failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      return HomeworkTestGradingStudentPeriodStats(
        studentId: sid,
        attemptCount: 0,
        scoreCorrectSum: 0,
        scoreTotalSum: 0,
        wrongCountSum: 0,
        unsolvedCountSum: 0,
        avgSolveElapsedMs: 0,
        avgExtraElapsedMs: 0,
      );
    }
  }

  Future<List<HomeworkTestQuestionErrorRate>> loadQuestionErrorRates({
    DateTime? from,
    DateTime? to,
    String? studentId,
    String? homeworkItemId,
    int limit = 300,
  }) async {
    final academyId = await _resolveAcademyId();
    if (academyId.isEmpty) return const <HomeworkTestQuestionErrorRate>[];
    final safeLimit = limit.clamp(1, 2000);
    final sid = (studentId ?? '').trim();
    final itemId = (homeworkItemId ?? '').trim();
    try {
      var query = Supabase.instance.client
          .from('homework_test_grading_attempt_items')
          .select('homework_item_id,question_key,question_uid,state')
          .eq('academy_id', academyId);
      if (sid.isNotEmpty) {
        query = query.eq('student_id', sid);
      }
      if (itemId.isNotEmpty) {
        query = query.eq('homework_item_id', itemId);
      }
      if (from != null) {
        query = query.gte('created_at', from.toUtc().toIso8601String());
      }
      if (to != null) {
        query = query.lte('created_at', to.toUtc().toIso8601String());
      }
      final rows = await query.limit(safeLimit);
      if (rows.isEmpty) {
        return const <HomeworkTestQuestionErrorRate>[];
      }
      final byKey = <String, _QuestionErrorAccumulator>{};
      for (final raw in rows) {
        final map = Map<String, dynamic>.from(raw);
        final rawQuestionKey = '${map['question_key'] ?? ''}'.trim();
        final rowHomeworkItemId = '${map['homework_item_id'] ?? ''}'.trim();
        final questionKey = rowHomeworkItemId.isEmpty
            ? rawQuestionKey
            : _stableQuestionKeyForRow(
                row: map,
                homeworkItemId: rowHomeworkItemId,
              );
        if (questionKey.isEmpty) continue;
        final questionUid = ('${map['question_uid'] ?? ''}'.trim().isNotEmpty
                ? '${map['question_uid'] ?? ''}'
                : (_questionUidFromKey(rawQuestionKey) ?? ''))
            .trim();
        final state = '${map['state'] ?? ''}'.trim().toLowerCase();
        final bucket =
            byKey.putIfAbsent(questionKey, () => _QuestionErrorAccumulator());
        bucket.totalCount += 1;
        if (questionUid.isNotEmpty && bucket.questionUid.isEmpty) {
          bucket.questionUid = questionUid;
        }
        if (state == 'wrong') {
          bucket.wrongCount += 1;
        } else if (state == 'unsolved') {
          bucket.unsolvedCount += 1;
        }
      }
      final out = byKey.entries
          .map(
            (entry) => HomeworkTestQuestionErrorRate(
              questionKey: entry.key,
              questionUid: entry.value.questionUid,
              totalCount: entry.value.totalCount,
              wrongCount: entry.value.wrongCount,
              unsolvedCount: entry.value.unsolvedCount,
            ),
          )
          .toList(growable: false)
        ..sort((a, b) {
          final byWrongRate = b.wrongRate.compareTo(a.wrongRate);
          if (byWrongRate != 0) return byWrongRate;
          final byWrongCount = b.wrongCount.compareTo(a.wrongCount);
          if (byWrongCount != 0) return byWrongCount;
          return b.totalCount.compareTo(a.totalCount);
        });
      return out;
    } catch (error, stackTrace) {
      if (!_isMissingTableError(error)) {
        debugPrint('loadQuestionErrorRates failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      return const <HomeworkTestQuestionErrorRate>[];
    }
  }

  Future<Map<String, HomeworkTestLatestScore>> loadLatestScoreByHomeworkItemIds(
    Iterable<String> homeworkItemIds,
  ) async {
    final ids = homeworkItemIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) return const <String, HomeworkTestLatestScore>{};
    final academyId = await _resolveAcademyId();
    if (academyId.isEmpty) return const <String, HomeworkTestLatestScore>{};
    final out = <String, HomeworkTestLatestScore>{};
    try {
      for (final chunk in _chunk(ids, _idFilterBatchSize)) {
        final rows = await Supabase.instance.client
            .from('homework_test_grading_attempts')
            .select('homework_item_id,score_correct,score_total,graded_at')
            .eq('academy_id', academyId)
            .inFilter('homework_item_id', chunk)
            .order('graded_at', ascending: false);
        if (rows.isEmpty) continue;
        for (final raw in rows) {
          final map = Map<String, dynamic>.from(raw);
          final itemId = '${map['homework_item_id'] ?? ''}'.trim();
          if (itemId.isEmpty || out.containsKey(itemId)) continue;
          out[itemId] = HomeworkTestLatestScore(
            scoreCorrect: _doubleOf(map['score_correct']),
            scoreTotal: _doubleOf(map['score_total']),
            gradedAt: _dateTimeOf(map['graded_at']) ?? DateTime(1970),
          );
        }
      }
      return out;
    } catch (error, stackTrace) {
      if (!_isMissingTableError(error)) {
        debugPrint('loadLatestScoreByHomeworkItemIds failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      return const <String, HomeworkTestLatestScore>{};
    }
  }

  _ComputedAttemptRows _computeAttemptRows({
    required Map<String, HomeworkAnswerCellState> states,
    required List<HomeworkAnswerGradingPage> gradingPages,
    required Map<String, double> scoreByQuestionKey,
    String baselineAttemptId = '',
    Map<String, HomeworkAnswerCellState> baselineStates =
        const <String, HomeworkAnswerCellState>{},
    Map<String, String> correctionStates = const <String, String>{},
    int nextAttemptNumber = 1,
    Map<String, int> existingCorrectionAttemptNumbers = const <String, int>{},
  }) {
    final hasScoreData = scoreByQuestionKey.isNotEmpty;
    final rows = <_ComputedAttemptRow>[];
    final seenKeys = <String>{};
    var scoreCorrect = 0.0;
    var scoreTotal = 0.0;
    var wrongCount = 0;
    var unsolvedCount = 0;
    for (final page in gradingPages) {
      for (final cell in page.cells) {
        final key = cell.key.trim();
        if (key.isEmpty || !seenKeys.add(key)) continue;
        final rawPoint = hasScoreData ? (scoreByQuestionKey[key] ?? 1.0) : 1.0;
        final pointValue =
            (rawPoint.isFinite && rawPoint >= 0) ? rawPoint : 1.0;
        final state = states[key] ?? HomeworkAnswerCellState.correct;
        // 세트형 파트 상태 — '<cellKey>#(1)' 서브 키를 part_states로 분리 기록.
        // 점수·통계는 문항 단위 state만 사용한다.
        final partStates = <String, String>{};
        final partPrefix = '$key#';
        states.forEach((stateKey, partState) {
          if (!stateKey.startsWith(partPrefix)) return;
          final label = stateKey.substring(partPrefix.length).trim();
          if (label.isEmpty) return;
          partStates[label] = _encodeState(partState);
        });
        final earnedPoint =
            state == HomeworkAnswerCellState.correct ? pointValue : 0.0;
        scoreTotal += pointValue;
        scoreCorrect += earnedPoint;
        if (state == HomeworkAnswerCellState.wrong) {
          wrongCount += 1;
        } else if (state == HomeworkAnswerCellState.unsolved) {
          unsolvedCount += 1;
        }
        final baselineState = baselineStates[key];
        final baselineStateRaw = baselineState == null ||
                baselineState == HomeworkAnswerCellState.correct
            ? ''
            : _encodeState(baselineState);
        final correctionState = correctionStates[key] == 'corrected' &&
                baselineStateRaw.isNotEmpty &&
                state == HomeworkAnswerCellState.correct
            ? 'corrected'
            : '';
        final correctionAttemptNumber = correctionState.isEmpty
            ? null
            : existingCorrectionAttemptNumbers[key] ??
                math.max(1, nextAttemptNumber);
        rows.add(
          _ComputedAttemptRow(
            questionKey: key,
            questionUid: _questionUidFromKey(key),
            pageNumber: page.pageNumber > 0 ? page.pageNumber : 1,
            questionIndex: cell.questionIndex > 0 ? cell.questionIndex : 1,
            correctAnswerSnapshot:
                cell.answer.trim().isEmpty ? null : cell.answer.trim(),
            state: _encodeState(state),
            baselineAttemptId:
                baselineStateRaw.isEmpty ? '' : baselineAttemptId.trim(),
            baselineState: baselineStateRaw,
            correctionState: correctionState,
            correctionAttemptNumber: correctionAttemptNumber,
            partStates: partStates,
            pointValue: pointValue,
            earnedPoint: earnedPoint,
          ),
        );
      }
    }
    return _ComputedAttemptRows(
      scoreCorrect: scoreCorrect,
      scoreTotal: scoreTotal,
      wrongCount: wrongCount,
      unsolvedCount: unsolvedCount,
      rows: rows,
    );
  }

  HomeworkTestGradingAttemptRecord _attemptFromRow(Map raw) {
    return HomeworkTestGradingAttemptRecord(
      id: '${raw['id'] ?? ''}'.trim(),
      studentId: '${raw['student_id'] ?? ''}'.trim(),
      homeworkItemId: '${raw['homework_item_id'] ?? ''}'.trim(),
      action: '${raw['action'] ?? ''}'.trim(),
      assignmentCodeSnapshot: '${raw['assignment_code_snapshot'] ?? ''}'.trim(),
      groupHomeworkTitleSnapshot:
          '${raw['group_homework_title_snapshot'] ?? ''}'.trim(),
      solveElapsedMs: _intOf(raw['solve_elapsed_ms']),
      extraElapsedMs: _intOf(raw['extra_elapsed_ms']),
      scoreCorrect: _doubleOf(raw['score_correct']),
      scoreTotal: _doubleOf(raw['score_total']),
      wrongCount: _intOf(raw['wrong_count']),
      unsolvedCount: _intOf(raw['unsolved_count']),
      gradedAt: _dateTimeOf(raw['graded_at']) ?? DateTime(1970),
    );
  }

  Future<List<dynamic>> _loadSavedSessionItemRows({
    required String academyId,
    required String attemptId,
  }) async {
    final supa = Supabase.instance.client;
    try {
      return await supa
          .from('homework_test_grading_attempt_items')
          .select(
              'question_key,question_uid,state,correction_state,correction_attempt_number,part_states')
          .eq('academy_id', academyId)
          .eq('attempt_id', attemptId)
          .order('page_number', ascending: true)
          .order('question_index', ascending: true);
    } catch (error) {
      if (!_isMissingRetryColumnError(error)) rethrow;
      return await supa
          .from('homework_test_grading_attempt_items')
          .select('question_key,question_uid,state')
          .eq('academy_id', academyId)
          .eq('attempt_id', attemptId)
          .order('page_number', ascending: true)
          .order('question_index', ascending: true);
    }
  }

  Future<int> _loadAttemptCountForHomework(
    String academyId,
    String homeworkItemId,
  ) async {
    try {
      final rows = await Supabase.instance.client
          .from('homework_test_grading_attempts')
          .select('id')
          .eq('academy_id', academyId)
          .eq('homework_item_id', homeworkItemId);
      return rows.length;
    } catch (_) {
      return 0;
    }
  }

  Future<Map<String, int>> _loadCorrectionAttemptNumbersForHomework({
    required String academyId,
    required String homeworkItemId,
  }) async {
    try {
      final rows = await Supabase.instance.client
          .from('homework_test_grading_attempt_items')
          .select('question_key,question_uid,correction_attempt_number')
          .eq('academy_id', academyId)
          .eq('homework_item_id', homeworkItemId)
          .eq('correction_state', 'corrected');
      final out = <String, int>{};
      for (final raw in rows) {
        final row = Map<String, dynamic>.from(raw as Map);
        final rawKey = '${row['question_key'] ?? ''}'.trim();
        final stableKey = _stableQuestionKeyForRow(
          row: row,
          homeworkItemId: homeworkItemId,
        );
        final number = _intOf(row['correction_attempt_number']);
        if (number <= 0) continue;
        for (final key in <String>{rawKey, stableKey}) {
          if (key.isEmpty) continue;
          final existing = out[key];
          if (existing == null || number < existing) {
            out[key] = number;
          }
        }
      }
      return out;
    } catch (error) {
      if (!_isMissingRetryColumnError(error)) {
        debugPrint('loadCorrectionAttemptNumbersForHomework failed: $error');
      }
      return const <String, int>{};
    }
  }

  void _mergeSavedSessionItemRow({
    required Map<String, dynamic> row,
    required String homeworkItemId,
    required Map<String, HomeworkAnswerCellState> states,
    required Map<String, String> correctionStates,
    required Map<String, int> correctionAttemptNumbers,
  }) {
    final key = '${row['question_key'] ?? ''}'.trim();
    if (key.isEmpty) return;
    final state = _decodeState('${row['state'] ?? ''}');
    final keys = <String>{key};
    final stableKey = _stableQuestionKeyForRow(
      row: row,
      homeworkItemId: homeworkItemId,
    );
    if (stableKey.isNotEmpty) keys.add(stableKey);

    final correctionState = '${row['correction_state'] ?? ''}'.trim();
    final correctionAttemptNumber = _intOf(row['correction_attempt_number']);
    final rawPartStates = row['part_states'];
    for (final oneKey in keys) {
      states[oneKey] = state;
      if (correctionState.isNotEmpty) {
        correctionStates[oneKey] = correctionState;
        if (correctionAttemptNumber > 0) {
          correctionAttemptNumbers[oneKey] = correctionAttemptNumber;
        }
      }
      // 세트형 파트 상태 복원 — '<cellKey>#(1)' 서브 키로 되살린다.
      if (rawPartStates is Map) {
        rawPartStates.forEach((label, partState) {
          final partLabel = '$label'.trim();
          if (partLabel.isEmpty) return;
          states['$oneKey#$partLabel'] = _decodeState('$partState');
        });
      }
    }
  }

  String _stableQuestionKeyForRow({
    required Map<String, dynamic> row,
    required String homeworkItemId,
  }) {
    final itemId = homeworkItemId.trim();
    if (itemId.isEmpty) return '';
    final explicitUid = '${row['question_uid'] ?? ''}'.trim();
    final uid = explicitUid.isNotEmpty
        ? explicitUid
        : (_questionUidFromKey('${row['question_key'] ?? ''}') ?? '').trim();
    if (uid.isEmpty) return '';
    return '$itemId|pb|$uid';
  }

  String _normalizeAssignmentCode(String? raw) {
    final compact =
        (raw ?? '').trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return compact;
  }

  String _encodeState(HomeworkAnswerCellState state) {
    switch (state) {
      case HomeworkAnswerCellState.correct:
        return 'correct';
      case HomeworkAnswerCellState.wrong:
        return 'wrong';
      case HomeworkAnswerCellState.unsolved:
        return 'unsolved';
    }
  }

  HomeworkAnswerCellState _decodeState(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'wrong':
        return HomeworkAnswerCellState.wrong;
      case 'unsolved':
        return HomeworkAnswerCellState.unsolved;
      case 'correct':
      default:
        return HomeworkAnswerCellState.correct;
    }
  }

  String? _questionUidFromKey(String key) {
    final parts = key.split('|');
    if (parts.length >= 3 && parts[1] == 'pb') {
      final uid = parts.sublist(2).join('|').trim();
      return uid.isEmpty ? null : uid;
    }
    if (parts.length < 4) return null;
    final uid = parts.sublist(3).join('|').trim();
    return uid.isEmpty ? null : uid;
  }

  double _doubleOf(dynamic raw) {
    if (raw is num) return raw.toDouble();
    return double.tryParse('$raw') ?? 0;
  }

  int _intOf(dynamic raw) {
    if (raw is num) return raw.toInt();
    return int.tryParse('$raw') ?? 0;
  }

  DateTime? _dateTimeOf(dynamic raw) {
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    return DateTime.tryParse('$raw');
  }

  bool _isMissingTableError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('homework_test_grading_attempts') &&
            (msg.contains('does not exist') || msg.contains('42p01')) ||
        msg.contains('homework_test_grading_attempt_items') &&
            (msg.contains('does not exist') || msg.contains('42p01'));
  }

  bool _isMissingRetryColumnError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('homework_test_grading_attempt_items') &&
        (msg.contains('baseline_attempt_id') ||
            msg.contains('baseline_state') ||
            msg.contains('correction_state') ||
            msg.contains('correction_attempt_number') ||
            msg.contains('part_states')) &&
        (msg.contains('schema cache') ||
            msg.contains('could not find') ||
            msg.contains('does not exist') ||
            msg.contains('42703'));
  }

  Future<String> _resolveAcademyId() async {
    var academyId =
        (await TenantService.instance.getActiveAcademyId() ?? '').trim();
    if (academyId.isEmpty) {
      academyId = (await TenantService.instance.ensureActiveAcademy()).trim();
    }
    return academyId;
  }

  Iterable<List<String>> _chunk(List<String> values, int size) sync* {
    if (values.isEmpty || size <= 0) return;
    for (var i = 0; i < values.length; i += size) {
      final end = (i + size > values.length) ? values.length : (i + size);
      yield values.sublist(i, end);
    }
  }
}

class _ComputedAttemptRows {
  final double scoreCorrect;
  final double scoreTotal;
  final int wrongCount;
  final int unsolvedCount;
  final List<_ComputedAttemptRow> rows;

  const _ComputedAttemptRows({
    required this.scoreCorrect,
    required this.scoreTotal,
    required this.wrongCount,
    required this.unsolvedCount,
    required this.rows,
  });
}

class _ComputedAttemptRow {
  final String questionKey;
  final String? questionUid;
  final int pageNumber;
  final int questionIndex;
  final String? correctAnswerSnapshot;
  final String state;
  final String baselineAttemptId;
  final String baselineState;
  final String correctionState;
  final int? correctionAttemptNumber;

  /// 세트형 파트 상태 — {'(1)': 'correct', '(2)': 'wrong'}.
  final Map<String, String> partStates;
  final double pointValue;
  final double earnedPoint;

  const _ComputedAttemptRow({
    required this.questionKey,
    required this.questionUid,
    required this.pageNumber,
    required this.questionIndex,
    required this.correctAnswerSnapshot,
    required this.state,
    required this.baselineAttemptId,
    required this.baselineState,
    required this.correctionState,
    required this.correctionAttemptNumber,
    this.partStates = const <String, String>{},
    required this.pointValue,
    required this.earnedPoint,
  });
}

class _QuestionErrorAccumulator {
  String questionUid = '';
  int totalCount = 0;
  int wrongCount = 0;
  int unsolvedCount = 0;
}
