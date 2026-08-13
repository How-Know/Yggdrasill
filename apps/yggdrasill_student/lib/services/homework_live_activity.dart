import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:live_activities/live_activities.dart';
import 'package:live_activities/models/activity_update.dart';
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
    WidgetsBinding.instance.removeObserver(this);
    await _urlSub?.cancel();
    _urlSub = null;
    await _activitySub?.cancel();
    _activitySub = null;
    _tick?.cancel();
    _tick = null;
    try {
      if (_activityId != null) {
        _endedByUs.add(_activityId!);
        await _plugin.endActivity(_activityId!);
      } else {
        await _plugin.endAllActivities();
      }
    } catch (_) {}
    _activityId = null;
  }

  /// 학생이 잠금화면에서 라이브 액티비티를 지우면 "그만한다"는 뜻으로 본다.
  /// 우리가 끝낸 것(과제 전환·로그아웃)과 구분해서 그때만 되감는다.
  void _onActivityUpdate(ActivityUpdate update) {
    update.mapOrNull(
      ended: (state) {
        final id = state.activityId;
        if (_endedByUs.remove(id)) return;
        if (!id.startsWith(_activityPrefix)) return;
        if (_activityId == id) _activityId = null;
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
      final ids = await _plugin.getAllActivitiesIds();
      if (ids.contains('$_activityPrefix${group.groupId}')) return;
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
      final id = _activityId;
      _activityId = null;
      if (id != null) {
        _endedByUs.add(id);
        try {
          await _plugin.endActivity(id);
        } catch (_) {}
      }
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
    final activityId = '$_activityPrefix$groupId';
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
      await _plugin.createOrUpdateActivity(
        activityId,
        data,
        removeWhenAppIsKilled: false,
        iOSEnableRemoteUpdates: false,
      );
      _activityId = activityId;
    } catch (e) {
      debugPrint('[HW][live] push failed: $e');
    }
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
