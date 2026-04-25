import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Tunables for "a single problem's crop" on a rendered page image.
///
/// Defaults assume the VLM already returns `item_region` = body-only (no
/// problem number, no label) per the prompt in
/// `gateway/src/textbook/vlm_detect_prompt.js` rule [D6]. In that mode we
/// only need a very small safety padding and the number-avoidance heuristics
/// can stay off. The heuristics are kept as opt-in knobs in case the VLM
/// regresses on a specific layout.
class ProblemCropOptions {
  const ProblemCropOptions({
    this.paddingRatio = 0.008,
    this.minPaddingPx = 6,
    this.avoidNumber = true,
    this.maskRemainingNumber = false,
    this.numberMarginPx = 6,
    // Default off: the per-crop Radon pass was over-rotating crops whose
    // visible content was dominated by figures / tables rather than text
    // lines (Radon picked up the long edges of the figure as if they were
    // text baselines). The page-level deskew in textbook_page_deskew.dart
    // already removes the bulk of the tilt — we keep this flag around so
    // a future smarter implementation (text-line specific) can flip it on.
    this.perCropDeskew = false,
    this.perCropDeskewMaxAngleDeg = 2.5,
    this.perCropDeskewStepDeg = 0.25,
    this.perCropDeskewSearchLongEdgePx = 320,
  });

  /// Extra margin on each side of `item_region` before cropping, as a fraction
  /// of the image's long edge. Keeps glyphs/figures from being shaved off by
  /// a VLM box that sits flush against the content.
  final double paddingRatio;

  /// Hard lower bound for padding (pixels). Important at low resolutions
  /// where `paddingRatio * longEdge` might round to 2-3 px.
  final int minPaddingPx;

  /// Legacy safety net: if the VLM hands us an `item_region` that still
  /// overlaps the problem number, try to push the crop's top or left edge
  /// past the number. With the current prompt the VLM is supposed to exclude
  /// the number itself, so this defaults to `false`.
  final bool avoidNumber;

  /// Legacy safety net: if the number bbox still overlaps the crop after
  /// edge-avoidance, paint it over with white. Defaults to `false` to match
  /// the current prompt contract.
  final bool maskRemainingNumber;

  /// Margin (px) around the number bbox when masking so we also cover the
  /// small gap between the number glyph and its shadow / aliasing.
  final int numberMarginPx;

  /// If true, runs a second (tiny) deskew pass on the cropped image itself
  /// after the page-level deskew. Scanned textbooks often have non-uniform
  /// skew across a page (paper curl / binding bow), so a single page rotation
  /// straightens the "average" while individual problems still end up 0.3° –
  /// 1.0° tilted. This pass catches that residual tilt per problem.
  final bool perCropDeskew;

  /// Maximum angle (deg) searched by the per-crop deskew pass. Kept small
  /// because the page-level deskew already removed the bulk of the tilt;
  /// we're only cleaning up the residual here.
  final double perCropDeskewMaxAngleDeg;

  /// Angle step (deg) for the per-crop deskew search.
  final double perCropDeskewStepDeg;

  /// Long-edge (px) the crop is downsampled to for the per-crop Radon
  /// search. Crops are small already, so 300 – 400 px is usually enough
  /// signal for a reliable angle pick.
  final int perCropDeskewSearchLongEdgePx;
}

/// Result from `cropProblemRegion`.
class ProblemCrop {
  const ProblemCrop({
    required this.pngBytes,
    required this.cropRectPx,
    required this.paddingPx,
    required this.avoidedNumberEdge,
    required this.maskedNumber,
  });

  /// PNG bytes of the cropped image.
  final Uint8List pngBytes;

  /// Final crop rect in *source image* pixel coordinates:
  /// `[x, y, width, height]`. Handy if you want to reconstruct the same crop
  /// later (e.g. for a vector PDF re-assembly step).
  final List<int> cropRectPx;

  /// Actual padding used (pixels).
  final int paddingPx;

