import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'homework_store.dart';
import 'tenant_service.dart';

enum HomeworkScoreEventType { assigned, checked, completed }

class HomeworkScoreEvent {
  final String studentId;
  final String homeworkItemId;
  final HomeworkScoreEventType type;
  final DateTime eventAt;
  final double baseXp;
  final String? flowId;
  final String? bookId;
  final String? gradeLabel;
  final int? difficultyLevel;
  final int? progress;

  const HomeworkScoreEvent({
    required this.studentId,
    required this.homeworkItemId,
    required this.type,
    required this.eventAt,
    required this.baseXp,
    this.flowId,
    this.bookId,
    this.gradeLabel,
    this.difficultyLevel,
    this.progress,
  });
}

typedef HomeworkEventWeightModifier = double Function(HomeworkScoreEvent event);

class HomeworkScoreService {
  HomeworkScoreService._internal();
  static final HomeworkScoreService instance = HomeworkScoreService._internal();

  static const String formulaVersion = 'homework_score_v1';

  // 과제 점수는 EXP형 누적 성격을 가지므로 출석보다 긴 반감기를 기본값으로 둔다.
  static const double _defaultHalfLifeDays = 180.0;
  static const double _defaultScaleK = 240.0;
  static const int _queryChunkSize = 40;

  static const double _assignedBaseXp = 0.45;
  static const double _checkBaseXp = 0.95;
  static const double _completedBaseXp = 3.80;

  Future<Map<String, dynamic>> calculateHomeworkScore({
    required String studentId,
    DateTime? nowRef,
    double halfLifeDays = _defaultHalfLifeDays,
    double scaleK = _defaultScaleK,
    HomeworkEventWeightModifier? weightModifier,
  }) async {
    final sid = studentId.trim();
    final now = (nowRef ?? DateTime.now()).toLocal();
    if (sid.isEmpty) {
      return _emptyScoreMap(
        halfLifeDays: halfLifeDays,
        scaleK: scaleK,
      );
    }
    final results = await calculateHomeworkScoresForStudents(
      studentIds: <String>[sid],
      nowRef: now,
      halfLifeDays: halfLifeDays,
      scaleK: scaleK,
      weightModifier: weightModifier,
    );
    return results[sid] ??
        _emptyScoreMap(
          halfLifeDays: halfLifeDays,
          scaleK: scaleK,
        );
  }

