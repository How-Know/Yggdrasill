// MyScript iink 네이티브 캔버스 (iOS 플랫폼뷰).
//
// iink 의 EditorViewController 를 그대로 띄운다 — 실시간 잉크 렌더링과
// 점진적 수식 인식, convert(잉크 → 조판 수식)를 SDK 가 직접 처리한다.
// 자체 구현 캔버스(PencilInputPad)와의 비교/선택용.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MyScriptEditorController {
  MethodChannel? _channel;

  void _attach(int viewId) {
    _channel = MethodChannel('yggdrasill.student/myscript_editor_$viewId');
  }

  bool get isAttached => _channel != null;

  Future<void> clear() async => _channel?.invokeMethod<void>('clear');

  Future<void> undo() async => _channel?.invokeMethod<void>('undo');

  Future<void> redo() async => _channel?.invokeMethod<void>('redo');

  /// 잉크를 조판된 수식으로 변환. 실패하면 에러 메시지를 돌려준다.
  Future<String?> convert() async =>
      _channel?.invokeMethod<String>('convert');

  /// 현재 인식 결과 LaTeX. 없으면 null.
  Future<String?> exportLatex() async =>
      _channel?.invokeMethod<String>('exportLatex');

  Future<String?> status() async => _channel?.invokeMethod<String>('status');
}

class MyScriptEditorView extends StatelessWidget {
  const MyScriptEditorView({super.key, required this.controller});

  final MyScriptEditorController controller;

  static bool get supported => !kIsWeb && Platform.isIOS;

  @override
  Widget build(BuildContext context) {
    if (!supported) {
      return const Center(child: Text('iOS에서만 지원돼요.'));
    }
    return UiKitView(
      viewType: 'myscript_editor_view',
      onPlatformViewCreated: controller._attach,
      // 필기 터치를 Flutter 제스처 아레나에 넘기지 않고 즉시 네이티브
      // InputView 로 전달한다. 이게 없으면 주변 스크롤/제스처가 획을
      // 가로채 잉크가 그려지지 않는다.
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
      },
    );
  }
}
