// Stage 2 / Stage 3 dialog — launched from the Stage 1 unit authoring dialog.
//
// The structure mirrors `TextbookUnitAuthoringDialog`: a left-side PDF viewer
// (`pdfrx` + two-page `layoutPages`) with VLM-detected overlays, and a
// right-side panel that drives the run / match / save workflow.
//
// Two tabs:
//   1. 정답 매칭 — 답지 PDF + `/textbook/vlm/extract-answers`. Each matched
//      row lets the operator fine-tune the answer (객관식 ①~⑤ picker or
//      주관식 LaTeX editor with a 2D preview).
//   2. 해설 좌표 — 해설 PDF + `/textbook/vlm/detect-solution-refs`. The
//      detected 문항번호 bbox per crop is persisted so the student app can
//      later jump straight to the solution region.
//
// Both tabs fetch the Stage 1 crops (crop_id, problem_number) from Supabase
// on init, so the dialog can be re-opened later even after a restart.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/textbook_pdf_page_renderer.dart';
import '../../services/textbook_pdf_service.dart';
import '../../services/textbook_vlm_answer_service.dart';
import '../../services/textbook_vlm_solution_ref_service.dart';
import '../../widgets/latex_text_renderer.dart';

/// Entry point invoked by the Stage 1 dialog's "다음" button.
class TextbookAuthoringStageDialog extends StatefulWidget {
  const TextbookAuthoringStageDialog({
    super.key,
    required this.academyId,
    required this.bookId,
    required this.bookName,
    required this.gradeLabel,
    required this.bigOrder,
    required this.midOrder,
    required this.subKey,
    this.linkId,
    this.bigName,
    this.midName,
    this.initialCrops = const <TextbookAuthoringStageCropSeed>[],
    this.batchScopes = const <TextbookAuthoringStageScope>[],
  });

  final String academyId;
  final String bookId;
  final String bookName;
  final String gradeLabel;
  final int? linkId;
  final int bigOrder;
  final int midOrder;
  final String subKey;
  final String? bigName;
  final String? midName;
  final List<TextbookAuthoringStageCropSeed> initialCrops;
  final List<TextbookAuthoringStageScope> batchScopes;

  static Future<void> show(
    BuildContext context, {
    required String academyId,
    required String bookId,
    required String bookName,
    required String gradeLabel,
    required int bigOrder,
    required int midOrder,
    required String subKey,
    int? linkId,
    String? bigName,
    String? midName,
    List<TextbookAuthoringStageCropSeed> initialCrops =
        const <TextbookAuthoringStageCropSeed>[],
    List<TextbookAuthoringStageScope> batchScopes =
        const <TextbookAuthoringStageScope>[],
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => TextbookAuthoringStageDialog(
        academyId: academyId,
        bookId: bookId,
        bookName: bookName,
        gradeLabel: gradeLabel,
        linkId: linkId,
        bigOrder: bigOrder,
        midOrder: midOrder,
        subKey: subKey,
        bigName: bigName,
        midName: midName,
        initialCrops: initialCrops,
        batchScopes: batchScopes,
      ),
    );
  }

  @override
  State<TextbookAuthoringStageDialog> createState() =>
      _TextbookAuthoringStageDialogState();
}

class TextbookAuthoringStageScope {
  const TextbookAuthoringStageScope({
    required this.bigOrder,
    required this.midOrder,
    required this.subKey,
    this.bigName = '',
    this.midName = '',
    this.subName = '',
  });

  final int bigOrder;
  final int midOrder;
  final String subKey;
  final String bigName;
  final String midName;
  final String subName;
}

/// Minimal crop row passed from Stage 1 immediately after a successful
/// regions-only upload. The Stage 2/3 dialog still tries to reload richer rows
/// from Supabase, but this seed prevents a race/RLS/cache issue from showing an
/// empty state right after the operator presses "영역 저장" → "다음".
class TextbookAuthoringStageCropSeed {
  const TextbookAuthoringStageCropSeed({
    required this.id,
    required this.problemNumber,
    this.rawPage,
    this.displayPage,
    this.section = '',
    this.isSetHeader = false,
    this.contentGroupKind = 'none',
    this.contentGroupLabel = '',
    this.contentGroupTitle = '',
    this.contentGroupOrder,
    this.scopeLabel = '',
  });

  final String id;
  final String problemNumber;
  final int? rawPage;
  final int? displayPage;
  final String section;
  final bool isSetHeader;
  final String contentGroupKind;
  final String contentGroupLabel;
  final String contentGroupTitle;
  final int? contentGroupOrder;
  final String scopeLabel;
}

