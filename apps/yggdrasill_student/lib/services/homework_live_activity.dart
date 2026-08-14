import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:live_activities/live_activities.dart';
import 'package:live_activities/models/activity_update.dart';
import 'package:live_activities/models/live_activity_state.dart';
import 'package:live_activities/models/url_scheme_data.dart';

import '../widgets/homework_now_playing_bar.dart';
import 'homework_session.dart';
import 'student_attendance_session.dart';

/// iOS Live Activity 브리지 — 미니바와 같은 과제 수행 상태.
///
/// Windows/Android에서는 no-op.
/// iOS에서 보이려면 Xcode에서 Widget Extension 타깃을 한 번 추가해야 한다
/// (`ios/HomeworkLiveActivity/` 템플릿 참고).
class HomeworkLiveActivity with WidgetsBindingObserver {
  HomeworkLiveActivity._();
  static final HomeworkLiveActivity instance = HomeworkLiveActivity._();

  static const appGroupId = 'group.com.beleunu.yggdrasillStudent';
  static const urlScheme = 'yggstudent';
  static const _activityPrefix = 'homework:';

  final LiveActivities _plugin = LiveActivities();
  StreamSubscription<UrlSchemeData>? _urlSub;
  StreamSubscription<ActivityUpdate>? _activitySub;
  Timer? _tick;
  bool _started = false;
  String? _activityKey;
  String? _activityId;

  /// 우리가 스스로 종료한 액티비티. 학생이 끈 것과 구분해야 한다.
  final Set<String> _endedByUs = <String>{};

  Future<void> start() async {
    if (_started || kIsWeb || !Platform.isIOS) return;
    _started = true;
    try {
      await _plugin.init(
        appGroupId: appGroupId,
        urlScheme: urlScheme,
        requestAndroidNotificationPermission: false,
      );
      HomeworkSession.instance.addListener(_onSessionChanged);
      StudentAttendanceSession.instance.addListener(_onSessionChanged);
      _urlSub = _plugin.urlSchemeStream().listen(_onUrlScheme);
      _activitySub = _plugin.activityUpdateStream.listen(_onActivityUpdate);
      WidgetsBinding.instance.addObserver(this);
      await _sync();
    } catch (e, st) {
      debugPrint('[HW][live] init failed: $e\n$st');
    }
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    HomeworkSession.instance.removeListener(_onSessionChanged);
    StudentAttendanceSession.instance.removeListener(_onSessionChanged);
    WidgetsBinding.instance.removeObserver(this);
    await _urlSub?.cancel();
    _urlSub = null;
    await _activitySub?.cancel();
    _activitySub = null;
    _tick?.cancel();
    _tick = null;
    await _endCurrentActivity(allIfUnknown: true);
  }

  /// 학생이 잠금화면에서 라이브 액티비티를 지우면 "그만한다"는 뜻으로 본다.
  /// 우리가 끝낸 것(과제 전환·로그아웃)과 구분해서 그때만 되감는다.
  void _onActivityUpdate(ActivityUpdate update) {
    update.mapOrNull(
      active: (state) {
        if (_activityKey != null) _activityId = state.activityId;
      },
      ended: (state) {
        final id = state.activityId;
        if (_endedByUs.remove(id)) return;
        if (_activityKey == null) return;
        if (_activityId != null && _activityId != id) return;
        _activityId = null;
        _activityKey = null;
        unawaited(
          HomeworkSession.instance
              .rewindToLastBeat(reason: 'live_activity_ended'),
        );
      },
    );
  }

