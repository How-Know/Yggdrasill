import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_config.dart';
import 'data_manager.dart';
import 'homework_assignment_store.dart';
import 'homework_store.dart';
import 'tenant_service.dart';
import '../utils/naesin_exam_context.dart';

/// 오늘 출결 타깃 스냅샷을 워치로 내려주기 위한 공급자.
///
/// main_screen 등 위젯 State에서 현재 출결 타깃 리스트를 직렬화한
/// `List<Map<String, dynamic>>`을 반환하도록 등록한다. 각 항목은 워치 이벤트
/// 계약(`todayTargets`)의 `items` 스키마를 따른다:
/// `{ setId, studentId, name, classDateTime, classEndTime, className,
///    sessionTypeId, status }`
typedef WatchTargetsProvider = List<Map<String, dynamic>> Function();

/// Apple Watch <-> iPhone 브리지.
///
/// 워치는 입력 리모컨 역할만 하고, 실제 데이터 로직(출결 버전 충돌, setId 해석,
/// academy 스코핑)은 전부 기존 Dart 서비스(`DataManager`)에 위임한다. 이 서비스는
/// 네이티브(AppDelegate)와의 MethodChannel 양방향 통신만 담당한다.
class WatchBridgeService {
  WatchBridgeService._();
  static final WatchBridgeService instance = WatchBridgeService._();

  static const MethodChannel _channel = MethodChannel('yggdrasill/watch');

  bool _initialized = false;

  /// main_screen이 등록하는 오늘 출결 타깃 공급자.
  WatchTargetsProvider? targetsProvider;

  /// 멱등 처리를 위한 최근 처리한 clientEventId 추적(중복 전달 방지).
  static const int _recentEventCap = 200;
  final Set<String> _recentEventIds = <String>{};
  final List<String> _recentEventOrder = <String>[];

  bool get _isSupported => !kIsWeb && Platform.isIOS;

