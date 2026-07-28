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
  static const int _answerImageLongEdgePx = 3000;

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
    String seriesKey = '',
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
        seriesKey: seriesKey,
        crops: crops,
        onStatus: onStatus,
      );
      final solResult = await _runSolutionRefs(
        doc: solutionDoc,
        academyId: academyId,
        bookId: bookId,
        gradeLabel: gradeLabel,
        crops: crops,
        seriesKey: seriesKey,
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
        .select('id, problem_number, is_set_header, section, display_page')
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
      requireMigratedStorage: true,
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
    String seriesKey = '',
    void Function(String status)? onStatus,
  }) async {
    final answerCrops = crops.where((crop) => !crop.isSetHeader).toList();
    // 개념+유형 답지는 코너별 박스로 인쇄되고 코너·소단원마다 번호가 1번부터
    // 다시 시작한다. 번호를 Map 키로 쓰면 같은 "1" 끼리 서로를 덮어써서 절반이
    // 정답 없이 남으므로, 목록의 위치를 열쇠로 쓴다.
    final targets = <_BatchTarget>[
      for (final c in answerCrops)
        if (c.problemNumber.trim().isNotEmpty)
          _BatchTarget(
            crop: c,
            expected: textbookExpectedAnswerFor(
              seriesKey: seriesKey,
              problemNumber: c.problemNumber,
              section: c.section,
              displayPage: c.displayPage,
            ),
          ),
    ];
    if (targets.isEmpty) {
      return const _SavedWithMissing(saved: 0, missing: <String>[]);
    }
    final batch = TextbookExpectedAnswerBatch(
      positions: <int>[for (var i = 0; i < targets.length; i += 1) i],
      entries: <TextbookExpectedAnswer>[for (final t in targets) t.expected],
    );

    final hits = <int, _BatchAnswerHit>{};
    final answerImagePageCache = <int, Uint8List>{};
    final pageErrors = <String>[];
    final totalPages = doc.pages.length;

    Future<Uint8List?> answerImagePagePng(int page) async {
      final cached = answerImagePageCache[page];
      if (cached != null) return cached;
      try {
        final png = await renderPdfPageToPng(
          document: doc,
          pageNumber: page,
          longEdgePx: _answerImageLongEdgePx,
        );
        answerImagePageCache[page] = png;
        return png;
      } catch (_) {
        return null;
      }
    }

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
          expectedNumbers: batch.numbers,
          expectedDetails: batch.entries,
          seriesKey: seriesKey,
        );
        for (final item in result.items) {
          if (item.answerText.trim().isEmpty) continue;
          final matched = batch.resolve(
            detectedNumber: item.problemNumber,
            expectedIndex: item.expectedIndex,
          );
          if (matched.isEmpty) continue;
          _ImageAnswerCrop? imageCrop;
          if (item.isImage && item.bbox != null) {
            final imagePng = await answerImagePagePng(result.rawPage);
            imageCrop = imagePng == null
                ? _cropAnswerImage(png, item.bbox!)
                : _cropAnswerImage(imagePng, item.bbox!);
          }
          for (final position in matched) {
            hits.putIfAbsent(
              position,
              () => _BatchAnswerHit(
                item: item,
                rawPage: result.rawPage,
                displayPage: result.displayPage,
                imageCrop: imageCrop,
              ),
            );
          }
        }
      } catch (e) {
        pageErrors.add('p$page: $e');
        onStatus?.call('정답 VLM $page / $totalPages 페이지 실패: $e');
        continue;
      }
    }

    if (hits.isEmpty) {
      final sample = pageErrors.isEmpty
          ? '모든 정답 PDF 페이지에서 매칭 가능한 정답을 찾지 못했습니다.'
          : pageErrors.take(3).join(' / ');
      throw Exception('정답 VLM 추출 실패: $sample');
    }

    final uploads = <TextbookAnswerUpload>[];
    final missing = <String>[];
    for (var position = 0; position < targets.length; position += 1) {
      final hit = hits[position];
      if (hit == null) {
        missing.add(targets[position].missingLabel);
        continue;
      }
      final item = hit.item;
      uploads.add(TextbookAnswerUpload(
        cropId: targets[position].crop.id,
        answerKind: item.kind,
        answerText: item.answerText,
        answerLatex2d:
            item.answerLatex2d.isEmpty ? item.answerText : item.answerLatex2d,
        answerSource: 'vlm',
        rawPage: hit.rawPage,
        displayPage: hit.displayPage,
        bbox1k: item.bbox,
        answerImagePngBytes: hit.imageCrop?.pngBytes,
        answerImageRegion1k: item.isImage ? item.bbox : null,
        answerImageWidthPx: hit.imageCrop?.width,
        answerImageHeightPx: hit.imageCrop?.height,
      ));
    }
    final saved = await _answerService.batchUpsertAnswers(
      academyId: academyId,
      answers: uploads,
    );
    return _SavedWithMissing(saved: saved, missing: missing);
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
    String seriesKey = '',
    void Function(String status)? onStatus,
  }) async {
    // 정답 단계와 같은 이유로 순서 배열을 쓴다.
    final targets = <_BatchTarget>[
      for (final c in crops)
        if (c.problemNumber.trim().isNotEmpty)
          _BatchTarget(
            crop: c,
            expected: textbookExpectedAnswerFor(
              seriesKey: seriesKey,
              problemNumber: c.problemNumber,
              section: c.section,
              displayPage: c.displayPage,
            ),
          ),
    ];
    if (targets.isEmpty) {
      return const _SavedWithMissing(saved: 0, missing: <String>[]);
    }
    final batch = TextbookExpectedAnswerBatch(
      positions: <int>[for (var i = 0; i < targets.length; i += 1) i],
      entries: <TextbookExpectedAnswer>[for (final t in targets) t.expected],
    );
    final hits = <int, _SolutionRefWithPage>{};
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
          expectedNumbers: batch.numbers,
          expectedDetails: batch.entries,
          seriesKey: seriesKey,
        );
        for (final item in result.items) {
          final matched = batch.resolve(
            detectedNumber: item.problemNumber,
            expectedIndex: item.expectedIndex,
          );
          for (final position in matched) {
            hits.putIfAbsent(
              position,
              () => _SolutionRefWithPage(
                item: item,
                rawPage: result.rawPage,
                displayPage: result.displayPage,
              ),
            );
          }
        }
      } catch (_) {
        continue;
      }
    }

    final uploads = <TextbookSolutionRefUpload>[];
    final missing = <String>[];
    for (var position = 0; position < targets.length; position += 1) {
      final found = hits[position];
      if (found == null) {
        missing.add(targets[position].missingLabel);
        continue;
      }
      uploads.add(TextbookSolutionRefUpload(
        cropId: targets[position].crop.id,
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
    this.section = '',
    this.displayPage,
  });

  final String id;
  final String problemNumber;
  final bool isSetHeader;
  final String section;
  final int? displayPage;

  factory _BatchCrop.fromRow(Map<dynamic, dynamic> row) {
    final page = int.tryParse('${row['display_page'] ?? ''}');
    return _BatchCrop(
      id: '${row['id'] ?? ''}'.trim(),
      problemNumber: '${row['problem_number'] ?? ''}'.trim(),
      isSetHeader: row['is_set_header'] == true,
      section: '${row['section'] ?? ''}'.trim(),
      displayPage: page != null && page > 0 ? page : null,
    );
  }
}

/// 크롭 하나와, 그 크롭을 답지·해설에서 특정하기 위한 기대 정보의 짝.
///
/// 목록에서의 위치가 곧 크롭의 신분증이다. 번호는 코너마다 겹치므로 못 쓴다.
class _BatchTarget {
  const _BatchTarget({required this.crop, required this.expected});

  final _BatchCrop crop;
  final TextbookExpectedAnswer expected;

  /// 누락 보고에 쓰는 이름. 번호만 적으면 어느 코너가 빠졌는지 알 수 없다.
  String get missingLabel {
    final corner = expected.corner.trim();
    return corner.isEmpty
        ? crop.problemNumber
        : '$corner ${crop.problemNumber}';
  }
}

class _BatchAnswerHit {
  const _BatchAnswerHit({
    required this.item,
    required this.rawPage,
    required this.displayPage,
    this.imageCrop,
  });

  final TextbookVlmAnswerItem item;
  final int rawPage;
  final int displayPage;
  final _ImageAnswerCrop? imageCrop;
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
