import 'dart:math' as math;

/// 평면 위의 점(또는 벡터).
class P {
  const P(this.x, this.y);
  final double x, y;

  P operator +(P o) => P(x + o.x, y + o.y);
  P operator -(P o) => P(x - o.x, y - o.y);
  P operator *(double k) => P(x * k, y * k);
  double dot(P o) => x * o.x + y * o.y;
  double cross(P o) => x * o.y - y * o.x;
  double get length => math.sqrt(x * x + y * y);
  double get angle => math.atan2(y, x);
  P get unit {
    final l = length;
    return l == 0 ? const P(0, 0) : P(x / l, y / l);
  }

  /// 반시계 방향으로 90도 돌린 벡터.
  P get normal => P(-y, x);
  double distanceTo(P o) => (this - o).length;
  P rotate(double rad, [P center = const P(0, 0)]) {
    final c = math.cos(rad), s = math.sin(rad);
    final d = this - center;
    return P(center.x + d.x * c - d.y * s, center.y + d.x * s + d.y * c);
  }

  static P polar(double r, double rad) => P(r * math.cos(rad), r * math.sin(rad));

  @override
  String toString() => '(${x.toStringAsFixed(4)}, ${y.toStringAsFixed(4)})';
}

/// 두 직선(각각 두 점으로 정해짐)의 교점. 평행하면 null.
P? lineLine(P a, P b, P c, P d) {
  final r = b - a, s = d - c;
  final den = r.cross(s);
  if (den.abs() < 1e-12) return null;
  final t = (c - a).cross(s) / den;
  return a + r * t;
}

/// 직선 ab 와 원의 교점(0~2개). a 에서 b 방향 순서.
List<P> lineCircle(P a, P b, P center, double r) {
  final d = (b - a).unit;
  final f = a - center;
  final bq = f.dot(d);
  final cq = f.dot(f) - r * r;
  final disc = bq * bq - cq;
  if (disc < -1e-10) return const [];
  final root = math.sqrt(math.max(disc, 0));
  if (root < 1e-9) return [a + d * (-bq)];
  return [a + d * (-bq - root), a + d * (-bq + root)];
}

/// 두 원의 교점(0~2개).
List<P> circleCircle(P c1, double r1, P c2, double r2) {
  final d = c1.distanceTo(c2);
  if (d < 1e-12 || d > r1 + r2 + 1e-10 || d < (r1 - r2).abs() - 1e-10) return const [];
  final a = (r1 * r1 - r2 * r2 + d * d) / (2 * d);
  final h2 = r1 * r1 - a * a;
  final u = (c2 - c1).unit;
  final m = c1 + u * a;
  if (h2 <= 1e-12) return [m];
  final h = math.sqrt(h2);
  return [m + u.normal * h, m - u.normal * h];
}

/// 점 p 에서 직선 ab 에 내린 수선의 발.
P footOnLine(P p, P a, P b) {
  final d = b - a;
  final t = (p - a).dot(d) / d.dot(d);
  return a + d * t;
}

/// 세 점을 지나는 원의 중심. 한 직선 위에 있으면 null.
P? circumcenter(P a, P b, P c) {
  final d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y));
  if (d.abs() < 1e-12) return null;
  final a2 = a.dot(a), b2 = b.dot(b), c2 = c.dot(c);
  return P(
    (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
    (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d,
  );
}

/// 선분 ab 와 cd 가 만나는 점(선분 안에서만).
P? segmentSegment(P a, P b, P c, P d) {
  final r = b - a, s = d - c;
  final den = r.cross(s);
  if (den.abs() < 1e-14) return null;
  final t = (c - a).cross(s) / den;
  final u = (c - a).cross(r) / den;
  if (t < -1e-9 || t > 1 + 1e-9 || u < -1e-9 || u > 1 + 1e-9) return null;
  return a + r * t;
}
