import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 매니저앱 전역 에러 리포터.
///
/// 목적은 두 가지다.
///   1. Windows 임베더에서 간헐적으로 발생하는 `mouse_tracker.dart` 관련 assertion
///      폭주 시 "최초 1회" 의 전체 스택(원인) 을 반드시 남긴다.
///      이후 동일 계열 assertion 은 스로틀링해서 로그가 관측 방해를 일으키지 않도록.
///   2. 미처 잡히지 않은 일반 Flutter 에러와 Zone 바깥의 비동기 에러도 파일에 덤프해
///      재현 후 포렌식 용도로 남긴다.
///
/// 로그 파일 위치:
///   * Windows: `%LOCALAPPDATA%/Yggdrasill/manager_crash.log`
///   * macOS/Linux: `$HOME/.yggdrasill/manager_crash.log`
///   * 실패 시 현재 작업 디렉토리 아래 `manager_crash.log` 로 폴백.
class ErrorReporter {
  ErrorReporter._();

  static final ErrorReporter instance = ErrorReporter._();

  /// `mouse_tracker.dart` assertion 처럼 1프레임에 수십 번 튀는 에러는
  /// 여기서 카운트하며, 같은 카테고리의 첫 발생만 풀 스택으로 덤프하고
  /// 나머지는 요약 카운터로만 남긴다.
  final Map<String, _ThrottleState> _throttles = <String, _ThrottleState>{};

  File? _logFile;
  IOSink? _sink;
  bool _initialized = false;

  Future<void> install() async {
    if (_initialized) return;
    _initialized = true;

    try {
      _logFile = await _resolveLogFile();
      _sink = _logFile!.openWrite(mode: FileMode.writeOnlyAppend);
      _writeRaw('\n==== Manager session start @ ${DateTime.now().toIso8601String()} ====\n');
    } catch (e) {
      debugPrint('[ErrorReporter] failed to open log file: $e');
    }

    final prev = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      final category = _categorize(details);
      _handleFlutterError(details, precomputedCategory: category);

      // mouse_tracker 계열은 Flutter 의 debug-only assertion 이며, release/profile
      // 에서는 조용히 무시된다. debug 에서도 이걸 상위(Flutter 기본) 핸들러로
      // 넘기면 한 프레임에 수십 번 presentError 가 호출되어 콘솔/UI 스레드가
      // 먹통이 된다. 우리 쪽에서 이미 "첫 1회 풀 덤프 + 이후 스로틀 카운터" 로
      // 근본 정보를 보존했으므로 여기서 흡수해서 presentError 호출을 차단한다.
      //
      // 흡수 대상:
      //   - mouse_tracker.* 카테고리 전체
      //   - 그로 인한 2차 피해 ('Cannot hit test a render box with no size',
      //     'RenderBox was not laid out') 도 프레임당 폭주하므로 같은 취급.
      final shouldSwallow = category.startsWith('mouse_tracker.')
          || _isSecondaryLayoutStorm(details);
      if (shouldSwallow) {
        return;
      }

      if (prev != null) {
        try {
          prev(details);
        } catch (_) {
          // 상위 핸들러가 실패해도 우리 쪽은 계속.
        }
      }
    };

