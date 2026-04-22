import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

/// Renders a single page of a loaded [PdfDocument] to a PNG byte buffer.
///
/// Used by the VLM test harness to ship individual pages to the gateway.
/// Not wired into any production flow.
///
/// [longEdgePx] controls the render resolution; the longer edge of the page
/// will be rendered at this many pixels. 1500 px is a good starting point for
/// ~300 dpi A4 scans: problem numbers stay crisp while the PNG stays under
/// a few MB.
Future<Uint8List> renderPdfPageToPng({
  required PdfDocument document,
  required int pageNumber,
  int longEdgePx = 1500,
}) async {
  if (pageNumber < 1 || pageNumber > document.pages.length) {
    throw ArgumentError(
      'pageNumber $pageNumber out of range (1..${document.pages.length})',
    );
  }
  final page = document.pages[pageNumber - 1];

  final pageW = page.width;
  final pageH = page.height;
  final longEdge = pageW > pageH ? pageW : pageH;
  final scale = longEdgePx / longEdge;
  final renderW = (pageW * scale).round();
  final renderH = (pageH * scale).round();

  final pdfImage = await page.render(
    fullWidth: renderW.toDouble(),
    fullHeight: renderH.toDouble(),
    backgroundColor: const ui.Color(0xFFFFFFFF),
  );
  if (pdfImage == null) {
    throw StateError('pdfrx_render_returned_null on page $pageNumber');
  }
  try {
    final image = await pdfImage.createImage();
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw StateError('png_encode_failed on page $pageNumber');
      }
      return byteData.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    pdfImage.dispose();
  }
}

/// Returns the rendered pixel dimensions we *will* use for [pageNumber] at
/// [longEdgePx]. Callers need this to scale VLM bounding boxes (which come
/// back normalized 0..1000) back onto the rendered image.
PageRenderSize pagePixelSize({
  required PdfDocument document,
  required int pageNumber,
  int longEdgePx = 1500,
}) {
  if (pageNumber < 1 || pageNumber > document.pages.length) {
    throw ArgumentError(
      'pageNumber $pageNumber out of range (1..${document.pages.length})',
    );
  }
  final page = document.pages[pageNumber - 1];
  final pageW = page.width;
  final pageH = page.height;
  final longEdge = pageW > pageH ? pageW : pageH;
  final scale = longEdgePx / longEdge;
  return PageRenderSize(
    widthPx: (pageW * scale).round(),
    heightPx: (pageH * scale).round(),
    pdfWidth: pageW,
    pdfHeight: pageH,
  );
}

class PageRenderSize {
  const PageRenderSize({
    required this.widthPx,
    required this.heightPx,
    required this.pdfWidth,
    required this.pdfHeight,
  });

  final int widthPx;
  final int heightPx;
  final double pdfWidth;
  final double pdfHeight;
}
