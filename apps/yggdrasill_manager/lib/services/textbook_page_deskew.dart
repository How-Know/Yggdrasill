import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Result of a deskew pass.
class DeskewResult {
  const DeskewResult({
    required this.pngBytes,
    required this.angleDeg,
    required this.searchLongEdgePx,
    required this.scored,
  });

  /// PNG bytes of the rotated image. Same orientation as the input, with the
  /// skew removed (bounds may grow slightly to keep content uncropped).
  final Uint8List pngBytes;

  /// Angle (in degrees) we rotated the **source** by to produce [pngBytes].
  /// Sign follows `package:image`'s `copyRotate`: positive = clockwise in
  /// screen coordinates (y-down).
  final double angleDeg;

  /// Long edge (px) of the image we analysed. Useful to log.
  final int searchLongEdgePx;

  /// Number of candidate angles we evaluated in the search pass.
  final int scored;
}

/// Estimates the small rotation needed to make dominant horizontal text
/// lines parallel to the x-axis and returns a deskewed PNG.
///
/// ### Algorithm
/// Radon-like horizontal projection *without* rotating the raster pixels.
/// For each candidate angle θ we:
///   1. Grab every dark (ink) pixel once — only coordinates, no rotation.
///   2. Rotate the *coordinates* by θ around the image centre.
///   3. Histogram the rotated `y'` values — if θ matches the skew, every
///      glyph on the same text line collapses into the same row bucket,
///      so the histogram becomes spiky → variance is maximised.
/// The best θ wins. We then apply a *single* real rotation to the full-res
/// source with cubic resampling.
///
/// Why not rotate the raster? Rotating the binary image per-candidate also
/// introduces empty "corners" that skew the variance and flip the sign of
/// the optimum in borderline cases. Coordinate-only Radon avoids that
/// entirely and is much faster.
///
/// Runs on a background isolate via `compute` so the UI thread stays free.
Future<DeskewResult> deskewPng(
  Uint8List srcPng, {
  double maxAngleDeg = 4.0,
  double stepDeg = 0.25,
  int searchLongEdgePx = 600,
}) {
  return compute<_DeskewArgs, DeskewResult>(
    _deskewIsolate,
    _DeskewArgs(
      srcPng: srcPng,
      maxAngleDeg: maxAngleDeg,
      stepDeg: stepDeg,
      searchLongEdgePx: searchLongEdgePx,
    ),
  );
}

/// Rotates a PNG by a pre-computed angle (in `package:image` convention —
/// positive = clockwise in screen coords). Use this when you already know
/// the best skew angle (e.g. from a previous [deskewPng] pass on a lower
/// resolution render) and want to apply it to a higher-resolution render
/// without paying for the Radon search twice.
///
/// Returns the original bytes unchanged for an (effectively) zero angle.
Future<Uint8List> rotatePng(
  Uint8List srcPng,
  double angleDeg, {
  bool useCubic = true,
}) {
  if (angleDeg.abs() < 1e-6) return Future.value(srcPng);
  return compute<_RotateArgs, Uint8List>(
    _rotateIsolate,
    _RotateArgs(
      srcPng: srcPng,
      angleDeg: angleDeg,
      useCubic: useCubic,
    ),
  );
}

class _RotateArgs {
  const _RotateArgs({
    required this.srcPng,
    required this.angleDeg,
    required this.useCubic,
  });
  final Uint8List srcPng;
  final double angleDeg;
  final bool useCubic;
}

Uint8List _rotateIsolate(_RotateArgs args) {
  final decoded = img.decodePng(args.srcPng);
  if (decoded == null) return args.srcPng;
  final rotated = img.copyRotate(
    decoded,
    angle: args.angleDeg,
    interpolation: args.useCubic
        ? img.Interpolation.cubic
        : img.Interpolation.linear,
  );
  return Uint8List.fromList(img.encodePng(rotated));
}

class _DeskewArgs {
  const _DeskewArgs({
    required this.srcPng,
    required this.maxAngleDeg,
    required this.stepDeg,
    required this.searchLongEdgePx,
  });
  final Uint8List srcPng;
  final double maxAngleDeg;
  final double stepDeg;
  final int searchLongEdgePx;
}

