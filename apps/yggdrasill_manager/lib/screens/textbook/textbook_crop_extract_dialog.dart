import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../services/textbook_page_deskew.dart';
import '../../services/textbook_pdf_page_renderer.dart';
import '../../services/textbook_pdf_service.dart';
import '../../services/textbook_problem_crop.dart';
import '../../services/textbook_vlm_test_service.dart';

/// Quick, one-page pipeline:
///  1. Download the textbook PDF (or reuse a cached temp copy).
///  2. Render the requested PDF page to PNG at analysis resolution.
///  3. Optionally deskew the PNG so tilted scans produce straight crops.
///  4. Call the VLM to detect problem numbers + regions on that page.
///  5. Crop each detected region with safe padding and number avoidance.
///  6. Let the user export the crops (+ metadata JSON) to a folder.
///
/// Intentionally lighter than `TextbookVlmTestDialog` — no PDF viewer, no
/// overlay, no range analysis. This is the "harvest one page" workflow.
class TextbookCropExtractDialog extends StatefulWidget {
  const TextbookCropExtractDialog({
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
      builder: (ctx) => TextbookCropExtractDialog(
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
  State<TextbookCropExtractDialog> createState() =>
      _TextbookCropExtractDialogState();
}

class _TextbookCropExtractDialogState
    extends State<TextbookCropExtractDialog> {
  static const _kBg = Color(0xFF15171C);
  static const _kCard = Color(0xFF1F1F1F);
  static const _kBorder = Color(0xFF2A2A2A);
  static const _kText = Colors.white;
  static const _kTextSub = Color(0xFFB3B3B3);
  static const _kAccent = Color(0xFF33A373);
  static const _kDanger = Color(0xFFE68A8A);

  final _pdfService = TextbookPdfService();
  final _vlmService = TextbookVlmTestService();
  final _pageCtl = TextEditingController();

  bool _loadingPdf = true;
  String? _loadError;
  String? _localPath;
  PdfDocument? _document;
  int _pageCount = 0;

  bool _deskew = true;
  bool _running = false;
  String _phase = 'idle';
  String? _error;

  /// Long-edge resolution (px) used when rendering the page for the
  /// *crop source*. VLM analysis stays at `_kAnalysisLongEdgePx` to keep
  /// the prompt/token cost constant; crop cutting uses this (usually
  /// higher) resolution so crops don't look soft compared to the PDF.
  int _cropLongEdgePx = 2400;

  static const int _kAnalysisLongEdgePx = 1500;
  static const List<int> _kCropResolutionChoices = [1500, 2000, 2400, 3000];

  _Outcome? _outcome;

  @override
  void initState() {
    super.initState();
    _downloadPdf();
  }

  @override
  void dispose() {
    _pageCtl.dispose();
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
      final safeBook =
          widget.bookId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final file = File(p.join(
        tempDir.path,
        'crop_${safeBook}_${widget.gradeLabel}_${widget.kind}.pdf',
      ));
      final res = await http.get(Uri.parse(downloadUrl));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('pdf_download_failed(${res.statusCode})');
      }
      await file.writeAsBytes(res.bodyBytes, flush: true);

      final doc = await PdfDocument.openFile(file.path);
      if (!mounted) {
        doc.dispose();
        return;
      }
      setState(() {
        _localPath = file.path;
        _document = doc;
        _pageCount = doc.pages.length;
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

  Future<void> _runPipeline() async {
    final pageNo = int.tryParse(_pageCtl.text.trim());
    final doc = _document;
    if (doc == null) return;
    if (pageNo == null || pageNo < 1 || pageNo > _pageCount) {
      setState(() => _error = '유효한 페이지 번호(1~$_pageCount)를 입력하세요.');
      return;
    }

    setState(() {
      _running = true;
      _error = null;
      _phase = '렌더링 중...';
      _outcome = null;
    });

    try {
      setState(() => _phase = '페이지 렌더링 (분석용 ${_kAnalysisLongEdgePx}px)...');
      final analysisBase = await renderPdfPageToPng(
        document: doc,
        pageNumber: pageNo,
        longEdgePx: _kAnalysisLongEdgePx,
      );
      if (!mounted) return;

      Uint8List analysisPng = analysisBase;
      double skewAngle = 0.0;
      if (_deskew) {
        setState(() => _phase = '스큐 보정 분석...');
        final deskew = await deskewPng(analysisBase);
        analysisPng = deskew.pngBytes;
        skewAngle = deskew.angleDeg;
      }
      if (!mounted) return;

      // Render a second, higher-resolution copy of the same page and apply
      // the already-computed skew angle. Crops will come from this copy so
      // they preserve the PDF's native detail instead of being tied to the
      // 1500px analysis render. If the user picked 1500 for crops too, we
      // just reuse the analysis bytes.
      Uint8List hiresPng = analysisPng;
      if (_cropLongEdgePx != _kAnalysisLongEdgePx) {
        setState(() => _phase = '고해상도 렌더링 (${_cropLongEdgePx}px)...');
        final hiresBase = await renderPdfPageToPng(
          document: doc,
          pageNumber: pageNo,
          longEdgePx: _cropLongEdgePx,
        );
        if (!mounted) return;
        hiresPng = _deskew && skewAngle.abs() > 1e-6
            ? await rotatePng(hiresBase, skewAngle)
            : hiresBase;
        if (!mounted) return;
      }

      setState(() => _phase = 'VLM 문항 탐지...');
      final detection = await _vlmService.detectProblemsOnPage(
        imageBytes: analysisPng,
        rawPage: pageNo,
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
      );
      if (!mounted) return;

      setState(() => _phase = '문항 크롭 (${detection.items.length}건)...');
      final batch = <_BatchCropJob>[];
      for (var i = 0; i < detection.items.length; i += 1) {
        final item = detection.items[i];
        final region = item.itemRegion;
        if (region != null && region.length == 4) {
          batch.add(_BatchCropJob(
            orderIndex: i + 1,
            itemRegion: region,
            numberBbox: item.bbox,
          ));
        }
      }
      // Decode the hi-res PNG once and slice every item out of the same
      // in-memory Image. An isolate is used so the main thread stays free
      // even when the page yields ~30 problems at 2400px.
      final cropsByOrder = batch.isEmpty
          ? <int, ProblemCrop?>{}
          : await compute<_BatchCropInput, Map<int, ProblemCrop?>>(
              _batchCropInIsolate,
              _BatchCropInput(sourcePng: hiresPng, jobs: batch),
            );
      if (!mounted) return;
      final crops = <_CropEntry>[];
      for (var i = 0; i < detection.items.length; i += 1) {
        final item = detection.items[i];
        final order = i + 1;
        final crop = cropsByOrder[order];
        crops.add(_CropEntry(
          item: item,
          crop: crop,
          orderIndex: order,
        ));
      }

      final analysisProbe = img.decodePng(analysisPng);
      final hiresProbe = identical(hiresPng, analysisPng)
          ? analysisProbe
          : img.decodePng(hiresPng);

      setState(() {
        _outcome = _Outcome(
          pageNumber: pageNo,
          displayPage: detection.displayPage,
          section: detection.section,
          deskewAngle: skewAngle,
          analysisPng: analysisPng,
          analysisW: analysisProbe?.width ?? 0,
          analysisH: analysisProbe?.height ?? 0,
          hiresLongEdgePx: _cropLongEdgePx,
          hiresW: hiresProbe?.width ?? 0,
          hiresH: hiresProbe?.height ?? 0,
          crops: crops,
          elapsedMs: detection.elapsedMs,
          model: detection.model,
        );
        _phase = '완료 · ${crops.length}건 · 크롭 ${_cropLongEdgePx}px';
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _phase = '실패';
        _error = '$e';
      });
    }
  }

  Future<void> _exportToFolder() async {
    final out = _outcome;
    if (out == null) return;
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '크롭 저장 폴더 선택',
    );
    if (dir == null) return;

    final safeBook =
        widget.bookName.replaceAll(RegExp(r'[^A-Za-z0-9가-힣_-]'), '_');
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final folderName =
        '${safeBook}_${widget.gradeLabel}_${widget.kind}_p${out.pageNumber}_$stamp';
    final outDir = Directory(p.join(dir, folderName));
    await outDir.create(recursive: true);

    final summary = <String, dynamic>{
      'book_id': widget.bookId,
      'book_name': widget.bookName,
      'grade_label': widget.gradeLabel,
      'kind': widget.kind,
      'pdf_page': out.pageNumber,
      'display_page': out.displayPage,
      'section': out.section,
      'deskew_angle_deg': out.deskewAngle,
      'analysis_resolution_px': [out.analysisW, out.analysisH],
      'crop_long_edge_px': out.hiresLongEdgePx,
      'crop_resolution_px': [out.hiresW, out.hiresH],
      'model': out.model,
      'vlm_elapsed_ms': out.elapsedMs,
      'exported_at': DateTime.now().toIso8601String(),
      'items': <Map<String, dynamic>>[],
    };

    for (final entry in out.crops) {
      final item = entry.item;
      final safeNum =
          item.number.replaceAll(RegExp(r'[^A-Za-z0-9가-힣_-]'), '_');
      final labelPart = item.label.isEmpty
          ? ''
          : '_${item.label.replaceAll(RegExp(r'[^A-Za-z0-9가-힣_-]'), '_')}';
      final baseName = 'p${out.pageNumber}_'
          '${entry.orderIndex.toString().padLeft(2, '0')}_$safeNum$labelPart';

      final itemMeta = <String, dynamic>{
        'order': entry.orderIndex,
        'number': item.number,
        'label': item.label,
        'is_set_header': item.isSetHeader,
        'set_from': item.setFrom,
        'set_to': item.setTo,
        'column': item.column,
        'bbox_1k': item.bbox,
        'item_region_1k': item.itemRegion,
      };

      if (entry.crop != null) {
        final pngPath = p.join(outDir.path, '$baseName.png');
        await File(pngPath).writeAsBytes(entry.crop!.pngBytes, flush: true);
        itemMeta['png'] = '$baseName.png';
        itemMeta['crop_rect_px'] = entry.crop!.cropRectPx;
        itemMeta['padding_px'] = entry.crop!.paddingPx;
        itemMeta['avoided_number_edge'] = entry.crop!.avoidedNumberEdge;
        itemMeta['masked_number'] = entry.crop!.maskedNumber;
      } else {
        itemMeta['png'] = null;
        itemMeta['skip_reason'] = 'no_item_region';
      }

      (summary['items'] as List<Map<String, dynamic>>).add(itemMeta);
    }

    final pagePng = File(p.join(outDir.path, 'page_analysis.png'));
    await pagePng.writeAsBytes(out.analysisPng, flush: true);
    final summaryFile = File(p.join(outDir.path, 'summary.json'));
    await summaryFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(summary),
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${outDir.path} 로 저장 완료 (${out.crops.length}건)'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context).size;
    final dialogW = media.width * 0.85;
    final dialogH = media.height * 0.9;
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
            Expanded(child: _buildBody()),
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
          const Icon(Icons.content_cut, color: _kAccent, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '페이지 크롭 추출 · ${widget.bookName} · '
              '${widget.gradeLabel}/${widget.kind}',
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

  Widget _buildBody() {
    if (_loadingPdf) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: _kAccent),
            SizedBox(height: 10),
            Text('PDF 다운로드 중...',
                style: TextStyle(color: _kTextSub, fontSize: 12)),
          ],
        ),
      );
    }
    if (_loadError != null || _localPath == null || _document == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'PDF를 불러오지 못했습니다.\n\n${_loadError ?? ''}',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: _kDanger, fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildControls(),
          const SizedBox(height: 10),
          _buildStatusRow(),
          const SizedBox(height: 10),
          Expanded(child: _buildOutcome()),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: TextField(
              controller: _pageCtl,
              enabled: !_running,
              style: const TextStyle(color: _kText, fontSize: 13),
              decoration: InputDecoration(
                labelText: '페이지',
                hintText: '1~$_pageCount',
                labelStyle: const TextStyle(color: _kTextSub),
                hintStyle: const TextStyle(color: Color(0xFF5C5C5C)),
                border: const OutlineInputBorder(),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 12),
              ),
              keyboardType: TextInputType.number,
              onSubmitted: (_) => _runPipeline(),
            ),
          ),
          const SizedBox(width: 16),
          Switch(
            value: _deskew,
            onChanged: _running ? null : (v) => setState(() => _deskew = v),
            activeThumbColor: _kAccent,
          ),
          const SizedBox(width: 4),
          const Text(
            '스큐 보정',
            style: TextStyle(color: _kText, fontSize: 12),
          ),
          const SizedBox(width: 18),
          const Text(
            '크롭 해상도',
            style: TextStyle(color: _kText, fontSize: 12),
          ),
          const SizedBox(width: 6),
          DropdownButton<int>(
            value: _cropLongEdgePx,
            dropdownColor: _kCard,
            isDense: true,
            underline: const SizedBox.shrink(),
            style: const TextStyle(color: _kText, fontSize: 12),
            iconEnabledColor: _kTextSub,
            onChanged: _running
                ? null
                : (v) {
                    if (v == null) return;
                    setState(() => _cropLongEdgePx = v);
                  },
            items: [
              for (final r in _kCropResolutionChoices)
                DropdownMenuItem<int>(
                  value: r,
                  child: Text('${r}px'),
                ),
            ],
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: _running ? null : _runPipeline,
            icon: _running
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.play_arrow, size: 16),
            label: Text(_running ? '분석 중...' : '분석 & 크롭'),
            style: FilledButton.styleFrom(
              backgroundColor: _kAccent,
              disabledBackgroundColor: const Color(0xFF2A2A2A),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed:
                (_outcome == null || _outcome!.crops.isEmpty) ? null : _exportToFolder,
            icon: const Icon(Icons.folder_zip_outlined, size: 16),
            label: const Text('폴더로 내보내기'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _kText,
              side: const BorderSide(color: _kBorder),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusRow() {
    return Row(
      children: [
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: _running ? const Color(0xFF234A34) : const Color(0xFF333333),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            _phase,
            style: const TextStyle(
                color: _kText, fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 10),
        if (_outcome != null) ...[
          _tag(
            'PDF ${_outcome!.pageNumber}p → 책 ${_outcome!.displayPage}p',
            const Color(0xFF234A34),
          ),
          const SizedBox(width: 6),
          _tag('skew ${_outcome!.deskewAngle.toStringAsFixed(2)}°',
              const Color(0xFF333333)),
          const SizedBox(width: 6),
          _tag(
            '크롭 ${_outcome!.hiresW}×${_outcome!.hiresH}',
            const Color(0xFF234A4A),
          ),
          const SizedBox(width: 6),
          _tag('${_outcome!.elapsedMs}ms', const Color(0xFF333333)),
        ],
        if (_error != null) ...[
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _kDanger, fontSize: 11),
            ),
          ),
        ],
      ],
    );
  }

