import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../widgets/student_status_island.dart';

/// 원형 프로필 크롭 — 이동·핀치 줌 후 정사각 JPEG로 반환.
class AvatarCircleCropScreen extends StatefulWidget {
  const AvatarCircleCropScreen({
    super.key,
    required this.imageBytes,
  });

  final Uint8List imageBytes;

  static Future<Uint8List?> open(
    BuildContext context, {
    required Uint8List imageBytes,
  }) {
    return Navigator.of(context, rootNavigator: true).push<Uint8List>(
      PageRouteBuilder<Uint8List>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, __, ___) =>
            AvatarCircleCropScreen(imageBytes: imageBytes),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curve = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(opacity: curve, child: child);
        },
      ),
    );
  }

  @override
  State<AvatarCircleCropScreen> createState() => _AvatarCircleCropScreenState();
}

class _AvatarCircleCropScreenState extends State<AvatarCircleCropScreen> {
  static const _exportSize = 720;

  ui.Image? _uiImage;
  int _imgW = 0;
  int _imgH = 0;
  bool _ready = false;
  bool _exporting = false;

  double _scale = 1.0;
  Offset _pan = Offset.zero;

  double _startScale = 1.0;
  Offset _startPan = Offset.zero;
  Offset? _focalViewport;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void dispose() {
    _uiImage?.dispose();
    super.dispose();
  }

  Future<void> _decode() async {
    final codec = await ui.instantiateImageCodec(widget.imageBytes);
    final frame = await codec.getNextFrame();
    if (!mounted) {
      frame.image.dispose();
      return;
    }
    setState(() {
      _uiImage?.dispose();
      _uiImage = frame.image;
      _imgW = frame.image.width;
      _imgH = frame.image.height;
      _ready = true;
      _scale = 1.0;
      _pan = Offset.zero;
    });
  }

  double _baseScale(double circleDiameter) {
    if (_imgW <= 0 || _imgH <= 0) return 1;
    return circleDiameter / math.min(_imgW, _imgH);
  }

  double _minScale() => 1.0;
  double _maxScale() => 4.0;

  Offset _clampPan({
    required Offset pan,
    required double scale,
    required Size viewport,
    required double circleDiameter,
  }) {
    final s = _baseScale(circleDiameter) * scale;
    final dispW = _imgW * s;
    final dispH = _imgH * s;
    final r = circleDiameter / 2;
    final cx = viewport.width / 2;
    final cy = viewport.height / 2;

    // 원이 이미지 밖으로 나가지 않도록 pan 제한.
    final minPanX = r - dispW / 2;
    final maxPanX = dispW / 2 - r;
    final minPanY = r - dispH / 2;
    final maxPanY = dispH / 2 - r;

    // viewport 중심 기준 pan.
    // image center = (cx, cy) + pan
    var x = pan.dx;
    var y = pan.dy;
    if (dispW <= circleDiameter) {
      x = 0;
    } else {
      x = x.clamp(minPanX, maxPanX);
    }
    if (dispH <= circleDiameter) {
      y = 0;
    } else {
      y = y.clamp(minPanY, maxPanY);
    }
    // unused cx/cy keep symmetry for future focal zoom
    assert(cx >= 0 && cy >= 0);
    return Offset(x, y);
  }

