import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as mlkit;

import '../services/handwriting_ink_png.dart';

/// ML Kit 모델과 인식기를 앱 전체에서 한 번만 준비해 재사용한다.
///
/// 문항을 바꿀 때마다 새 인식기를 만들면 iOS에서 모델 다운로드가 중복되거나
/// 메모리 매핑이 실패할 수 있다.
class _DigitalInkService {
  _DigitalInkService._();

  static final instance = _DigitalInkService._();
  static const model = 'en-US';
  static const _channel = MethodChannel(
    'google_mlkit_digital_ink_recognizer',
  );

  mlkit.DigitalInkRecognizer? _recognizer;
  Future<mlkit.DigitalInkRecognizer>? _initializing;

  Future<mlkit.DigitalInkRecognizer> prepare({
    required VoidCallback onDownloading,
  }) {
    final ready = _recognizer;
    if (ready != null) return Future.value(ready);
    final running = _initializing;
    if (running != null) return running;

    final future = _prepare(onDownloading);
    _initializing = future;
    future.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {
        _initializing = null;
      },
    );
    return future;
  }

  Future<mlkit.DigitalInkRecognizer> _prepare(
    VoidCallback onDownloading,
  ) async {
    final manager = mlkit.DigitalInkRecognizerModelManager();
    var downloaded = await manager
        .isModelDownloaded(model)
        .timeout(const Duration(seconds: 10));
    if (!downloaded) {
      onDownloading();
      final ok = await manager
          .downloadModel(model, isWifiRequired: false)
          .timeout(const Duration(seconds: 75));
      if (!ok) throw StateError('모델 다운로드가 완료되지 않았습니다.');
      downloaded = await manager
          .isModelDownloaded(model)
          .timeout(const Duration(seconds: 10));
    }
    if (!downloaded) throw StateError('다운로드된 필기 모델을 찾지 못했습니다.');

    final recognizer = mlkit.DigitalInkRecognizer(languageCode: model);
    _recognizer = recognizer;
    return recognizer;
  }

  /// 플러그인 0.15.0은 iOS가 정수 score를 반환하면 이를 double로 직접
  /// 캐스팅하다 예외를 낸다. 수정 버전이 배포될 때까지 동일 네이티브 채널을
  /// 호출하되 num 타입을 허용해 정상 인식 결과를 보존한다.
  Future<List<String>> recognize(
    mlkit.DigitalInkRecognizer recognizer,
    mlkit.Ink ink,
    mlkit.DigitalInkRecognitionContext context,
  ) async {
    final result = await _channel.invokeMethod<List<dynamic>>(
          'vision#startDigitalInkRecognizer',
          <String, dynamic>{
            'id': recognizer.id,
            'ink': ink.toJson(),
            'context': context.toJson(),
            'model': model,
          },
        ) ??
        const <dynamic>[];

    return result
        .whereType<Map<dynamic, dynamic>>()
        .map((candidate) => candidate['text'])
        .whereType<String>()
        .toList(growable: false);
  }
}

/// 애플펜슬(터치) 필기 → ML Kit 온디바이스 인식.
///
/// 획이 멈추면 잠시 후 자동으로 인식해 [onRecognized]로 전달한다.
/// 인식 결과는 화면에 즉시 표시되므로 학생이 틀린 인식을 바로 고칠 수 있다.
class PencilInputPad extends StatefulWidget {
  const PencilInputPad({
    super.key,
    required this.onRecognized,
    this.candidateSelector,
    this.remoteRecognizer,
    this.onSnapshot,
    this.height = 220,
    this.showControls = true,
    this.showEmptyHint = true,
    this.embedded = false,
  });

  final ValueChanged<String> onRecognized;

  /// 인식 후보 목록에서 답으로 쓸 후보를 고른다.
  /// null 반환 = "답 형태 후보 없음" → [remoteRecognizer] 폴백을 시도한다.
  /// 콜백 자체가 null이면 첫 번째 후보를 쓴다.
  final String? Function(List<String> candidates)? candidateSelector;

  /// VLM 2차 인식 폴백. 온디바이스 후보가 전부 답 형태가 아니거나
  /// 인식이 실패했을 때, 필기 렌더 PNG 를 넘기면 인식 텍스트를 돌려준다.
  final Future<String?> Function(Uint8List png)? remoteRecognizer;

