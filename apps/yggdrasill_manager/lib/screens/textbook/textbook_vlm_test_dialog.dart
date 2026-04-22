import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../services/textbook_pdf_page_renderer.dart';
import '../../services/textbook_pdf_service.dart';
import '../../services/textbook_problem_crop.dart';
import '../../services/textbook_vlm_test_service.dart';

/// Test harness dialog: renders a textbook PDF side-by-side with the VLM's
/// problem-number detection output.
///
/// Invocation surface is the "VLM 테스트" button on each `_MigLink` row of
/// the migration pane. The dialog:
///   1. Resolves a download URL via `/textbook/pdf/download-url`.
///   2. Streams the PDF into a temp file so `PdfViewer.file` can scroll it
///      smoothly (uri-based loading chokes on 250MB Supabase signed URLs).
///   3. Loads a second `PdfDocument` reference (via onViewerReady) so we can
///      rasterize arbitrary pages to PNG for VLM calls.
///   4. On demand, sends the current page's PNG to the gateway and keeps
///      the normalized bbox result keyed by page number so we can overlay
///      red boxes on top of the viewer.
///
/// This is intentionally decoupled from the rest of the migration pane —
/// closing the dialog frees everything and the migration flow is unaffected.
class TextbookVlmTestDialog extends StatefulWidget {
  const TextbookVlmTestDialog({
    super.key,
    this.linkId,
    required this.academyId,
    required this.bookId,
    required this.bookName,
    required this.gradeLabel,
    required this.kind,
  });

  final int? linkId;
  final String academyId;
  final String bookId;
  final String bookName;
  final String gradeLabel;

  /// 'body' | 'sol' | 'ans' — only 'body' is useful for problem-number
  /// detection but we don't hard-block the other kinds so the tester can
  /// probe ans/sol pages if they want.
  final String kind;

  static Future<void> show(
    BuildContext context, {
    int? linkId,
    required String academyId,
    required String bookId,
    required String bookName,
    required String gradeLabel,
    required String kind,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      useSafeArea: true,
      builder: (ctx) => TextbookVlmTestDialog(
        linkId: linkId,
        academyId: academyId,
        bookId: bookId,
        bookName: bookName,
        gradeLabel: gradeLabel,
        kind: kind,
      ),
    );
  }

  @override
  State<TextbookVlmTestDialog> createState() => _TextbookVlmTestDialogState();
}

class _TextbookVlmTestDialogState extends State<TextbookVlmTestDialog> {
  static const _kBg = Color(0xFF15171C);
  static const _kCard = Color(0xFF1F1F1F);
  static const _kBorder = Color(0xFF2A2A2A);
  static const _kText = Colors.white;
  static const _kTextSub = Color(0xFFB3B3B3);
  static const _kAccent = Color(0xFF33A373);
  static const _kDanger = Color(0xFFE68A8A);

  final _pdfService = TextbookPdfService();
  final _vlmService = TextbookVlmTestService();
  final _controller = PdfViewerController();

  bool _loadingPdf = true;
  String? _loadError;
  String? _localPath;
  PdfDocument? _document;
  int _pageCount = 0;
  int _pageNumber = 1;

  bool _analyzing = false;
  String? _analyzeError;
  final Map<int, _PageVlmResult> _resultsByPage = {};

  /// Index of the problem item the user clicked in the side panel list for
  /// the *current* page. When set, the viewer dims all items except the
  /// focused one (crop mode) and the sidebar shows a cropped preview.
  int? _focusedItemIndex;

  /// Cache of cropped PNG bytes keyed by "<pageNumber>:<itemIndex>".
  /// Populated lazily when the user focuses an item.
  final Map<String, Uint8List> _cropCache = {};

  // ──────────────────────────── Range (unit-wide) analysis state ───────────
  //
  // We let the user specify a start..end PDF-page range and fire one VLM call
  // per page sequentially. The map `_resultsByPage` is the single source of
  // truth, so range analysis simply populates it page by page and the existing
  // viewer/side panel continue to render whichever page is currently shown.
  bool _rangeRunning = false;
  bool _rangeCancel = false;
  int _rangeStart = 0;
  int _rangeEnd = 0;
  int _rangeCursor = 0;
  int _rangeDone = 0;
  int _rangeFailed = 0;
  String? _rangeLastError;