DeskewResult _deskewIsolate(_DeskewArgs args) {
  final decoded = img.decodePng(args.srcPng);
  if (decoded == null) {
    return DeskewResult(
      pngBytes: args.srcPng,
      angleDeg: 0.0,
      searchLongEdgePx: 0,
      scored: 0,
    );
  }

  final w = decoded.width;
  final h = decoded.height;
  final longEdge = w > h ? w : h;
  final scale = longEdge > args.searchLongEdgePx
      ? args.searchLongEdgePx / longEdge
      : 1.0;
  final searchImg = scale < 1.0
      ? img.copyResize(
          decoded,
          width: (w * scale).round(),
          height: (h * scale).round(),
          interpolation: img.Interpolation.linear,
        )
      : decoded;

  final gray = img.grayscale(searchImg);
  final sw = gray.width;
  final sh = gray.height;
  final cx = sw / 2.0;
  final cy = sh / 2.0;

  // Collect ink pixel coordinates (centered at image centre).
  final xs = <double>[];
  final ys = <double>[];
  for (var y = 0; y < sh; y += 1) {
    for (var x = 0; x < sw; x += 1) {
      final lum = gray.getPixel(x, y).luminance;
      if (lum < 170) {
        xs.add(x - cx);
        ys.add(y - cy);
      }
    }
  }
  if (xs.isEmpty) {
    return DeskewResult(
      pngBytes: args.srcPng,
      angleDeg: 0.0,
      searchLongEdgePx: longEdge,
      scored: 0,
    );
  }

  // Candidate angles: include 0° first so a non-skewed page cleanly wins.
  final candidates = <double>[0.0];
  for (var a = args.stepDeg; a <= args.maxAngleDeg + 1e-9; a += args.stepDeg) {
    candidates
      ..add(a)
      ..add(-a);
  }

  // Bin domain has to cover rotated y' across the image diagonal.
  final binCount = sw + sh;
  final halfBin = binCount / 2.0;

  double bestAngleMath = 0.0;
  double bestScore = double.negativeInfinity;
  for (final angleDeg in candidates) {
    final theta = angleDeg * math.pi / 180.0;
    final s = math.sin(theta);
    final c = math.cos(theta);
    final bins = List<int>.filled(binCount, 0);
    for (var i = 0; i < xs.length; i += 1) {
      // Rotate (x, y) by +theta in this 2D frame. We only need y'.
      // y' = sin(theta)*x + cos(theta)*y
      final yRot = s * xs[i] + c * ys[i];
      final idx = (yRot + halfBin).round();
      if (idx >= 0 && idx < binCount) bins[idx] += 1;
    }
    var sum = 0.0;
    for (final b in bins) {
      sum += b;
    }
    final mean = sum / binCount;
    var vsum = 0.0;
    for (final b in bins) {
      final d = b - mean;
      vsum += d * d;
    }
    if (vsum > bestScore) {
      bestScore = vsum;
      bestAngleMath = angleDeg;
    }
  }

  if (bestAngleMath.abs() < 1e-6) {
    return DeskewResult(
      pngBytes: args.srcPng,
      angleDeg: 0.0,
      searchLongEdgePx: longEdge,
      scored: candidates.length,
    );
  }

  // Map from our math-frame search angle to `package:image`'s rotation.
  //
  // Our Radon search used `y' = sin(θ)x + cos(θ)y` on y-down pixel coords.
  // That's equivalent to rotating the image itself by **-θ** in screen
  // space (y-down → flip the sign). `img.copyRotate(angle: +x)` rotates
  // clockwise (same convention as Cairo / HTML Canvas / Flutter).
  //
  // So: to visually deskew, we apply `-bestAngleMath`.
  final applyAngle = -bestAngleMath;
  final rotatedFull = img.copyRotate(
    decoded,
    angle: applyAngle,
    interpolation: img.Interpolation.cubic,
  );
  return DeskewResult(
    pngBytes: Uint8List.fromList(img.encodePng(rotatedFull)),
    angleDeg: applyAngle,
    searchLongEdgePx: longEdge,
    scored: candidates.length,
  );
}
