import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

/// 펜을 떼어 획을 마감했을 때의 결과.
enum PencilCommitOutcome {
  /// 마감할 열린 획이 없었다.
  none,

  /// 일반 필기 획 하나로 확정됐다.
  added,

  /// 좌우 문지르기 지우개로 판정되어 문지른 획과 대상 글자 묶음을 지웠다.
  erased,
}

/// 문지르기 지우개가 한 번에 지운 획 하나와 원래 위치.
class RemovedInkStroke {
  RemovedInkStroke({
    required this.index,
    required this.points,
    required this.times,
    required this.pressures,
  });

  final int index;
  final List<Offset> points;
  final List<int> times;
  final List<double> pressures;
}

class _InkHistoryStep {
  _InkHistoryStep.added({
    this.points,
    this.times,
    this.pressures,
  }) : erasedStrokes = null;

  _InkHistoryStep.erased(List<RemovedInkStroke> strokes)
      : erasedStrokes = List<RemovedInkStroke>.unmodifiable(strokes),
        points = null,
        times = null,
        pressures = null;

  final List<Offset>? points;
  final List<int>? times;
  final List<double>? pressures;
  final List<RemovedInkStroke>? erasedStrokes;

  bool get isErase => erasedStrokes != null;
}

/// 필기 패드가 들고 있는 획과, 되돌리기로 빼 둔 기록.
///
/// 진행 중인 획은 목록의 마지막에 있다. 그 획은 아직 펜을 떼기 전이라
/// 실행 취소 대상이 아니고, 되돌리기는 그 앞의 끝난 단계를 되돌린다.
/// 좌우로 문질러 지운 글자 묶음도 한 단계로 기록되어 한 번에 복구된다.
class PencilInkHistory {
  final List<List<Offset>> strokes = <List<Offset>>[];
  final List<List<int>> times = <List<int>>[];
  final List<List<double>> pressures = <List<double>>[];

  final List<List<Offset>> redoStrokes = <List<Offset>>[];
  final List<List<int>> redoTimes = <List<int>>[];
  final List<List<double>> redoPressures = <List<double>>[];

  final List<_InkHistoryStep> _undoStack = <_InkHistoryStep>[];
  final List<_InkHistoryStep> _redoStack = <_InkHistoryStep>[];
  bool _hasUncommittedStroke = false;

  void beginStroke(Offset position, int timestamp, double pressure) {
    if (_hasUncommittedStroke && strokes.isNotEmpty) {
      _undoStack.add(_InkHistoryStep.added());
    }
    strokes.add(<Offset>[position]);
    times.add(<int>[timestamp]);
    pressures.add(<double>[pressure]);
    _hasUncommittedStroke = true;
  }

  bool extendStroke(Offset position, int timestamp, double pressure) {
    if (strokes.isEmpty) return false;
    final previous = strokes.last.last;
    final previousTime = times.last.last;
    final previousPressure = pressures.last.last;
    final distance = (position - previous).distance;
    if (distance < 0.6) return false;
    final steps = (distance / 1.8).ceil().clamp(1, 64);
    for (var step = 1; step <= steps; step++) {
      final t = step / steps;
      strokes.last.add(Offset.lerp(previous, position, t)!);
      times.last.add(previousTime + ((timestamp - previousTime) * t).round());
      pressures.addIfEmpty(pressure);
      pressures.last.add(
        (previousPressure < 0 || pressure < 0)
            ? pressure
            : previousPressure + (pressure - previousPressure) * t,
      );
    }
    return true;
  }

  /// 두 손가락 제스처 등으로 방금 시작한 획을 버린다. 실행 취소 기록에는 넣지 않는다.
  void cancelOpenStroke() {
    if (strokes.isEmpty) return;
    strokes.removeLast();
    times.removeLast();
    pressures.removeLast();
    _hasUncommittedStroke = false;
  }