  Future<void> _confirm(Size viewport, double circleDiameter) async {
    if (_exporting || !_ready || _imgW <= 0) return;
    setState(() => _exporting = true);
    try {
      final pan = _clampPan(
        pan: _pan,
        scale: _scale,
        viewport: viewport,
        circleDiameter: circleDiameter,
      );
      final s = _baseScale(circleDiameter) * _scale;
      final cx = viewport.width / 2;
      final cy = viewport.height / 2;
      final r = circleDiameter / 2;
      final imageLeft = cx + pan.dx - (_imgW * s) / 2;
      final imageTop = cy + pan.dy - (_imgH * s) / 2;

      var cropX = ((cx - r) - imageLeft) / s;
      var cropY = ((cy - r) - imageTop) / s;
      var cropSize = circleDiameter / s;

      cropX = cropX.clamp(0, _imgW - 1.0);
      cropY = cropY.clamp(0, _imgH - 1.0);
      cropSize = cropSize.clamp(1.0, math.min(_imgW - cropX, _imgH - cropY));

      final decoded = img.decodeImage(widget.imageBytes);
      if (decoded == null) {
        throw StateError('decode failed');
      }
      final cropped = img.copyCrop(
        decoded,
        x: cropX.round(),
        y: cropY.round(),
        width: cropSize.round(),
        height: cropSize.round(),
      );
      final resized = img.copyResize(
        cropped,
        width: _exportSize,
        height: _exportSize,
        interpolation: img.Interpolation.cubic,
      );
      final out = Uint8List.fromList(img.encodeJpg(resized, quality: 90));
      if (!mounted) return;
      Navigator.of(context).pop(out);
    } catch (_) {
      if (!mounted) return;
      TopGlassSnackBar.show(
        context,
        message: '사진을 자르지 못했어요.',
        icon: Icons.error_outline_rounded,
      );
      setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
      return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final viewport = Size(constraints.maxWidth, constraints.maxHeight);
            final circleDiameter =
                math.min(viewport.width, viewport.height) * 0.62;
            final pan = _ready
                ? _clampPan(
                    pan: _pan,
                    scale: _scale,
                    viewport: viewport,
                    circleDiameter: circleDiameter,
                  )
                : Offset.zero;

            return Stack(
              fit: StackFit.expand,
              children: [
                if (_ready && _uiImage != null)
                  GestureDetector(
                    onScaleStart: (details) {
                      _startScale = _scale;
                      _startPan = pan;
                      _focalViewport = details.localFocalPoint;
                    },
                    onScaleUpdate: (details) {
                      final startFocal = _focalViewport ?? details.localFocalPoint;
                      final focal = details.localFocalPoint;
                      final nextScale = (_startScale * details.scale)
                          .clamp(_minScale(), _maxScale());

                      final cx = viewport.width / 2;
                      final cy = viewport.height / 2;
                      final oldS = _baseScale(circleDiameter) * _startScale;
                      final newS = _baseScale(circleDiameter) * nextScale;
                      final imgCx = cx + _startPan.dx;
                      final imgCy = cy + _startPan.dy;
                      final relX = (startFocal.dx - imgCx) / oldS;
                      final relY = (startFocal.dy - imgCy) / oldS;
                      final scaledCenter = Offset(
                        startFocal.dx - relX * newS,
                        startFocal.dy - relY * newS,
                      );
                      final nextPan = Offset(
                            scaledCenter.dx - cx,
                            scaledCenter.dy - cy,
                          ) +
                          (focal - startFocal);

                      setState(() {
                        _scale = nextScale;
                        _pan = _clampPan(
                          pan: nextPan,
                          scale: nextScale,
                          viewport: viewport,
                          circleDiameter: circleDiameter,
                        );
                      });
                    },
                    child: CustomPaint(
                      size: viewport,
                      painter: _CropImagePainter(
                        image: _uiImage!,
                        imgW: _imgW,
                        imgH: _imgH,
                        baseScale: _baseScale(circleDiameter),
                        scale: _scale,
                        pan: pan,
                      ),
                    ),
                  )
                else
                  const Center(child: YggLoadingIndicator(size: 36)),
                IgnorePointer(
                  child: CustomPaint(
                    size: viewport,
                    painter: _CircleDimPainter(diameter: circleDiameter),
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StudentStatusIslandToolbarSlot(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              SolidCapsuleActionBar(
                                padding: const EdgeInsets.all(8),
                                children: [
                                  SolidCapsuleActionButton(
                                    tooltip: '취소',
                                    icon: Icons.close_rounded,
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                  ),
                                ],
                              ),
                              const Spacer(),
                              // 상태 아일랜드 자리
                              const SizedBox(width: 128),
                              const Spacer(),
                              SolidCapsuleActionBar(
                                padding: const EdgeInsets.all(8),
                                children: [
                                  SolidCapsuleActionButton(
                                    tooltip: '완료',
                                    icon: Icons.check_rounded,
                                    onPressed: (!_ready || _exporting)
                                        ? null
                                        : () => _confirm(
                                              viewport,
                                              circleDiameter,
                                            ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(top: 4, bottom: 8),
                        child: Text(
                          '이동 및 크기 조절',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_exporting)
                  const ColoredBox(
                    color: Color(0x66000000),
                    child: Center(child: YggLoadingIndicator(size: 36)),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CropImagePainter extends CustomPainter {
  _CropImagePainter({
    required this.image,
    required this.imgW,
    required this.imgH,
    required this.baseScale,
    required this.scale,
    required this.pan,
  });

  final ui.Image image;
  final int imgW;
  final int imgH;
  final double baseScale;
  final double scale;
  final Offset pan;

  @override
  void paint(Canvas canvas, Size size) {
    final s = baseScale * scale;
    final w = imgW * s;
    final h = imgH * s;
    final cx = size.width / 2 + pan.dx;
    final cy = size.height / 2 + pan.dy;
    final dst = Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
    paintImage(
      canvas: canvas,
      rect: dst,
      image: image,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(covariant _CropImagePainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.scale != scale ||
        oldDelegate.pan != pan ||
        oldDelegate.baseScale != baseScale;
  }
}

class _CircleDimPainter extends CustomPainter {
  _CircleDimPainter({required this.diameter});

  final double diameter;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = diameter / 2;
    final overlay = Path()..addRect(Offset.zero & size);
    final hole = Path()
      ..addOval(Rect.fromCircle(center: center, radius: r));
    final dim = Path.combine(PathOperation.difference, overlay, hole);
    canvas.drawPath(dim, Paint()..color = const Color(0xB3000000));
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(covariant _CircleDimPainter oldDelegate) =>
      oldDelegate.diameter != diameter;
}
