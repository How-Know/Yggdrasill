import 'figure.dart';
import 'scene.dart';

/// 화면에서 바로 보여 줄 때 쓰는, 정한 크기에 맞춘 그림(어림).
///
/// 도형만 커지거나 작아지고 글자·선 굵기는 그대로다. 글자가 도형 밖으로 나온 만큼은 그림 파일의
/// 그림판 여백으로 어림한다. 조판하지 않으므로 빠르지만 조금 어긋날 수 있다. 인쇄용 그림은
/// 명령줄 도구(`export --sizes`)가 실제로 조판해 잰 크기로 낸다.
({Scene scene, double scale, double widthMm, double heightMm}) sizedSceneEstimate(
  Map<String, dynamic> doc, {
  required double widthMm,
  double? maxHeightMm,
}) {
  final natural = buildFigure(doc);
  final g1 = natural.geometryBounds();
  if (g1 == null) return (scene: natural, scale: 1, widthMm: natural.width, heightMm: natural.height);
  // 그림판에서 도형이 차지하지 않는 만큼(글자와 여백). 배율과 상관없이 그대로라고 본다.
  final overW = natural.width - (g1.right - g1.left);
  final overH = natural.height - (g1.bottom - g1.top);

  double solve(double from, double target, bool byWidth) {
    if (!(target > 1)) return from;
    var s = from;
    for (var i = 0; i < 12; i++) {
      final g = buildFigure(doc, scale: s).geometryBounds()!;
      final now = byWidth ? g.right - g.left : g.bottom - g.top;
      if ((now - target).abs() < 0.01) break;
      s = (s * target / now).clamp(0.05, 20.0);
    }
    return s;
  }

  var s = solve(1, widthMm - overW, true);
  var scene = buildFigure(doc, scale: s);
  var g = scene.geometryBounds()!;
  if (maxHeightMm != null && (g.bottom - g.top) + overH > maxHeightMm) {
    s = solve(s, maxHeightMm - overH, false);
    scene = buildFigure(doc, scale: s);
    g = scene.geometryBounds()!;
  }
  final w = (g.right - g.left) + overW, h = (g.bottom - g.top) + overH;
  return (
    scene: scene.window(g.left - g1.left, g.top - g1.top, w, h),
    scale: s,
    widthMm: w,
    heightMm: h,
  );
}