  /// 펜을 떼어 열린 획을 확정한다.
  ///
  /// 이미 써 둔 글씨 위를 좌우로 문지른 획이면 문지른 획 자신과 겹친 글자 묶음을
  /// 함께 지우고, 되돌리기 한 번에 묶음 전체가 돌아오도록 기록한다.
  PencilCommitOutcome commitOpenStroke({bool allowScribbleErase = true}) {
    if (strokes.isEmpty) return PencilCommitOutcome.none;
    _hasUncommittedStroke = false;
    discardRedo();

    if (allowScribbleErase && strokes.length >= 2) {
      final scribble = strokes.last;
      final committed = strokes.sublist(0, strokes.length - 1);
      final targetIndices = scribbleEraseIndices(committed, scribble);
      if (targetIndices.isNotEmpty) {
        strokes.removeLast();
        times.removeLast();
        pressures.removeLast();

        final removed = <RemovedInkStroke>[
          for (final index in targetIndices)
            RemovedInkStroke(
              index: index,
              points: strokes[index],
              times: times[index],
              pressures: pressures[index],
            ),
        ];
        for (var i = targetIndices.length - 1; i >= 0; i--) {
          final target = targetIndices[i];
          strokes.removeAt(target);
          times.removeAt(target);
          pressures.removeAt(target);
        }
        _undoStack.add(_InkHistoryStep.erased(removed));
        return PencilCommitOutcome.erased;
      }
    }

    _undoStack.add(_InkHistoryStep.added());
    return PencilCommitOutcome.added;
  }

  /// 펜을 떼어 획이 확정되면, 그 전에 되돌렸던 기록은 다시 살리지 않는다.
  void discardRedo() {
    _redoStack.clear();
    redoStrokes.clear();
    redoTimes.clear();
    redoPressures.clear();
  }

  bool canUndo({required bool strokeOpen}) {
    if (!strokeOpen && _hasUncommittedStroke && strokes.isNotEmpty) {
      return true;
    }
    return _undoStack.isNotEmpty;
  }

  bool undo({required bool strokeOpen}) {
    if (!strokeOpen && _hasUncommittedStroke && strokes.isNotEmpty) {
      _hasUncommittedStroke = false;
      _undoStack.add(_InkHistoryStep.added());
    }
    if (_undoStack.isEmpty) {
      final fallbackIndex = committedUndoIndex(
        strokeCount: strokes.length,
        strokeOpen: strokeOpen,
      );
      if (fallbackIndex == null) return false;
      final removedStroke = strokes.removeAt(fallbackIndex);
      final removedTime = times.removeAt(fallbackIndex);
      final removedPressure = pressures.removeAt(fallbackIndex);
      redoStrokes.add(removedStroke);
      redoTimes.add(removedTime);
      redoPressures.add(removedPressure);
      _redoStack.add(
        _InkHistoryStep.added(
          points: removedStroke,
          times: removedTime,
          pressures: removedPressure,
        ),
      );
      return true;
    }

    final step = _undoStack.removeLast();
    if (step.isErase) {
      final limit = strokeOpen && strokes.isNotEmpty
          ? strokes.length - 1
          : strokes.length;
      for (final item in step.erasedStrokes!) {
        final insertAt = item.index.clamp(0, limit + strokes.length);
        final clamped = strokeOpen && strokes.isNotEmpty
            ? insertAt.clamp(0, strokes.length - 1)
            : insertAt.clamp(0, strokes.length);
        strokes.insert(clamped, item.points);
        times.insert(clamped, item.times);
        pressures.insert(clamped, item.pressures);
      }
      _redoStack.add(step);
      return true;
    }

    final index = committedUndoIndex(
      strokeCount: strokes.length,
      strokeOpen: strokeOpen,
    );
    if (index == null) return false;
    final removedStroke = strokes.removeAt(index);
    final removedTime = times.removeAt(index);
    final removedPressure = pressures.removeAt(index);
    redoStrokes.add(removedStroke);
    redoTimes.add(removedTime);
    redoPressures.add(removedPressure);
    _redoStack.add(
      _InkHistoryStep.added(
        points: removedStroke,
        times: removedTime,
        pressures: removedPressure,
      ),
    );
    return true;
  }

