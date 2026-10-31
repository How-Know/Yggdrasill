import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../widgets/departure_summary_dialog.dart'
    show
        applyDepartureSummaryAfterSave,
        buildAutoDepartureSummary,
        finalizeDepartureTodoSheetSnapshot;
import '../widgets/homework_assign_dialog.dart' show printHomeworkTodoSheet;
import '../widgets/todo_sheet_share_link_dialog.dart';
import 'data_manager.dart';
import 'homework_departure_draft_service.dart';
import 'homework_store.dart';
import 'print_routing_service.dart';
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
  String? _workerId;
  Timer? _pendingPollTimer;
  bool _pendingLoadRunning = false;
  final Set<String> _handledRequestKeys = <String>{};
  final Set<String> _remoteShareStarted = <String>{};
  final Map<String, Future<void>> _printJobs = <String, Future<void>>{};

  Future<void> start(String academyId) async {
    final normalizedAcademyId = academyId.trim();
    if (normalizedAcademyId.isEmpty) return;
    if (_academyId == normalizedAcademyId && _channel != null) return;
    await stop();
    _academyId = normalizedAcademyId;
    try {
      _workerId = await _ensureWorkerId();
      final chan = Supabase.instance.client
          .channel('kiosk_notice_print:$normalizedAcademyId')
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'attendance_records',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'academy_id',
              value: normalizedAcademyId,
            ),
            callback: (payload) {
              final m = payload.newRecord;
              _onUpdate(m);
            },
          );
      _channel = chan;
      RealtimeReconciler.instance.attachResubscribe(
        chan,
        key: 'kiosk_notice_print:$normalizedAcademyId',
        onResync: () => _loadRecentPendingRequests(normalizedAcademyId),
        skipFirstSubscribed: false,
      );
      // 구독 완료 직전 들어온 UPDATE도 놓치지 않도록 즉시 한 번 조회한다.
      await _loadRecentPendingRequests(normalizedAcademyId);
      _pendingPollTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(_loadRecentPendingRequests(normalizedAcademyId)),
      );
      debugPrint(
          '[KIOSK_PRINT] started academy=$normalizedAcademyId worker=$_workerId');
    } catch (e, st) {
      debugPrint('[KIOSK_PRINT][START_ERROR] $e\n$st');
    }
  }

  Future<void> stop() async {
    _pendingPollTimer?.cancel();
    _pendingPollTimer = null;
    try {
      await _channel?.unsubscribe();
    } catch (_) {}
    _channel = null;
    _academyId = null;
  }

  void _onUpdate(Map<String, dynamic> m) {
    _scheduleRemoteShareLink(m);
    try {
      final id = m['id'] as String?;
      if (id == null) return;
      final requestedAt = m['notice_print_requested_at'];
      final printedAt = m['notice_printed_at'];
      final error = m['notice_print_error'];
      if (requestedAt == null) return; // 인쇄 요청이 아님
      if (printedAt != null || error != null) return; // 이미 처리됨

      // 오래된 요청(예: 재접속 시점 등)에 반응하지 않도록 최근 요청만 처리.
      final reqTime = DateTime.tryParse(requestedAt as String)?.toLocal();
      if (reqTime == null) return;
      if (DateTime.now().difference(reqTime).inMinutes.abs() > 10) return;

      // attendance id가 재사용되더라도 새 requested_at은 별도 요청이다.
      final requestKey = '$id|${reqTime.toUtc().toIso8601String()}';
      if (!_handledRequestKeys.add(requestKey)) return;
      debugPrint('[KIOSK_PRINT] request id=$id requestedAt=$requestedAt');
      final job = _claimAndProcess(id, requestKey, m);
      _printJobs[id] = job;
    } catch (e, st) {
      debugPrint('[KIOSK_PRINT][UPDATE_ERROR] $e\n$st');
    }
  }

  /// 스탠바이미 하원은 이 PC의 하원 버튼과 달리 출결 갱신으로만 들어온다.
  /// 알림장에 동의한 학생만, 인쇄가 있으면 인쇄 뒤에 같은 링크 창을 띄운다.
  void _scheduleRemoteShareLink(Map<String, dynamic> m) {
    final id = (m['id'] as String?)?.trim() ?? '';
    final studentId = (m['student_id'] as String?)?.trim() ?? '';
    if (id.isEmpty || studentId.isEmpty) return;
    final departure =
        DateTime.tryParse('${m['departure_time'] ?? ''}')?.toLocal();
    if (departure == null) return;
    if (DateTime.now().difference(departure).inMinutes.abs() > 10) return;
    if (todoSheetShareLinkOwnedByThisApp(id, studentId: studentId)) return;
    if (!studentAllowsTodoSheetShareLink(studentId)) return;
    if (!_remoteShareStarted.add(id)) return;
    scheduleMicrotask(() {
      unawaited(_finalizeRemoteShareLink(m));
    });
  }

  Future<void> _finalizeRemoteShareLink(Map<String, dynamic> m) async {
    final attendanceId = (m['id'] as String?)?.trim() ?? '';
    final studentId = (m['student_id'] as String?)?.trim() ?? '';
    if (attendanceId.isEmpty || studentId.isEmpty) return;
    final printJob = _printJobs[attendanceId];
    if (printJob != null) {
      try {
        await printJob;
      } catch (e, st) {
        debugPrint('[KIOSK_PRINT][SHARE_WAIT] $e\n$st');
      }
    }
    try {
      DateTime? parse(dynamic v) =>
          (v == null) ? null : DateTime.tryParse('$v')?.toLocal();
      final classDateTime = parse(m['class_date_time']) ?? DateTime.now();
      final arrivalTime = parse(m['arrival_time']);
      final departureTime = parse(m['departure_time']) ?? DateTime.now();
      final studentName = _studentName(studentId);
      HomeworkDepartureDraftService.instance.cacheFromAttendanceRow(m);
      await HomeworkStore.instance.reloadStudentHomework(studentId);
      final summary = await buildAutoDepartureSummary(
        studentId: studentId,
        attendanceId: attendanceId,
        classDateTime: classDateTime,
        arrivalTime: arrivalTime,
      );
      try {
        await applyDepartureSummaryAfterSave(
          studentId: studentId,
          attendanceId: attendanceId,
          result: summary,
        );
      } catch (e, st) {
        debugPrint('[KIOSK_PRINT][SHARE_CONFIRM] $e\n$st');
      }
      final snapshotId = await finalizeDepartureTodoSheetSnapshot(
        attendanceId: attendanceId,
        studentId: studentId,
        studentName: studentName,
        classDateTime: classDateTime,
        arrivalTime: arrivalTime,
        departureTime: departureTime,
        result: summary,
        className: m['class_name'] as String?,
        classEndTime: parse(m['class_end_time']),
        setId: m['set_id'] as String?,
      );
      await showTodoSheetShareLinkOnRoot(
        studentId: studentId,
        studentName: studentName,
        snapshotId: snapshotId,
      );
    } catch (e, st) {
      debugPrint('[KIOSK_PRINT][SHARE_LINK] $e\n$st');
      reportTodoSheetShareLinkFailure('알림장 링크를 만들지 못했어요: $e');
    }
  }

  Future<void> _claimAndProcess(
    String attendanceId,
    String requestKey,
    Map<String, dynamic> m,
  ) async {
    final workerId = _workerId;
    if (workerId == null) {
      _handledRequestKeys.remove(requestKey);
      return;
    }
    try {
      // 알림장 프린터가 지정되지 않은 PC가 요청을 먼저 선점하지 않게 한다.
      final configuredPrinter = await PrintRoutingService.instance
          .loadConfiguredPrinter(PrintRoutingChannel.todoSheet);
      if ((configuredPrinter ?? '').trim().isEmpty) {
        _handledRequestKeys.remove(requestKey);
        debugPrint('[KIOSK_PRINT] skip claim: todo printer is not configured');
        return;
      }
      final result = await Supabase.instance.client.rpc(
        'kiosk_notice_print_claim',
        params: {
          'p_attendance_id': attendanceId,
          'p_worker_id': workerId,
        },
      );
      if (result is! Map || result['claimed'] != true) {
        debugPrint(
            '[KIOSK_PRINT] claim skipped id=$attendanceId result=$result');
        return;
      }
      debugPrint(
          '[KIOSK_PRINT] claimed id=$attendanceId printer=$configuredPrinter');
      await _process(attendanceId, m);
    } catch (e, st) {
      _handledRequestKeys.remove(requestKey);
      debugPrint('[KIOSK_PRINT][CLAIM_ERROR] id=$attendanceId $e\n$st');
    }
  }

  Future<void> _loadRecentPendingRequests(String academyId) async {
    if (_pendingLoadRunning) return;
    _pendingLoadRunning = true;
    try {
      final cutoff = DateTime.now()
          .toUtc()
          .subtract(const Duration(minutes: 10))
          .toIso8601String();
      final rowsRaw = await Supabase.instance.client
          .from('attendance_records')
          .select()
          .eq('academy_id', academyId)
          .not('notice_print_requested_at', 'is', null)
          .isFilter('notice_printed_at', null)
          .isFilter('notice_print_error', null)
          .gte('notice_print_requested_at', cutoff)
          .order('notice_print_requested_at')
          .limit(20);
      final rows = (rowsRaw as List<dynamic>).cast<Map<String, dynamic>>();
      if (rows.isNotEmpty) {
        debugPrint('[KIOSK_PRINT] pending resync count=${rows.length}');
      }
      for (final row in rows) {
        _onUpdate(row);
      }
    } catch (e, st) {
      debugPrint('[KIOSK_PRINT][RESYNC_ERROR] $e\n$st');
    } finally {
      _pendingLoadRunning = false;
    }
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

      HomeworkDepartureDraftService.instance.cacheFromAttendanceRow(m);
      await HomeworkStore.instance.reloadStudentHomework(studentId);

      // 숙제는 고르지 않는다. 수업 계획의 오늘·숙제만 싣고 다음은 뺀다.
      // M5 는 하원 전에, 스탠바이미는 하원 뒤에 요청하므로 둘 다 같은 결과가 나와야 한다.
      // 오늘→숙제 전환은 departure_time 트리거가 처리한다.
      final summary = await buildAutoDepartureSummary(
        studentId: studentId,
        attendanceId: attendanceId,
        classDateTime: classDateTime,
        arrivalTime: arrivalTime,
      );
      try {
        await applyDepartureSummaryAfterSave(
          studentId: studentId,
          attendanceId: attendanceId,
          result: summary,
        );
      } catch (e, st) {
        debugPrint('[KIOSK_PRINT][CONFIRM_ERROR] id=$attendanceId $e\n$st');
      }
      HomeworkStore.instance.convertAllTestCardsToPrintForDeparture(studentId);

      await printHomeworkTodoSheet(
        studentId: studentId,
        studentName: _studentName(studentId),
        classDateTime: classDateTime,
        arrivalTime: arrivalTime,
        departureTime: departureTime,
        selectedHomeworkIds: summary.homeworkItemIds,
        additionalHomeworkIds: summary.rolloverItemIds,
        selectedBehaviorIds: summary.selectedBehaviorIds,
        irregularBehaviorCounts: summary.irregularBehaviorCounts,
        dueDate: summary.dueDate,
        className: className,
        classEndTime: classEndTime,
        setId: setId,
      );

      await _writeDone(attendanceId);
    } catch (e) {
      await _writeError(attendanceId, e.toString());
    }
  }

  Future<String> _ensureWorkerId() async {
    const key = 'kiosk_notice_print_worker_id';
    final prefs = await SharedPreferences.getInstance();
    final saved = (prefs.getString(key) ?? '').trim();
    if (saved.isNotEmpty) return saved;
    final created = 'pc:${const Uuid().v4()}';
    await prefs.setString(key, created);
    return created;
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
    final workerId = _workerId;
    if (workerId == null) return;
    try {
      await Supabase.instance.client.rpc(
        'kiosk_notice_print_complete',
        params: {
          'p_attendance_id': attendanceId,
          'p_worker_id': workerId,
        },
      );
    } catch (_) {}
  }

  Future<void> _writeError(String attendanceId, String message) async {
    final workerId = _workerId;
    if (workerId == null) return;
    try {
      final trimmed =
          message.length > 500 ? message.substring(0, 500) : message;
      await Supabase.instance.client.rpc(
        'kiosk_notice_print_fail',
        params: {
          'p_attendance_id': attendanceId,
          'p_worker_id': workerId,
          'p_error': trimmed,
        },
      );
    } catch (_) {}
  }
}
