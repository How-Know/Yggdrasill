import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../services/textbook_pdf_service.dart';
import '../dialog_tokens.dart';

/// Opens the in-app textbook viewer as a full-screen page. The viewer asks
/// [TextbookPdfService] to resolve the ref into a local file (preferred) or
/// a URL (legacy / remote fallback) and then renders it with `pdfrx`.
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
}) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => TextbookViewerPage(
        ref: ref,
        title: title,
        cacheKey: cacheKey,
        initialPage: initialPage,
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
  });

  final TextbookPdfRef ref;
  final String title;
  final String? cacheKey;
  final int? initialPage;

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

  @override
  void initState() {
    super.initState();
    _pageNumber = widget.initialPage ?? 1;
    unawaited(_resolve());
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
    return Scaffold(
      backgroundColor: kDlgBg,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
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
