import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../services/textbook_pdf_service.dart';
import '../dialog_tokens.dart';
import 'textbook_problem_region.dart';

/// Opens the in-app textbook viewer as a full-screen page. The viewer asks
/// [TextbookPdfService] to resolve the ref into a local file (preferred) or
/// a URL (legacy / remote fallback) and then renders it with `pdfrx`.
///
/// Pass [problemRegions] (optionally with [tapDetectionMode] left at its
/// default `true`) to enable the problem-region overlay: the viewer then
/// draws translucent tap targets for every VLM-detected region on each
/// page and surfaces a `pN · 47번` badge when the user taps one.
///
/// SECURITY TODO (pre-release):
/// - Wrap the viewer in a watermark overlay (slot added below).
/// - Toggle Android `FLAG_SECURE` when entering this page.
Future<void> openTextbookViewerDialog(
  BuildContext context, {
  required TextbookPdfRef ref,
  required String title,
  String? cacheKey,
  int? initialPage,
  List<TextbookProblemRegion>? problemRegions,
  bool tapDetectionMode = true,
}) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => TextbookViewerPage(
        ref: ref,
        title: title,
        cacheKey: cacheKey,
        initialPage: initialPage,
        problemRegions: problemRegions,
        tapDetectionMode: tapDetectionMode,
      ),
    ),
  );
}

class TextbookViewerPage extends StatefulWidget {
  const TextbookViewerPage({
    super.key,
    required this.ref,
    required this.title,
    this.cacheKey,
    this.initialPage,
    this.problemRegions,
    this.tapDetectionMode = false,
  });

  final TextbookPdfRef ref;
  final String title;
  final String? cacheKey;
  final int? initialPage;

  /// When non-null and [tapDetectionMode] is true, the viewer overlays a
  /// thin outline + tap target per region so the operator can verify the
  /// VLM detections by tapping directly on the PDF.
  final List<TextbookProblemRegion>? problemRegions;
  final bool tapDetectionMode;

  @override
  State<TextbookViewerPage> createState() => _TextbookViewerPageState();
}

class _TextbookViewerPageState extends State<TextbookViewerPage> {
  final PdfViewerController _controller = PdfViewerController();
  TextbookPdfSource? _source;
  Object? _error;
  int _downloadedBytes = 0;
  int _totalBytes = 0;
  bool _loading = true;
  int _pageNumber = 1;
  int _pageCount = 0;
  bool _chromeVisible = true;

  /// Regions indexed by raw page number — built once in initState so the
  /// pageOverlaysBuilder callback (invoked on every repaint) stays O(1).
  late final Map<int, List<TextbookProblemRegion>> _regionsByPage;
  TextbookProblemRegion? _lastTappedRegion;
  DateTime? _lastTapAt;

