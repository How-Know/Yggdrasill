import 'dart:async';

import 'package:flutter/foundation.dart';

import 'student_api.dart';
import 'student_attendance_session.dart';
import 'student_install_id.dart';

/// 학생앱 온라인 presence — 학습앱에 학원/집 로그인 상태를 보여 주기 위한 heartbeat.
/// iOS 는 1인 1기기: 다른 iPad 가 클레임하면 이 기기는 로그아웃아웃된다.
class StudentPresenceSession {
  StudentPresenceSession._();
  static final StudentPresenceSession instance = StudentPresenceSession._();

  static const Duration _interval = Duration(seconds: 25);

  bool _started = false;
  Timer? _timer;
  DateTime? _lastArrival;
  DateTime? _lastDeparture;
  String? _iosInstallId;
  Future<void> Function()? _onIosDeviceReplaced;

  /// 다른 iPad 로그인으로 밀려났을 때 (보통 signOut).
  void setOnIosDeviceReplaced(Future<void> Function()? handler) {
    _onIosDeviceReplaced = handler;
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    StudentAttendanceSession.instance.addListener(_onAttendanceChanged);
    _lastArrival = StudentAttendanceSession.instance.arrival;
    _lastDeparture = StudentAttendanceSession.instance.departure;
    _iosInstallId = await StudentInstallId.iosInstallIdOrNull();
    if (_iosInstallId != null) {
      try {
        await StudentApi.instance.claimIosDevice(_iosInstallId!);
      } catch (e) {
        debugPrint('[PRESENCE] ios claim failed: $e');
      }
    }
    await _beat();
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => unawaited(_beat()));
  }

  Future<void> stop({bool markOffline = true}) async {
    _started = false;
    StudentAttendanceSession.instance.removeListener(_onAttendanceChanged);
    _timer?.cancel();
    _timer = null;
    if (!markOffline) return;
    try {
      await StudentApi.instance.presenceOffline();
    } catch (e) {
      debugPrint('[PRESENCE] offline failed: $e');
    }
  }

  void _onAttendanceChanged() {
    final arrival = StudentAttendanceSession.instance.arrival;
    final departure = StudentAttendanceSession.instance.departure;
    if (arrival == _lastArrival && departure == _lastDeparture) return;
    _lastArrival = arrival;
    _lastDeparture = departure;
    unawaited(_beat());
  }

  Future<void> _beat() async {
    if (!_started || !StudentApi.instance.isLoggedIn) return;
    try {
      final result = await StudentApi.instance.presenceHeartbeat(
        iosInstallId: _iosInstallId,
      );
      if (result.iosDeviceReplaced) {
        debugPrint('[PRESENCE] ios device replaced — signing out');
        final handler = _onIosDeviceReplaced;
        if (handler != null) {
          await handler();
        } else {
          await StudentApi.instance.signOut();
        }
      }
    } catch (e) {
      debugPrint('[PRESENCE] heartbeat failed: $e');
    }
  }
}
