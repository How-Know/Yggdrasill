import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../app_overlays.dart';
import '../dialog_tokens.dart';
import '../latex_text_renderer.dart';

enum HomeworkAnswerViewerAction { confirm, complete }

enum HomeworkAnswerCellState {
  correct,
  wrong,
  unsolved,
}

class HomeworkAnswerGradingCell {
  final String key;
  final int questionIndex;
  final String answer;

  const HomeworkAnswerGradingCell({
    required this.key,
    required this.questionIndex,
    required this.answer,
  });
}

class HomeworkAnswerGradingPage {
  final int pageNumber;
  final List<HomeworkAnswerGradingCell> cells;

  const HomeworkAnswerGradingPage({
    required this.pageNumber,
    required this.cells,
  });
}

class HomeworkAnswerOverlayEntry {
  final String title;
  final String page;
  final String memo;

  const HomeworkAnswerOverlayEntry({
    required this.title,
    required this.page,
    required this.memo,
  });
}

Future<HomeworkAnswerViewerAction?> openHomeworkAnswerViewerPage(
  BuildContext context, {
  required String filePath,
  required String title,
  String? solutionFilePath,
  String? cacheKey,
  bool enableConfirm = true,
  List<HomeworkAnswerOverlayEntry> overlayEntries =
      const <HomeworkAnswerOverlayEntry>[],
  List<HomeworkAnswerGradingPage> gradingPages =
      const <HomeworkAnswerGradingPage>[],
  Map<String, HomeworkAnswerCellState> initialGradingStates =
      const <String, HomeworkAnswerCellState>{},
  void Function(Map<String, HomeworkAnswerCellState> states)?
      onGradingStatesChanged,
  bool hideSourceDocument = false,
}) async {
  final previousMemoFloatingHidden = hideGlobalMemoFloatingBanners.value;
  hideGlobalMemoFloatingBanners.value = true;
  try {
    return await Navigator.of(context).push<HomeworkAnswerViewerAction>(
      MaterialPageRoute<HomeworkAnswerViewerAction>(
        builder: (_) => HomeworkAnswerViewerPage(
          filePath: filePath,
          title: title,
          solutionFilePath: solutionFilePath,
          cacheKey: cacheKey,
          enableConfirm: enableConfirm,
          overlayEntries: overlayEntries,
          gradingPages: gradingPages,
          initialGradingStates: initialGradingStates,
          onGradingStatesChanged: onGradingStatesChanged,
          hideSourceDocument: hideSourceDocument,
        ),
      ),
    );
  } finally {
    hideGlobalMemoFloatingBanners.value = previousMemoFloatingHidden;
  }
}

class HomeworkAnswerViewerPage extends StatefulWidget {
  final String filePath;
  final String title;
  final String? solutionFilePath;
  final String? cacheKey;
  final bool enableConfirm;
  final List<HomeworkAnswerOverlayEntry> overlayEntries;
  final List<HomeworkAnswerGradingPage> gradingPages;
  final Map<String, HomeworkAnswerCellState> initialGradingStates;
  final void Function(Map<String, HomeworkAnswerCellState> states)?
      onGradingStatesChanged;
  final bool hideSourceDocument;

  const HomeworkAnswerViewerPage({
    super.key,
    required this.filePath,
    required this.title,
    this.solutionFilePath,
    this.cacheKey,
    this.enableConfirm = true,
    this.overlayEntries = const <HomeworkAnswerOverlayEntry>[],
    this.gradingPages = const <HomeworkAnswerGradingPage>[],
    this.initialGradingStates = const <String, HomeworkAnswerCellState>{},
    this.onGradingStatesChanged,
    this.hideSourceDocument = false,
  });

  @override
  State<HomeworkAnswerViewerPage> createState() =>
      _HomeworkAnswerViewerPageState();
}

class _ViewerCacheState {
  final int page;
  final double? zoom;
  final double? centerX;
  final double? centerY;
  final double? pageCenterRatioX;
  final double? pageCenterRatioY;
  final double? panRangeRatioX;
  final double? panRangeRatioY;
  final List<double>? matrixStorage;
  final double? viewWidth;
  final double? viewHeight;

  const _ViewerCacheState({
    required this.page,
    required this.zoom,
    required this.centerX,
    required this.centerY,
    required this.pageCenterRatioX,
    required this.pageCenterRatioY,
    required this.panRangeRatioX,
    required this.panRangeRatioY,
    required this.matrixStorage,
    required this.viewWidth,
    required this.viewHeight,
  });
}

class _HomeworkAnswerViewerPageState extends State<HomeworkAnswerViewerPage> {
  static final Map<String, _ViewerCacheState> _viewCacheByKey =
      <String, _ViewerCacheState>{};
  static const bool _restoreDebugLog = true;