  bool redo({required bool strokeOpen}) {
    if (_redoStack.isEmpty) return false;
    final step = _redoStack.removeLast();
    if (step.isErase) {
      final erased = step.erasedStrokes!;
      final maxIndex = strokeOpen && strokes.isNotEmpty
          ? strokes.length - 2
          : strokes.length - 1;
      for (var i = erased.length - 1; i >= 0; i--) {
        final target = erased[i].index;
        if (target < 0 || target > maxIndex) continue;
        strokes.removeAt(target);
        times.removeAt(target);
        pressures.removeAt(target);
      }
      _undoStack.add(step);
      return true;
    }

    final insertAt = strokeOpen && strokes.isNotEmpty
        ? strokes.length - 1
        : strokes.length;
    final stroke = step.points ??
        (redoStrokes.isNotEmpty ? redoStrokes.removeLast() : null);
    final time =
        step.times ?? (redoTimes.isNotEmpty ? redoTimes.removeLast() : null);
    final pressure = step.pressures ??
        (redoPressures.isNotEmpty ? redoPressures.removeLast() : null);
    if (stroke == null || time == null || pressure == null) return false;
    if (step.points != null && redoStrokes.isNotEmpty) {
      redoStrokes.removeLast();
      if (redoTimes.isNotEmpty) redoTimes.removeLast();
      if (redoPressures.isNotEmpty) redoPressures.removeLast();
    }
    strokes.insert(insertAt, stroke);
    times.insert(insertAt, time);
    pressures.insert(insertAt, pressure);
    _undoStack.add(_InkHistoryStep.added());
    return true;
  }

  void clear() {
    strokes.clear();
    times.clear();
    pressures.clear();
    _undoStack.clear();
    _hasUncommittedStroke = false;
    discardRedo();
  }
}

extension on List<List<double>> {
  void addIfEmpty(double fallback) {
    if (isEmpty) add(<double>[fallback]);
  }
}