  Future<Map<String, Map<String, dynamic>>> calculateHomeworkScoresForStudents({
    required List<String> studentIds,
    DateTime? nowRef,
    double halfLifeDays = _defaultHalfLifeDays,
    double scaleK = _defaultScaleK,
    HomeworkEventWeightModifier? weightModifier,
  }) async {
    final now = (nowRef ?? DateTime.now()).toLocal();
    final ids = studentIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return <String, Map<String, dynamic>>{};

    final double safeHalfLife = halfLifeDays <= 0 ? _defaultHalfLifeDays : halfLifeDays;
    final double safeScaleK = scaleK <= 0 ? _defaultScaleK : scaleK;
    const double ln2 = 0.6931471805599453;

    await HomeworkStore.instance.loadAll();

    final assignmentRows = await _loadAssignmentRowsForStudents(ids);
    final checkRows = await _loadCheckRowsForStudents(ids);

    final Map<String, List<Map<String, dynamic>>> assignmentsByStudent =
        <String, List<Map<String, dynamic>>>{};
    for (final row in assignmentRows) {
      final sid = (row['student_id'] as String?)?.trim() ?? '';
      if (sid.isEmpty) continue;
      assignmentsByStudent.putIfAbsent(sid, () => <Map<String, dynamic>>[]).add(row);
    }

    final Map<String, List<Map<String, dynamic>>> checksByStudent =
        <String, List<Map<String, dynamic>>>{};
    for (final row in checkRows) {
      final sid = (row['student_id'] as String?)?.trim() ?? '';
      if (sid.isEmpty) continue;
      checksByStudent.putIfAbsent(sid, () => <Map<String, dynamic>>[]).add(row);
    }

    final Map<String, Map<String, dynamic>> out = <String, Map<String, dynamic>>{};
    for (final sid in ids) {
      final items = HomeworkStore.instance.items(sid);
      final Map<String, HomeworkItem> itemById = <String, HomeworkItem>{};
      for (final item in items) {
        itemById[item.id] = item;
      }

      final List<HomeworkScoreEvent> events = <HomeworkScoreEvent>[];

      for (final row in assignmentsByStudent[sid] ?? const <Map<String, dynamic>>[]) {
        final itemId = (row['homework_item_id'] as String?)?.trim() ?? '';
        if (itemId.isEmpty) continue;
        final eventAt = _parseTsOpt(row['assigned_at']) ?? now;
        if (eventAt.isAfter(now)) continue;
        final progress = _asInt(row['progress']);
        final normalizedProgress = (progress.clamp(0, 150)).toDouble() / 150.0;
        final status = (row['status'] as String?)?.trim().toLowerCase();
        final completionHint = status == 'completed' ? 0.15 : 0.0;
        final baseXp = _assignedBaseXp + (normalizedProgress * 0.20) + completionHint;
        final item = itemById[itemId];
        events.add(
          HomeworkScoreEvent(
            studentId: sid,
            homeworkItemId: itemId,
            type: HomeworkScoreEventType.assigned,
            eventAt: eventAt,
            baseXp: baseXp,
            flowId: item?.flowId,
            bookId: item?.bookId,
            gradeLabel: item?.gradeLabel,
            progress: progress,
          ),
        );
      }

      for (final row in checksByStudent[sid] ?? const <Map<String, dynamic>>[]) {
        final itemId = (row['homework_item_id'] as String?)?.trim() ?? '';
        if (itemId.isEmpty) continue;
        final eventAt = _parseTsOpt(row['checked_at']) ?? now;
        if (eventAt.isAfter(now)) continue;
        final progress = _asInt(row['progress']);
        final normalizedProgress = (progress.clamp(0, 150)).toDouble() / 150.0;
        final baseXp = _checkBaseXp + (normalizedProgress * 0.35);
        final item = itemById[itemId];
        events.add(
          HomeworkScoreEvent(
            studentId: sid,
            homeworkItemId: itemId,
            type: HomeworkScoreEventType.checked,
            eventAt: eventAt,
            baseXp: baseXp,
            flowId: item?.flowId,
            bookId: item?.bookId,
            gradeLabel: item?.gradeLabel,
            progress: progress,
          ),
        );
      }

      for (final item in items) {
        final bool completed = item.status == HomeworkStatus.completed ||
            item.completedAt != null ||
            item.confirmedAt != null;
        if (!completed) continue;
        final eventAt =
            item.completedAt ?? item.confirmedAt ?? item.submittedAt ?? item.updatedAt ?? item.createdAt;
        if (eventAt == null || eventAt.isAfter(now)) continue;
        final double minutes = math.max(0.0, item.accumulatedMs.toDouble() / 60000.0);
        final double timeBonus = (minutes / 90.0).clamp(0.0, 1.50).toDouble();
        final double checkBonus = (item.checkCount / 10.0).clamp(0.0, 1.00).toDouble();
        final baseXp = _completedBaseXp + timeBonus + checkBonus;
        events.add(
          HomeworkScoreEvent(
            studentId: sid,
            homeworkItemId: item.id,
            type: HomeworkScoreEventType.completed,
            eventAt: eventAt.toLocal(),
            baseXp: baseXp,
            flowId: item.flowId,
            bookId: item.bookId,
            gradeLabel: item.gradeLabel,
          ),
        );
      }

      double expRaw = 0.0;
      double expDecayed = 0.0;
      double assignedExpDecayed = 0.0;
      double checkExpDecayed = 0.0;
      double completedExpDecayed = 0.0;
      int assignedCount = 0;
      int checkCount = 0;
      int completedCount = 0;
      DateTime? lastEventAt;

      for (final event in events) {
        final daysAgo = math.max(
          0.0,
          now.difference(event.eventAt).inMinutes.toDouble() / (24 * 60),
        );
        final double weight = math.exp(-ln2 * (daysAgo / safeHalfLife));
        if (!weight.isFinite || weight <= 0) continue;
        final double mod = _safeModifier(weightModifier, event);
        if (mod <= 0) continue;
        final double eventXp = event.baseXp * mod;
        if (!eventXp.isFinite || eventXp <= 0) continue;
        final double decayedXp = eventXp * weight;
        expRaw += eventXp;
        expDecayed += decayedXp;
        if (lastEventAt == null || event.eventAt.isAfter(lastEventAt)) {
          lastEventAt = event.eventAt;
        }
        switch (event.type) {
          case HomeworkScoreEventType.assigned:
            assignedCount += 1;
            assignedExpDecayed += decayedXp;
            break;
          case HomeworkScoreEventType.checked:
            checkCount += 1;
            checkExpDecayed += decayedXp;
            break;
          case HomeworkScoreEventType.completed:
            completedCount += 1;
            completedExpDecayed += decayedXp;
            break;
        }
      }

      final score100 = expDecayed <= 0
          ? 0.0
          : (100.0 * (1.0 - math.exp(-(expDecayed / safeScaleK)))).clamp(0.0, 100.0).toDouble();
      final eventCount = assignedCount + checkCount + completedCount;

      out[sid] = <String, dynamic>{
        'score100': score100,
        'expRaw': expRaw,
        'expDecayed': expDecayed,
        'assignedExpDecayed': assignedExpDecayed,
        'checkExpDecayed': checkExpDecayed,
        'completedExpDecayed': completedExpDecayed,
        'eventCount': eventCount,
        'assignedCount': assignedCount,
        'checkCount': checkCount,
        'completedCount': completedCount,
        'halfLifeDays': safeHalfLife,
        'scaleK': safeScaleK,
        'formulaVersion': formulaVersion,
        'lastEventAt': lastEventAt?.toIso8601String(),
      };
    }

    return out;
  }

