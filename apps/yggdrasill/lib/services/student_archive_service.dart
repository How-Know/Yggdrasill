import 'package:supabase_flutter/supabase_flutter.dart';

import 'data_manager.dart';

class StudentArchiveMeta {
  final String id;
  final String studentId;
  final String studentName;
  final DateTime? archivedAt;
  final DateTime? purgeAfter;

  const StudentArchiveMeta({
    required this.id,
    required this.studentId,
    required this.studentName,
    required this.archivedAt,
    required this.purgeAfter,
  });

  factory StudentArchiveMeta.fromMap(Map<String, dynamic> m) {
    DateTime? parseDt(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      return DateTime.tryParse(v.toString());
    }

    return StudentArchiveMeta(
      id: (m['id'] ?? '').toString(),
      studentId: (m['student_id'] ?? '').toString(),
      studentName: (m['student_name'] ?? '').toString(),
      archivedAt: parseDt(m['archived_at']),
      purgeAfter: parseDt(m['purge_after']),
    );
  }
}

class StudentArchiveRestoreOptions {
  final bool includeHistory;
  final bool deleteArchiveAfter;

  const StudentArchiveRestoreOptions({
    this.includeHistory = false,
    this.deleteArchiveAfter = false,
  });
}

class StudentArchiveRestoreResult {
  final List<String> historyErrors;

  const StudentArchiveRestoreResult({
    this.historyErrors = const <String>[],
  });

  bool get hasHistoryErrors => historyErrors.isNotEmpty;
}

class StudentArchiveService {
  StudentArchiveService._();
  static final StudentArchiveService instance = StudentArchiveService._();

  DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

