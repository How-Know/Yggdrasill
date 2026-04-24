// Unit tree authoring + VLM analysis dialog.
//
// This is the main workbench after a textbook has been registered via
// `TextbookRegisterWizard`. It orchestrates:
//
//   1. Loading the stored unit tree from `textbook_metadata.payload` and
//      letting the user edit 대/중단원 names and A/B/C start/end pages.
//   2. Running the VLM range-analysis + hi-res crop pipeline for one 소단원
//      at a time — reusing `textbook_vlm_range_runner.dart` so the retry
//      behavior matches `TextbookVlmTestDialog`.
//   3. Rendering the crop grid, letting the user review problems, and
//      uploading the selected crops through `TextbookCropUploader` — which
//      fans out to the gateway's `/textbook/crops/batch-upsert` endpoint.
//   4. Surfacing a "정답 VLM 추출 (베타)" stub button that hits
//      `/textbook/vlm/extract-answers` so the real implementation can slot
//      in later without UI changes.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../services/textbook_book_registry.dart';
import '../../services/textbook_crop_uploader.dart';
import '../../services/textbook_page_deskew.dart';
import '../../services/textbook_pdf_page_renderer.dart';
import '../../services/textbook_pdf_service.dart';
import '../../services/textbook_problem_crop.dart';
import '../../services/textbook_series_catalog.dart';
import '../../services/textbook_vlm_range_runner.dart';
import '../../services/textbook_vlm_test_service.dart';

class TextbookUnitAuthoringDialog extends StatefulWidget {
  const TextbookUnitAuthoringDialog({
    super.key,
    required this.academyId,
    required this.bookId,
    required this.bookName,
    required this.gradeLabel,
    this.linkId,
  });

  final String academyId;
  final String bookId;
  final String bookName;
  final String gradeLabel;
  final int? linkId;

  static Future<void> show(
    BuildContext context, {
    required String academyId,
    required String bookId,
    required String bookName,
    required String gradeLabel,
    int? linkId,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => TextbookUnitAuthoringDialog(
        academyId: academyId,
        bookId: bookId,
        bookName: bookName,
        gradeLabel: gradeLabel,
        linkId: linkId,
      ),
    );
  }

  @override
  State<TextbookUnitAuthoringDialog> createState() =>
      _TextbookUnitAuthoringDialogState();
}

