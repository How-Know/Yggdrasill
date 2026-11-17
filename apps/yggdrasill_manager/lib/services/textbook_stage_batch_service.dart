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

/// 정답·풀이가 정답 파일이 아니라 본문 지면의 "풀이" 단락에 인쇄된 문항인지.
///
/// 개념원리는 필수유형·특강 전체, 개념+유형은 쓱쓱 서술형 중 "예제", 개념+유형 고등은 필수예제다.
/// [category] 는 크롭의 section(개념서 카테고리)이다.
bool textbookConceptBodySolutionItem(String seriesKey, String category, String problemNumber) {
  switch (seriesKey.trim().toLowerCase()) {
    case 'gaeyu':
      return category == 'descriptive' && problemNumber.startsWith('예제');
    case 'gaeyu_high':
      return category == 'high_example';
    default:
      return category == 'type_example' || category == 'special_lecture';
  }
}

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
  static const int _layoutLongEdgePx = 2400;
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
    int? answerStartPage,
    int? answerEndPage,
    int? solutionStartPage,
    int? solutionEndPage,
    int? bodyPageFrom,
    int? bodyPageTo,
    void Function(String status)? onStatus,
  }) async {
    final usesBodySolutions = const {'wonri', 'gaeyu', 'gaeyu_high'}.contains(seriesKey.trim().toLowerCase());
    final crops = [
      for (final c in await _loadCrops(
        academyId: academyId,
        bookId: bookId,
        gradeLabel: gradeLabel,
        bigOrder: bigOrder,
        midOrder: midOrder,
        subKey: subKey,
        subIndex: subIndex,
        bodyPageFrom: bodyPageFrom,
        bodyPageTo: bodyPageTo,
      ))
        // 본문 "풀이" 단락이 딸린 문항은 runBodySolutionChainForSubunit 이 맡는다.
        if (!usesBodySolutions || !textbookConceptBodySolutionItem(seriesKey, c.section, c.problemNumber)) c,
    ];
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
                startPage: answerStartPage ?? solutionStartPage,
                endPage: answerEndPage ?? solutionEndPage,
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
                startPage: solutionStartPage,
                endPage: solutionEndPage,
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
        startPage: answerStartPage,
        endPage: answerEndPage,
        onStatus: onStatus,
      );
      final solResult = await _runSolutionRefs(
        doc: solutionDoc,
        academyId: academyId,
        bookId: bookId,
        gradeLabel: gradeLabel,
        crops: crops,
        seriesKey: seriesKey,
        startPage: solutionStartPage,
        endPage: solutionEndPage,
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

  /// 정답·풀이가 정답 파일이 아니라 본문 "풀이" 단락에 인쇄된 문항의 정답·풀이 위치를 본문 PDF 에서 찾아 저장한다.
  /// [onlyMissing] 이면 정답과 풀이 위치가 모두 있는 문항은 건너뛴다.
  Future<TextbookStageBatchResult> runBodySolutionChainForSubunit({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required int bigOrder,
    required int midOrder,
    required String subKey,
    required int subIndex,
    required String seriesKey,
    int? bodyPageFrom,
    int? bodyPageTo,
    bool onlyMissing = true,
    void Function(String status)? onStatus,
  }) async {
    const empty = TextbookStageBatchResult(
      answerSaved: 0,
      solutionRefSaved: 0,
      answerMissing: <String>[],
      solutionMissing: <String>[],
    );
    final crops = (await _loadCrops(
      academyId: academyId,
      bookId: bookId,
      gradeLabel: gradeLabel,
      bigOrder: bigOrder,
      midOrder: midOrder,
      subKey: subKey,
      subIndex: subIndex,
      bodyPageFrom: bodyPageFrom,
      bodyPageTo: bodyPageTo,
    ))
        .where((c) =>
            !c.isSetHeader &&
            c.rawPage != null &&
            textbookConceptBodySolutionItem(seriesKey, c.section, c.problemNumber))
        .toList(growable: false);
    if (crops.isEmpty) return empty;
    var targets = crops;
    if (onlyMissing) {
      final ids = [for (final c in crops) c.id];
      final answered = await _supa.from('textbook_problem_answers').select('crop_id').inFilter('crop_id', ids);
      final located = await _supa.from('textbook_problem_solution_refs').select('crop_id').inFilter('crop_id', ids);
      final hasAnswer = {for (final r in (answered as List).whereType<Map>()) '${r['crop_id']}'};
      final hasRef = {for (final r in (located as List).whereType<Map>()) '${r['crop_id']}'};
      targets = [for (final c in crops) if (!hasAnswer.contains(c.id) || !hasRef.contains(c.id)) c];
      if (targets.isEmpty) return empty;
    }

    onStatus?.call('본문 PDF 준비 중...');
    final doc = await _downloadPdf(
      academyId: academyId,
      bookId: bookId,
      gradeLabel: gradeLabel,
      kind: 'body',
      tempPrefix: 'batch_body_solution',
    );
    try {
      final byPage = <int, List<_BatchCrop>>{};
      for (final c in targets) {
        byPage.putIfAbsent(c.rawPage!, () => <_BatchCrop>[]).add(c);
      }
      final answers = <TextbookAnswerUpload>[];
      final refs = <TextbookSolutionRefUpload>[];
      final answerMissing = <String>[];
      final solutionMissing = <String>[];
      final pages = byPage.keys.toList()..sort();
      for (var index = 0; index < pages.length; index += 1) {
        final page = pages[index];
        final pageCrops = byPage[page]!;
        onStatus?.call('본문 정답·풀이 ${index + 1} / ${pages.length}페이지...');
        final idByKey = <String, _BatchCrop>{
          for (final c in pageCrops) textbookAnswerNumberKey(c.problemNumber): c,
        };
        final answeredKeys = <String>{};
        final locatedKeys = <String>{};
        // 일시적 VLM 실패(파싱·타임아웃)로 지면 전체가 빠지지 않게 한 번 더 시도한다.
        for (var attempt = 0; attempt < 2; attempt += 1) {
          try {
            final png = await renderPdfPageToPng(document: doc, pageNumber: page, longEdgePx: _vlmLongEdgePx);
            final result = await _solutionRefService.extractBodySolutionsOnPage(
              imageBytes: png,
              rawPage: page,
              expectedNumbers: [for (final c in pageCrops) c.problemNumber],
              seriesKey: seriesKey,
            );
            Uint8List? imagePage;
            for (final item in result.items) {
              final key = textbookAnswerNumberKey(item.problemNumber);
              final crop = idByKey[key];
              if (crop == null) continue;
              _ImageAnswerCrop? imageCrop;
              final imageRegion = item.answerRegion1k;
              if (item.answerKind == 'image' && imageRegion != null) {
                imagePage ??= await _renderAnswerImagePage(doc, page);
                imageCrop = _cropAnswerImage(imagePage ?? png, imageRegion);
              }
              var answerText = item.answerText.trim();
              var answerLatex = item.answerLatex2d.trim();
              // 증명처럼 풀이 상자는 있지만 굵은 최종 답이 없으면 해설지처럼 '풀이 참조'로 둔다.
              if (answerText.isEmpty && answerLatex.isEmpty && item.contentRegion1k != null) {
                answerText = '풀이 참조';
                answerLatex = '풀이 참조';
              }
              if (answerText.isNotEmpty || answerLatex.isNotEmpty || imageCrop != null) {
                answeredKeys.add(key);
                answers.add(TextbookAnswerUpload(
                  cropId: crop.id,
                  answerKind: imageCrop == null && item.answerKind == 'image' ? 'subjective' : item.answerKind,
                  answerText: answerText.isNotEmpty ? answerText : (imageCrop != null ? '[그림]' : answerLatex),
                  answerLatex2d: answerLatex.isEmpty ? null : answerLatex,
                  answerSource: 'vlm',
                  rawPage: page,
                  displayPage: crop.displayPage,
                  bbox1k: imageCrop == null ? null : imageRegion,
                  answerImagePngBytes: imageCrop?.pngBytes,
                  answerImageRegion1k: imageCrop == null ? null : imageRegion,
                  answerImageWidthPx: imageCrop?.width,
                  answerImageHeightPx: imageCrop?.height,
                ));
              }
              locatedKeys.add(key);
              refs.add(TextbookSolutionRefUpload(
                cropId: crop.id,
                rawPage: page,
                displayPage: crop.displayPage,
                numberRegion1k: item.numberRegion1k,
                contentRegion1k: item.contentRegion1k,
                sourceKind: 'body',
              ));
            }
            break;
          } catch (_) {
            if (attempt == 1) break;
          }
        }
        for (final c in pageCrops) {
          final key = textbookAnswerNumberKey(c.problemNumber);
          if (!answeredKeys.contains(key)) answerMissing.add(c.problemNumber);
          if (!locatedKeys.contains(key)) solutionMissing.add(c.problemNumber);
        }
      }
      final answerSaved =
          answers.isEmpty ? 0 : await _answerService.batchUpsertAnswers(academyId: academyId, answers: answers);
      final refSaved =
          refs.isEmpty ? 0 : await _solutionRefService.batchUpsertSolutionRefs(academyId: academyId, refs: refs);
      return TextbookStageBatchResult(
        answerSaved: answerSaved,
        solutionRefSaved: refSaved,
        answerMissing: answerMissing,
        solutionMissing: solutionMissing,
      );
    } finally {
      doc.dispose();
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
    int? bodyPageFrom,
    int? bodyPageTo,
  }) async {
    // 개념서는 익히기·확인 체크처럼 중단원 전체가 sub_index 0 을 함께 쓰는 슬롯이 있다.
    // 소단원 하나만 돌릴 때는 본문 쪽 범위로 그 소단원 문항만 남긴다.
    var query = _supa
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
        .eq('sub_index', subIndex);
    if (bodyPageFrom != null && bodyPageFrom > 0) query = query.gte('raw_page', bodyPageFrom);
    if (bodyPageTo != null && bodyPageTo > 0) query = query.lte('raw_page', bodyPageTo);
    final rows = await query.order('raw_page').order('problem_number');
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
    int? startPage,
    int? endPage,
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
    final requireExpectedIndex = textbookAnswerNeedsCorner(seriesKey);

    final hits = <int, _BatchAnswerHit>{};
    final answerImagePageCache = <int, Uint8List>{};
    final pageErrors = <String>[];
    final totalPages = doc.pages.length;
    final firstPage = (startPage != null && startPage > 0)
        ? startPage.clamp(1, totalPages)
        : 1;
    final initialLastPage = (endPage != null && endPage >= firstPage)
        ? endPage.clamp(firstPage, totalPages)
        : (startPage != null && startPage > 0
            ? (firstPage + 2).clamp(firstPage, totalPages)
            : totalPages);
    // 지정된 범위 안에서 다 못 찾았을 때만 바로 다음 1페이지까지 여유로 확인한다.
    final maxAllowedPage = (startPage != null && startPage > 0)
        ? (initialLastPage + 1).clamp(firstPage, totalPages)
        : totalPages;

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

    // 수력충전 빠른 정답은 소단원 블록마다 번호가 01부터 다시 시작하고 한 지면에
    // 블록 여럿이 실린다. 기대 번호를 물으면 모델이 다른 블록의 같은 번호를
    // 집으므로, 블록 머리와 번호·정답만 읽고 블록은 머리의 쪽 배지로 가린다.
    final byLayout = seriesKey.trim().toLowerCase() == 'suryeok';
    if (byLayout) {
      await _assignAnswersByLayout(
        doc: doc,
        targets: targets,
        hits: hits,
        firstPage: firstPage,
        lastPage: maxAllowedPage,
        pageErrors: pageErrors,
        answerImagePagePng: answerImagePagePng,
        onStatus: onStatus,
      );
    }
    for (var page = firstPage;
        !byLayout && page <= maxAllowedPage && hits.length < targets.length;
        page += 1) {
      if (page > initialLastPage && hits.length >= targets.length) break;
      final remainingPositions = <int>[
        for (var i = 0; i < targets.length; i += 1)
          if (!hits.containsKey(i)) i,
      ];
      if (remainingPositions.isEmpty) break;
      final pageBatch = TextbookExpectedAnswerBatch(
        positions: remainingPositions,
        entries: <TextbookExpectedAnswer>[
          for (final pos in remainingPositions) targets[pos].expected,
        ],
        requireExpectedIndex: requireExpectedIndex,
      );
      onStatus?.call(
        '정답 VLM $page / $initialLastPage 페이지 (남은 ${remainingPositions.length}문항)...',
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
      try {
        final result = await _answerService.extractAnswersOnPage(
          imageBytes: png,
          rawPage: page,
          academyId: academyId,
          bookId: bookId,
          gradeLabel: gradeLabel,
          expectedNumbers: pageBatch.numbers,
          expectedDetails: pageBatch.entries,
          seriesKey: seriesKey,
        );
        for (final item in result.items) {
          if (item.answerText.trim().isEmpty) continue;
          final matched = pageBatch.resolve(
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
        onStatus?.call('정답 VLM $page / $initialLastPage 페이지 실패: $e');
        continue;
      }
    }

    // 지면을 하나도 못 읽었을 때만 멈춘다. 읽었는데 못 찾은 문항은 "정답 없음"으로
    // 남기고 해설·AI 풀이·검수를 이어 간다(해설 정답으로 되살릴 수 있다).
    if (hits.isEmpty && pageErrors.isNotEmpty) {
      throw Exception('정답 VLM 추출 실패: ${pageErrors.take(3).join(' / ')}');
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
      Uint8List? answerImagePage;
      for (final crop in pageCrops) {
        final item =
            items[textbookWonriMiddlePrintedNumberKey(crop.problemNumber)];
        if (item == null) continue;
        final role = textbookWonriMiddleItemRole(
          section: crop.section,
          problemNumber: crop.problemNumber,
          itemName: crop.itemName,
        );
        _ImageAnswerCrop? imageCrop;
        final imageRegion = item.answerRegion1k;
        if (item.answerKind == 'image' && imageRegion != null) {
          answerImagePage ??= await _renderAnswerImagePage(doc, page);
          imageCrop = _cropAnswerImage(answerImagePage ?? png, imageRegion);
        }
        final resolvedAnswerText = item.answerText.trim().isNotEmpty
            ? item.answerText.trim()
            : (item.contentRegion1k != null ? '풀이 참조' : '');
        final resolvedAnswerLatex = item.answerLatex2d.trim().isNotEmpty
            ? item.answerLatex2d.trim()
            : resolvedAnswerText;
        if (resolvedAnswerText.isNotEmpty) {
          answerUploads.add(TextbookAnswerUpload(
            cropId: crop.id,
            answerKind: imageCrop == null && item.answerKind == 'image'
                ? 'subjective'
                : item.answerKind,
            answerText: resolvedAnswerText,
            answerLatex2d: resolvedAnswerLatex,
            answerSource: 'vlm',
            rawPage: page,
            displayPage: crop.displayPage,
            bbox1k: imageCrop == null ? null : imageRegion,
            answerImagePngBytes: imageCrop?.pngBytes,
            answerImageRegion1k: imageCrop == null ? null : imageRegion,
            answerImageWidthPx: imageCrop?.width,
            answerImageHeightPx: imageCrop?.height,
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
    int? startPage,
    int? endPage,
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
    final firstPage = (startPage != null && startPage > 0)
        ? startPage.clamp(1, totalPages)
        : 1;
    final initialLastPage = (endPage != null && endPage >= firstPage)
        ? endPage.clamp(firstPage, totalPages)
        : (startPage != null && startPage > 0
            ? (firstPage + 3).clamp(firstPage, totalPages)
            : totalPages);
    final maxAllowedPage = (startPage != null && startPage > 0)
        ? (initialLastPage + 1).clamp(firstPage, totalPages)
        : totalPages;
    for (var page = firstPage;
        page <= maxAllowedPage && pending.isNotEmpty;
        page += 1) {
      onStatus?.call(
        '중등 개념원리 ${answers ? '빠른 정답' : '상세 해설'} VLM '
        '$page / $initialLastPage 페이지... '
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
        bodyPageOf: (position) => targets[position].displayPage,
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
    final answerImagePages = <int, Uint8List?>{};
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
        _ImageAnswerCrop? imageCrop;
        final imageRegion = item.answerRegion1k;
        if (item.answerKind == 'image' && imageRegion != null) {
          final pagePng = answerImagePages.containsKey(hit.rawPage)
              ? answerImagePages[hit.rawPage]
              : (answerImagePages[hit.rawPage] =
                  await _renderAnswerImagePage(doc, hit.rawPage));
          if (pagePng != null) imageCrop = _cropAnswerImage(pagePng, imageRegion);
        }
        answerUploads.add(TextbookAnswerUpload(
          cropId: target.id,
          answerKind: imageCrop == null && item.answerKind == 'image'
              ? 'subjective'
              : item.answerKind,
          answerText: item.answerText,
          answerLatex2d:
              item.answerLatex2d.isEmpty ? item.answerText : item.answerLatex2d,
          answerSource: 'vlm',
          rawPage: hit.rawPage,
          displayPage: hit.rawPage,
          bbox1k: item.answerRegion1k ?? item.numberRegion1k,
          answerImagePngBytes: imageCrop?.pngBytes,
          answerImageRegion1k: imageCrop == null ? null : imageRegion,
          answerImageWidthPx: imageCrop?.width,
          answerImageHeightPx: imageCrop?.height,
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

  Future<Uint8List?> _renderAnswerImagePage(PdfDocument doc, int page) async {
    try {
      return await renderPdfPageToPng(
        document: doc,
        pageNumber: page,
        longEdgePx: _answerImageLongEdgePx,
      );
    } catch (_) {
      return null;
    }
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
    int? startPage,
    int? endPage,
    void Function(String status)? onStatus,
  }) async {
    final solCrops = crops.where((crop) => !crop.isSetHeader).toList();
    // 정답 단계와 같은 이유로 순서 배열을 쓴다.
    final targets = <_BatchTarget>[
      for (final c in solCrops)
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
    final requireExpectedIndex = textbookAnswerNeedsCorner(seriesKey);
    final hits = <int, _SolutionRefWithPage>{};
    final totalPages = doc.pages.length;
    final firstPage = (startPage != null && startPage > 0)
        ? startPage.clamp(1, totalPages)
        : 1;
    final initialLastPage = (endPage != null && endPage >= firstPage)
        ? endPage.clamp(firstPage, totalPages)
        : (startPage != null && startPage > 0
            ? (firstPage + 3).clamp(firstPage, totalPages)
            : totalPages);
    final maxAllowedPage = (startPage != null && startPage > 0)
        ? (initialLastPage + 1).clamp(firstPage, totalPages)
        : totalPages;
    // 정답과 같은 이유로 수력충전 해설은 소단원 머리 아래의 번호만 그 소단원으로 받는다.
    final byLayout = seriesKey.trim().toLowerCase() == 'suryeok';
    if (byLayout) {
      await _assignSolutionRefsByLayout(
        doc: doc,
        targets: targets,
        hits: hits,
        firstPage: firstPage,
        lastPage: maxAllowedPage,
        onStatus: onStatus,
      );
    }
    for (var page = firstPage;
        !byLayout && page <= maxAllowedPage && hits.length < targets.length;
        page += 1) {
      final remainingPositions = <int>[
        for (var i = 0; i < targets.length; i += 1)
          if (!hits.containsKey(i)) i,
      ];
      if (remainingPositions.isEmpty) break;
      final pageBatch = TextbookExpectedAnswerBatch(
        positions: remainingPositions,
        entries: <TextbookExpectedAnswer>[
          for (final pos in remainingPositions) targets[pos].expected,
        ],
        requireExpectedIndex: requireExpectedIndex,
      );
      onStatus?.call(
        '해설 VLM $page / $initialLastPage 페이지 (남은 ${remainingPositions.length}문항)...',
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
      try {
        final result = await _solutionRefService.detectOnPage(
          imageBytes: png,
          rawPage: page,
          academyId: academyId,
          bookId: bookId,
          gradeLabel: gradeLabel,
          expectedNumbers: pageBatch.numbers,
          expectedDetails: pageBatch.entries,
          seriesKey: seriesKey,
        );
        String itemSection(TextbookVlmSolutionRefItem item) {
          final index = item.expectedIndex;
          if (index >= 0 && index < remainingPositions.length) {
            return targets[remainingPositions[index]].crop.section;
          }
          return RegExp(r'^(예제|유제|연습)').hasMatch(item.problemNumber)
              ? 'descriptive'
              : '';
        }

        final sections = <String>{
          for (final pos in remainingPositions) targets[pos].crop.section
        };
        final reported = <(String, String)>[
          for (final item in result.items)
            (item.problemNumber.trim(), itemSection(item)),
        ];
        final sectionsToVerify = <String>{};
        if (seriesKey == 'gaeyu' && sections.length > 1) {
          for (final position in remainingPositions) {
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
          final matched = pageBatch.resolve(
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
            requireExpectedIndex: requireExpectedIndex,
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

  /// 수력충전 빠른 정답을 지면 구조(소단원 머리 → 번호·정답)로 읽어 붙인다.
  /// 모델은 글자만 읽고, 어느 소단원 블록인지는 머리의 쪽 배지로 우리가 정한다.
  Future<void> _assignAnswersByLayout({
    required PdfDocument doc,
    required List<_BatchTarget> targets,
    required Map<int, _BatchAnswerHit> hits,
    required int firstPage,
    required int lastPage,
    required List<String> pageErrors,
    required Future<Uint8List?> Function(int page) answerImagePagePng,
    void Function(String status)? onStatus,
  }) async {
    final blocks = TextbookLayoutBlocks.of([for (final t in targets) t.expected]);
    final pending = <int>{
      for (var i = 0; i < targets.length; i += 1)
        if (!hits.containsKey(i)) i,
    };

    Future<TextbookVlmAnswerLayoutPage?> read(int page, {bool record = true}) async {
      try {
        final png = await renderPdfPageToPng(
          document: doc,
          pageNumber: page,
          longEdgePx: _layoutLongEdgePx,
        );
        return await _answerService.extractAnswerLayoutOnPage(imageBytes: png, rawPage: page);
      } catch (e) {
        if (record) pageErrors.add('p$page: $e');
        return null;
      }
    }

    Future<int> apply(int page, TextbookVlmAnswerLayoutPage layout, int current) async {
      for (final entry in textbookAnswerLayoutReadingOrder(layout.entries)) {
        if (entry.isHeader) {
          current = blocks.blockForHeader(entry.title, entry.pageStart, entry.pageEnd);
          continue;
        }
        final answer = entry.answer;
        if (answer == null || current < 0) continue;
        if (answer.answerText.trim().isEmpty && !answer.isImage) continue;
        final positions = blocks.positionsFor(current, answer.problemNumber, pending);
        if (positions.isEmpty) continue;
        _ImageAnswerCrop? imageCrop;
        if (answer.isImage && answer.bbox != null) {
          final pagePng = await answerImagePagePng(page);
          if (pagePng != null) imageCrop = _cropAnswerImage(pagePng, answer.bbox!);
        }
        for (final position in positions) {
          pending.remove(position);
          hits[position] = _BatchAnswerHit(
            item: TextbookVlmAnswerItem(
              problemNumber: targets[position].expected.number,
              kind: answer.kind,
              answerText: answer.answerText,
              answerLatex2d: answer.answerLatex2d,
              answerAssets: answer.answerAssets,
              bbox: answer.bbox,
            ),
            rawPage: page,
            displayPage: page,
            imageCrop: imageCrop,
          );
        }
      }
      return current;
    }

    var current = -1;
    for (var page = firstPage; page <= lastPage && pending.isNotEmpty; page += 1) {
      onStatus?.call('정답 지면 구조 읽기 $page / $lastPage 페이지 (남은 ${pending.length}문항)...');
      final layout = await read(page);
      if (layout == null) {
        current = -1;
        continue;
      }
      if (!layout.leadingContinuation) {
        current = -1;
      } else if (page == firstPage && page > 1) {
        // 범위 첫 지면이 앞 지면에서 이어지면 그 블록 머리는 앞 지면에 있다.
        final prev = await read(page - 1, record: false);
        if (prev != null) current = await apply(page - 1, prev, -1);
      }
      current = await apply(page, layout, current);
    }
  }

  /// 수력충전 해설 좌표를 지면 구조(소단원 머리 → 번호)로 붙인다.
  /// 위 블록의 같은 번호(예: 종이접기 04번)를 아래 블록 문항에 붙이지 않는다.
  Future<void> _assignSolutionRefsByLayout({
    required PdfDocument doc,
    required List<_BatchTarget> targets,
    required Map<int, _SolutionRefWithPage> hits,
    required int firstPage,
    required int lastPage,
    void Function(String status)? onStatus,
  }) async {
    final blocks = TextbookLayoutBlocks.of([for (final t in targets) t.expected]);
    final pending = <int>{
      for (var i = 0; i < targets.length; i += 1)
        if (!hits.containsKey(i)) i,
    };

    Future<({int current, int skipped, bool leading})?> readPage(int page, int enterBlock) async {
      final TextbookVlmSolutionBlockPage res;
      try {
        final png = await renderPdfPageToPng(
          document: doc,
          pageNumber: page,
          longEdgePx: _layoutLongEdgePx,
        );
        res = await _solutionRefService.detectBlocksOnPage(imageBytes: png, rawPage: page);
      } catch (e) {
        onStatus?.call('해설 p$page 지면 읽기 실패: $e');
        return null;
      }
      var current = res.leadingContinuation ? enterBlock : -1;
      var skipped = 0;
      for (final entry in res.sequence) {
        if (entry.isHeader) {
          current = blocks.blockForHeader(entry.title, entry.pageStart, entry.pageEnd);
          onStatus?.call('해설 p$page 머리 "${entry.title}" p.${entry.pageStart}~${entry.pageEnd} → '
              '${current < 0 ? '이번 범위 아님' : '이번 소단원'}');
          continue;
        }
        final region = entry.numberRegion1k;
        if (current < 0 || region == null) {
          skipped += 1;
          continue;
        }
        final positions = blocks.positionsFor(current, entry.text, pending);
        if (positions.isEmpty) {
          skipped += 1;
          continue;
        }
        for (final position in positions) {
          pending.remove(position);
          hits[position] = _SolutionRefWithPage(
            item: TextbookVlmSolutionRefItem(
              problemNumber: targets[position].expected.number,
              numberRegion1k: region,
              contentRegion1k: entry.contentRegion1k,
            ),
            rawPage: page,
            displayPage: page,
          );
        }
      }
      return (current: current, skipped: skipped, leading: res.leadingContinuation);
    }

    final enterBlock = <int, int>{};
    final shakyPages = <int>[];
    var current = -1;
    for (var page = firstPage; page <= lastPage && pending.isNotEmpty; page += 1) {
      onStatus?.call('해설 지면 구조 읽기 $page / $lastPage 페이지 (남은 ${pending.length}문항)...');
      enterBlock[page] = current;
      var read = await readPage(page, current);
      if (read == null) {
        current = -1;
        continue;
      }
      if (read.leading && current < 0 && page == firstPage && page > 1 && pending.isNotEmpty) {
        // 범위 첫 지면이 앞 지면에서 이어지면 앞 지면에서 블록을 정한 뒤 다시 읽는다.
        final prev = await readPage(page - 1, -1);
        if (prev != null && prev.current >= 0) {
          enterBlock[page] = prev.current;
          read = await readPage(page, prev.current) ?? read;
        }
      }
      current = read.current;
      if (read.skipped > 0) shakyPages.add(page);
    }
    // 모델은 같은 지면도 회차마다 다르게 읽는다. 빈칸이 남았으면 튕긴 지면만
    // 그때 읽던 블록에서 한 번 더 읽는다.
    for (final page in shakyPages) {
      if (pending.isEmpty) return;
      onStatus?.call('해설 p$page 다시 읽기 (남은 ${pending.length}문항)...');
      await readPage(page, enterBlock[page] ?? -1);
    }
  }
}

/// 답지·해설 지면을 블록 구조로 읽을 때 쓰는 기대 문항 표.
///
/// 블록은 번호가 01부터 다시 시작하는 묶음(소단원 하나 또는 단원 마무리 평가)이다.
/// 본문 쪽 순서로 세워 코너가 바뀌거나 번호가 되돌아가는 곳에서 끊는다.
class TextbookLayoutBlocks {
  TextbookLayoutBlocks._(this.lowPage, this.highPage, this.cornerOf, this.byNumber);

  factory TextbookLayoutBlocks.of(List<TextbookExpectedAnswer> expected) {
    int valueOf(int i) => int.tryParse(expected[i].number.replaceAll(RegExp(r'\D'), '')) ?? 0;
    // 입력 순서에 기대지 않는다. 크롭 목록은 번호 내림차순으로 오기도 해서, 그대로
    // 세우면 번호마다 "되돌아감"으로 끊겨 블록이 문항 수만큼 생긴다.
    final order = <int>[for (var i = 0; i < expected.length; i += 1) i]
      ..sort((a, b) {
        final byPage = (expected[a].bodyPage ?? 0).compareTo(expected[b].bodyPage ?? 0);
        if (byPage != 0) return byPage;
        final byCorner = expected[a].corner.trim().compareTo(expected[b].corner.trim());
        if (byCorner != 0) return byCorner;
        final byValue = valueOf(a).compareTo(valueOf(b));
        return byValue != 0 ? byValue : a.compareTo(b);
      });
    final lowPage = <int, int>{};
    final highPage = <int, int>{};
    final cornerOf = <int, String>{};
    final byNumber = <int, Map<String, int>>{};
    var block = -1;
    var lastCorner = '\u0000';
    var lastValue = 0;
    for (final position in order) {
      final e = expected[position];
      final corner = e.corner.trim();
      final value = int.tryParse(e.number.replaceAll(RegExp(r'\D'), '')) ?? 0;
      if (block < 0 || corner != lastCorner || value <= lastValue) block += 1;
      lastCorner = corner;
      lastValue = value;
      cornerOf.putIfAbsent(block, () => corner);
      final page = e.bodyPage ?? 0;
      if (page > 0) {
        lowPage[block] = (lowPage[block] ?? page) < page ? lowPage[block]! : page;
        highPage[block] = (highPage[block] ?? page) > page ? highPage[block]! : page;
      }
      (byNumber[block] ??= <String, int>{}).putIfAbsent(textbookAnswerNumberKey(e.number), () => position);
    }
    return TextbookLayoutBlocks._(lowPage, highPage, cornerOf, byNumber);
  }

  final Map<int, int> lowPage;
  final Map<int, int> highPage;
  final Map<int, String> cornerOf;
  final Map<int, Map<String, int>> byNumber;

  /// 머리("16 평행선의 성질 ▸p.41~43")가 가리키는 블록. 이번 범위 밖이면 -1.
  int blockForHeader(String title, int pageStart, int pageEnd) => textbookStageBlockForHeader(
        title: title,
        pageStart: pageStart,
        pageEnd: pageEnd,
        lowPage: lowPage,
        highPage: highPage,
        cornerOf: cornerOf,
      );

  /// 블록 안에서 인쇄된 번호가 채울 기대 문항 위치들. "05~09" 처럼 묶인 번호는
  /// 범위에 드는 문항 모두를 돌려준다. 이미 채운 문항은 빼고 준다.
  List<int> positionsFor(int block, String printedNumber, Set<int> pending) {
    final table = byNumber[block];
    if (table == null || table.isEmpty) return const <int>[];
    final single = table[textbookAnswerNumberKey(printedNumber)];
    if (single != null) return pending.contains(single) ? <int>[single] : const <int>[];
    final range = textbookAnswerNumberRange(printedNumber);
    if (range == null) return const <int>[];
    return <int>[
      for (var n = range.$1; n <= range.$2; n += 1)
        if (table['$n'] != null && pending.contains(table['$n'])) table['$n']!,
    ];
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
