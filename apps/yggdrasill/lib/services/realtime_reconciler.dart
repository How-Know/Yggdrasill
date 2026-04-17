import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show
        RealtimeChannel,
        RealtimeSubscribeStatus,
        Supabase;

/// 리얼타임 채널이 구독에 성공하거나 재연결될 때마다, 구독자가 놓쳤을 수
/// 있는 변경분을 '전량 재로드' 콜백으로 한 번씩 흘려주기 위한 얇은 유틸.
///
/// - 네트워크가 잠깐 끊겨 리얼타임 이벤트를 놓쳐도, 재연결 직후 전체 로더가
///   한 번 돌아 상태를 서버 기준으로 수렴시킨다.
/// - 전역 rate-limit(표시 가능한 토스트 없이) 기본 3초 쿨다운을 두어, 동시에
///   여러 채널이 동일 로더를 연타 호출하지 않도록 방어한다.
/// - 앱 생명주기·네트워크 이벤트 훅은 여기서 직접 걸지 않는다. 각 구독자가
///   `attachResubscribe` 호출 지점을 제공하면 재구독 때마다 콜백이 실행된다.
class RealtimeReconciler {
  RealtimeReconciler._();
  static final RealtimeReconciler instance = RealtimeReconciler._();

  final Map<String, DateTime> _lastRunByKey = <String, DateTime>{};
  Duration minInterval = const Duration(seconds: 3);
  bool debug = false;

  /// 재구독 시 수행할 콜백을 등록한다.
  /// - [key]가 같은 콜백은 [minInterval] 내 중복 실행을 건너뛴다.
  /// - 첫 `subscribed` 는 보통 초기 로드 이후라 2회 호출을 피하기 위해
  ///   [skipFirstSubscribed]=true 옵션을 두었다.
  void attachResubscribe(
    RealtimeChannel channel, {
    required String key,
    required Future<void> Function() onResync,
    bool skipFirstSubscribed = true,
  }) {
    bool sawFirstSubscribed = false;
    channel.subscribe((status, [err]) async {
      if (err != null) {
        if (debug) {
          debugPrint('[RT][$key] subscribe error: $err');
        }
      }
      if (status == RealtimeSubscribeStatus.subscribed) {
        if (skipFirstSubscribed && !sawFirstSubscribed) {
          sawFirstSubscribed = true;
          if (debug) {
            debugPrint('[RT][$key] first subscribed (skip initial resync)');
          }
          return;
        }
        await _runThrottled(key, onResync);
      } else if (debug) {
        debugPrint('[RT][$key] status=$status');
      }
    });
  }

  /// 외부에서 강제로 재동기화를 트리거하고 싶을 때 사용.
  Future<void> runNow(String key, Future<void> Function() onResync) =>
      _runThrottled(key, onResync);

  Future<void> _runThrottled(
      String key, Future<void> Function() onResync) async {
    final now = DateTime.now();
    final last = _lastRunByKey[key];
    if (last != null && now.difference(last) < minInterval) {
      if (debug) {
        debugPrint(
            '[RT][$key] skip resync (cooldown ${now.difference(last).inMilliseconds}ms)');
      }
      return;
    }
    _lastRunByKey[key] = now;
    try {
      if (debug) debugPrint('[RT][$key] resync start');
      await onResync();
      if (debug) debugPrint('[RT][$key] resync done');
    } catch (e, st) {
      debugPrint('[RT][$key] resync failed: $e');
      if (debug) debugPrint(st.toString());
    }
  }

  /// 전체 리얼타임 연결을 수동으로 새로 맺고 싶을 때(예: 포그라운드 복귀).
  Future<void> kickAllChannels() async {
    try {
      final rt = Supabase.instance.client.realtime;
      rt.disconnect();
      // supabase_flutter 에서는 channel.subscribe() 가 호출될 때 자동으로 connect() 됨.
    } catch (_) {}
  }
}