  final PdfViewerController _viewerController = PdfViewerController();
  int _pageNumber = 1;
  int _lockedPageNumber = 1;
  int _pageCount = 0;
  double _sliderPage = 1;
  bool _draggingSlider = false;
  bool _isViewerReady = false;
  bool _openingSolution = false;
  bool _overlayCollapsed = false;
  bool _gradingPanelCollapsed = false;
  late Map<String, HomeworkAnswerCellState> _gradingStates;
  double? _cachedInitialZoom;
  Offset? _cachedInitialCenter;
  Offset? _cachedInitialCenterRatio;
  Offset? _cachedInitialPanRangeRatio;
  List<double>? _cachedInitialMatrixStorage;
  Size? _cachedInitialViewSize;
  static const double _minUserZoom = 0.35;
  static const double _maxUserZoom = 10.0;

  String _fmtNum(double? v) => (v == null) ? 'null' : v.toStringAsFixed(4);
  String _fmtOffset(Offset? o) =>
      (o == null) ? 'null' : '(${_fmtNum(o.dx)}, ${_fmtNum(o.dy)})';
  void _logRestore(String message) {
    if (!_restoreDebugLog) return;
    debugPrint('[ANS_VIEW][RESTORE] $message');
  }

  bool get _hasSolution => (widget.solutionFilePath ?? '').trim().isNotEmpty;

  bool get _hasGradingPanel => widget.gradingPages.isNotEmpty;
  bool get _showDocument => !(widget.hideSourceDocument && _hasGradingPanel);

  String get _cacheKey => (widget.cacheKey ?? '').trim();

