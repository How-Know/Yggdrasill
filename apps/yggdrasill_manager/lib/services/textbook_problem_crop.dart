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
    this.avoidNumber = false,
    this.maskRemainingNumber = false,
    this.numberMarginPx = 6,
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

  final cropped = img.copyCrop(
    source,
    x: cx,
    y: cy,
    width: cw,
    height: ch,
  );

  // If we couldn't push an edge past the number, white-mask it out so the
  // printed crop doesn't carry the number glyph.
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

  final pngBytes = Uint8List.fromList(img.encodePng(cropped));
  return ProblemCrop(
    pngBytes: pngBytes,
    cropRectPx: [cx, cy, cw, ch],
    paddingPx: padPx,
    avoidedNumberEdge: avoidedEdge,
    maskedNumber: maskedNumber,
  );
}