  Future<List<StudentArchiveMeta>> loadArchives({
    required String academyId,
    String searchText = '',
    DateTime? startInclusive,
    DateTime? endInclusive,
    int limit = 300,
  }) async {
    final supa = Supabase.instance.client;
    var q = supa
        .from('student_archives')
        .select('id,student_id,student_name,archived_at,purge_after')
        .eq('academy_id', academyId);

    if (startInclusive != null && endInclusive != null) {
      final start = _startOfDay(startInclusive);
      final endExclusive =
          _startOfDay(endInclusive).add(const Duration(days: 1));
      q = q.gte('archived_at', start.toUtc().toIso8601String());
      q = q.lt('archived_at', endExclusive.toUtc().toIso8601String());
    }

    final text = searchText.trim();
    if (text.isNotEmpty) {
      q = q.ilike('student_name', '%$text%');
    }

    final rows = await q.order('archived_at', ascending: false).limit(limit);
    return (rows as List)
        .map((m) => StudentArchiveMeta.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<Map<String, dynamic>> loadPayload(String archiveId) async {
    final supa = Supabase.instance.client;
    final row = await supa
        .from('student_archives')
        .select('payload')
        .eq('id', archiveId)
        .maybeSingle();
    if (row == null) return {};
    final payload = row['payload'];
    if (payload is Map) return Map<String, dynamic>.from(payload);
    return {'payload': payload};
  }

  Future<bool> studentExistsOnServer({
    required String academyId,
    required String studentId,
  }) async {
    final supa = Supabase.instance.client;
    final row = await supa
        .from('students')
        .select('id')
        .eq('academy_id', academyId)
        .eq('id', studentId)
        .maybeSingle();
    return row != null;
  }

  Future<StudentArchiveRestoreResult> restoreArchive({
    required String academyId,
    required StudentArchiveMeta meta,
    required StudentArchiveRestoreOptions options,
  }) async {
    final payload = await loadPayload(meta.id);
    final supa = Supabase.instance.client;

    Map<String, dynamic>? asMap(dynamic v) {
      if (v is Map) return Map<String, dynamic>.from(v);
      return null;
    }

    List<Map<String, dynamic>> asListOfMaps(dynamic v) {
      if (v is List) {
        return v
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
      }
      return const [];
    }

    final studentRow = asMap(payload['students']);
    if (studentRow == null) {
      throw Exception('payload.students가 비어있습니다.');
    }
    studentRow['academy_id'] = academyId;
    await supa.from('students').upsert(studentRow, onConflict: 'id');

    final basicInfoRow = asMap(payload['student_basic_info']);
    if (basicInfoRow != null) {
      basicInfoRow['academy_id'] = academyId;
      basicInfoRow['student_id'] = meta.studentId;
      await supa
          .from('student_basic_info')
          .upsert(basicInfoRow, onConflict: 'student_id');
    }

    final paymentInfoRow = asMap(payload['student_payment_info']);
    if (paymentInfoRow != null) {
      paymentInfoRow['academy_id'] = academyId;
      paymentInfoRow['student_id'] = meta.studentId;
      await supa
          .from('student_payment_info')
          .upsert(paymentInfoRow, onConflict: 'student_id');
    }

    final timeBlocks = asListOfMaps(payload['student_time_blocks']);
    await supa
        .from('student_time_blocks')
        .delete()
        .eq('academy_id', academyId)
        .eq('student_id', meta.studentId);
    if (timeBlocks.isNotEmpty) {
      final rows = [
        for (final r in timeBlocks)
          {
            ...r,
            'academy_id': academyId,
            'student_id': meta.studentId,
          }
      ];
      await supa.from('student_time_blocks').upsert(rows, onConflict: 'id');
    }

    final historyErrors = <String>[];
    if (options.includeHistory) {
      Future<void> upsertChunked(
        String table,
        List<Map<String, dynamic>> rows, {
        required String onConflict,
      }) async {
        const chunk = 200;
        for (int i = 0; i < rows.length; i += chunk) {
          final part = rows.sublist(i, (i + chunk).clamp(0, rows.length));
          await supa.from(table).upsert(part, onConflict: onConflict);
        }
      }

      Future<void> tryStep(String label, Future<void> Function() fn) async {
        try {
          await fn();
        } catch (e) {
          historyErrors.add('$label: $e');
        }
      }

      final payments = asListOfMaps(payload['payment_records']);
      await tryStep('납부 기록', () async {
        if (payments.isEmpty) return;
        final rows = [
          for (final r in payments)
            {
              ...r,
              'academy_id': academyId,
              'student_id': meta.studentId,
            }
        ];
        await upsertChunked('payment_records', rows, onConflict: 'id');
      });

      final overrides = asListOfMaps(payload['session_overrides']);
      await tryStep('보강 기록', () async {
        if (overrides.isEmpty) return;
        final hasOccurrencesInPayload =
            payload.containsKey('lesson_occurrences');
        final rows = [
          for (final r in overrides)
            {
              ...r,
              'academy_id': academyId,
              'student_id': meta.studentId,
              'occurrence_id':
                  hasOccurrencesInPayload ? r['occurrence_id'] : null,
            }
        ];
        await upsertChunked('session_overrides', rows, onConflict: 'id');
      });

      final attendance = asListOfMaps(payload['attendance_records']);
      await tryStep('출석 기록', () async {
        if (attendance.isEmpty) return;
        final hasSnapshotsInPayload =
            payload.containsKey('lesson_snapshot_headers');
        final hasBatchSessionsInPayload =
            payload.containsKey('lesson_batch_sessions');
        final hasOccurrencesInPayload =
            payload.containsKey('lesson_occurrences');
        final rows = [
          for (final r in attendance)
            {
              ...r,
              'academy_id': academyId,
              'student_id': meta.studentId,
              'snapshot_id': hasSnapshotsInPayload ? r['snapshot_id'] : null,
              'batch_session_id':
                  hasBatchSessionsInPayload ? r['batch_session_id'] : null,
              'occurrence_id':
                  hasOccurrencesInPayload ? r['occurrence_id'] : null,
            }
        ];
        await upsertChunked('attendance_records', rows, onConflict: 'id');
      });
    }

    if (options.deleteArchiveAfter) {
      await supa
          .from('student_archives')
          .delete()
          .eq('academy_id', academyId)
          .eq('id', meta.id);
    }

    try {
      await DataManager.instance.loadStudents();
      await DataManager.instance.loadStudentTimeBlocks();
    } catch (_) {}

    return StudentArchiveRestoreResult(historyErrors: historyErrors);
  }
}