  void _onSessionChanged() => unawaited(_sync());

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_verifyAfterResume());
  }

  /// 앱이 죽어 있는 동안 학생이 라이브 액티비티를 지웠을 수 있다.
  /// 돌아왔을 때 수행 중인데 액티비티가 없으면 그 사이는 인정하지 않는다.
  Future<void> _verifyAfterResume() async {
    if (!_started || !Platform.isIOS) return;
    final session = HomeworkSession.instance;
    final group = session.active;
    if (group == null || !session.isRunningGroup(group.groupId)) return;
    try {
      if (!await _plugin.areActivitiesSupported()) return;
      final state = await _plugin.getActivityState(
        '$_activityPrefix${group.groupId}',
      );
      if (state == LiveActivityState.active ||
          state == LiveActivityState.stale) {
        return;
      }
    } catch (e) {
      debugPrint('[HW][live] resume check failed: $e');
      return;
    }
    await session.rewindToLastBeat(reason: 'live_activity_missing');
  }

  Future<void> _sync() async {
    if (!_started || !Platform.isIOS) return;
    final session = HomeworkSession.instance;
    final group = session.active;
    if (group == null) {
      _tick?.cancel();
      _tick = null;
      await _endCurrentActivity(allIfUnknown: true);
      return;
    }

    final running = session.isRunningGroup(group.groupId);
    _ensureTicker(running);
    await _push(groupId: group.groupId, running: running);
  }

  void _ensureTicker(bool running) {
    if (running && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 15), (_) {
        unawaited(_sync());
      });
    } else if (!running && _tick != null) {
      _tick?.cancel();
      _tick = null;
    }
  }

  Future<void> _push({
    required String groupId,
    required bool running,
  }) async {
    final session = HomeworkSession.instance;
    final group = session.active;
    if (group == null || group.groupId != groupId) return;

    final elapsed = running
        ? group.liveCycleElapsed()
        : (group.cycleElapsed < 0 ? 0 : group.cycleElapsed);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // 카운트업 타이머 앵커 = 지금 − 이미 경과한 초.
    final timerAnchorMs = nowMs - elapsed * 1000;
    final activityKey = '$_activityPrefix$groupId';
    final data = <String, dynamic>{
      'title': group.title.isEmpty ? '(제목 없음)' : group.title,
      'subtitle': group.primaryMetaLine,
      'isRunning': running ? '1' : '0',
      'statusLabel': running ? '수행 중' : '일시정지',
      'elapsedLabel': HomeworkNowPlayingBar.formatCycleElapsed(elapsed),
      'elapsedSec': elapsed,
      'timerAnchorMs': timerAnchorMs.toDouble(),
      'groupId': groupId,
      // 등원 중에만 제출을 받는다. 잠금화면 버튼도 같이 흐려진다.
      'canSubmit': StudentAttendanceSession.instance.isAtAcademy ? '1' : '0',
    };

    try {
      final supported = await _plugin.areActivitiesSupported();
      if (!supported) return;
      if (_activityKey != null && _activityKey != activityKey) {
        await _endCurrentActivity();
      }
      final result = await _plugin.createOrUpdateActivity(
        activityKey,
        data,
        removeWhenAppIsKilled: false,
        iOSEnableRemoteUpdates: false,
      );
      _activityKey = activityKey;
      if (result is String && result.isNotEmpty) _activityId = result;
    } catch (e) {
      debugPrint('[HW][live] push failed: $e');
    }
  }

  Future<void> _endCurrentActivity({bool allIfUnknown = false}) async {
    final endId = _activityId ?? _activityKey;
    _activityId = null;
    _activityKey = null;
    if (endId == null) {
      if (!allIfUnknown) return;
      try {
        _endedByUs.addAll(await _plugin.getAllActivitiesIds());
        await _plugin.endAllActivities();
      } catch (_) {}
      return;
    }
    try {
      // 앱 재시작 뒤에는 custom key만 알고 실제 ActivityKit id를 모를 수 있다.
      // 종료 이벤트를 사용자 삭제로 오인하지 않도록 현재 id들도 함께 표시한다.
      _endedByUs.addAll(await _plugin.getAllActivitiesIds());
    } catch (_) {}
    _endedByUs.add(endId);
    try {
      await _plugin.endActivity(endId);
    } catch (_) {}
  }

  void _onUrlScheme(UrlSchemeData data) {
    if (data.scheme != urlScheme) return;
    final host = (data.host ?? '').toLowerCase();
    final path = (data.path ?? '').toLowerCase();
    final action = host.isNotEmpty
        ? host
        : path.replaceFirst(RegExp(r'^/'), '').split('/').first;
    unawaited(_handleAction(action));
  }

  Future<void> _handleAction(String action) async {
    final session = HomeworkSession.instance;
    if (action == 'toggle' || action == 'playpause') {
      final group = session.active;
      if (group == null) return;
      if (session.isRunningGroup(group.groupId)) {
        await session.pause();
      } else {
        await session.play(group.groupId);
      }
      return;
    }
    if (action == 'submit') {
      // 잠금화면에서는 안내를 띄울 수 없다. 등원 중이 아니면 조용히 무시하고
      // 앱에서 이유를 보게 한다 (서버도 같은 규칙으로 거절한다).
      if (!StudentAttendanceSession.instance.isAtAcademy) return;
      await session.submit();
    }
  }
}