  /// 'top' | 'left' | 'none' — which edge we moved to avoid the number box.
  final String avoidedNumberEdge;

  /// True if we masked a remaining number bbox with white.
  final bool maskedNumber;
}

/// Crops a single problem out of a rendered page image, applying a safety
/// padding and — when possible — avoiding the problem-number glyph.
///
/// Coordinates for [itemRegion]/[numberBbox] are the VLM's normalised
/// `[ymin, xmin, ymax, xmax]` in 0..1000, matching
/// `TextbookVlmItem.itemRegion`/`TextbookVlmItem.bbox`.
///
/// Returns null if the region is degenerate (zero-area / outside the image).
ProblemCrop? cropProblemRegion({
  required Uint8List sourcePng,
  required List<int> itemRegion,
  List<int>? numberBbox,
  ProblemCropOptions options = const ProblemCropOptions(),
}) {
  if (itemRegion.length != 4) return null;
  final decoded = img.decodePng(sourcePng);
  if (decoded == null) return null;
  return cropProblemRegionOnImage(
    source: decoded,
    itemRegion: itemRegion,
    numberBbox: numberBbox,
    options: options,
  );
}

/// Same as [cropProblemRegion] but takes a pre-decoded image. Useful when
/// slicing many crops out of the same page to avoid re-decoding the PNG
/// for every item.
ProblemCrop? cropProblemRegionOnImage({
  required img.Image source,
  required List<int> itemRegion,
  List<int>? numberBbox,
  ProblemCropOptions options = const ProblemCropOptions(),
}) {
  if (itemRegion.length != 4) return null;
  final w = source.width;
  final h = source.height;
  if (w <= 0 || h <= 0) return null;

  final longEdge = w > h ? w : h;
  final padPx = (longEdge * options.paddingRatio)
      .round()
      .clamp(options.minPaddingPx, longEdge);

  var y0 = itemRegion[0] / 1000.0 * h - padPx;
  var x0 = itemRegion[1] / 1000.0 * w - padPx;
  var y1 = itemRegion[2] / 1000.0 * h + padPx;
  var x1 = itemRegion[3] / 1000.0 * w + padPx;

  y0 = y0.clamp(0.0, h - 1.0);
  x0 = x0.clamp(0.0, w - 1.0);
  y1 = y1.clamp(y0 + 1.0, h.toDouble());
  x1 = x1.clamp(x0 + 1.0, w.toDouble());

  String avoidedEdge = 'none';
  var numAbsY0 = 0.0;
  var numAbsX0 = 0.0;
  var numAbsY1 = 0.0;
  var numAbsX1 = 0.0;
  final hasNumber = options.avoidNumber &&
      numberBbox != null &&
      numberBbox.length == 4;

  if (hasNumber) {
    numAbsY0 = numberBbox[0] / 1000.0 * h;
    numAbsX0 = numberBbox[1] / 1000.0 * w;
    numAbsY1 = numberBbox[2] / 1000.0 * h;
    numAbsX1 = numberBbox[3] / 1000.0 * w;

    final bboxW = (numAbsX1 - numAbsX0).clamp(0.0, w.toDouble());
    final bboxH = (numAbsY1 - numAbsY0).clamp(0.0, h.toDouble());
    final regionW = x1 - x0;
    final regionH = y1 - y0;
    final gap = (padPx * 0.5).clamp(4.0, padPx.toDouble());

    // Only consider avoidance when the number box is small relative to the
    // region — otherwise we might be misreading a figure/table as a "number".
    final numberLooksSmall =
        bboxW < regionW * 0.45 && bboxH < regionH * 0.40;

    final numberInsideX =
        numAbsX0 < x1 - gap && numAbsX1 > x0 + gap;
    final numberInsideY =
        numAbsY0 < y1 - gap && numAbsY1 > y0 + gap;

    if (numberLooksSmall && numberInsideX && numberInsideY) {
      // Case A (Style-B / type_practice): number sits at the top.
      // Move the top edge below the number.
      final topBand = y0 + regionH * 0.25;
      if (numAbsY1 < topBand &&
          numAbsY1 + gap < y1 &&
          (numAbsY1 - y0) < regionH * 0.4) {
        y0 = numAbsY1 + gap;
        avoidedEdge = 'top';
      } else {
        // Case B (Style-A / basic_drill): number sits on the left of the
        // same row as the body. Move the left edge past the number.
        final leftBand = x0 + regionW * 0.25;
        if (numAbsX1 < leftBand &&
            numAbsX1 + gap < x1 &&
            (numAbsX1 - x0) < regionW * 0.35) {
          x0 = numAbsX1 + gap;
          avoidedEdge = 'left';
        }
      }
    }

    y0 = y0.clamp(0.0, h - 1.0);
    x0 = x0.clamp(0.0, w - 1.0);
    y1 = y1.clamp(y0 + 1.0, h.toDouble());
    x1 = x1.clamp(x0 + 1.0, w.toDouble());
  }

  final cx = x0.round();
  final cy = y0.round();
  final cw = (x1 - x0).round();
  final ch = (y1 - y0).round();
  if (cw < 2 || ch < 2) return null;

  var cropped = img.copyCrop(
    source,
    x: cx,
    y: cy,
    width: cw,
    height: ch,
  );

  // If we couldn't push an edge past the number, white-mask it out so the
  // printed crop doesn't carry the number glyph. Runs BEFORE the per-crop
  // deskew so the mask coordinates are in the pre-rotation frame.
  var maskedNumber = false;
  if (hasNumber && options.maskRemainingNumber && avoidedEdge == 'none') {
    final margin = options.numberMarginPx;
    final localX0 = (numAbsX0 - cx - margin).round().clamp(0, cw);
    final localY0 = (numAbsY0 - cy - margin).round().clamp(0, ch);
    final localX1 = (numAbsX1 - cx + margin).round().clamp(0, cw);
    final localY1 = (numAbsY1 - cy + margin).round().clamp(0, ch);
    if (localX1 > localX0 && localY1 > localY0) {
      img.fillRect(
        cropped,
        x1: localX0,
        y1: localY0,
        x2: localX1 - 1,
        y2: localY1 - 1,
        color: img.ColorRgb8(255, 255, 255),
      );
      maskedNumber = true;
    }
  }

  // Per-problem residual-skew cleanup. Runs AFTER masking so mask rect
  // coordinates are still valid, and AFTER the main crop so we don't pay
  // for rotating pixels we're about to throw away. Search angle stays
  // small (±~2.5°) because the page-level deskew already removed the
  // dominant tilt and we only want to clean up the residual that varies
  // from problem to problem on bowed scans.
  if (options.perCropDeskew) {
    final angle = _estimateCropSkewDeg(
      cropped,
      maxAngleDeg: options.perCropDeskewMaxAngleDeg,
      stepDeg: options.perCropDeskewStepDeg,
      searchLongEdgePx: options.perCropDeskewSearchLongEdgePx,
    );
    if (angle.abs() > 1e-3) {
      cropped = img.copyRotate(
        cropped,
        angle: angle,
        interpolation: img.Interpolation.cubic,
      );
    }
  }

  final pngBytes = Uint8List.fromList(img.encodePng(cropped));
  return ProblemCrop(
    pngBytes: pngBytes,
    cropRectPx: [cx, cy, cw, ch],
    paddingPx: padPx,
    avoidedNumberEdge: avoidedEdge,
    maskedNumber: maskedNumber,
  );
}

