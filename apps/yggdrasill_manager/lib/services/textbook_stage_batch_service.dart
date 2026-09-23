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
  static const Duration _pdfCacheMaxAge = Duration(days: 7);
  static final Map<String, Future<File>> _pdfDownloadsInFlight =
      <String, Future<File>>{};

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
    required int subIndex,
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
      subIndex: subIndex,
    );
    if (crops.isEmpty) {
      return const TextbookStageBatchResult(
        answerSaved: 0,
        solutionRefSaved: 0,
        answerMissing: <String>[],
        solutionMissing: <String>[],
      );
    }

    if (seriesKey.trim().toLowerCase() == 'wonri_middle') {
      final bodyCrops = crops
          .where((crop) => textbookWonriMiddleUsesBodySolution(
                section: crop.section,
                problemNumber: crop.problemNumber,
                itemName: crop.itemName,
              ))
          .toList(growable: false);
      final solutionCrops = crops
          .where((crop) => !textbookWonriMiddleUsesBodySolution(
                section: crop.section,
                problemNumber: crop.problemNumber,
                itemName: crop.itemName,
              ))
          .toList(growable: false);
      PdfDocument? bodyDoc;
      PdfDocument? solutionDoc;
      try {
        if (bodyCrops.isNotEmpty) {
          onStatus?.call('본문 PDF 준비 중...');
          bodyDoc = await _downloadPdf(
            academyId: academyId,
            bookId: bookId,
            gradeLabel: gradeLabel,
            kind: 'body',
            tempPrefix: 'batch_wonri_middle_body',
          );
        }
        if (solutionCrops.isNotEmpty) {
          onStatus?.call('해설 PDF 준비 중...');
          solutionDoc = await _downloadPdf(
            academyId: academyId,
            bookId: bookId,
            gradeLabel: gradeLabel,
            kind: 'sol',
            tempPrefix: 'batch_wonri_middle_solution',
          );
        }
        final bodyResult = bodyDoc == null
            ? const TextbookStageBatchResult(
                answerSaved: 0,
                solutionRefSaved: 0,
                answerMissing: <String>[],
                solutionMissing: <String>[],
              )
            : await _runWonriMiddleBody(
                doc: bodyDoc,
                academyId: academyId,
                crops: bodyCrops,
                onStatus: onStatus,
              );
        final quickAnswerResult = solutionDoc == null
            ? const TextbookStageBatchResult(
                answerSaved: 0,
                solutionRefSaved: 0,
                answerMissing: <String>[],
                solutionMissing: <String>[],
              )
            : await _runWonriMiddleCombined(
                doc: solutionDoc,
                academyId: academyId,
                crops: solutionCrops,
                answers: true,
                onStatus: onStatus,
              );
        final detailedSolutionResult = solutionDoc == null
            ? const TextbookStageBatchResult(
                answerSaved: 0,
                solutionRefSaved: 0,
                answerMissing: <String>[],
                solutionMissing: <String>[],
              )
            : await _runWonriMiddleCombined(
                doc: solutionDoc,
                academyId: academyId,
                crops: solutionCrops,
                answers: false,
                onStatus: onStatus,
              );
        return TextbookStageBatchResult(
          answerSaved: bodyResult.answerSaved + quickAnswerResult.answerSaved,
          solutionRefSaved: bodyResult.solutionRefSaved +
              detailedSolutionResult.solutionRefSaved,
          answerMissing: <String>[
            ...bodyResult.answerMissing,
            ...quickAnswerResult.answerMissing,
          ],
          solutionMissing: <String>[
            ...bodyResult.solutionMissing,
            ...detailedSolutionResult.solutionMissing,
          ],
        );
      } finally {
        bodyDoc?.dispose();
        solutionDoc?.dispose();
      }
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
    required int subIndex,
  }) async {
    final rows = await _supa
        .from('textbook_problem_crops')
        .select(
          'id, problem_number, is_set_header, section, raw_page, '
          'display_page, item_name',
        )
        .eq('academy_id', academyId)
        .eq('book_id', bookId)
        .eq('grade_label', gradeLabel)
        .eq('big_order', bigOrder)
        .eq('mid_order', midOrder)
        .eq('sub_key', subKey)
        .eq('sub_index', subIndex)
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
    final cacheDir =
        Directory(p.join(tempDir.path, 'yggdrasill_textbook_pdf_cache'));
    await cacheDir.create(recursive: true);
    await _prunePdfCache(cacheDir);

    final safeBook = bookId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final safeGrade = gradeLabel.replaceAll(RegExp(r'[^A-Za-z0-9가-힣_-]'), '_');
    final rawIdentity = (target.contentHash ?? '').trim().isNotEmpty
        ? target.contentHash!.trim()
        : 'size_${target.fileSizeBytes ?? 0}';
    final safeIdentity = rawIdentity.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final cacheKey = '${tempPrefix}_${safeBook}_${safeGrade}_$safeIdentity';
    final file = File(p.join(cacheDir.path, '$cacheKey.pdf'));

    if (await _isValidCachedPdf(file, target.fileSizeBytes)) {
      return PdfDocument.openFile(file.path);
    }

    final pending = _pdfDownloadsInFlight[cacheKey];
    if (pending != null) {
      final cached = await pending;
      return PdfDocument.openFile(cached.path);
    }

    final download = _downloadPdfToCache(
      target: target,
      destination: file,
      kind: kind,
    );
    _pdfDownloadsInFlight[cacheKey] = download;
    try {
      final cached = await download;
      return PdfDocument.openFile(cached.path);
    } finally {
      _pdfDownloadsInFlight.remove(cacheKey);
    }
  }

  Future<bool> _isValidCachedPdf(File file, int? expectedSize) async {
    if (!await file.exists()) return false;
    final length = await file.length();
    if (length <= 0) return false;
    return expectedSize == null || expectedSize <= 0 || length == expectedSize;
  }

  Future<File> _downloadPdfToCache({
    required TextbookDownloadTarget target,
    required File destination,
    required String kind,
  }) async {
    final res = await _http.get(Uri.parse(target.url));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('${kind}_pdf_download_failed(${res.statusCode})');
    }
    final expectedSize = target.fileSizeBytes;
    if (expectedSize != null &&
        expectedSize > 0 &&
        res.bodyBytes.length != expectedSize) {
      throw Exception(
        '${kind}_pdf_size_mismatch(${res.bodyBytes.length}/$expectedSize)',
      );
    }
    final partial = File(
      '${destination.path}.${DateTime.now().microsecondsSinceEpoch}.part',
    );
    await partial.writeAsBytes(res.bodyBytes, flush: true);
    if (await destination.exists()) {
      await destination.delete();
    }
    return partial.rename(destination.path);
  }

  Future<void> _prunePdfCache(Directory cacheDir) async {
    final cutoff = DateTime.now().subtract(_pdfCacheMaxAge);
    try {
      await for (final entity in cacheDir.list()) {
        if (entity is! File || !entity.path.endsWith('.pdf')) continue;
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete();
        }
      }
    } catch (_) {
      // 캐시 정리 실패는 추출을 막지 않는다.
    }
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
      requireExpectedIndex: textbookAnswerNeedsCorner(seriesKey),
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

  Future<TextbookStageBatchResult> _runWonriMiddleBody({
    required PdfDocument doc,
    required String academyId,
    required List<_BatchCrop> crops,
    void Function(String status)? onStatus,
  }) async {
    final targets = crops
        .where((crop) =>
            !crop.isSetHeader &&
            crop.id.isNotEmpty &&
            crop.problemNumber.isNotEmpty &&
            crop.rawPage != null)
        .toList(growable: false);
    final byPage = <int, List<_BatchCrop>>{};
    for (final crop in targets) {
      byPage.putIfAbsent(crop.rawPage!, () => <_BatchCrop>[]).add(crop);
    }

    final answerUploads = <TextbookAnswerUpload>[];
    final refUploads = <TextbookSolutionRefUpload>[];
    final answerMissingIds = <String>{for (final crop in crops) crop.id};
    final solutionMissingIds = <String>{for (final crop in crops) crop.id};
    final pages = byPage.keys.toList()..sort();
    for (var index = 0; index < pages.length; index += 1) {
      final page = pages[index];
      final pageCrops = byPage[page]!;
      onStatus?.call(
        '중등 개념원리 본문 예제 VLM ${index + 1} / ${pages.length}페이지...',
      );
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
      TextbookVlmBodySolutionPageResult result;
      try {
        result = await _solutionRefService.extractBodySolutionsOnPage(
          imageBytes: png,
          rawPage: page,
          expectedNumbers: <String>[
            for (final crop in pageCrops) crop.problemNumber,
          ],
          seriesKey: 'wonri_middle',
        );
      } catch (_) {
        continue;
      }
      final items = <String, TextbookVlmBodySolutionItem>{
        for (final item in result.items)
          textbookWonriMiddlePrintedNumberKey(item.problemNumber): item,
      };
      for (final crop in pageCrops) {
        final item =
            items[textbookWonriMiddlePrintedNumberKey(crop.problemNumber)];
        if (item == null) continue;
        final role = textbookWonriMiddleItemRole(
          section: crop.section,
          problemNumber: crop.problemNumber,
          itemName: crop.itemName,
        );
        if (item.answerText.isNotEmpty || item.answerLatex2d.isNotEmpty) {
          answerUploads.add(TextbookAnswerUpload(
            cropId: crop.id,
            answerKind: item.answerKind,
            answerText: item.answerText,
            answerLatex2d: item.answerLatex2d.isEmpty
                ? item.answerText
                : item.answerLatex2d,
            answerSource: 'vlm',
            rawPage: page,
            displayPage: crop.displayPage,
            solutionMetadata: <String, dynamic>{
              'solution_kind': 'full',
              'item_role': role,
            },
          ));
          answerMissingIds.remove(crop.id);
        }
        if (item.contentRegion1k != null) {
          refUploads.add(TextbookSolutionRefUpload(
            cropId: crop.id,
            rawPage: page,
            displayPage: crop.displayPage,
            numberRegion1k: item.numberRegion1k,
            contentRegion1k: item.contentRegion1k,
            source: 'vlm',
            sourceKind: 'body',
          ));
          solutionMissingIds.remove(crop.id);
        }
      }
    }
    final answerSaved = await _answerService.batchUpsertAnswers(
      academyId: academyId,
      answers: answerUploads,
    );
    final solutionRefSaved = await _solutionRefService.batchUpsertSolutionRefs(
      academyId: academyId,
      refs: refUploads,
    );
    String missingLabel(_BatchCrop crop) =>
        '${crop.section} ${crop.problemNumber}'.trim();
    return TextbookStageBatchResult(
      answerSaved: answerSaved,
      solutionRefSaved: solutionRefSaved,
      answerMissing: <String>[
        for (final crop in crops)
          if (answerMissingIds.contains(crop.id)) missingLabel(crop),
      ],
      solutionMissing: <String>[
        for (final crop in crops)
          if (solutionMissingIds.contains(crop.id)) missingLabel(crop),
      ],
    );
  }

  Future<TextbookStageBatchResult> _runWonriMiddleCombined({
    required PdfDocument doc,
    required String academyId,
    required List<_BatchCrop> crops,
    required bool answers,
    void Function(String status)? onStatus,
  }) async {
    final targets = crops
        .where((crop) =>
            !crop.isSetHeader &&
            crop.id.isNotEmpty &&
            crop.problemNumber.isNotEmpty)
        .toList(growable: false);
    if (targets.isEmpty) {
      return const TextbookStageBatchResult(
        answerSaved: 0,
        solutionRefSaved: 0,
        answerMissing: <String>[],
        solutionMissing: <String>[],
      );
    }

    final pending = <int>{for (var i = 0; i < targets.length; i += 1) i};
    final hits = <int, _WonriMiddleCombinedHit>{};
    final totalPages = doc.pages.length;
    for (var page = 1; page <= totalPages && pending.isNotEmpty; page += 1) {
      onStatus?.call(
        '중등 개념원리 ${answers ? '빠른 정답' : '상세 해설'} VLM '
        '$page / $totalPages 페이지... '
        '남은 ${pending.length}개',
      );
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
      // 코너를 섞거나 번호를 뒤섞어 물으면 모델이 해설 박스를 특정하지 못하고
      // items=[]로 물러난다. 코너별로 번호 오름차순으로만 묻는다.
      final batches = textbookWonriMiddleRequestBatches(
        order: pending.toList()..sort(),
        sectionOf: (position) => targets[position].section,
        scopeKeyOf: (_) => '',
        numberOf: (position) => targets[position].problemNumber,
      );
      for (final batch in batches) {
        final order = batch.where(pending.contains).toList(growable: false);
        if (order.isEmpty) continue;
        try {
          final result =
              await _solutionRefService.extractWonriMiddleSolutionsOnPage(
            imageBytes: png,
            rawPage: page,
            mode: answers ? 'answers' : 'solution_refs',
            expectedEntries: <TextbookWonriMiddleSolutionExpected>[
              for (final position in order)
                TextbookWonriMiddleSolutionExpected(
                  problemNumber: targets[position].problemNumber,
                  category: targets[position].section,
                  itemRole: textbookWonriMiddleItemRole(
                    section: targets[position].section,
                    problemNumber: targets[position].problemNumber,
                    itemName: targets[position].itemName,
                  ),
                  bodyPage: targets[position].displayPage,
                ),
            ],
          );
          for (final item in result.items) {
            int? position;
            final numberKey =
                textbookWonriMiddlePrintedNumberKey(item.problemNumber);
            if (item.expectedIndex >= 0 && item.expectedIndex < order.length) {
              final indexed = order[item.expectedIndex];
              final crop = targets[indexed];
              if (textbookWonriMiddlePrintedNumberKey(crop.problemNumber) ==
                      numberKey &&
                  (item.category.isEmpty || crop.section == item.category)) {
                position = indexed;
              }
            }
            if (position == null) {
              final candidates = order.where((candidate) {
                final crop = targets[candidate];
                return textbookWonriMiddlePrintedNumberKey(
                          crop.problemNumber,
                        ) ==
                        numberKey &&
                    (item.category.isEmpty || crop.section == item.category);
              }).toList();
              if (candidates.length == 1) position = candidates.single;
            }
            if (position == null || !pending.remove(position)) continue;
            hits[position] = _WonriMiddleCombinedHit(
              item: item,
              rawPage: result.rawPage,
            );
          }
        } catch (_) {
          continue;
        }
      }
    }

    final answerUploads = <TextbookAnswerUpload>[];
    final refUploads = <TextbookSolutionRefUpload>[];
    final missing = <String>[];
    for (var position = 0; position < targets.length; position += 1) {
      final target = targets[position];
      final hit = hits[position];
      if (hit == null) {
        missing.add('${target.section} ${target.problemNumber}'.trim());
        continue;
      }
      final item = hit.item;
      if (answers && item.answerText.isEmpty && item.answerLatex2d.isEmpty) {
        missing.add('${target.section} ${target.problemNumber}'.trim());
        continue;
      }
      if (answers &&
          (item.answerText.isNotEmpty || item.answerLatex2d.isNotEmpty)) {
        answerUploads.add(TextbookAnswerUpload(
          cropId: target.id,
          answerKind: item.answerKind,
          answerText: item.answerText,
          answerLatex2d:
              item.answerLatex2d.isEmpty ? item.answerText : item.answerLatex2d,
          answerSource: 'vlm',
          rawPage: hit.rawPage,
          displayPage: hit.rawPage,
          bbox1k: item.answerRegion1k ?? item.numberRegion1k,
          rubricSteps: item.rubricSteps,
          solutionMetadata: <String, dynamic>{
            'solution_kind': item.solutionKind,
            'item_role': textbookWonriMiddleItemRole(
              section: target.section,
              problemNumber: target.problemNumber,
              itemName: target.itemName,
            ),
            if (item.totalPoints != null) 'total_points': item.totalPoints,
          },
        ));
      }
      if (!answers) {
        refUploads.add(TextbookSolutionRefUpload(
          cropId: target.id,
          rawPage: hit.rawPage,
          displayPage: hit.rawPage,
          numberRegion1k: item.numberRegion1k,
          contentRegion1k: item.contentRegion1k,
          source: 'vlm',
          sourceKind: 'sol',
        ));
      }
    }
    final answerSaved = await _answerService.batchUpsertAnswers(
      academyId: academyId,
      answers: answerUploads,
    );
    final solutionRefSaved = await _solutionRefService.batchUpsertSolutionRefs(
      academyId: academyId,
      refs: refUploads,
    );
    return TextbookStageBatchResult(
      answerSaved: answerSaved,
      solutionRefSaved: solutionRefSaved,
      answerMissing: answers ? missing : const <String>[],
      solutionMissing: answers ? const <String>[] : missing,
    );
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
      requireExpectedIndex: textbookAnswerNeedsCorner(seriesKey),
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
        String itemSection(TextbookVlmSolutionRefItem item) {
          final index = item.expectedIndex;
          if (index >= 0 && index < targets.length) {
            return targets[index].crop.section;
          }
          return RegExp(r'^(예제|유제|연습)').hasMatch(item.problemNumber)
              ? 'descriptive'
              : '';
        }

        final sections = <String>{
          for (final target in targets) target.crop.section
        };
        final reported = <(String, String)>[
          for (final item in result.items)
            (item.problemNumber.trim(), itemSection(item)),
        ];
        final sectionsToVerify = <String>{};
        if (seriesKey == 'gaeyu' && sections.length > 1) {
          for (var position = 0; position < targets.length; position += 1) {
            if (hits.containsKey(position)) continue;
            final target = targets[position];
            final number = target.crop.problemNumber.trim();
            if (reported.any((one) =>
                one.$1 == number &&
                one.$2.isNotEmpty &&
                one.$2 != target.crop.section)) {
              sectionsToVerify.add(target.crop.section);
            }
          }
          if (reported.any((one) => one.$2 == 'descriptive')) {
            sectionsToVerify.add('descriptive');
          }
        }
        final pageItems = sectionsToVerify.isNotEmpty
            ? result.items
                .where((item) => !sectionsToVerify.contains(itemSection(item)))
            : result.items;
        for (final item in pageItems) {
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
        for (final section in sectionsToVerify) {
          final sectionPositions = <int>[
            for (var i = 0; i < targets.length; i += 1)
              if (!hits.containsKey(i) && targets[i].crop.section == section) i,
          ];
          if (sectionPositions.isEmpty) continue;
          final sectionBatch = TextbookExpectedAnswerBatch(
            positions: sectionPositions,
            entries: <TextbookExpectedAnswer>[
              for (final position in sectionPositions)
                targets[position].expected,
            ],
            requireExpectedIndex: textbookAnswerNeedsCorner(seriesKey),
          );
          final verified = await _solutionRefService.detectOnPage(
            imageBytes: png,
            rawPage: page,
            academyId: academyId,
            bookId: bookId,
            gradeLabel: gradeLabel,
            expectedNumbers: sectionBatch.numbers,
            expectedDetails: sectionBatch.entries,
            seriesKey: seriesKey,
          );
          for (final item in verified.items) {
            final matched = sectionBatch.resolve(
              detectedNumber: item.problemNumber,
              expectedIndex: item.expectedIndex,
            );
            for (final position in matched) {
              hits.putIfAbsent(
                position,
                () => _SolutionRefWithPage(
                  item: item,
                  rawPage: verified.rawPage,
                  displayPage: verified.displayPage,
                ),
              );
            }
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
    this.rawPage,
    this.displayPage,
    this.itemName = '',
  });

  final String id;
  final String problemNumber;
  final bool isSetHeader;
  final String section;
  final int? rawPage;
  final int? displayPage;
  final String itemName;

  factory _BatchCrop.fromRow(Map<dynamic, dynamic> row) {
    final rawPage = int.tryParse('${row['raw_page'] ?? ''}');
    final page = int.tryParse('${row['display_page'] ?? ''}');
    return _BatchCrop(
      id: '${row['id'] ?? ''}'.trim(),
      problemNumber: '${row['problem_number'] ?? ''}'.trim(),
      isSetHeader: row['is_set_header'] == true,
      section: '${row['section'] ?? ''}'.trim(),
      rawPage: rawPage != null && rawPage > 0 ? rawPage : null,
      displayPage: page != null && page > 0 ? page : null,
      itemName: '${row['item_name'] ?? ''}'.trim(),
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

class _WonriMiddleCombinedHit {
  const _WonriMiddleCombinedHit({
    required this.item,
    required this.rawPage,
  });

  final TextbookVlmWonriMiddleSolutionItem item;
  final int rawPage;
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
