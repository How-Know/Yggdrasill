import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

class ProblemBankExportServerPreviewDialog extends StatefulWidget {
  const ProblemBankExportServerPreviewDialog({
    super.key,
    required this.pdfUrl,
    required this.titleText,
  });

  final String pdfUrl;
  final String titleText;

  static Future<void> open(
    BuildContext context, {
    required String pdfUrl,
    String titleText = '서버 PDF 미리보기',
  }) async {
    final size = MediaQuery.sizeOf(context);
    final maxWidth = (size.width - 40).clamp(920.0, 1640.0).toDouble();
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
              minWidth: 780,
              minHeight: 620,
            ),
            child: ProblemBankExportServerPreviewDialog(
              pdfUrl: pdfUrl,
              titleText: titleText,
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

  final PdfViewerController _viewerController = PdfViewerController();
  int _pageNumber = 1;
  int _pageCount = 0;
  double? _fitZoom;

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

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(widget.pdfUrl.trim());
    final zoomPercent = _viewerController.isReady
        ? (_viewerController.currentZoom * 100).round()
        : 100;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
                        controller: _viewerController,
                        params: PdfViewerParams(
                          backgroundColor: const Color(0xFF0B1112),
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
                              _pageNumber =
                                  (controller.pageNumber ?? 1).clamp(1, 9999);
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
                              child: CircularProgressIndicator(strokeWidth: 2),
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
    );
  }
}