  @override
  void initState() {
    super.initState();
    _gradingStates = Map<String, HomeworkAnswerCellState>.from(
      widget.initialGradingStates,
    );
    final key = _cacheKey;
    if (key.isNotEmpty) {
      final cached = _viewCacheByKey[key];
      if (cached != null && cached.page > 0) {
        _pageNumber = cached.page;
        _lockedPageNumber = cached.page;
        _sliderPage = cached.page.toDouble();
        _cachedInitialZoom = cached.zoom;
        if (cached.centerX != null && cached.centerY != null) {
          _cachedInitialCenter = Offset(cached.centerX!, cached.centerY!);
        }
        if (cached.pageCenterRatioX != null &&
            cached.pageCenterRatioY != null) {
          _cachedInitialCenterRatio = Offset(
            cached.pageCenterRatioX!,
            cached.pageCenterRatioY!,
          );
        }
        if (cached.panRangeRatioX != null && cached.panRangeRatioY != null) {
          _cachedInitialPanRangeRatio = Offset(
            cached.panRangeRatioX!,
            cached.panRangeRatioY!,
          );
        }
        if (cached.matrixStorage != null &&
            cached.matrixStorage!.length == 16) {
          _cachedInitialMatrixStorage =
              List<double>.from(cached.matrixStorage!);
        }
        if (cached.viewWidth != null && cached.viewHeight != null) {
          _cachedInitialViewSize = Size(cached.viewWidth!, cached.viewHeight!);
        }
        _logRestore(
          'init cache hit key="$key" page=${cached.page} zoom=${_fmtNum(cached.zoom)} '
          'center=(${_fmtNum(cached.centerX)}, ${_fmtNum(cached.centerY)}) '
          'pageRatio=(${_fmtNum(cached.pageCenterRatioX)}, ${_fmtNum(cached.pageCenterRatioY)}) '
          'panRatio=(${_fmtNum(cached.panRangeRatioX)}, ${_fmtNum(cached.panRangeRatioY)}) '
          'view=(${_fmtNum(cached.viewWidth)}, ${_fmtNum(cached.viewHeight)}) '
          'matrix=${cached.matrixStorage != null ? "yes" : "no"}',
        );
      } else {
        _logRestore('init cache miss key="$key"');
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  bool _isUrl(String raw) {
    final lower = raw.trim().toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  void _savePageCache() {
    final key = _cacheKey;
    if (key.isEmpty) return;
    final int pageNow = _viewerController.isReady
        ? ((_viewerController.pageNumber ?? _pageNumber).clamp(1, _pageCount))
            .toInt()
        : _pageNumber;
    final previous = _viewCacheByKey[key];
    final zoom = _viewerController.isReady
        ? _viewerController.currentZoom
        : previous?.zoom;
    final center = _viewerController.isReady
        ? _viewerController.centerPosition
        : (previous?.centerX != null && previous?.centerY != null
            ? Offset(previous!.centerX!, previous.centerY!)
            : null);
    final pageCenterRatio = _viewerController.isReady
        ? _pageCenterRatioForCurrentView()
        : (previous?.pageCenterRatioX != null &&
                previous?.pageCenterRatioY != null
            ? Offset(previous!.pageCenterRatioX!, previous.pageCenterRatioY!)
            : null);
    final panRangeRatio = _viewerController.isReady
        ? _pagePanRangeRatioForCurrentView()
        : (previous?.panRangeRatioX != null && previous?.panRangeRatioY != null
            ? Offset(previous!.panRangeRatioX!, previous.panRangeRatioY!)
            : null);
    final matrixStorage = _viewerController.isReady
        ? List<double>.from(_viewerController.value.storage)
        : previous?.matrixStorage;
    final viewSize = _viewerController.isReady
        ? _viewerController.viewSize
        : (previous?.viewWidth != null && previous?.viewHeight != null
            ? Size(previous!.viewWidth!, previous.viewHeight!)
            : null);
    _viewCacheByKey[key] = _ViewerCacheState(
      page: pageNow <= 0 ? 1 : pageNow,
      zoom: zoom,
      centerX: center?.dx,
      centerY: center?.dy,
      pageCenterRatioX: pageCenterRatio?.dx,
      pageCenterRatioY: pageCenterRatio?.dy,
      panRangeRatioX: panRangeRatio?.dx,
      panRangeRatioY: panRangeRatio?.dy,
      matrixStorage:
          matrixStorage == null ? null : List<double>.from(matrixStorage),
      viewWidth: viewSize?.width,
      viewHeight: viewSize?.height,
    );
    _logRestore(
      'save key="$key" page=$pageNow zoom=${_fmtNum(zoom)} center=${_fmtOffset(center)} '
      'pageRatio=${_fmtOffset(pageCenterRatio)} panRatio=${_fmtOffset(panRangeRatio)} '
      'view=(${_fmtNum(viewSize?.width)}, ${_fmtNum(viewSize?.height)})',
    );
  }

  Offset? _pageCenterRatioForCurrentView() {
    if (!_viewerController.isReady || _pageNumber <= 0) return null;
    final layouts = _viewerController.layout.pageLayouts;
    final pageNow = (_viewerController.pageNumber ?? _pageNumber).clamp(
      1,
      layouts.length,
    );
    final idx = (pageNow - 1).clamp(0, layouts.length - 1);
    if (idx < 0 || idx >= layouts.length) return null;
    final rect = layouts[idx];
    if (rect.width <= 0 || rect.height <= 0) return null;
    final center = _viewerController.centerPosition;
    final rx = ((center.dx - rect.left) / rect.width).clamp(0.0, 1.0);
    final ry = ((center.dy - rect.top) / rect.height).clamp(0.0, 1.0);
    return Offset(rx.toDouble(), ry.toDouble());
  }

  Offset? _pagePanRangeRatioForCurrentView() {
    if (!_viewerController.isReady || _pageNumber <= 0) return null;
    final layouts = _viewerController.layout.pageLayouts;
    final pageNow = (_viewerController.pageNumber ?? _pageNumber).clamp(
      1,
      layouts.length,
    );
    final idx = (pageNow - 1).clamp(0, layouts.length - 1);
    if (idx < 0 || idx >= layouts.length) return null;
    final rect = layouts[idx];
    final zoom = _viewerController.currentZoom;
    if (zoom <= 0 || rect.width <= 0 || rect.height <= 0) return null;
    final view = _viewerController.viewSize;
    final center = _viewerController.centerPosition;
    final halfW = view.width / 2 / zoom;
    final halfH = view.height / 2 / zoom;
    final minX = rect.left + halfW;
    final maxX = rect.right - halfW;
    final minY = rect.top + halfH;
    final maxY = rect.bottom - halfH;
    final rx = (minX >= maxX)
        ? 0.5
        : ((center.dx - minX) / (maxX - minX)).clamp(0.0, 1.0);
    final ry = (minY >= maxY)
        ? 0.5
        : ((center.dy - minY) / (maxY - minY)).clamp(0.0, 1.0);
    return Offset(rx.toDouble(), ry.toDouble());
  }

  Offset _centerFromPanRangeRatio({
    required Rect pageRect,
    required Offset ratio,
    required double zoom,
    required Size viewSize,
  }) {
    final halfW = viewSize.width / 2 / zoom;
    final halfH = viewSize.height / 2 / zoom;
    final minX = pageRect.left + halfW;
    final maxX = pageRect.right - halfW;
    final minY = pageRect.top + halfH;
    final maxY = pageRect.bottom - halfH;
    final rx = ratio.dx.clamp(0.0, 1.0).toDouble();
    final ry = ratio.dy.clamp(0.0, 1.0).toDouble();
    final cx =
        (minX >= maxX) ? pageRect.center.dx : (minX + (maxX - minX) * rx);
    final cy =
        (minY >= maxY) ? pageRect.center.dy : (minY + (maxY - minY) * ry);
    return Offset(cx, cy);
  }

  double _sliderUiValueFromPage(double page) {
    if (_pageCount <= 1) return 1;
    final raw = _pageCount + 1 - page;
    return raw.clamp(1.0, _pageCount.toDouble()).toDouble();
  }

  double _pageFromSliderUiValue(double uiValue) {
    if (_pageCount <= 1) return 1;
    final raw = _pageCount + 1 - uiValue;
    return raw.clamp(1.0, _pageCount.toDouble()).toDouble();
  }

  Future<void> _goPrev() async {
    if (!_isViewerReady || _pageNumber <= 1) return;
    final target = _pageNumber - 1;
    setState(() {
      _lockedPageNumber = target;
      _pageNumber = target;
      if (!_draggingSlider) _sliderPage = target.toDouble();
    });
    await _viewerController.goToPage(
      pageNumber: target,
      duration: const Duration(milliseconds: 120),
    );
  }

  Future<void> _goNext() async {
    if (!_isViewerReady || _pageNumber >= _pageCount) return;
    final target = _pageNumber + 1;
    setState(() {
      _lockedPageNumber = target;
      _pageNumber = target;
      if (!_draggingSlider) _sliderPage = target.toDouble();
    });
    await _viewerController.goToPage(
      pageNumber: target,
      duration: const Duration(milliseconds: 120),
    );
  }

  Future<void> _openSolution() async {
    final solutionPath = (widget.solutionFilePath ?? '').trim();
    if (solutionPath.isEmpty || _openingSolution) return;
    setState(() => _openingSolution = true);
    try {
      await openHomeworkAnswerViewerPage(
        context,
        filePath: solutionPath,
        title: '${widget.title} · 해설',
        cacheKey:
            'sol|${_cacheKey.isEmpty ? widget.filePath : _cacheKey}|$solutionPath',
        enableConfirm: false,
        overlayEntries: widget.overlayEntries,
      );
    } finally {
      if (mounted) setState(() => _openingSolution = false);
    }
  }

  HomeworkAnswerCellState _nextGradingState(HomeworkAnswerCellState current) {
    switch (current) {
      case HomeworkAnswerCellState.correct:
        return HomeworkAnswerCellState.wrong;
      case HomeworkAnswerCellState.wrong:
        return HomeworkAnswerCellState.unsolved;
      case HomeworkAnswerCellState.unsolved:
        return HomeworkAnswerCellState.correct;
    }
  }

  HomeworkAnswerCellState _gradingStateOf(String key) {
    return _gradingStates[key] ?? HomeworkAnswerCellState.correct;
  }

  void _emitGradingStates() {
    final callback = widget.onGradingStatesChanged;
    if (callback == null) return;
    callback(Map<String, HomeworkAnswerCellState>.from(_gradingStates));
  }

  void _toggleGradingCellState(String key) {
    final current = _gradingStateOf(key);
    setState(() {
      _gradingStates[key] = _nextGradingState(current);
    });
    _emitGradingStates();
  }

  String _normalizeAnswerForMathRendering(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '-';
    if (trimmed == '-') return trimmed;
    if (trimmed.contains(r'$$') || trimmed.contains(r'\(')) {
      return trimmed;
    }
    var normalized = trimmed.replaceAll('\n', r' \\ ');
    normalized = normalized.replaceAllMapped(
      RegExp(r'(?<!\\)(\d+)\s*/\s*(\d+)'),
      (match) =>
          r'\frac{' +
          (match.group(1) ?? '') +
          '}{' +
          (match.group(2) ?? '') +
          '}',
    );
    final looksMath = normalized.contains(r'\') ||
        RegExp(r'[\^\_\=\+\-\*\/]').hasMatch(normalized);
    if (!looksMath) return trimmed;
    return '\$\$$normalized\$\$';
  }

  PdfPageLayout _layoutSinglePageVertical(
      List<PdfPage> pages, PdfViewerParams params) {
    if (pages.isEmpty) {
      return PdfPageLayout(
          pageLayouts: const <Rect>[], documentSize: Size.zero);
    }
    final maxWidth =
        pages.fold<double>(0, (prev, p) => math.max(prev, p.width));
    final width = maxWidth + params.margin * 2;
    const pageGap = 22000.0;
    double y = params.margin;
    final pageLayouts = <Rect>[];
    for (final p in pages) {
      final x = (width - p.width) / 2.0;
      pageLayouts.add(Rect.fromLTWH(x, y, p.width, p.height));
      y += p.height + pageGap;
    }
    return PdfPageLayout(
      pageLayouts: pageLayouts,
      documentSize: Size(width, y + params.margin),
    );
  }

  PdfViewerParams _viewerParams() {
    return PdfViewerParams(
      backgroundColor: kDlgBg,
      margin: 8,
      layoutPages: _layoutSinglePageVertical,
      pageAnchor: PdfPageAnchor.center,
      pageAnchorEnd: PdfPageAnchor.center,
      pageDropShadow: null,
      panEnabled: true,
      scaleEnabled: true,
      panAxis: PanAxis.free,
      maxScale: _maxUserZoom,
      minScale: _minUserZoom,
      useAlternativeFitScaleAsMinScale: false,
      scrollByMouseWheel: null,
      scrollHorizontallyByMouseWheel: false,
      onePassRenderingScaleThreshold: 340 / 72,
      maxImageBytesCachedOnMemory: 220 * 1024 * 1024,
      calculateInitialZoom: (document, controller, fitZoom, coverZoom) {
        final cached = _cachedInitialZoom;
        if (cached == null || !cached.isFinite) return fitZoom;
        return cached.clamp(_minUserZoom, _maxUserZoom).toDouble();
      },
      normalizeMatrix: (matrix, viewSize, layout, controller) {
        if (controller == null ||
            !controller.isReady ||
            layout.pageLayouts.isEmpty) {
          return matrix;
        }
        final int index =
            (_lockedPageNumber - 1).clamp(0, layout.pageLayouts.length - 1);
        final Rect pageRect = layout.pageLayouts[index];
        final double zoom =
            matrix.zoom.clamp(_minUserZoom, _maxUserZoom).toDouble();
        final Offset pos = matrix.calcPosition(viewSize);
        final double halfW = viewSize.width / 2 / zoom;
        final double halfH = viewSize.height / 2 / zoom;

        final double minX = pageRect.left + halfW;
        final double maxX = pageRect.right - halfW;
        final double minY = pageRect.top + halfH;
        final double maxY = pageRect.bottom - halfH;

        final double clampedX = (minX > maxX)
            ? pageRect.center.dx
            : pos.dx.clamp(minX, maxX).toDouble();
        final double clampedY = (minY > maxY)
            ? pageRect.center.dy
            : pos.dy.clamp(minY, maxY).toDouble();
        return controller.calcMatrixFor(
          Offset(clampedX, clampedY),
          zoom: zoom,
          viewSize: viewSize,
        );
      },
      getPageRenderingScale: (context, page, controller, estimatedScale) {
        final boosted = estimatedScale * 1.25;
        const maxPixels = 7000.0;
        final maxByPixels = math.min(
          maxPixels / page.width,
          maxPixels / page.height,
        );
        return math.max(1.0, math.min(boosted, maxByPixels));
      },
      onViewerReady: (document, controller) {
        if (!mounted) return;
        final maxPage = document.pages.length <= 0 ? 1 : document.pages.length;
        final int requested = _pageNumber.clamp(1, maxPage);
        _logRestore(
          'ready key="$_cacheKey" docPages=$maxPage requested=$requested '
          'cachedZoom=${_fmtNum(_cachedInitialZoom)} cachedCenter=${_fmtOffset(_cachedInitialCenter)} '
          'cachedPageRatio=${_fmtOffset(_cachedInitialCenterRatio)} cachedPanRatio=${_fmtOffset(_cachedInitialPanRangeRatio)} '
          'cachedView=${_cachedInitialViewSize == null ? "null" : "(${_fmtNum(_cachedInitialViewSize!.width)}, ${_fmtNum(_cachedInitialViewSize!.height)})"} '
          'cachedMatrix=${_cachedInitialMatrixStorage != null ? "yes" : "no"}',
        );
        setState(() {
          _isViewerReady = true;
          _pageCount = maxPage;
          _pageNumber = requested;
          _lockedPageNumber = requested;
          _sliderPage = requested.toDouble();
        });
        unawaited(() async {
          await controller.goToPage(
            pageNumber: requested,
            anchor: PdfPageAnchor.center,
            duration: Duration.zero,
          );
          bool matrixApplied = false;
          final cachedMatrixValues = _cachedInitialMatrixStorage;
          final cachedSize = _cachedInitialViewSize;
          if (cachedMatrixValues != null &&
              cachedMatrixValues.length == 16 &&
              cachedSize != null) {
            final currentSize = controller.viewSize;
            final sameSize =
                (currentSize.width - cachedSize.width).abs() < 2.0 &&
                    (currentSize.height - cachedSize.height).abs() < 2.0;
            _logRestore(
              'matrix candidate sameSize=$sameSize currentView=(${_fmtNum(currentSize.width)}, ${_fmtNum(currentSize.height)}) '
              'cachedView=(${_fmtNum(cachedSize.width)}, ${_fmtNum(cachedSize.height)})',
            );
            if (sameSize) {
              final matrix = Matrix4.fromList(cachedMatrixValues);
              await controller.goTo(matrix, duration: Duration.zero);
              await Future<void>.delayed(const Duration(milliseconds: 16));
              await controller.goTo(
                Matrix4.fromList(cachedMatrixValues),
                duration: Duration.zero,
              );
              matrixApplied = true;
              _logRestore(
                'matrix applied page=${controller.pageNumber} zoom=${_fmtNum(controller.currentZoom)} '
                'center=${_fmtOffset(controller.centerPosition)}',
              );
            }
          }
          Offset? center;
          final panRangeRatio = _cachedInitialPanRangeRatio;
          final double targetZoom =
              (_cachedInitialZoom ?? controller.currentZoom)
                  .clamp(_minUserZoom, _maxUserZoom)
                  .toDouble();
          if (panRangeRatio != null &&
              requested >= 1 &&
              requested <= controller.layout.pageLayouts.length) {
            final rect = controller.layout.pageLayouts[requested - 1];
            center = _centerFromPanRangeRatio(
              pageRect: rect,
              ratio: panRangeRatio,
              zoom: targetZoom,
              viewSize: controller.viewSize,
            );
            _logRestore(
              'use panRatio ratio=${_fmtOffset(panRangeRatio)} targetZoom=${_fmtNum(targetZoom)} center=${_fmtOffset(center)}',
            );
          }
          final ratio = _cachedInitialCenterRatio;
          if (center == null &&
              ratio != null &&
              requested >= 1 &&
              requested <= controller.layout.pageLayouts.length) {
            final rect = controller.layout.pageLayouts[requested - 1];
            center = Offset(
              rect.left + rect.width * ratio.dx.clamp(0.0, 1.0),
              rect.top + rect.height * ratio.dy.clamp(0.0, 1.0),
            );
            _logRestore(
              'use pageRatio ratio=${_fmtOffset(ratio)} targetZoom=${_fmtNum(targetZoom)} center=${_fmtOffset(center)}',
            );
          } else {
            center ??= _cachedInitialCenter;
            if (center != null) {
              _logRestore(
                'use absoluteCenter center=${_fmtOffset(center)} targetZoom=${_fmtNum(targetZoom)}',
              );
            }
          }
          if (center != null) {
            final matrix = controller.calcMatrixFor(center, zoom: targetZoom);
            await controller.goTo(matrix, duration: Duration.zero);
            // 렌더/레이아웃 직후 한 번 더 적용해 복원 정확도를 올린다.
            await Future<void>.delayed(const Duration(milliseconds: 16));
            final matrix2 = controller.calcMatrixFor(center, zoom: targetZoom);
            await controller.goTo(matrix2, duration: Duration.zero);
            // 페이지 progressive load 이후 미세 drift 보정.
            await Future<void>.delayed(const Duration(milliseconds: 140));
            final matrix3 = controller.calcMatrixFor(center, zoom: targetZoom);
            await controller.goTo(matrix3, duration: Duration.zero);
            _logRestore(
              '${matrixApplied ? "matrix+center" : "center"} applied page=${controller.pageNumber} '
              'zoom=${_fmtNum(controller.currentZoom)} center=${_fmtOffset(controller.centerPosition)} '
              'targetCenter=${_fmtOffset(center)}',
            );
          } else {
            _logRestore('no cached center available; using viewer default');
          }
        }());
      },
      onPageChanged: (page) {
        if (!mounted || page == null) return;
        setState(() {
          _pageNumber = page;
          _lockedPageNumber = page;
          if (!_draggingSlider) {
            _sliderPage = page.toDouble();
          }
        });
        _logRestore(
          'pageChanged page=$page zoom=${_fmtNum(_viewerController.isReady ? _viewerController.currentZoom : null)} '
          'center=${_fmtOffset(_viewerController.isReady ? _viewerController.centerPosition : null)}',
        );
      },
      loadingBannerBuilder: (context, bytesDownloaded, totalBytes) {
        return const Center(
          child: CircularProgressIndicator(color: kDlgAccent),
        );
      },
      errorBannerBuilder: (context, error, stackTrace, documentRef) {
        return const Center(
          child: Text(
            'PDF를 열 수 없습니다.',
            style: TextStyle(color: kDlgTextSub, fontWeight: FontWeight.w700),
          ),
        );
      },
    );
  }

  Future<void> _jumpBySlider(double pageValue) async {
    final target = pageValue.round().clamp(1, _pageCount);
    if (!_viewerController.isReady) return;
    setState(() {
      _lockedPageNumber = target;
      _pageNumber = target;
      _sliderPage = target.toDouble();
    });
    await _viewerController.goToPage(
      pageNumber: target,
      anchor: PdfPageAnchor.center,
      duration: const Duration(milliseconds: 80),
    );
  }

  Widget _buildViewer() {
    final source = widget.filePath.trim();
    if (_isUrl(source)) {
      final uri = Uri.tryParse(source);
      if (uri == null) {
        return const Center(
          child: Text(
            '잘못된 PDF URL입니다.',
            style: TextStyle(color: kDlgTextSub, fontWeight: FontWeight.w700),
          ),
        );
      }
      return PdfViewer.uri(
        uri,
        controller: _viewerController,
        params: _viewerParams(),
        initialPageNumber: _pageNumber,
      );
    }
    return PdfViewer.file(
      source,
      controller: _viewerController,
      params: _viewerParams(),
      initialPageNumber: _pageNumber,
    );
  }

  @override
  Widget build(BuildContext context) {
    final canPrev = _showDocument && _isViewerReady && _pageNumber > 1;
    final canNext = _showDocument && _isViewerReady && _pageNumber < _pageCount;
    final showPageSlider = _showDocument && _pageCount > 1;
    final controlsRightInset = showPageSlider ? 72.0 : 16.0;
    final sliderUiValue = _sliderUiValueFromPage(_sliderPage);
    return Scaffold(
      backgroundColor: kDlgBg,
      body: WillPopScope(
        onWillPop: () async {
          _savePageCache();
          _emitGradingStates();
          return true;
        },
        child: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: ColoredBox(
                  color: kDlgBg,
                  child:
                      _showDocument ? _buildViewer() : const SizedBox.shrink(),
                ),
              ),
              Positioned(
                left: 8,
                top: 8,
                right: 8,
                child: Row(
                  children: [
                    _circleIconButton(
                      icon: Icons.arrow_back_rounded,
                      tooltip: '뒤로가기',
                      onTap: () {
                        _savePageCache();
                        _emitGradingStates();
                        Navigator.of(context).pop(null);
                      },
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kDlgText,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_showDocument && widget.overlayEntries.isNotEmpty)
                Positioned(
                  left: 14,
                  top: 92,
                  right: showPageSlider ? 78 : 14,
                  child: _buildChildOverlayPanel(context),
                ),
              if (showPageSlider)
                Positioned(
                  right: 8,
                  top: 84,
                  bottom: 14,
                  child: Container(
                    width: 54,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
                    decoration: BoxDecoration(
                      color: kDlgPanelBg.withOpacity(0.92),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: kDlgBorder),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          '1',
                          style: TextStyle(
                            color: kDlgText,
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final int displayPage =
                                  _sliderPage.round().clamp(1, _pageCount);
                              final double ratio = _pageCount <= 1
                                  ? 0
                                  : (displayPage - 1) / (_pageCount - 1);
                              const double badgeH = 30;
                              final double badgeTop = ratio *
                                  (constraints.maxHeight - badgeH)
                                      .clamp(0.0, double.infinity)
                                      .toDouble();
                              return Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Positioned.fill(
                                    child: RotatedBox(
                                      quarterTurns: 3,
                                      child: SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          activeTrackColor: kDlgAccent,
                                          inactiveTrackColor: kDlgBorder,
                                          thumbColor: kDlgAccent,
                                          overlayColor:
                                              kDlgAccent.withOpacity(0.18),
                                          trackHeight: 6.0,
                                          thumbShape:
                                              const RoundSliderThumbShape(
                                            enabledThumbRadius: 9,
                                          ),
                                        ),
                                        child: Slider(
                                          min: 1,
                                          max: _pageCount.toDouble(),
                                          divisions: _pageCount > 1
                                              ? _pageCount - 1
                                              : null,
                                          value: sliderUiValue,
                                          onChangeStart: (_) {
                                            setState(
                                                () => _draggingSlider = true);
                                          },
                                          onChanged: (v) {
                                            setState(() {
                                              _sliderPage =
                                                  _pageFromSliderUiValue(v);
                                            });
                                          },
                                          onChangeEnd: (v) {
                                            final target =
                                                _pageFromSliderUiValue(v);
                                            setState(() {
                                              _draggingSlider = false;
                                              _sliderPage = target;
                                            });
                                            unawaited(_jumpBySlider(target));
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: -16,
                                    top: badgeTop,
                                    child: IgnorePointer(
                                      child: Container(
                                        constraints: const BoxConstraints(
                                          minWidth: 28,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: kDlgAccent,
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: RotatedBox(
                                          quarterTurns: 0,
                                          child: Text(
                                            '$displayPage',
                                            textAlign: TextAlign.center,
                                            maxLines: 1,
                                            softWrap: false,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w900,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        Text(
                          '$_pageCount',
                          style: const TextStyle(
                            color: kDlgTextSub,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_hasGradingPanel)
                Positioned(
                  right: controlsRightInset,
                  top: 92,
                  bottom: 100,
                  child: _buildGradingAnswerPanel(context),
                ),
              Positioned(
                right: controlsRightInset,
                bottom: 16,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_showDocument && _hasSolution)
                      _pillButton(
                        label: _openingSolution ? '열기...' : '해설',
                        icon: Icons.menu_book_rounded,
                        enabled: !_openingSolution,
                        onTap: () => unawaited(_openSolution()),
                      ),
                    if (_showDocument && _hasSolution)
                      const SizedBox(width: 12),
                    if (_showDocument) ...[
                      _circleIconButton(
                        icon: Icons.chevron_left_rounded,
                        tooltip: '이전 페이지',
                        enabled: canPrev,
                        onTap: () => unawaited(_goPrev()),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 14),
                        decoration: BoxDecoration(
                          color: kDlgPanelBg.withOpacity(0.92),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: kDlgBorder),
                        ),
                        child: Text(
                          _pageCount > 0
                              ? '$_pageNumber / $_pageCount'
                              : '- / -',
                          style: const TextStyle(
                            color: kDlgTextSub,
                            fontWeight: FontWeight.w800,
                            fontSize: 19,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      _circleIconButton(
                        icon: Icons.chevron_right_rounded,
                        tooltip: '다음 페이지',
                        enabled: canNext,
                        onTap: () => unawaited(_goNext()),
                      ),
                    ],
                    if (widget.enableConfirm) const SizedBox(width: 12),
                    if (widget.enableConfirm)
                      _pillButton(
                        label: '완료',
                        icon: Icons.task_alt_rounded,
                        enabled: true,
                        onTap: () {
                          _savePageCache();
                          _emitGradingStates();
                          Navigator.of(context).pop(
                            HomeworkAnswerViewerAction.complete,
                          );
                        },
                      ),
                    if (widget.enableConfirm) const SizedBox(width: 12),
                    if (widget.enableConfirm)
                      _pillButton(
                        label: '확인',
                        icon: Icons.check_rounded,
                        enabled: true,
                        onTap: () {
                          _savePageCache();
                          _emitGradingStates();
                          Navigator.of(context).pop(
                            HomeworkAnswerViewerAction.confirm,
                          );
                        },
                        filled: true,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChildOverlayPanel(BuildContext context) {
    final entries = widget.overlayEntries;
    if (entries.isEmpty) return const SizedBox.shrink();
    final maxWidth = math.min(MediaQuery.of(context).size.width * 0.29, 380.0);
    const titleStyle = TextStyle(
      color: Colors.white,
      fontSize: 20.0,
      fontWeight: FontWeight.w800,
      height: 1.1,
    );
    const metaStyle = TextStyle(
      color: Color(0xFF9AA3AD),
      fontSize: 20.0,
      fontWeight: FontWeight.w800,
      height: 1.1,
    );
    String normalize(String raw, {String fallback = '-'}) {
      final trimmed = raw.trim();
      return trimmed.isEmpty ? fallback : trimmed;
    }

    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF121A20),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.18),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '하위 과제 ${entries.length}개',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        height: 1.1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => setState(() {
                      _overlayCollapsed = !_overlayCollapsed;
                    }),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        _overlayCollapsed
                            ? Icons.expand_more_rounded
                            : Icons.expand_less_rounded,
                        size: 20,
                        color: Colors.white.withValues(alpha: 0.92),
                      ),
                    ),
                  ),
                ],
              ),
              if (!_overlayCollapsed) ...[
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (int i = 0; i < entries.length; i++) ...[
                          Text(
                            normalize(
                              entries[i].title,
                              fallback: '(제목 없음)',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: titleStyle,
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  normalize(entries[i].page),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.left,
                                  style: metaStyle,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  normalize(entries[i].memo),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.right,
                                  style: metaStyle,
                                ),
                              ),
                            ],
                          ),
                          if (i != entries.length - 1) ...[
                            const SizedBox(height: 9),
                            Container(
                              width: double.infinity,
                              height: 1,
                              color: Colors.white.withValues(alpha: 0.18),
                            ),
                            const SizedBox(height: 9),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGradingAnswerPanel(BuildContext context) {
    final pages = widget.gradingPages;
    if (pages.isEmpty) return const SizedBox.shrink();
    final panelWidth = widget.hideSourceDocument && _hasGradingPanel
        ? math.min(MediaQuery.of(context).size.width * 0.72, 760.0)
        : math.min(MediaQuery.of(context).size.width * 0.42, 520.0);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: panelWidth),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF121A20).withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '테스트 채점',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => setState(() {
                    _gradingPanelCollapsed = !_gradingPanelCollapsed;
                  }),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(
                      _gradingPanelCollapsed
                          ? Icons.expand_more_rounded
                          : Icons.expand_less_rounded,
                      size: 20,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ],
            ),
            if (!_gradingPanelCollapsed) ...[
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (int i = 0; i < pages.length; i++) ...[
                        _buildGradingPageRow(pages[i]),
                        if (i != pages.length - 1) ...[
                          const SizedBox(height: 10),
                          Container(
                            height: 1,
                            color: Colors.white.withValues(alpha: 0.15),
                          ),
                          const SizedBox(height: 10),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGradingPageRow(HomeworkAnswerGradingPage page) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.end,
            runAlignment: WrapAlignment.end,
            children: [
              for (final cell in page.cells) _buildGradingCellBox(cell),
            ],
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 28,
          child: RotatedBox(
            quarterTurns: 1,
            child: Text(
              'p.${page.pageNumber}',
              maxLines: 1,
              overflow: TextOverflow.visible,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Color(0xFF9FB3B3),
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGradingCellBox(HomeworkAnswerGradingCell cell) {
    final state = _gradingStateOf(cell.key);
    Color borderColor;
    Color backgroundColor;
    Color textColor;
    String text;
    switch (state) {
      case HomeworkAnswerCellState.correct:
        borderColor = const Color(0xFF3F4C4C);
        backgroundColor = const Color(0xFF1F2A2F);
        textColor = const Color(0xFFEAF2F2);
        text = _normalizeAnswerForMathRendering(cell.answer);
        break;
      case HomeworkAnswerCellState.wrong:
        borderColor = const Color(0xFFA84A4A);
        backgroundColor = const Color(0xFF3A2323);
        textColor = const Color(0xFFFFB3B3);
        text = 'X';
        break;
      case HomeworkAnswerCellState.unsolved:
        borderColor = const Color(0xFF596565);
        backgroundColor = const Color(0xFF202929);
        textColor = const Color(0xFF8FA1A1);
        text = '-';
        break;
    }
    return Tooltip(
      message: '${cell.questionIndex}번',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _toggleGradingCellState(cell.key),
        child: Container(
          constraints: const BoxConstraints(minWidth: 68, minHeight: 68),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor),
          ),
          child: Center(
            child: state == HomeworkAnswerCellState.correct
                ? LatexTextRenderer(
                    text,
                    textAlign: TextAlign.right,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    maxLines: 3,
                    softWrap: true,
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.w800,
                      fontSize: 25,
                      height: 1.0,
                    ),
                  )
                : Text(
                    text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.w800,
                      fontSize: 25,
                      height: 1.0,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _circleIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: kDlgPanelBg.withOpacity(0.92),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? () => onTap() : null,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Icon(
              icon,
              size: 36,
              color: enabled ? kDlgText : kDlgTextSub.withOpacity(0.45),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pillButton({
    required String label,
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
    bool filled = false,
  }) {
    return Material(
      color: filled ? kDlgAccent : kDlgPanelBg.withOpacity(0.92),
      shape: StadiumBorder(
        side: filled ? BorderSide.none : const BorderSide(color: kDlgBorder),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: enabled ? () => onTap() : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 28,
                color: enabled
                    ? (filled ? Colors.white : kDlgText)
                    : kDlgTextSub.withOpacity(0.45),
              ),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  color: enabled
                      ? (filled ? Colors.white : kDlgText)
                      : kDlgTextSub.withOpacity(0.45),
                  fontWeight: FontWeight.w800,
                  fontSize: 20,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
