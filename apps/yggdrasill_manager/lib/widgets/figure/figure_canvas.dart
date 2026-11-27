import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:ygg_figure/ygg_figure.dart';

import '../../screens/think/think_style.dart';

/// 그림판을 누른 자리와, 그 근처에 있던 것.
class FigureHit {
  const FigureHit(this.mm, {this.pointId, this.source});

  /// 누른 자리(그림판 mm, 왼쪽 위 기준).
  final P mm;

  /// 가까이 있던 점의 이름.
  final String? pointId;

  /// 가까이 있던 도형의 이름.
  final String? source;
}

/// 엔진이 계산한 그림 한 장을 화면에 그린다. 선·채움은 붓으로, 글자는 수식 위젯으로 놓는다.
///
/// 화면의 글자체는 인쇄본과 다르다(인쇄는 본문 글꼴로 조판한다).
class FigureCanvas extends StatefulWidget {
  const FigureCanvas({
    super.key,
    required this.scene,
    required this.pxPerMm,
    this.picked,
    this.onPick,
    this.onLabelDragStart,
    this.onLabelDrag,
    this.points = const {},
    this.movable = const {},
    this.marked = const [],
    this.pickedSource,
    this.onPointDragStart,
    this.onPointDrag,
    this.onDragEnd,
    this.onTap,
  });

  final Scene scene;
  final double pxPerMm;

  /// 고른 글자의 열쇠.
  final String? picked;
  final ValueChanged<String>? onPick;
  final ValueChanged<String>? onLabelDragStart;

  /// 글자를 끈 만큼(mm, 화면 방향).
  final void Function(String key, Offset mm)? onLabelDrag;

  /// 손잡이를 보일 점들(이름 → 그림판 mm). 비어 있으면 손잡이를 그리지 않는다.
  final Map<String, P> points;

  /// 끌 수 있는 점.
  final Set<String> movable;

  /// 지금 도형을 그리느라 찍어 둔 점.
  final List<String> marked;

  /// 고른 도형·점의 이름.
  final String? pickedSource;
  final ValueChanged<String>? onPointDragStart;
  final void Function(String id, P mm)? onPointDrag;
  final VoidCallback? onDragEnd;
  final ValueChanged<FigureHit>? onTap;

  @override
  State<FigureCanvas> createState() => _FigureCanvasState();
}

class _FigureCanvasState extends State<FigureCanvas> {
  String? _dragging;

  double get _k => widget.pxPerMm;
  P _mm(Offset local) => P(local.dx / _k, local.dy / _k);

  String? _pointNear(Offset local, double px) {
    String? best;
    var bestD = px / _k;
    final at = _mm(local);
    widget.points.forEach((id, p) {
      final d = p.distanceTo(at);
      if (d < bestD) {
        bestD = d;
        best = id;
      }
    });
    return best;
  }

  String? _sourceNear(Offset local, double px) {
    final at = _mm(local);
    String? best;
    var bestD = px / _k;
    for (final item in widget.scene.items.whereType<PathItem>()) {
      if (item.source == null || item.stroke == null) continue;
      for (final run in item.path.flatten(0.4)) {
        for (final q in run) {
          final d = q.distanceTo(at);
          if (d < bestD) {
            bestD = d;
            best = item.source;
          }
        }
      }
    }
    if (best != null) return best;
    // 선이 없으면 색칠한 면 안쪽인지 본다(위에 그려진 것부터).
    for (final item in widget.scene.items.whereType<PathItem>().toList().reversed) {
      if (item.source == null || item.fill == null || item.stroke != null) continue;
      for (final run in item.path.flatten(0.4)) {
        var inside = false;
        for (var i = 0, j = run.length - 1; i < run.length; j = i++) {
          final a = run[i], b = run[j];
          if ((a.y > at.y) != (b.y > at.y) && at.x < (b.x - a.x) * (at.y - a.y) / (b.y - a.y) + a.x) inside = !inside;
        }
        if (inside) return item.source;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scene = widget.scene;
    final interactive = widget.onTap != null || widget.onPointDrag != null;
    return SizedBox(
      width: scene.width * _k,
      height: scene.height * _k,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: CustomPaint(painter: _ScenePainter(scene, _k))),
          if (interactive)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // 끌기 시작 자리는 처음 누른 자리로 받는다(움직인 뒤의 자리면 점을 놓친다).
                dragStartBehavior: DragStartBehavior.down,
                onTapUp: (d) => widget.onTap?.call(FigureHit(
                  _mm(d.localPosition),
                  pointId: _pointNear(d.localPosition, 10),
                  source: _sourceNear(d.localPosition, 6),
                )),
                onPanStart: (d) {
                  _dragging = _pointNear(d.localPosition, 12);
                  if (_dragging != null) widget.onPointDragStart?.call(_dragging!);
                },
                onPanUpdate: (d) {
                  if (_dragging != null) widget.onPointDrag?.call(_dragging!, _mm(d.localPosition));
                },
                onPanEnd: (_) {
                  if (_dragging != null) widget.onDragEnd?.call();
                  _dragging = null;
                },
              ),
            ),
          for (final t in scene.items.whereType<TextItem>())
            Positioned.fill(
              child: CustomSingleChildLayout(
                delegate: _LabelPlace(Offset(t.pos.x * _k, t.pos.y * _k), t.anchorDeg),
                child: _label(t),
              ),
            ),
          if (widget.points.isNotEmpty || widget.pickedSource != null)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _HandlePainter(scene, _k, widget.points, widget.movable, widget.marked, widget.pickedSource),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _label(TextItem t) {
    final style = TextStyle(color: Colors.black, fontSize: t.sizePt * mmPerPt * _k, height: 1);
    final plain = Text(t.tex, style: style);
    Widget child = t.raw ? plain : Math.tex(t.tex, textStyle: style, onErrorFallback: (_) => plain);
    if (t.background) child = Container(color: Colors.white, padding: EdgeInsets.all(0.5 * _k), child: child);
    final drag = widget.onLabelDrag;
    if (drag == null || t.key.isEmpty) return IgnorePointer(child: child);
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onPick?.call(t.key),
        onPanStart: (_) {
          widget.onPick?.call(t.key);
          widget.onLabelDragStart?.call(t.key);
        },
        onPanUpdate: (d) => drag(t.key, d.delta / _k),
        onPanEnd: (_) => widget.onDragEnd?.call(),
        child: Container(
          foregroundDecoration: widget.picked == t.key ? BoxDecoration(border: Border.all(color: kThinkBlue)) : null,
          child: child,
        ),
      ),
    );
  }
}

