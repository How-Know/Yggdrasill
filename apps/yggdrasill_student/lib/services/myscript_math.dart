import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart';

/// MyScript iink 수식 인식 브리지 (iOS 네이티브, PoC).
///
/// 획 좌표를 네이티브 Math Recognizer 로 배치 재생해 LaTeX 를 받는다.
/// 인증서(MyCertificate.c)가 플레이스홀더거나 초기화에 실패하면
/// [available] 이 false 를 돌려주고, 호출부는 기존 ML Kit 경로를 쓴다.
class MyScriptMath {
  MyScriptMath._();

  static final instance = MyScriptMath._();

  static const _channel = MethodChannel('yggdrasill.student/myscript_math');

  bool? _available;
  String _status = 'unknown';

  /// 진단용 상태 (ready / certificate_missing / channel_error 등).
  String get status => _status;

  /// 엔진 사용 가능 여부. 최초 1회만 네이티브에 물어보고 캐시한다.
  Future<bool> available() async {
    final cached = _available;
    if (cached != null) return cached;
    if (kIsWeb || !Platform.isIOS) {
      _available = false;
      _status = 'unsupported_platform';
      return false;
    }
    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('isAvailable')
          .timeout(const Duration(seconds: 10));
      _available = result?['available'] == true;
      _status = (result?['status'] as String?) ?? 'unknown';
    } catch (e) {
      debugPrint('MyScript availability check failed: $e');
      _available = false;
      _status = 'channel_error';
    }
    return _available!;
  }

  /// iink 실물 리소스의 지원 자산 타입·기호·규칙 목록을 진단용으로 가져온다.
  Future<String> dumpRecognitionAssets() async {
    if (kIsWeb || !Platform.isIOS) return 'unsupported_platform';
    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('dumpRecognitionAssets')
          .timeout(const Duration(seconds: 20));
      return (result?['dump'] as String?) ?? 'empty_dump';
    } catch (e) {
      debugPrint('MyScript asset dump failed: $e');
      return 'channel_error: $e';
    }
  }

  /// 획 데이터를 인식해 LaTeX 문자열을 돌려준다. 실패·빈 결과는 null.
  ///
  /// [strokes]: [{'x': [double], 'y': [double], 't': [int(ms)]}]
  /// 좌표는 필기 캔버스 논리 픽셀 기준.
  Future<String?> recognizeLatex(List<Map<String, dynamic>> strokes) async {
    if (strokes.isEmpty) return null;
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'recognize',
        <String, dynamic>{'strokes': strokes},
      ).timeout(const Duration(seconds: 8));
      final error = result?['error'];
      if (error is String && error.isNotEmpty) {
        debugPrint('MyScript recognize error: $error');
      }
      final latex = result?['latex'];
      if (latex is! String) return null;
      final trimmed = latex.trim();
      return trimmed.isEmpty ? null : trimmed;
    } catch (e) {
      debugPrint('MyScript recognize failed: $e');
      return null;
    }
  }
}
