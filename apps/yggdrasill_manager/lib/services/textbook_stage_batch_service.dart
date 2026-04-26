import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'textbook_pdf_page_renderer.dart';
import 'textbook_pdf_service.dart';
import 'textbook_vlm_answer_service.dart';
import 'textbook_vlm_solution_ref_service.dart';

class TextbookStageBatchService {
  TextbookStageBatchService({
    TextbookPdfService? pdfService,
    TextbookVlmAnswerService? answerService,
    TextbookVlmSolutionRefService? solutionRefService,
    SupabaseClient? supabase,
    http.Client? httpClient,
  })  : _pdfService = pdfService ?? TextbookPdfService(),
        _answerService = answerService ?? TextbookVlmAnswerService(),
        _solutionRefService =
            solutionRefService ?? TextbookVlmSolutionRefService(),
        _supa = supabase ?? Supabase.instance.client,
        _http = httpClient ?? http.Client();

  static const int _vlmLongEdgePx = 1500;

  final TextbookPdfService _pdfService;
  final TextbookVlmAnswerService _answerService;
  final TextbookVlmSolutionRefService _solutionRefService;
  final SupabaseClient _supa;
  final http.Client _http;

  Future<TextbookStageBatchResult> runStage23ForSubunit({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required int bigOrder,
    required int midOrder,
    required String subKey,
    void Function(String status)? onStatus,
  }) async {
    final crops = await _loadCrops(
      academyId: academyId,
      bookId: bookId,
      gradeLabel: gradeLabel,
      bigOrder: bigOrder,
      midOrder: midOrder,
      subKey: subKey,
    );
    if (crops.isEmpty) {
      return const TextbookStageBatchResult(
        answerSaved: 0,
        solutionRefSaved: 0,
        answerMissing: <String>[],
        solutionMissing: <String>[],
      );
    }

    onStatus?.call('정답 PDF 준비 중...');
    final answerDoc = await _downloadPdf(
      academyId: academyId,
      bookId: bookId,
      gradeLabel: gradeLabel,
      kind: 'ans',
      tempPrefix: 'batch_answer',
    );
    onStatus?.call('해설 PDF 준비 중...');
    final solutionDoc = await _downloadPdf(
      academyId: academyId,
      bookId: bookId,
      gradeLabel: gradeLabel,
      kind: 'sol',
      tempPrefix: 'batch_solution',
    );

    try {
      final answerResult = await _runAnswers(
        doc: answerDoc,
        academyId: academyId,
        bookId: bookId,
        gradeLabel: gradeLabel,
        crops: crops,
        onStatus: onStatus,
      );
      final solResult = await _runSolutionRefs(
        doc: solutionDoc,
        academyId: academyId,
        bookId: bookId,
        gradeLabel: gradeLabel,
        crops: crops,
        onStatus: onStatus,
      );
      return TextbookStageBatchResult(
        answerSaved: answerResult.saved,
        solutionRefSaved: solResult.saved,
        answerMissing: answerResult.missing,
        solutionMissing: solResult.missing,
      );
    } finally {
      answerDoc.dispose();
      solutionDoc.dispose();
    }
  }

  Future<List<_BatchCrop>> _loadCrops({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required int bigOrder,
    required int midOrder,
    required String subKey,
  }) async {
    final rows = await _supa
        .from('textbook_problem_crops')
        .select('id, problem_number, is_set_header')
        .eq('academy_id', academyId)
        .eq('book_id', bookId)
        .eq('grade_label', gradeLabel)
        .eq('big_order', bigOrder)
        .eq('mid_order', midOrder)
        .eq('sub_key', subKey)
        .order('raw_page')
        .order('problem_number');
    return (rows as List)
        .whereType<Map>()
        .map((row) => _BatchCrop.fromRow(row))
        .where((crop) => crop.id.isNotEmpty && crop.problemNumber.isNotEmpty)
        .toList(growable: false);
  }

