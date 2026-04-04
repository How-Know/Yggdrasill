import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

class ProblemBankPreviewRefreshRequest {
  const ProblemBankPreviewRefreshRequest({
    required this.subjectTitleText,
    required this.pageColumnQuestionCounts,
    required this.columnLabelAnchors,
  });

  final String subjectTitleText;
  final List<Map<String, dynamic>> pageColumnQuestionCounts;
  final List<Map<String, dynamic>> columnLabelAnchors;
}

class ProblemBankPreviewRefreshResult {
  const ProblemBankPreviewRefreshResult({
    required this.pdfUrl,
    this.pageColumnQuestionCounts = const <Map<String, dynamic>>[],
    this.columnLabelAnchors = const <Map<String, dynamic>>[],
  });

  final String pdfUrl;
  final List<Map<String, dynamic>> pageColumnQuestionCounts;
  final List<Map<String, dynamic>> columnLabelAnchors;
}

typedef ProblemBankPreviewRefreshCallback
    = Future<ProblemBankPreviewRefreshResult?> Function(
  ProblemBankPreviewRefreshRequest request,
);

typedef ProblemBankPreviewGeneratePdfCallback = Future<void> Function(
  ProblemBankPreviewRefreshRequest request,
);

class ProblemBankExportServerPreviewDialog extends StatefulWidget {
  const ProblemBankExportServerPreviewDialog({
    super.key,
    required this.pdfUrl,
    required this.titleText,
    this.initialSubjectTitle = '수학 영역',
    this.layoutColumns = 1,
    this.maxQuestionsPerPage = 4,
    this.totalQuestionCount = 0,
    this.initialPageColumnQuestionCounts = const <Map<String, dynamic>>[],
    this.initialColumnLabelAnchors = const <Map<String, dynamic>>[],
    this.onRefreshRequested,
    this.onGeneratePdfRequested,
  });

  final String pdfUrl;
  final String titleText;
  final String initialSubjectTitle;
  final int layoutColumns;
  final int maxQuestionsPerPage;
  final int totalQuestionCount;
  final List<Map<String, dynamic>> initialPageColumnQuestionCounts;
  final List<Map<String, dynamic>> initialColumnLabelAnchors;
  final ProblemBankPreviewRefreshCallback? onRefreshRequested;
  final ProblemBankPreviewGeneratePdfCallback? onGeneratePdfRequested;

  static Future<void> open(
    BuildContext context, {
    required String pdfUrl,
    String titleText = '서버 PDF 미리보기',
    String initialSubjectTitle = '수학 영역',
    int layoutColumns = 1,
    int maxQuestionsPerPage = 4,
    int totalQuestionCount = 0,
    List<Map<String, dynamic>> initialPageColumnQuestionCounts =
        const <Map<String, dynamic>>[],
    List<Map<String, dynamic>> initialColumnLabelAnchors =
        const <Map<String, dynamic>>[],
    ProblemBankPreviewRefreshCallback? onRefreshRequested,
    ProblemBankPreviewGeneratePdfCallback? onGeneratePdfRequested,
  }) async {
    final size = MediaQuery.sizeOf(context);
    final maxWidth = (size.width - 24).clamp(1180.0, 2320.0).toDouble();
    final maxHeight = (size.height * 0.8).clamp(640.0, 1280.0).toDouble();
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: const Color(0xFF10171A),
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: maxHeight,
              minWidth: 1040,
              minHeight: 620,
            ),
            child: ProblemBankExportServerPreviewDialog(
              pdfUrl: pdfUrl,
              titleText: titleText,
              initialSubjectTitle: initialSubjectTitle,
              layoutColumns: layoutColumns,
              maxQuestionsPerPage: maxQuestionsPerPage,
              totalQuestionCount: totalQuestionCount,
              initialPageColumnQuestionCounts: initialPageColumnQuestionCounts,
              initialColumnLabelAnchors: initialColumnLabelAnchors,
              onRefreshRequested: onRefreshRequested,
              onGeneratePdfRequested: onGeneratePdfRequested,
            ),
          ),
        );
      },
    );
  }

  @override
  State<ProblemBankExportServerPreviewDialog> createState() =>
      _ProblemBankExportServerPreviewDialogState();
}