class _TextbookUnitAuthoringDialogState
    extends State<TextbookUnitAuthoringDialog> {
  static const _kBg = Color(0xFF131315);
  static const _kPanel = Color(0xFF1B1B1E);
  static const _kCard = Color(0xFF15171C);
  static const _kBorder = Color(0xFF2A2A2A);
  static const _kText = Colors.white;
  static const _kTextSub = Color(0xFFB3B3B3);
  static const _kAccent = Color(0xFF33A373);
  static const _kDanger = Color(0xFFE68A8A);
  static const _kInfo = Color(0xFF7AA9E6);

  static const int _kAnalysisLongEdgePx = 1500;
  static const List<int> _kCropResolutionChoices = [1500, 2000, 2400, 3000];

  final _registry = TextbookBookRegistry();
  final _pdfService = TextbookPdfService();
  final _vlmService = TextbookVlmTestService();
  final _cropUploader = TextbookCropUploader();

  // Cached PDF document for the body PDF. Loaded lazily because the user
  // may browse the unit tree without ever triggering an analysis.
  PdfDocument? _bodyDocument;
  String? _pdfLoadError;
  bool _loadingPdf = false;

  bool _loadingPayload = true;
  String? _payloadError;
  String _seriesKey = kTextbookSeriesCatalog.first.key;
  final List<_BigUnitEdit> _bigUnits = <_BigUnitEdit>[];

  // Navigation state for the right pane.
  _SubFocus? _focus;

  // Per-sub VLM state. Keyed by '<big>/<mid>/<sub>' so switching tabs keeps
  // previously computed results visible.
  final Map<String, _SubRunState> _subStates = <String, _SubRunState>{};

  int _cropLongEdgePx = 2400;
  bool _deskew = true;

  // Answer-extraction stub state.
  bool _answerBusy = false;
  String? _answerStatus;

  @override
  void initState() {
    super.initState();
    _loadPayload();
  }

  @override
  void dispose() {
    _bodyDocument?.dispose();
    for (final big in _bigUnits) {
      big.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------ payload

  Future<void> _loadPayload() async {
    setState(() {
      _loadingPayload = true;
      _payloadError = null;
    });
    try {
      final row = await _registry.loadPayload(
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
      );
      final payload = row == null
          ? null
          : (row['payload'] is Map
              ? Map<String, dynamic>.from(row['payload'] as Map)
              : null);
      final series = (payload?['series'] as String?)?.trim().isNotEmpty == true
          ? (payload!['series'] as String).trim()
          : kTextbookSeriesCatalog.first.key;
      final entry = textbookSeriesByKey(series) ?? kTextbookSeriesCatalog.first;
      final loaded = bigUnitsFromPayload(payload, seriesKey: entry.key);
      final editable = <_BigUnitEdit>[];
      for (final big in loaded) {
        final bigEdit = _BigUnitEdit(bigName: big.bigName);
        for (final mid in big.middles) {
          final midEdit = _MidUnitEdit(series: entry, midName: mid.midName);
          // Overlay stored start/end pages.
          for (final sub in mid.subs) {
            for (final slot in midEdit.subs) {
              if (slot.preset.key == sub.subKey) {
                slot.startCtrl.text =
                    sub.startPage == null ? '' : '${sub.startPage}';
                slot.endCtrl.text =
                    sub.endPage == null ? '' : '${sub.endPage}';
                break;
              }
            }
          }
          bigEdit.middles.add(midEdit);
        }
        if (bigEdit.middles.isEmpty) {
          bigEdit.middles.add(_MidUnitEdit(series: entry));
        }
        editable.add(bigEdit);
      }
      if (editable.isEmpty) {
        final newBig = _BigUnitEdit();
        newBig.middles.add(_MidUnitEdit(series: entry));
        editable.add(newBig);
      }
      if (!mounted) return;
      setState(() {
        _seriesKey = entry.key;
        _bigUnits
          ..clear()
          ..addAll(editable);
        _loadingPayload = false;
        _focus = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingPayload = false;
        _payloadError = '$e';
      });
    }
  }

  Future<void> _saveTree() async {
    final payload = _buildBigUnitInputs();
    try {
      await _registry.saveUnitPayload(
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        seriesKey: _seriesKey,
        bigUnits: payload,
      );
      if (!mounted) return;
      _toast('단원 구조를 저장했습니다');
    } catch (e) {
      if (!mounted) return;
      _toast('저장 실패: $e', error: true);
    }
  }

  List<BigUnitInput> _buildBigUnitInputs() {
    final out = <BigUnitInput>[];
    for (var i = 0; i < _bigUnits.length; i += 1) {
      final big = _bigUnits[i];
      final midList = <MidUnitInput>[];
      for (var m = 0; m < big.middles.length; m += 1) {
        final mid = big.middles[m];
        final subList = <SubSectionInput>[];
        for (var s = 0; s < mid.subs.length; s += 1) {
          final sub = mid.subs[s];
          subList.add(SubSectionInput(
            order: s,
            subKey: sub.preset.key,
            displayName: sub.preset.displayName,
            startPage: _positiveInt(sub.startCtrl.text),
            endPage: _positiveInt(sub.endCtrl.text),
          ));
        }
        midList.add(MidUnitInput(
          midOrder: m,
          midName: mid.nameCtrl.text.trim(),
          subs: subList,
        ));
      }
      out.add(BigUnitInput(
        bigOrder: i,
        bigName: big.nameCtrl.text.trim(),
        middles: midList,
      ));
    }
    return out;
  }

  // ------------------------------------------------------------ pdf load

  Future<PdfDocument?> _ensurePdf() async {
    if (_bodyDocument != null) return _bodyDocument;
    if (_loadingPdf) return null;
    setState(() {
      _loadingPdf = true;
      _pdfLoadError = null;
    });
    try {
      final target = await _pdfService.requestDownloadUrl(
        linkId: widget.linkId,
        academyId: widget.academyId,
        fileId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        kind: 'body',
      );
      final url = target.url;
      if (url.isEmpty) throw Exception('empty_download_url');

      final tempDir = await getTemporaryDirectory();
      final safeBook =
          widget.bookId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final file = File(p.join(
        tempDir.path,
        'auth_${safeBook}_${widget.gradeLabel}_body.pdf',
      ));
      final res = await http.get(Uri.parse(url));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('pdf_download_failed(${res.statusCode})');
      }
      await file.writeAsBytes(res.bodyBytes, flush: true);
      final doc = await PdfDocument.openFile(file.path);
      if (!mounted) {
        doc.dispose();
        return null;
      }
      setState(() {
        _bodyDocument = doc;
        _loadingPdf = false;
      });
      return doc;
    } catch (e) {
      if (!mounted) return null;
      setState(() {
        _loadingPdf = false;
        _pdfLoadError = '$e';
      });
      return null;
    }
  }

  // ------------------------------------------------------------ analysis

  String _stateKeyFor(_SubFocus focus) =>
      '${focus.bigIndex}/${focus.midIndex}/${focus.subKey}';

  _SubRunState _ensureSubState(_SubFocus focus) {
    final key = _stateKeyFor(focus);
    return _subStates.putIfAbsent(key, () => _SubRunState());
  }

  Future<void> _runFocusedAnalysis(_SubFocus focus) async {
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final sub = mid.subs.firstWhere(
      (s) => s.preset.key == focus.subKey,
      orElse: () => mid.subs.first,
    );
    final startPage = _positiveInt(sub.startCtrl.text);
    final endPage = _positiveInt(sub.endCtrl.text);
    if (startPage == null || endPage == null || endPage < startPage) {
      _toast('시작/끝 페이지를 먼저 입력하세요', error: true);
      return;
    }
    final doc = await _ensurePdf();
    if (doc == null) return;
    final state = _ensureSubState(focus);
    if (state.running) return;
    setState(() {
      state.running = true;
      state.cancelled = false;
      state.pageResults.clear();
      state.progress = RangeProgress(
        cursor: startPage,
        total: endPage - startPage + 1,
        done: 0,
        failed: 0,
        failedPages: <int>{},
      );
      state.phase = '페이지 렌더링/분석 중...';
      state.error = null;
      state.uploadResult = null;
    });

    Future<Uint8List> render({
      required int rawPage,
      required int longEdgePx,
    }) {
      return renderPdfPageToPng(
        document: doc,
        pageNumber: rawPage,
        longEdgePx: longEdgePx,
      );
    }

    Future<TextbookVlmDetectResult> detect({
      required Uint8List imageBytes,
      required int rawPage,
    }) {
      return _vlmService.detectProblemsOnPage(
        imageBytes: imageBytes,
        rawPage: rawPage,
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
      );
    }

    try {
      await runRangeAnalysis(
        startPage: startPage,
        endPage: endPage,
        analysisLongEdgePx: _kAnalysisLongEdgePx,
        renderer: render,
        detector: detect,
        isCancelled: () => state.cancelled,
        onPageSuccess: (outcome) async {
          await _processPageOutcome(
            doc: doc,
            focus: focus,
            outcome: outcome,
          );
        },
        onPageFailure: (f) {
          state.pageResults.add(_PageAnalysisRow.failure(
            rawPage: f.rawPage,
            error: '${f.error}',
          ));
          if (!mounted) return;
          setState(() {});
        },
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            state.progress = progress;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        state.running = false;
        state.phase = '완료';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        state.running = false;
        state.error = '$e';
        state.phase = '실패';
      });
    }
  }

  Future<void> _processPageOutcome({
    required PdfDocument doc,
    required _SubFocus focus,
    required PageAnalysisOutcome outcome,
  }) async {
    final state = _ensureSubState(focus);
    try {
      final analysisBase = outcome.renderedPng;
      Uint8List analysisPng = analysisBase;
      double skew = 0.0;
      if (_deskew) {
        final deskew = await deskewPng(analysisBase);
        analysisPng = deskew.pngBytes;
        skew = deskew.angleDeg;
      }

      Uint8List hiresPng = analysisPng;
      int hiresW = 0;
      int hiresH = 0;
      if (_cropLongEdgePx != _kAnalysisLongEdgePx) {
        final hiresBase = await renderPdfPageToPng(
          document: doc,
          pageNumber: outcome.rawPage,
          longEdgePx: _cropLongEdgePx,
        );
        hiresPng = _deskew && skew.abs() > 1e-6
            ? await rotatePng(hiresBase, skew)
            : hiresBase;
      }

      final batch = <_BatchCropJob>[];
      for (var i = 0; i < outcome.result.items.length; i += 1) {
        final item = outcome.result.items[i];
        final region = item.itemRegion;
        if (region != null && region.length == 4) {
          batch.add(_BatchCropJob(
            orderIndex: i + 1,
            itemRegion: region,
            numberBbox: item.bbox,
          ));
        }
      }
      final cropsByOrder = batch.isEmpty
          ? <int, ProblemCrop?>{}
          : await compute<_BatchCropInput, Map<int, ProblemCrop?>>(
              _batchCropInIsolate,
              _BatchCropInput(sourcePng: hiresPng, jobs: batch),
            );

      final hiresProbe = identical(hiresPng, analysisPng)
          ? img.decodePng(analysisPng)
          : img.decodePng(hiresPng);
      hiresW = hiresProbe?.width ?? 0;
      hiresH = hiresProbe?.height ?? 0;

      final crops = <_ProblemCropEntry>[];
      for (var i = 0; i < outcome.result.items.length; i += 1) {
        final item = outcome.result.items[i];
        final order = i + 1;
        crops.add(_ProblemCropEntry(
          orderIndex: order,
          item: item,
          crop: cropsByOrder[order],
        ));
      }

      final row = _PageAnalysisRow.success(
        rawPage: outcome.rawPage,
        displayPage: outcome.result.displayPage,
        section: outcome.result.section,
        analysisPng: analysisPng,
        deskewAngle: skew,
        hiresLongEdgePx: _cropLongEdgePx,
        hiresW: hiresW,
        hiresH: hiresH,
        crops: crops,
      );
      state.pageResults.add(row);
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      state.pageResults.add(_PageAnalysisRow.failure(
        rawPage: outcome.rawPage,
        error: '크롭 실패: $e',
      ));
      if (!mounted) return;
      setState(() {});
    }
  }

  void _cancelFocused(_SubFocus focus) {
    final state = _ensureSubState(focus);
    state.cancelled = true;
    setState(() {
      state.phase = '취소 요청...';
    });
  }

  Future<void> _retryFailedForFocus(_SubFocus focus) async {
    final state = _ensureSubState(focus);
    final failed = state.progress?.failedPages ?? const <int>{};
    if (failed.isEmpty) return;
    final doc = await _ensurePdf();
    if (doc == null) return;
    setState(() {
      state.running = true;
      state.cancelled = false;
      state.phase = '실패 페이지 재분석...';
    });

    Future<Uint8List> render({
      required int rawPage,
      required int longEdgePx,
    }) {
      return renderPdfPageToPng(
        document: doc,
        pageNumber: rawPage,
        longEdgePx: longEdgePx,
      );
    }

    Future<TextbookVlmDetectResult> detect({
      required Uint8List imageBytes,
      required int rawPage,
    }) {
      return _vlmService.detectProblemsOnPage(
        imageBytes: imageBytes,
        rawPage: rawPage,
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
      );
    }

    try {
      await retryFailedPages(
        pages: failed.toList()..sort(),
        analysisLongEdgePx: _kAnalysisLongEdgePx,
        renderer: render,
        detector: detect,
        isCancelled: () => state.cancelled,
        onPageSuccess: (outcome) async {
          // Drop the previous failure marker for this page, if any.
          state.pageResults
              .removeWhere((r) => r.rawPage == outcome.rawPage && !r.ok);
          await _processPageOutcome(
            doc: doc,
            focus: focus,
            outcome: outcome,
          );
        },
        onPageFailure: (f) {
          state.pageResults
              .removeWhere((r) => r.rawPage == f.rawPage && !r.ok);
          state.pageResults.add(_PageAnalysisRow.failure(
            rawPage: f.rawPage,
            error: '${f.error}',
          ));
          if (!mounted) return;
          setState(() {});
        },
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            state.progress = progress;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        state.running = false;
        state.phase = '재분석 완료';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        state.running = false;
        state.error = '$e';
        state.phase = '재분석 실패';
      });
    }
  }

  Future<void> _uploadFocused(_SubFocus focus) async {
    final state = _ensureSubState(focus);
    if (state.running || state.uploading) return;
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final items = <TextbookCropUploadItem>[];
    for (final row in state.pageResults.where((r) => r.ok)) {
      for (final c in row.crops) {
        if (c.crop == null) continue;
        items.add(TextbookCropUploadItem(
          rawPage: row.rawPage,
          displayPage: row.displayPage,
          section: row.section,
          problemNumber: c.item.number,
          label: c.item.label,
          isSetHeader: c.item.isSetHeader,
          setFrom: c.item.setFrom,
          setTo: c.item.setTo,
          columnIndex: c.item.column,
          bbox1k: c.item.bbox,
          itemRegion1k: c.item.itemRegion,
          pngBytes: c.crop!.pngBytes,
          cropRectPx: c.crop!.cropRectPx,
          paddingPx: c.crop!.paddingPx,
          cropLongEdgePx: row.hiresLongEdgePx,
          deskewAngleDeg: row.deskewAngle,
          widthPx: row.hiresW,
          heightPx: row.hiresH,
        ));
      }
    }
    if (items.isEmpty) {
      _toast('업로드할 크롭이 없습니다', error: true);
      return;
    }

    setState(() {
      state.uploading = true;
      state.phase = '업로드 중... (${items.length}건)';
      state.error = null;
      state.uploadResult = null;
    });
    try {
      final result = await _cropUploader.uploadCropBatch(
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        bigOrder: focus.bigIndex,
        midOrder: focus.midIndex,
        subKey: focus.subKey,
        bigName: big.nameCtrl.text.trim(),
        midName: mid.nameCtrl.text.trim(),
        items: items,
        onProgress: (processed, total) {
          if (!mounted) return;
          setState(() {
            state.phase = '업로드 중... $processed / $total';
          });
        },
      );
      if (!mounted) return;
      setState(() {
        state.uploading = false;
        state.uploadResult = result;
        state.phase =
            '업로드 완료 · ${result.upserted}/${items.length}건 · ${result.bucket}';
      });
      _toast(
        '${focus.subKey} 크롭 ${result.upserted}건을 서버에 저장했습니다',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        state.uploading = false;
        state.error = '$e';
        state.phase = '업로드 실패';
      });
    }
  }

  Future<void> _exportFocusedToFolder(_SubFocus focus) async {
    final state = _ensureSubState(focus);
    if (state.pageResults.every((r) => !r.ok || r.crops.isEmpty)) {
      _toast('내보낼 크롭이 없습니다', error: true);
      return;
    }
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '소단원 크롭 저장 폴더',
    );
    if (dir == null) return;
    final safeBook =
        widget.bookName.replaceAll(RegExp(r'[^A-Za-z0-9가-힣_-]'), '_');
    final folderName =
        '${safeBook}_${widget.gradeLabel}_${focus.bigIndex}_${focus.midIndex}_${focus.subKey}';
    final outDir = Directory(p.join(dir, folderName));
    await outDir.create(recursive: true);
    var count = 0;
    for (final row in state.pageResults.where((r) => r.ok)) {
      for (final c in row.crops) {
        if (c.crop == null) continue;
        final safeNum = c.item.number
            .replaceAll(RegExp(r'[^A-Za-z0-9가-힣_-]'), '_');
        final file = File(p.join(
          outDir.path,
          'p${row.rawPage}_${c.orderIndex.toString().padLeft(2, '0')}_$safeNum.png',
        ));
        await file.writeAsBytes(c.crop!.pngBytes, flush: true);
        count += 1;
      }
    }
    if (!mounted) return;
    _toast('$count개 크롭을 ${outDir.path} 에 저장했습니다');
  }

  // ------------------------------------------------------------ answer stub

  Future<void> _requestAnswerExtraction() async {
    if (_answerBusy) return;
    setState(() {
      _answerBusy = true;
      _answerStatus = null;
    });
    try {
      final res = await _cropUploader.requestAnswerExtraction(
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
      );
      final message = (res['message'] as String?)?.trim() ??
          (res['error'] as String?)?.trim() ??
          '응답 코드 ${res['status_code']}';
      if (!mounted) return;
      setState(() {
        _answerStatus = message;
        _answerBusy = false;
      });
      _toast(message);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _answerBusy = false;
        _answerStatus = '호출 실패: $e';
      });
    }
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _kBg,
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: MediaQuery.of(context).size.width * 0.92,
        height: MediaQuery.of(context).size.height * 0.92,
        child: Column(
          children: [
            _buildHeader(),
            const Divider(height: 1, color: _kBorder),
            Expanded(
              child: _loadingPayload
                  ? const Center(
                      child: CircularProgressIndicator(color: _kAccent),
                    )
                  : _payloadError != null
                      ? Center(
                          child: Text(
                            '단원 정보를 불러오지 못했습니다\n${_payloadError!}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: _kDanger,
                              fontSize: 13,
                            ),
                          ),
                        )
                      : _buildMain(),
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
          const Icon(Icons.account_tree_outlined,
              color: _kAccent, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '단원·분석 · ${widget.bookName} · ${widget.gradeLabel}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _kText,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (_loadingPdf) ...[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _kInfo,
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'PDF 로드 중...',
              style: TextStyle(color: _kTextSub, fontSize: 11),
            ),
            const SizedBox(width: 10),
          ],
          if (_pdfLoadError != null) ...[
            Tooltip(
              message: _pdfLoadError!,
              child: const Icon(Icons.warning_amber,
                  size: 14, color: _kDanger),
            ),
            const SizedBox(width: 10),
          ],
          OutlinedButton.icon(
            onPressed: _saveTree,
            icon: const Icon(Icons.save_outlined,
                size: 14, color: _kTextSub),
            label: const Text(
              '단원 저장',
              style: TextStyle(color: _kTextSub, fontSize: 12),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: _kBorder),
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close, color: _kTextSub),
          ),
        ],
      ),
    );
  }

  Widget _buildMain() {
    return Row(
      children: [
        SizedBox(width: 380, child: _buildLeftPane()),
        const VerticalDivider(width: 1, color: _kBorder),
        Expanded(child: _buildRightPane()),
      ],
    );
  }

  Widget _buildLeftPane() {
    return Container(
      color: _kPanel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '단원 트리',
                    style: TextStyle(
                      color: _kText,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      final newBig = _BigUnitEdit();
                      newBig.middles.add(
                        _MidUnitEdit(series: _currentSeries()),
                      );
                      _bigUnits.add(newBig);
                    });
                  },
                  icon: const Icon(Icons.add, size: 14, color: _kTextSub),
                  label: const Text(
                    '대단원',
                    style: TextStyle(color: _kTextSub, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _kBorder),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 14),
              itemCount: _bigUnits.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _buildBigUnit(i),
            ),
          ),
        ],
      ),
    );
  }

  TextbookSeriesCatalogEntry _currentSeries() =>
      textbookSeriesByKey(_seriesKey) ?? kTextbookSeriesCatalog.first;

  Widget _buildBigUnit(int i) {
    final big = _bigUnits[i];
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _pill(text: '대 ${i + 1}', color: const Color(0xFF1B2B1B), fg: _kAccent),
              const SizedBox(width: 8),
              Expanded(
                child: _textInput(big.nameCtrl, hint: '대단원 이름'),
              ),
              IconButton(
                tooltip: '중단원 추가',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  setState(() {
                    big.middles.add(
                      _MidUnitEdit(series: _currentSeries()),
                    );
                  });
                },
                icon: const Icon(Icons.add, size: 14, color: _kTextSub),
              ),
              IconButton(
                tooltip: '대단원 삭제',
                visualDensity: VisualDensity.compact,
                onPressed: _bigUnits.length == 1
                    ? null
                    : () {
                        setState(() {
                          _bigUnits[i].dispose();
                          _bigUnits.removeAt(i);
                          if (_focus != null &&
                              _focus!.bigIndex >= _bigUnits.length) {
                            _focus = null;
                          }
                        });
                      },
                icon: const Icon(Icons.close, size: 13, color: _kTextSub),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (var m = 0; m < big.middles.length; m += 1) ...[
            _buildMidUnit(i, m),
            if (m < big.middles.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildMidUnit(int bigIndex, int midIndex) {
    final mid = _bigUnits[bigIndex].middles[midIndex];
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF101216),
        border: Border.all(color: const Color(0xFF1A1A1A)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _pill(
                text: '중 ${midIndex + 1}',
                color: const Color(0xFF1B2430),
                fg: _kInfo,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _textInput(mid.nameCtrl, hint: '중단원 이름'),
              ),
              IconButton(
                tooltip: '중단원 삭제',
                visualDensity: VisualDensity.compact,
                onPressed: _bigUnits[bigIndex].middles.length == 1
                    ? null
                    : () {
                        setState(() {
                          _bigUnits[bigIndex]
                              .middles[midIndex]
                              .dispose();
                          _bigUnits[bigIndex].middles.removeAt(midIndex);
                          if (_focus != null &&
                              _focus!.bigIndex == bigIndex &&
                              _focus!.midIndex >= _bigUnits[bigIndex]
                                  .middles.length) {
                            _focus = null;
                          }
                        });
                      },
                icon: const Icon(Icons.close, size: 12, color: _kTextSub),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final sub in mid.subs) _buildSubRow(bigIndex, midIndex, sub),
        ],
      ),
    );
  }

  Widget _buildSubRow(int bigIndex, int midIndex, _SubSectionEdit sub) {
    final focus = _SubFocus(
      bigIndex: bigIndex,
      midIndex: midIndex,
      subKey: sub.preset.key,
    );
    final selected = _focus != null &&
        _focus!.bigIndex == focus.bigIndex &&
        _focus!.midIndex == focus.midIndex &&
        _focus!.subKey == focus.subKey;
    final state = _subStates[_stateKeyFor(focus)];
    final upserted = state?.uploadResult?.upserted ?? 0;
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF1B2B1B) : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
      ),
      child: InkWell(
        onTap: () {
          setState(() => _focus = focus);
        },
        child: Row(
          children: [
            Container(
              width: 80,
              padding: const EdgeInsets.symmetric(
                  horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1A12),
                borderRadius: BorderRadius.circular(4),
              ),
              alignment: Alignment.center,
              child: Text(
                sub.preset.displayName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFEAB968),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _textInput(
                sub.startCtrl,
                hint: '시작',
                dense: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: _textInput(
                sub.endCtrl,
                hint: '끝',
                dense: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
            if (upserted > 0) ...[
              const SizedBox(width: 4),
              Tooltip(
                message: '이 소단원에 $upserted건의 크롭이 저장되어 있습니다',
                child: const Icon(Icons.check_circle,
                    size: 13, color: _kAccent),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRightPane() {
    final focus = _focus;
    if (focus == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '왼쪽에서 소단원(A/B/C)을 선택하면 분석 패널이 열립니다.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _kTextSub, fontSize: 13),
          ),
        ),
      );
    }
    final state = _ensureSubState(focus);
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final sub = mid.subs.firstWhere(
      (s) => s.preset.key == focus.subKey,
      orElse: () => mid.subs.first,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${big.nameCtrl.text.trim().isEmpty ? "대${focus.bigIndex + 1}" : big.nameCtrl.text.trim()} '
                  '› ${mid.nameCtrl.text.trim().isEmpty ? "중${focus.midIndex + 1}" : mid.nameCtrl.text.trim()} '
                  '› ${sub.preset.displayName}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _kText,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              _buildAnswerExtractButton(),
            ],
          ),
        ),
        const Divider(height: 1, color: _kBorder),
        Padding(
          padding: const EdgeInsets.all(12),
          child: _buildSubControls(focus, state, sub),
        ),
        if (state.progress != null) _buildProgressRow(state),
        Expanded(child: _buildResultsGrid(state)),
      ],
    );
  }

  Widget _buildSubControls(
    _SubFocus focus,
    _SubRunState state,
    _SubSectionEdit sub,
  ) {
    final start = _positiveInt(sub.startCtrl.text);
    final end = _positiveInt(sub.endCtrl.text);
    final readyRange = start != null && end != null && end >= start;
    final hasFailures = (state.progress?.failedPages ?? const <int>{}).isNotEmpty;
    final succeeded = state.pageResults.where((r) => r.ok).toList();
    final totalCrops = succeeded.fold<int>(
      0,
      (sum, row) => sum + row.crops.where((c) => c.crop != null).length,
    );

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          if (readyRange)
            _tag('범위 $start–${end}p (${end - start + 1}p)',
                const Color(0xFF234A34))
          else
            const _InfoTag(text: '시작/끝 페이지를 입력하세요', danger: true),
          const SizedBox(width: 8),
          _tag('분석 ${_kAnalysisLongEdgePx}px', const Color(0xFF333333)),
          const SizedBox(width: 6),
          Row(
            children: [
              const Text('크롭',
                  style:
                      TextStyle(color: _kTextSub, fontSize: 11)),
              const SizedBox(width: 4),
              DropdownButton<int>(
                value: _cropLongEdgePx,
                dropdownColor: _kCard,
                isDense: true,
                underline: const SizedBox.shrink(),
                style: const TextStyle(color: _kText, fontSize: 12),
                iconEnabledColor: _kTextSub,
                onChanged: state.running || state.uploading
                    ? null
                    : (v) => setState(() => _cropLongEdgePx = v!),
                items: [
                  for (final r in _kCropResolutionChoices)
                    DropdownMenuItem<int>(
                      value: r,
                      child: Text('${r}px'),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(width: 10),
          Row(
            children: [
              Switch(
                value: _deskew,
                onChanged: state.running || state.uploading
                    ? null
                    : (v) => setState(() => _deskew = v),
                activeThumbColor: _kAccent,
              ),
              const Text('스큐 보정',
                  style:
                      TextStyle(color: _kTextSub, fontSize: 11)),
            ],
          ),
          const Spacer(),
          if (totalCrops > 0)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                '$totalCrops개 준비',
                style: const TextStyle(color: _kAccent, fontSize: 11),
              ),
            ),
          if (state.running)
            OutlinedButton.icon(
              onPressed: () => _cancelFocused(focus),
              icon: const Icon(Icons.stop_circle_outlined,
                  size: 14, color: _kDanger),
              label: const Text(
                '취소',
                style: TextStyle(color: _kDanger, fontSize: 12),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF5A2A2A)),
              ),
            )
          else ...[
            if (hasFailures) ...[
              OutlinedButton.icon(
                onPressed: () => _retryFailedForFocus(focus),
                icon: const Icon(Icons.refresh, size: 14, color: _kInfo),
                label: Text(
                  '실패 ${(state.progress?.failedPages.length ?? 0)}p 재분석',
                  style: const TextStyle(color: _kInfo, fontSize: 12),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF2A3E5A)),
                ),
              ),
              const SizedBox(width: 6),
            ],
            FilledButton.icon(
              onPressed: !readyRange || state.uploading
                  ? null
                  : () => _runFocusedAnalysis(focus),
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('분석 시작'),
              style: FilledButton.styleFrom(
                backgroundColor: _kAccent,
              ),
            ),
          ],
          const SizedBox(width: 6),
          OutlinedButton.icon(
            onPressed:
                (state.running || state.uploading || totalCrops == 0)
                    ? null
                    : () => _exportFocusedToFolder(focus),
            icon: const Icon(Icons.folder_zip_outlined,
                size: 14, color: _kTextSub),
            label: const Text(
              '폴더 내보내기',
              style: TextStyle(color: _kTextSub, fontSize: 12),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: _kBorder),
            ),
          ),
          const SizedBox(width: 6),
          FilledButton.icon(
            onPressed: state.running || state.uploading || totalCrops == 0
                ? null
                : () => _uploadFocused(focus),
            icon: state.uploading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.cloud_upload_outlined, size: 16),
            label: Text(state.uploading ? '업로드 중' : '서버로 저장'),
            style: FilledButton.styleFrom(
              backgroundColor: _kInfo,
              disabledBackgroundColor: const Color(0xFF2A2A2A),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnswerExtractButton() {
    return OutlinedButton.icon(
      onPressed: _answerBusy ? null : _requestAnswerExtraction,
      icon: _answerBusy
          ? const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _kInfo,
              ),
            )
          : const Icon(Icons.auto_awesome, size: 14, color: _kInfo),
      label: Text(
        _answerStatus == null ? '정답 VLM 추출 시도 (베타)' : _answerStatus!,
        style: const TextStyle(color: _kInfo, fontSize: 11),
      ),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Color(0xFF2A3E5A)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
    );
  }

  Widget _buildProgressRow(_SubRunState state) {
    final progress = state.progress;
    if (progress == null) return const SizedBox.shrink();
    final total = progress.total == 0 ? 1 : progress.total;
    final ratio =
        ((progress.done + progress.failed) / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                state.phase,
                style: const TextStyle(color: _kText, fontSize: 11),
              ),
              const Spacer(),
              Text(
                '${progress.done}/${progress.total} 완료'
                '${progress.failed > 0 ? " · 실패 ${progress.failed}" : ""}'
                ' · 현재 ${progress.cursor}p',
                style: const TextStyle(color: _kTextSub, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: state.running ? ratio : 1.0,
              minHeight: 4,
              backgroundColor: const Color(0xFF2A2A2A),
              valueColor: AlwaysStoppedAnimation<Color>(
                progress.failed > 0 ? _kDanger : _kAccent,
              ),
            ),
          ),
          if (progress.lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                progress.lastError!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _kDanger, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildResultsGrid(_SubRunState state) {
    if (state.pageResults.isEmpty) {
      return const Center(
        child: Text(
          '아직 분석 결과가 없습니다. "분석 시작" 버튼을 눌러 실행하세요.',
          style: TextStyle(color: _kTextSub, fontSize: 12),
        ),
      );
    }
    final cropEntries = <_FlatCropEntry>[];
    final failureRows = <_PageAnalysisRow>[];
    final sorted = [...state.pageResults]
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    for (final row in sorted) {
      if (!row.ok) {
        failureRows.add(row);
        continue;
      }
      for (final c in row.crops) {
        cropEntries.add(_FlatCropEntry(row: row, entry: c));
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      children: [
        if (failureRows.isNotEmpty) _buildFailureList(failureRows),
        const SizedBox(height: 8),
        if (cropEntries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                '탐지된 문항이 없습니다.',
                style: TextStyle(color: _kTextSub, fontSize: 12),
              ),
            ),
          )
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 240,
              mainAxisExtent: 280,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: cropEntries.length,
            itemBuilder: (_, i) => _buildCropCard(cropEntries[i]),
          ),
      ],
    );
  }

  Widget _buildFailureList(List<_PageAnalysisRow> failures) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1919),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF5A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '분석 실패 ${failures.length}건',
            style: const TextStyle(
              color: _kDanger,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          for (final f in failures)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'p${f.rawPage}: ${f.error}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFE0B5B5), fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCropCard(_FlatCropEntry flat) {
    final entry = flat.entry;
    final row = flat.row;
    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(6),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: entry.item.isSetHeader
                        ? const Color(0xFFFFB44A)
                        : _kAccent,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    entry.item.number,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                if (entry.item.label.isNotEmpty)
                  Text(
                    entry.item.label,
                    style: const TextStyle(
                      color: _kText,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                const Spacer(),
                Text(
                  'p${row.rawPage}',
                  style: const TextStyle(color: _kTextSub, fontSize: 10),
                ),
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
                      padding: EdgeInsets.all(8),
                      child: Text(
                        '크롭 없음',
                        style: TextStyle(
                          color: Color(0xFF6A6A6A),
                          fontSize: 10,
                        ),
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
  }

  // ------------------------------------------------------------ widgets

  Widget _pill({required String text, required Color color, required Color fg}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: fg,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _textInput(
    TextEditingController controller, {
    required String hint,
    bool dense = false,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return TextField(
      controller: controller,
      onChanged: (_) => setState(() {}),
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      style: const TextStyle(color: _kText, fontSize: 12),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF5C5C5C), fontSize: 11),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(
          horizontal: 8,
          vertical: dense ? 6 : 8,
        ),
        filled: true,
        fillColor: _kCard,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: _kBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: _kBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: _kAccent),
        ),
      ),
    );
  }

  Widget _tag(String text, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: _kText,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor:
            error ? const Color(0xFFB53A3A) : const Color(0xFF2E7D32),
      ),
    );
  }
}

