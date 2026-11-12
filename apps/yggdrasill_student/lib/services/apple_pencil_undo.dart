import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// 애플 펜슬의 시스템 동작과 문제 풀기를 잇는다.
///
/// 프로를 쥐면 실행 취소 슬라이더가 뜨고, 등록된 획을 되돌린다.
/// 옆면을 두 번 두드리면 문제 풀기 하단의 ‘한 단계 지우기’와 같다.
/// 설정이 색 팔레트이거나 끄기이면 두드림은 무시한다.
class ApplePencilUndo {
  ApplePencilUndo._();

  static const _channel = MethodChannel('yggdrasill.student/apple_pencil_undo');
  static bool _handlerReady = false;
  static Object? _owner;
  static Object? _eraseOwner;
  static void Function()? _onUndo;
  static void Function()? _onRedo;
  static void Function()? _onErase;

  static bool get enabled => !kIsWeb && Platform.isIOS;

  static void bind({
    required Object owner,
    required void Function() onUndo,
    required void Function() onRedo,
  }) {
    _owner = owner;
    _onUndo = onUndo;
    _onRedo = onRedo;
    _ensureHandler();
  }

  /// 두 번 두드리면 [onErase]를 부른다. 문제 풀기 하단 지우기와 같은 함수를 넘긴다.
  static void bindErase({
    required Object owner,
    required void Function() onErase,
  }) {
    _eraseOwner = owner;
    _onErase = onErase;
    _ensureHandler();
    if (!enabled) return;
    unawaited(_invoke('attach'));
  }

  static void unbindErase(Object owner) {
    if (_eraseOwner != owner) return;
    _eraseOwner = null;
    _onErase = null;
  }

  static void _ensureHandler() {
    if (_handlerReady) return;
    _handlerReady = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'undo':
          _onUndo?.call();
        case 'redo':
          _onRedo?.call();
        case 'erase':
          _onErase?.call();
      }
    });
  }

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  static void unbind(Object owner) {
    if (_owner != owner) return;
    _owner = null;
    _onUndo = null;
    _onRedo = null;
    unawaited(reset());
  }

  /// 끝난 획 하나를 시스템 실행 취소 스택에 올린다.
  static Future<bool> push() async {
    if (!enabled) return false;
    try {
      final registered = await _channel.invokeMethod<bool>('push');
      return registered ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 화면에서 이미 뺀 획과 같은 단계를 시스템 스택에서도 뺀다.
  /// 우리 단계가 맨 위가 아니면 false.
  static Future<bool> noteLocalUndo() async {
    if (!enabled) return false;
    try {
      final handled = await _channel.invokeMethod<bool>('noteLocalUndo');
      return handled ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> reset() async {
    if (!enabled) return;
    try {
      await _channel.invokeMethod<void>('reset');
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }
}