  Widget _tag(String text, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
            color: _kText, fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _buildOutcome() {
    final out = _outcome;
    if (out == null) {
      return const Center(
        child: Text(
          '페이지 번호를 입력하고 "분석 & 크롭" 을 눌러 시작하세요.',
          style: TextStyle(color: _kTextSub, fontSize: 12),
        ),
      );
    }
    if (out.crops.isEmpty) {
      return const Center(
        child: Text(
          '이 페이지에서 탐지된 문항이 없습니다.',
          style: TextStyle(color: _kTextSub, fontSize: 12),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 280,
        mainAxisExtent: 320,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: out.crops.length,
      itemBuilder: (_, i) => _buildCropCard(out.crops[i]),
    );
  }

  Widget _buildCropCard(_CropEntry entry) {
    final item = entry.item;
    final clickable = entry.crop != null;
    final card = Container(
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
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
                        fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 6),
                if (item.label.isNotEmpty)
                  Text(item.label,
                      style: const TextStyle(
                          color: _kText,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                const Spacer(),
                if (entry.crop?.maskedNumber == true)
                  const Tooltip(
                    message: '번호를 흰색 매트로 덮었습니다.',
                    child: Icon(Icons.edit_off,
                        size: 14, color: Color(0xFF8FA7BF)),
                  )
                else if ((entry.crop?.avoidedNumberEdge ?? 'none') != 'none')
                  Tooltip(
                    message: '${entry.crop!.avoidedNumberEdge} 경계를 밀어 번호 회피',
                    child: const Icon(Icons.border_clear,
                        size: 14, color: Color(0xFF8FA7BF)),
                  ),
                if (clickable) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.open_in_full,
                      size: 12, color: Color(0xFF7A7A7A)),
                ],
              ],
            ),
          ),
          const Divider(height: 1, color: _kBorder),
          Expanded(
            child: Container(
              color: Colors.white,
              alignment: Alignment.center,
              child: entry.crop == null
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: Text(
                        '영역 정보 없음 (item_region 없음)',
                        style: TextStyle(
                            color: Color(0xFF6A6A6A), fontSize: 11),
                      ),
                    )
                  : Image.memory(
                      entry.crop!.pngBytes,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
            ),
          ),
        ],
      ),
    );
    if (!clickable) return card;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openCropPreview(entry),
        child: card,
      ),
    );
  }

  void _openCropPreview(_CropEntry entry) {
    final out = _outcome;
    if (out == null) return;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withAlpha(200),
      builder: (_) => _CropPreviewDialog(
        entry: entry,
        analysisPng: out.analysisPng,
        pageImageW: out.analysisW,
        pageImageH: out.analysisH,
        pageNumber: out.pageNumber,
        displayPage: out.displayPage,
        section: out.section,
      ),
    );
  }
}