class _ProblemBankExportServerPreviewDialogState
    extends State<ProblemBankExportServerPreviewDialog> {
  static const double _minScale = 0.2;
  static const double _maxScale = 8;
  static const Color _panelBg = Color(0xFF151C21);
  static const Color _panelSectionBg = Color(0xFF10171A);
  static const Color _panelBorder = Color(0xFF223131);
  static const Color _textPrimary = Color(0xFFEAF2F2);
  static const Color _textMuted = Color(0xFF9FB3B3);
  static const Color _accent = Color(0xFF33A373);
  static const double _firstPageAnchorTopPt = 16.0;
  static const double _firstPageAnchorPaddingTopPt = 27.0;
  static const double _otherPageAnchorTopPt = 9.2;
  static const double _otherPageAnchorPaddingTopPt = 35.8;

  final PdfViewerController _viewerController = PdfViewerController();
  late final TextEditingController _subjectController;

  late String _currentPdfUrl;
  int _pageNumber = 1;
  int _pageCount = 0;
  double? _fitZoom;
  int _viewerRevision = 0;
  bool _isRefreshing = false;
  bool _isGeneratingPdf = false;
  late Map<int, List<int>> _pageOverrides;
  late List<List<int>> _computedPageColumnCounts;
  late Map<String, Map<String, dynamic>> _columnLabelAnchorMap;
  final Map<String, TextEditingController> _labelControllers =
      <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _currentPdfUrl = widget.pdfUrl;
    _subjectController =
        TextEditingController(text: widget.initialSubjectTitle);
    _pageOverrides = _readInitialPageOverrides();
    _computedPageColumnCounts = _recomputePageColumnCounts();
    _columnLabelAnchorMap = _readInitialColumnLabelAnchors();
  }

  @override
  void dispose() {
    for (final controller in _labelControllers.values) {
      controller.dispose();
    }
    _subjectController.dispose();
    super.dispose();
  }

  bool get _isTwoColumnLayout => widget.layoutColumns == 2;

  List<int> get _baseColumnCounts {
    if (!_isTwoColumnLayout) return const <int>[1, 0];
    final safePerPage =
        widget.maxQuestionsPerPage <= 0 ? 4 : widget.maxQuestionsPerPage;
    final left = (safePerPage / 2).ceil();
    final right = math.max(0, safePerPage - left);
    return <int>[left, right];
  }

  Map<int, List<int>> _parsePageOverrides(
    List<Map<String, dynamic>> source,
  ) {
    if (!_isTwoColumnLayout) return <int, List<int>>{};
    final out = <int, List<int>>{};
    for (final one in source) {
      final pageRaw = int.tryParse(
        '${one['pageIndex'] ?? one['page'] ?? one['pageNo'] ?? one['pageNumber'] ?? ''}',
      );
      final leftRaw = int.tryParse(
          '${one['left'] ?? one['leftCount'] ?? one['col1'] ?? ''}');
      final rightRaw = int.tryParse(
          '${one['right'] ?? one['rightCount'] ?? one['col2'] ?? ''}');
      if (leftRaw == null || rightRaw == null) continue;
      if (leftRaw < 0 || rightRaw < 0) continue;
      if (leftRaw + rightRaw <= 0) continue;
      final pageIndex = pageRaw == null ? out.length : math.max(0, pageRaw - 1);
      out[pageIndex] = <int>[leftRaw, rightRaw];
    }
    return out;
  }

  Map<int, List<int>> _readInitialPageOverrides() {
    return _parsePageOverrides(widget.initialPageColumnQuestionCounts);
  }

  String _anchorKey(int pageIndex, int columnIndex) =>
      '${pageIndex + 1}:$columnIndex';

  int? _parseAnchorPageIndex(dynamic raw) {
    final text = '$raw'.trim().toLowerCase();
    if (text.isEmpty || text == 'first') return 0;
    if (text == 'all') return 0;
    final parsed = int.tryParse(text);
    if (parsed == null || parsed <= 0) return null;
    return parsed - 1;
  }

  double _defaultAnchorTopForPage(int pageIndex) {
    return pageIndex == 0 ? _firstPageAnchorTopPt : _otherPageAnchorTopPt;
  }

  double _defaultAnchorPaddingForPage(int pageIndex) {
    return pageIndex == 0
        ? _firstPageAnchorPaddingTopPt
        : _otherPageAnchorPaddingTopPt;
  }

  Map<String, Map<String, dynamic>> _parseColumnLabelAnchors(
    List<Map<String, dynamic>> source,
  ) {
    if (!_isTwoColumnLayout) return <String, Map<String, dynamic>>{};
    final out = <String, Map<String, dynamic>>{};
    for (final one in source) {
      final pageIndex = _parseAnchorPageIndex(
        one['page'] ?? one['pageIndex'] ?? one['pageNo'] ?? one['pageNumber'],
      );
      final columnIndex = int.tryParse(
        '${one['columnIndex'] ?? one['column'] ?? one['col'] ?? ''}',
      );
      final label = '${one['label'] ?? one['text'] ?? ''}'
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (pageIndex == null) continue;
      if (columnIndex == null || columnIndex < 0 || columnIndex > 1) continue;
      if (label.isEmpty) continue;
      final defaultTop = _defaultAnchorTopForPage(pageIndex);
      final defaultPadding = _defaultAnchorPaddingForPage(pageIndex);
      var topPt =
          (one['topPt'] is num) ? (one['topPt'] as num).toDouble() : defaultTop;
      var paddingTopPt = (one['paddingTopPt'] is num)
          ? (one['paddingTopPt'] as num).toDouble()
          : defaultPadding;
      // Migrate older defaults and recent transient baselines on page 2+.
      final isLegacyOld =
          (topPt - 8.0).abs() < 0.01 && (paddingTopPt - 46.0).abs() < 0.01;
      final isLegacyRecentWrong = pageIndex > 0 &&
          (topPt - _firstPageAnchorTopPt).abs() < 0.01 &&
          (paddingTopPt - _firstPageAnchorPaddingTopPt).abs() < 0.01;
      final isLegacyLargeGap = pageIndex > 0 &&
          (topPt - 18.0).abs() < 0.01 &&
          (paddingTopPt - 58.0).abs() < 0.01;
      if (isLegacyOld || isLegacyRecentWrong || isLegacyLargeGap) {
        topPt = defaultTop;
        paddingTopPt = defaultPadding;
      }
      out[_anchorKey(pageIndex, columnIndex)] = <String, dynamic>{
        'page': pageIndex + 1,
        'columnIndex': columnIndex,
        'label': label,
        'topPt': topPt,
        'paddingTopPt': paddingTopPt,
      };
    }
    final firstLeftKey = _anchorKey(0, 0);
    out.putIfAbsent(
        firstLeftKey,
        () => <String, dynamic>{
              'page': 1,
              'columnIndex': 0,
              'label': '5지선다형',
              'topPt': _firstPageAnchorTopPt,
              'paddingTopPt': _firstPageAnchorPaddingTopPt,
            });
    return out;
  }

  Map<String, Map<String, dynamic>> _readInitialColumnLabelAnchors() {
    return _parseColumnLabelAnchors(widget.initialColumnLabelAnchors);
  }

  TextEditingController _controllerForAnchor({
    required int pageIndex,
    required int columnIndex,
  }) {
    final key = _anchorKey(pageIndex, columnIndex);
    final existing = _labelControllers[key];
    if (existing != null) return existing;
    final initial = '${_columnLabelAnchorMap[key]?['label'] ?? ''}'.trim();
    final controller = TextEditingController(text: initial);
    _labelControllers[key] = controller;
    return controller;
  }

  void _setAnchorLabel({
    required int pageIndex,
    required int columnIndex,
    required String rawLabel,
  }) {
    final key = _anchorKey(pageIndex, columnIndex);
    final label = rawLabel.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (label.isEmpty) {
      _columnLabelAnchorMap.remove(key);
      return;
    }
    final prev = _columnLabelAnchorMap[key];
    _columnLabelAnchorMap[key] = <String, dynamic>{
      'page': pageIndex + 1,
      'columnIndex': columnIndex,
      'label': label,
      'topPt': prev?['topPt'] ?? _defaultAnchorTopForPage(pageIndex),
      'paddingTopPt':
          prev?['paddingTopPt'] ?? _defaultAnchorPaddingForPage(pageIndex),
    };
  }

  void _addDefaultAnchor({
    required int pageIndex,
    required int columnIndex,
  }) {
    final controller =
        _controllerForAnchor(pageIndex: pageIndex, columnIndex: columnIndex);
    controller.text = '5지선다형';
    _setAnchorLabel(
      pageIndex: pageIndex,
      columnIndex: columnIndex,
      rawLabel: controller.text,
    );
    setState(() {});
  }

  List<Map<String, dynamic>> _columnLabelAnchorsPayload() {
    if (!_isTwoColumnLayout || _columnLabelAnchorMap.isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    final maxPage = _computedPageColumnCounts.length;
    return _columnLabelAnchorMap.values
        .where((row) {
          final page = int.tryParse('${row['page'] ?? 0}') ?? 0;
          final col = int.tryParse('${row['columnIndex'] ?? -1}') ?? -1;
          return page >= 1 && page <= maxPage && col >= 0 && col <= 1;
        })
        .map((row) => <String, dynamic>{
              'columnIndex': row['columnIndex'],
              'label': row['label'],
              'page': row['page'],
              'topPt': row['topPt'],
              'paddingTopPt': row['paddingTopPt'],
            })
        .toList(growable: false)
      ..sort((a, b) {
        final pageA = int.tryParse('${a['page'] ?? 0}') ?? 0;
        final pageB = int.tryParse('${b['page'] ?? 0}') ?? 0;
        if (pageA != pageB) return pageA.compareTo(pageB);
        final colA = int.tryParse('${a['columnIndex'] ?? 0}') ?? 0;
        final colB = int.tryParse('${b['columnIndex'] ?? 0}') ?? 0;
        return colA.compareTo(colB);
      });
  }

  List<List<int>> _recomputePageColumnCounts() {
    if (!_isTwoColumnLayout) return const <List<int>>[];
    final totalQuestions = math.max(0, widget.totalQuestionCount);
    if (totalQuestions <= 0) return const <List<int>>[];
    final base = _baseColumnCounts;
    var remaining = totalQuestions;
    var pageIndex = 0;
    final pages = <List<int>>[];
    while (remaining > 0) {
      final override = _pageOverrides[pageIndex];
      var left = override != null ? override[0] : base[0];
      var right = override != null ? override[1] : base[1];
      if (left < 0) left = 0;
      if (right < 0) right = 0;
      if (left + right <= 0) {
        left = 1;
        right = 0;
      }
      final assignedLeft = math.min(left, remaining);
      remaining -= assignedLeft;
      final assignedRight = math.min(right, remaining);
      remaining -= assignedRight;
      pages.add(<int>[assignedLeft, assignedRight]);
      pageIndex += 1;
    }
    return pages;
  }

  void _applyPageColumnDelta({
    required int pageIndex,
    required bool isLeft,
    required int delta,
  }) {
    if (!_isTwoColumnLayout || delta == 0) return;
    final pages = _computedPageColumnCounts.isEmpty
        ? _recomputePageColumnCounts()
        : _computedPageColumnCounts;
    if (pageIndex < 0 || pageIndex >= pages.length) return;
    final current = pages[pageIndex];
    var left = current[0];
    var right = current[1];
    if (isLeft) {
      left = math.max(0, left + delta);
    } else {
      right = math.max(0, right + delta);
    }
    if (left + right <= 0) {
      if (isLeft) {
        left = 1;
      } else {
        right = 1;
      }
    }
    _pageOverrides[pageIndex] = <int>[left, right];
    setState(() {
      _computedPageColumnCounts = _recomputePageColumnCounts();
    });
  }

  List<Map<String, dynamic>> _pageColumnPayload() {
    if (!_isTwoColumnLayout || _computedPageColumnCounts.isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    return _computedPageColumnCounts
        .asMap()
        .entries
        .map((entry) {
          final counts = entry.value;
          return <String, dynamic>{
            'pageIndex': entry.key + 1,
            'left': counts[0],
            'right': counts[1],
          };
        })
        .where((row) => (row['left'] as int) + (row['right'] as int) > 0)
        .toList(growable: false);
  }

  ProblemBankPreviewRefreshRequest _buildRequestPayload() {
    return ProblemBankPreviewRefreshRequest(
      subjectTitleText: _subjectController.text.trim(),
      pageColumnQuestionCounts: _pageColumnPayload(),
      columnLabelAnchors: _columnLabelAnchorsPayload(),
    );
  }

  PdfPageLayout _layoutTwoPageVertical(
      List<PdfPage> pages, PdfViewerParams params) {
    if (pages.isEmpty) {
      return PdfPageLayout(
          pageLayouts: const <Rect>[], documentSize: Size.zero);
    }
    const colGap = 20.0;
    const rowGap = 24.0;
    final rowWidths = <double>[];
    for (var i = 0; i < pages.length; i += 2) {
      final left = pages[i];
      final right = (i + 1) < pages.length ? pages[i + 1] : null;
      final width =
          right == null ? left.width : left.width + colGap + right.width;
      rowWidths.add(width);
    }
    final maxRowWidth = rowWidths.fold<double>(0, (acc, w) => math.max(acc, w));
    final totalWidth = maxRowWidth + params.margin * 2;
    final layouts = <Rect>[];
    var y = params.margin;
    for (var i = 0; i < pages.length; i += 2) {
      final left = pages[i];
      final right = (i + 1) < pages.length ? pages[i + 1] : null;
      final rowWidth =
          right == null ? left.width : left.width + colGap + right.width;
      final startX = (totalWidth - rowWidth) / 2;
      layouts.add(Rect.fromLTWH(startX, y, left.width, left.height));
      if (right != null) {
        layouts.add(Rect.fromLTWH(
            startX + left.width + colGap, y, right.width, right.height));
      }
      final rowHeight = math.max(left.height, right?.height ?? 0);
      y += rowHeight + rowGap;
    }
    return PdfPageLayout(
      pageLayouts: layouts,
      documentSize: Size(totalWidth, y + params.margin),
    );
  }

  Future<void> _zoomByFactor(double factor) async {
    if (!_viewerController.isReady) return;
    final current = _viewerController.currentZoom;
    final target = (current * factor).clamp(_minScale, _maxScale).toDouble();
    final center = _viewerController.centerPosition;
    final matrix = _viewerController.calcMatrixFor(center, zoom: target);
    await _viewerController.goTo(
      matrix,
      duration: const Duration(milliseconds: 110),
    );
    if (mounted) setState(() {});
  }

  Future<void> _resetZoomToFit() async {
    if (!_viewerController.isReady) return;
    final target = (_fitZoom ?? 1.0).clamp(_minScale, _maxScale).toDouble();
    final center = _viewerController.centerPosition;
    final matrix = _viewerController.calcMatrixFor(center, zoom: target);
    await _viewerController.goTo(
      matrix,
      duration: const Duration(milliseconds: 120),
    );
    if (mounted) setState(() {});
  }

  Future<void> _refreshPreview() async {
    final callback = widget.onRefreshRequested;
    if (callback == null || _isRefreshing) return;
    setState(() {
      _isRefreshing = true;
    });
    try {
      final refreshed = await callback(_buildRequestPayload());
      if (!mounted) return;
      if (refreshed == null || refreshed.pdfUrl.trim().isEmpty) return;
      setState(() {
        _currentPdfUrl = refreshed.pdfUrl.trim();
        _fitZoom = null;
        _pageNumber = 1;
        _pageCount = 0;
        _viewerRevision += 1;
        if (_isTwoColumnLayout) {
          _pageOverrides =
              _parsePageOverrides(refreshed.pageColumnQuestionCounts);
          _computedPageColumnCounts = _recomputePageColumnCounts();
          _columnLabelAnchorMap =
              _parseColumnLabelAnchors(refreshed.columnLabelAnchors);
          for (final entry in _labelControllers.entries) {
            final updated =
                '${_columnLabelAnchorMap[entry.key]?['label'] ?? ''}'.trim();
            if (entry.value.text != updated) {
              entry.value.text = updated;
            }
          }
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
    }
  }

  Future<void> _generatePdf() async {
    final callback = widget.onGeneratePdfRequested;
    if (callback == null || _isGeneratingPdf || _isRefreshing) return;
    setState(() {
      _isGeneratingPdf = true;
    });
    try {
      await callback(_buildRequestPayload());
    } finally {
      if (mounted) {
        setState(() {
          _isGeneratingPdf = false;
        });
      }
    }
  }

  Widget _buildSectionCard({
    required String title,
    required Widget child,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: _textPrimary,
              fontSize: 13.4,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          child,
          const SizedBox(height: 10),
          const Divider(height: 1, color: Color(0xFF213037)),
        ],
      ),
    );
  }

  Widget _buildColumnStepper({
    required String label,
    required int value,
    required VoidCallback onIncrease,
    required VoidCallback onDecrease,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF0C1418),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF213037)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: _textMuted,
                fontSize: 11.4,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                IconButton(
                  onPressed: onDecrease,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  color: _textMuted,
                  tooltip: '감소',
                ),
                Expanded(
                  child: Text(
                    '$value',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: _textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onIncrease,
                  icon: const Icon(Icons.keyboard_arrow_up_rounded),
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  color: _textMuted,
                  tooltip: '증가',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnchorEditor({
    required int pageIndex,
    required int columnIndex,
    required String title,
  }) {
    final key = _anchorKey(pageIndex, columnIndex);
    final hasAnchor = _columnLabelAnchorMap.containsKey(key);
    if (!hasAnchor) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
        decoration: BoxDecoration(
          color: const Color(0xFF0C1418),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF213037)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$title 라벨 없음',
                style: const TextStyle(
                  color: _textMuted,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              onPressed: () => _addDefaultAnchor(
                pageIndex: pageIndex,
                columnIndex: columnIndex,
              ),
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              tooltip: '5지선다형 라벨 추가',
              color: _textPrimary,
              icon: const Icon(Icons.add_circle_outline_rounded),
            ),
          ],
        ),
      );
    }
    final controller = _controllerForAnchor(
      pageIndex: pageIndex,
      columnIndex: columnIndex,
    );
    return TextField(
      controller: controller,
      style: const TextStyle(
        color: _textPrimary,
        fontSize: 12.4,
        fontWeight: FontWeight.w700,
      ),
      cursorColor: _textPrimary,
      onChanged: (value) {
        _setAnchorLabel(
          pageIndex: pageIndex,
          columnIndex: columnIndex,
          rawLabel: value,
        );
      },
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF0C1418),
        labelText: '$title 라벨',
        labelStyle: const TextStyle(
          color: _textMuted,
          fontSize: 11.8,
          fontWeight: FontWeight.w700,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF213037)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _accent, width: 1.1),
        ),
        suffixIcon: IconButton(
          onPressed: () {
            controller.clear();
            _setAnchorLabel(
              pageIndex: pageIndex,
              columnIndex: columnIndex,
              rawLabel: '',
            );
            setState(() {});
          },
          icon: const Icon(Icons.close_rounded, size: 16),
          tooltip: '라벨 제거',
          color: _textMuted,
        ),
      ),
    );
  }

  Widget _buildPageLayoutCards() {
    if (!_isTwoColumnLayout) {
      return const Text(
        '2단 레이아웃에서만 페이지별 좌/우 문항 수를 수정할 수 있습니다.',
        style: TextStyle(
          color: Color(0xFF9FB3B3),
          fontSize: 12.2,
          fontWeight: FontWeight.w600,
          height: 1.35,
        ),
      );
    }
    if (_computedPageColumnCounts.isEmpty) {
      return const Text(
        '선택된 문항이 없어 페이지 카드가 표시되지 않습니다.',
        style: TextStyle(
          color: Color(0xFF9FB3B3),
          fontSize: 12.2,
          fontWeight: FontWeight.w600,
          height: 1.35,
        ),
      );
    }
    return Column(
      children: [
        const Text(
          '자동 배치 결과를 기준으로 페이지별 좌/우 문항 수를 조정합니다. 값 변경 시 뒤 페이지가 자동 재배치되며, 단별 라벨(5지선다형)도 편집할 수 있습니다.',
          style: TextStyle(
            color: Color(0xFF8DA3A6),
            fontSize: 11.4,
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 8),
        ..._computedPageColumnCounts.asMap().entries.map((entry) {
          final index = entry.key;
          final counts = entry.value;
          final left = counts[0];
          final right = counts[1];
          return Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(9, 8, 9, 9),
            decoration: BoxDecoration(
              color: const Color(0xFF0D161A),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: const Color(0xFF203038)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${index + 1}페이지',
                  style: const TextStyle(
                    color: _textPrimary,
                    fontSize: 12.4,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _buildColumnStepper(
                      label: '왼쪽 단',
                      value: left,
                      onIncrease: () => _applyPageColumnDelta(
                        pageIndex: index,
                        isLeft: true,
                        delta: 1,
                      ),
                      onDecrease: () => _applyPageColumnDelta(
                        pageIndex: index,
                        isLeft: true,
                        delta: -1,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _buildColumnStepper(
                      label: '오른쪽 단',
                      value: right,
                      onIncrease: () => _applyPageColumnDelta(
                        pageIndex: index,
                        isLeft: false,
                        delta: 1,
                      ),
                      onDecrease: () => _applyPageColumnDelta(
                        pageIndex: index,
                        isLeft: false,
                        delta: -1,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _buildAnchorEditor(
                  pageIndex: index,
                  columnIndex: 0,
                  title: '왼쪽 단',
                ),
                const SizedBox(height: 6),
                _buildAnchorEditor(
                  pageIndex: index,
                  columnIndex: 1,
                  title: '오른쪽 단',
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(_currentPdfUrl.trim());
    final zoomPercent = _viewerController.isReady
        ? (_viewerController.currentZoom * 100).round()
        : 100;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.titleText,
                        style: const TextStyle(
                          color: Color(0xFFEAF2F2),
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: '닫기',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, color: Color(0xFF9FB3B3)),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF151E24),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: const Color(0xFF223131)),
                      ),
                      child: Text(
                        _pageCount > 0 ? '$_pageNumber / $_pageCount' : '- / -',
                        style: const TextStyle(
                          color: Color(0xFF9FB3B3),
                          fontSize: 12.4,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '축소',
                      onPressed: () => _zoomByFactor(0.85),
                      icon: const Icon(Icons.remove, color: Color(0xFF9FB3B3)),
                    ),
                    Text(
                      '$zoomPercent%',
                      style: const TextStyle(
                        color: Color(0xFF9FB3B3),
                        fontSize: 12.6,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    IconButton(
                      tooltip: '확대',
                      onPressed: () => _zoomByFactor(1.15),
                      icon: const Icon(Icons.add, color: Color(0xFF9FB3B3)),
                    ),
                    IconButton(
                      tooltip: '화면 맞춤',
                      onPressed: _resetZoomToFit,
                      icon: const Icon(
                        Icons.fit_screen_rounded,
                        color: Color(0xFF9FB3B3),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      color: const Color(0xFF0B1112),
                      child: uri == null
                          ? const Center(
                              child: Text(
                                '유효한 PDF URL이 아닙니다.',
                                style: TextStyle(
                                  color: Color(0xFF9FB3B3),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            )
                          : PdfViewer.uri(
                              uri,
                              key: ValueKey(
                                  'preview_${_viewerRevision}_${uri.toString()}'),
                              controller: _viewerController,
                              params: PdfViewerParams(
                                backgroundColor: const Color(0xFF0B1112),
                                margin: 10,
                                layoutPages: _layoutTwoPageVertical,
                                pageAnchor: PdfPageAnchor.center,
                                pageAnchorEnd: PdfPageAnchor.center,
                                panEnabled: true,
                                scaleEnabled: true,
                                panAxis: PanAxis.free,
                                pageDropShadow: null,
                                maxScale: _maxScale,
                                minScale: _minScale,
                                useAlternativeFitScaleAsMinScale: false,
                                calculateInitialZoom: (
                                  document,
                                  controller,
                                  fitZoom,
                                  coverZoom,
                                ) {
                                  _fitZoom ??= fitZoom;
                                  return fitZoom;
                                },
                                onViewerReady: (document, controller) {
                                  if (!mounted) return;
                                  setState(() {
                                    _pageCount = document.pages.length;
                                    _pageNumber = (controller.pageNumber ?? 1)
                                        .clamp(1, 9999);
                                  });
                                },
                                onPageChanged: (page) {
                                  if (!mounted || page == null) return;
                                  setState(() {
                                    _pageNumber = page;
                                  });
                                },
                                loadingBannerBuilder: (
                                  context,
                                  bytesDownloaded,
                                  totalBytes,
                                ) {
                                  return const Center(
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  );
                                },
                                errorBannerBuilder: (
                                  context,
                                  error,
                                  stackTrace,
                                  documentRef,
                                ) {
                                  return Center(
                                    child: Text(
                                      '미리보기 PDF를 열 수 없습니다: $error',
                                      style: const TextStyle(
                                        color: Color(0xFF9FB3B3),
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 360,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              decoration: BoxDecoration(
                color: _panelBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _panelBorder),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '설정',
                          style: TextStyle(
                            color: Color(0xFFEAF2F2),
                            fontSize: 14.2,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _isRefreshing ? null : _refreshPreview,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1C2A31),
                          foregroundColor: _textPrimary,
                          disabledBackgroundColor: const Color(0xFF172026),
                          disabledForegroundColor: _textMuted,
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: _isRefreshing
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh_rounded, size: 16),
                        label: const Text('새로고침'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          _buildSectionCard(
                            title: '타이틀',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TextField(
                                  controller: _subjectController,
                                  style: const TextStyle(
                                    color: _textPrimary,
                                    fontSize: 13.2,
                                    fontWeight: FontWeight.w700,
                                  ),
                                  cursorColor: _textPrimary,
                                  decoration: InputDecoration(
                                    isDense: true,
                                    filled: true,
                                    fillColor: _panelSectionBg,
                                    hintText: '예: 수학 영역',
                                    hintStyle: const TextStyle(
                                      color: Color(0xFF5F787C),
                                      fontSize: 12.6,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    labelText: '중앙 타이틀',
                                    labelStyle: const TextStyle(
                                      color: _textMuted,
                                      fontSize: 12.4,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(
                                        color: _panelBorder,
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(
                                        color: _accent,
                                        width: 1.2,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  '입력값은 첫 페이지/이후 페이지 중앙 타이틀에 반영됩니다.',
                                  style: TextStyle(
                                    color: Color(0xFF8DA3A6),
                                    fontSize: 11.6,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          _buildSectionCard(
                            title: '문제와 답안',
                            child: const Text(
                              '문항/답안 표시 방식은 현재 문제은행 설정을 사용합니다.',
                              style: TextStyle(
                                color: Color(0xFF9FB3B3),
                                fontSize: 12.2,
                                fontWeight: FontWeight.w600,
                                height: 1.35,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          _buildSectionCard(
                            title: '레이아웃',
                            child: _buildPageLayoutCards(),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: (widget.onGeneratePdfRequested == null ||
                              _isGeneratingPdf ||
                              _isRefreshing)
                          ? null
                          : _generatePdf,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF173C36),
                        foregroundColor: const Color(0xFFC7F2D8),
                        disabledBackgroundColor: const Color(0xFF152A27),
                        disabledForegroundColor: const Color(0xFF7CA39A),
                        minimumSize: const Size.fromHeight(42),
                        shape: const StadiumBorder(),
                      ),
                      icon: _isGeneratingPdf
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.picture_as_pdf, size: 18),
                      label: const Text(
                        'PDF 생성',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