/// Radon-style residual-skew estimator for a single problem crop.
///
/// Mirrors `textbook_page_deskew._deskewIsolate` but works on a pre-decoded
/// `img.Image` so it can run inside the same isolate that builds the crops.
/// Returns an angle in degrees that matches `img.copyRotate(angle: …)` — i.e.
/// positive = clockwise in screen (y-down) coordinates.
double _estimateCropSkewDeg(
  img.Image src, {
  required double maxAngleDeg,
  required double stepDeg,
  required int searchLongEdgePx,
}) {
  final w = src.width;
  final h = src.height;
  if (w <= 4 || h <= 4) return 0.0;

  final longEdge = w > h ? w : h;
  final scale = longEdge > searchLongEdgePx ? searchLongEdgePx / longEdge : 1.0;
  final searchImg = scale < 1.0
      ? img.copyResize(
          src,
          width: (w * scale).round(),
          height: (h * scale).round(),
          interpolation: img.Interpolation.linear,
        )
      : src;
  final gray = img.grayscale(searchImg);
  final sw = gray.width;
  final sh = gray.height;
  final cx = sw / 2.0;
  final cy = sh / 2.0;

  // Collect ink pixel coordinates (centred at image centre).
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
  // A crop that's mostly figure / white space won't have enough ink to
  // produce a reliable variance peak — bail out with 0.
  if (xs.length < 120) return 0.0;

  final candidates = <double>[0.0];
  for (var a = stepDeg; a <= maxAngleDeg + 1e-9; a += stepDeg) {
    candidates
      ..add(a)
      ..add(-a);
  }

  final binCount = sw + sh;
  final halfBin = binCount / 2.0;

  var bestAngleMath = 0.0;
  var bestScore = double.negativeInfinity;
  for (final angleDeg in candidates) {
    final theta = angleDeg * _degToRad;
    final s = _sin(theta);
    final c = _cos(theta);
    final bins = List<int>.filled(binCount, 0);
    for (var i = 0; i < xs.length; i += 1) {
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

  // Our Radon search uses y-down coords (see textbook_page_deskew.dart for
  // the derivation), so to visually straighten we apply -bestAngleMath.
  return -bestAngleMath;
}

const double _degToRad = math.pi / 180.0;
double _sin(double x) => math.sin(x);
double _cos(double x) => math.cos(x);

// ─────────── Column-aware region normalization ───────────
//
// The VLM fits each `item_region` tightly around that one problem's content,
// which means two problems in the same column can end up with visibly
// different widths (one 440 wide, the next 470 wide) and very uneven top /
// bottom gaps. When those crops are laid out side-by-side the result looks
// unbalanced even though the detection is correct.
//
// `normalizeItemRegionsByColumn` rewrites the regions so that:
//   • every item in the same column shares the same `xmin` / `xmax`
//     (taken from the union of the column's regions — the widest problem
//     sets the width for everyone), and
//   • the vertical padding is pushed out to a fixed target (`targetPaddingY1k`)
//     as long as the midpoint with the adjacent item still leaves a safety
//     gap. No edge is moved outward by more than `maxExpandY1k`, so the VLM
//     always has the final say when it was already generous.
//
// The function never *shrinks* a region — only pushes an edge outward — so it
// can't accidentally cut off content the VLM already captured. If everything
// is off the same way on a page it simply becomes "off the same way" on
// every item, which is exactly what the operator wants when eyeballing the
// crop grid.

/// Per-item input for [normalizeItemRegionsByColumn].
class ColumnRegionInput {
  const ColumnRegionInput({required this.itemRegion, required this.column});

  /// `[ymin, xmin, ymax, xmax]` in the VLM's 0..1000 space. May be `null` /
  /// wrong length when the detector didn't produce a region for this item —
  /// in that case the function returns the original value unchanged.
  final List<int>? itemRegion;

  /// `1` for the left column, `2` for the right column, `null` for
  /// single-column or unknown layouts. Items with the same non-null column
  /// are normalised together; items with `null` are normalised as their own
  /// bucket.
  final int? column;
}

/// Produces one adjusted region per input, in the same order. When an input
/// has a malformed / missing region the matching slot in the result is the
/// untouched original (or `null` if it was `null`).
List<List<int>?> normalizeItemRegionsByColumn({
  required List<ColumnRegionInput> items,
  double targetPaddingY1k = 10,
  double maxExpandY1k = 24,
  double pairSafetyGapY1k = 2,
}) {
  final result = <List<int>?>[];
  for (final it in items) {
    final r = it.itemRegion;
    if (r == null || r.length != 4) {
      result.add(r == null ? null : List<int>.from(r));
    } else {
      result.add(List<int>.from(r));
    }
  }

  // Group by column. `null` goes into its own bucket keyed by -1 so it never
  // collides with real columns 1 / 2.
  final buckets = <int, List<int>>{};
  for (var i = 0; i < items.length; i++) {
    final r = items[i].itemRegion;
    if (r == null || r.length != 4) continue;
    final key = items[i].column ?? -1;
    buckets.putIfAbsent(key, () => <int>[]).add(i);
  }

  final targetPad = targetPaddingY1k.round();
  final maxExpand = maxExpandY1k.round();
  final safety = pairSafetyGapY1k.round();

  for (final entry in buckets.entries) {
    final indices = entry.value;
    if (indices.isEmpty) continue;

    // ── Column x-snap ────────────────────────────────────────────────
    // Use the column's widest left/right edges. Outliers here almost always
    // mean "this problem really is the widest in the column" (a figure or
    // a long formula), so we keep the union instead of a percentile.
    var colXMin = 1001;
    var colXMax = -1;
    for (final idx in indices) {
      final r = items[idx].itemRegion!;
      colXMin = math.min(colXMin, r[1]);
      colXMax = math.max(colXMax, r[3]);
    }
    if (colXMin < colXMax) {
      for (final idx in indices) {
        final r = result[idx]!;
        r[1] = colXMin;
        r[3] = colXMax;
      }
    }

    // ── Vertical normalisation ──────────────────────────────────────
    // Sort by original ymin so "previous" / "next" stays a meaningful notion
    // even if the VLM returned the items in reading order that does not
    // quite match top-down order for this column.
    indices.sort((a, b) =>
        items[a].itemRegion![0].compareTo(items[b].itemRegion![0]));

    for (var k = 0; k < indices.length; k++) {
      final idx = indices[k];
      final origTop = items[idx].itemRegion![0];
      final origBot = items[idx].itemRegion![2];

      // Start by attempting the full target padding.
      var newTop = origTop - targetPad;
      var newBot = origBot + targetPad;

      // Cap the outward movement so we never drift far from the VLM's idea.
      newTop = math.max(newTop, origTop - maxExpand);
      newBot = math.min(newBot, origBot + maxExpand);

      // Never go outside the image.
      newTop = math.max(newTop, 0);
      newBot = math.min(newBot, 1000);

      // Midpoint with the previous item — we must not cross into it.
      if (k > 0) {
        final prevIdx = indices[k - 1];
        final prevOrigBot = items[prevIdx].itemRegion![2];
        if (prevOrigBot < origTop) {
          final mid = (prevOrigBot + origTop) ~/ 2;
          newTop = math.max(newTop, mid + safety);
        } else {
          // Overlap in the VLM output — don't expand upward at all.
          newTop = origTop;
        }
      }

      // Midpoint with the next item.
      if (k < indices.length - 1) {
        final nextIdx = indices[k + 1];
        final nextOrigTop = items[nextIdx].itemRegion![0];
        if (origBot < nextOrigTop) {
          final mid = (origBot + nextOrigTop) ~/ 2;
          newBot = math.min(newBot, mid - safety);
        } else {
          newBot = origBot;
        }
      }

      // Never shrink below the original tight box (so we keep every glyph).
      newTop = math.min(newTop, origTop);
      newBot = math.max(newBot, origBot);

      if (newBot <= newTop) {
        // Degenerate — fall back to the VLM's original box.
        newTop = origTop;
        newBot = origBot;
      }

      final r = result[idx]!;
      r[0] = newTop;
      r[2] = newBot;
    }
  }

  return result;
}