  /// Pages that failed (even after retry) in the most recent run. Kept so the
  /// user can hit "실패 페이지 재분석" to retry only these. Persists across runs
  /// until cleared explicitly or the next fresh range run starts.
  final Set<int> _rangeFailedPages = <int>{};
  final TextEditingController _rangeStartCtl = TextEditingController();
  final TextEditingController _rangeEndCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _downloadPdf();
  }

  @override
  void dispose() {
    _rangeStartCtl.dispose();
    _rangeEndCtl.dispose();
    _document?.dispose();
    super.dispose();
  }

  Future<void> _downloadPdf() async {
    setState(() {
      _loadingPdf = true;
      _loadError = null;
    });
    try {
      final target = await _pdfService.requestDownloadUrl(
        linkId: widget.linkId,
        academyId: widget.academyId,
        fileId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        kind: widget.kind,
      );
      final downloadUrl = target.url;
      if (downloadUrl.isEmpty) {
        throw Exception('empty_download_url');
      }

      final tempDir = await getTemporaryDirectory();
      final safeBook = widget.bookId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final file = File(p.join(
        tempDir.path,
        'vlm_test_${safeBook}_${widget.gradeLabel}_${widget.kind}.pdf',
      ));
      final res = await http.get(Uri.parse(downloadUrl));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('pdf_download_failed(${res.statusCode})');
      }
      await file.writeAsBytes(res.bodyBytes, flush: true);

      if (!mounted) return;
      setState(() {
        _localPath = file.path;
        _loadingPdf = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingPdf = false;
        _loadError = '$e';
      });
    }
  }

  Future<void> _analyzeCurrentPage() async {
    final pageNo = _pageNumber;
    setState(() {
      _analyzing = true;
      _analyzeError = null;
    });
    try {
      await _analyzeSinglePageWithRetry(pageNo, retries: 1);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _analyzeError = '$e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _analyzing = false;
        });
      }
    }
  }

  /// Core helper shared by both "analyze current page" and "analyze unit".
  /// Renders the page, calls the VLM, and stores the result in
  /// `_resultsByPage`. Never sets `_analyzing` or `_analyzeError` so the
  /// caller controls those flags.
  Future<void> _analyzeSinglePage(int pageNo) async {
    final doc = _document;
    if (doc == null || pageNo < 1 || pageNo > doc.pages.length) {
      throw StateError('invalid_page_or_document_not_ready');
    }
    final pngBytes = await renderPdfPageToPng(
      document: doc,
      pageNumber: pageNo,
      longEdgePx: 1500,
    );
    final result = await _vlmService.detectProblemsOnPage(
      imageBytes: pngBytes,
      rawPage: pageNo,
      academyId: widget.academyId,
      bookId: widget.bookId,
      gradeLabel: widget.gradeLabel,
    );
    if (!mounted) return;
    setState(() {
      _resultsByPage[pageNo] = _PageVlmResult(
        rawPage: result.rawPage,
        displayPage: result.displayPage,
        pageOffset: result.pageOffset,
        pageOffsetFound: result.pageOffsetFound,
        section: result.section,
        layout: result.layout,
        items: result.items,
        notes: result.notes,
        model: result.model,
        elapsedMs: result.elapsedMs,
        renderedPng: pngBytes,
      );
      // If the user is currently viewing this page, reset focus so the
      // freshly analysed result isn't in a stale-focus state.
      if (_pageNumber == pageNo) {
        _focusedItemIndex = null;
      }
      // Drop any cached crops tied to this page since the underlying result
      // changed.
      _cropCache.removeWhere((k, _) => k.startsWith('$pageNo:'));
    });
  }

  // ───────────────────────────── Range analysis ─────────────────────────────

  /// Transient errors we'll auto-retry (don't scare the user with these).
  /// This mostly covers the `http.Client` ↔ Node gateway keep-alive race where
  /// a pooled socket was closed on the server side while we tried to reuse it.
  bool _isRetriableError(Object err) {
    final s = '$err'.toLowerCase();
    return s.contains('connection closed before full header') ||
        s.contains('connection reset') ||
        s.contains('softwarecausedconnectionabort') ||
        s.contains('httpexception') ||
        s.contains('socketexception') ||
        s.contains('os error: connection') ||
        s.contains('timeoutexception');
  }

  /// Analyze a single page with automatic retry on transient HTTP errors.
  /// The exponential-ish backoff keeps the loop gentle on the VLM endpoint.
  Future<void> _analyzeSinglePageWithRetry(
    int pageNo, {
    int retries = 1,
  }) async {
    var attempt = 0;
    while (true) {
      try {
        await _analyzeSinglePage(pageNo);
        return;
      } catch (err) {
        attempt += 1;
        if (attempt > retries || !_isRetriableError(err)) rethrow;
        if (_rangeCancel) rethrow;
        final waitMs = 500 * attempt;
        debugPrint('[vlm-test] retriable error on page $pageNo '
            '(attempt $attempt, wait ${waitMs}ms): $err');
        await Future<void>.delayed(Duration(milliseconds: waitMs));
      }
    }
  }

  Future<void> _startRangeAnalysis(int startPage, int endPage) async {
    final doc = _document;
    if (doc == null) return;
    final maxPage = doc.pages.length;
    final s = startPage.clamp(1, maxPage);
    final e = endPage.clamp(s, maxPage);
    if (_rangeRunning) return;

    setState(() {
      _rangeRunning = true;
      _rangeCancel = false;
      _rangeStart = s;
      _rangeEnd = e;
      _rangeCursor = s;
      _rangeDone = 0;
      _rangeFailed = 0;
      _rangeFailedPages.clear();
      _rangeLastError = null;
      _analyzeError = null;
    });

    try {
      for (var p = s; p <= e; p += 1) {
        if (_rangeCancel) break;
        if (!mounted) return;
        setState(() {
          _rangeCursor = p;
        });
        try {
          await _analyzeSinglePageWithRetry(p, retries: 1);
          if (mounted) {
            setState(() => _rangeDone += 1);
          }
        } catch (err) {
          if (mounted) {
            setState(() {
              _rangeFailed += 1;
              _rangeFailedPages.add(p);
              _rangeLastError = '페이지 $p: $err';
            });
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _rangeRunning = false;
        });
      }
    }
  }

  /// Retry only the pages that are still sitting in [_rangeFailedPages].
  /// Triggered by the "실패 페이지 재분석" button on the progress strip.
  Future<void> _retryFailedPages() async {
    if (_rangeRunning) return;
    final failed = _rangeFailedPages.toList()..sort();
    if (failed.isEmpty) return;

    setState(() {
      _rangeRunning = true;
      _rangeCancel = false;
      _rangeStart = failed.first;
      _rangeEnd = failed.last;
      _rangeCursor = failed.first;
      _rangeDone = 0;
      _rangeFailed = 0;
      _rangeLastError = null;
      _analyzeError = null;
    });

    try {
      for (final p in failed) {
        if (_rangeCancel) break;
        if (!mounted) return;
        setState(() => _rangeCursor = p);
        try {
          // Give the straggler a bit more patience on retries (2 total).
          await _analyzeSinglePageWithRetry(p, retries: 2);
          if (mounted) {
            setState(() {
              _rangeDone += 1;
              _rangeFailedPages.remove(p);
            });
          }
        } catch (err) {
          if (mounted) {
            setState(() {
              _rangeFailed += 1;
              _rangeLastError = '페이지 $p: $err';
            });
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _rangeRunning = false;
        });
      }
    }
  }

  void _cancelRangeAnalysis() {
    if (!_rangeRunning) return;
    setState(() {
      _rangeCancel = true;
    });
  }

  Future<void> _promptAndStartRange() async {
    if (_document == null) return;
    final maxPage = _pageCount;
    if (_rangeStartCtl.text.isEmpty) {
      _rangeStartCtl.text = '$_pageNumber';
    }
    if (_rangeEndCtl.text.isEmpty) {
      final suggested = (_pageNumber + 19).clamp(1, maxPage);
      _rangeEndCtl.text = '$suggested';
    }

    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kCard,
        title: const Text(
          '단원 분석 범위',
          style: TextStyle(
            color: _kText,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '이 PDF 의 시작 페이지와 끝 페이지를 입력하세요.\n'
              '전체 PDF 페이지 수: $maxPage',
              style: const TextStyle(color: _kTextSub, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _rangeStartCtl,
                    style: const TextStyle(color: _kText, fontSize: 13),
                    decoration: const InputDecoration(
                      labelText: '시작 페이지',
                      labelStyle: TextStyle(color: _kTextSub),
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _rangeEndCtl,
                    style: const TextStyle(color: _kText, fontSize: 13),
                    decoration: const InputDecoration(
                      labelText: '끝 페이지',
                      labelStyle: TextStyle(color: _kTextSub),
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '순차 호출이므로 20페이지 기준 대략 30초~수 분 걸릴 수 있습니다. '
              '중간에 취소 가능.',
              style: TextStyle(color: _kTextSub, fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: _kAccent),
            child: const Text('분석 시작'),
          ),
        ],
      ),
    );
    if (accepted != true) return;

    final s = int.tryParse(_rangeStartCtl.text.trim());
    final e = int.tryParse(_rangeEndCtl.text.trim());
    if (s == null || e == null) return;
    await _startRangeAnalysis(s, e);
  }

  Future<void> _goPrev() async {
    if (_pageNumber <= 1) return;
    await _controller.goToPage(
      pageNumber: _pageNumber - 1,
      duration: const Duration(milliseconds: 120),
    );
  }

  Future<void> _goNext() async {
    if (_pageNumber >= _pageCount) return;
    await _controller.goToPage(
      pageNumber: _pageNumber + 1,
      duration: const Duration(milliseconds: 120),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context).size;
    final dialogW = media.width * 0.92;
    final dialogH = media.height * 0.92;

    return Dialog(
      backgroundColor: _kBg,
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: dialogW,
        height: dialogH,
        child: Column(
          children: [
            _buildHeader(),
            const Divider(height: 1, color: _kBorder),
            Expanded(
              child: Row(
                children: [
                  Expanded(flex: 3, child: _buildViewerPane()),
                  Container(width: 1, color: _kBorder),
                  SizedBox(width: 420, child: _buildSidePane()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.visibility_outlined, color: _kAccent, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'VLM 문항번호 탐지 테스트 · ${widget.bookName}  ·  ${widget.gradeLabel}/${widget.kind}',
              style: const TextStyle(
                color: _kText,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close, color: _kTextSub),
            tooltip: '닫기',
          ),
        ],
      ),
    );
  }

  Widget _buildViewerPane() {
    if (_loadingPdf) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: _kAccent),
            SizedBox(height: 10),
            Text(
              'PDF 다운로드 중...',
              style: TextStyle(color: _kTextSub, fontSize: 12),
            ),
          ],
        ),
      );
    }
    if (_loadError != null || _localPath == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'PDF를 불러오지 못했습니다.\n\n${_loadError ?? ''}',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _kDanger,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }
    return Container(
      color: _kCard,
      child: Column(
        children: [
          Expanded(
            child: PdfViewer.file(
              _localPath!,
              controller: _controller,
              params: PdfViewerParams(
                backgroundColor: _kCard,
                margin: 8,
                pageAnchor: PdfPageAnchor.center,
                onViewerReady: (document, controller) {
                  if (!mounted) return;
                  setState(() {
                    _document = document;
                    _pageCount = document.pages.length;
                  });
                },
                onPageChanged: (page) {
                  if (!mounted || page == null) return;
                  setState(() {
                    _pageNumber = page;
                    _focusedItemIndex = null;
                  });
                },
                pageOverlaysBuilder: (context, pageRect, page) {
                  final result = _resultsByPage[page.pageNumber];
                  if (result == null || result.items.isEmpty) {
                    return const [];
                  }
                  final focusForThisPage =
                      page.pageNumber == _pageNumber ? _focusedItemIndex : null;
                  return _buildBboxOverlays(
                    result,
                    pageRect.size,
                    focusedIndex: focusForThisPage,
                  );
                },
              ),
            ),
          ),
          _buildPageNavBar(),
        ],
      ),
    );
  }

  List<Widget> _buildBboxOverlays(
    _PageVlmResult result,
    Size pageSize, {
    int? focusedIndex,
  }) {
    final out = <Widget>[];

    // When a specific item is focused, darken everything else with a mask
    // that has a rectangular hole cut over the focused region.
    if (focusedIndex != null &&
        focusedIndex >= 0 &&
        focusedIndex < result.items.length) {
      final focused = result.items[focusedIndex];
      final hole = focused.itemRegion ?? focused.bbox;
      if (hole != null && hole.length == 4) {
        out.add(Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _FocusMaskPainter(
                holeBbox: hole,
              ),
            ),
          ),
        ));
      }
    }

    // First pass: item_region rectangles (full problem area, translucent fill).
    for (var i = 0; i < result.items.length; i += 1) {
      final item = result.items[i];
      final region = item.itemRegion;
      if (region == null || region.length != 4) continue;
      final rect = _normalizedBboxToRect(region, pageSize);
      if (rect == null) continue;
      final isFocused = focusedIndex == i;
      final isDimmed = focusedIndex != null && !isFocused;
      final regionColor = item.isSetHeader
          ? const Color(0xFFFFB44A)
          : const Color(0xFF5AA6FF);
      out.add(Positioned(
        left: rect.left,
        top: rect.top,
        width: rect.width,
        height: rect.height,
        child: IgnorePointer(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: isDimmed
                    ? regionColor.withValues(alpha: 0.25)
                    : regionColor.withValues(
                        alpha: isFocused ? 1.0 : 0.85),
                width: isFocused ? 3 : 1.5,
              ),
              color: isDimmed
                  ? regionColor.withValues(alpha: 0.03)
                  : regionColor.withValues(
                      alpha: isFocused ? 0.10 : 0.05),
            ),
          ),
        ),
      ));
    }

    // Second pass: problem-number bboxes (smaller, red/orange) drawn *on top*
    // so they stay readable even inside the item_region fill.
    for (var i = 0; i < result.items.length; i += 1) {
      final item = result.items[i];
      final bbox = item.bbox;
      if (bbox == null || bbox.length != 4) continue;
      final rect = _normalizedBboxToRect(bbox, pageSize);
      if (rect == null) continue;
      final isFocused = focusedIndex == i;
      final isDimmed = focusedIndex != null && !isFocused;
      final color = item.isSetHeader
          ? const Color(0xFFFFB44A)
          : const Color(0xFFFF4D4F);
      out.add(Positioned(
        left: rect.left,
        top: rect.top,
        width: rect.width,
        height: rect.height,
        child: IgnorePointer(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isDimmed
                        ? color.withValues(alpha: 0.35)
                        : color,
                    width: 2,
                  ),
                  color: isDimmed
                      ? color.withValues(alpha: 0.03)
                      : color.withValues(alpha: 0.08),
                ),
              ),
              Positioned(
                left: -2,
                top: -18,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 1),
                  color: isDimmed
                      ? color.withValues(alpha: 0.5)
                      : color,
                  child: Text(
                    item.label.isEmpty
                        ? item.number
                        : '${item.number} · ${item.label}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ));
    }
    return out;
  }

  Rect? _normalizedBboxToRect(List<int> bbox, Size pageSize) {
    final ymin = bbox[0] / 1000.0;
    final xmin = bbox[1] / 1000.0;
    final ymax = bbox[2] / 1000.0;
    final xmax = bbox[3] / 1000.0;
    final left = xmin * pageSize.width;
    final top = ymin * pageSize.height;
    final width = (xmax - xmin) * pageSize.width;
    final height = (ymax - ymin) * pageSize.height;
    if (width <= 0 || height <= 0) return null;
    return Rect.fromLTWH(left, top, width, height);
  }

  Widget _buildPageNavBar() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _kBorder)),
        color: _kCard,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_rangeRunning ||
              _rangeDone > 0 ||
              _rangeFailed > 0 ||
              _rangeFailedPages.isNotEmpty)
            _buildRangeProgressBar(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left, color: _kText),
                  onPressed: _pageNumber > 1 ? _goPrev : null,
                  tooltip: '이전 페이지',
                ),
                Text(
                  '$_pageNumber / $_pageCount',
                  style: const TextStyle(
                    color: _kText,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right, color: _kText),
                  onPressed: _pageNumber < _pageCount ? _goNext : null,
                  tooltip: '다음 페이지',
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 64,
                  child: TextField(
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: _kText, fontSize: 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                      border: OutlineInputBorder(),
                      hintText: '페이지',
                      hintStyle: TextStyle(color: _kTextSub, fontSize: 12),
                    ),
                    keyboardType: TextInputType.number,
                    onSubmitted: (s) async {
                      final n = int.tryParse(s.trim());
                      if (n == null || n < 1 || n > _pageCount) return;
                      await _controller.goToPage(pageNumber: n);
                    },
                  ),
                ),
                const Spacer(),
                _buildRangeButton(),
                const SizedBox(width: 8),
                _buildAnalyzeButton(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRangeProgressBar() {
    final total = _rangeRunning
        ? (_rangeEnd - _rangeStart + 1)
        : ((_rangeDone + _rangeFailed) == 0
            ? 1
            : (_rangeDone + _rangeFailed));
    final progressed = _rangeDone + _rangeFailed;
    final ratio = total <= 0 ? 0.0 : (progressed / total).clamp(0.0, 1.0);
    final percentTxt = (ratio * 100).toStringAsFixed(0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        color: Color(0xFF1A2A22),
        border: Border(bottom: BorderSide(color: _kBorder)),
      ),
      child: Row(
        children: [
          Icon(
            _rangeRunning ? Icons.auto_mode : Icons.done_all,
            size: 14,
            color: _rangeRunning ? _kAccent : const Color(0xFF8FD9B2),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _rangeRunning
                      ? '단원 분석 중: p$_rangeCursor (${_rangeStart}~$_rangeEnd) '
                          '· 성공 $_rangeDone · 실패 $_rangeFailed · $percentTxt%'
                      : '단원 분석 완료: ${_rangeStart}~$_rangeEnd '
                          '· 성공 $_rangeDone · 실패 $_rangeFailed',
                  style: const TextStyle(
                    color: _kText,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: _rangeRunning && ratio == 0 ? null : ratio,
                    minHeight: 4,
                    backgroundColor: const Color(0xFF2A2A2A),
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(_kAccent),
                  ),
                ),
                if (_rangeLastError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      '마지막 오류 · $_rangeLastError',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _kDanger,
                        fontSize: 10,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_rangeRunning)
            TextButton.icon(
              onPressed: _rangeCancel ? null : _cancelRangeAnalysis,
              icon: const Icon(Icons.stop_circle_outlined, size: 14),
              label: Text(_rangeCancel ? '취소 중...' : '취소'),
              style: TextButton.styleFrom(foregroundColor: _kDanger),
            )
          else if (_rangeFailedPages.isNotEmpty)
            TextButton.icon(
              onPressed: _retryFailedPages,
              icon: const Icon(Icons.replay, size: 14),
              label: Text('실패 ${_rangeFailedPages.length}p 재분석'),
              style: TextButton.styleFrom(foregroundColor: _kAccent),
            ),
        ],
      ),
    );
  }

  Widget _buildAnalyzeButton() {
    final disabled = _analyzing || _document == null || _rangeRunning;
    return FilledButton.icon(
      onPressed: disabled ? null : _analyzeCurrentPage,
      icon: _analyzing
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.auto_awesome, size: 16),
      label: Text(_analyzing ? '분석 중...' : '이 페이지 분석'),
      style: FilledButton.styleFrom(
        backgroundColor: _kAccent,
        disabledBackgroundColor: const Color(0xFF2A2A2A),
      ),
    );
  }

  Widget _buildRangeButton() {
    final disabled = _analyzing || _document == null || _rangeRunning;
    return OutlinedButton.icon(
      onPressed: disabled ? null : _promptAndStartRange,
      icon: const Icon(Icons.menu_book_outlined, size: 16),
      label: const Text('단원 분석'),
      style: OutlinedButton.styleFrom(
        foregroundColor: _kText,
        side: const BorderSide(color: _kBorder),
      ),
    );
  }

  Widget _buildSidePane() {
    final result = _resultsByPage[_pageNumber];
    final showUnitSummary = _rangeRunning ||
        _rangeDone > 0 ||
        _rangeFailed > 0 ||
        _resultsByPage.length > 1;
    return Container(
      color: _kBg,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSideHeader(result),
          const SizedBox(height: 10),
          if (showUnitSummary) ...[
            _buildUnitSummary(),
            const SizedBox(height: 10),
          ],
          if (_analyzeError != null)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF2A1919),
                border: Border.all(color: const Color(0xFF5A2A2A)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '분석 실패: $_analyzeError',
                style: const TextStyle(
                    color: _kDanger, fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
          const SizedBox(height: 10),
          Expanded(child: _buildResultBody(result)),
        ],
      ),
    );
  }

  Widget _buildUnitSummary() {
    final counts = <String, int>{
      'basic_drill': 0,
      'type_practice': 0,
      'mastery': 0,
      'unknown': 0,
    };
    final labelCounts = <String, int>{};
    var totalItems = 0;
    var setHeaders = 0;
    for (final r in _resultsByPage.values) {
      counts.update(
        counts.containsKey(r.section) ? r.section : 'unknown',
        (v) => v + 1,
        ifAbsent: () => 1,
      );
      for (final it in r.items) {
        totalItems += 1;
        if (it.isSetHeader) setHeaders += 1;
        final l = it.label.isEmpty ? '—' : it.label;
        labelCounts.update(l, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    final analyzedPages = _resultsByPage.length;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '단원 누적 · 분석 $analyzedPages페이지 · 총 $totalItems건',
            style: const TextStyle(
              color: _kText,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final s in const [
                'basic_drill',
                'type_practice',
                'mastery',
                'unknown',
              ])
                if (counts[s]! > 0)
                  _sectionChip(s, counts[s]!),
              if (setHeaders > 0)
                _miniTag('세트형 $setHeaders건', const Color(0xFF3A2A1A)),
            ],
          ),
          if (labelCounts.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: labelCounts.entries
                  .map((e) => _miniTag(
                        '${e.key} ${e.value}',
                        const Color(0xFF222E28),
                      ))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionChip(String section, int? count) {
    final bg = _sectionColor(section);
    final txt = count == null
        ? _sectionLabel(section)
        : '${_sectionLabel(section)} ${count}p';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        txt,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildSideHeader(_PageVlmResult? result) {
    if (result == null) {
      return const Text(
        '분석 결과 없음 — "이 페이지 분석" 또는 "단원 분석" 버튼을 눌러 시작하세요.',
        style: TextStyle(color: _kTextSub, fontSize: 12),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            _sectionChip(result.section, null),
            _miniTag(
                'PDF ${result.rawPage}p → 책면 ${result.displayPage}p',
                const Color(0xFF234A34)),
            _miniTag(
              'offset ${result.pageOffset}${result.pageOffsetFound ? '' : '(없음)'}',
              const Color(0xFF333333),
            ),
            _miniTag(
              result.layout == 'two_column'
                  ? '2단'
                  : result.layout == 'one_column'
                      ? '1단'
                      : '레이아웃?',
              const Color(0xFF333333),
            ),
            _miniTag('${result.elapsedMs}ms', const Color(0xFF333333)),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '탐지 ${result.items.length}건 · ${result.model}',
          style: const TextStyle(
            color: _kText,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
        if (result.notes.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            'notes: ${result.notes}',
            style: const TextStyle(color: _kTextSub, fontSize: 11),
          ),
        ],
      ],
    );
  }

  Widget _miniTag(String text, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: _kText,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildResultBody(_PageVlmResult? result) {
    if (result == null) {
      return const Center(
        child: Text(
          '결과가 여기에 표시됩니다.',
          style: TextStyle(color: _kTextSub, fontSize: 12),
        ),
      );
    }
    if (result.items.isEmpty) {
      return const Center(
        child: Text(
          '이 페이지에서 문항번호를 찾지 못했습니다.',
          style: TextStyle(color: _kTextSub, fontSize: 12),
        ),
      );
    }
    final focusedIndex = _focusedItemIndex;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (focusedIndex != null &&
            focusedIndex >= 0 &&
            focusedIndex < result.items.length)
          _buildCropPreview(result, focusedIndex),
        Expanded(
          child: ListView.separated(
            itemCount: result.items.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, color: _kBorder),
            itemBuilder: (context, i) => _buildResultItem(result, i),
          ),
        ),
      ],
    );
  }

  Widget _buildResultItem(_PageVlmResult result, int i) {
    final item = result.items[i];
    final isFocused = _focusedItemIndex == i;
    final hasRegion = item.itemRegion != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        debugPrint('[vlm-test] tap item i=$i '
            'number=${item.number} '
            'hasRegion=$hasRegion '
            'bbox=${item.bbox}');
        _toggleFocus(i);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: isFocused ? const Color(0xFF1E3A2A) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                color: item.isSetHeader
                    ? const Color(0xFFFFB44A)
                    : _kAccent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                item.number,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        item.label.isEmpty ? '—' : item.label,
                        style: const TextStyle(
                          color: _kText,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (item.column != null)
                        Text(
                          '단 ${item.column}',
                          style: const TextStyle(
                              color: _kTextSub, fontSize: 11),
                        ),
                      if (item.isSetHeader && item.setFrom != null &&
                          item.setTo != null) ...[
                        const SizedBox(width: 10),
                        Text(
                          '세트 ${item.setFrom}~${item.setTo}',
                          style: const TextStyle(
                              color: Color(0xFFFFB44A), fontSize: 11),
                        ),
                      ],
                      if (hasRegion) ...[
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A3A4A),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: const Text(
                            '영역',
                            style: TextStyle(
                              color: Color(0xFF5AA6FF),
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (item.bbox != null)
                    Text(
                      'bbox [${item.bbox!.join(', ')}]',
                      style: const TextStyle(
                        color: Color(0xFF6A7A7A),
                        fontSize: 10,
                        fontFamily: 'monospace',
                      ),
                    ),
                ],
              ),
            ),
            Icon(
              isFocused ? Icons.visibility : Icons.crop,
              size: 16,
              color: isFocused ? _kAccent : _kTextSub,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCropPreview(_PageVlmResult result, int index) {
    final item = result.items[index];
    final bytes = _cropBytesFor(result, index);
    final hasRegion = item.itemRegion != null;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF5AA6FF).withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: item.isSetHeader
                      ? const Color(0xFFFFB44A)
                      : _kAccent,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  item.number,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hasRegion
                      ? '${item.number}번 크롭 미리보기'
                      : '${item.number}번 (번호 bbox 기준)',
                  style: const TextStyle(
                    color: _kText,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => _toggleFocus(index),
                icon: const Icon(Icons.close, size: 16, color: _kTextSub),
                tooltip: '포커스 해제',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(
              maxHeight: 320,
              minHeight: 80,
            ),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(4),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: bytes == null
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: Text(
                        '영역 정보 없음',
                        style: TextStyle(
                            color: _kTextSub, fontSize: 12),
                      ),
                    )
                  : Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
            ),
          ),
          if (!hasRegion)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '※ 문항 영역(item_region) 이 비어 있어 번호 bbox 기준으로 잘랐습니다. 재분석 시 영역이 나올 수도 있습니다.',
                style: TextStyle(color: _kTextSub, fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }

  void _toggleFocus(int index) {
    final current = _focusedItemIndex;
    final next = current == index ? null : index;
    debugPrint('[vlm-test] _toggleFocus $current -> $next');
    setState(() {
      _focusedItemIndex = next;
    });
  }

  /// Returns cached cropped PNG bytes for (page, index) or computes them.
  /// Delegates to the shared `cropProblemRegion` so padding/number-avoidance
  /// behaviour stays in one place (also used by the crop-extract dialog).
  Uint8List? _cropBytesFor(_PageVlmResult result, int index) {
    if (index < 0 || index >= result.items.length) return null;
    final key = '$_pageNumber:$index';
    final cached = _cropCache[key];
    if (cached != null) return cached;

    final item = result.items[index];
    final region = item.itemRegion;
    if (region == null || region.length != 4) {
      // Fallback: no item_region — crop around the number bbox itself,
      // generously padded. Better than returning nothing.
      final bbox = item.bbox;
      if (bbox == null || bbox.length != 4) return null;
      final fallback = cropProblemRegion(
        sourcePng: result.renderedPng,
        itemRegion: bbox,
        options: const ProblemCropOptions(
          paddingRatio: 0.04,
          minPaddingPx: 24,
          avoidNumber: false,
          maskRemainingNumber: false,
        ),
      );
      if (fallback == null) return null;
      _cropCache[key] = fallback.pngBytes;
      return fallback.pngBytes;
    }

    final crop = cropProblemRegion(
      sourcePng: result.renderedPng,
      itemRegion: region,
      numberBbox: item.bbox,
    );
    if (crop == null) return null;
    _cropCache[key] = crop.pngBytes;
    return crop.pngBytes;
  }
}

/// Paints a translucent black mask over the whole page rect with a
/// rectangular hole cut over the focused item so everything else is dimmed.
class _FocusMaskPainter extends CustomPainter {
  _FocusMaskPainter({required this.holeBbox});

  /// Normalized [ymin, xmin, ymax, xmax] in 0..1000.
  final List<int> holeBbox;

  @override
  void paint(Canvas canvas, Size size) {
    if (holeBbox.length != 4) return;
    final ymin = holeBbox[0] / 1000.0 * size.height;
    final xmin = holeBbox[1] / 1000.0 * size.width;
    final ymax = holeBbox[2] / 1000.0 * size.height;
    final xmax = holeBbox[3] / 1000.0 * size.width;
    final hole = Rect.fromLTRB(xmin, ymin, xmax, ymax);
    final full = Rect.fromLTWH(0, 0, size.width, size.height);

    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(full)
      ..addRect(hole);
    final paint = Paint()..color = const Color(0x80000000);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _FocusMaskPainter old) =>
      old.holeBbox != holeBbox;
}

class _PageVlmResult {
  const _PageVlmResult({
    required this.rawPage,
    required this.displayPage,
    required this.pageOffset,
    required this.pageOffsetFound,
    required this.section,
    required this.layout,
    required this.items,
    required this.notes,
    required this.model,
    required this.elapsedMs,
    required this.renderedPng,
  });

  final int rawPage;
  final int displayPage;
  final int pageOffset;
  final bool pageOffsetFound;

  /// basic_drill | type_practice | mastery | unknown
  final String section;
  final String layout;
  final List<TextbookVlmItem> items;
  final String notes;
  final String model;
  final int elapsedMs;

  /// PNG bytes of the page we sent to the VLM. Kept in memory so the crop
  /// preview on the right can slice it without re-rendering.
  final Uint8List renderedPng;
}

/// Human-readable Korean label for a backend `section` code. Kept alongside
/// the result model so dialog, side pane, and crop header all stay in sync.
String _sectionLabel(String section) {
  switch (section) {
    case 'basic_drill':
      return '기본다잡기';
    case 'type_practice':
      return '유형뽀개기';
    case 'mastery':
      return '만점도전하기';
    default:
      return '섹션 ?';
  }
}

Color _sectionColor(String section) {
  switch (section) {
    case 'basic_drill':
      return const Color(0xFFBE7A3C); // 오렌지/갈색 (이미지의 0001 번호 톤)
    case 'type_practice':
      return const Color(0xFF33A373);
    case 'mastery':
      return const Color(0xFF5C6BC0);
    default:
      return const Color(0xFF555555);
  }
}