/// 이미 확정된 획 목록 [committedStrokes] 위에 방금 그은 [scribble]이
/// 좌우 문지르기 지우개이면, 함께 지울 획들의 오름차순 인덱스를 돌려준다.
/// 지우개 동작이 아니거나 겹치는 기존 획이 없으면 빈 목록을 돌려준다.
List<int> scribbleEraseIndices(
  List<List<Offset>> committedStrokes,
  List<Offset> scribble,
) {
  if (committedStrokes.isEmpty || scribble.length < 4) {
    return const <int>[];
  }

  final scribbleBox = _strokeBounds(scribble);
  final width = scribbleBox.width;
  final height = scribbleBox.height;
  if (width < 10.0 || height > width * 1.65) {
    return const <int>[];
  }

  var totalAbsDx = 0.0;
  var totalAbsDy = 0.0;
  for (var i = 1; i < scribble.length; i++) {
    totalAbsDx += (scribble[i].dx - scribble[i - 1].dx).abs();
    totalAbsDy += (scribble[i].dy - scribble[i - 1].dy).abs();
  }
  if (totalAbsDx < totalAbsDy * 0.95 || totalAbsDx < width * 1.75) {
    return const <int>[];
  }

  final legs = _extractHorizontalLegs(
    scribble,
    minLegDx: math.max(7.0, width * 0.18),
  );
  if (legs.length < 3) {
    return const <int>[];
  }

  final horizontalLegs =
      legs.where((leg) => leg.absDx >= leg.absDy * 0.85).length;
  if (horizontalLegs < 3) {
    return const <int>[];
  }

  var overlappingPairs = 0;
  for (var i = 0; i < legs.length - 1; i++) {
    final a = legs[i].bounds;
    final b = legs[i + 1].bounds;
    final minLegW = math.min(a.width, b.width);
    if (minLegW > 0 && _horizontalOverlap(a, b) >= minLegW * 0.35) {
      overlappingPairs++;
    }
  }
  if (overlappingPairs < 2) {
    return const <int>[];
  }

  if (legs.length == 3) {
    // 3구간(좌→우→좌 등)은 z·2 와 겹칠 수 있으므로, 가운데 구간이 대각선으로
    // 꺾이며 위에서 아래로 떨어지는 형태만 제외한다.
    if (height > width * 1.35 || totalAbsDx < totalAbsDy * 1.15) {
      return const <int>[];
    }
    final middleIsDiagonal = legs[1].absDx < legs[1].absDy * 1.35;
    final progressesTopToBottom =
        (legs[2].midY - legs[0].midY).abs() > height * 0.55 && height > 16.0;
    if (middleIsDiagonal && progressesTopToBottom) {
      return const <int>[];
    }
  } else if (legs.length == 4 && height > width * 1.25) {
    final strictlyDownward = legs[0].midY < legs[1].midY &&
        legs[1].midY < legs[2].midY &&
        legs[2].midY < legs[3].midY &&
        (legs[3].midY - legs[0].midY) > height * 0.55;
    if (strictlyDownward) {
      return const <int>[];
    }
  }

  const hitRadius = 10.0;
  final inflatedScribbleBox = scribbleBox.inflate(8.0);
  final committedBounds = <Rect>[
    for (final stroke in committedStrokes) _strokeBounds(stroke),
  ];

  final directlyHit = <int>{};
  final engagedLegs = <int>{};

  for (var s = 0; s < committedStrokes.length; s++) {
    final target = committedStrokes[s];
    if (target.isEmpty) continue;
    final targetBox = committedBounds[s];
    if (!inflatedScribbleBox.inflate(hitRadius).overlaps(targetBox)) {
      continue;
    }

    final hittingLegs = <int>[];
    for (var l = 0; l < legs.length; l++) {
      final leg = legs[l];
      if (!leg.bounds.inflate(hitRadius).overlaps(targetBox)) continue;
      if (_polylineDistance(leg.points, target) <= hitRadius) {
        hittingLegs.add(l);
      }
    }
    if (hittingLegs.isEmpty) continue;

    final xOverlap = _horizontalOverlap(scribbleBox, targetBox);
    if (targetBox.width > width * 1.75) {
      if (hittingLegs.length >= 2 && xOverlap >= targetBox.width * 0.35) {
        directlyHit.add(s);
        engagedLegs.addAll(hittingLegs);
      }
      continue;
    }

    final coversHorizontally = targetBox.width < 10.0
        ? (targetBox.center.dx >= scribbleBox.left - 4.0 &&
            targetBox.center.dx <= scribbleBox.right + 4.0)
        : xOverlap >= math.min(targetBox.width * 0.30, width * 0.40);
    final insideRatio = _pointsInsideRatio(target, inflatedScribbleBox);
    if (insideRatio >= 0.45 ||
        (coversHorizontally && hittingLegs.length >= 2)) {
      directlyHit.add(s);
      engagedLegs.addAll(hittingLegs);
    }
  }

  if (directlyHit.isEmpty || engagedLegs.length < 2) {
    return const <int>[];
  }

  final erased = <int>{...directlyHit};
  var clusterBox = _unionBounds([
    for (final idx in erased) committedBounds[idx],
  ]);
  final scribbleColumn = scribbleBox.inflate(4.0);

  var changed = true;
  while (changed) {
    changed = false;
    for (var j = 0; j < committedStrokes.length; j++) {
      if (erased.contains(j)) continue;
      final candidate = committedStrokes[j];
      if (candidate.isEmpty) continue;
      final candidateBox = committedBounds[j];

      if (candidateBox.width >
          math.max(width * 1.45, clusterBox.width * 1.35)) {
        continue;
      }

      final alignedWithScribble = candidateBox.width < 10.0
          ? (candidateBox.center.dx >= scribbleColumn.left &&
              candidateBox.center.dx <= scribbleColumn.right)
          : _horizontalOverlap(candidateBox, scribbleColumn) >=
              candidateBox.width * 0.50;
      if (!alignedWithScribble) continue;

      for (final e in erased) {
        final erasedStroke = committedStrokes[e];
        final erasedBox = committedBounds[e];
        final yGap = _verticalGap(candidateBox, erasedBox);
        if (yGap > 14.0) continue;

        final dist = _polylineDistance(candidate, erasedStroke);
        final xOverlap = _horizontalOverlap(candidateBox, erasedBox);
        final narrower =
            candidateBox.width <= erasedBox.width ? candidateBox : erasedBox;
        final wider =
            candidateBox.width <= erasedBox.width ? erasedBox : candidateBox;
        final alignedWithErased = narrower.width < 8.0
            ? (narrower.center.dx >= wider.left - 4.0 &&
                narrower.center.dx <= wider.right + 4.0)
            : xOverlap >= narrower.width * 0.45;

        final touchesSameChar = dist <= 6.0 && alignedWithErased;
        final stackedSameChar =
            yGap <= 14.0 && dist <= 16.0 && alignedWithErased;

        if (touchesSameChar || stackedSameChar) {
          erased.add(j);
          clusterBox = clusterBox.expandToInclude(candidateBox);
          changed = true;
          break;
        }
      }
    }
  }

  final result = erased.toList()..sort();
  return result;
}

class _HorizontalLeg {
  const _HorizontalLeg({
    required this.points,
    required this.bounds,
    required this.absDx,
    required this.absDy,
  });

