import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:live_activities/live_activities.dart';
import 'package:live_activities/models/url_scheme_data.dart';

import '../widgets/homework_now_playing_bar.dart';
import 'homework_session.dart';

/// iOS Live Activity 브리지 — 미니바와 같은 과제 수행 상태.
///
/// Windows/Android에서는 no-op.
/// iOS에서 보이려면 Xcode에서 Widget Extension 타깃을 한 번 추가해야 한다
/// (`ios/HomeworkLiveActivity/` 템플릿 참고).
class HomeworkLiveActivity {
  HomeworkLiveActivity._();
  static final HomeworkLiveActivity instance = HomeworkLiveActivity._();

  static const appGroupId = 'group.com.beleunu.yggdrasillStudent';
  static const urlScheme = 'yggstudent';
  static const _activityPrefix = 'homework:';

  final LiveActivities _plugin = LiveActivities();
  StreamSubscription<UrlSchemeData>? _urlSub;
  Timer? _tick;
  bool _started = false;
  String? _activityId;

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
      await _sync();
    } catch (e, st) {
      debugPrint('[HW][live] init failed: $e\n$st');
    }
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    HomeworkSession.instance.removeListener(_onSessionChanged);
    await _urlSub?.cancel();
    _urlSub = null;
    _tick?.cancel();
    _tick = null;
    try {
      if (_activityId != null) {
        await _plugin.endActivity(_activityId!);
      } else {
        await _plugin.endAllActivities();
      }
    } catch (_) {}
    _activityId = null;
  }

  void _onSessionChanged() => unawaited(_sync());

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
      await session.submit();
    }
  }
}
