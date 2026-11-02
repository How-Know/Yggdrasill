import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'textbook_pdf_service.dart';

/// 문항검수용 — 해설 PDF(또는 본문 PDF)에서 `textbook_problem_solution_refs` 좌표 영역만 잘라 PNG로 만든다.
///
/// Stage 3에서 저장한 좌표([ymin, xmin, ymax, xmax], 0..1000)는 쪽 전체 기준이므로 pdfrx 부분 렌더(x, y, width, height)로
/// 그 영역만 고해상도로 찍는다. 잘라낸 이미지는 ai_think(textbook_problem_review)에 base64로 보내 Vision이 원본 해설을 전사한다.
class TextbookReviewSolutionImageService {
  TextbookReviewSolutionImageService({
    TextbookPdfService? pdfService,
    http.Client? httpClient,
  })  : _pdf = pdfService ?? TextbookPdfService(),
        _http = httpClient ?? http.Client();

  final TextbookPdfService _pdf;
  final http.Client _http;

  final Map<String, Future<PdfDocument?>> _docLoads = {};
  final Map<String, PdfDocument> _docs = {};

  /// 잘라낸 영역의 가로 목표 해상도. 2단 조판 해설 한 칸이 1100px면 수식 첨자까지 읽힌다.
  static const int kTargetCropWidthPx = 1100;
  static const int kMaxFullLongEdgePx = 5200;

  /// 좌표 주변 여백(0..1000 단위). 번호 글자나 마지막 줄이 잘리지 않게 조금 넓힌다.
  static const int kRegionPad1k = 10;

  String _docKey(String bookId, String gradeLabel, String kind) => '$bookId|$gradeLabel|$kind';

  Future<PdfDocument?> _ensureDoc({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required String kind,
  }) {
    final key = _docKey(bookId, gradeLabel, kind);
    final loaded = _docs[key];
    if (loaded != null) return Future.value(loaded);
    return _docLoads.putIfAbsent(key, () async {
      try {
        final target = await _pdf.requestDownloadUrl(
          academyId: academyId,
          fileId: bookId,
          gradeLabel: gradeLabel,
          kind: kind,
          requireMigratedStorage: true,
        );
        if (target.url.isEmpty) return null;
        final tempDir = await getTemporaryDirectory();
        final safeBook = bookId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
        final safeGrade = gradeLabel.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
        final file = File(p.join(tempDir.path, 'review_${safeBook}_${safeGrade}_$kind.pdf'));
        final res = await _http.get(Uri.parse(target.url));
        if (res.statusCode < 200 || res.statusCode >= 300) return null;
        await file.writeAsBytes(res.bodyBytes, flush: true);
        final doc = await PdfDocument.openFile(file.path);
        _docs[key] = doc;
        return doc;
      } catch (_) {
        return null;
      } finally {
        _docLoads.remove(key);
      }
    });
  }

  /// 해설 좌표 영역 PNG. PDF를 못 받거나 쪽·좌표가 없으면 null.
  Future<Uint8List?> renderSolutionCrop({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required String sourceKind,
    required int rawPage,
    required List<int> region1k,
  }) async {
    if (rawPage < 1 || region1k.length != 4) return null;
    final kind = sourceKind == 'body' ? 'body' : 'sol';
    final doc = await _ensureDoc(academyId: academyId, bookId: bookId, gradeLabel: gradeLabel, kind: kind);
    if (doc == null || rawPage > doc.pages.length) return null;
    final page = doc.pages[rawPage - 1];

    final ymin = (region1k[0] - kRegionPad1k).clamp(0, 1000);
    final xmin = (region1k[1] - kRegionPad1k).clamp(0, 1000);
    final ymax = (region1k[2] + kRegionPad1k).clamp(0, 1000);
    final xmax = (region1k[3] + kRegionPad1k).clamp(0, 1000);
    if (ymax <= ymin || xmax <= xmin) return null;

    final cropWFrac = (xmax - xmin) / 1000.0;
    final cropHFrac = (ymax - ymin) / 1000.0;
    // 잘라낸 폭이 목표 해상도가 되도록 쪽 전체 배율을 정한다(너무 작은 영역이면 전체 배율 상한으로 묶는다).
    var fullW = kTargetCropWidthPx / cropWFrac;
    var fullH = fullW * (page.height / page.width);
    final longEdge = fullW > fullH ? fullW : fullH;
    if (longEdge > kMaxFullLongEdgePx) {
      final s = kMaxFullLongEdgePx / longEdge;
      fullW *= s;
      fullH *= s;
    }
    final x = (fullW * xmin / 1000.0).floor();
    final y = (fullH * ymin / 1000.0).floor();
    final w = (fullW * cropWFrac).ceil().clamp(1, fullW.ceil());
    final h = (fullH * cropHFrac).ceil().clamp(1, fullH.ceil());

    final img = await page.render(
      x: x,
      y: y,
      width: w,
      height: h,
      fullWidth: fullW,
      fullHeight: fullH,
      backgroundColor: const ui.Color(0xFFFFFFFF),
    );
    if (img == null) return null;
    try {
      final image = await img.createImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        return bytes?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      img.dispose();
    }
  }

  void dispose() {
    for (final d in _docs.values) {
      d.dispose();
    }
    _docs.clear();
  }
}