  final List<Offset> points;
  final Rect bounds;
  final double absDx;
  final double absDy;

  double get midY => bounds.center.dy;
}

List<_HorizontalLeg> _extractHorizontalLegs(
  List<Offset> stroke, {
  required double minLegDx,
}) {
  final legs = <_HorizontalLeg>[];
  var minIdx = 0;
  var maxIdx = 0;
  var minX = stroke.first.dx;
  var maxX = stroke.first.dx;
  var dir = 0;
  var anchorIndex = 0;
  var extremeIndex = 0;
  var extremeX = stroke.first.dx;

  for (var i = 1; i < stroke.length; i++) {
    final x = stroke[i].dx;
    if (dir == 0) {
      if (x < minX) {
        minX = x;
        minIdx = i;
      }
      if (x > maxX) {
        maxX = x;
        maxIdx = i;
      }
      if (maxX - minX >= minLegDx) {
        if (minIdx < maxIdx) {
          dir = 1;
          anchorIndex = minIdx;
          extremeIndex = maxIdx;
          extremeX = maxX;
        } else {
          dir = -1;
          anchorIndex = maxIdx;
          extremeIndex = minIdx;
          extremeX = minX;
        }
      }
      continue;
    }

    if (dir == 1) {
      if (x >= extremeX) {
        extremeX = x;
        extremeIndex = i;
      } else if (extremeX - x >= minLegDx) {
        legs.add(_buildLeg(stroke, anchorIndex, extremeIndex));
        anchorIndex = extremeIndex;
        dir = -1;
        extremeIndex = i;
        extremeX = x;
      }
    } else {
      if (x <= extremeX) {
        extremeX = x;
        extremeIndex = i;
      } else if (x - extremeX >= minLegDx) {
        legs.add(_buildLeg(stroke, anchorIndex, extremeIndex));
        anchorIndex = extremeIndex;
        dir = 1;
        extremeIndex = i;
        extremeX = x;
      }
    }
  }

  if (dir != 0 &&
      (stroke[extremeIndex].dx - stroke[anchorIndex].dx).abs() >= minLegDx) {
    legs.add(_buildLeg(stroke, anchorIndex, extremeIndex));
  }
  return legs;
}

_HorizontalLeg _buildLeg(List<Offset> stroke, int start, int end) {
  final lo = math.min(start, end);
  final hi = math.max(start, end);
  final slice = stroke.sublist(lo, hi + 1);
  var absDx = 0.0;
  var absDy = 0.0;
  for (var i = 1; i < slice.length; i++) {
    absDx += (slice[i].dx - slice[i - 1].dx).abs();
    absDy += (slice[i].dy - slice[i - 1].dy).abs();
  }
  return _HorizontalLeg(
    points: slice,
    bounds: _strokeBounds(slice),
    absDx: absDx,
    absDy: absDy,
  );
}