// ────────────────────────────── helpers ──────────────────────────────

class _InfoTag extends StatelessWidget {
  const _InfoTag({required this.text, this.danger = false});
  final String text;
  final bool danger;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: danger ? const Color(0xFF5A2A2A) : const Color(0xFF333333),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: danger ? const Color(0xFFE68A8A) : Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SubFocus {
  const _SubFocus({
    required this.bigIndex,
    required this.midIndex,
    required this.subKey,
  });
  final int bigIndex;
  final int midIndex;
  final String subKey;
}

class _SubRunState {
  bool running = false;
  bool uploading = false;
  bool cancelled = false;
  String phase = '대기';
  String? error;
  RangeProgress? progress;
  final List<_PageAnalysisRow> pageResults = <_PageAnalysisRow>[];
  TextbookCropBatchResult? uploadResult;
}

class _PageAnalysisRow {
  _PageAnalysisRow({
    required this.rawPage,
    required this.ok,
    this.error,
    this.displayPage = 0,
    this.section = 'unknown',
    this.analysisPng,
    this.deskewAngle = 0.0,
    this.hiresLongEdgePx = 0,
    this.hiresW = 0,
    this.hiresH = 0,
    List<_ProblemCropEntry>? crops,
  }) : crops = crops ?? <_ProblemCropEntry>[];

