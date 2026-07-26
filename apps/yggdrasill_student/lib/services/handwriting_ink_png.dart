// 필기 획 → VLM 인식용 PNG 오프스크린 렌더.
//
// 온디바이스 인식이 실패했을 때 서버(Gemini) 2차 인식에 보낼 이미지를
// 만든다. 화면 렌더(리본 필)와 달리 인식 정확도가 목적이므로
// 흰 배경/검정 균일 획으로 단순하게 그린다.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// [strokes]를 흰 배경 PNG 로 렌더한다. 긴 변이 [maxLongSide]px.
/// 획이 없거나 캔버스 크기가 유효하지 않으면 null.
Future<Uint8List?> renderHandwritingPng({
  required List<List<Offset>> strokes,
  required Size canvasSize,
  int maxLongSide = 1024,
}) async {
  if (strokes.isEmpty || canvasSize.width <= 0 || canvasSize.height <= 0) {
    return null;
  }
  final scale =
      maxLongSide / math.max(canvasSize.width, canvasSize.height);
  final width =
      (canvasSize.width * scale).round().clamp(1, maxLongSide);
  final height =
      (canvasSize.height * scale).round().clamp(1, maxLongSide);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = Colors.white,
  );

  final strokePaint = Paint()
    ..color = Colors.black
    ..style = PaintingStyle.stroke
    ..strokeWidth = (2.75 * scale).clamp(1.5, 8.0)
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  for (final stroke in strokes) {
    if (stroke.isEmpty) continue;
    if (stroke.length == 1) {
      canvas.drawCircle(
        stroke.first * scale,
        strokePaint.strokeWidth / 2,
        Paint()..color = Colors.black,
      );
      continue;
    }
    final path = Path()
      ..moveTo(stroke.first.dx * scale, stroke.first.dy * scale);
    for (var i = 1; i < stroke.length; i++) {
      path.lineTo(stroke[i].dx * scale, stroke[i].dy * scale);
    }
    canvas.drawPath(path, strokePaint);
  }

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
