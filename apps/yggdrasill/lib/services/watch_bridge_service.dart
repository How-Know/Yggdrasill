import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/services.dart';

import 'data_manager.dart';

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
    final sanitizedItems = items
        .map((item) => _stripNulls(item))
        .toList(growable: false);
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
        final payload = _buildTodayTargetsPayload();
        if (payload == null) {
          return <String, dynamic>{'ok': false, 'message': '스냅샷 준비 안 됨'};
        }
        await pushTodayTargets();
        return payload;
      case 'attendance':
        return _handleAttendance(event);
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
      return <String, dynamic>{'ok': true, 'message': '이미 처리됨', 'duplicate': true};
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
    final className =
        (event['className'] as String?)?.trim().isNotEmpty == true
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
      // 변경된 상태를 워치로 즉시 반영.
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