  factory _PageAnalysisRow.success({
    required int rawPage,
    required int displayPage,
    required String section,
    required Uint8List analysisPng,
    required double deskewAngle,
    required int hiresLongEdgePx,
    required int hiresW,
    required int hiresH,
    required List<_ProblemCropEntry> crops,
  }) {
    return _PageAnalysisRow(
      rawPage: rawPage,
      ok: true,
      displayPage: displayPage,
      section: section,
      analysisPng: analysisPng,
      deskewAngle: deskewAngle,
      hiresLongEdgePx: hiresLongEdgePx,
      hiresW: hiresW,
      hiresH: hiresH,
      crops: crops,
    );
  }

  factory _PageAnalysisRow.failure({
    required int rawPage,
    required String error,
  }) {
    return _PageAnalysisRow(rawPage: rawPage, ok: false, error: error);
  }

  final int rawPage;
  final bool ok;
  final String? error;
  final int displayPage;
  final String section;
  final Uint8List? analysisPng;
  final double deskewAngle;
  final int hiresLongEdgePx;
  final int hiresW;
  final int hiresH;
  final List<_ProblemCropEntry> crops;
}

class _ProblemCropEntry {
  const _ProblemCropEntry({
    required this.orderIndex,
    required this.item,
    required this.crop,
  });
  final int orderIndex;
  final TextbookVlmItem item;
  final ProblemCrop? crop;
}

class _FlatCropEntry {
  const _FlatCropEntry({required this.row, required this.entry});
  final _PageAnalysisRow row;
  final _ProblemCropEntry entry;
}

// ─────────── reused unit-edit models (tree editor) ───────────

class _BigUnitEdit {
  _BigUnitEdit({String? bigName}) {
    if (bigName != null) nameCtrl.text = bigName;
  }
  final TextEditingController nameCtrl = TextEditingController();
  final List<_MidUnitEdit> middles = <_MidUnitEdit>[];
  void dispose() {
    nameCtrl.dispose();
    for (final m in middles) {
      m.dispose();
    }
  }
}

class _MidUnitEdit {
  _MidUnitEdit({
    required TextbookSeriesCatalogEntry series,
    String? midName,
  }) {
    if (midName != null) nameCtrl.text = midName;
    for (final preset in series.subPreset) {
      subs.add(_SubSectionEdit(preset: preset));
    }
  }
  final TextEditingController nameCtrl = TextEditingController();
  final List<_SubSectionEdit> subs = <_SubSectionEdit>[];
  void dispose() {
    nameCtrl.dispose();
    for (final s in subs) {
      s.dispose();
    }
  }
}

class _SubSectionEdit {
  _SubSectionEdit({required this.preset});
  final TextbookSubSectionPreset preset;
  final TextEditingController startCtrl = TextEditingController();
  final TextEditingController endCtrl = TextEditingController();
  void dispose() {
    startCtrl.dispose();
    endCtrl.dispose();
  }
}

int? _positiveInt(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  final n = int.tryParse(t);
  if (n == null || n <= 0) return null;
  return n;
}

// ─────────── isolate-bound batch cropping (same shape as crop dialog) ───────────

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
