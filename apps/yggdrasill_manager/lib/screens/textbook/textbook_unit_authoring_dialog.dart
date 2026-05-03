// Unit tree authoring + VLM analysis dialog (coordinate-only redesign).
//
// After the pivot away from client-side cropping, this dialog no longer
// decodes/stores/exports per-problem PNGs. Instead it:
//
//   1. Loads the unit tree from `textbook_metadata.payload` and lets the
//      operator edit 대/중단원 names and A/B/C start/end pages (unchanged).
//   2. Runs the VLM problem-number detection for one 소단원 at a time,
//      accumulating the normalised bounding boxes in memory.
//   3. Renders the body PDF with `PdfViewer.file` + `pageOverlaysBuilder`
//      so the user can visually confirm the detected regions on the real
//      PDF — two pages per row (layoutPages) so spreads are easier to
//      review.
//   4. Supports **manual fine-tuning**: click a bbox → drag its four
//      corner handles → the stored `item_region_1k` is overridden.
//   5. Saves the coordinates (no images) via `TextbookCropUploader` in
//      `regions_only` mode.
//   6. A "다음 →" button opens the Stage 2/3 authoring dialog
//      (`TextbookAuthoringStageDialog`) for 정답 VLM / 해설 좌표 VLM.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/textbook_book_registry.dart';
import '../../services/textbook_crop_uploader.dart';
import '../../services/textbook_pdf_page_renderer.dart';
import '../../services/textbook_pdf_service.dart';
import '../../services/textbook_series_catalog.dart';
import '../../services/textbook_vlm_range_runner.dart';
import '../../services/textbook_vlm_test_service.dart';
import '../../services/problem_bank_service.dart';
import 'textbook_authoring_stage_dialog.dart';

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

  final _registry = TextbookBookRegistry();
  final _pdfService = TextbookPdfService();
  final _vlmService = TextbookVlmTestService();
  final _cropUploader = TextbookCropUploader();
  final _pbService = ProblemBankService();
  final _supa = Supabase.instance.client;

  PdfDocument? _bodyDocument;
  String? _bodyLocalPath;
  String? _pdfLoadError;
  bool _loadingPdf = false;
  final _viewerController = PdfViewerController();

  bool _loadingPayload = true;
  String? _payloadError;
  String _seriesKey = kTextbookSeriesCatalog.first.key;
  int _pageOffset = 0;
  final List<_BigUnitEdit> _bigUnits = <_BigUnitEdit>[];

  _SubFocus? _focus;

  // Per-sub VLM state. Keyed by '<big>/<mid>/<sub>' so switching tabs keeps
  // previously computed results visible.
  final Map<String, _SubRunState> _subStates = <String, _SubRunState>{};

  // Manual item_region overrides. Outer key = state key, inner key = problem
  // key (rawPage + ':' + 0-based order). When present, the stored value
  // wins over the VLM's original `item.itemRegion`.
  final Map<String, Map<String, List<int>>> _manualEdits =
      <String, Map<String, List<int>>>{};

  final Set<String> _batchSelection = <String>{};
  final Map<String, String> _pbExtractStatusBySub = <String, String>{};
  final Map<String, TextbookStageScopeStatus> _stageStatusBySub =
      <String, TextbookStageScopeStatus>{};
  bool _loadingStageStatuses = false;
  _EmbeddedStageArgs? _embeddedStage;
  bool _batchRunning = false;
  int _batchDone = 0;
  int _batchTotal = 0;
  String _batchStatus = '';

  // Single-selection for the corner-handle editor. Null ⇒ no handles drawn.
  String? _selectedProblemKey;

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
      final pageOffset = int.tryParse('${row?['page_offset'] ?? 0}') ?? 0;
      final entry = textbookSeriesByKey(series) ?? kTextbookSeriesCatalog.first;
      final loaded = bigUnitsFromPayload(payload, seriesKey: entry.key);
      final editable = <_BigUnitEdit>[];
      for (final big in loaded) {
        final bigEdit = _BigUnitEdit(bigName: big.bigName);
        for (final mid in big.middles) {
          final midEdit = _MidUnitEdit(series: entry, midName: mid.midName);
          for (final sub in mid.subs) {
            for (final slot in midEdit.subs) {
              if (slot.preset.key == sub.subKey) {
                slot.startCtrl.text =
                    sub.startPage == null ? '' : '${sub.startPage}';
                slot.endCtrl.text = sub.endPage == null ? '' : '${sub.endPage}';
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
        _pageOffset = pageOffset;
        _bigUnits
          ..clear()
          ..addAll(editable);
        _loadingPayload = false;
        _focus = null;
      });
      unawaited(_loadPbExtractRuns());
      unawaited(_loadExistingCrops());
      unawaited(_loadStageStatuses());
      unawaited(_ensurePdf());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingPayload = false;
        _payloadError = '$e';
      });
    }
  }

  Future<void> _loadPbExtractRuns() async {
    try {
      final rows = await _pbService.listTextbookPdfExtractRuns(
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
      );
      if (!mounted) return;
      setState(() {
        _pbExtractStatusBySub.clear();
        for (final row in rows) {
          final focus = _SubFocus(
            bigIndex: int.tryParse('${row['big_order'] ?? ''}') ?? -1,
            midIndex: int.tryParse('${row['mid_order'] ?? ''}') ?? -1,
            subKey: '${row['sub_key'] ?? ''}',
          );
          if (focus.bigIndex < 0 || focus.midIndex < 0) continue;
          _pbExtractStatusBySub[_stateKeyFor(focus)] =
              '${row['status'] ?? 'idle'}';
        }
      });
    } catch (_) {
      // 상태 배지는 보조 정보라 로딩 실패가 오서링 흐름을 막으면 안 된다.
    }
  }

  List<_SubFocus> _allSubFocuses() {
    final out = <_SubFocus>[];
    for (var b = 0; b < _bigUnits.length; b += 1) {
      final big = _bigUnits[b];
      for (var m = 0; m < big.middles.length; m += 1) {
        for (final sub in big.middles[m].subs) {
          out.add(_SubFocus(
            bigIndex: b,
            midIndex: m,
            subKey: sub.preset.key,
          ));
        }
      }
    }
    return out;
  }

  Map<String, dynamic> _stageScopePayload(_SubFocus focus) => <String, dynamic>{
        'big_order': focus.bigIndex,
        'mid_order': focus.midIndex,
        'sub_key': focus.subKey,
      };

  Future<void> _loadStageStatuses() async {
    final focuses = _allSubFocuses();
    if (focuses.isEmpty) return;
    setState(() => _loadingStageStatuses = true);
    try {
      final statuses = await _pdfService.fetchStageStatuses(
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        scopes: [for (final focus in focuses) _stageScopePayload(focus)],
      );
      if (!mounted) return;
      setState(() {
        _stageStatusBySub
          ..clear()
          ..addEntries(statuses.map((s) {
            final focus = _SubFocus(
              bigIndex: s.bigOrder,
              midIndex: s.midOrder,
              subKey: s.subKey,
            );
            return MapEntry(_stateKeyFor(focus), s);
          }));
        _loadingStageStatuses = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingStageStatuses = false);
      debugPrint('[textbook-stage-status] load failed: $e');
    }
  }

  Future<void> _loadExistingCrops() async {
    try {
      final rows = await _supa
          .from('textbook_problem_crops')
          .select('id, raw_page, display_page, section, problem_number, label, '
              'is_set_header, set_from, set_to, content_group_kind, '
              'content_group_label, content_group_title, content_group_order, '
              'column_index, bbox_1k, item_region_1k, big_order, mid_order, '
              'sub_key')
          .eq('academy_id', widget.academyId)
          .eq('book_id', widget.bookId)
          .eq('grade_label', widget.gradeLabel)
          .order('big_order', ascending: true)
          .order('mid_order', ascending: true)
          .order('sub_key', ascending: true)
          .order('raw_page', ascending: true)
          .order('problem_number', ascending: true);
      final byFocus = <String, List<Map<String, dynamic>>>{};
      for (final row in (rows as List).cast<Map<String, dynamic>>()) {
        final focus = _SubFocus(
          bigIndex: int.tryParse('${row['big_order'] ?? ''}') ?? -1,
          midIndex: int.tryParse('${row['mid_order'] ?? ''}') ?? -1,
          subKey: '${row['sub_key'] ?? ''}',
        );
        if (focus.bigIndex < 0 || focus.midIndex < 0) continue;
        byFocus
            .putIfAbsent(_stateKeyFor(focus), () => <Map<String, dynamic>>[])
            .add(row);
      }
      if (!mounted) return;
      setState(() {
        for (final entry in byFocus.entries) {
          final focus = _focusFromStateKey(entry.key);
          if (focus == null) continue;
          final state = _ensureSubState(focus);
          if (state.running ||
              state.uploading ||
              state.pageResults.isNotEmpty) {
            continue;
          }
          state.uploadResult = TextbookCropBatchResult(
            upserted: entry.value.length,
            bucket: 'textbook-crops',
            rows: entry.value,
          );
          state.pageResults
            ..clear()
            ..addAll(_pageRowsFromSavedCrops(entry.value, focus));
          state.phase = '저장된 영역 ${entry.value.length}건';
          state.error = null;
        }
      });
    } catch (_) {
      // 저장된 영역 복원은 보조 기능이다. 실패해도 신규 분석 흐름은 유지한다.
    }
  }

  _SubFocus? _focusFromStateKey(String key) {
    final parts = key.split('/');
    if (parts.length != 3) return null;
    final bigIndex = int.tryParse(parts[0]);
    final midIndex = int.tryParse(parts[1]);
    if (bigIndex == null || midIndex == null) return null;
    if (bigIndex < 0 || bigIndex >= _bigUnits.length) return null;
    if (midIndex < 0 || midIndex >= _bigUnits[bigIndex].middles.length) {
      return null;
    }
    return _SubFocus(
      bigIndex: bigIndex,
      midIndex: midIndex,
      subKey: parts[2],
    );
  }

  int _rawPageForDisplayPage(int displayPage) => displayPage + _pageOffset;

  int _displayPageForRawPage(int rawPage) => rawPage - _pageOffset;

  List<_PageAnalysisRow> _pageRowsFromSavedCrops(
    List<Map<String, dynamic>> rows,
    _SubFocus focus,
  ) {
    int? asIntN(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('$v');
    }

    final byPage = <int, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      final rawPage = asIntN(row['raw_page']);
      if (rawPage == null || rawPage <= 0) continue;
      byPage.putIfAbsent(rawPage, () => <Map<String, dynamic>>[]).add(row);
    }
    final out = <_PageAnalysisRow>[];
    for (final entry in byPage.entries) {
      final first = entry.value.first;
      out.add(_PageAnalysisRow.success(
        rawPage: entry.key,
        displayPage:
            asIntN(first['display_page']) ?? _displayPageForRawPage(entry.key),
        section: '${first['section'] ?? _sectionForSubKey(focus.subKey)}',
        pageKind: 'problem_page',
        notes: 'saved_crops',
        items: [
          for (final row in entry.value)
            _vlmItemFromSavedCrop(row, focus.subKey),
        ],
      ));
    }
    out.sort((a, b) => a.rawPage.compareTo(b.rawPage));
    return out;
  }

  TextbookVlmItem _vlmItemFromSavedCrop(
    Map<String, dynamic> row,
    String subKey,
  ) {
    final section = '${row['section'] ?? _sectionForSubKey(subKey)}';
    final isMastery = subKey == 'C' || section == 'mastery';
    final rawKind = '${row['content_group_kind'] ?? 'none'}'.trim();
    final groupKind =
        isMastery || rawKind != 'type' && rawKind != 'basic_subtopic'
            ? 'none'
            : rawKind;
    return TextbookVlmItem.fromMap(<String, dynamic>{
      'number': row['problem_number'],
      'label': row['label'],
      'is_set_header': row['is_set_header'],
      'set_range': <String, dynamic>{
        'from': row['set_from'],
        'to': row['set_to'],
      },
      'content_group_kind': groupKind,
      'content_group_label':
          groupKind == 'none' ? '' : row['content_group_label'],
      'content_group_title':
          groupKind == 'none' ? '' : row['content_group_title'],
      'content_group_order':
          groupKind == 'none' ? null : row['content_group_order'],
      'column': row['column_index'],
      'bbox': row['bbox_1k'],
      'item_region': row['item_region_1k'],
    });
  }

  _ResolvedContentGroup _rawContentGroupForItem(
    TextbookVlmItem item,
    String subKey,
    String section,
  ) {
    if (subKey == 'C' || section == 'mastery') {
      return const _ResolvedContentGroup.none();
    }
    final kind = item.contentGroupKind.trim();
    if (kind != 'type' && kind != 'basic_subtopic') {
      return const _ResolvedContentGroup.none();
    }
    final label = item.contentGroupLabel.trim();
    final title = item.contentGroupTitle.trim();
    if (label.isEmpty && title.isEmpty) {
      return const _ResolvedContentGroup.none();
    }
    return _ResolvedContentGroup(
      kind: kind,
      label: label,
      title: title,
      order: item.contentGroupOrder,
    );
  }

  String _sectionForSubKey(String subKey) {
    switch (subKey) {
      case 'A':
        return 'basic_drill';
      case 'B':
        return 'type_practice';
      case 'C':
        return 'mastery';
      default:
        return 'unknown';
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
      _toast('단원 구조를 Supabase에 저장했어요.');
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
      final safeBook = widget.bookId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
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
        _bodyLocalPath = file.path;
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

  List<_SubFocus> _selectedBatchFocuses() {
    final out = <_SubFocus>[];
    for (var b = 0; b < _bigUnits.length; b += 1) {
      final big = _bigUnits[b];
      for (var m = 0; m < big.middles.length; m += 1) {
        for (final sub in big.middles[m].subs) {
          final focus = _SubFocus(
            bigIndex: b,
            midIndex: m,
            subKey: sub.preset.key,
          );
          if (_batchSelection.contains(_stateKeyFor(focus))) {
            out.add(focus);
          }
        }
      }
    }
    return out;
  }

  List<_SubFocus> _midBatchFocuses(int bigIndex, int midIndex) {
    final mid = _bigUnits[bigIndex].middles[midIndex];
    return [
      for (final sub in mid.subs)
        _SubFocus(
          bigIndex: bigIndex,
          midIndex: midIndex,
          subKey: sub.preset.key,
        ),
    ];
  }

  void _toggleBatchSub(_SubFocus focus, bool selected) {
    setState(() {
      final key = _stateKeyFor(focus);
      if (selected) {
        _batchSelection.add(key);
        _focus = focus;
        _selectedProblemKey = null;
      } else {
        _batchSelection.remove(key);
        if (_focus != null &&
            _focus!.bigIndex == focus.bigIndex &&
            _focus!.midIndex == focus.midIndex &&
            _focus!.subKey == focus.subKey &&
            _batchSelection.isNotEmpty) {
          final next = _selectedBatchFocuses().first;
          _focus = next;
          _selectedProblemKey = null;
        }
      }
    });
  }

  void _toggleBatchMid(int bigIndex, int midIndex, bool selected) {
    final focuses = _midBatchFocuses(bigIndex, midIndex);
    setState(() {
      for (final focus in focuses) {
        final key = _stateKeyFor(focus);
        if (selected) {
          _batchSelection.add(key);
        } else {
          _batchSelection.remove(key);
        }
      }
      if (selected && focuses.isNotEmpty) {
        _focus = focuses.first;
        _selectedProblemKey = null;
      } else if (_focus != null && _batchSelection.isNotEmpty) {
        final next = _selectedBatchFocuses().first;
        _focus = next;
        _selectedProblemKey = null;
      }
    });
  }

  bool? _midBatchValue(int bigIndex, int midIndex) {
    final focuses = _midBatchFocuses(bigIndex, midIndex);
    if (focuses.isEmpty) return false;
    final selected = focuses
        .where((focus) => _batchSelection.contains(_stateKeyFor(focus)))
        .length;
    if (selected == 0) return false;
    if (selected == focuses.length) return true;
    return null;
  }

  _SubRunState _ensureSubState(_SubFocus focus) {
    final key = _stateKeyFor(focus);
    return _subStates.putIfAbsent(key, () => _SubRunState());
  }

  Map<String, List<int>> _ensureManualEdits(_SubFocus focus) {
    return _manualEdits.putIfAbsent(
      _stateKeyFor(focus),
      () => <String, List<int>>{},
    );
  }

  String _problemKey(int rawPage, int orderIndex) => '$rawPage:$orderIndex';

  /// Returns the currently effective item_region for a problem: the manual
  /// edit if present, else the VLM original (possibly null).
  List<int>? _effectiveItemRegion({
    required _SubFocus focus,
    required int rawPage,
    required int orderIndex,
    required TextbookVlmItem item,
  }) {
    final edits = _manualEdits[_stateKeyFor(focus)];
    final edited = edits?[_problemKey(rawPage, orderIndex)];
    if (edited != null && edited.length == 4) return edited;
    return item.itemRegion;
  }

  Future<void> _runFocusedAnalysis(_SubFocus focus) async {
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final sub = mid.subs.firstWhere(
      (s) => s.preset.key == focus.subKey,
      orElse: () => mid.subs.first,
    );
    final displayStartPage = _positiveInt(sub.startCtrl.text);
    final displayEndPage = _positiveInt(sub.endCtrl.text);
    if (displayStartPage == null ||
        displayEndPage == null ||
        displayEndPage < displayStartPage) {
      _toast('시작/끝 페이지를 먼저 입력하세요', error: true);
      return;
    }
    final rawStartPage = _rawPageForDisplayPage(displayStartPage);
    final rawEndPage = _rawPageForDisplayPage(displayEndPage);
    final doc = await _ensurePdf();
    if (doc == null) return;
    final state = _ensureSubState(focus);
    if (state.running) return;
    // Wipe prior manual edits for this sub before re-analysing — once the
    // VLM items change index the old keys can silently point at the wrong
    // problem, which is worse than asking the user to redo tweaks.
    _manualEdits.remove(_stateKeyFor(focus));
    setState(() {
      state.running = true;
      state.cancelled = false;
      state.pageResults.clear();
      state.progress = RangeProgress(
        cursor: rawStartPage,
        total: rawEndPage - rawStartPage + 1,
        done: 0,
        failed: 0,
        failedPages: <int>{},
      );
      state.phase = '페이지 렌더링/분석 중...';
      state.error = null;
      state.uploadResult = null;
      _selectedProblemKey = null;
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
        sectionHint: _sectionForSubKey(focus.subKey),
      );
    }

    try {
      await runRangeAnalysis(
        startPage: rawStartPage,
        endPage: rawEndPage,
        analysisLongEdgePx: _kAnalysisLongEdgePx,
        renderer: render,
        detector: detect,
        isCancelled: () => state.cancelled,
        onPageSuccess: (outcome) async {
          state.pageResults.add(_PageAnalysisRow.success(
            rawPage: outcome.rawPage,
            displayPage: outcome.result.displayPage,
            section: outcome.result.section,
            pageKind: outcome.result.pageKind,
            notes: outcome.result.notes,
            items: outcome.result.items,
          ));
          if (!mounted) return;
          setState(() {});
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
        sectionHint: _sectionForSubKey(focus.subKey),
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
          state.pageResults
              .removeWhere((r) => r.rawPage == outcome.rawPage && !r.ok);
          state.pageResults.add(_PageAnalysisRow.success(
            rawPage: outcome.rawPage,
            displayPage: outcome.result.displayPage,
            section: outcome.result.section,
            pageKind: outcome.result.pageKind,
            notes: outcome.result.notes,
            items: outcome.result.items,
          ));
          if (!mounted) return;
          setState(() {});
        },
        onPageFailure: (f) {
          state.pageResults.removeWhere((r) => r.rawPage == f.rawPage && !r.ok);
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

  int _totalRegionsFor(_SubRunState state, _SubFocus focus) {
    final edits = _manualEdits[_stateKeyFor(focus)];
    var total = 0;
    for (final row in state.pageResults.where((r) => r.ok)) {
      for (var i = 0; i < row.items.length; i += 1) {
        final item = row.items[i];
        final edited = edits?[_problemKey(row.rawPage, i)];
        final region = edited ?? item.itemRegion;
        if (region != null && region.length == 4) total += 1;
      }
    }
    return total;
  }

  Future<void> _uploadFocused(_SubFocus focus) async {
    final state = _ensureSubState(focus);
    if (state.running || state.uploading) return;
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final edits = _manualEdits[_stateKeyFor(focus)];
    final items = <TextbookCropUploadItem>[];
    _ResolvedContentGroup? lastBGroup;
    final pageRows = state.pageResults.where((r) => r.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    for (final row in pageRows) {
      for (var i = 0; i < row.items.length; i += 1) {
        final vlm = row.items[i];
        final edited = edits?[_problemKey(row.rawPage, i)];
        final region = edited ?? vlm.itemRegion;
        if (region == null || region.length != 4) continue;
        final rawGroup =
            _rawContentGroupForItem(vlm, focus.subKey, row.section);
        final group = focus.subKey == 'B' && rawGroup.kind == 'none'
            ? (lastBGroup ?? rawGroup)
            : rawGroup;
        if (focus.subKey == 'B' && rawGroup.kind == 'type') {
          lastBGroup = rawGroup;
        }
        items.add(TextbookCropUploadItem(
          rawPage: row.rawPage,
          displayPage: row.displayPage,
          section: row.section,
          problemNumber: vlm.number,
          label: vlm.label,
          isSetHeader: vlm.isSetHeader,
          setFrom: vlm.setFrom,
          setTo: vlm.setTo,
          contentGroupKind: group.kind,
          contentGroupLabel: group.label,
          contentGroupTitle: group.title,
          contentGroupOrder: group.order,
          columnIndex: vlm.column,
          bbox1k: vlm.bbox,
          itemRegion1k: region,
        ));
      }
    }
    if (items.isEmpty) {
      _toast('저장할 문항 영역이 없습니다', error: true);
      return;
    }

    setState(() {
      state.uploading = true;
      state.phase = '영역 저장 중... (${items.length}건)';
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
        regionsOnly: true,
        onProgress: (processed, total) {
          if (!mounted) return;
          setState(() {
            state.phase = '영역 저장 중... $processed / $total';
          });
        },
      );
      if (!mounted) return;
      setState(() {
        state.uploading = false;
        state.uploadResult = result;
        state.phase = '영역 저장 완료 · ${result.upserted}/${items.length}건';
      });
      _toast(
        '${focus.subKey} 영역 ${result.upserted}건을 서버에 저장했습니다',
      );
      unawaited(_loadStageStatuses());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        state.uploading = false;
        state.error = '$e';
        state.phase = '영역 저장 실패';
      });
    }
  }

  Future<void> _runSelectedBatch() async {
    if (_batchRunning) return;
    final selected = _selectedBatchFocuses();
    if (selected.isEmpty) {
      _toast('중단원 또는 소단원 체크박스를 먼저 선택하세요', error: true);
      return;
    }
    setState(() {
      _batchRunning = true;
      _batchDone = 0;
      _batchTotal = selected.length;
      _batchStatus = '일괄 실행 준비 중...';
    });
    final failed = <String>[];
    try {
      for (var i = 0; i < selected.length; i += 1) {
        final focus = selected[i];
        final label = _subFocusLabel(focus);
        if (!mounted) return;
        setState(() {
          _focus = focus;
          _selectedProblemKey = null;
          _batchStatus = '$label · Stage 1 분석 중...';
        });
        await _runFocusedAnalysis(focus);
        final state = _ensureSubState(focus);
        if (state.error != null || _totalRegionsFor(state, focus) == 0) {
          failed.add('$label(Stage 1)');
          if (mounted) setState(() => _batchDone = i + 1);
          continue;
        }

        if (!mounted) return;
        setState(() {
          _batchDone = i + 1;
          _batchStatus = '$label · Stage 1 분석 완료';
        });
      }
      if (!mounted) return;
      final failText = failed.isEmpty ? '' : ' · 실패 ${failed.length}개';
      _toast('선택 분석 완료$failText');
      setState(() {
        _batchRunning = false;
        _batchStatus = failed.isEmpty
            ? '크롭 확인 후 다음 버튼을 누르면 영역을 저장하고 정답 VLM 단계로 진행합니다'
            : failed.join('\n');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _batchRunning = false;
        _batchStatus = '일괄 실행 실패: $e';
      });
      _toast('일괄 실행 실패: $e', error: true);
    }
  }

  String _subFocusLabel(_SubFocus focus) {
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final sub = mid.subs.firstWhere(
      (s) => s.preset.key == focus.subKey,
      orElse: () => mid.subs.first,
    );
    final bigName = big.nameCtrl.text.trim().isEmpty
        ? '대${focus.bigIndex + 1}'
        : big.nameCtrl.text.trim();
    final midName = mid.nameCtrl.text.trim().isEmpty
        ? '중${focus.midIndex + 1}'
        : mid.nameCtrl.text.trim();
    return '$bigName/$midName/${sub.preset.displayName}';
  }

  Future<void> _startPdfOnlyExtractForFocus(_SubFocus focus) async {
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final sub = mid.subs.firstWhere(
      (s) => s.preset.key == focus.subKey,
      orElse: () => mid.subs.first,
    );
    final displayStart = _positiveInt(sub.startCtrl.text);
    final displayEnd = _positiveInt(sub.endCtrl.text);
    final rawStart =
        displayStart == null ? null : _rawPageForDisplayPage(displayStart);
    final rawEnd =
        displayEnd == null ? null : _rawPageForDisplayPage(displayEnd);
    await _pbService.createTextbookPdfOnlyExtractRun(
      academyId: widget.academyId,
      bookId: widget.bookId,
      bookName: widget.bookName,
      gradeLabel: widget.gradeLabel,
      bigOrder: focus.bigIndex,
      midOrder: focus.midIndex,
      subKey: focus.subKey,
      bigName: big.nameCtrl.text.trim(),
      midName: mid.nameCtrl.text.trim(),
      subName: sub.preset.displayName,
      rawPageFrom: rawStart,
      rawPageTo: rawEnd,
      displayPageFrom: displayStart,
      displayPageTo: displayEnd,
      bodyLinkId: widget.linkId,
    );
    if (!mounted) return;
    setState(() {
      _pbExtractStatusBySub[_stateKeyFor(focus)] = 'queued';
    });
  }

  // ------------------------------------------------------------ next stage

  Future<void> _saveTargetsAndOpenStage(List<_SubFocus> targets) async {
    if (targets.isEmpty) return;
    for (final focus in targets) {
      final state = _ensureSubState(focus);
      final hasRows = (state.uploadResult?.rows ?? const []).isNotEmpty;
      if (hasRows) continue;
      if (_totalRegionsFor(state, focus) == 0) {
        _toast('${_subFocusLabel(focus)} 분석된 문항 영역이 없습니다', error: true);
        return;
      }
      if (!mounted) return;
      setState(() {
        _focus = focus;
        _selectedProblemKey = null;
        _batchStatus = '${_subFocusLabel(focus)} · 다음 단계 진입 전 영역 저장 중...';
      });
      await _uploadFocused(focus);
      if ((state.uploadResult?.rows ?? const []).isEmpty) {
        _toast('${_subFocusLabel(focus)} 영역 저장 실패', error: true);
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _batchStatus = '영역 저장 완료 · 정답 VLM 단계로 이동합니다';
    });
    _openStageDialogForTargets(targets);
  }

  void _openStageDialogForTargets(List<_SubFocus> targets) {
    if (targets.isEmpty) return;
    final allSeeds = <TextbookAuthoringStageCropSeed>[];
    final scopes = <TextbookAuthoringStageScope>[];
    for (final focus in targets) {
      final state = _ensureSubState(focus);
      final seeds = _buildStageCropSeeds(focus, state);
      if (seeds.isEmpty) {
        _toast('${_subFocusLabel(focus)} 저장 문항이 없습니다', error: true);
        return;
      }
      allSeeds.addAll(seeds);
      scopes.add(_stageScopeFor(focus));
      unawaited(_startPdfOnlyExtractForFocus(focus).catchError((Object e) {
        debugPrint('[textbook-pb-extract] start failed: $e');
      }));
    }
    final first = targets.first;
    final big = _bigUnits[first.bigIndex];
    final mid = big.middles[first.midIndex];
    setState(() {
      _embeddedStage = _EmbeddedStageArgs(
        bigOrder: first.bigIndex,
        midOrder: first.midIndex,
        subKey: first.subKey,
        bigName: big.nameCtrl.text.trim(),
        midName: mid.nameCtrl.text.trim(),
        initialCrops: allSeeds,
        batchScopes:
            scopes.length > 1 ? scopes : const <TextbookAuthoringStageScope>[],
      );
    });
  }

  TextbookAuthoringStageScope _stageScopeFor(_SubFocus focus) {
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final sub = mid.subs.firstWhere(
      (s) => s.preset.key == focus.subKey,
      orElse: () => mid.subs.first,
    );
    return TextbookAuthoringStageScope(
      bigOrder: focus.bigIndex,
      midOrder: focus.midIndex,
      subKey: focus.subKey,
      bigName: big.nameCtrl.text.trim(),
      midName: mid.nameCtrl.text.trim(),
      subName: sub.preset.displayName,
    );
  }

  List<TextbookAuthoringStageCropSeed> _buildStageCropSeeds(
    _SubFocus focus,
    _SubRunState state,
  ) {
    final uploadRows =
        state.uploadResult?.rows ?? const <Map<String, dynamic>>[];
    if (uploadRows.isEmpty) return const <TextbookAuthoringStageCropSeed>[];
    final scope = _stageScopeFor(focus);
    final seedScopeLabel =
        '${scope.midName.trim().isEmpty ? '중${scope.midOrder + 1}' : scope.midName}/${scope.subName.trim().isEmpty ? scope.subKey : scope.subName}';
    final idByNumber = <String, String>{};
    for (final row in uploadRows) {
      final id = '${row['id'] ?? ''}'.trim();
      final number = '${row['problem_number'] ?? ''}'.trim();
      if (id.isNotEmpty && number.isNotEmpty) {
        idByNumber[number] = id;
      }
    }
    if (idByNumber.isEmpty) return const <TextbookAuthoringStageCropSeed>[];

    final seeds = <TextbookAuthoringStageCropSeed>[];
    _ResolvedContentGroup? lastBGroup;
    final pageRows = state.pageResults.where((r) => r.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    for (final row in pageRows) {
      for (final item in row.items) {
        final id = idByNumber[item.number];
        if (id == null) continue;
        final rawGroup =
            _rawContentGroupForItem(item, focus.subKey, row.section);
        final group = focus.subKey == 'B' && rawGroup.kind == 'none'
            ? (lastBGroup ?? rawGroup)
            : rawGroup;
        if (focus.subKey == 'B' && rawGroup.kind == 'type') {
          lastBGroup = rawGroup;
        }
        seeds.add(TextbookAuthoringStageCropSeed(
          id: id,
          problemNumber: item.number,
          rawPage: row.rawPage,
          displayPage: row.displayPage,
          section: row.section,
          isSetHeader: item.isSetHeader,
          contentGroupKind: group.kind,
          contentGroupLabel: group.label,
          contentGroupTitle: group.title,
          contentGroupOrder: group.order,
          scopeLabel: seedScopeLabel,
        ));
      }
    }
    return seeds;
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
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            final offset = Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(animation);
            return SlideTransition(position: offset, child: child);
          },
          child: _embeddedStage == null
              ? _buildStage1Shell()
              : TextbookAuthoringStageDialog(
                  key: ValueKey('stage:${_embeddedStage!.subKey}'),
                  academyId: widget.academyId,
                  bookId: widget.bookId,
                  bookName: widget.bookName,
                  gradeLabel: widget.gradeLabel,
                  linkId: widget.linkId,
                  bigOrder: _embeddedStage!.bigOrder,
                  midOrder: _embeddedStage!.midOrder,
                  subKey: _embeddedStage!.subKey,
                  bigName: _embeddedStage!.bigName,
                  midName: _embeddedStage!.midName,
                  initialCrops: _embeddedStage!.initialCrops,
                  batchScopes: _embeddedStage!.batchScopes,
                  embedded: true,
                  onBack: () {
                    setState(() => _embeddedStage = null);
                    unawaited(_loadStageStatuses());
                  },
                  onStageChanged: () => unawaited(_loadStageStatuses()),
                ),
        ),
      ),
    );
  }

  Widget _buildStage1Shell() {
    return Column(
      key: const ValueKey('stage1'),
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
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.account_tree_outlined, color: _kAccent, size: 20),
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
              child: const Icon(Icons.warning_amber, size: 14, color: _kDanger),
            ),
            const SizedBox(width: 10),
          ],
          Tooltip(
            message:
                '대·중·소단원 이름과 페이지 범위를 Supabase textbook_metadata.payload에 저장합니다.\n'
                '영역 저장은 각 A/B/C 탭의 "영역 저장" 버튼을 눌러야 진행됩니다.',
            child: OutlinedButton.icon(
              onPressed: _saveTree,
              icon: const Icon(Icons.save_outlined, size: 14, color: _kTextSub),
              label: const Text(
                '단원 구조 저장',
                style: TextStyle(color: _kTextSub, fontSize: 12),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: _kBorder),
              ),
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
          if (_batchRunning || _batchStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 12, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_batchTotal > 0)
                    LinearProgressIndicator(
                      value: _batchRunning ? _batchDone / _batchTotal : 1,
                      minHeight: 3,
                      backgroundColor: const Color(0xFF24272D),
                      color: _kAccent,
                    ),
                  const SizedBox(height: 6),
                  Text(
                    _batchStatus,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _kTextSub, fontSize: 11),
                  ),
                ],
              ),
            ),
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
              _pill(
                  text: '대 ${i + 1}',
                  color: const Color(0xFF1B2B1B),
                  fg: _kAccent),
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
              Checkbox(
                value: _midBatchValue(bigIndex, midIndex),
                tristate: true,
                onChanged: _batchRunning
                    ? null
                    : (value) => _toggleBatchMid(
                          bigIndex,
                          midIndex,
                          value != false,
                        ),
                visualDensity: VisualDensity.compact,
                side: const BorderSide(color: _kTextSub),
              ),
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
                          _bigUnits[bigIndex].middles[midIndex].dispose();
                          _bigUnits[bigIndex].middles.removeAt(midIndex);
                          if (_focus != null &&
                              _focus!.bigIndex == bigIndex &&
                              _focus!.midIndex >=
                                  _bigUnits[bigIndex].middles.length) {
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
    final batchSelected = _batchSelection.contains(_stateKeyFor(focus));
    final state = _subStates[_stateKeyFor(focus)];
    final analyzed = state == null
        ? 0
        : state.pageResults.where((r) => r.ok).fold<int>(
              0,
              (sum, row) =>
                  sum +
                  row.items
                      .where((it) => (it.itemRegion?.length ?? 0) == 4)
                      .length,
            );
    final uploaded = state?.uploadResult?.upserted ?? 0;
    final isRunning = state?.running == true || state?.uploading == true;
    final key = _stateKeyFor(focus);
    final pbStatus = _pbExtractStatusBySub[key] ?? '';
    final stageStatus = _stageStatusBySub[key];
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF1B2B1B) : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
      ),
      child: InkWell(
        onTap: () {
          setState(() {
            _focus = focus;
            _selectedProblemKey = null;
          });
          _jumpViewerToFocusStart(focus);
        },
        child: Column(
          children: [
            Row(
              children: [
                Checkbox(
                  value: batchSelected,
                  onChanged: _batchRunning
                      ? null
                      : (value) => _toggleBatchSub(focus, value == true),
                  visualDensity: VisualDensity.compact,
                  side: const BorderSide(color: _kTextSub),
                ),
                Container(
                  constraints: const BoxConstraints(minWidth: 72),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
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
                  child: _StageProgressChip(
                    status: stageStatus,
                    loading: _loadingStageStatuses,
                    onTap: () => _showStageStatusDialog(focus),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const SizedBox(width: 38),
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
                const SizedBox(width: 6),
                _SubRowStats(
                  analyzed: analyzed,
                  uploaded: uploaded,
                  running: isRunning,
                ),
                if (pbStatus.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  _PbExtractStatusChip(status: pbStatus),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showStageStatusDialog(_SubFocus focus) async {
    await _loadStageStatuses();
    if (!mounted) return;
    final status = _stageStatusBySub[_stateKeyFor(focus)];
    final title = _subFocusLabel(focus);
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: _kPanel,
          title: Text(
            '$title 추출 상태',
            style: const TextStyle(color: _kText, fontWeight: FontWeight.w800),
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StageStatusDialogRow(
                  label: '본문',
                  description: '문항 영역 좌표',
                  done: status?.bodyDone ?? 0,
                  total: status?.bodyTotal ?? 0,
                  dangerHint: '본문 삭제 시 정답·해설·문제은행 문서도 함께 삭제',
                  onDelete: () {
                    Navigator.of(ctx).pop();
                    _confirmDeleteStage(focus, 'body');
                  },
                ),
                const SizedBox(height: 8),
                _StageStatusDialogRow(
                  label: '정답',
                  description: '정답 VLM 및 이미지 크롭',
                  done: status?.answerDone ?? 0,
                  total: status?.answerTotal ?? 0,
                  dangerHint: '정답 삭제 시 해설도 함께 삭제',
                  onDelete: (status?.bodyDone ?? 0) == 0
                      ? null
                      : () {
                          Navigator.of(ctx).pop();
                          _confirmDeleteStage(focus, 'answer');
                        },
                ),
                const SizedBox(height: 8),
                _StageStatusDialogRow(
                  label: '해설',
                  description: '해설 번호/본문 좌표',
                  done: status?.solutionDone ?? 0,
                  total: status?.solutionTotal ?? 0,
                  dangerHint: '해설 좌표만 삭제',
                  onDelete: (status?.bodyDone ?? 0) == 0
                      ? null
                      : () {
                          Navigator.of(ctx).pop();
                          _confirmDeleteStage(focus, 'solution');
                        },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('닫기'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmDeleteStage(_SubFocus focus, String stage) async {
    final label = switch (stage) {
      'body' => '본문',
      'answer' => '정답',
      'solution' => '해설',
      _ => stage,
    };
    final detail = switch (stage) {
      'body' => '본문 영역, 정답, 해설, 연결된 문제은행 문서를 모두 서버에서 영구 삭제합니다.',
      'answer' => '정답과 해설 좌표를 서버에서 영구 삭제합니다.',
      'solution' => '해설 좌표만 서버에서 영구 삭제합니다.',
      _ => '선택한 데이터를 서버에서 영구 삭제합니다.',
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kPanel,
        title: Text(
          '$label 삭제',
          style: const TextStyle(color: _kText, fontWeight: FontWeight.w800),
        ),
        content: Text(
          '$detail\n대상 소단원: ${focus.subKey}\n되돌릴 수 없습니다.',
          style: const TextStyle(color: _kTextSub, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: _kDanger),
            child: const Text('영구 삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final result = await _pdfService.deleteStageData(
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        bigOrder: focus.bigIndex,
        midOrder: focus.midIndex,
        subKey: focus.subKey,
        stage: stage,
      );
      if (!mounted) return;
      if (stage == 'body') {
        _subStates.remove(_stateKeyFor(focus));
        _manualEdits.remove(_stateKeyFor(focus));
      }
      final affected = result.affectedSubKeys.isEmpty
          ? focus.subKey
          : result.affectedSubKeys.join(', ');
      _toast('$label 삭제 완료 · 대상 $affected');
      if (result.warnings.isNotEmpty) {
        debugPrint('[textbook-stage-delete] warnings: ${result.warnings}');
      }
      await _loadExistingCrops();
      await _loadStageStatuses();
    } catch (e) {
      if (!mounted) return;
      _toast('$label 삭제 실패: $e', error: true);
    }
  }

  void _jumpViewerToFocusStart(_SubFocus focus) {
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final sub = mid.subs.firstWhere(
      (s) => s.preset.key == focus.subKey,
      orElse: () => mid.subs.first,
    );
    final start = _positiveInt(sub.startCtrl.text);
    if (start == null) return;
    if (!_viewerController.isReady) return;
    try {
      _viewerController.goToPage(pageNumber: _rawPageForDisplayPage(start));
    } catch (_) {
      // Best-effort; pdfrx throws if the page number is out of range.
    }
  }

  Widget _buildRightPane() {
    final focus = _focus;
    if (focus == null) {
      final selected = _selectedBatchFocuses();
      if (selected.isNotEmpty) {
        return _buildBatchSelectionPane(selected);
      }
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
            ],
          ),
        ),
        const Divider(height: 1, color: _kBorder),
        Padding(
          padding: const EdgeInsets.all(12),
          child: _buildSubControls(focus, state, sub),
        ),
        if (state.progress != null) _buildProgressRow(state),
        Expanded(child: _buildViewerArea(focus, state)),
      ],
    );
  }

  Widget _buildBatchSelectionPane(List<_SubFocus> selected) {
    final totalReady = selected.fold<int>(
      0,
      (sum, focus) => sum + _totalRegionsFor(_ensureSubState(focus), focus),
    );
    return Center(
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: _kCard,
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '선택된 소단원 ${selected.length}개',
              style: const TextStyle(
                color: _kText,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _batchStatus.isNotEmpty
                  ? _batchStatus
                  : '체크한 소단원을 한 번에 Stage 1 분석/저장합니다.',
              style: const TextStyle(color: _kTextSub, fontSize: 12),
            ),
            if (_batchTotal > 0) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: _batchRunning
                    ? (_batchDone / _batchTotal).clamp(0.0, 1.0)
                    : 1,
                backgroundColor: const Color(0xFF2A2A2A),
                color: _kAccent,
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                if (totalReady > 0 && !_batchRunning)
                  FilledButton.icon(
                    onPressed: () => _saveTargetsAndOpenStage(selected),
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    label: Text(
                      selected.length > 1 ? '다음 (${selected.length}개)' : '다음',
                    ),
                    style: FilledButton.styleFrom(backgroundColor: _kInfo),
                  )
                else
                  FilledButton.icon(
                    onPressed: _batchRunning ? null : _runSelectedBatch,
                    icon: _batchRunning
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.play_arrow, size: 16),
                    label: Text(_batchRunning ? '선택 분석 중' : '선택 분석'),
                    style: FilledButton.styleFrom(backgroundColor: _kAccent),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNextButton(_SubFocus focus, _SubRunState state) {
    final selected = _selectedBatchFocuses();
    final targets = selected.isEmpty ? <_SubFocus>[focus] : selected;
    final total = targets.fold<int>(
      0,
      (sum, f) => sum + _totalRegionsFor(_ensureSubState(f), f),
    );
    final busy = targets.any((f) {
      final s = _ensureSubState(f);
      return s.running || s.uploading;
    });
    final enabled = total > 0 && !busy;
    return Tooltip(
      message: total == 0
          ? '먼저 이 소단원에서 문항 영역을 분석하세요.'
          : '$total개 문항을 저장한 뒤 정답·해설 좌표 단계로 이동합니다.',
      child: FilledButton.icon(
        onPressed: enabled ? () => _saveTargetsAndOpenStage(targets) : null,
        icon: const Icon(Icons.arrow_forward, size: 14),
        label: Text(targets.length > 1 ? '다음 (${targets.length}개)' : '다음'),
        style: FilledButton.styleFrom(
          backgroundColor: _kAccent,
          disabledBackgroundColor: const Color(0xFF2A2A2A),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        ),
      ),
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
    final hasFailures =
        (state.progress?.failedPages ?? const <int>{}).isNotEmpty;
    final totalRegions = _totalRegionsFor(state, focus);
    final edits = _manualEdits[_stateKeyFor(focus)];
    final manualCount = edits?.length ?? 0;
    final selectedCount = _selectedBatchFocuses().length;
    final runSelection = selectedCount > 0;
    final canRunAnalysis = runSelection ? !_batchRunning : readyRange;

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
          if (manualCount > 0) ...[
            const SizedBox(width: 6),
            _tag('수동 편집 $manualCount건', const Color(0xFF3A2F18)),
          ],
          const Spacer(),
          if (totalRegions > 0)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                '$totalRegions개 준비',
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
              onPressed: !canRunAnalysis || state.uploading
                  ? null
                  : () => runSelection
                      ? _runSelectedBatch()
                      : _runFocusedAnalysis(focus),
              icon: const Icon(Icons.play_arrow, size: 16),
              label: Text(runSelection ? '선택 분석 ($selectedCount)' : '분석 시작'),
              style: FilledButton.styleFrom(backgroundColor: _kAccent),
            ),
          ],
          const SizedBox(width: 6),
          Tooltip(
            message: totalRegions == 0
                ? '분석된 문항 영역이 없어요. 먼저 "분석 시작" 을 눌러 VLM으로 감지하세요.'
                : '이 소단원에서 감지된 $totalRegions건의 문항 영역(좌표)을 '
                    'textbook_problem_crops 테이블에 저장합니다.',
            child: FilledButton.icon(
              onPressed: state.running || state.uploading || totalRegions == 0
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
                  : const Icon(Icons.save_outlined, size: 16),
              label: Text(
                state.uploading
                    ? '영역 저장 중'
                    : totalRegions == 0
                        ? '영역 저장'
                        : '영역 저장 ($totalRegions건)',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _kInfo,
                disabledBackgroundColor: const Color(0xFF2A2A2A),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _buildNextButton(focus, state),
        ],
      ),
    );
  }

  Widget _buildProgressRow(_SubRunState state) {
    final progress = state.progress;
    if (progress == null) return const SizedBox.shrink();
    final total = progress.total == 0 ? 1 : progress.total;
    final ratio = ((progress.done + progress.failed) / total).clamp(0.0, 1.0);
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
                ' · 현재 책면 ${_displayPageForRawPage(progress.cursor)}p'
                ' (PDF ${progress.cursor}p)',
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

  // ─── PDF viewer + overlays ──────────────────────────────────────────

  Widget _buildViewerArea(_SubFocus focus, _SubRunState state) {
    if (_bodyLocalPath == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.picture_as_pdf_outlined,
                  size: 32, color: _kTextSub),
              const SizedBox(height: 8),
              Text(
                _pdfLoadError != null
                    ? 'PDF 로드 실패\n$_pdfLoadError'
                    : 'PDF가 아직 로드되지 않았어요.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: _kTextSub, fontSize: 12),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _loadingPdf ? null : _ensurePdf,
                icon: const Icon(Icons.file_download_outlined, size: 14),
                label: const Text('PDF 로드'),
                style: FilledButton.styleFrom(backgroundColor: _kInfo),
              ),
              if (state.pageResults.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    '"분석 시작" 을 누르면 PDF를 로드하고 문항 영역을 감지합니다.',
                    style: TextStyle(color: _kTextSub, fontSize: 11),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return Container(
      color: _kBg,
      child: Stack(
        children: [
          Positioned.fill(
            child: PdfViewer.file(
              _bodyLocalPath!,
              controller: _viewerController,
              params: PdfViewerParams(
                backgroundColor: _kBg,
                margin: 8,
                layoutPages: _layoutTwoPageSpread,
                pageAnchor: PdfPageAnchor.center,
                viewerOverlayBuilder: (context, size, handleLinkTap) => [
                  PdfViewerScrollThumb(
                    controller: _viewerController,
                    orientation: ScrollbarOrientation.right,
                  ),
                  PdfViewerScrollThumb(
                    controller: _viewerController,
                    orientation: ScrollbarOrientation.bottom,
                  ),
                ],
                onViewerReady: (document, controller) {
                  if (!mounted) return;
                  _jumpViewerToFocusStart(focus);
                },
                pageOverlaysBuilder: (context, pageRect, page) {
                  return _buildPageOverlays(
                    focus: focus,
                    state: state,
                    pageNumber: page.pageNumber,
                    pageRect: pageRect,
                  );
                },
              ),
            ),
          ),
          if (state.pageResults.any((r) => !r.ok))
            Positioned(
              left: 10,
              top: 10,
              child: _FailureChip(
                count: state.pageResults.where((r) => !r.ok).length,
              ),
            ),
          if (_selectedProblemKey != null)
            Positioned(
              right: 10,
              bottom: 10,
              child: _SelectedHintChip(
                onDismiss: () => setState(() => _selectedProblemKey = null),
              ),
            ),
        ],
      ),
    );
  }

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

  List<Widget> _buildPageOverlays({
    required _SubFocus focus,
    required _SubRunState state,
    required int pageNumber,
    required Rect pageRect,
  }) {
    final row = state.pageResults.firstWhere(
      (r) => r.rawPage == pageNumber && r.ok,
      orElse: () => _PageAnalysisRow.placeholder(),
    );
    if (row.items.isEmpty) {
      if (row.isConceptPage) {
        return const <Widget>[
          Positioned(
            left: 12,
            top: 12,
            child: _ConceptPageMarker(),
          ),
        ];
      }
      return const <Widget>[];
    }
    final pageSize = pageRect.size;
    final widgets = <Widget>[];
    for (var i = 0; i < row.items.length; i += 1) {
      final item = row.items[i];
      final region = _effectiveItemRegion(
        focus: focus,
        rawPage: pageNumber,
        orderIndex: i,
        item: item,
      );
      if (region == null || region.length != 4) continue;
      final rect = _bboxToRect(region, pageSize);
      if (rect == null) continue;
      final key = _problemKey(pageNumber, i);
      final isSelected = _selectedProblemKey == key;
      final isEdited =
          _manualEdits[_stateKeyFor(focus)]?.containsKey(key) == true;
      widgets.add(_RegionBox(
        rect: rect,
        item: item,
        selected: isSelected,
        edited: isEdited,
        onTap: () {
          setState(() {
            _selectedProblemKey = isSelected ? null : key;
          });
        },
      ));
    }
    // Bottom pass: number bboxes (for context)
    for (var i = 0; i < row.items.length; i += 1) {
      final item = row.items[i];
      final bbox = item.bbox;
      if (bbox == null || bbox.length != 4) continue;
      final rect = _bboxToRect(bbox, pageSize);
      if (rect == null) continue;
      widgets.add(_NumberBadge(rect: rect, item: item));
    }
    // Top pass: drag handles for the selected region. Drawn last so they
    // stay clickable.
    if (_selectedProblemKey != null) {
      final parts = _selectedProblemKey!.split(':');
      if (parts.length == 2) {
        final selRawPage = int.tryParse(parts[0]);
        final selIndex = int.tryParse(parts[1]);
        if (selRawPage == pageNumber && selIndex != null) {
          if (selIndex >= 0 && selIndex < row.items.length) {
            final item = row.items[selIndex];
            final region = _effectiveItemRegion(
              focus: focus,
              rawPage: pageNumber,
              orderIndex: selIndex,
              item: item,
            );
            if (region != null && region.length == 4) {
              final rect = _bboxToRect(region, pageSize);
              if (rect != null) {
                widgets.addAll(_buildDragHandles(
                  rect: rect,
                  pageSize: pageSize,
                  focus: focus,
                  rawPage: pageNumber,
                  orderIndex: selIndex,
                  currentRegion: region,
                ));
              }
            }
          }
        }
      }
    }
    return widgets;
  }

  List<Widget> _buildDragHandles({
    required Rect rect,
    required Size pageSize,
    required _SubFocus focus,
    required int rawPage,
    required int orderIndex,
    required List<int> currentRegion,
  }) {
    const handleSize = 14.0;
    Widget makeHandle(Offset center, _HandleKind kind) {
      return Positioned(
        left: center.dx - handleSize / 2,
        top: center.dy - handleSize / 2,
        width: handleSize,
        height: handleSize,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (details) {
            _onHandleDrag(
              kind: kind,
              delta: details.delta,
              pageSize: pageSize,
              focus: focus,
              rawPage: rawPage,
              orderIndex: orderIndex,
            );
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeUpLeftDownRight,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: _kAccent, width: 2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      );
    }

    return [
      makeHandle(Offset(rect.left, rect.top), _HandleKind.topLeft),
      makeHandle(Offset(rect.right, rect.top), _HandleKind.topRight),
      makeHandle(Offset(rect.left, rect.bottom), _HandleKind.bottomLeft),
      makeHandle(Offset(rect.right, rect.bottom), _HandleKind.bottomRight),
    ];
  }

  void _onHandleDrag({
    required _HandleKind kind,
    required Offset delta,
    required Size pageSize,
    required _SubFocus focus,
    required int rawPage,
    required int orderIndex,
  }) {
    if (pageSize.width <= 0 || pageSize.height <= 0) return;
    // The overlay is drawn on top of the already-zoomed page rect, so the
    // delta is already in viewer-space pixels relative to the current
    // zoom. Converting to normalised 0..1000 by the current pageSize gives
    // the same effective step regardless of zoom.
    final dxNorm = (delta.dx / pageSize.width * 1000).round();
    final dyNorm = (delta.dy / pageSize.height * 1000).round();

    final edits = _ensureManualEdits(focus);
    final key = _problemKey(rawPage, orderIndex);
    final state = _ensureSubState(focus);
    final row = state.pageResults.firstWhere(
      (r) => r.rawPage == rawPage && r.ok,
      orElse: () => _PageAnalysisRow.placeholder(),
    );
    if (orderIndex < 0 || orderIndex >= row.items.length) return;
    final item = row.items[orderIndex];
    final current = edits[key] ?? List<int>.from(item.itemRegion ?? const []);
    if (current.length != 4) return;
    // item_region format = [ymin, xmin, ymax, xmax] in 0..1000.
    var ymin = current[0];
    var xmin = current[1];
    var ymax = current[2];
    var xmax = current[3];
    switch (kind) {
      case _HandleKind.topLeft:
        ymin = (ymin + dyNorm).clamp(0, ymax - 10);
        xmin = (xmin + dxNorm).clamp(0, xmax - 10);
        break;
      case _HandleKind.topRight:
        ymin = (ymin + dyNorm).clamp(0, ymax - 10);
        xmax = (xmax + dxNorm).clamp(xmin + 10, 1000);
        break;
      case _HandleKind.bottomLeft:
        ymax = (ymax + dyNorm).clamp(ymin + 10, 1000);
        xmin = (xmin + dxNorm).clamp(0, xmax - 10);
        break;
      case _HandleKind.bottomRight:
        ymax = (ymax + dyNorm).clamp(ymin + 10, 1000);
        xmax = (xmax + dxNorm).clamp(xmin + 10, 1000);
        break;
    }
    edits[key] = <int>[ymin, xmin, ymax, xmax];
    if (mounted) setState(() {});
  }

  Rect? _bboxToRect(List<int> bbox, Size pageSize) {
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

  // ─── widgets ────────────────────────────────────────────────────────

  Widget _pill(
      {required String text, required Color color, required Color fg}) {
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

// ────────────────────────────── overlays ──────────────────────────────

class _ConceptPageMarker extends StatelessWidget {
  const _ConceptPageMarker();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A1E).withValues(alpha: 0.92),
          border: Border.all(color: Color(0xFFE6C07A)),
          borderRadius: BorderRadius.circular(999),
          boxShadow: const [
            BoxShadow(
              color: Colors.black38,
              blurRadius: 6,
              offset: Offset(1, 2),
            ),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lightbulb_outline, size: 13, color: Color(0xFFE6C07A)),
            SizedBox(width: 5),
            Text(
              '개념 페이지',
              style: TextStyle(
                color: Color(0xFFE6C07A),
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RegionBox extends StatelessWidget {
  const _RegionBox({
    required this.rect,
    required this.item,
    required this.selected,
    required this.edited,
    required this.onTap,
  });

  final Rect rect;
  final TextbookVlmItem item;
  final bool selected;
  final bool edited;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final baseColor =
        item.isSetHeader ? const Color(0xFFFFB44A) : const Color(0xFF5AA6FF);
    final borderColor = selected
        ? const Color(0xFF33A373)
        : edited
            ? const Color(0xFFEAB968)
            : baseColor;
    final fillColor = selected
        ? const Color(0xFF33A373).withValues(alpha: 0.12)
        : edited
            ? const Color(0xFFEAB968).withValues(alpha: 0.08)
            : baseColor.withValues(alpha: 0.05);
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: fillColor,
            border: Border.all(
              color: borderColor,
              width: selected ? 2.5 : 1.5,
            ),
          ),
        ),
      ),
    );
  }
}

class _NumberBadge extends StatelessWidget {
  const _NumberBadge({required this.rect, required this.item});
  final Rect rect;
  final TextbookVlmItem item;

  @override
  Widget build(BuildContext context) {
    final color =
        item.isSetHeader ? const Color(0xFFFFB44A) : const Color(0xFFFF4D4F);
    final groupLabel = item.contentGroupLabel.trim();
    final numberLabel =
        item.label.isEmpty ? item.number : '${item.number} · ${item.label}';
    final text =
        groupLabel.isEmpty ? numberLabel : '$groupLabel · $numberLabel';
    return Positioned(
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
                border: Border.all(color: color, width: 2),
                color: color.withValues(alpha: 0.08),
              ),
            ),
            Positioned(
              left: -2,
              top: -18,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                color: color,
                child: Text(
                  text,
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
    );
  }
}

class _FailureChip extends StatelessWidget {
  const _FailureChip({required this.count});
  final int count;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF5A2A2A),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFF8A4A4A)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.warning_amber, size: 12, color: Color(0xFFE0B5B5)),
          const SizedBox(width: 4),
          Text(
            '$count 페이지 분석 실패',
            style: const TextStyle(
              color: Color(0xFFE0B5B5),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectedHintChip extends StatelessWidget {
  const _SelectedHintChip({required this.onDismiss});
  final VoidCallback onDismiss;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onDismiss,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF1B3A2A),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: const Color(0xFF33A373)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.pan_tool_alt, size: 12, color: Color(0xFF9FD49F)),
              SizedBox(width: 4),
              Text(
                '모서리 핸들을 드래그해서 영역 조정 · 클릭하여 해제',
                style: TextStyle(
                  color: Color(0xFF9FD49F),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
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

class _SubRowStats extends StatelessWidget {
  const _SubRowStats({
    required this.analyzed,
    required this.uploaded,
    required this.running,
  });

  final int analyzed;
  final int uploaded;
  final bool running;

  @override
  Widget build(BuildContext context) {
    if (!running && analyzed == 0 && uploaded == 0) {
      return const SizedBox(width: 72);
    }

    final fullyUploaded = uploaded > 0 && uploaded >= analyzed;
    final partiallyUploaded = uploaded > 0 && uploaded < analyzed;
    final label = '$uploaded/$analyzed';
    final Color bg;
    final Color fg;
    if (fullyUploaded) {
      bg = const Color(0xFF1B3A2A);
      fg = const Color(0xFF9FD49F);
    } else if (partiallyUploaded) {
      bg = const Color(0xFF3A2F18);
      fg = const Color(0xFFEAB968);
    } else if (analyzed > 0) {
      bg = const Color(0xFF1B2A3A);
      fg = const Color(0xFF7AA9E6);
    } else {
      bg = const Color(0xFF242424);
      fg = const Color(0xFFB3B3B3);
    }
    return Tooltip(
      message: fullyUploaded
          ? '분석 $analyzed건 · 전부 서버 저장 완료 ($uploaded건)'
          : partiallyUploaded
              ? '분석 $analyzed건 · 서버 저장 $uploaded건 (일부)'
              : analyzed > 0
                  ? '분석 $analyzed건 · 서버 저장 아직 안 됨 — "영역 저장" 을 눌러주세요'
                  : '분석 진행 중',
      child: SizedBox(
        width: 72,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    fullyUploaded
                        ? Icons.cloud_done_outlined
                        : analyzed > 0 && uploaded == 0
                            ? Icons.cloud_upload_outlined
                            : Icons.inventory_2_outlined,
                    size: 11,
                    color: fg,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            if (running)
              const Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: SizedBox(
                  width: 10,
                  height: 10,
                  child: Center(
                    child: SizedBox(
                      width: 8,
                      height: 8,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.2,
                        color: Color(0xFFEAB968),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StageProgressChip extends StatelessWidget {
  const _StageProgressChip({
    required this.status,
    required this.loading,
    required this.onTap,
  });

  final TextbookStageScopeStatus? status;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final completed = status?.completedStages ?? 0;
    final ready = completed == 3;
    final label = loading ? '확인 중...' : '$completed/3 완료';
    final color = ready
        ? const Color(0xFF9FD49F)
        : completed > 0
            ? const Color(0xFFEAB968)
            : const Color(0xFF9FB3B3);
    return Tooltip(
      message: '본문 → 정답 → 해설 추출 상태를 확인합니다',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.45)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (loading)
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.3,
                    color: Color(0xFF9FB3B3),
                  ),
                )
              else
                Icon(
                  ready ? Icons.task_alt : Icons.fact_check_outlined,
                  size: 11,
                  color: color,
                ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StageStatusDialogRow extends StatelessWidget {
  const _StageStatusDialogRow({
    required this.label,
    required this.description,
    required this.done,
    required this.total,
    required this.dangerHint,
    required this.onDelete,
  });

  final String label;
  final String description;
  final int done;
  final int total;
  final String dangerHint;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final exists = total > 0 || done > 0;
    final complete = total > 0 && done >= total;
    final color = complete
        ? const Color(0xFF9FD49F)
        : exists
            ? const Color(0xFFEAB968)
            : const Color(0xFF8A8A8A);
    final countText = total > 0 ? '$done/$total' : '$done';
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF15171C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Row(
        children: [
          Icon(
            complete
                ? Icons.check_circle_outline
                : Icons.radio_button_unchecked,
            color: color,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$label · $countText',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$description · $dangerHint',
                  style: const TextStyle(
                    color: Color(0xFF9FB3B3),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: exists ? onDelete : null,
            icon: const Icon(Icons.delete_outline, size: 14),
            label: const Text('삭제'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFE68A8A),
              disabledForegroundColor: const Color(0xFF4A4A4A),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }
}

class _PbExtractStatusChip extends StatelessWidget {
  const _PbExtractStatusChip({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final normalized = status.trim().toLowerCase();
    final success = normalized == 'completed';
    final failed = normalized == 'failed' || normalized == 'cancelled';
    final running = normalized == 'queued' || normalized == 'extracting';
    final Color color = success
        ? const Color(0xFF9FD49F)
        : failed
            ? const Color(0xFFE68A8A)
            : running
                ? const Color(0xFF7AA9E6)
                : const Color(0xFFB3B3B3);
    final text = success
        ? '본문 성공'
        : failed
            ? '본문 실패'
            : running
                ? '본문 진행'
                : '본문 대기';
    return Tooltip(
      message: '문제은행 PDF-only 본문 추출: $status',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

// ─────────── data classes ───────────

enum _HandleKind { topLeft, topRight, bottomLeft, bottomRight }

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

class _EmbeddedStageArgs {
  const _EmbeddedStageArgs({
    required this.bigOrder,
    required this.midOrder,
    required this.subKey,
    required this.bigName,
    required this.midName,
    required this.initialCrops,
    required this.batchScopes,
  });

  final int bigOrder;
  final int midOrder;
  final String subKey;
  final String bigName;
  final String midName;
  final List<TextbookAuthoringStageCropSeed> initialCrops;
  final List<TextbookAuthoringStageScope> batchScopes;
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

class _ResolvedContentGroup {
  const _ResolvedContentGroup({
    required this.kind,
    required this.label,
    required this.title,
    required this.order,
  });

  const _ResolvedContentGroup.none()
      : kind = 'none',
        label = '',
        title = '',
        order = null;

  final String kind;
  final String label;
  final String title;
  final int? order;
}

class _PageAnalysisRow {
  _PageAnalysisRow({
    required this.rawPage,
    required this.ok,
    this.error,
    this.displayPage = 0,
    this.section = 'unknown',
    this.pageKind = 'unknown',
    this.notes = '',
    List<TextbookVlmItem>? items,
  }) : items = items ?? const <TextbookVlmItem>[];

  factory _PageAnalysisRow.success({
    required int rawPage,
    required int displayPage,
    required String section,
    required String pageKind,
    required String notes,
    required List<TextbookVlmItem> items,
  }) {
    return _PageAnalysisRow(
      rawPage: rawPage,
      ok: true,
      displayPage: displayPage,
      section: section,
      pageKind: pageKind,
      notes: notes,
      items: items,
    );
  }

  factory _PageAnalysisRow.failure({
    required int rawPage,
    required String error,
  }) {
    return _PageAnalysisRow(rawPage: rawPage, ok: false, error: error);
  }

  /// Sentinel used by the overlay builder when the requested page has no
  /// analysis yet. Every property is safe to read but `items` is empty so
  /// the overlay list comes back empty.
  factory _PageAnalysisRow.placeholder() {
    return _PageAnalysisRow(rawPage: 0, ok: false);
  }

  final int rawPage;
  final bool ok;
  final String? error;
  final int displayPage;
  final String section;
  final String pageKind;
  final String notes;
  final List<TextbookVlmItem> items;

  bool get isConceptPage =>
      ok &&
      items.isEmpty &&
      (pageKind == 'concept_page' ||
          notes.toLowerCase().contains('concept_page'));
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
