import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'realtime_reconciler.dart';

/// M5 질문 버튼 → Supabase `m5_student_question_requests` 미확인 행 (홈 칩용).
class M5QuestionRequestEntry {
  final String id;
  final String studentDisplayName;

  const M5QuestionRequestEntry({
    required this.id,
    required this.studentDisplayName,
  });

  static M5QuestionRequestEntry? fromRow(Map<String, dynamic> row) {
    final id = row['id'] as String?;
    if (id == null || id.isEmpty) return null;
    final name = (row['student_display_name'] as String?)?.trim() ?? '';
    return M5QuestionRequestEntry(
      id: id,
      studentDisplayName: name.isEmpty ? '학생' : name,
    );
  }
}

class M5QuestionRequestStore {
  M5QuestionRequestStore._();
  static final M5QuestionRequestStore instance = M5QuestionRequestStore._();

  final ValueNotifier<List<M5QuestionRequestEntry>> pending =
      ValueNotifier<List<M5QuestionRequestEntry>>([]);

  RealtimeChannel? _channel;
  String? _academyId;

  Future<void> start(String academyId) async {
    final aid = academyId.trim();
    if (aid.isEmpty) return;
    if (_academyId == aid && _channel != null) return;
    await stop();
    _academyId = aid;
    await reload();
    try {
      _channel = Supabase.instance.client
          .channel('public:m5_student_question_requests:$aid')
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'm5_student_question_requests',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'academy_id',
            value: aid,
          ),
          callback: (_) {
            unawaited(reload());
          },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'm5_student_question_requests',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'academy_id',
            value: aid,
          ),
          callback: (_) {
            unawaited(reload());
          },
        );
      RealtimeReconciler.instance.attachResubscribe(
        _channel!,
        key: 'm5_student_question_requests:$aid',
        onResync: () async {
          try {
            await reload();
          } catch (_) {}
        },
      );
    } catch (e, st) {
      debugPrint('[M5_Q][rt] subscribe failed: $e\n$st');
    }
  }

  Future<void> stop() async {
    try {
      await _channel?.unsubscribe();
    } catch (_) {}
    _channel = null;
    _academyId = null;
    pending.value = [];
  }

  Future<void> reload() async {
    final aid = _academyId;
    if (aid == null || aid.isEmpty) return;
    try {
      final rows = await Supabase.instance.client
          .from('m5_student_question_requests')
          .select('id, student_display_name, created_at')
          .eq('academy_id', aid)
          .isFilter('acknowledged_at', null)
          .order('created_at', ascending: true);
      final list = <M5QuestionRequestEntry>[];
      for (final raw in (rows as List<dynamic>)) {
        if (raw is! Map<String, dynamic>) continue;
        final e = M5QuestionRequestEntry.fromRow(raw);
        if (e != null) list.add(e);
      }
      pending.value = list;
    } catch (e, st) {
      debugPrint('[M5_Q] reload failed: $e\n$st');
    }
  }

  Future<void> acknowledge(String requestId) async {
    if (requestId.isEmpty) return;
    try {
      await Supabase.instance.client.rpc(
        'm5_ack_student_question_request',
        params: {'p_request_id': requestId},
      );
      await reload();
    } catch (e, st) {
      debugPrint('[M5_Q] ack failed: $e\n$st');
    }
  }
}