  /// iOS에서만 MethodChannel 핸들러를 연결한다. 그 외 플랫폼은 no-op.
  void init() {
    if (_initialized || !_isSupported) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleNativeCall);
    debugPrint('[WatchBridge] initialized');
  }

  /// 워치 단독 동작용 스냅샷 발행 throttle(과도한 숙제 발행 방지).
  DateTime? _lastHomeworkPublish;

  /// 현재 오늘 출결 타깃 스냅샷을 워치로 전송(applicationContext).
  Future<void> pushTodayTargets() async {
    if (!_isSupported || !_initialized) return;
    final payload = _buildTodayTargetsPayload();
    if (payload == null) return;
    try {
      await _channel.invokeMethod<void>('sendSnapshot', payload);
    } catch (e) {
      debugPrint('[WatchBridge] sendSnapshot 실패: $e');
    }
    // 단독 동작: iPhone이 꺼져 있어도 Watch가 직접 읽을 수 있도록 서버에 발행.
    unawaited(_publishTodayTargetsSnapshot(payload));
    // 숙제 스냅샷은 비용이 크므로 최소 90초 간격으로만 발행.
    final now = DateTime.now();
    if (_lastHomeworkPublish == null ||
        now.difference(_lastHomeworkPublish!).inSeconds >= 90) {
      _lastHomeworkPublish = now;
      unawaited(publishHomeworkSnapshotsForCurrentTargets());
    }
  }

  /// iPhone 로그인 세션(JWT/refresh)과 academy를 Watch로 릴레이한다.
  /// Watch는 이 토큰으로 watch_api Edge Function을 직접 호출한다.
  Future<void> pushWatchAuth() async {
    if (!_isSupported || !_initialized) return;
    try {
      final session = Supabase.instance.client.auth.currentSession;
      final academyId = await TenantService.instance.getActiveAcademyId();
      if (session == null || academyId == null) return;
      final payload = <String, dynamic>{
        'type': 'watchAuth',
        'accessToken': session.accessToken,
        'refreshToken': session.refreshToken ?? '',
        'supabaseUrl': gResolvedSupabaseUrl,
        'anonKey': gResolvedSupabaseAnonKey,
        'academyId': academyId,
        'expiresAt': session.expiresAt ?? 0,
      };
      await _channel.invokeMethod<void>('sendWatchAuth', _stripNulls(payload));
    } catch (e) {
      debugPrint('[WatchBridge] pushWatchAuth 실패: $e');
    }
  }

  /// 오늘 출결 타깃 페이로드를 watch_snapshots(kind='today_targets')에 upsert.
  Future<void> _publishTodayTargetsSnapshot(
    Map<String, dynamic> payload,
  ) async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId();
      if (academyId == null) return;
      await Supabase.instance.client.rpc('watch_upsert_snapshot', params: {
        'p_academy_id': academyId,
        'p_kind': 'today_targets',
        'p_scope_key': 'all',
        'p_snapshot_date': _kstDateKey(DateTime.now()),
        'p_payload': {'items': payload['items'] ?? const []},
      });
    } catch (e) {
      debugPrint('[WatchBridge] today_targets 발행 실패: $e');
    }
  }

  /// 현재 오늘 타깃에 속한 학생들의 숙제 목록을 watch_snapshots(kind='homework')에 발행.
  Future<void> publishHomeworkSnapshotsForCurrentTargets() async {
    if (!_isSupported || !_initialized) return;
    final provider = targetsProvider;
    if (provider == null) return;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId();
      if (academyId == null) return;
      final items = provider();
      final studentIds = <String>{
        for (final item in items)
          if ((item['studentId'] as String?)?.trim().isNotEmpty == true)
            (item['studentId'] as String).trim(),
      };
      if (studentIds.isEmpty) return;
      final dateKey = _kstDateKey(DateTime.now());
      final bookNameById = await _loadTextbookNamesById();
      for (final studentId in studentIds) {
        try {
          final assignments = await HomeworkAssignmentStore.instance
              .loadActiveAssignments(studentId);
          final hwItems = assignments
              .where((a) => a.status != 'completed')
              .map((a) =>
                  _stripNulls(_buildWatchHomeworkItem(studentId, a, bookNameById)))
              .toList(growable: false);
          await Supabase.instance.client.rpc('watch_upsert_snapshot', params: {
            'p_academy_id': academyId,
            'p_kind': 'homework',
            'p_scope_key': studentId,
            'p_snapshot_date': dateKey,
            'p_payload': {'items': hwItems},
          });
        } catch (e) {
          debugPrint('[WatchBridge] 숙제 스냅샷($studentId) 발행 실패: $e');
        }
      }
    } catch (e) {
      debugPrint('[WatchBridge] 숙제 스냅샷 발행 실패: $e');
    }
  }

  String _kstDateKey(DateTime now) {
    // KST = UTC+9. 서버 watch_record_attendance/snapshot과 동일 기준.
    final kst = now.toUtc().add(const Duration(hours: 9));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${kst.year}-${two(kst.month)}-${two(kst.day)}';
  }

  Map<String, dynamic>? _buildTodayTargetsPayload() {
    final provider = targetsProvider;
    if (provider == null) return null;
    List<Map<String, dynamic>> items;
    try {
      items = provider();
    } catch (e) {
      debugPrint('[WatchBridge] targetsProvider 실패: $e');
      return null;
    }
    // WCSession은 null(NSNull)을 전송하지 못하므로 null 값을 모두 제거한다.
    final sanitizedItems =
        items.map((item) => _stripNulls(item)).toList(growable: false);
    return <String, dynamic>{
      'ok': true,
      'type': 'todayTargets',
      'date': DateTime.now().toIso8601String(),
      'items': sanitizedItems,
      'message': '${sanitizedItems.length}명 동기화',
    };
  }

  Map<String, dynamic> _stripNulls(Map<String, dynamic> input) {
    final out = <String, dynamic>{};
    input.forEach((key, value) {
      if (value == null) return;
      if (value is Map<String, dynamic>) {
        out[key] = _stripNulls(value);
      } else {
        out[key] = value;
      }
    });
    return out;
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onWatchEvent':
        final raw = call.arguments;
        final map = (raw is Map)
            ? raw.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};
        return _handleWatchEvent(map);
      case 'requestSnapshot':
        await _resyncAttendanceForWatch();
        await pushTodayTargets();
        return <String, dynamic>{'ok': true};
      default:
        return null;
    }
  }

  Future<Map<String, dynamic>> _handleWatchEvent(
    Map<String, dynamic> event,
  ) async {
    final type = event['type'] as String?;
    switch (type) {
      case 'requestSnapshot':
        await _resyncAttendanceForWatch();
        final payload = _buildTodayTargetsPayload();
        if (payload == null) {
          return <String, dynamic>{'ok': false, 'message': '스냅샷 준비 안 됨'};
        }
        await pushTodayTargets();
        return payload;
      case 'attendance':
        return _handleAttendance(event);
      case 'homeworkList':
        return _handleHomeworkList(event);
      case 'homeworkCheck':
        return _handleHomeworkCheck(event);
      default:
        return <String, dynamic>{'ok': false, 'message': '알 수 없는 이벤트'};
    }
  }

  /// 워치가 보낸 등원/하원 이벤트를 기존 출결 로직으로 처리한다.
  ///
  /// 워치가 스냅샷에서 받은 컨텍스트(setId/classDateTime/classEndTime/className/
  /// sessionTypeId)를 그대로 되돌려주므로, iPhone은 재해석 없이
  /// `DataManager.saveOrUpdateAttendance`를 호출한다.
  Future<Map<String, dynamic>> _handleAttendance(
    Map<String, dynamic> event,
  ) async {
    debugPrint('[WatchBridge] attendance 수신: '
        'action=${event['action']} studentId=${event['studentId']} '
        'setId=${event['setId']} classDateTime=${event['classDateTime']}');
    final clientEventId = event['clientEventId'] as String?;
    if (clientEventId != null && _isDuplicate(clientEventId)) {
      return <String, dynamic>{
        'ok': true,
        'message': '이미 처리됨',
        'duplicate': true
      };
    }

    final action = event['action'] as String?;
    final studentId = event['studentId'] as String?;
    final setId = event['setId'] as String?;
    final classDateTime = _parseDate(event['classDateTime']);
    if (studentId == null ||
        studentId.isEmpty ||
        classDateTime == null ||
        (action != 'arrival' && action != 'departure')) {
      return <String, dynamic>{'ok': false, 'message': '잘못된 출결 이벤트'};
    }

    final now = DateTime.now();
    final className = (event['className'] as String?)?.trim().isNotEmpty == true
        ? event['className'] as String
        : '수업';
    final sessionTypeId = event['sessionTypeId'] as String?;

    try {
      final existing =
          DataManager.instance.getAttendanceRecord(studentId, classDateTime);
      final classEndTime = _parseDate(event['classEndTime']) ??
          existing?.classEndTime ??
          classDateTime.add(const Duration(hours: 1));

      if (action == 'arrival') {
        await DataManager.instance.saveOrUpdateAttendance(
          studentId: studentId,
          classDateTime: classDateTime,
          classEndTime: classEndTime,
          className: className,
          isPresent: true,
          arrivalTime: now,
          setId: setId ?? existing?.setId,
          sessionTypeId: sessionTypeId ?? existing?.sessionTypeId,
          cycle: existing?.cycle,
          sessionOrder: existing?.sessionOrder,
          snapshotId: existing?.snapshotId,
          batchSessionId: existing?.batchSessionId,
        );
      } else {
        // departure: 기존 등원 시각을 보존한다.
        final arrival = existing?.arrivalTime ?? now;
        await DataManager.instance.saveOrUpdateAttendance(
          studentId: studentId,
          classDateTime: classDateTime,
          classEndTime: classEndTime,
          className: className,
          isPresent: true,
          arrivalTime: arrival,
          departureTime: now,
          setId: setId ?? existing?.setId,
          sessionTypeId: sessionTypeId ?? existing?.sessionTypeId,
          cycle: existing?.cycle,
          sessionOrder: existing?.sessionOrder,
          isPlanned: existing?.isPlanned ?? false,
          snapshotId: existing?.snapshotId,
          batchSessionId: existing?.batchSessionId,
        );
      }

      if (clientEventId != null) _markProcessed(clientEventId);
      // 변경된 로컬 상태를 기반으로 만든 스냅샷을 응답에도 담아 Watch UI가
      // applicationContext 지연 여부와 무관하게 즉시 수렴하도록 한다.
      final snapshot = _buildTodayTargetsPayload();
      if (snapshot != null) {
        await pushTodayTargets();
        return <String, dynamic>{
          ...snapshot,
          'ok': true,
          'message': action == 'arrival' ? '등원 기록됨' : '하원 기록됨',
        };
      }
      await pushTodayTargets();
      return <String, dynamic>{
        'ok': true,
        'message': action == 'arrival' ? '등원 기록됨' : '하원 기록됨',
      };
    } catch (e) {
      debugPrint('[WatchBridge] 출결 처리 실패: $e');
      return <String, dynamic>{'ok': false, 'message': '저장 실패: $e'};
    }
  }

  Future<void> _resyncAttendanceForWatch() async {
    try {
      await DataManager.instance.loadAttendanceRecords();
    } catch (e) {
      debugPrint('[WatchBridge] 출결 재동기화 실패: $e');
    }
  }

  Future<Map<String, dynamic>> _handleHomeworkList(
    Map<String, dynamic> event,
  ) async {
    final studentId = (event['studentId'] as String?)?.trim();
    if (studentId == null || studentId.isEmpty) {
      return <String, dynamic>{'ok': false, 'message': '학생 정보 없음'};
    }
    try {
      final bookNameById = await _loadTextbookNamesById();
      final assignments =
          await HomeworkAssignmentStore.instance.loadActiveAssignments(
        studentId,
      );
      final items = assignments
          .where((a) => a.status != 'completed')
          .map((a) => _buildWatchHomeworkItem(studentId, a, bookNameById))
          .toList(growable: false);
      return <String, dynamic>{
        'ok': true,
        'type': 'homeworkList',
        'studentId': studentId,
        'items': items.map(_stripNulls).toList(growable: false),
        'message': items.isEmpty ? '진행 중 숙제 없음' : '${items.length}개 숙제',
      };
    } catch (e) {
      debugPrint('[WatchBridge] 숙제 목록 실패: $e');
      return <String, dynamic>{'ok': false, 'message': '숙제 목록 실패: $e'};
    }
  }

  Map<String, dynamic> _buildWatchHomeworkItem(
    String studentId,
    HomeworkAssignmentDetail assignment,
    Map<String, String> bookNameById,
  ) {
    final homework =
        HomeworkStore.instance.getById(studentId, assignment.homeworkItemId);
    final source = homework == null
        ? '교재'
        : _extractHomeworkBookName(homework, bookNameById);
    final course = homework == null ? '' : _extractHomeworkCourseName(homework);
    final groupTitle = _firstNonEmpty([
      assignment.groupTitleSnapshot,
      assignment.title,
      '그룹과제',
    ]);
    final assignmentCode = _firstNonEmpty([
      homework?.assignmentCode,
      '',
    ]);
    final page = _firstNonEmpty([
      assignment.page,
      homework?.page,
      '',
    ]);
    return <String, dynamic>{
      'assignmentId': assignment.id,
      'homeworkItemId': assignment.homeworkItemId,
      'studentId': studentId,
      'assignmentCode': assignmentCode,
      'source': source,
      'course': course.isEmpty ? '과정' : course,
      'groupTitle': groupTitle,
      'assignedDate': _formatDate(assignment.assignedAt),
      'page': page,
      'line1': [
        if (assignmentCode.isNotEmpty) assignmentCode,
        groupTitle,
      ].join('  '),
      'line2': '$source · $course',
      'line3': _formatDate(assignment.assignedAt),
      'title': assignment.title,
      'progress': assignment.progress,
    };
  }

  Future<Map<String, String>> _loadTextbookNamesById() async {
    try {
      final rows =
          await DataManager.instance.loadResourceFilesForCategory('textbook');
      return <String, String>{
        for (final row in rows)
          if ('${row['id'] ?? ''}'.trim().isNotEmpty)
            '${row['id'] ?? ''}'.trim(): _firstNonEmpty(
                ['${row['name'] ?? ''}', '${row['book_name'] ?? ''}']),
      };
    } catch (e) {
      debugPrint('[WatchBridge] 교재명 로드 실패: $e');
      return const <String, String>{};
    }
  }

  String _extractHomeworkBookName(
    HomeworkItem homework,
    Map<String, String> bookNameById,
  ) {
    final bookId = (homework.bookId ?? '').trim();
    final linkedBookName = bookNameById[bookId]?.trim() ?? '';
    if (linkedBookName.isNotEmpty) return linkedBookName;

    final title = homework.title.trim();
    if (title.contains('·')) {
      final candidate = title.split('·').first.trim();
      if (candidate.isNotEmpty) return candidate;
    }
    final type = (homework.type ?? '').trim();
    if (type.isNotEmpty) return type;
    return '교재';
  }

  String _extractHomeworkCourseName(HomeworkItem homework) {
    final sourceUnitPath = (homework.sourceUnitPath ?? '').trim();
    final parsedLink = NaesinExamContext.parseNaesinLinkKey(sourceUnitPath);
    if (parsedLink != null) {
      return NaesinExamContext.courseLabel(parsedLink.courseKey);
    }

    final contentRaw = (homework.content ?? '').trim();
    final fromContent = RegExp(r'(?:^|\n)\s*과정:\s*([^\n]+)')
            .firstMatch(contentRaw)
            ?.group(1)
            ?.trim() ??
        '';
    if (fromContent.isNotEmpty) return fromContent;

    final gradeLabel = (homework.gradeLabel ?? '').trim();
    if (gradeLabel.isNotEmpty) return _humanCourseLabel(gradeLabel);
    return '';
  }

  String _humanCourseLabel(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    return NaesinExamContext.courseLabel(trimmed);
  }

  Future<Map<String, dynamic>> _handleHomeworkCheck(
    Map<String, dynamic> event,
  ) async {
    final studentId = (event['studentId'] as String?)?.trim();
    final assignmentId = (event['assignmentId'] as String?)?.trim();
    final homeworkItemId = (event['homeworkItemId'] as String?)?.trim();
    final rawProgress = event['progress'];
    final progress = rawProgress is num ? rawProgress.round() : null;
    if (studentId == null ||
        studentId.isEmpty ||
        assignmentId == null ||
        assignmentId.isEmpty ||
        homeworkItemId == null ||
        homeworkItemId.isEmpty ||
        progress == null) {
      return <String, dynamic>{'ok': false, 'message': '숙제 검사 정보 부족'};
    }
    try {
      final saved = await HomeworkAssignmentStore.instance.saveAssignmentCheck(
        assignmentId: assignmentId,
        studentId: studentId,
        homeworkItemId: homeworkItemId,
        progress: progress,
        markCompleted: progress >= 100,
      );
      if (!saved) {
        return <String, dynamic>{'ok': false, 'message': '숙제 검사 저장 실패'};
      }
      await HomeworkStore.instance.placeItemAtActiveTail(
        studentId,
        homeworkItemId,
        activateFromHomework: true,
      );
      if (progress >= 100) {
        await HomeworkStore.instance.submit(studentId, homeworkItemId);
      } else {
        await HomeworkStore.instance.waitPhase(studentId, homeworkItemId);
      }
      await HomeworkAssignmentStore.instance.clearActiveAssignmentsForItems(
        studentId,
        [homeworkItemId],
      );
      return <String, dynamic>{
        'ok': true,
        'message': '숙제 ${progress.clamp(0, 150)}% 기록됨',
      };
    } catch (e) {
      debugPrint('[WatchBridge] 숙제 검사 저장 실패: $e');
      return <String, dynamic>{'ok': false, 'message': '숙제 저장 오류: $e'};
    }
  }

  String _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      final text = value?.trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return '';
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.month}/${two(local.day)}';
  }

  bool _isDuplicate(String id) => _recentEventIds.contains(id);

  void _markProcessed(String id) {
    if (_recentEventIds.add(id)) {
      _recentEventOrder.add(id);
      if (_recentEventOrder.length > _recentEventCap) {
        final oldest = _recentEventOrder.removeAt(0);
        _recentEventIds.remove(oldest);
      }
    }
  }

  DateTime? _parseDate(dynamic value) {
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value);
    }
    return null;
  }
}