    // 엔진(비-Dart) 측에서 올라오는 비동기 에러. 예: platform channel 실패.
    PlatformDispatcher.instance.onError = (error, stack) {
      _report(
        category: 'PlatformDispatcher',
        summary: error.toString(),
        stack: stack,
      );
      return false; // 기본 핸들러에 계속 흘림.
    };
  }

  Future<File> _resolveLogFile() async {
    Directory dir;
    try {
      if (Platform.isWindows) {
        final localAppData = Platform.environment['LOCALAPPDATA'];
        if (localAppData != null && localAppData.isNotEmpty) {
          dir = Directory('$localAppData\\Yggdrasill');
        } else {
          dir = Directory.current;
        }
      } else {
        final home = Platform.environment['HOME'];
        if (home != null && home.isNotEmpty) {
          dir = Directory('$home/.yggdrasill');
        } else {
          dir = Directory.current;
        }
      }
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (_) {
      dir = Directory.current;
    }
    return File('${dir.path}${Platform.pathSeparator}manager_crash.log');
  }

  void _handleFlutterError(
    FlutterErrorDetails details, {
    String? precomputedCategory,
  }) {
    final category = precomputedCategory ?? _categorize(details);
    final message = details.exceptionAsString();
    final stack = details.stack;
    _report(
      category: category,
      summary: message,
      stack: stack,
      extra: {
        'library': details.library,
        'context': details.context?.toDescription(),
      },
    );
  }

  /// mouse_tracker 폭주의 2차 피해로 쏟아지는 레이아웃 관련 에러를 식별한다.
  /// 한 프레임에 수십 줄 터지는 패턴이므로 흡수 대상.
  bool _isSecondaryLayoutStorm(FlutterErrorDetails details) {
    final msg = details.exceptionAsString();
    if (msg.contains('Cannot hit test a render box with no size')) return true;
    if (msg.contains('RenderBox was not laid out')) return true;
    return false;
  }

  /// 현재 에러가 "알려진 폭주 패턴" 인지 분류. 같은 카테고리는 첫 1회만
  /// 풀 덤프하고 이후엔 카운터만 증가시킨다.
  String _categorize(FlutterErrorDetails details) {
    final msg = details.exceptionAsString();
    if (msg.contains('mouse_tracker.dart')) {
      if (msg.contains('_debugDuringDeviceUpdate')) {
        return 'mouse_tracker.debugDuringDeviceUpdate';
      }
      if (msg.contains('PointerAddedEvent') ||
          msg.contains('PointerRemovedEvent')) {
        return 'mouse_tracker.pointerLifecycle';
      }
      return 'mouse_tracker.other';
    }
    return 'general:${msg.split('\n').first}';
  }

  /// 진입점: Zone 외부/내부 어디서든 부를 수 있는 공용 보고 경로.
  void reportZoneError(Object error, StackTrace stack) {
    _report(
      category: 'Zone',
      summary: error.toString(),
      stack: stack,
    );
  }

  void _report({
    required String category,
    required String summary,
    StackTrace? stack,
    Map<String, Object?>? extra,
  }) {
    final state = _throttles.putIfAbsent(category, () => _ThrottleState());
    state.count += 1;

    final isFirst = state.count == 1;
    // 동일 카테고리의 2회차 이상은 1초에 한 번씩만 요약 로그.
    final now = DateTime.now();
    if (!isFirst) {
      if (state.lastSummaryAt != null &&
          now.difference(state.lastSummaryAt!) < const Duration(seconds: 1)) {
        return;
      }
      state.lastSummaryAt = now;
      _writeRaw(
        '[ErrorReporter] $category x${state.count} (repeating, throttled)\n',
      );
      return;
    }

    state.lastSummaryAt = now;

    final buf = StringBuffer();
    buf.writeln('');
    buf.writeln('──── [ErrorReporter] FIRST OCCURRENCE ────');
    buf.writeln('time    : ${now.toIso8601String()}');
    buf.writeln('category: $category');
    buf.writeln('summary : $summary');
    if (extra != null && extra.isNotEmpty) {
      extra.forEach((k, v) {
        if (v != null) buf.writeln('$k: $v');
      });
    }
    if (stack != null) {
      buf.writeln('stack   :');
      buf.writeln(stack.toString());
    } else {
      buf.writeln('stack   : (none)');
    }
    buf.writeln('──────────────────────────────────────────');
    final text = buf.toString();

    // 콘솔과 파일 양쪽에 모두 남긴다. 콘솔은 debugPrint 로 라인 잘림 방지.
    for (final line in text.split('\n')) {
      debugPrint(line);
    }
    _writeRaw(text);
  }

  void _writeRaw(String text) {
    try {
      _sink?.write(text);
      // 중요한 1회 덤프가 있으므로 즉시 flush.
      _sink?.flush();
    } catch (_) {
      // 로그 파일 쓰기 실패는 조용히 무시(앱 자체 동작에 영향 주지 않음).
    }
  }
}

class _ThrottleState {
  int count = 0;
  DateTime? lastSummaryAt;
}
