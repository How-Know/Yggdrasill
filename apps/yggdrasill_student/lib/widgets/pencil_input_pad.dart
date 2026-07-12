import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as mlkit;

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
    this.height = 220,
  });

  final ValueChanged<String> onRecognized;
  final double height;

  static bool get supported =>
      !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  @override
  State<PencilInputPad> createState() => _PencilInputPadState();
}

class _PencilInputPadState extends State<PencilInputPad> {
  final List<List<Offset>> _strokes = <List<Offset>>[];
  final List<List<int>> _strokeTimes = <List<int>>[];

  mlkit.DigitalInkRecognizer? _recognizer;
  bool _modelReady = false;
  bool _modelDownloading = false;
  String? _modelError;
  String? _recognitionError;
  bool _recognizing = false;
  Timer? _debounce;
  Size _canvasSize = Size.zero;

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

  void _startStroke(Offset position) {
    _debounce?.cancel();
    setState(() {
      _strokes.add(<Offset>[position]);
      _strokeTimes.add(<int>[DateTime.now().millisecondsSinceEpoch]);
    });
  }

  void _extendStroke(Offset position) {
    if (_strokes.isEmpty) return;
    setState(() {
      _strokes.last.add(position);
      _strokeTimes.last.add(DateTime.now().millisecondsSinceEpoch);
    });
  }

  void _endStroke() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _recognize);
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
      if (!mounted || candidates.isEmpty) return;
      widget.onRecognized(candidates.first.trim());
    } catch (e, stack) {
      debugPrint('Digital ink recognition failed: $e\n$stack');
      if (mounted) {
        setState(() => _recognitionError = '인식하지 못했어요. 다시 써 주세요.');
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
    });
  }

  void _undo() {
    if (_strokes.isEmpty) return;
    setState(() {
      _strokes.removeLast();
      _strokeTimes.removeLast();
    });
    _endStroke();
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
                style:
                    theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
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
                _canvasSize =
                    Size(constraints.maxWidth, constraints.maxHeight);
                return GestureDetector(
                  onPanStart:
                      _modelReady ? (d) => _startStroke(d.localPosition) : null,
                  onPanUpdate:
                      _modelReady ? (d) => _extendStroke(d.localPosition) : null,
                  onPanEnd: _modelReady ? (_) => _endStroke() : null,
                  child: Container(
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.04)
                          : Colors.black.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: theme.dividerColor.withValues(alpha: 0.4),
                      ),
                    ),
                    child: CustomPaint(
                      painter: _StrokePainter(
                        strokes: _strokes,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                      size: Size.infinite,
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
                      _modelDownloading
                          ? '필기 모델을 처음 다운로드하는 중…'
                          : '필기 인식 준비 중…',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor),
                    ),
                  ],
                ),
              ),
            ),
          if (_strokes.isEmpty && _modelReady)
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

class _StrokePainter extends CustomPainter {
  const _StrokePainter({required this.strokes, required this.color});

  final List<List<Offset>> strokes;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (final stroke in strokes) {
      if (stroke.length < 2) {
        if (stroke.isNotEmpty) {
          canvas.drawPoints(PointMode.points, stroke, paint..strokeWidth = 4);
          paint.strokeWidth = 3;
        }
        continue;
      }
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (var i = 1; i < stroke.length; i++) {
        path.lineTo(stroke[i].dx, stroke[i].dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StrokePainter oldDelegate) => true;
}
