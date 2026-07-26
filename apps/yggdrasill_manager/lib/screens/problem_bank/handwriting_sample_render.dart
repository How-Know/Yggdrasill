// 학생 필기 샘플(student_handwriting_samples.payload) 파싱·렌더.
//
// 필기 획을 흰 배경/검정 폴리라인으로 그린다. 화면 표시(CustomPaint)와
// AI 판단용 PNG 생성이 같은 페인터를 공유하므로, AI가 보는 이미지와
// 매니저가 보는 렌더가 항상 일치한다.
//
// AI 판단용 PNG는 화면 캡처가 아니라 획 데이터에서 직접 오프스크린으로
// 그린다 — 창 크기·스크롤 상태와 무관하게 고정 해상도가 보장된다.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class HandwritingInkStroke {
  const HandwritingInkStroke({required this.x, required this.y});

  final List<double> x;
  final List<double> y;
}

class HandwritingInk {
  const HandwritingInk({
    required this.canvasWidth,
    required this.canvasHeight,
    required this.strokes,
  });

  final double canvasWidth;
  final double canvasHeight;
  final List<HandwritingInkStroke> strokes;

  bool get isEmpty => strokes.isEmpty;

  double get aspectRatio =>
      (canvasWidth > 0 && canvasHeight > 0) ? canvasWidth / canvasHeight : 3.0;

  static const empty = HandwritingInk(
    canvasWidth: 0,
    canvasHeight: 0,
    strokes: <HandwritingInkStroke>[],
  );

  static List<double> _numList(dynamic value) {
    if (value is! List) return const <double>[];
    return value
        .map((e) => e is num ? e.toDouble() : double.tryParse('$e') ?? 0.0)
        .toList(growable: false);
  }

  /// 학생앱이 올린 payload({canvas_width, canvas_height, strokes:[{x,y,...}]}).
  static HandwritingInk fromPayload(Map<String, dynamic> payload) {
    final strokes = <HandwritingInkStroke>[];
    final rawStrokes = payload['strokes'];
    if (rawStrokes is List) {
      for (final raw in rawStrokes) {
        if (raw is! Map) continue;
        final x = _numList(raw['x']);
        final y = _numList(raw['y']);
        if (x.isEmpty || y.isEmpty) continue;
        strokes.add(HandwritingInkStroke(x: x, y: y));
      }
    }
    return HandwritingInk(
      canvasWidth: double.tryParse('${payload['canvas_width'] ?? ''}') ?? 0.0,
      canvasHeight: double.tryParse('${payload['canvas_height'] ?? ''}') ?? 0.0,
      strokes: strokes,
    );
  }
}

class HandwritingInkPainter extends CustomPainter {
  HandwritingInkPainter({required this.ink});

  final HandwritingInk ink;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    if (ink.isEmpty || ink.canvasWidth <= 0 || ink.canvasHeight <= 0) return;

    // 원본 캔버스 비율을 유지한 채 위젯 크기에 맞춰 균등 스케일.
    final scale = math.min(
      size.width / ink.canvasWidth,
      size.height / ink.canvasHeight,
    );
    final dx = (size.width - ink.canvasWidth * scale) / 2;
    final dy = (size.height - ink.canvasHeight * scale) / 2;

    final strokePaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = (2.75 * scale).clamp(1.5, 8.0)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (final stroke in ink.strokes) {
      final count = math.min(stroke.x.length, stroke.y.length);
      if (count == 0) continue;
      if (count == 1) {
        // 점 하나짜리 획은 원으로 찍는다.
        canvas.drawCircle(
          Offset(dx + stroke.x[0] * scale, dy + stroke.y[0] * scale),
          strokePaint.strokeWidth / 2,
          Paint()..color = Colors.black,
        );
        continue;
      }
      final path = Path()
        ..moveTo(dx + stroke.x[0] * scale, dy + stroke.y[0] * scale);
      for (var i = 1; i < count; i++) {
        path.lineTo(dx + stroke.x[i] * scale, dy + stroke.y[i] * scale);
      }
      canvas.drawPath(path, strokePaint);
    }
  }

  @override
  bool shouldRepaint(covariant HandwritingInkPainter oldDelegate) {
    return oldDelegate.ink != ink;
  }
}

/// 획 데이터에서 AI 판단용 PNG를 오프스크린 렌더한다.
///
/// 긴 변이 [maxLongSide]px가 되도록 원본 비율을 유지한다.
/// 획이 없거나 캔버스 크기 정보가 없으면 null.
Future<Uint8List?> renderHandwritingInkPng(
  HandwritingInk ink, {
  int maxLongSide = 1200,
}) async {
  if (ink.isEmpty || ink.canvasWidth <= 0 || ink.canvasHeight <= 0) {
    return null;
  }
  final scale = maxLongSide / math.max(ink.canvasWidth, ink.canvasHeight);
  final width = (ink.canvasWidth * scale).round().clamp(1, maxLongSide);
  final height = (ink.canvasHeight * scale).round().clamp(1, maxLongSide);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  HandwritingInkPainter(ink: ink)
      .paint(canvas, Size(width.toDouble(), height.toDouble()));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return null;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}