  Future<PdfDocument> _downloadPdf({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required String kind,
    required String tempPrefix,
  }) async {
    final target = await _pdfService.requestDownloadUrl(
      academyId: academyId,
      fileId: bookId,
      gradeLabel: gradeLabel,
      kind: kind,
    );
    if (target.url.isEmpty) throw Exception('${kind}_pdf_url_empty');
    final tempDir = await getTemporaryDirectory();
    final safeBook = bookId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final file = File(p.join(
      tempDir.path,
      '${tempPrefix}_${safeBook}_${gradeLabel}_${DateTime.now().microsecondsSinceEpoch}.pdf',
    ));
    final res = await _http.get(Uri.parse(target.url));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('${kind}_pdf_download_failed(${res.statusCode})');
    }
    await file.writeAsBytes(res.bodyBytes, flush: true);
    return PdfDocument.openFile(file.path);
  }

  Future<_SavedWithMissing> _runAnswers({
    required PdfDocument doc,
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required List<_BatchCrop> crops,
    void Function(String status)? onStatus,
  }) async {
    final answerCrops = crops.where((crop) => !crop.isSetHeader).toList();
    final expected = <String>[
      for (final c in answerCrops) c.problemNumber,
    ];
    if (expected.isEmpty) {
      return const _SavedWithMissing(saved: 0, missing: <String>[]);
    }

    final aggregated = <TextbookVlmAnswerItem>[];
    final imageByNumber = <String, _ImageAnswerCrop>{};
    final totalPages = doc.pages.length;
    for (var page = 1; page <= totalPages; page += 1) {
      onStatus?.call('정답 VLM $page / $totalPages 페이지...');
      Uint8List png;
      try {
        png = await renderPdfPageToPng(
          document: doc,
          pageNumber: page,
          longEdgePx: _vlmLongEdgePx,
        );
      } catch (_) {
        continue;
      }
      try {
        final result = await _answerService.extractAnswersOnPage(
          imageBytes: png,
          rawPage: page,
          academyId: academyId,
          bookId: bookId,
          gradeLabel: gradeLabel,
          expectedNumbers: expected,
        );
        for (final item in result.items) {
          if (item.answerText.trim().isEmpty) continue;
          aggregated.add(item);
          if (item.isImage && item.bbox != null) {
            final crop = _cropAnswerImage(png, item.bbox!);
            if (crop != null) {
              imageByNumber.putIfAbsent(item.problemNumber, () => crop);
            }
          }
        }
      } catch (_) {
        continue;
      }
    }

    final report = TextbookAnswerMatchReport.match(
      expectedNumbers: expected,
      items: aggregated,
    );
    final cropIdByNumber = <String, String>{
      for (final crop in answerCrops) crop.problemNumber: crop.id,
    };
    final uploads = <TextbookAnswerUpload>[];
    for (final entry in report.matched.entries) {
      final cropId = cropIdByNumber[entry.key];
      if (cropId == null) continue;
      final item = entry.value;
      uploads.add(TextbookAnswerUpload(
        cropId: cropId,
        answerKind: item.kind,
        answerText: item.answerText,
        answerLatex2d:
            item.answerLatex2d.isEmpty ? item.answerText : item.answerLatex2d,
        answerSource: 'vlm',
        bbox1k: item.bbox,
        answerImagePngBytes: imageByNumber[entry.key]?.pngBytes,
        answerImageRegion1k: item.isImage ? item.bbox : null,
        answerImageWidthPx: imageByNumber[entry.key]?.width,
        answerImageHeightPx: imageByNumber[entry.key]?.height,
      ));
    }
    final saved = await _answerService.batchUpsertAnswers(
      academyId: academyId,
      answers: uploads,
    );
    return _SavedWithMissing(saved: saved, missing: report.missing);
  }

  _ImageAnswerCrop? _cropAnswerImage(Uint8List pagePng, List<int> bbox1k) {
    final decoded = img.decodeImage(pagePng);
    if (decoded == null || bbox1k.length != 4) return null;
    final ymin = bbox1k[0].clamp(0, 1000);
    final xmin = bbox1k[1].clamp(0, 1000);
    final ymax = bbox1k[2].clamp(0, 1000);
    final xmax = bbox1k[3].clamp(0, 1000);
    var x = (xmin / 1000 * decoded.width).floor();
    var y = (ymin / 1000 * decoded.height).floor();
    var w = ((xmax - xmin) / 1000 * decoded.width).ceil();
    var h = ((ymax - ymin) / 1000 * decoded.height).ceil();
    if (w <= 0 || h <= 0) return null;
    x = x.clamp(0, decoded.width - 1);
    y = y.clamp(0, decoded.height - 1);
    w = w.clamp(1, decoded.width - x);
    h = h.clamp(1, decoded.height - y);
    final cropped = img.copyCrop(decoded, x: x, y: y, width: w, height: h);
    return _ImageAnswerCrop(
      pngBytes: Uint8List.fromList(img.encodePng(cropped)),
      width: cropped.width,
      height: cropped.height,
    );
  }

  Future<_SavedWithMissing> _runSolutionRefs({
    required PdfDocument doc,
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required List<_BatchCrop> crops,
    void Function(String status)? onStatus,
  }) async {
    final expected = <String>[for (final c in crops) c.problemNumber];
    if (expected.isEmpty) {
      return const _SavedWithMissing(saved: 0, missing: <String>[]);
    }
    final aggregated = <String, _SolutionRefWithPage>{};
    final totalPages = doc.pages.length;
    for (var page = 1; page <= totalPages; page += 1) {
      onStatus?.call('해설 VLM $page / $totalPages 페이지...');
      Uint8List png;
      try {
        png = await renderPdfPageToPng(
          document: doc,
          pageNumber: page,
          longEdgePx: _vlmLongEdgePx,
        );
      } catch (_) {
        continue;
      }
      try {
        final result = await _solutionRefService.detectOnPage(
          imageBytes: png,
          rawPage: page,
          academyId: academyId,
          bookId: bookId,
          gradeLabel: gradeLabel,
          expectedNumbers: expected,
        );
        for (final item in result.items) {
          aggregated.putIfAbsent(
            item.problemNumber,
            () => _SolutionRefWithPage(
              item: item,
              rawPage: result.rawPage,
              displayPage: result.displayPage,
            ),
          );
        }
      } catch (_) {
        continue;
      }
    }

    final cropIdByNumber = <String, String>{
      for (final crop in crops) crop.problemNumber: crop.id,
    };
    final uploads = <TextbookSolutionRefUpload>[];
    final missing = <String>[];
    for (final crop in crops) {
      final found = aggregated[crop.problemNumber];
      final cropId = cropIdByNumber[crop.problemNumber];
      if (cropId == null) continue;
      if (found == null) {
        missing.add(crop.problemNumber);
        continue;
      }
      uploads.add(TextbookSolutionRefUpload(
        cropId: cropId,
        rawPage: found.rawPage,
        displayPage: found.displayPage,
        numberRegion1k: found.item.numberRegion1k,
        contentRegion1k: found.item.contentRegion1k,
        source: 'vlm',
      ));
    }
    final saved = await _solutionRefService.batchUpsertSolutionRefs(
      academyId: academyId,
      refs: uploads,
    );
    return _SavedWithMissing(saved: saved, missing: missing);
  }
}

