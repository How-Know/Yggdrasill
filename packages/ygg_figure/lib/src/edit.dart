/// 편집 화면과 AI 가 그림 파일을 고칠 때 쓰는 도구. 그림 파일(JSON)만 고치고, 그리는 일은 엔진이 한다.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'figure.dart';
import 'geom.dart';

List<Map<String, dynamic>> figureObjects(Map<String, dynamic> doc) {
  final list = (doc['objects'] as List?) ?? (doc['objects'] = <dynamic>[]);
  return [for (final o in list) o as Map<String, dynamic>];
}

Map<String, dynamic>? figureObject(Map<String, dynamic> doc, String id) {
  for (final o in figureObjects(doc)) {
    if (o['id'] == id) return o;
  }
  return null;
}

Set<String> _ids(Map<String, dynamic> doc) => {
      for (final o in figureObjects(doc))
        if (o['id'] is String) o['id'] as String,
    };

/// 아직 안 쓴 점 이름(A, B, … Z, 그다음 P1, P2, …).
String nextPointName(Map<String, dynamic> doc) {
  final used = _ids(doc);
  for (var c = 65; c <= 90; c++) {
    final name = String.fromCharCode(c);
    if (!used.contains(name)) return name;
  }
  for (var i = 1;; i++) {
    if (!used.contains('P$i')) return 'P$i';
  }
}

/// 아직 안 쓴 요소 이름([prefix] + 번호).
String nextObjectId(Map<String, dynamic> doc, String prefix) {
  final used = _ids(doc);
  for (var i = 1;; i++) {
    if (!used.contains('$prefix$i')) return '$prefix$i';
  }
}

const _nameable = {
  'segment', 'ray', 'line', 'polyline', 'polygon', 'circle', 'arc', 'ellipse', 'function', 'parametric',
  'fill', 'path', 'right_angle', 'angle', 'dimension', 'label', 'axes', 'perpendicular', 'parallel', 'tangent',
};

/// 이름 없는 도형에 이름을 붙인다(화면에서 집을 수 있게). 그림의 모양은 달라지지 않는다.
///
/// 이름 없는 요소의 글자 미세 이동은 '#순번' 으로 적혀 있으므로 새 이름으로 옮겨 적는다.
/// 점은 이름이 곧 글자가 되므로 건드리지 않는다.
void ensureObjectIds(Map<String, dynamic> doc) {
  final objects = figureObjects(doc);
  final nudges = doc['label_nudge'] as Map<String, dynamic>?;
  for (var i = 0; i < objects.length; i++) {
    final o = objects[i];
    if (o['id'] != null || !_nameable.contains(o['type'])) continue;
    final id = nextObjectId(doc, 'o');
    // 이름을 맨 앞에 둔다.
    final rest = Map<String, dynamic>.of(o);
    o
      ..clear()
      ..['id'] = id
      ..addAll(rest);
    if (nudges == null) continue;
    final old = '#${i + 1}';
    for (final key in nudges.keys.toList()) {
      if (key == old || key.startsWith('$old:')) nudges['$id${key.substring(old.length)}'] = nudges.remove(key);
    }
  }
}

// 식에서 변수 이름을 찾는다. "2th" 처럼 숫자 뒤에 바로 붙은 이름도 찾고, "C.y"·"sin(" 은 뺀다.
final _name = RegExp(r'(?<![A-Za-z_.])[A-Za-z_]\w*(?![\w.(])');

class _Knob {
  _Knob(this.get, this.set);
  final double Function() get;
  final void Function(double) set;
}

double _round(double v) => (v * 10000).round() / 10000;

/// 점 하나의 자리를 정하는 값들(숫자로 적힌 좌표, 또는 좌표 식에 쓰인 변수).
List<_Knob> _knobs(Map<String, dynamic> doc, Map<String, dynamic> o) {
  final params = doc['params'] as Map?;
  final seen = <String>{};
  final out = <_Knob>[];
  void slot(dynamic holder, dynamic key) {
    final v = holder[key];
    if (v is num) {
      out.add(_Knob(() => (holder[key] as num).toDouble(), (x) => holder[key] = x));
    } else if (v is String && params != null) {
      for (final m in _name.allMatches(v)) {
        final name = m.group(0)!;
        final now = params[name];
        if (now is num && seen.add(name)) {
          out.add(_Knob(() => (params[name] as num).toDouble(), (x) => params[name] = x));
          return;
        }
        if (now is Map && now['value'] is num && seen.add(name)) {
          out.add(_Knob(() => (now['value'] as num).toDouble(), (x) => now['value'] = x));
          return;
        }
      }
    }
  }

  switch (o['type']) {
    case 'point':
      final at = o['at'];
      if (at is List && at.length == 2) {
        slot(at, 0);
        slot(at, 1);
      }
    case 'on':
      for (final k in const ['angle', 't', 'x']) {
        if (o.containsKey(k)) slot(o, k);
      }
    case 'polar':
      slot(o, 'angle');
      slot(o, 'radius');
  }
  return out;
}