Rect _strokeBounds(List<Offset> stroke) {
  var minX = stroke.first.dx;
  var maxX = stroke.first.dx;
  var minY = stroke.first.dy;
  var maxY = stroke.first.dy;
  for (var i = 1; i < stroke.length; i++) {
    final p = stroke[i];
    if (p.dx < minX) minX = p.dx;
    if (p.dx > maxX) maxX = p.dx;
    if (p.dy < minY) minY = p.dy;
    if (p.dy > maxY) maxY = p.dy;
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

Rect _unionBounds(List<Rect> rects) {
  var out = rects.first;
  for (var i = 1; i < rects.length; i++) {
    out = out.expandToInclude(rects[i]);
  }
  return out;
}

double _horizontalOverlap(Rect a, Rect b) {
  final left = math.max(a.left, b.left);
  final right = math.min(a.right, b.right);
  return math.max(0.0, right - left);
}

double _verticalGap(Rect a, Rect b) {
  if (a.bottom < b.top) return b.top - a.bottom;
  if (b.bottom < a.top) return a.top - b.bottom;
  return 0.0;
}

double _pointsInsideRatio(List<Offset> stroke, Rect box) {
  if (stroke.isEmpty) return 0.0;
  var inside = 0;
  for (final p in stroke) {
    if (box.contains(p)) inside++;
  }
  return inside / stroke.length;
}

double _polylineDistance(List<Offset> a, List<Offset> b) {
  if (a.isEmpty || b.isEmpty) return double.infinity;
  if (a.length == 1 && b.length == 1) {
    return (a.first - b.first).distance;
  }
  if (a.length == 1) {
    return _pointToPolylineDistance(a.first, b);
  }
  if (b.length == 1) {
    return _pointToPolylineDistance(b.first, a);
  }
  var best = double.infinity;
  for (var i = 0; i < a.length - 1; i++) {
    final a0 = a[i];
    final a1 = a[i + 1];
    for (var j = 0; j < b.length - 1; j++) {
      final d = _segmentDistance(a0, a1, b[j], b[j + 1]);
      if (d <= 0.0) return 0.0;
      if (d < best) best = d;
    }
  }
  return best;
}

double _pointToPolylineDistance(Offset p, List<Offset> line) {
  var best = double.infinity;
  for (var i = 0; i < line.length - 1; i++) {
    final d = _pointToSegmentDistance(p, line[i], line[i + 1]);
    if (d < best) best = d;
  }
  return best;
}

double _segmentDistance(Offset a0, Offset a1, Offset b0, Offset b1) {
  if (_segmentsIntersect(a0, a1, b0, b1)) return 0.0;
  return math.min(
    math.min(
      _pointToSegmentDistance(a0, b0, b1),
      _pointToSegmentDistance(a1, b0, b1),
    ),
    math.min(
      _pointToSegmentDistance(b0, a0, a1),
      _pointToSegmentDistance(b1, a0, a1),
    ),
  );
}

bool _segmentsIntersect(Offset a0, Offset a1, Offset b0, Offset b1) {
  final d1 = _cross(b1 - b0, a0 - b0);
  final d2 = _cross(b1 - b0, a1 - b0);
  final d3 = _cross(a1 - a0, b0 - a0);
  final d4 = _cross(a1 - a0, b1 - a0);
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

double _cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;

double _pointToSegmentDistance(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final lenSq = ab.dx * ab.dx + ab.dy * ab.dy;
  if (lenSq <= 1e-9) return (p - a).distance;
  final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lenSq)
      .clamp(0.0, 1.0);
  final projection = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
  return (p - projection).distance;
}

/// 끝난 획 중 가장 최근 것의 인덱스. 진행 중인 획이 있으면 그 앞을 고른다.
int? committedUndoIndex({
  required int strokeCount,
  required bool strokeOpen,
}) {
  if (strokeOpen) {
    if (strokeCount < 2) return null;
    return strokeCount - 2;
  }
  if (strokeCount < 1) return null;
  return strokeCount - 1;
}

/// 네이티브 실행 취소 스택에 올린 획 수.
///
/// 펜을 떼는 즉시 등록을 요청하지만 응답은 한 박자 늦다. 그 사이에
/// 시스템 되돌리기가 먼저 오면, 늦게 도착한 등록 성공을 개수에 더하지 않는다.
class ApplePencilUndoLedger {
  int levels = 0;
  int pendingPushes = 0;
  int _epoch = 0;
  int _skipIncrements = 0;
  bool _consumeNextPush = false;

  int get epoch => _epoch;

  void reset() {
    levels = 0;
    pendingPushes = 0;
    _skipIncrements = 0;
    _consumeNextPush = false;
    _epoch++;
  }

  void beginPush() {
    pendingPushes++;
  }

  /// 등록에 성공했을 때, 방금 올린 단계를 바로 다시 내려야 하면 true.
  /// [epoch]가 [beginPush] 뒤의 [reset]보다 오래됐으면 무시한다.
  bool finishPush({required bool registered, required int epoch}) {
    if (epoch != _epoch) return false;
    if (pendingPushes > 0) pendingPushes--;
    if (!registered) {
      _consumeNextPush = false;
      return false;
    }
    if (_consumeNextPush) {
      _consumeNextPush = false;
      return true;
    }
    if (_skipIncrements > 0) {
      _skipIncrements--;
      return false;
    }
    levels++;
    return false;
  }

  /// 화면의 지우기가 획을 이미 뺐고, 네이티브 등록은 아직 응답 전일 때.
  void buttonUndoWhilePushPending() {
    if (levels == 0 && pendingPushes > 0) _consumeNextPush = true;
  }

  /// 네이티브 스택에서 우리 단계가 하나 빠졌다.
  void notePopped() {
    if (levels > 0) {
      levels--;
    } else {
      _skipIncrements++;
    }
  }

  void noteRedone() {
    levels++;
  }
}
