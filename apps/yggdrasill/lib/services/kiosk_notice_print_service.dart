import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/homework_assign_dialog.dart'
    show buildDefaultHomeworkAssignSelection, printHomeworkTodoSheet;
import 'data_manager.dart';
import 'homework_departure_draft_service.dart';
import 'homework_store.dart';
import 'realtime_reconciler.dart';

/// 키오스크(webOS TV) 하원 시 요청된 "알림장 인쇄"를 PC(메인앱)에서 대신 수행한다.
///
/// 키오스크는 프린터로 직접 출력할 수 없으므로, kiosk_check_out 이
/// attendance_records 에 notice_print_requested_at 을 찍는다. PC 앱은
/// 이 서비스로 해당 UPDATE 를 실시간 감지해 **기존 인쇄 로직을 그대로 재사용**해
/// 알림장을 출력하고, 완료/실패를 다시 기록한다(키오스크는 이 값을 폴링해 진행 표시).
///
/// - PC 수동 하원은 notice_print_requested_at 을 세팅하지 않으므로 중복 인쇄가 없다.
/// - 완료(notice_printed_at) 또는 오류(notice_print_error)가 기록되면 재처리하지 않는다.
class KioskNoticePrintService {
  KioskNoticePrintService._();
  static final KioskNoticePrintService instance = KioskNoticePrintService._();

  RealtimeChannel? _channel;
  String? _academyId;
  final Set<String> _handled = <String>{};

  Future<void> start(String academyId) async {
    if (_academyId == academyId && _channel != null) return;
    await stop();
    _academyId = academyId;
    try {
      final chan = Supabase.instance.client
          .channel('kiosk_notice_print:$academyId')
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'attendance_records',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'academy_id',
              value: academyId,
            ),
            callback: (payload) {
              final m = payload.newRecord;
              _onUpdate(m);
            },
          );
      _channel = chan;
      RealtimeReconciler.instance.attachResubscribe(
        chan,
        key: 'kiosk_notice_print:$academyId',
        onResync: () async {},
      );
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      await _channel?.unsubscribe();
    } catch (_) {}
    _channel = null;
  }

  void _onUpdate(Map<String, dynamic> m) {
    try {
      final id = m['id'] as String?;
      if (id == null) return;
      final requestedAt = m['notice_print_requested_at'];
      final printedAt = m['notice_printed_at'];
      final error = m['notice_print_error'];
      if (requestedAt == null) return; // 인쇄 요청이 아님
      if (printedAt != null || error != null) return; // 이미 처리됨
      if (_handled.contains(id)) return;

      // 오래된 요청(예: 재접속 시점 등)에 반응하지 않도록 최근 요청만 처리.
      final reqTime = DateTime.tryParse(requestedAt as String)?.toLocal();
      if (reqTime == null) return;
      if (DateTime.now().difference(reqTime).inMinutes.abs() > 10) return;

      _handled.add(id);
      // ignore: discarded_futures
      _process(id, m);
    } catch (_) {}
  }

  Future<void> _process(String attendanceId, Map<String, dynamic> m) async {
    try {
      final studentId = m['student_id'] as String?;
      if (studentId == null) {
        await _writeError(attendanceId, '학생 정보를 찾을 수 없습니다.');
        return;
      }

      DateTime? parse(dynamic v) =>
          (v == null) ? null : DateTime.tryParse(v as String)?.toLocal();
      final classDateTime = parse(m['class_date_time']) ?? DateTime.now();
      final classEndTime = parse(m['class_end_time']);
      final arrivalTime = parse(m['arrival_time']);
      final departureTime = parse(m['departure_time']) ?? DateTime.now();
      final className = m['class_name'] as String?;
      final setId = m['set_id'] as String?;

      final departureDraft = HomeworkDepartureDraft.fromRow(m);
      HomeworkDepartureDraftService.instance.cacheFromAttendanceRow(m);

      // 저장된 초안이 있으면 정확히 그 그룹만, 없으면 기존처럼 전체 그룹을 선택한다.
      final selection = await buildDefaultHomeworkAssignSelection(
        studentId,
        anchorTime: classDateTime,
        initialSelectedGroupIds:
            departureDraft.isSaved ? departureDraft.groupIds : null,
        initialDueDateByGroupId: departureDraft.isSaved
            ? departureDraft.dueDateByGroupId
            : const <String, DateTime>{},
      );

      // 하원 시 PC 수동 흐름과 동일한 전처리.
      if (selection != null) {
        if (selection.itemIds.isNotEmpty) {
          for (final itemId in selection.itemIds) {
            HomeworkStore.instance.markItemsAsHomework(
              studentId,
              <String>[itemId],
              dueDate: selection.dueDateByItemId[itemId] ?? selection.dueDate,
              cloneCompletedItems: true,
            );
          }
        }
        final selectedIds = selection.itemIds.toSet();
        final unselected = selection.selectableItemIds
            .where((id) => !selectedIds.contains(id))
            .toList(growable: false);
        if (unselected.isNotEmpty) {
          HomeworkStore.instance.restoreItemsToWaiting(studentId, unselected);
        }
      }
      HomeworkStore.instance.convertAllTestCardsToPrintForDeparture(studentId);

      await printHomeworkTodoSheet(
        studentId: studentId,
        studentName: _studentName(studentId),
        classDateTime: classDateTime,
        arrivalTime: arrivalTime,
        departureTime: departureTime,
        selectedHomeworkIds: selection?.itemIds ?? const <String>[],
        selectedBehaviorIds: selection?.selectedBehaviorIds,
        irregularBehaviorCounts: selection?.irregularBehaviorCounts,
        dueDate: selection?.dueDate,
        className: className,
        classEndTime: classEndTime,
        setId: setId,
      );

      await _writeDone(attendanceId);
    } catch (e) {
      _handled.remove(attendanceId); // 실패 시 재시도 여지
      await _writeError(attendanceId, e.toString());
    }
  }

  String _studentName(String studentId) {
    try {
      final s = DataManager.instance.students
          .firstWhere((e) => e.student.id == studentId);
      return s.student.name;
    } catch (_) {
      return '학생';
    }
  }

  Future<void> _writeDone(String attendanceId) async {
    try {
      await Supabase.instance.client.from('attendance_records').update({
        'notice_printed_at': DateTime.now().toUtc().toIso8601String(),
        'notice_print_error': null,
      }).eq('id', attendanceId);
    } catch (_) {}
  }

  Future<void> _writeError(String attendanceId, String message) async {
    try {
      final trimmed =
          message.length > 500 ? message.substring(0, 500) : message;
      await Supabase.instance.client
          .from('attendance_records')
          .update({'notice_print_error': trimmed}).eq('id', attendanceId);
    } catch (_) {}
  }
}