  /// 인식을 시도할 때마다(실패 포함) 필기 스냅샷을 전달한다.
  /// 호출부가 문항별로 보관해 두면 패드가 언마운트된 뒤에도
  /// 신고(필기 인식 불량)에 첨부할 수 있다.
  final ValueChanged<Map<String, dynamic>>? onSnapshot;

  final double height;
  final bool showControls;
  final bool showEmptyHint;
  final bool embedded;

  static bool get supported =>
      !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  @override
  State<PencilInputPad> createState() => PencilInputPadState();
}

class PencilInputPadState extends State<PencilInputPad> {
  /// 획이 끝난 뒤 이 시간 동안 새 입력이 없어야 인식을 시작한다.
  /// 여러 획으로 된 글자(예: 4, 분수)를 쓰는 도중 잘려 인식되는 것을 막는다.
  static const Duration recognitionDelay = Duration(seconds: 2);

  final List<List<Offset>> _strokes = <List<Offset>>[];
  final List<List<int>> _strokeTimes = <List<int>>[];
  /// 포인트별 정규화 압력(0~1). 압력 정보가 없는 기기는 -1.
  final List<List<double>> _strokePressures = <List<double>>[];
  int? _activePointer;
  /// 동시에 내려온 포인터 수. 2개 이상이면 필기를 막고(두 손가락 스와이프용)
  /// 진행 중 획을 취소한다.
  int _pointerCount = 0;

  mlkit.DigitalInkRecognizer? _recognizer;
  bool _modelReady = false;
  bool _modelDownloading = false;
  String? _modelError;
  String? _recognitionError;
  bool _recognizing = false;
  Timer? _debounce;
  Size _canvasSize = Size.zero;

  /// 마지막 인식 시점의 필기 스냅샷 — 신고(필기 인식 불량) 첨부용.
  Map<String, dynamic>? _lastRecognitionSnapshot;

  /// 마지막 인식 이후 획이 바뀌었는지. 스냅샷의 획·후보 정합성 판단용.
  bool _strokesDirty = false;

  @override
  void initState() {
    super.initState();
    _prepareModel();
  }