class _TextbookAuthoringStageDialogState
    extends State<TextbookAuthoringStageDialog>
    with SingleTickerProviderStateMixin {
  static const _kBg = Color(0xFF131315);
  static const _kPanel = Color(0xFF1B1B1E);
  static const _kCard = Color(0xFF15171C);
  static const _kBorder = Color(0xFF2A2A2A);
  static const _kText = Colors.white;
  static const _kTextSub = Color(0xFFB3B3B3);
  static const _kAccent = Color(0xFF33A373);
  static const _kDanger = Color(0xFFE68A8A);
  static const _kInfo = Color(0xFF7AA9E6);
  static const _kWarn = Color(0xFFE6C07A);

  static const int _kVlmLongEdgePx = 1500;

  final _pdfService = TextbookPdfService();
  final _answerService = TextbookVlmAnswerService();
  final _solRefService = TextbookVlmSolutionRefService();
  final _supa = Supabase.instance.client;

  late final TabController _tab;

  // Stage 1 crop rows for this sub-unit: [{id, problem_number, raw_page,
  // display_page, section, ...}]. Shared between Stage 2 and Stage 3.
  bool _loadingCrops = true;
  String? _cropsError;
  final List<_StageCrop> _crops = <_StageCrop>[];

  // --- Stage 2 (answers) -----------------------------------------------
  bool _loadingAnswerPdf = false;
  String? _answerPdfError;
  PdfDocument? _answerDocument;
  String? _answerLocalPath;
  final _answerViewerController = PdfViewerController();

  bool _runningAnswerVlm = false;
  double _answerProgress = 0;
  String _answerStatus = '';

  // Existing saved rows from textbook_problem_answers, keyed by crop_id.
  final Map<String, _AnswerDraft> _answersByCropId = <String, _AnswerDraft>{};
  // Problem numbers the Stage 2 VLM could not match.
  final List<String> _answerMissing = <String>[];

  bool _savingAnswers = false;

  // --- Stage 3 (solution refs) -----------------------------------------
  bool _loadingSolutionPdf = false;
  String? _solutionPdfError;
  PdfDocument? _solutionDocument;
  String? _solutionLocalPath;
  final _solutionViewerController = PdfViewerController();

  bool _runningSolRefVlm = false;
  double _solRefProgress = 0;
  String _solRefStatus = '';

  final Map<String, _SolRefDraft> _solRefsByCropId = <String, _SolRefDraft>{};
  final List<String> _solRefMissing = <String>[];

  bool _savingSolRefs = false;
  bool _loadingPbRuns = false;
  final Map<String, String> _pbRunStatusByKey = <String, String>{};

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    unawaited(_loadCrops());
    unawaited(_refreshPbRunStatuses());
  }

  @override
  void dispose() {
    _tab.dispose();
    _answerDocument?.dispose();
    _solutionDocument?.dispose();
    super.dispose();
  }

  // --------------------------------------------------------------- data

  Future<void> _loadCrops() async {
    setState(() {
      _loadingCrops = true;
      _cropsError = null;
    });
    try {
      final list = await _loadCropRowsForScopes();
      _crops
        ..clear()
        ..addAll(list.map(_StageCrop.fromRow));
      if (_crops.isEmpty && widget.initialCrops.isNotEmpty) {
        _crops.addAll(widget.initialCrops.map(_StageCrop.fromSeed));
      }

      // Pre-load existing answer/solref rows so revisits show saved state.
      await _loadExistingAnswers();
      await _loadExistingSolRefs();

      setState(() {
        _loadingCrops = false;
      });
    } catch (e) {
      if (widget.initialCrops.isNotEmpty) {
        _crops
          ..clear()
          ..addAll(widget.initialCrops.map(_StageCrop.fromSeed));
        setState(() {
          _loadingCrops = false;
          _cropsError = null;
        });
        return;
      }
      setState(() {
        _loadingCrops = false;
        _cropsError = '$e';
      });
    }
  }

  Future<List<Map<String, dynamic>>> _loadCropRowsForScopes() async {
    const select = 'id, problem_number, raw_page, display_page, section, '
        'is_set_header, content_group_kind, content_group_label, '
        'content_group_title, content_group_order, bbox_1k, item_region_1k';
    final scopes = widget.batchScopes.isNotEmpty
        ? widget.batchScopes
        : <TextbookAuthoringStageScope>[
            TextbookAuthoringStageScope(
              bigOrder: widget.bigOrder,
              midOrder: widget.midOrder,
              subKey: widget.subKey,
              bigName: widget.bigName ?? '',
              midName: widget.midName ?? '',
            ),
          ];
    final out = <Map<String, dynamic>>[];
    for (final scope in scopes) {
      final rows = await _supa
          .from('textbook_problem_crops')
          .select(select)
          .eq('academy_id', widget.academyId)
          .eq('book_id', widget.bookId)
          .eq('grade_label', widget.gradeLabel)
          .eq('big_order', scope.bigOrder)
          .eq('mid_order', scope.midOrder)
          .eq('sub_key', scope.subKey)
          .order('raw_page', ascending: true)
          .order('problem_number', ascending: true);
      for (final row in (rows as List).cast<Map<String, dynamic>>()) {
        out.add(<String, dynamic>{
          ...row,
          'scope_label': _scopeLabel(scope),
        });
      }
    }
    return out;
  }

  String _scopeLabel(TextbookAuthoringStageScope scope) {
    final mid =
        scope.midName.trim().isEmpty ? '중${scope.midOrder + 1}' : scope.midName;
    final sub = scope.subName.trim().isEmpty ? scope.subKey : scope.subName;
    return '$mid/$sub';
  }

  Future<void> _loadExistingAnswers() async {
    if (_crops.isEmpty) return;
    final ids = _crops.map((c) => c.id).toList();
    final rows = await _supa
        .from('textbook_problem_answers')
        .select('crop_id, answer_kind, answer_text, answer_latex_2d, '
            'answer_source, raw_page, display_page, bbox_1k, '
            'answer_image_bucket, answer_image_path, answer_image_region_1k, '
            'note')
        .inFilter('crop_id', ids);
    final list = (rows as List).cast<Map<String, dynamic>>();
    _answersByCropId.clear();
    for (final r in list) {
      final cropId = '${r['crop_id'] ?? ''}';
      if (cropId.isEmpty) continue;
      final draft = _AnswerDraft.fromRow(r);
      await _attachAnswerImageUrl(draft, r);
      _answersByCropId[cropId] = draft;
    }
  }

  Future<void> _attachAnswerImageUrl(
    _AnswerDraft draft,
    Map<String, dynamic> row,
  ) async {
    if (draft.kind != 'image') return;
    final bucket = '${row['answer_image_bucket'] ?? ''}'.trim();
    final path = '${row['answer_image_path'] ?? ''}'.trim();
    if (bucket.isEmpty || path.isEmpty) return;
    try {
      draft.answerImageUrl =
          await _supa.storage.from(bucket).createSignedUrl(path, 60 * 30);
    } catch (_) {
      // 미리보기 실패는 저장된 정답 자체를 막지 않는다.
    }
  }

  Future<void> _loadExistingSolRefs() async {
    if (_crops.isEmpty) return;
    final ids = _crops.map((c) => c.id).toList();
    final rows = await _supa
        .from('textbook_problem_solution_refs')
        .select('crop_id, raw_page, display_page, number_region_1k, '
            'content_region_1k')
        .inFilter('crop_id', ids);
    final list = (rows as List).cast<Map<String, dynamic>>();
    _solRefsByCropId.clear();
    for (final r in list) {
      final cropId = '${r['crop_id'] ?? ''}';
      if (cropId.isEmpty) continue;
      _solRefsByCropId[cropId] = _SolRefDraft.fromRow(r);
    }
  }

  // --------------------------------------------------------------- pdf

  Future<PdfDocument?> _ensureAnswerPdf() async {
    if (_answerDocument != null) return _answerDocument;
    if (_loadingAnswerPdf) return null;
    setState(() {
      _loadingAnswerPdf = true;
      _answerPdfError = null;
    });
    try {
      final target = await _pdfService.requestDownloadUrl(
        // Do not pass the Stage-1/body link id here. The gateway resolves
        // `link_id` before the logical `(book, grade, kind)` tuple, so passing
        // it would load the body PDF even when kind='ans'.
        academyId: widget.academyId,
        fileId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        kind: 'ans',
      );
      final url = target.url;
      if (url.isEmpty) throw Exception('empty_download_url');
      final tempDir = await getTemporaryDirectory();
      final safeBook = widget.bookId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final file = File(p.join(
        tempDir.path,
        'stage_${safeBook}_${widget.gradeLabel}_answer.pdf',
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
        _answerDocument = doc;
        _answerLocalPath = file.path;
        _loadingAnswerPdf = false;
      });
      return doc;
    } catch (e) {
      if (!mounted) return null;
      setState(() {
        _loadingAnswerPdf = false;
        _answerPdfError = '$e';
      });
      return null;
    }
  }

  Future<PdfDocument?> _ensureSolutionPdf() async {
    if (_solutionDocument != null) return _solutionDocument;
    if (_loadingSolutionPdf) return null;
    setState(() {
      _loadingSolutionPdf = true;
      _solutionPdfError = null;
    });
    try {
      final target = await _pdfService.requestDownloadUrl(
        // Same reason as `_ensureAnswerPdf`: solution must be resolved by
        // kind, not by the body PDF's resource_file_links.id.
        academyId: widget.academyId,
        fileId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        kind: 'sol',
      );
      final url = target.url;
      if (url.isEmpty) throw Exception('empty_download_url');
      final tempDir = await getTemporaryDirectory();
      final safeBook = widget.bookId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final file = File(p.join(
        tempDir.path,
        'stage_${safeBook}_${widget.gradeLabel}_solution.pdf',
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
        _solutionDocument = doc;
        _solutionLocalPath = file.path;
        _loadingSolutionPdf = false;
      });
      return doc;
    } catch (e) {
      if (!mounted) return null;
      setState(() {
        _loadingSolutionPdf = false;
        _solutionPdfError = '$e';
      });
      return null;
    }
  }

  // --------------------------------------------------------------- stage 2

  Future<void> _runAnswerVlm() async {
    if (_runningAnswerVlm) return;
    final doc = await _ensureAnswerPdf();
    if (doc == null) return;
    if (_crops.isEmpty) {
      _toast('문항 번호가 비어 있어 정답 매칭을 실행할 수 없습니다', error: true);
      return;
    }
    setState(() {
      _runningAnswerVlm = true;
      _answerProgress = 0;
      _answerStatus = '답지 PDF 정답 추출 중…';
    });

    final answerCrops = _crops.where((c) => !c.isSetHeader).toList();
    final expected = <String>[
      for (final c in answerCrops)
        if (c.problemNumber.isNotEmpty) c.problemNumber,
    ];
    if (expected.isEmpty) {
      setState(() {
        _runningAnswerVlm = false;
        _answerStatus = '정답 매칭 대상이 없습니다';
      });
      return;
    }
    final totalPages = doc.pages.length;
    final aggregated = <TextbookVlmAnswerItem>[];
    final imageByNumber = <String, _ImageAnswerCrop>{};

    try {
      for (var page = 1; page <= totalPages; page += 1) {
        if (!mounted) return;
        setState(() {
          _answerStatus = '답지 $page / $totalPages 페이지 분석…';
        });
        Uint8List png;
        try {
          png = await renderPdfPageToPng(
            document: doc,
            pageNumber: page,
            longEdgePx: _kVlmLongEdgePx,
          );
        } catch (e) {
          debugPrint('[stage2] render failed page=$page err=$e');
          continue;
        }
        try {
          final res = await _answerService.extractAnswersOnPage(
            imageBytes: png,
            rawPage: page,
            academyId: widget.academyId,
            bookId: widget.bookId,
            gradeLabel: widget.gradeLabel,
            expectedNumbers: expected,
          );
          for (final it in res.items) {
            if (it.answerText.trim().isEmpty) continue;
            aggregated.add(it);
            if (it.isImage && it.bbox != null) {
              final crop = _cropAnswerImage(png, it.bbox!);
              if (crop != null) {
                imageByNumber.putIfAbsent(it.problemNumber, () => crop);
              }
            }
          }
        } catch (e) {
          debugPrint('[stage2] vlm failed page=$page err=$e');
        }
        if (!mounted) return;
        setState(() {
          _answerProgress = page / totalPages;
        });
      }

      final report = TextbookAnswerMatchReport.match(
        expectedNumbers: expected,
        items: aggregated,
      );
      final byNumber = <String, String>{
        for (final c in answerCrops) c.problemNumber: c.id,
      };
      setState(() {
        for (final entry in report.matched.entries) {
          final cropId = byNumber[entry.key];
          if (cropId == null) continue;
          final vlm = entry.value;
          _answersByCropId[cropId] = _AnswerDraft(
            cropId: cropId,
            problemNumber: entry.key,
            kind: vlm.kind,
            answerText: vlm.answerText,
            answerLatex2d:
                vlm.answerLatex2d.isEmpty ? vlm.answerText : vlm.answerLatex2d,
            source: 'vlm',
            rawPage: null,
            bbox1k: vlm.bbox,
            answerImageBytes: imageByNumber[entry.key]?.pngBytes,
            answerImageRegion1k: vlm.isImage ? vlm.bbox : null,
            answerImageWidthPx: imageByNumber[entry.key]?.width,
            answerImageHeightPx: imageByNumber[entry.key]?.height,
            dirty: true,
          );
        }
        _answerMissing
          ..clear()
          ..addAll(report.missing);
        _runningAnswerVlm = false;
        _answerStatus = report.missing.isEmpty
            ? 'VLM 완료 · 모든 번호 매칭됨'
            : 'VLM 완료 · 누락 ${report.missing.length}개';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _runningAnswerVlm = false;
        _answerStatus = 'VLM 실패: $e';
      });
    }
  }

  Future<void> _saveAnswers() async {
    if (_savingAnswers) return;
    final uploads = <TextbookAnswerUpload>[];
    for (final entry in _answersByCropId.values) {
      if (entry.answerText.trim().isEmpty) continue;
      uploads.add(TextbookAnswerUpload(
        cropId: entry.cropId,
        answerKind: entry.kind,
        answerText: entry.answerText,
        answerLatex2d: entry.answerLatex2d,
        answerSource: entry.source,
        rawPage: entry.rawPage,
        bbox1k: entry.bbox1k,
        answerImagePngBytes: entry.answerImageBytes,
        answerImageRegion1k: entry.answerImageRegion1k,
        answerImageWidthPx: entry.answerImageWidthPx,
        answerImageHeightPx: entry.answerImageHeightPx,
      ));
    }
    if (uploads.isEmpty) {
      _toast('저장할 정답이 없습니다', error: true);
      return;
    }
    setState(() => _savingAnswers = true);
    try {
      final count = await _answerService.batchUpsertAnswers(
        academyId: widget.academyId,
        answers: uploads,
      );
      for (final d in _answersByCropId.values) {
        d.dirty = false;
      }
      if (!mounted) return;
      _toast('$count개 정답 저장 완료');
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      _toast('저장 실패: $e', error: true);
    } finally {
      if (mounted) setState(() => _savingAnswers = false);
    }
  }

  void _editAnswerText(String cropId, String problemNumber) {
    final existing = _answersByCropId[cropId] ??
        _AnswerDraft(
          cropId: cropId,
          problemNumber: problemNumber,
          kind: 'subjective',
          answerText: '',
          answerLatex2d: '',
          source: 'manual',
        );
    final ctrl = TextEditingController(text: existing.answerText);
    String kind = existing.kind;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: _kPanel,
              title: Text(
                '$problemNumber 번 정답 편집',
                style: const TextStyle(color: _kText, fontSize: 14),
              ),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('유형',
                            style: TextStyle(color: _kTextSub, fontSize: 12)),
                        const SizedBox(width: 8),
                        DropdownButton<String>(
                          dropdownColor: _kCard,
                          value: kind,
                          items: const [
                            DropdownMenuItem(
                                value: 'objective',
                                child: Text('객관식',
                                    style: TextStyle(color: _kText))),
                            DropdownMenuItem(
                                value: 'subjective',
                                child: Text('주관식',
                                    style: TextStyle(color: _kText))),
                          ],
                          onChanged: (v) =>
                              setLocal(() => kind = v ?? 'subjective'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: ctrl,
                      autofocus: true,
                      maxLines: 3,
                      style: const TextStyle(color: _kText),
                      decoration: InputDecoration(
                        hintText: kind == 'objective'
                            ? '예: ③ 또는 ①'
                            : '예: \\dfrac{3}{4}',
                        hintStyle:
                            const TextStyle(color: _kTextSub, fontSize: 12),
                        filled: true,
                        fillColor: _kCard,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: const BorderSide(color: _kBorder),
                        ),
                      ),
                    ),
                    if (kind == 'subjective' && ctrl.text.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: _kCard,
                            border: Border.all(color: _kBorder),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: LatexTextRenderer(
                            '\\(${ctrl.text.trim()}\\)',
                            style: const TextStyle(color: _kText),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: () {
                    final text = ctrl.text.trim();
                    setState(() {
                      _answersByCropId[cropId] = _AnswerDraft(
                        cropId: cropId,
                        problemNumber: problemNumber,
                        kind: kind,
                        answerText: text,
                        answerLatex2d: kind == 'subjective' ? text : '',
                        source: 'manual',
                        rawPage: existing.rawPage,
                        bbox1k: existing.bbox1k,
                        dirty: true,
                      );
                    });
                    Navigator.of(ctx).pop();
                  },
                  style: FilledButton.styleFrom(backgroundColor: _kAccent),
                  child: const Text('저장'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _pickObjective(String cropId, String problemNumber, String circled) {
    final prev = _answersByCropId[cropId];
    setState(() {
      _answersByCropId[cropId] = _AnswerDraft(
        cropId: cropId,
        problemNumber: problemNumber,
        kind: 'objective',
        answerText: circled,
        answerLatex2d: '',
        source: 'manual',
        rawPage: prev?.rawPage,
        bbox1k: prev?.bbox1k,
        dirty: true,
      );
    });
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

  // --------------------------------------------------------------- stage 3

  Future<void> _runSolutionRefVlm() async {
    if (_runningSolRefVlm) return;
    final doc = await _ensureSolutionPdf();
    if (doc == null) return;
    if (_crops.isEmpty) {
      _toast('문항 번호가 비어 있어 해설 좌표 탐지를 실행할 수 없습니다', error: true);
      return;
    }
    setState(() {
      _runningSolRefVlm = true;
      _solRefProgress = 0;
      _solRefStatus = '해설 PDF 분석 중…';
    });

    final expected = <String>[
      for (final c in _crops)
        if (c.problemNumber.isNotEmpty) c.problemNumber,
    ];
    final totalPages = doc.pages.length;
    final aggregated =
        <String, _SolutionRefWithPage>{}; // problem_number -> draft

    try {
      for (var page = 1; page <= totalPages; page += 1) {
        if (!mounted) return;
        setState(() {
          _solRefStatus = '해설 $page / $totalPages 페이지 분석…';
        });
        Uint8List png;
        try {
          png = await renderPdfPageToPng(
            document: doc,
            pageNumber: page,
            longEdgePx: _kVlmLongEdgePx,
          );
        } catch (e) {
          debugPrint('[stage3] render failed page=$page err=$e');
          continue;
        }
        try {
          final res = await _solRefService.detectOnPage(
            imageBytes: png,
            rawPage: page,
            academyId: widget.academyId,
            bookId: widget.bookId,
            gradeLabel: widget.gradeLabel,
            expectedNumbers: expected,
          );
          for (final it in res.items) {
            aggregated.putIfAbsent(
              it.problemNumber,
              () => _SolutionRefWithPage(
                item: it,
                rawPage: res.rawPage,
                displayPage: res.displayPage,
              ),
            );
          }
        } catch (e) {
          debugPrint('[stage3] vlm failed page=$page err=$e');
        }
        if (!mounted) return;
        setState(() {
          _solRefProgress = page / totalPages;
        });
      }

      final byNumber = <String, String>{
        for (final c in _crops) c.problemNumber: c.id,
      };
      final missing = <String>[];
      setState(() {
        for (final c in _crops) {
          final found = aggregated[c.problemNumber];
          final cropId = byNumber[c.problemNumber];
          if (cropId == null) continue;
          if (found == null) {
            missing.add(c.problemNumber);
            continue;
          }
          _solRefsByCropId[cropId] = _SolRefDraft(
            cropId: cropId,
            problemNumber: c.problemNumber,
            rawPage: found.rawPage,
            displayPage: found.displayPage,
            numberRegion1k: found.item.numberRegion1k,
            contentRegion1k: found.item.contentRegion1k,
            source: 'vlm',
            dirty: true,
          );
        }
        _solRefMissing
          ..clear()
          ..addAll(missing);
        _runningSolRefVlm = false;
        _solRefStatus = missing.isEmpty
            ? 'VLM 완료 · 모든 번호 좌표 확보'
            : 'VLM 완료 · 누락 ${missing.length}개';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _runningSolRefVlm = false;
        _solRefStatus = 'VLM 실패: $e';
      });
    }
  }

  Future<void> _saveSolutionRefs() async {
    if (_savingSolRefs) return;
    final uploads = <TextbookSolutionRefUpload>[];
    for (final d in _solRefsByCropId.values) {
      uploads.add(TextbookSolutionRefUpload(
        cropId: d.cropId,
        rawPage: d.rawPage,
        displayPage: d.displayPage,
        numberRegion1k: d.numberRegion1k,
        contentRegion1k: d.contentRegion1k,
        source: d.source,
      ));
    }
    if (uploads.isEmpty) {
      _toast('저장할 해설 좌표가 없습니다', error: true);
      return;
    }
    setState(() => _savingSolRefs = true);
    try {
      final count = await _solRefService.batchUpsertSolutionRefs(
        academyId: widget.academyId,
        refs: uploads,
      );
      for (final d in _solRefsByCropId.values) {
        d.dirty = false;
      }
      if (!mounted) return;
      _toast('$count개 해설 좌표 저장 완료');
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      _toast('저장 실패: $e', error: true);
    } finally {
      if (mounted) setState(() => _savingSolRefs = false);
    }
  }

  // --------------------------------------------------------------- UI

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
            Container(
              color: _kPanel,
              child: TabBar(
                controller: _tab,
                indicatorColor: _kAccent,
                labelColor: _kText,
                unselectedLabelColor: _kTextSub,
                labelStyle:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                tabs: const [
                  Tab(icon: Icon(Icons.check_circle_outline), text: '정답 매칭'),
                  Tab(icon: Icon(Icons.location_searching), text: '해설 좌표'),
                ],
              ),
            ),
            Expanded(
              child: _loadingCrops
                  ? const Center(
                      child: CircularProgressIndicator(color: _kAccent),
                    )
                  : _cropsError != null
                      ? Center(
                          child: Text(
                            '문항 번호를 불러오지 못했습니다\n$_cropsError',
                            textAlign: TextAlign.center,
                            style:
                                const TextStyle(color: _kDanger, fontSize: 13),
                          ),
                        )
                      : TabBarView(
                          controller: _tab,
                          children: [
                            _buildStage2Tab(),
                            _buildStage3Tab(),
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final bigPart = (widget.bigName ?? '').isEmpty ? '대단원' : widget.bigName!;
    final midPart = (widget.midName ?? '').isEmpty ? '중단원' : widget.midName!;
    final scopeTitle = widget.batchScopes.isEmpty
        ? '$bigPart / $midPart (${widget.subKey})'
        : '선택 ${widget.batchScopes.length}개 소단원';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.task_alt, color: _kAccent, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '정답·해설 단계 · ${widget.bookName} · $scopeTitle',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _kText,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            '${_crops.length}개 문항',
            style: const TextStyle(color: _kTextSub, fontSize: 12),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back, size: 14),
            label: const Text('뒤로'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _kTextSub,
              side: const BorderSide(color: _kBorder),
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '닫기',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close, color: _kTextSub, size: 18),
          ),
        ],
      ),
    );
  }

  // ================================================================ Stage 2

  Widget _buildStage2Tab() {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: _buildAnswerViewer(),
        ),
        const VerticalDivider(width: 1, color: _kBorder),
        Expanded(
          flex: 2,
          child: _buildAnswerRightPane(),
        ),
      ],
    );
  }

  Widget _buildAnswerViewer() {
    if (_loadingAnswerPdf) {
      return const Center(
        child: CircularProgressIndicator(color: _kAccent),
      );
    }
    if (_answerPdfError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '답지 PDF 로드 실패\n$_answerPdfError',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _kDanger, fontSize: 12),
          ),
        ),
      );
    }
    if (_answerLocalPath == null) {
      return Center(
        child: FilledButton.icon(
          onPressed: () => _ensureAnswerPdf(),
          icon: const Icon(Icons.picture_as_pdf, size: 16),
          label: const Text('답지 PDF 불러오기'),
          style: FilledButton.styleFrom(backgroundColor: _kAccent),
        ),
      );
    }
    return Container(
      color: _kCard,
      child: PdfViewer.file(
        _answerLocalPath!,
        controller: _answerViewerController,
        params: PdfViewerParams(
          margin: 16,
          backgroundColor: _kCard,
          layoutPages: _layoutTwoPageSpread,
          viewerOverlayBuilder: (context, size, handleLinkTap) => [
            PdfViewerScrollThumb(
              controller: _answerViewerController,
              orientation: ScrollbarOrientation.right,
            ),
            PdfViewerScrollThumb(
              controller: _answerViewerController,
              orientation: ScrollbarOrientation.bottom,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnswerRightPane() {
    return Container(
      color: _kPanel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                FilledButton.icon(
                  onPressed: _runningAnswerVlm ? null : _runAnswerVlm,
                  icon: _runningAnswerVlm
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _kText,
                          ),
                        )
                      : const Icon(Icons.auto_awesome, size: 14),
                  label: const Text('정답 VLM 실행'),
                  style: FilledButton.styleFrom(backgroundColor: _kAccent),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: (_savingAnswers || _runningAnswerVlm)
                      ? null
                      : _saveAnswers,
                  icon: _savingAnswers
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _kText,
                          ),
                        )
                      : const Icon(Icons.save, size: 14),
                  label: const Text('저장'),
                  style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF3A4A5E)),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: _runningAnswerVlm ? null : () => _tab.animateTo(1),
                  icon: const Icon(Icons.arrow_forward, size: 14),
                  label: const Text('다음: 해설 좌표'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _kTextSub,
                    side: const BorderSide(color: _kBorder),
                  ),
                ),
              ],
            ),
          ),
          if (_runningAnswerVlm || _answerStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(
                    value: _runningAnswerVlm ? _answerProgress : null,
                    backgroundColor: _kCard,
                    color: _kAccent,
                    minHeight: 3,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _answerStatus,
                    style: const TextStyle(color: _kTextSub, fontSize: 11),
                  ),
                ],
              ),
            ),
          if (_answerMissing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A1E),
                  border: Border.all(color: _kWarn.withValues(alpha: 0.6)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'VLM이 찾지 못한 번호: ${_answerMissing.join(', ')}',
                  style: const TextStyle(color: _kWarn, fontSize: 11),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _crops.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (context, i) {
                final crop = _crops[i];
                return _buildAnswerRow(crop);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnswerRow(_StageCrop crop) {
    if (crop.isSetHeader) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: _kCard,
          border: Border.all(color: _kWarn.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 56,
              child: Text(
                crop.problemNumber,
                style: const TextStyle(
                  color: _kWarn,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const Expanded(
              child: Text(
                '세트 공통문항 · 정답 VLM 제외',
                style: TextStyle(color: _kWarn, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }
    final draft = _answersByCropId[crop.id];
    final kind = draft?.kind ?? 'subjective';
    final hasAnswer = draft != null && draft.answerText.trim().isNotEmpty;
    final dirty = draft?.dirty == true;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(
          color: dirty ? _kAccent.withValues(alpha: 0.8) : _kBorder,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  crop.problemNumber,
                  style: const TextStyle(
                    color: _kText,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (crop.scopeLabel.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    crop.scopeLabel,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _kTextSub, fontSize: 10),
                  ),
                ],
                if (crop.contentGroupDisplay.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  _GroupChip(text: crop.contentGroupDisplay),
                ],
                if (crop.displayPage != null)
                  Text(
                    'p.${crop.displayPage}',
                    style: const TextStyle(color: _kTextSub, fontSize: 10),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _KindChip(kind: kind),
                    const SizedBox(width: 6),
                    if (hasAnswer && draft.source == 'vlm')
                      const _SourceChip(text: 'VLM', color: _kInfo),
                    if (hasAnswer && draft.source == 'manual')
                      const _SourceChip(text: '수정됨', color: _kAccent),
                  ],
                ),
                const SizedBox(height: 6),
                if (kind == 'image')
                  _buildAnswerImagePreview(draft)
                else if (kind == 'objective')
                  Wrap(
                    spacing: 4,
                    children: [
                      for (final c in const ['①', '②', '③', '④', '⑤'])
                        GestureDetector(
                          onTap: () =>
                              _pickObjective(crop.id, crop.problemNumber, c),
                          child: Container(
                            width: 26,
                            height: 26,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: (hasAnswer && draft.answerText.trim() == c)
                                  ? _kAccent.withValues(alpha: 0.25)
                                  : _kPanel,
                              border: Border.all(
                                color:
                                    (hasAnswer && draft.answerText.trim() == c)
                                        ? _kAccent
                                        : _kBorder,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              c,
                              style: const TextStyle(
                                color: _kText,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                    ],
                  )
                else if (hasAnswer)
                  LatexTextRenderer(
                    '\\(${draft.answerText}\\)',
                    style: const TextStyle(color: _kText, fontSize: 13),
                  )
                else
                  const Text(
                    '정답 없음',
                    style: TextStyle(color: _kTextSub, fontSize: 11),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: '편집',
            onPressed: () => _editAnswerText(crop.id, crop.problemNumber),
            icon: const Icon(Icons.edit, size: 14, color: _kTextSub),
          ),
        ],
      ),
    );
  }

  Widget _buildAnswerImagePreview(_AnswerDraft? draft) {
    final bytes = draft?.answerImageBytes;
    final url = draft?.answerImageUrl?.trim() ?? '';
    Widget child;
    if (bytes != null && bytes.isNotEmpty) {
      child = Image.memory(bytes, fit: BoxFit.contain);
    } else if (url.isNotEmpty) {
      child = Image.network(url, fit: BoxFit.contain);
    } else {
      child = const Center(
        child: Text(
          '그림 정답 미리보기 없음',
          style: TextStyle(color: _kTextSub, fontSize: 11),
        ),
      );
    }
    return Container(
      constraints: const BoxConstraints(maxHeight: 96, minHeight: 44),
      width: double.infinity,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: _kPanel,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: child,
    );
  }

  // ================================================================ Stage 3

  Widget _buildStage3Tab() {
    return Row(
      children: [
        Expanded(flex: 3, child: _buildSolutionViewer()),
        const VerticalDivider(width: 1, color: _kBorder),
        Expanded(flex: 2, child: _buildSolutionRightPane()),
      ],
    );
  }

  Widget _buildSolutionViewer() {
    if (_loadingSolutionPdf) {
      return const Center(
        child: CircularProgressIndicator(color: _kAccent),
      );
    }
    if (_solutionPdfError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '해설 PDF 로드 실패\n$_solutionPdfError',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _kDanger, fontSize: 12),
          ),
        ),
      );
    }
    if (_solutionLocalPath == null) {
      return Center(
        child: FilledButton.icon(
          onPressed: () => _ensureSolutionPdf(),
          icon: const Icon(Icons.picture_as_pdf, size: 16),
          label: const Text('해설 PDF 불러오기'),
          style: FilledButton.styleFrom(backgroundColor: _kAccent),
        ),
      );
    }
    return Container(
      color: _kCard,
      child: PdfViewer.file(
        _solutionLocalPath!,
        controller: _solutionViewerController,
        params: PdfViewerParams(
          margin: 16,
          backgroundColor: _kCard,
          layoutPages: _layoutTwoPageSpread,
          viewerOverlayBuilder: (context, size, handleLinkTap) => [
            PdfViewerScrollThumb(
              controller: _solutionViewerController,
              orientation: ScrollbarOrientation.right,
            ),
            PdfViewerScrollThumb(
              controller: _solutionViewerController,
              orientation: ScrollbarOrientation.bottom,
            ),
          ],
          pageOverlaysBuilder: (context, pageRect, page) =>
              _buildSolutionOverlays(
            pageNumber: page.pageNumber,
            pageRect: pageRect,
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSolutionOverlays({
    required int pageNumber,
    required Rect pageRect,
  }) {
    final widgets = <Widget>[];
    for (final d in _solRefsByCropId.values) {
      if (d.rawPage != pageNumber) continue;
      final region = d.numberRegion1k;
      if (region.length != 4) continue;
      final ymin = region[0] / 1000;
      final xmin = region[1] / 1000;
      final ymax = region[2] / 1000;
      final xmax = region[3] / 1000;
      final left = xmin * pageRect.width;
      final top = ymin * pageRect.height;
      final width = (xmax - xmin) * pageRect.width;
      final height = (ymax - ymin) * pageRect.height;
      widgets.add(Positioned(
        left: left,
        top: top,
        width: math.max(width, 6),
        height: math.max(height, 6),
        child: IgnorePointer(
          child: Container(
            decoration: BoxDecoration(
              color: _kInfo.withValues(alpha: 0.12),
              border: Border.all(color: _kInfo, width: 1.4),
              borderRadius: BorderRadius.circular(3),
            ),
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              child: Text(
                d.problemNumber,
                style: const TextStyle(
                  color: _kInfo,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ));
    }
    return widgets;
  }

  Widget _buildSolutionRightPane() {
    return Container(
      color: _kPanel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                FilledButton.icon(
                  onPressed: _runningSolRefVlm ? null : _runSolutionRefVlm,
                  icon: _runningSolRefVlm
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _kText,
                          ),
                        )
                      : const Icon(Icons.location_searching, size: 14),
                  label: const Text('해설 VLM 실행'),
                  style: FilledButton.styleFrom(backgroundColor: _kAccent),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: (_savingSolRefs || _runningSolRefVlm)
                      ? null
                      : _saveSolutionRefs,
                  icon: _savingSolRefs
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _kText,
                          ),
                        )
                      : const Icon(Icons.save, size: 14),
                  label: const Text('저장'),
                  style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF3A4A5E)),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: (_runningSolRefVlm || _savingSolRefs)
                      ? null
                      : _completeIfReady,
                  icon: _loadingPbRuns
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _kText,
                          ),
                        )
                      : const Icon(Icons.done_all, size: 14),
                  label: const Text('완료'),
                  style: FilledButton.styleFrom(backgroundColor: _kAccent),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '본문 문제 추출: $_pbRunStatusText',
              style: TextStyle(
                color: _allPbRunsFinished ? _kAccent : _kTextSub,
                fontSize: 11,
              ),
            ),
          ),
          if (_runningSolRefVlm || _solRefStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(
                    value: _runningSolRefVlm ? _solRefProgress : null,
                    backgroundColor: _kCard,
                    color: _kAccent,
                    minHeight: 3,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _solRefStatus,
                    style: const TextStyle(color: _kTextSub, fontSize: 11),
                  ),
                ],
              ),
            ),
          if (_solRefMissing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A1E),
                  border: Border.all(color: _kWarn.withValues(alpha: 0.6)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '해설 PDF에서 찾지 못한 번호: ${_solRefMissing.join(', ')}',
                  style: const TextStyle(color: _kWarn, fontSize: 11),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _crops.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (context, i) {
                final crop = _crops[i];
                return _buildSolutionRow(crop);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSolutionRow(_StageCrop crop) {
    final d = _solRefsByCropId[crop.id];
    final hasCoord = d != null;
    final dirty = d?.dirty == true;
    return InkWell(
      onTap: hasCoord
          ? () {
              _solutionViewerController.goToPage(pageNumber: d.rawPage);
            }
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: _kCard,
          border: Border.all(
            color: dirty
                ? _kAccent.withValues(alpha: 0.8)
                : (hasCoord ? _kBorder : _kWarn.withValues(alpha: 0.5)),
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 56,
              child: Text(
                crop.problemNumber,
                style: const TextStyle(
                  color: _kText,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Expanded(
              child: hasCoord
                  ? Text(
                      '해설 p.${d.displayPage ?? d.rawPage}  ·  raw ${d.rawPage}',
                      style: const TextStyle(
                        color: _kTextSub,
                        fontSize: 11,
                      ),
                    )
                  : const Text(
                      '좌표 없음',
                      style: TextStyle(color: _kWarn, fontSize: 11),
                    ),
            ),
            if (hasCoord && d.source == 'vlm')
              const _SourceChip(text: 'VLM', color: _kInfo),
            if (hasCoord && d.source == 'manual')
              const _SourceChip(text: '수정됨', color: _kAccent),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------- helpers

  PdfPageLayout _layoutTwoPageSpread(
      List<PdfPage> pages, PdfViewerParams params) {
    if (pages.isEmpty) {
      return PdfPageLayout(
        pageLayouts: const <Rect>[],
        documentSize: Size.zero,
      );
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

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? _kDanger : _kAccent,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  List<TextbookAuthoringStageScope> get _activeScopes =>
      widget.batchScopes.isNotEmpty
          ? widget.batchScopes
          : <TextbookAuthoringStageScope>[
              TextbookAuthoringStageScope(
                bigOrder: widget.bigOrder,
                midOrder: widget.midOrder,
                subKey: widget.subKey,
                bigName: widget.bigName ?? '',
                midName: widget.midName ?? '',
              ),
            ];

  String _scopeKey(TextbookAuthoringStageScope scope) =>
      '${scope.bigOrder}:${scope.midOrder}:${scope.subKey}';

  bool get _allPbRunsFinished {
    if (_activeScopes.isEmpty) return true;
    for (final scope in _activeScopes) {
      final status = _pbRunStatusByKey[_scopeKey(scope)] ?? '';
      if (status != 'completed' &&
          status != 'review_required' &&
          status != 'failed' &&
          status != 'cancelled') {
        return false;
      }
    }
    return true;
  }

  String get _pbRunStatusText {
    if (_pbRunStatusByKey.isEmpty) return '본문 추출 상태 확인 전';
    final counts = <String, int>{};
    for (final status in _pbRunStatusByKey.values) {
      counts[status] = (counts[status] ?? 0) + 1;
    }
    return counts.entries.map((e) => '${e.key} ${e.value}').join(' · ');
  }

  Future<void> _refreshPbRunStatuses() async {
    if (_loadingPbRuns) return;
    if (!mounted) return;
    setState(() => _loadingPbRuns = true);
    try {
      final next = <String, String>{};
      for (final scope in _activeScopes) {
        final row = await _supa
            .from('textbook_pb_extract_runs')
            .select('status')
            .eq('academy_id', widget.academyId)
            .eq('book_id', widget.bookId)
            .eq('grade_label', widget.gradeLabel)
            .eq('big_order', scope.bigOrder)
            .eq('mid_order', scope.midOrder)
            .eq('sub_key', scope.subKey)
            .maybeSingle();
        next[_scopeKey(scope)] = '${row?['status'] ?? ''}'.trim();
      }
      if (!mounted) return;
      setState(() {
        _pbRunStatusByKey
          ..clear()
          ..addAll(next);
      });
    } catch (_) {
      // 신규 마이그레이션 전 환경에서는 완료 버튼을 막지 않는다.
    } finally {
      if (mounted) setState(() => _loadingPbRuns = false);
    }
  }

  Future<void> _completeIfReady() async {
    await _refreshPbRunStatuses();
    if (!mounted) return;
    if (!_allPbRunsFinished) {
      _toast('본문 문제 추출이 아직 진행 중입니다: $_pbRunStatusText', error: true);
      return;
    }
    Navigator.of(context).maybePop();
  }
}

class _StageCrop {
  const _StageCrop({
    required this.id,
    required this.problemNumber,
    required this.rawPage,
    required this.displayPage,
    required this.section,
    required this.isSetHeader,
    this.contentGroupKind = 'none',
    this.contentGroupLabel = '',
    this.contentGroupTitle = '',
    this.contentGroupOrder,
    this.scopeLabel = '',
  });

  final String id;
  final String problemNumber;
  final int? rawPage;
  final int? displayPage;
  final String section;
  final bool isSetHeader;
  final String contentGroupKind;
  final String contentGroupLabel;
  final String contentGroupTitle;
  final int? contentGroupOrder;
  final String scopeLabel;

  String get contentGroupDisplay {
    final label = contentGroupLabel.trim();
    final title = contentGroupTitle.trim();
    if (label.isEmpty && title.isEmpty) return '';
    if (label.isEmpty) return title;
    if (title.isEmpty) return label;
    return '$label $title';
  }

  factory _StageCrop.fromRow(Map<String, dynamic> r) {
    int? asIntN(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('$v');
    }

    return _StageCrop(
      id: '${r['id'] ?? ''}',
      problemNumber: '${r['problem_number'] ?? ''}'.trim(),
      rawPage: asIntN(r['raw_page']),
      displayPage: asIntN(r['display_page']),
      section: '${r['section'] ?? ''}',
      isSetHeader: r['is_set_header'] == true,
      contentGroupKind: '${r['content_group_kind'] ?? 'none'}',
      contentGroupLabel: '${r['content_group_label'] ?? ''}'.trim(),
      contentGroupTitle: '${r['content_group_title'] ?? ''}'.trim(),
      contentGroupOrder: asIntN(r['content_group_order']),
      scopeLabel: '${r['scope_label'] ?? ''}'.trim(),
    );
  }

  factory _StageCrop.fromSeed(TextbookAuthoringStageCropSeed seed) {
    return _StageCrop(
      id: seed.id,
      problemNumber: seed.problemNumber,
      rawPage: seed.rawPage,
      displayPage: seed.displayPage,
      section: seed.section,
      isSetHeader: seed.isSetHeader,
      contentGroupKind: seed.contentGroupKind,
      contentGroupLabel: seed.contentGroupLabel,
      contentGroupTitle: seed.contentGroupTitle,
      contentGroupOrder: seed.contentGroupOrder,
      scopeLabel: '',
    );
  }
}

class _AnswerDraft {
  _AnswerDraft({
    required this.cropId,
    required this.problemNumber,
    required this.kind,
    required this.answerText,
    required this.answerLatex2d,
    required this.source,
    this.rawPage,
    this.bbox1k,
    this.answerImageBytes,
    this.answerImageRegion1k,
    this.answerImageWidthPx,
    this.answerImageHeightPx,
    this.answerImagePath,
    this.dirty = false,
  });

  final String cropId;
  final String problemNumber;
  String kind; // 'objective' | 'subjective' | 'image'
  String answerText;
  String answerLatex2d;
  String source; // 'vlm' | 'manual'
  int? rawPage;
  List<int>? bbox1k;
  Uint8List? answerImageBytes;
  List<int>? answerImageRegion1k;
  int? answerImageWidthPx;
  int? answerImageHeightPx;
  String? answerImagePath;
  String? answerImageUrl;
  bool dirty;

  factory _AnswerDraft.fromRow(Map<String, dynamic> r) {
    int? asIntN(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('$v');
    }

    List<int>? parseBbox(dynamic raw) {
      if (raw is! List || raw.length != 4) return null;
      final out = <int>[];
      for (final v in raw) {
        final n = asIntN(v);
        if (n == null) return null;
        out.add(n);
      }
      return out;
    }

    return _AnswerDraft(
      cropId: '${r['crop_id'] ?? ''}',
      problemNumber: '',
      kind: '${r['answer_kind'] ?? 'subjective'}',
      answerText: '${r['answer_text'] ?? ''}',
      answerLatex2d: '${r['answer_latex_2d'] ?? ''}',
      source: '${r['answer_source'] ?? 'vlm'}',
      rawPage: asIntN(r['raw_page']),
      bbox1k: parseBbox(r['bbox_1k']),
      answerImageRegion1k: parseBbox(r['answer_image_region_1k']),
      answerImagePath: '${r['answer_image_path'] ?? ''}',
    );
  }
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

class _SolRefDraft {
  _SolRefDraft({
    required this.cropId,
    required this.problemNumber,
    required this.rawPage,
    required this.numberRegion1k,
    this.displayPage,
    this.contentRegion1k,
    this.source = 'vlm',
    this.dirty = false,
  });

  final String cropId;
  final String problemNumber;
  int rawPage;
  int? displayPage;
  List<int> numberRegion1k;
  List<int>? contentRegion1k;
  String source;
  bool dirty;

  factory _SolRefDraft.fromRow(Map<String, dynamic> r) {
    int? asIntN(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('$v');
    }

    List<int> parseBboxReq(dynamic raw) {
      if (raw is! List || raw.length != 4) return const [0, 0, 0, 0];
      final out = <int>[];
      for (final v in raw) {
        final n = asIntN(v);
        if (n == null) return const [0, 0, 0, 0];
        out.add(n);
      }
      return out;
    }

    List<int>? parseBbox(dynamic raw) {
      if (raw is! List || raw.length != 4) return null;
      final out = <int>[];
      for (final v in raw) {
        final n = asIntN(v);
        if (n == null) return null;
        out.add(n);
      }
      return out;
    }

    return _SolRefDraft(
      cropId: '${r['crop_id'] ?? ''}',
      problemNumber: '',
      rawPage: asIntN(r['raw_page']) ?? 0,
      displayPage: asIntN(r['display_page']),
      numberRegion1k: parseBboxReq(r['number_region_1k']),
      contentRegion1k: parseBbox(r['content_region_1k']),
    );
  }
}

class _SolutionRefWithPage {
  _SolutionRefWithPage({
    required this.item,
    required this.rawPage,
    required this.displayPage,
  });

  final TextbookVlmSolutionRefItem item;
  final int rawPage;
  final int displayPage;
}

class _KindChip extends StatelessWidget {
  const _KindChip({required this.kind});
  final String kind;

  @override
  Widget build(BuildContext context) {
    final isObj = kind == 'objective';
    final isImage = kind == 'image';
    final color = isObj
        ? const Color(0xFF7AA9E6)
        : isImage
            ? const Color(0xFFE6C07A)
            : const Color(0xFFE67AA9);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        isObj
            ? '객관식'
            : isImage
                ? '그림'
                : '주관식',
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _GroupChip extends StatelessWidget {
  const _GroupChip({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF242018),
        border:
            Border.all(color: const Color(0xFFEAB968).withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Color(0xFFEAB968),
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