/// 글 상자의 테두리에서 [anchorDeg] 방향의 점을 [pos] 에 맞춘다(인쇄 조판과 같은 규칙).
class _LabelPlace extends SingleChildLayoutDelegate {
  _LabelPlace(this.pos, this.anchorDeg);

  final Offset pos;
  final double? anchorDeg;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => const BoxConstraints();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    var ax = childSize.width / 2, ay = childSize.height / 2;
    final deg = anchorDeg;
    if (deg != null) {
      final c = math.cos(deg * math.pi / 180), s = math.sin(deg * math.pi / 180);
      final t = math.min(
        c.abs() < 1e-9 ? double.infinity : childSize.width / 2 / c.abs(),
        s.abs() < 1e-9 ? double.infinity : childSize.height / 2 / s.abs(),
      );
      ax += c * t;
      ay -= s * t;
    }
    return Offset(pos.dx - ax, pos.dy - ay);
  }

  @override
  bool shouldRelayout(_LabelPlace old) => old.pos != pos || old.anchorDeg != anchorDeg;
}

ui.Path _toPath(Path2 from, double k) {
  final path = ui.Path();
  var i = 0;
  for (final c in from.cmds) {
    switch (c) {
      case Cmd.move:
        path.moveTo(from.pts[i].x * k, from.pts[i].y * k);
        i += 1;
      case Cmd.line:
        path.lineTo(from.pts[i].x * k, from.pts[i].y * k);
        i += 1;
      case Cmd.cubic:
        final a = from.pts[i], b = from.pts[i + 1], p = from.pts[i + 2];
        path.cubicTo(a.x * k, a.y * k, b.x * k, b.y * k, p.x * k, p.y * k);
        i += 3;
      case Cmd.close:
        path.close();
    }
  }
  return path;
}

class _ScenePainter extends CustomPainter {
  _ScenePainter(this.scene, this.k);

  final Scene scene;
  final double k;

  @override
  void paint(Canvas canvas, Size size) {
    for (final item in scene.items.whereType<PathItem>()) {
      final path = _toPath(item.path, k);
      final fill = item.fill;
      if (fill != null) {
        final v = (fill.clamp(0.0, 1.0) * 255).round();
        canvas.drawPath(path, Paint()..color = Color.fromARGB(255, v, v, v));
      }
      final stroke = item.stroke;
      if (stroke != null) {
        final dash = stroke.dash;
        canvas.drawPath(
          dash == null ? path : _dashed(path, dash[0] * k, dash[1] * k),
          Paint()
            ..style = PaintingStyle.stroke
            ..color = Colors.black
            ..strokeWidth = stroke.width * k
            ..strokeCap = stroke.roundCap ? StrokeCap.round : StrokeCap.butt
            ..strokeJoin = StrokeJoin.round,
        );
      }
    }
  }

  ui.Path _dashed(ui.Path path, double on, double off) {
    final out = ui.Path();
    if (!(on > 0) || !(off > 0)) return path;
    for (final metric in path.computeMetrics()) {
      for (var at = 0.0; at < metric.length; at += on + off) {
        out.addPath(metric.extractPath(at, math.min(at + on, metric.length)), Offset.zero);
      }
    }
    return out;
  }

  @override
  bool shouldRepaint(_ScenePainter old) => old.scene != scene || old.k != k;
}

/// 편집할 때만 보이는 것: 고른 도형의 강조와 점 손잡이. 인쇄에는 나오지 않는다.
class _HandlePainter extends CustomPainter {
  _HandlePainter(this.scene, this.k, this.points, this.movable, this.marked, this.picked);

  final Scene scene;
  final double k;
  final Map<String, P> points;
  final Set<String> movable;
  final List<String> marked;
  final String? picked;

  @override
  void paint(Canvas canvas, Size size) {
    if (picked != null) {
      final glow = Paint()
        ..style = PaintingStyle.stroke
        ..color = kThinkBlue.withValues(alpha: 0.35)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      for (final item in scene.items.whereType<PathItem>()) {
        if (item.source != picked) continue;
        canvas.drawPath(_toPath(item.path, k), glow..strokeWidth = (item.stroke?.width ?? 0) * k + 6);
      }
    }
    points.forEach((id, p) {
      final c = Offset(p.x * k, p.y * k);
      final on = marked.contains(id) || picked == id;
      final color = movable.contains(id) ? kThinkBlue : kThinkHint;
      canvas.drawCircle(c, 4, Paint()..color = on ? color : Colors.white);
      canvas.drawCircle(
        c,
        4,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color,
      );
    });
  }

  @override
  bool shouldRepaint(_HandlePainter old) => true;
}