class TextbookStageBatchResult {
  const TextbookStageBatchResult({
    required this.answerSaved,
    required this.solutionRefSaved,
    required this.answerMissing,
    required this.solutionMissing,
  });

  final int answerSaved;
  final int solutionRefSaved;
  final List<String> answerMissing;
  final List<String> solutionMissing;
}

class _BatchCrop {
  const _BatchCrop({
    required this.id,
    required this.problemNumber,
    required this.isSetHeader,
  });

  final String id;
  final String problemNumber;
  final bool isSetHeader;

  factory _BatchCrop.fromRow(Map<dynamic, dynamic> row) {
    return _BatchCrop(
      id: '${row['id'] ?? ''}'.trim(),
      problemNumber: '${row['problem_number'] ?? ''}'.trim(),
      isSetHeader: row['is_set_header'] == true,
    );
  }
}

class _SolutionRefWithPage {
  const _SolutionRefWithPage({
    required this.item,
    required this.rawPage,
    required this.displayPage,
  });

  final TextbookVlmSolutionRefItem item;
  final int rawPage;
  final int displayPage;
}

class _ImageAnswerCrop {
  const _ImageAnswerCrop({
    required this.pngBytes,
    required this.width,
    required this.height,
  });

  final Uint8List pngBytes;
  final int width;
  final int height;
}

class _SavedWithMissing {
  const _SavedWithMissing({
    required this.saved,
    required this.missing,
  });

  final int saved;
  final List<String> missing;
}