  Future<List<Map<String, dynamic>>> _loadAssignmentRowsForStudents(
    List<String> studentIds,
  ) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final out = <Map<String, dynamic>>[];
      for (final chunk in _chunked(studentIds, _queryChunkSize)) {
        final rows = await supa
            .from('homework_assignments')
            .select('student_id,homework_item_id,assigned_at,status,progress')
            .eq('academy_id', academyId)
            .inFilter('student_id', chunk);
        out.addAll((rows as List<dynamic>).cast<Map<String, dynamic>>());
      }
      return out;
    } catch (e, st) {
      debugPrint('[HW_SCORE][assignments][ERROR] $e\n$st');
      return const <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> _loadCheckRowsForStudents(
    List<String> studentIds,
  ) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final out = <Map<String, dynamic>>[];
      for (final chunk in _chunked(studentIds, _queryChunkSize)) {
        final rows = await supa
            .from('homework_assignment_checks')
            .select('student_id,homework_item_id,checked_at,progress')
            .eq('academy_id', academyId)
            .inFilter('student_id', chunk);
        out.addAll((rows as List<dynamic>).cast<Map<String, dynamic>>());
      }
      return out;
    } catch (e, st) {
      debugPrint('[HW_SCORE][checks][ERROR] $e\n$st');
      return const <Map<String, dynamic>>[];
    }
  }

  DateTime? _parseTsOpt(dynamic value) {
    if (value == null) return null;
    final raw = value as String?;
    if (raw == null || raw.trim().isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  int _asInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  double _safeModifier(
    HomeworkEventWeightModifier? modifier,
    HomeworkScoreEvent event,
  ) {
    if (modifier == null) return 1.0;
    final v = modifier(event);
    if (!v.isFinite || v.isNaN) return 1.0;
    return v.clamp(0.0, 10.0).toDouble();
  }

  Map<String, dynamic> _emptyScoreMap({
    required double halfLifeDays,
    required double scaleK,
  }) {
    final safeHalfLife = halfLifeDays <= 0 ? _defaultHalfLifeDays : halfLifeDays;
    final safeScaleK = scaleK <= 0 ? _defaultScaleK : scaleK;
    return <String, dynamic>{
      'score100': 0.0,
      'expRaw': 0.0,
      'expDecayed': 0.0,
      'assignedExpDecayed': 0.0,
      'checkExpDecayed': 0.0,
      'completedExpDecayed': 0.0,
      'eventCount': 0,
      'assignedCount': 0,
      'checkCount': 0,
      'completedCount': 0,
      'halfLifeDays': safeHalfLife,
      'scaleK': safeScaleK,
      'formulaVersion': formulaVersion,
      'lastEventAt': null,
    };
  }

  Iterable<List<T>> _chunked<T>(List<T> source, int size) sync* {
    if (source.isEmpty) return;
    final chunkSize = size <= 0 ? 1 : size;
    for (int i = 0; i < source.length; i += chunkSize) {
      final end = (i + chunkSize < source.length) ? i + chunkSize : source.length;
      yield source.sublist(i, end);
    }
  }
}