  bool get _hasRegions =>
      widget.tapDetectionMode &&
      widget.problemRegions != null &&
      widget.problemRegions!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _pageNumber = widget.initialPage ?? 1;
    _regionsByPage = _groupRegions(widget.problemRegions);
    unawaited(_resolve());
  }

  static Map<int, List<TextbookProblemRegion>> _groupRegions(
    List<TextbookProblemRegion>? regions,
  ) {
    final out = <int, List<TextbookProblemRegion>>{};
    if (regions == null) return out;
    for (final r in regions) {
      out.putIfAbsent(r.rawPage, () => <TextbookProblemRegion>[]).add(r);
    }
    return out;
  }

  void _onRegionTapped(TextbookProblemRegion region) {
    setState(() {
      _lastTappedRegion = region;
      _lastTapAt = DateTime.now();
    });
  }

  Future<void> _resolve() async {
    try {
      final resolved = await TextbookPdfService.instance.resolve(
        widget.ref,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _downloadedBytes = received;
            _totalBytes = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _source = resolved;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    double value = bytes.toDouble();
    int unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit += 1;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  Widget _buildLoading() {
    final double? progress =
        _totalBytes > 0 ? (_downloadedBytes / _totalBytes) : null;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 220,
            child: LinearProgressIndicator(
              value: progress,
              color: kDlgAccent,
              backgroundColor: kDlgBorder,
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            _totalBytes > 0
                ? 'PDF 불러오는 중 · ${_formatBytes(_downloadedBytes)} / ${_formatBytes(_totalBytes)}'
                : 'PDF 불러오는 중...',
            style: const TextStyle(
              color: kDlgTextSub,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '최초 1회 다운로드 후에는 기기 안에서 바로 열립니다.',
            style: TextStyle(color: kDlgTextSub, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Text(
          'PDF를 열 수 없습니다.\n\n${_error ?? ''}',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: kDlgTextSub,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  PdfViewerParams _viewerParams() {
    return PdfViewerParams(
      backgroundColor: kDlgBg,
      margin: 8,
      pageAnchor: PdfPageAnchor.center,
      onViewerReady: (document, controller) {
        if (!mounted) return;
        setState(() {
          _pageCount = document.pages.length;
        });
      },
      onPageChanged: (page) {
        if (!mounted || page == null) return;
        setState(() => _pageNumber = page);
      },
      // Per-page overlay: pdfrx places the widgets we return into a Stack
      // whose size matches the drawn page. So we can use `Positioned`
      // with local coordinates (0,0 = page top-left) to drop a tap target
      // on every VLM-detected region. The rect scales naturally when the
      // user pinch-zooms because `pageRect.size` tracks the visible page.
      pageOverlaysBuilder: _hasRegions
          ? (context, pageRect, page) {
              final regions = _regionsByPage[page.pageNumber];
              if (regions == null || regions.isEmpty) {
                return const <Widget>[];
              }
              final w = pageRect.width;
              final h = pageRect.height;
              return regions
                  .map((r) => _RegionOverlay(
                        region: r,
                        left: w * r.xminFraction,
                        top: h * r.yminFraction,
                        width: w * (r.xmaxFraction - r.xminFraction),
                        height: h * (r.ymaxFraction - r.yminFraction),
                        highlighted: identical(_lastTappedRegion, r),
                        onTap: () => _onRegionTapped(r),
                      ))
                  .toList(growable: false);
            }
          : null,
      loadingBannerBuilder: (context, downloaded, total) {
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

  Widget _buildViewer() {
    final source = _source;
    if (source == null) return const SizedBox.shrink();
    switch (source.type) {
      case TextbookPdfSourceType.localFile:
        final path = source.localPath ?? '';
        if (path.isEmpty) return _buildError();
        return PdfViewer.file(
          path,
          controller: _controller,
          params: _viewerParams(),
          initialPageNumber: _pageNumber,
        );
      case TextbookPdfSourceType.legacyUrl:
      case TextbookPdfSourceType.remoteUrl:
        final url = source.url ?? '';
        final uri = Uri.tryParse(url);
        if (url.isEmpty || uri == null) return _buildError();
        return PdfViewer.uri(
          uri,
          controller: _controller,
          params: _viewerParams(),
          initialPageNumber: _pageNumber,
        );
    }
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
    final canPrev = !_loading && _source != null && _pageNumber > 1;
    final canNext = !_loading && _source != null && _pageNumber < _pageCount;
    // When tap-detection is armed, a background tap toggling chrome would
    // fight with the region tap targets (the outer GestureDetector wins on
    // HitTestBehavior.opaque). Use a translucent detector so taps inside a
    // region bubble up to the overlay; background taps still toggle chrome
    // because the overlay only catches the region rects.
    final tapBehavior = _hasRegions
        ? HitTestBehavior.translucent
        : HitTestBehavior.opaque;
    return Scaffold(
      backgroundColor: kDlgBg,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: tapBehavior,
                onTap: () {
                  if (!mounted) return;
                  setState(() => _chromeVisible = !_chromeVisible);
                },
                child: ColoredBox(
                  color: kDlgBg,
                  child: _loading
                      ? _buildLoading()
                      : (_error != null ? _buildError() : _buildViewer()),
                ),
              ),
            ),
            // SECURITY TODO (pre-release): render a watermark overlay here.
            //   Positioned.fill(
            //     child: IgnorePointer(
            //       child: RepaintBoundary(
            //         child: TextbookWatermarkOverlay(
            //           userLabel: AuthService.instance.currentUserLabel,
            //           deviceId: DeviceInfo.instance.stableId,
            //         ),
            //       ),
            //     ),
            //   ),
            // Also call `SecureWindow.enableFlagSecure()` in `initState` and
            // `SecureWindow.disableFlagSecure()` in `dispose` to block screen
            // capture on Android during textbook viewing.
            if (_chromeVisible)
              Positioned(
                left: 8,
                top: 8,
                right: 8,
                child: Row(
                  children: [
                    _CircleIconButton(
                      icon: Icons.arrow_back_rounded,
                      tooltip: '뒤로가기',
                      onTap: () => Navigator.of(context).pop(),
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
                    if (_source != null) _buildSourceBadge(_source!),
                  ],
                ),
              ),
            if (_chromeVisible && _pageCount > 0)
              Positioned(
                right: 16,
                bottom: 16,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _CircleIconButton(
                      icon: Icons.chevron_left_rounded,
                      tooltip: '이전 페이지',
                      onTap: () => unawaited(_goPrev()),
                      enabled: canPrev,
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: kDlgPanelBg.withOpacity(0.92),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: kDlgBorder),
                      ),
                      child: Text(
                        '$_pageNumber / $_pageCount',
                        style: const TextStyle(
                          color: kDlgTextSub,
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _CircleIconButton(
                      icon: Icons.chevron_right_rounded,
                      tooltip: '다음 페이지',
                      onTap: () => unawaited(_goNext()),
                      enabled: canNext,
                    ),
                  ],
                ),
              ),
            if (_hasRegions && _chromeVisible && _pageCount > 0)
              Positioned(
                left: 16,
                bottom: 16,
                child: _RegionStatusChip(
                  pageRegionCount:
                      (_regionsByPage[_pageNumber] ?? const []).length,
                  totalRegionCount: widget.problemRegions?.length ?? 0,
                ),
              ),
            if (_lastTappedRegion != null)
              Positioned(
                top: 80,
                left: 0,
                right: 0,
                child: Center(
                  child: _TappedBadge(
                    region: _lastTappedRegion!,
                    shownAt: _lastTapAt ?? DateTime.now(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceBadge(TextbookPdfSource source) {
    late final String label;
    late final Color bg;
    late final Color fg;
    switch (source.type) {
      case TextbookPdfSourceType.localFile:
        label = 'Local';
        bg = const Color(0xFF1B2B1B);
        fg = const Color(0xFF7CC67C);
        break;
      case TextbookPdfSourceType.legacyUrl:
        label = 'Dropbox';
        bg = const Color(0xFF2D2419);
        fg = const Color(0xFFEAB968);
        break;
      case TextbookPdfSourceType.remoteUrl:
        label = 'Stream';
        bg = const Color(0xFF1B2430);
        fg = const Color(0xFF7AA9E6);
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: kDlgPanelBg.withOpacity(0.92),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Icon(
              icon,
              size: 26,
              color: enabled ? kDlgText : kDlgTextSub.withOpacity(0.45),
            ),
          ),
        ),
      ),
    );
  }
}

/// Thin coloured rectangle rendered inside a pdfrx page overlay. Each
/// instance corresponds to one VLM-detected problem; tapping it calls
/// back into the viewer which then surfaces a `pN · 47번` badge.
class _RegionOverlay extends StatelessWidget {
  const _RegionOverlay({
    required this.region,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.onTap,
    required this.highlighted,
  });

  final TextbookProblemRegion region;
  final double left;
  final double top;
  final double width;
  final double height;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final border = highlighted
        ? const Color(0xFF7CC67C) // solid green when most recently tapped
        : const Color(0x667AA9E6); // soft blue for idle regions
    final fill = highlighted
        ? const Color(0x337CC67C)
        : Colors.transparent;
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: border, width: highlighted ? 2 : 1),
            borderRadius: BorderRadius.circular(4),
          ),
          padding: const EdgeInsets.only(left: 4, top: 2),
          alignment: Alignment.topLeft,
          child: Text(
            region.isSetHeader
                ? '${region.setFrom ?? '?'}~${region.setTo ?? '?'}'
                : region.problemNumber,
            style: TextStyle(
              color: highlighted
                  ? const Color(0xFF1B2B1B)
                  : const Color(0xCC7AA9E6),
              fontSize: 10,
              fontWeight: FontWeight.w800,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom-left chip telling the operator how many regions the current
/// page has and how many are loaded document-wide.
class _RegionStatusChip extends StatelessWidget {
  const _RegionStatusChip({
    required this.pageRegionCount,
    required this.totalRegionCount,
  });

  final int pageRegionCount;
  final int totalRegionCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: kDlgPanelBg.withOpacity(0.92),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: kDlgBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.crop_free, size: 14, color: Color(0xFF7AA9E6)),
          const SizedBox(width: 6),
          Text(
            pageRegionCount > 0
                ? '이 페이지 · $pageRegionCount개'
                : '이 페이지에 문항 영역 없음',
            style: const TextStyle(
              color: kDlgText,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 1,
            height: 10,
            color: kDlgBorder,
          ),
          const SizedBox(width: 8),
          Text(
            '총 $totalRegionCount개',
            style: const TextStyle(
              color: kDlgTextSub,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Animated "pN · 47번" badge that appears at the top of the viewer
/// whenever the operator taps a region. We rebuild on every tap (and on
/// repeat taps of the same region) so the user gets a crisp confirmation.
class _TappedBadge extends StatelessWidget {
  const _TappedBadge({required this.region, required this.shownAt});

  final TextbookProblemRegion region;
  final DateTime shownAt;

  @override
  Widget build(BuildContext context) {
    final setHint = region.isSetHeader ? ' · 세트 대표' : '';
    final labelHint = region.label.isEmpty ? '' : ' · ${region.label}';
    final sectionHint = region.section == null || region.section!.isEmpty
        ? ''
        : ' · ${region.section}';
    return TweenAnimationBuilder<double>(
      key: ValueKey(shownAt.microsecondsSinceEpoch),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Transform.scale(
        scale: 0.85 + 0.15 * t,
        child: Opacity(opacity: t.clamp(0, 1), child: child),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xE61B2B1B),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0xFF7CC67C), width: 1.4),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 18,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.task_alt, size: 16, color: Color(0xFFB6E6B6)),
            const SizedBox(width: 8),
            Text(
              region.badgeLabel(),
              style: const TextStyle(
                color: Color(0xFFEFFFEF),
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (setHint.isNotEmpty ||
                labelHint.isNotEmpty ||
                sectionHint.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '$sectionHint$labelHint$setHint'.trimLeft(),
                  style: const TextStyle(
                    color: Color(0xFFB6E6B6),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
