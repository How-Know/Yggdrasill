import 'package:supabase_flutter/supabase_flutter.dart';

class TodoSheetSnapshotSummary {
  const TodoSheetSnapshotSummary({
    required this.id,
    required this.attendanceId,
    required this.sessionDate,
    required this.finalizedAt,
    required this.className,
  });

  final String id;
  final String attendanceId;
  final DateTime sessionDate;
  final DateTime finalizedAt;
  final String className;

  factory TodoSheetSnapshotSummary.fromJson(Map<String, dynamic> json) {
    return TodoSheetSnapshotSummary(
      id: '${json['id'] ?? ''}',
      attendanceId: '${json['attendance_id'] ?? ''}',
      sessionDate: DateTime.parse('${json['session_date']}').toLocal(),
      finalizedAt: DateTime.parse('${json['finalized_at']}').toLocal(),
      className: '${json['class_name'] ?? ''}'.trim(),
    );
  }
}

class TodoSheetSnapshotService {
  TodoSheetSnapshotService._();

  static final TodoSheetSnapshotService instance = TodoSheetSnapshotService._();

  Future<String> finalize({
    required String attendanceId,
    required Map<String, dynamic> payload,
    int schemaVersion = 1,
    String renderVersion = 'refined_v1',
  }) async {
    final result = await Supabase.instance.client.rpc(
      'staff_finalize_todo_sheet_snapshot_v1',
      params: <String, dynamic>{
        'p_attendance_id': attendanceId,
        'p_payload': payload,
        'p_schema_version': schemaVersion,
        'p_render_version': renderVersion,
      },
    );
    return '$result';
  }

  /// 저장본의 학부모 링크 토큰. 이미 있으면 그 토큰을 다시 준다.
  Future<String> ensureShareLink(String snapshotId) async {
    final result = await Supabase.instance.client.rpc(
      'staff_ensure_todo_sheet_share_link_v1',
      params: <String, dynamic>{'p_snapshot_id': snapshotId},
    );
    final token = '$result'.trim();
    if (!RegExp(r'^[0-9a-fA-F]{32,64}$').hasMatch(token)) {
      throw StateError('알림장 링크를 만들지 못했습니다.');
    }
    return token;
  }

  Future<List<TodoSheetSnapshotSummary>> listForStudent(
    String studentId,
  ) async {
    final rows = await Supabase.instance.client
        .from('student_class_session_todo_sheet_snapshots')
        .select('id,attendance_id,session_date,finalized_at,class_name')
        .eq('student_id', studentId)
        .order('session_date', ascending: false)
        .order('finalized_at', ascending: false);
    return (rows as List<dynamic>)
        .whereType<Map>()
        .map(
          (row) => TodoSheetSnapshotSummary.fromJson(
            Map<String, dynamic>.from(row),
          ),
        )
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> loadPayload(String snapshotId) async {
    final row = await Supabase.instance.client
        .from('student_class_session_todo_sheet_snapshots')
        .select('payload')
        .eq('id', snapshotId)
        .single();
    final payload = row['payload'];
    if (payload is! Map) {
      throw StateError('알림장 스냅샷 형식이 올바르지 않습니다.');
    }
    return Map<String, dynamic>.from(payload);
  }

  /// 화면에서 이전 알림장 목록을 열 때 학생 id가 같이 필요하다.
  Future<({String studentId, Map<String, dynamic> payload})> loadForPage(
    String snapshotId,
  ) async {
    final row = await Supabase.instance.client
        .from('student_class_session_todo_sheet_snapshots')
        .select('student_id,payload')
        .eq('id', snapshotId)
        .single();
    final payload = row['payload'];
    if (payload is! Map) {
      throw StateError('알림장 스냅샷 형식이 올바르지 않습니다.');
    }
    return (
      studentId: '${row['student_id'] ?? ''}'.trim(),
      payload: Map<String, dynamic>.from(payload),
    );
  }
}