// ─────────────────────── preview dialog ───────────────────────

class _CropPreviewDialog extends StatelessWidget {
  const _CropPreviewDialog({
    required this.entry,
    required this.analysisPng,
    required this.pageImageW,
    required this.pageImageH,
    required this.pageNumber,
    required this.displayPage,
    required this.section,
  });

  final _CropEntry entry;
  final Uint8List analysisPng;
  final int pageImageW;
  final int pageImageH;
  final int pageNumber;
  final int displayPage;
  final String section;

  static const _kBg = Color(0xFF15171C);
  static const _kCard = Color(0xFF1F1F1F);
  static const _kBorder = Color(0xFF2A2A2A);
  static const _kText = Colors.white;
  static const _kTextSub = Color(0xFFB3B3B3);
  static const _kAccent = Color(0xFF33A373);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context).size;
    final item = entry.item;
    return Dialog(
      backgroundColor: _kBg,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: media.width * 0.9,
        height: media.height * 0.9,
        child: Column(
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (item.label.isNotEmpty)
                    Text(
                      item.label,
                      style: const TextStyle(
                        color: _kText,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  const SizedBox(width: 12),
                  Text(
                    'PDF ${pageNumber}p → 책 ${displayPage}p · section=$section',
                    style:
                        const TextStyle(color: _kTextSub, fontSize: 11),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close, color: _kTextSub),
                    tooltip: '닫기',
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: _kBorder),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: _buildCropPane()),
                    const SizedBox(width: 12),
                    Expanded(flex: 4, child: _buildPagePane()),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCropPane() {
    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              '크롭 결과',
              style: TextStyle(
                  color: _kTextSub,
                  fontSize: 11,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const Divider(height: 1, color: _kBorder),
          Expanded(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(6),
              child: entry.crop == null
                  ? const Center(
                      child: Text('크롭 결과 없음',
                          style: TextStyle(
                              color: Color(0xFF6A6A6A), fontSize: 12)),
                    )
                  : InteractiveViewer(
                      maxScale: 8,
                      child: Image.memory(
                        entry.crop!.pngBytes,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    ),
            ),
          ),
          if (entry.crop != null)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: _buildCropMeta(entry.crop!),
            ),
        ],
      ),
    );
  }

  Widget _buildCropMeta(ProblemCrop crop) {
    final rect = crop.cropRectPx;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        _chip('패딩 ${crop.paddingPx}px'),
        _chip('영역 ${rect.length == 4 ? "${rect[2]}×${rect[3]}" : "-"} px'),
        _chip(crop.avoidedNumberEdge == 'none'
            ? '번호 회피 없음'
            : '${crop.avoidedNumberEdge} 경계로 회피'),
        if (crop.maskedNumber) _chip('번호 흰색 매트', danger: true),
      ],
    );
  }

  Widget _chip(String text, {bool danger = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: danger ? const Color(0xFF5E3A3A) : const Color(0xFF2E2E2E),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
            color: _kText, fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _buildPagePane() {
    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              '분석 원본 (스큐 보정 후) · 이 문항 영역을 강조',
              style: TextStyle(
                  color: _kTextSub,
                  fontSize: 11,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const Divider(height: 1, color: _kBorder),
          Expanded(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(6),
              child: InteractiveViewer(
                maxScale: 8,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(
                      analysisPng,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _OverlayPainter(
                          imageW: pageImageW.toDouble(),
                          imageH: pageImageH.toDouble(),
                          itemRegion: entry.item.itemRegion,
                          bbox: entry.item.bbox,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.imageW,
    required this.imageH,
    required this.itemRegion,
    required this.bbox,
  });

  final double imageW;
  final double imageH;
  final List<int>? itemRegion;
  final List<int>? bbox;

  @override
  void paint(Canvas canvas, Size size) {
    if (imageW <= 0 || imageH <= 0) return;

    // The page image uses BoxFit.contain, so we reconstruct the displayed
    // rect to place overlay boxes precisely over the rendered pixels.
    final fit = _applyContain(size, imageW, imageH);

    if (itemRegion != null && itemRegion!.length == 4) {
      _drawBbox(
        canvas,
        fit,
        itemRegion!,
        color: const Color(0xFF33A373),
        strokeWidth: 2.5,
      );
    }
    if (bbox != null && bbox!.length == 4) {
      _drawBbox(
        canvas,
        fit,
        bbox!,
        color: const Color(0xFFFF6A5C),
        strokeWidth: 2.0,
      );
    }
  }

  void _drawBbox(
    Canvas canvas,
    Rect fitRect,
    List<int> bbox, {
    required Color color,
    required double strokeWidth,
  }) {
    final ymin = bbox[0] / 1000.0;
    final xmin = bbox[1] / 1000.0;
    final ymax = bbox[2] / 1000.0;
    final xmax = bbox[3] / 1000.0;
    final left = fitRect.left + fitRect.width * xmin;
    final top = fitRect.top + fitRect.height * ymin;
    final right = fitRect.left + fitRect.width * xmax;
    final bottom = fitRect.top + fitRect.height * ymax;
    final rect = Rect.fromLTRB(left, top, right, bottom);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawRect(rect, paint);
  }

  Rect _applyContain(Size target, double imgW, double imgH) {
    final scale = (target.width / imgW) < (target.height / imgH)
        ? target.width / imgW
        : target.height / imgH;
    final drawW = imgW * scale;
    final drawH = imgH * scale;
    final dx = (target.width - drawW) / 2.0;
    final dy = (target.height - drawH) / 2.0;
    return Rect.fromLTWH(dx, dy, drawW, drawH);
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) {
    return old.imageW != imageW ||
        old.imageH != imageH ||
        old.itemRegion != itemRegion ||
        old.bbox != bbox;
  }
}

class _Outcome {
  const _Outcome({
    required this.pageNumber,
    required this.displayPage,
    required this.section,
    required this.deskewAngle,
    required this.analysisPng,
    required this.analysisW,
    required this.analysisH,
    required this.hiresLongEdgePx,
    required this.hiresW,
    required this.hiresH,
    required this.crops,
    required this.elapsedMs,
    required this.model,
  });
  final int pageNumber;
  final int displayPage;
  final String section;
  final double deskewAngle;

  /// PNG used for VLM analysis and the "Page analysis" preview (1500px).
  final Uint8List analysisPng;
  final int analysisW;
  final int analysisH;

  /// Long-edge px of the render used to produce the crops. May equal the
  /// analysis resolution if the user chose 1500px for crops too.
  final int hiresLongEdgePx;
  final int hiresW;
  final int hiresH;

  final List<_CropEntry> crops;
  final int elapsedMs;
  final String model;
}

class _CropEntry {
  const _CropEntry({
    required this.item,
    required this.crop,
    required this.orderIndex,
  });
  final TextbookVlmItem item;
  final ProblemCrop? crop;
  final int orderIndex;
}

// ─────────────────────── isolate plumbing ───────────────────────
//
// The `image` package is CPU-heavy and PNG decoding a 2400px page can cost
// 100+ ms on its own, so we decode once per batch and slice every item out
// of the same pre-decoded image. Returned as a {order → crop} map so the
// caller can splice it back into the original item order.

class _BatchCropJob {
  const _BatchCropJob({
    required this.orderIndex,
    required this.itemRegion,
    required this.numberBbox,
  });
  final int orderIndex;
  final List<int> itemRegion;
  final List<int>? numberBbox;
}

class _BatchCropInput {
  const _BatchCropInput({
    required this.sourcePng,
    required this.jobs,
  });
  final Uint8List sourcePng;
  final List<_BatchCropJob> jobs;
}

Map<int, ProblemCrop?> _batchCropInIsolate(_BatchCropInput input) {
  final out = <int, ProblemCrop?>{};
  final decoded = img.decodePng(input.sourcePng);
  if (decoded == null) {
    for (final job in input.jobs) {
      out[job.orderIndex] = null;
    }
    return out;
  }
  for (final job in input.jobs) {
    out[job.orderIndex] = cropProblemRegionOnImage(
      source: decoded,
      itemRegion: job.itemRegion,
      numberBbox: job.numberBbox,
    );
  }
  return out;
}