  Future<void> _prepareModel() async {
    if (!PencilInputPad.supported) {
      setState(() => _modelError = '이 기기에서는 필기 인식을 지원하지 않아요.');
      return;
    }
    setState(() {
      _modelReady = false;
      _modelDownloading = false;
      _modelError = null;
    });
    try {
      final recognizer = await _DigitalInkService.instance.prepare(
        onDownloading: () {
          if (mounted) setState(() => _modelDownloading = true);
        },
      );
      if (!mounted) return;
      setState(() {
        _recognizer = recognizer;
        _modelReady = true;
        _modelDownloading = false;
      });
    } catch (e, stack) {
      debugPrint('Digital ink model preparation failed: $e\n$stack');
      if (!mounted) return;
      setState(() {
        _modelDownloading = false;
        _modelError = e is TimeoutException
            ? '필기 모델 다운로드가 지연되고 있어요.'
            : '필기 모델을 준비하지 못했어요.';
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // 인식기는 앱 전체에서 재사용하므로 여기서 닫지 않는다.
    super.dispose();
  }

  /// 기기가 실제 압력을 주는 경우 0~1로 정규화, 아니면 -1(정보 없음).
  double _normalizedPressure(PointerEvent event) {
    final range = event.pressureMax - event.pressureMin;
    if (range <= 0) return -1;
    final value = (event.pressure - event.pressureMin) / range;
    if (!value.isFinite) return -1;
    return value.clamp(0.0, 1.0).toDouble();
  }

  void _startStroke(Offset position, int timestamp, double pressure) {
    _debounce?.cancel();
    _strokesDirty = true;
    setState(() {
      _strokes.add(<Offset>[position]);
      _strokeTimes.add(<int>[timestamp]);
      _strokePressures.add(<double>[pressure]);
    });
  }

  void _extendStroke(Offset position, int timestamp, double pressure) {
    if (_strokes.isEmpty) return;
    final previous = _strokes.last.last;
    final previousTime = _strokeTimes.last.last;
    final previousPressure = _strokePressures.last.last;
    final distance = (position - previous).distance;
    // 손떨림 수준의 미세 이동은 방향 노이즈만 만들므로 무시.
    if (distance < 0.6) return;
    // 1.8px 간격 보간 — 빠른 획도 끊김 없이 촘촘하게 채운다.
    final steps = (distance / 1.8).ceil().clamp(1, 64);
    setState(() {
      for (var step = 1; step <= steps; step++) {
        final t = step / steps;
        _strokes.last.add(Offset.lerp(previous, position, t)!);
        _strokeTimes.last.add(
          previousTime + ((timestamp - previousTime) * t).round(),
        );
        _strokePressures.last.add(
          (previousPressure < 0 || pressure < 0)
              ? pressure
              : previousPressure + (pressure - previousPressure) * t,
        );
      }
    });
  }

  void _endStroke() {
    _debounce?.cancel();
    _debounce = Timer(recognitionDelay, _recognize);
  }

  /// 두 손가락 제스처가 시작되면 방금 시작한 획을 버린다.
  void _cancelActiveStroke() {
    _debounce?.cancel();
    _activePointer = null;
    if (_strokes.isEmpty) return;
    setState(() {
      _strokes.removeLast();
      _strokeTimes.removeLast();
      _strokePressures.removeLast();
    });
  }

  Future<void> _recognize() async {
    final recognizer = _recognizer;
    if (recognizer == null || _strokes.isEmpty || _recognizing) return;
    setState(() {
      _recognizing = true;
      _recognitionError = null;
    });
    try {
      final ink = mlkit.Ink();
      for (var i = 0; i < _strokes.length; i++) {
        final stroke = mlkit.Stroke();
        for (var j = 0; j < _strokes[i].length; j++) {
          stroke.points.add(mlkit.StrokePoint(
            x: _strokes[i][j].dx,
            y: _strokes[i][j].dy,
            t: _strokeTimes[i][j],
          ));
        }
        ink.strokes.add(stroke);
      }
      final context = mlkit.DigitalInkRecognitionContext(
        writingArea: mlkit.WritingArea(
          width: _canvasSize.width,
          height: _canvasSize.height,
        ),
      );
      final candidates = await _DigitalInkService.instance.recognize(
        recognizer,
        ink,
        context,
      );
      String selected = '';
      var needFallback = candidates.isEmpty;
      if (candidates.isNotEmpty) {
        if (widget.candidateSelector != null) {
          final picked = widget.candidateSelector!(candidates)?.trim();
          if (picked == null || picked.isEmpty) {
            // 온디바이스 후보 전부가 답 형태가 아님 → VLM 폴백 시도.
            selected = candidates.first.trim();
            needFallback = true;
          } else {
            selected = picked;
          }
        } else {
          selected = candidates.first.trim();
        }
      }
      var usedRemote = false;
      if (needFallback) {
        final remote = await _tryRemoteRecognize();
        if (remote != null) {
          selected = remote;
          usedRemote = true;
        }
      }
      _publishSnapshot(
        candidates,
        recognizedText: selected,
        usedRemoteFallback: usedRemote,
      );
      if (!mounted || selected.isEmpty) return;
      widget.onRecognized(selected);
    } catch (e, stack) {
      debugPrint('Digital ink recognition failed: $e\n$stack');
      // 온디바이스 인식 자체가 실패해도 VLM 폴백은 시도한다.
      final remote = await _tryRemoteRecognize();
      if (remote != null) {
        _publishSnapshot(
          const <String>[],
          recognizedText: remote,
          usedRemoteFallback: true,
        );
        if (mounted) widget.onRecognized(remote);
      } else {
        // 인식 실패도 신고 대상이므로 획 스냅샷은 남긴다.
        _publishSnapshot(const <String>[]);
        if (mounted) {
          setState(() => _recognitionError = '인식하지 못했어요. 다시 써 주세요.');
        }
      }
    } finally {
      if (mounted) setState(() => _recognizing = false);
    }
  }

  void _clear() {
    _debounce?.cancel();
    setState(() {
      _strokes.clear();
      _strokeTimes.clear();
      _strokePressures.clear();
    });
  }

  void _undo() {
    if (_strokes.isEmpty) return;
    _strokesDirty = true;
    setState(() {
      _strokes.removeLast();
      _strokeTimes.removeLast();
      _strokePressures.removeLast();
    });
    _endStroke();
  }

  bool undoStroke() {
    _undo();
    return _strokes.isNotEmpty;
  }

  void clearStrokes() => _clear();

  /// VLM 2차 인식 폴백. 현재 획을 PNG 로 렌더해 [widget.remoteRecognizer]에
  /// 넘긴다. 실패·타임아웃·빈 결과는 모두 null (호출부가 기존 동작 유지).
  Future<String?> _tryRemoteRecognize() async {
    final recognizer = widget.remoteRecognizer;
    if (recognizer == null || _strokes.isEmpty) return null;
    try {
      // await 중 학생이 이어 쓸 수 있으므로 획을 복사해 렌더한다.
      final png = await renderHandwritingPng(
        strokes: <List<Offset>>[for (final s in _strokes) List.of(s)],
        canvasSize: _canvasSize,
      );
      if (png == null) return null;
      final text = await recognizer(png).timeout(const Duration(seconds: 12));
      final trimmed = text?.trim() ?? '';
      return trimmed.isEmpty ? null : trimmed;
    } catch (e) {
      debugPrint('Remote handwriting fallback failed: $e');
      return null;
    }
  }

  /// 인식 시도 직후 스냅샷을 갱신하고 호출부에 전달한다.
  void _publishSnapshot(
    List<String> candidates, {
    String recognizedText = '',
    bool usedRemoteFallback = false,
  }) {
    final snapshot = _buildSnapshot(
      candidates,
      recognizedText: recognizedText,
      usedRemoteFallback: usedRemoteFallback,
    );
    _lastRecognitionSnapshot = snapshot;
    _strokesDirty = false;
    widget.onSnapshot?.call(snapshot);
  }

  Map<String, dynamic> _buildSnapshot(
    List<String> candidates, {
    String recognizedText = '',
    bool usedRemoteFallback = false,
  }) {
    return <String, dynamic>{
      'canvas_width': _canvasSize.width,
      'canvas_height': _canvasSize.height,
      'model': _DigitalInkService.model,
      'recognized_candidates': candidates,
      'recognized_text': recognizedText,
      if (usedRemoteFallback) 'used_remote_fallback': true,
      'captured_at': DateTime.now().toUtc().toIso8601String(),
      'strokes': <Map<String, dynamic>>[
        for (var i = 0; i < _strokes.length; i++)
          <String, dynamic>{
            'x': [for (final p in _strokes[i]) _round2(p.dx)],
            'y': [for (final p in _strokes[i]) _round2(p.dy)],
            't': _strokeTimes[i],
            'p': [for (final v in _strokePressures[i]) _round2(v)],
          },
      ],
    };
  }

  static double _round2(double v) => (v * 100).roundToDouble() / 100;

  /// 신고(필기 인식 불량) 첨부용 필기 데이터.
  ///
  /// 마지막 인식 이후 획이 그대로면 그 스냅샷을(획·후보 정합), 인식 전에
  /// 획이 바뀌었으면 현재 획을 후보 없이 돌려준다. 획을 모두 지웠으면
  /// 마지막 인식 스냅샷. 필기 이력이 전혀 없으면 null.
  Map<String, dynamic>? get handwritingReportPayload {
    if (_strokes.isEmpty) return _lastRecognitionSnapshot;
    if (!_strokesDirty && _lastRecognitionSnapshot != null) {
      return _lastRecognitionSnapshot;
    }
    return _buildSnapshot(const <String>[]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (_modelError != null) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$_modelError\nWi-Fi 연결을 확인한 뒤 다시 시도해 주세요.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.hintColor),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _prepareModel,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('다시 준비하기'),
              ),
            ],
          ),
        ),
      );
    }

    return SizedBox(
      height: widget.height,
      child: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
                return Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _modelReady
                      ? (event) {
                          _pointerCount += 1;
                          // 두 손가락 이상: 필기 대신 상위 스와이프 제스처에 맡긴다.
                          if (_pointerCount >= 2) {
                            _cancelActiveStroke();
                            return;
                          }
                          if (_activePointer != null) return;
                          _activePointer = event.pointer;
                          _startStroke(
                            event.localPosition,
                            event.timeStamp.inMilliseconds,
                            _normalizedPressure(event),
                          );
                        }
                      : null,
                  onPointerMove: _modelReady
                      ? (event) {
                          if (_pointerCount >= 2) return;
                          if (_activePointer != event.pointer) return;
                          _extendStroke(
                            event.localPosition,
                            event.timeStamp.inMilliseconds,
                            _normalizedPressure(event),
                          );
                        }
                      : null,
                  onPointerUp: _modelReady
                      ? (event) {
                          _pointerCount =
                              (_pointerCount - 1).clamp(0, 10).toInt();
                          if (_activePointer != event.pointer) return;
                          _activePointer = null;
                          if (_pointerCount == 0) _endStroke();
                        }
                      : null,
                  onPointerCancel: _modelReady
                      ? (event) {
                          _pointerCount =
                              (_pointerCount - 1).clamp(0, 10).toInt();
                          if (_activePointer != event.pointer) return;
                          _activePointer = null;
                          if (_pointerCount == 0) _endStroke();
                        }
                      : null,
                  child: Container(
                    decoration: BoxDecoration(
                      color: widget.embedded
                          ? Colors.transparent
                          : (isDark
                              ? Colors.white.withValues(alpha: 0.04)
                              : Colors.black.withValues(alpha: 0.03)),
                      borderRadius:
                          BorderRadius.circular(widget.embedded ? 0 : 14),
                      border: widget.embedded
                          ? null
                          : Border.all(
                              color: theme.dividerColor.withValues(alpha: 0.4),
                            ),
                    ),
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _StrokePainter(
                          strokes: _strokes,
                          times: _strokeTimes,
                          pressures: _strokePressures,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (!_modelReady)
            Positioned.fill(
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _modelDownloading ? '필기 모델을 처음 다운로드하는 중…' : '필기 인식 준비 중…',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor),
                    ),
                  ],
                ),
              ),
            ),
          if (_strokes.isEmpty && _modelReady && widget.showEmptyHint)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Text(
                    '여기에 정답을 써 주세요',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.hintColor),
                  ),
                ),
              ),
            ),
          if (_recognitionError != null)
            Positioned(
              left: 12,
              bottom: 10,
              child: Text(
                _recognitionError!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          if (widget.showControls)
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                children: [
                  if (_recognizing)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  IconButton(
                    tooltip: '한 획 지우기',
                    onPressed: _strokes.isEmpty ? null : _undo,
                    icon: const Icon(Icons.undo_rounded, size: 20),
                  ),
                  IconButton(
                    tooltip: '모두 지우기',
                    onPressed: _strokes.isEmpty ? null : _clear,
                    icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 연필 느낌의 가변 두께 획 렌더러 — 리본 필 방식.
///
/// 노트앱들이 쓰는 방식과 동일하게, 획의 중심선을 이동평균으로 매끈하게
/// 다듬고 포인트별 반지름(애플펜슬 압력 또는 획 속도 기반)으로 좌우
/// 외곽선을 만든 뒤 **하나의 닫힌 면으로 채운다**. 세그먼트를 이어 붙이는
/// 방식과 달리 두께가 변해도 마디·울퉁불퉁함이 생기지 않는다.
class _StrokePainter extends CustomPainter {
  const _StrokePainter({
    required this.strokes,
    required this.times,
    required this.pressures,
    required this.color,
  });

  final List<List<Offset>> strokes;
  final List<List<int>> times;
  final List<List<double>> pressures;
  final Color color;

  static const double _baseWidth = 3.0;
  static const double _minWidth = 2.1;
  static const double _maxWidth = 4.1;

  double _targetWidth(
    List<Offset> stroke,
    List<int> time,
    List<double> pressure,
    int index,
  ) {
    final p = index < pressure.length ? pressure[index] : -1.0;
    if (p >= 0) {
      // 실제 압력: 살짝 눌러도 최소 두께는 유지.
      return _baseWidth * (0.72 + 0.62 * p);
    }
    if (index == 0 || index >= time.length) return _baseWidth;
    // 속도 폴백 (px/ms): 빠른 획일수록 가늘게.
    final dt = (time[index] - time[index - 1]).abs().clamp(1, 1000);
    final velocity = (stroke[index] - stroke[index - 1]).distance / dt;
    final t = (velocity / 1.6).clamp(0.0, 1.0);
    return _baseWidth * (1.18 - 0.5 * t);
  }

  /// 중심선 위치를 창 크기 5의 이동평균으로 다듬는다.
  /// 시작·끝점은 그대로 두어 획 끝이 뭉개지지 않게 한다.
  List<Offset> _smoothedCenters(List<Offset> stroke) {
    final n = stroke.length;
    if (n < 5) return stroke;
    final out = List<Offset>.of(stroke, growable: false);
    for (var i = 1; i < n - 1; i++) {
      final lo = math.max(0, i - 2);
      final hi = math.min(n - 1, i + 2);
      var sum = Offset.zero;
      for (var j = lo; j <= hi; j++) {
        sum += stroke[j];
      }
      out[i] = sum / (hi - lo + 1).toDouble();
    }
    return out;
  }

  /// 포인트별 반지름 — 목표 두께를 구한 뒤 같은 이동평균으로 다듬는다.
  List<double> _smoothedRadii(
    List<Offset> stroke,
    List<int> time,
    List<double> pressure,
  ) {
    final n = stroke.length;
    final raw = List<double>.generate(
      n,
      (i) => _targetWidth(stroke, time, pressure, i)
          .clamp(_minWidth, _maxWidth)
          .toDouble(),
      growable: false,
    );
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final lo = math.max(0, i - 2);
      final hi = math.min(n - 1, i + 2);
      var sum = 0.0;
      for (var j = lo; j <= hi; j++) {
        sum += raw[j];
      }
      out[i] = sum / (hi - lo + 1) / 2; // 두께 → 반지름
    }
    return out;
  }

  /// 중심선 좌우로 반지름만큼 벌린 외곽선을 하나의 닫힌 Path로 만든다.
  /// 양 끝은 원(cap)을 같은 Path에 합쳐 이음매 없이 채운다.
  Path _ribbonPath(List<Offset> centers, List<double> radii) {
    final n = centers.length;
    final left = List<Offset>.filled(n, Offset.zero);
    final right = List<Offset>.filled(n, Offset.zero);
    var lastDir = const Offset(1, 0);
    for (var i = 0; i < n; i++) {
      final prev = centers[math.max(0, i - 1)];
      final next = centers[math.min(n - 1, i + 1)];
      var dir = next - prev;
      final len = dir.distance;
      dir = len < 1e-6 ? lastDir : dir / len;
      lastDir = dir;
      final normal = Offset(-dir.dy, dir.dx);
      left[i] = centers[i] + normal * radii[i];
      right[i] = centers[i] - normal * radii[i];
    }

    final path = Path()..moveTo(left[0].dx, left[0].dy);
    for (var i = 1; i < n - 1; i++) {
      final mid = (left[i] + left[i + 1]) / 2;
      path.quadraticBezierTo(left[i].dx, left[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(left[n - 1].dx, left[n - 1].dy);
    path.lineTo(right[n - 1].dx, right[n - 1].dy);
    for (var i = n - 2; i >= 1; i--) {
      final mid = (right[i] + right[i - 1]) / 2;
      path.quadraticBezierTo(right[i].dx, right[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(right[0].dx, right[0].dy);
    path.close();

    // 양 끝 라운드 캡 — 같은 Path 안에서는 겹쳐도 균일하게 채워진다.
    path.addOval(Rect.fromCircle(center: centers.first, radius: radii.first));
    path.addOval(Rect.fromCircle(center: centers.last, radius: radii.last));
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    for (var s = 0; s < strokes.length; s++) {
      final stroke = strokes[s];
      final time = s < times.length ? times[s] : const <int>[];
      final pressure = s < pressures.length ? pressures[s] : const <double>[];

      if (stroke.length < 2) {
        if (stroke.isNotEmpty) {
          canvas.drawCircle(stroke.first, _baseWidth * 0.62, paint);
        }
        continue;
      }

      final centers = _smoothedCenters(stroke);
      final radii = _smoothedRadii(centers, time, pressure);
      canvas.drawPath(_ribbonPath(centers, radii), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StrokePainter oldDelegate) => true;
}