/// 이 점을 끌어 옮길 수 있는가(다른 것에서 계산되는 점은 옮길 수 없다).
bool canMovePoint(Map<String, dynamic> doc, String id) {
  final o = figureObject(doc, id);
  return o != null && _knobs(doc, o).isNotEmpty;
}

/// 점 [id] 가 그림판의 [target](mm) 에 오도록 그림 파일을 고친다.
///
/// 자유로운 점은 그 자리로 가고, 원·선 위의 점은 그 위에서 가장 가까운 자리로 간다. 좌표가 변수로
/// 적혀 있으면 그 변수를 고치므로 같은 변수를 쓰는 다른 도형도 함께 움직인다. 옮길 수 없으면 false.
bool movePoint(Map<String, dynamic> doc, String id, P target, {double scale = 1}) {
  final o = figureObject(doc, id);
  if (o == null) return false;
  final knobs = _knobs(doc, o);
  if (knobs.isEmpty) return false;
  final start = [for (final k in knobs) k.get()];

  P? where() {
    try {
      return layoutFigure(doc, scale: scale).points[id];
    } on Object {
      return null;
    }
  }

  final first = where();
  if (first == null) return false;
  var p = first;
  for (var round = 0; round < 8; round++) {
    final miss = target - p;
    final far = p.distanceTo(target);
    if (far < 0.005) break;
    // 값을 조금씩 바꿔 보고 점이 어느 쪽으로 얼마나 가는지 잰다.
    final now = [for (final k in knobs) k.get()];
    final cols = <P>[];
    for (var i = 0; i < knobs.length; i++) {
      final h = math.max(1e-4, now[i].abs() * 1e-4);
      knobs[i].set(now[i] + h);
      final q = where();
      knobs[i].set(now[i]);
      cols.add(q == null ? const P(0, 0) : (q - p) * (1 / h));
    }
    double dot(P a, P b) => a.x * b.x + a.y * b.y;
    var step = List<double>.filled(knobs.length, 0);
    final det = knobs.length == 2 ? cols[0].x * cols[1].y - cols[1].x * cols[0].y : 0.0;
    if (knobs.length == 2 && det.abs() > 1e-9) {
      step = [(miss.x * cols[1].y - cols[1].x * miss.y) / det, (cols[0].x * miss.y - miss.x * cols[0].y) / det];
    } else {
      // 값 하나로만 움직일 수 있으면 가장 가까워지는 만큼만 간다.
      var best = 0;
      for (var i = 1; i < cols.length; i++) {
        if (dot(cols[i], cols[i]) > dot(cols[best], cols[best])) best = i;
      }
      final len = dot(cols[best], cols[best]);
      if (len < 1e-12) break;
      step[best] = dot(cols[best], miss) / len;
    }
    var moved = false;
    for (var f = 1.0; f > 0.05; f /= 2) {
      for (var i = 0; i < knobs.length; i++) {
        knobs[i].set(now[i] + step[i] * f);
      }
      final q = where();
      if (q != null && q.distanceTo(target) < far - 1e-6) {
        p = q;
        moved = true;
        break;
      }
    }
    if (!moved) {
      for (var i = 0; i < knobs.length; i++) {
        knobs[i].set(now[i]);
      }
      break;
    }
  }
  for (final k in knobs) {
    k.set(_round(k.get()));
  }
  if (where() == null) {
    for (var i = 0; i < knobs.length; i++) {
      knobs[i].set(start[i]);
    }
    return false;
  }
  return true;
}

String _inline(dynamic v) => switch (v) {
      Map() => '{${v.entries.map((e) => '${jsonEncode(e.key)}: ${_inline(e.value)}').join(', ')}}',
      List() => '[${v.map(_inline).join(', ')}]',
      _ => jsonEncode(v),
    };

/// 그림 파일을 저장소의 그림 파일과 같은 모양(요소 하나에 한 줄)으로 적는다.
String formatFigureJson(Map<String, dynamic> doc) {
  final b = StringBuffer('{\n');
  final keys = doc.keys.toList();
  for (var i = 0; i < keys.length; i++) {
    final value = doc[keys[i]];
    b.write('  ${jsonEncode(keys[i])}: ');
    if (keys[i] == 'objects' && value is List && value.isNotEmpty) {
      b.write('[\n${value.map((o) => '    ${_inline(o)}').join(',\n')}\n  ]');
    } else if (keys[i] == 'parts' && value is Map && value.isNotEmpty) {
      // 되풀이 조각도 도형 하나에 한 줄씩 적는다.
      b.write('{\n');
      b.write(value.entries
          .map((e) => '    ${jsonEncode(e.key)}: [\n${(e.value as List).map((o) => '      ${_inline(o)}').join(',\n')}\n    ]')
          .join(',\n'));
      b.write('\n  }');
    } else {
      b.write(_inline(value));
    }
    b.write(i == keys.length - 1 ? '\n' : ',\n');
  }
  b.write('}\n');
  return b.toString();
}
