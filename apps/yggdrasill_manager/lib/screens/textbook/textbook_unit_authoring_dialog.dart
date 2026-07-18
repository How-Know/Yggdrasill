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
import '../../services/textbook_vlm_answer_service.dart';
import '../../services/textbook_vlm_range_runner.dart';
import '../../services/textbook_vlm_solution_ref_service.dart';
import '../../services/textbook_vlm_test_service.dart';
import '../../services/problem_bank_service.dart';
import 'textbook_authoring_stage_dialog.dart';
import 'textbook_toc_autofill.dart';

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
  // 개념원리 필수유형 — 본문 '풀이' 단락에서 정답·해설 좌표를 추출/저장한다.
  final _answerService = TextbookVlmAnswerService();
  final _solRefService = TextbookVlmSolutionRefService();
  final _supa = Supabase.instance.client;

  PdfDocument? _bodyDocument;
  String? _bodyLocalPath;
  String? _pdfLoadError;
  bool _loadingPdf = false;
  final _viewerController = PdfViewerController();

  bool _loadingPayload = true;
  String? _payloadError;
  String _seriesKey = kTextbookSeriesCatalog.first.key;
  final List<_BigUnitEdit> _bigUnits = <_BigUnitEdit>[];

  bool _tocParsing = false;
  String? _tocStatus;

  // ── 개념원리(wonri) 단일 패스 ─────────────────────────────────────────
  //
  // 개념원리는 한 소단원 페이지 안에 개념/개념원리 익히기/필수유형/확인 체크
  // (/연습문제)가 섞여 순서대로 나온다. 그래서 분석 단위는 카테고리가 아니라
  // **소단원 행** 이고 (focus.subKey = 'W<rowIndex>'), VLM 은 그 페이지 범위를
  // 한 번만 훑으면서 문항마다 category 를 붙인다. 저장 시 카테고리를
  // sub_key(A~D)로 매핑해 분리 업로드한다 — 이후 정답/해설/문제은행 흐름은
  // 쎈과 동일하다.
  static const Map<String, String> _kWonriSubKeyByCategory = {
    'concept_drill': 'A', // 개념원리 익히기
    'type_example': 'B', // 필수유형
    'check': 'C', // 확인 체크
    'exercise': 'D', // 연습문제 (STEP1/STEP2/실력 UP)
  };
  static const Map<String, String> _kWonriCategoryBySubKey = {
    'A': 'concept_drill',
    'B': 'type_example',
    'C': 'check',
    'D': 'exercise',
  };
  static const Map<String, String> _kWonriCategoryShortNames = {
    'concept_drill': '익히기',
    'type_example': '필수유형',
    'check': '확인체크',
    'exercise': '연습문제',
  };

  /// 개념원리 필수유형 본문 정답·풀이 추출 대기열.
  ///
  /// 영역 저장은 소단원별로 빠르게 연속 완료될 수 있다. 기존에는 첫 소단원의
  /// 본문 체인이 실행 중이면 뒤 소단원 체인을 즉시 return 해 영구 누락시켰다.
  /// 모든 요청을 이 tail 뒤에 연결해 소단원 순서대로 반드시 한 번씩 실행한다.
  Future<void> _wonriBodyChainTail = Future<void>.value();

  bool _isWonriRowFocus(_SubFocus focus) =>
      _seriesKey == 'wonri' && focus.subKey.startsWith('W');

  _SubUnitRowEdit? _wonriRowFor(_SubFocus focus) {
    if (!_isWonriRowFocus(focus)) return null;
    final index = int.tryParse(focus.subKey.substring(1));
    if (index == null || index < 0) return null;
    if (focus.bigIndex < 0 || focus.bigIndex >= _bigUnits.length) return null;
    final big = _bigUnits[focus.bigIndex];
    if (focus.midIndex < 0 || focus.midIndex >= big.middles.length) {
      return null;
    }
    final rows = big.middles[focus.midIndex].subUnitRows;
    return index < rows.length ? rows[index] : null;
  }

  /// raw_page 가 페이지 범위에 속하는 소단원 행의 포커스 키(`W<idx>`).
  /// DB에 저장된 크롭(sub_key A~D)을 소단원 작업 단위로 복원할 때 쓴다.
  String? _wonriRowSubKeyForPage(int bigIndex, int midIndex, int? rawPage) {
    if (rawPage == null || rawPage <= 0) return null;
    if (bigIndex < 0 || bigIndex >= _bigUnits.length) return null;
    final big = _bigUnits[bigIndex];
    if (midIndex < 0 || midIndex >= big.middles.length) return null;
    final rows = big.middles[midIndex].subUnitRows;
    for (var i = 0; i < rows.length; i += 1) {
      final start = _positiveInt(rows[i].startCtrl.text);
      final end = _positiveInt(rows[i].endCtrl.text);
      if (start == null || end == null) continue;
      if (rawPage >= start && rawPage <= end) return 'W$i';
    }
    return null;
  }

  /// 분석에 실제로 쓸 페이지 범위.
  /// 개념원리 소단원 포커스면 소단원 행의 범위, 아니면 슬롯(A~C) 입력 범위.
  (int?, int?) _focusRange(_SubFocus focus) {
    if (_isWonriRowFocus(focus)) {
      final row = _wonriRowFor(focus);
      if (row == null) return (null, null);
      return (
        _positiveInt(row.startCtrl.text),
        _positiveInt(row.endCtrl.text),
      );
    }
    if (focus.bigIndex < 0 || focus.bigIndex >= _bigUnits.length) {
      return (null, null);
    }
    final big = _bigUnits[focus.bigIndex];
    if (focus.midIndex < 0 || focus.midIndex >= big.middles.length) {
      return (null, null);
    }
    final mid = big.middles[focus.midIndex];
    if (mid.subs.isEmpty) return (null, null);
    final sub = mid.subs.firstWhere(
      (s) => s.preset.key == focus.subKey,
      orElse: () => mid.subs.first,
    );
    return (_positiveInt(sub.startCtrl.text), _positiveInt(sub.endCtrl.text));
  }

  /// 문항의 개념원리 카테고리. VLM 이 붙인 category 를 우선하고,
  /// 없으면 라벨 → 페이지 section 순으로 보정한다.
  String _wonriCategoryOfItem(TextbookVlmItem item, String pageSection) {
    if (_kWonriSubKeyByCategory.containsKey(item.category)) {
      return item.category;
    }
    final label = item.label.trim();
    if (label == '필수' || label == '필수유형') return 'type_example';
    if (label == '개념원리 익히기') return 'concept_drill';
    if (label == '확인 체크' || label == '확인체크') return 'check';
    const exerciseLabels = {
      'STEP1',
      'STEP2',
      '실력',
      '실력 UP',
      '실력UP',
      '연습문제',
      '수능기출',
      '수능 기출',
      '평가원기출',
      '평가원 기출',
      '교육청기출',
      '교육청 기출',
    };
    if (exerciseLabels.contains(label)) return 'exercise';
    if (_kWonriSubKeyByCategory.containsKey(pageSection)) return pageSection;
    return '';
  }

  /// 개념원리 "문항이름" — 쎈의 난이도 자리를 대체하는 사람이 읽는 라벨.
  /// 카테고리(익히기/필수유형/확인 체크)는 그대로, 연습문제는 구간 라벨
  /// (STEP1/STEP2/실력 UP/수능·평가원·교육청 기출)을 쓰고 없으면 "연습문제".
  String _wonriItemName(String category, String rawLabel) {
    switch (category) {
      case 'concept_drill':
        return '개념원리 익히기';
      case 'type_example':
        return '필수유형';
      case 'check':
        return '확인 체크';
      case 'exercise':
        // 원시 라벨(STEP1/실력/수능기출)과 이미 정제된 표기(실력 UP/수능 기출)를
        // 모두 받아 동일하게 매핑한다 (저장된 크롭 복원 시 idempotent).
        switch (rawLabel.trim()) {
          case 'STEP1':
            return 'STEP1';
          case 'STEP2':
            return 'STEP2';
          case '실력':
          case '실력 UP':
          case '실력UP':
            return '실력 UP';
          case '수능기출':
          case '수능 기출':
            return '수능 기출';
          case '평가원기출':
          case '평가원 기출':
            return '평가원 기출';
          case '교육청기출':
          case '교육청 기출':
            return '교육청 기출';
          default:
            return '연습문제';
        }
      default:
        return '';
    }
  }

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
  bool _runProblemExtractionAfterStage1 = true;

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
      final entry = textbookSeriesByKey(series) ?? kTextbookSeriesCatalog.first;
      final loaded = bigUnitsFromPayload(payload, seriesKey: entry.key);
      final editable = <_BigUnitEdit>[];
      for (final big in loaded) {
        final bigEdit = _BigUnitEdit(bigName: big.bigName);
        for (final mid in big.middles) {
          final midEdit = _MidUnitEdit(series: entry, midName: mid.midName);
          for (final subUnit in mid.subUnits) {
            final row = _SubUnitRowEdit(
              name: subUnit.name,
              isExercise: subUnit.isExercise,
            );
            if (subUnit.startPage != null) {
              row.startCtrl.text = '${subUnit.startPage}';
            }
            if (subUnit.endPage != null) {
              row.endCtrl.text = '${subUnit.endPage}';
            }
            if (subUnit.answerStartPage != null) {
              row.answerStartCtrl.text = '${subUnit.answerStartPage}';
            }
            if (subUnit.solutionStartPage != null) {
              row.solutionStartCtrl.text = '${subUnit.solutionStartPage}';
            }
            midEdit.subUnitRows.add(row);
          }
          for (final sub in mid.subs) {
            for (final slot in midEdit.subs) {
              if (slot.preset.key == sub.subKey) {
                slot.startCtrl.text =
                    sub.startPage == null ? '' : '${sub.startPage}';
                slot.endCtrl.text = sub.endPage == null ? '' : '${sub.endPage}';
                slot.answerStartCtrl.text =
                    sub.answerStartPage == null ? '' : '${sub.answerStartPage}';
                slot.solutionStartCtrl.text = sub.solutionStartPage == null
                    ? ''
                    : '${sub.solutionStartPage}';
                break;
              }
            }
          }
          // 개념원리: 소단원 행이 있으면 A~D 슬롯 페이지를 소단원에서 유도한
          // 값으로 맞춘다 (payload 의 슬롯 값이 비었거나 어긋난 경우 대비).
          if (entry.key == 'wonri' && midEdit.subUnitRows.isNotEmpty) {
            _recalcWonriSlotPages(midEdit);
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
              'item_name, is_set_header, set_from, set_to, content_group_kind, '
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
        final bigIndex = int.tryParse('${row['big_order'] ?? ''}') ?? -1;
        final midIndex = int.tryParse('${row['mid_order'] ?? ''}') ?? -1;
        if (bigIndex < 0 || midIndex < 0) continue;
        var subKey = '${row['sub_key'] ?? ''}';
        // 개념원리: DB의 sub_key 는 카테고리(A~D)지만 작업 단위는 소단원
        // 행이므로, raw_page 가 속한 소단원 행(W<idx>)으로 재매핑한다.
        if (_seriesKey == 'wonri') {
          final rawPage = int.tryParse('${row['raw_page'] ?? ''}');
          final wonriKey = _wonriRowSubKeyForPage(bigIndex, midIndex, rawPage);
          if (wonriKey == null) continue;
          subKey = wonriKey;
        }
        final focus = _SubFocus(
          bigIndex: bigIndex,
          midIndex: midIndex,
          subKey: subKey,
        );
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

  // 단원분석/VLM 추출에서는 입력 페이지를 PDF raw page 로 그대로 사용한다.
  // textbook_metadata.page_offset 은 학습앱 표시용 보정값이며 추출 범위에는 적용하지 않는다.
  int _rawPageForDisplayPage(int displayPage) => displayPage;

  int _displayPageForRawPage(int rawPage) => rawPage;

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
            // 개념원리 W 포커스에서는 행마다 실제 카테고리 sub_key(A~D)가
            // 다르므로 DB 행의 sub_key 를 우선 사용한다.
            _vlmItemFromSavedCrop(
              row,
              '${row['sub_key'] ?? ''}'.trim().isEmpty
                  ? focus.subKey
                  : '${row['sub_key']}'.trim(),
            ),
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
      // 개념원리는 난이도(label)가 비어 있고 문항이름(item_name)에 값이 있다.
      // 복원 시 문항이름을 라벨 자리에 실어 뱃지/재저장이 그대로 동작하게 한다.
      'label': _seriesKey == 'wonri'
          ? ('${row['item_name'] ?? ''}'.trim().isNotEmpty
              ? row['item_name']
              : row['label'])
          : row['label'],
      // 개념원리: DB 의 section(=카테고리) 또는 sub_key 에서 category 복원.
      if (_seriesKey == 'wonri')
        'category': _kWonriSubKeyByCategory.containsKey(section)
            ? section
            : (_kWonriCategoryBySubKey[subKey.toUpperCase()] ?? ''),
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

  _ResolvedContentGroup _effectiveContentGroupForItem({
    required _SubFocus focus,
    required _SubRunState state,
    required int rawPage,
    required int itemIndex,
  }) {
    if (focus.subKey != 'B') return const _ResolvedContentGroup.none();
    _ResolvedContentGroup? lastGroup;
    final rows = state.pageResults.where((row) => row.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    for (final row in rows) {
      for (var i = 0; i < row.items.length; i += 1) {
        final rawGroup =
            _rawContentGroupForItem(row.items[i], focus.subKey, row.section);
        if (rawGroup.kind == 'type') lastGroup = rawGroup;
        if (row.rawPage == rawPage && i == itemIndex) {
          return rawGroup.kind == 'type'
              ? rawGroup
              : (lastGroup ?? const _ResolvedContentGroup.none());
        }
      }
    }
    return const _ResolvedContentGroup.none();
  }

  String? _requiredTypeGroupError(_SubFocus focus, _SubRunState state) {
    if (focus.subKey != 'B' ||
        (_seriesKey != 'ssen' && _seriesKey != 'rpm')) {
      return null;
    }
    final items = state.pageResults
        .where((row) => row.ok)
        .expand((row) => row.items)
        .toList(growable: false);
    if (items.isEmpty) return null;
    final hasType = items.any((item) {
      final group =
          _rawContentGroupForItem(item, focus.subKey, 'type_practice');
      return group.kind == 'type';
    });
    return hasType
        ? null
        : 'B단계 유형명을 하나도 추출하지 못했습니다. 유형명 포함 재분석이 필요합니다.';
  }

  String _sectionForSubKey(String subKey) {
    // 개념원리는 슬롯 의미가 문제집(쎈/RPM)과 다르다.
    // 게이트웨이 vlm_detect_prompt.js 의 WONRI_SECTION_BY_SUB_KEY 와 동일하게 유지.
    if (_seriesKey == 'wonri') {
      switch (subKey) {
        case 'A':
          return 'concept_drill'; // 개념원리 익히기
        case 'B':
          return 'type_example'; // 필수유형
        case 'C':
          return 'check'; // 확인 체크
        case 'D':
          return 'exercise'; // 연습문제 (STEP1/STEP2/실력 UP)
        default:
          return 'unknown';
      }
    }
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

  bool _isRpmAConceptPage(
    _SubFocus focus,
    int rawPage,
    int rawStartPage,
  ) {
    return _seriesKey == 'rpm' &&
        focus.subKey == 'A' &&
        (rawPage - rawStartPage).isEven;
  }

  TextbookVlmDetectResult _rpmAConceptPageResult(int rawPage) {
    return TextbookVlmDetectResult(
      rawPage: rawPage,
      displayPage: _displayPageForRawPage(rawPage),
      pageOffset: 0,
      pageOffsetFound: false,
      section: 'basic_drill',
      pageKind: 'concept_page',
      conceptDrillHeaderVisible: false,
      layout: 'unknown',
      items: const <TextbookVlmItem>[],
      notes: 'rpm_a_concept_page_by_alternation',
      model: 'deterministic_series_rule',
      elapsedMs: 0,
      finishReason: 'RULE',
    );
  }

  // ------------------------------------------------------- 목차 자동 인식
  //
  // 등록 위저드와 동일한 흐름: 본문 PDF의 목차 페이지 범위 + 페이지 보정을
  // 입력받아 VLM 으로 단원 트리를 읽고, 단원 이름과 페이지 범위를 자동으로
  // 채운다. 신규행으로 추가한(위저드를 거치지 않은) 책도 여기서 쓸 수 있다.
  // 적용 후 "단원 구조 저장"을 눌러야 Supabase 에 반영된다.

  Future<void> _runTocAutoParse() async {
    if (_tocParsing) return;
    final doc = await _ensurePdf();
    if (doc == null) {
      _toast(
        '본문 PDF를 불러오지 못했습니다'
        '${_pdfLoadError == null ? '' : ': $_pdfLoadError'}',
        error: true,
      );
      return;
    }
    if (!mounted) return;
    // 이미 입력된 트리가 있으면 덮어쓰기 확인.
    final hasContent = _bigUnits.any((b) =>
        b.nameCtrl.text.trim().isNotEmpty ||
        b.middles.any((m) => m.nameCtrl.text.trim().isNotEmpty));
    if (hasContent) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          title: const Text('기존 트리 덮어쓰기',
              style:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
          content: const Text(
            '목차 자동 인식은 현재 단원 트리를 새 결과로 교체합니다. 계속할까요?\n'
            '(저장 전까지는 Supabase 에 반영되지 않습니다)',
            style: TextStyle(color: Color(0xFF9FB3B3), fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('취소', style: TextStyle(color: Colors.white70)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(backgroundColor: _kAccent),
              child: const Text('덮어쓰기'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final range = await showTocRangeDialog(context);
    if (range == null) return;
    setState(() {
      _tocParsing = true;
      _tocStatus = '목차 페이지 렌더링 중...';
    });
    try {
      final start = range.start.clamp(1, doc.pages.length);
      final end = range.end.clamp(start, doc.pages.length);
      final images = <Uint8List>[];
      for (var page = start; page <= end; page += 1) {
        images.add(await renderPdfPageToPng(
          document: doc,
          pageNumber: page,
          longEdgePx: 1600,
        ));
        if (!mounted) return;
        setState(() => _tocStatus = '목차 페이지 렌더링 중... ($page / $end)');
      }
      if (!mounted) return;
      setState(() => _tocStatus = 'VLM 목차 분석 중... (${images.length}페이지)');
      final result = await _vlmService.parseToc(
        pageImages: images,
        series: _seriesKey,
      );
      if (!mounted) return;
      final applied = await _applyTocResult(
        result,
        document: doc,
        tocPageOffset: range.pageOffset,
      );
      if (!mounted) return;
      setState(() {
        _tocParsing = false;
        _tocStatus = applied == null
            ? '실패: 목차에서 단원을 찾지 못했습니다.'
            : '목차 인식 완료 · 대단원 ${applied.$1}개 / 중단원 ${applied.$2}개 · '
                '페이지 자동 입력됨(보정 ${range.pageOffset >= 0 ? '+' : ''}'
                '${range.pageOffset}) — 검토 후 "단원 구조 저장"을 누르세요'
                '${applied.$3}'
                '${result.notes.isEmpty ? '' : ' · ${result.notes}'}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tocParsing = false;
        _tocStatus = '실패: $e';
      });
    }
  }

  /// VLM 목차 결과를 단원 트리에 반영한다. (대단원 수, 중단원 수) 를 반환.
  ///
  /// 이름 정리와 페이지 자동 채움은 [buildTocAutofillTree] (공용 로직) 가
  /// 처리한다. 개념원리(wonri)는 소단원 행을 payload 용으로 보존하고,
  /// A~D 슬롯 페이지를 소단원 범위에서 유도해 입력칸까지 채운다
  /// (A/B/C = 일반 소단원 전체 범위, D = 연습문제 행 범위).
  Future<(int, int, String)?> _applyTocResult(
    TextbookTocParseResult toc, {
    required PdfDocument document,
    int tocPageOffset = 0,
  }) async {
    final entry = _currentSeries();
    final isWonri = _seriesKey == 'wonri';
    final tree = buildTocAutofillTree(
      toc,
      subUnitRows: isWonri,
      tocPageOffset: tocPageOffset,
      lastRawPage: document.pages.length,
    );
    if (tree.isEmpty) return null;
    var partStatus = '';
    if (_seriesKey == 'ssen' || _seriesKey == 'rpm') {
      final report = await autofillProblemBookPartRanges(
        tree,
        classify: (rawPages) async {
          final images = <TextbookRpmSectionImage>[];
          for (final rawPage in rawPages) {
            images.add(TextbookRpmSectionImage(
              rawPage: rawPage,
              bytes: await renderPdfPageToPng(
                document: document,
                pageNumber: rawPage,
                longEdgePx: 1100,
              ),
            ));
          }
          final result = await _vlmService.classifyProblemBookSections(
            images: images,
            series: _seriesKey,
          );
          return result.pages;
        },
        onProgress: (message) {
          if (mounted) setState(() => _tocStatus = message);
        },
      );
      if (report.incompleteMids.isNotEmpty) {
        partStatus = ' · ${_seriesKey == 'ssen' ? '쎈' : 'RPM'} 경계 미확인: '
            '${report.incompleteMids.join(', ')}';
      } else {
        partStatus = ' · ${_seriesKey == 'ssen' ? '쎈' : 'RPM'} '
            'A/B/C ${report.completedMids}개 중단원 자동 분리';
      }
    }
    final newBigs = <_BigUnitEdit>[];
    for (final big in tree) {
      final bigEdit = _BigUnitEdit(bigName: big.name);
      for (final mid in big.midUnits) {
        final midEdit = _MidUnitEdit(series: entry, midName: mid.name);
        if (isWonri) {
          for (final sub in mid.subUnits) {
            final row = _SubUnitRowEdit(
              name: sub.name,
              isExercise: sub.isExercise,
            );
            if (sub.startPage != null) row.startCtrl.text = '${sub.startPage}';
            if (sub.endPage != null) row.endCtrl.text = '${sub.endPage}';
            midEdit.subUnitRows.add(row);
          }
          _recalcWonriSlotPages(midEdit);
        }
        if (_seriesKey == 'ssen' || _seriesKey == 'rpm') {
          for (final slot in midEdit.subs) {
            final range = mid.rpmPartRanges[slot.preset.key];
            if (range == null) continue;
            slot.startCtrl.text = '${range.startPage}';
            slot.endCtrl.text = '${range.endPage}';
          }
        }
        bigEdit.middles.add(midEdit);
      }
      if (bigEdit.middles.isEmpty) {
        bigEdit.middles.add(_MidUnitEdit(series: entry));
      }
      newBigs.add(bigEdit);
    }
    var midCount = 0;
    for (final big in newBigs) {
      midCount += big.middles.length;
    }
    setState(() {
      for (final big in _bigUnits) {
        big.dispose();
      }
      _bigUnits
        ..clear()
        ..addAll(newBigs);
      _focus = null;
      _selectedProblemKey = null;
    });
    return (newBigs.length, midCount, partStatus);
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

  /// 소단원 행들의 페이지에서 A~D 슬롯 페이지를 유도해 입력칸을 갱신한다.
  /// A/B/C(개념원리 익히기·필수유형·확인 체크) = 일반 소단원 전체 범위,
  /// D(연습문제) = "연습문제" 행 범위.
  void _recalcWonriSlotPages(_MidUnitEdit mid) {
    int? lessonStart;
    int? lessonEnd;
    int? exerciseStart;
    int? exerciseEnd;
    for (final row in mid.subUnitRows) {
      final start = _positiveInt(row.startCtrl.text);
      final end = _positiveInt(row.endCtrl.text);
      if (row.isExercise) {
        if (start != null) {
          exerciseStart = exerciseStart == null
              ? start
              : (start < exerciseStart ? start : exerciseStart);
        }
        if (end != null) {
          exerciseEnd = exerciseEnd == null
              ? end
              : (end > exerciseEnd ? end : exerciseEnd);
        }
      } else {
        if (start != null) {
          lessonStart = lessonStart == null
              ? start
              : (start < lessonStart ? start : lessonStart);
        }
        if (end != null) {
          lessonEnd =
              lessonEnd == null ? end : (end > lessonEnd ? end : lessonEnd);
        }
      }
    }
    for (final slot in mid.subs) {
      final isExerciseSlot = slot.preset.key == 'D';
      final start = isExerciseSlot ? exerciseStart : lessonStart;
      final end = isExerciseSlot ? exerciseEnd : lessonEnd;
      slot.startCtrl.text = start == null ? '' : '$start';
      slot.endCtrl.text = end == null ? '' : '$end';
    }
  }

  List<BigUnitInput> _buildBigUnitInputs() {
    final out = <BigUnitInput>[];
    for (var i = 0; i < _bigUnits.length; i += 1) {
      final big = _bigUnits[i];
      final midList = <MidUnitInput>[];
      for (var m = 0; m < big.middles.length; m += 1) {
        final mid = big.middles[m];
        // 개념원리: 저장 직전에 소단원 행 → A~D 슬롯 페이지를 다시 유도해
        // 슬롯 입력칸과 payload 가 항상 소단원 입력과 일치하게 한다.
        if (_seriesKey == 'wonri' && mid.subUnitRows.isNotEmpty) {
          _recalcWonriSlotPages(mid);
        }
        final subUnitList = <SubUnitInput>[];
        var order = 0;
        for (final row in mid.subUnitRows) {
          final name = row.nameCtrl.text.trim();
          if (name.isEmpty) continue;
          subUnitList.add(SubUnitInput(
            order: order,
            name: name,
            startPage: _positiveInt(row.startCtrl.text),
            endPage: _positiveInt(row.endCtrl.text),
            answerStartPage: _positiveInt(row.answerStartCtrl.text),
            solutionStartPage: _positiveInt(row.solutionStartCtrl.text),
            isExercise: row.isExercise,
          ));
          order += 1;
        }
        final subList = <SubSectionInput>[];
        for (var s = 0; s < mid.subs.length; s += 1) {
          final sub = mid.subs[s];
          subList.add(SubSectionInput(
            order: s,
            subKey: sub.preset.key,
            displayName: sub.preset.displayName,
            startPage: _positiveInt(sub.startCtrl.text),
            endPage: _positiveInt(sub.endCtrl.text),
            answerStartPage: _positiveInt(sub.answerStartCtrl.text),
            solutionStartPage: _positiveInt(sub.solutionStartCtrl.text),
          ));
        }
        midList.add(MidUnitInput(
          midOrder: m,
          midName: mid.nameCtrl.text.trim(),
          subs: subList,
          subUnits: subUnitList,
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
        requireMigratedStorage: true,
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
        for (final focus in _midBatchFocuses(b, m)) {
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
    // 개념원리: 배치 실행 단위는 카테고리 슬롯이 아니라 소단원 행이다.
    if (_seriesKey == 'wonri') {
      return [
        for (var s = 0; s < mid.subUnitRows.length; s += 1)
          _SubFocus(bigIndex: bigIndex, midIndex: midIndex, subKey: 'W$s'),
      ];
    }
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

  Future<String?> _expectedStartNumberForFocus(_SubFocus focus) async {
    // 4자리 연속 번호(0001~)는 쎈/RPM A 파트 전용 개념이다.
    if (focus.subKey != 'A' || _seriesKey == 'wonri') return null;
    try {
      final rows = await _supa
          .from('textbook_problem_crops')
          .select('problem_number,set_to,big_order,mid_order,sub_key')
          .eq('academy_id', widget.academyId)
          .eq('book_id', widget.bookId)
          .eq('grade_label', widget.gradeLabel)
          .limit(5000);
      var maxPrevious = 0;
      for (final raw in rows) {
        if (!_cropRowIsBeforeFocus(raw, focus)) continue;
        final value = _problemNumberEndValue(raw);
        if (value != null && value > maxPrevious) {
          maxPrevious = value;
        }
      }
      if (maxPrevious <= 0 || maxPrevious >= 9999) return null;
      return _formatBasicDrillNumber(maxPrevious + 1);
    } catch (e) {
      debugPrint('[textbook-stage1] expected start lookup failed: $e');
      return null;
    }
  }

  bool _cropRowIsBeforeFocus(Map<dynamic, dynamic> row, _SubFocus focus) {
    final bigOrder = int.tryParse('${row['big_order'] ?? ''}');
    final midOrder = int.tryParse('${row['mid_order'] ?? ''}');
    if (bigOrder == null || midOrder == null) return false;
    if (bigOrder != focus.bigIndex) return bigOrder < focus.bigIndex;
    if (midOrder != focus.midIndex) return midOrder < focus.midIndex;
    return _subOrderOf('${row['sub_key'] ?? ''}') < _subOrderOf(focus.subKey);
  }

  int _subOrderOf(String subKey) {
    switch (subKey.trim()) {
      case 'A':
        return 0;
      case 'B':
        return 1;
      case 'C':
        return 2;
      case 'D':
        return 3;
      default:
        return 99;
    }
  }

  int? _problemNumberEndValue(Map<dynamic, dynamic> row) {
    final setTo = int.tryParse('${row['set_to'] ?? ''}');
    if (setTo != null && setTo > 0 && setTo <= 9999) return setTo;
    final rawNumber = '${row['problem_number'] ?? ''}';
    final matches = RegExp(r'\d+').allMatches(rawNumber);
    var out = 0;
    for (final match in matches) {
      final value = int.tryParse(match.group(0) ?? '');
      if (value != null && value > out && value <= 9999) {
        out = value;
      }
    }
    return out > 0 ? out : null;
  }

  String _formatBasicDrillNumber(int value) => value.toString().padLeft(4, '0');

  String? _expectedStartNumberForPage(
    _SubFocus focus,
    _SubRunState state,
    int rawPage,
    String? expectedStartNumber,
  ) {
    if (focus.subKey != 'A' || expectedStartNumber == null) return null;
    final alreadySawProblemBeforePage = state.pageResults.any((row) =>
        row.ok &&
        row.rawPage < rawPage &&
        row.section == 'basic_drill' &&
        row.items.isNotEmpty);
    return alreadySawProblemBeforePage ? null : expectedStartNumber;
  }

  Future<void> _runFocusedAnalysis(_SubFocus focus) async {
    final (displayStartPage, displayEndPage) = _focusRange(focus);
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
    final expectedStartNumber = await _expectedStartNumberForFocus(focus);
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
    }) async {
      if (_isRpmAConceptPage(focus, rawPage, rawStartPage)) {
        return _rpmAConceptPageResult(rawPage);
      }
      final result = await _vlmService.detectProblemsOnPage(
        imageBytes: imageBytes,
        rawPage: rawPage,
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        // 개념원리는 단일 패스: 카테고리 힌트 없이 페이지의 모든 문항을
        // 감지하고 문항별 category 를 받는다.
        sectionHint:
            _seriesKey == 'wonri' ? null : _sectionForSubKey(focus.subKey),
        expectedStartNumber: _expectedStartNumberForPage(
          focus,
          state,
          rawPage,
          expectedStartNumber,
        ),
        series: _seriesKey,
      );
      if (_seriesKey == 'rpm' &&
          focus.subKey == 'A' &&
          result.items.isEmpty) {
        throw StateError(
          'rpm_a_expected_problem_page_empty: raw_page=$rawPage',
        );
      }
      return result;
    }

    try {
      final finalProgress = await runRangeAnalysis(
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
            conceptDrillHeaderVisible: outcome.result.conceptDrillHeaderVisible,
            notes: outcome.result.notes,
            items: outcome.result.items,
          ));
          _applyScopeGuards(focus);
          if (!mounted) return;
          setState(() {});
        },
        onPageFailure: (f) {
          debugPrint('[textbook-stage1] page failed '
              'raw=${f.rawPage} attempts=${f.attempts} error=${f.error}');
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
      final typeGroupError = _requiredTypeGroupError(focus, state);
      setState(() {
        state.running = false;
        state.error = finalProgress.lastError ?? typeGroupError;
        state.phase = finalProgress.failed > 0
            ? '일부 실패'
            : (typeGroupError == null ? '완료' : '유형명 누락');
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
    final expectedStartNumber = await _expectedStartNumberForFocus(focus);
    final rawStartPage = _rawStartPageForFocus(focus);
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
    }) async {
      if (rawStartPage != null &&
          _isRpmAConceptPage(focus, rawPage, rawStartPage)) {
        return _rpmAConceptPageResult(rawPage);
      }
      final result = await _vlmService.detectProblemsOnPage(
        imageBytes: imageBytes,
        rawPage: rawPage,
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        sectionHint:
            _seriesKey == 'wonri' ? null : _sectionForSubKey(focus.subKey),
        expectedStartNumber: _expectedStartNumberForPage(
          focus,
          state,
          rawPage,
          expectedStartNumber,
        ),
        series: _seriesKey,
      );
      if (_seriesKey == 'rpm' &&
          focus.subKey == 'A' &&
          result.items.isEmpty) {
        throw StateError(
          'rpm_a_expected_problem_page_empty: raw_page=$rawPage',
        );
      }
      return result;
    }

    try {
      final finalProgress = await retryFailedPages(
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
            conceptDrillHeaderVisible: outcome.result.conceptDrillHeaderVisible,
            notes: outcome.result.notes,
            items: outcome.result.items,
          ));
          _applyScopeGuards(focus);
          if (!mounted) return;
          setState(() {});
        },
        onPageFailure: (f) {
          debugPrint('[textbook-stage1-retry] page failed '
              'raw=${f.rawPage} attempts=${f.attempts} error=${f.error}');
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
      final typeGroupError = _requiredTypeGroupError(focus, state);
      setState(() {
        state.running = false;
        state.error = finalProgress.lastError ?? typeGroupError;
        state.phase = finalProgress.failed > 0
            ? '재분석 일부 실패'
            : (typeGroupError == null ? '재분석 완료' : '유형명 누락');
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

  void _applyScopeGuards(_SubFocus focus) {
    final state = _ensureSubState(focus);
    if (state.pageResults.isEmpty) return;
    late final List<_PageAnalysisRow> guarded;
    if (_seriesKey == 'wonri') {
      // 개념원리 일반 소단원은 정확한 "개념원리 익히기" 헤더가 처음
      // 확인되기 전까지 전부 개념 페이지다. 연습문제 행은 STEP 구조라 제외.
      final row = _wonriRowFor(focus);
      if (row == null || row.isExercise) return;
      guarded = _guardWonriRowsBeforeConceptDrillHeader(state.pageResults);
    } else {
      // basic_drill(4자리 번호) 가드는 쎈/RPM A 파트 전용.
      if (focus.subKey != 'A') return;
      guarded = _guardBasicDrillRows(
        state.pageResults,
        startRawPage: _rawStartPageForFocus(focus),
      );
    }
    if (_samePageRows(state.pageResults, guarded)) return;
    state.pageResults
      ..clear()
      ..addAll(guarded);
    _manualEdits[_stateKeyFor(focus)]?.removeWhere((key, _) {
      final parts = key.split(':');
      if (parts.length != 2) return true;
      final rawPage = int.tryParse(parts[0]);
      final index = int.tryParse(parts[1]);
      if (rawPage == null || index == null) return true;
      final row = state.pageResults.firstWhere(
        (r) => r.rawPage == rawPage && r.ok,
        orElse: () => _PageAnalysisRow.placeholder(),
      );
      return index < 0 || index >= row.items.length;
    });
  }

  /// 개념원리 일반 소단원의 최초 "개념원리 익히기" 인쇄 헤더 전 페이지를
  /// 강제로 concept_page 로 만든다. VLM 이 개념 번호/예제 번호를 문항으로
  /// 오인해도 이 경계를 통과하기 전에는 저장될 수 없다.
  List<_PageAnalysisRow> _guardWonriRowsBeforeConceptDrillHeader(
    List<_PageAnalysisRow> rows,
  ) {
    final successful = rows.where((r) => r.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    int? firstHeaderPage;
    for (final row in successful) {
      if (row.conceptDrillHeaderVisible) {
        firstHeaderPage = row.rawPage;
        break;
      }
    }
    final out = <_PageAnalysisRow>[];
    for (final row in rows) {
      final beforeHeader =
          row.ok && (firstHeaderPage == null || row.rawPage < firstHeaderPage);
      if (!beforeHeader) {
        out.add(row);
        continue;
      }
      if (row.items.isEmpty && row.pageKind == 'concept_page') {
        out.add(row);
        continue;
      }
      out.add(_rowWithGuardedItems(
        row,
        const <TextbookVlmItem>[],
        row.items.length,
        reason: 'wonri_before_concept_drill_header_filtered',
      ));
    }
    return out;
  }

  int? _rawStartPageForFocus(_SubFocus focus) {
    if (focus.bigIndex < 0 || focus.bigIndex >= _bigUnits.length) return null;
    final big = _bigUnits[focus.bigIndex];
    if (focus.midIndex < 0 || focus.midIndex >= big.middles.length) {
      return null;
    }
    final mid = big.middles[focus.midIndex];
    final sub = mid.subs.firstWhere(
      (s) => s.preset.key == focus.subKey,
      orElse: () => mid.subs.first,
    );
    final displayStart = _positiveInt(sub.startCtrl.text);
    return displayStart == null ? null : _rawPageForDisplayPage(displayStart);
  }

  List<_PageAnalysisRow> _guardBasicDrillRows(
    List<_PageAnalysisRow> rows, {
    int? startRawPage,
  }) {
    final firstPass = <_PageAnalysisRow>[];

    for (final row in rows) {
      if (!row.ok || row.section != 'basic_drill' || row.items.isEmpty) {
        firstPass.add(row);
        continue;
      }
      final kept = <TextbookVlmItem>[];
      var dropped = 0;
      for (final item in row.items) {
        if (_isValidBasicDrillCandidate(item)) {
          kept.add(item);
        } else {
          dropped += 1;
        }
      }
      firstPass.add(_rowWithGuardedItems(
        row,
        kept,
        dropped,
        reason: 'basic_drill_candidate_filtered',
      ));
    }

    return _guardBasicDrillStartPage(firstPass, startRawPage);
  }

  List<_PageAnalysisRow> _guardBasicDrillStartPage(
    List<_PageAnalysisRow> rows,
    int? startRawPage,
  ) {
    if (startRawPage == null) return rows;
    final firstIndex = rows.indexWhere((r) =>
        r.ok &&
        r.rawPage == startRawPage &&
        r.section == 'basic_drill' &&
        r.items.isNotEmpty);
    if (firstIndex < 0) return rows;

    final first = rows[firstIndex];
    final laterRows = rows
        .where((r) =>
            r.ok &&
            r.rawPage > startRawPage &&
            r.section == 'basic_drill' &&
            r.items.isNotEmpty)
        .toList();
    if (laterRows.isEmpty) return rows;

    final firstValues = _basicDrillNumberValues(first.items);
    final laterValues = _basicDrillNumberValues(
      laterRows.expand((r) => r.items).toList(growable: false),
    );
    if (firstValues.isEmpty || laterValues.isEmpty) return rows;

    final firstHasGroup = first.items.any(_hasBasicDrillContentGroup);
    final laterHasGroup =
        laterRows.expand((r) => r.items).any(_hasBasicDrillContentGroup);
    final connected = _numberSetsAreNear(firstValues, laterValues);

    if (connected || firstHasGroup || !laterHasGroup) return rows;

    final out = List<_PageAnalysisRow>.of(rows);
    out[firstIndex] = _rowWithGuardedItems(
      first,
      const <TextbookVlmItem>[],
      first.items.length,
      reason: 'basic_drill_start_page_filtered',
    );
    return out;
  }

  _PageAnalysisRow _rowWithGuardedItems(
    _PageAnalysisRow row,
    List<TextbookVlmItem> kept,
    int dropped, {
    required String reason,
  }) {
    if (dropped <= 0) return row;
    final notes = _appendGuardNote(row.notes, '$reason=$dropped');
    if (kept.isEmpty) {
      return _PageAnalysisRow.success(
        rawPage: row.rawPage,
        displayPage: row.displayPage,
        section: row.section,
        pageKind: 'concept_page',
        conceptDrillHeaderVisible: row.conceptDrillHeaderVisible,
        notes: _appendGuardNote(notes, 'concept_page:auto_guarded'),
        items: const <TextbookVlmItem>[],
      );
    }
    return _PageAnalysisRow.success(
      rawPage: row.rawPage,
      displayPage: row.displayPage,
      section: row.section,
      pageKind: row.pageKind == 'concept_page' ? 'mixed' : row.pageKind,
      conceptDrillHeaderVisible: row.conceptDrillHeaderVisible,
      notes: notes,
      items: kept,
    );
  }

  bool _isValidBasicDrillCandidate(TextbookVlmItem item) {
    if (!_isBasicDrillNumber(item)) return false;
    final bbox = item.bbox;
    final region = item.itemRegion;
    if (bbox == null ||
        bbox.length != 4 ||
        region == null ||
        region.length != 4) {
      return false;
    }
    final byMin = bbox[0];
    final bxMin = bbox[1];
    final byMax = bbox[2];
    final bxMax = bbox[3];
    final ryMin = region[0];
    final rxMin = region[1];
    final ryMax = region[2];
    final rxMax = region[3];
    if (byMin >= byMax || bxMin >= bxMax || ryMin >= ryMax || rxMin >= rxMax) {
      return false;
    }

    // RPM A에는 짧은 가로형 외에 세로형·독립형 세트가 섞인다. 4자리 번호와
    // 유효 좌표가 확인되면 쎈 전용 짧은 행 기하 검증으로 제거하지 않는다.
    if (_seriesKey == 'rpm') return true;

    if (item.label.trim().isNotEmpty) return false;
    final regionHeight = ryMax - ryMin;
    final numberCenterY = (byMin + byMax) / 2;
    if (regionHeight > 380) return false;
    final regionStartsAfterNumber = bxMin < rxMin && bxMax <= rxMin + 60;
    final regionContainsNumber = rxMin <= bxMin + 8 && rxMax >= bxMax + 40;
    if (!regionStartsAfterNumber && !regionContainsNumber) return false;
    if (numberCenterY < ryMin - 80 || numberCenterY > ryMax + 80) {
      return false;
    }
    return true;
  }

  bool _isBasicDrillNumber(TextbookVlmItem item) {
    final number = item.number.trim();
    if (item.isSetHeader) {
      final pattern = _seriesKey == 'rpm'
          ? RegExp(r'^(\d{1,4})\s*[~\-\u2013\u2014\u301c]\s*(\d{1,4})$')
          : RegExp(r'^(\d{4})\s*[~\-\u2013\u2014\u301c]\s*(\d{4})$');
      final match = pattern.firstMatch(number);
      if (match == null) return false;
      final from = int.tryParse(match.group(1)!);
      final to = int.tryParse(match.group(2)!);
      return from != null && to != null && from <= to;
    }
    return RegExp(r'^\d{4}$').hasMatch(number);
  }

  int? _basicDrillIndividualNumber(TextbookVlmItem item) {
    if (item.isSetHeader) return null;
    final number = item.number.trim();
    if (!RegExp(r'^\d{4}$').hasMatch(number)) return null;
    return int.tryParse(number);
  }

  Set<int> _basicDrillNumberValues(List<TextbookVlmItem> items) {
    final out = <int>{};
    for (final item in items) {
      if (item.isSetHeader) {
        final pattern = _seriesKey == 'rpm'
            ? RegExp(r'^(\d{1,4})\s*[~\-\u2013\u2014\u301c]\s*(\d{1,4})$')
            : RegExp(r'^(\d{4})\s*[~\-\u2013\u2014\u301c]\s*(\d{4})$');
        final match = pattern.firstMatch(item.number.trim());
        final from = match == null ? null : int.tryParse(match.group(1)!);
        final to = match == null ? null : int.tryParse(match.group(2)!);
        if (from != null && to != null && from <= to && to - from <= 30) {
          for (var n = from; n <= to; n += 1) {
            out.add(n);
          }
        }
      } else {
        final n = _basicDrillIndividualNumber(item);
        if (n != null) out.add(n);
      }
    }
    return out;
  }

  bool _hasBasicDrillContentGroup(TextbookVlmItem item) {
    if (item.contentGroupKind != 'basic_subtopic') return false;
    return item.contentGroupLabel.trim().isNotEmpty ||
        item.contentGroupTitle.trim().isNotEmpty;
  }

  bool _numberSetsAreNear(Set<int> a, Set<int> b) {
    for (final x in a) {
      for (final y in b) {
        if ((x - y).abs() <= 2) return true;
      }
    }
    return false;
  }

  String _appendGuardNote(String notes, String suffix) {
    final trimmed = notes.trim();
    if (trimmed.contains(suffix)) return trimmed;
    return trimmed.isEmpty ? suffix : '$trimmed; $suffix';
  }

  bool _samePageRows(List<_PageAnalysisRow> a, List<_PageAnalysisRow> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i].rawPage != b[i].rawPage ||
          a[i].ok != b[i].ok ||
          a[i].pageKind != b[i].pageKind ||
          a[i].notes != b[i].notes ||
          a[i].items.length != b[i].items.length) {
        return false;
      }
    }
    return true;
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
    _applyScopeGuards(focus);
    final typeGroupError = _requiredTypeGroupError(focus, state);
    if (typeGroupError != null) {
      _toast(typeGroupError, error: true);
      return;
    }
    if (_isWonriRowFocus(focus)) {
      await _uploadWonriRowFocus(focus, state);
      return;
    }
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

  /// 개념원리 단일 패스 저장 — 소단원 분석 결과의 문항을 category 별로
  /// sub_key(A~D)에 나눠 업로드한다. 이후 정답/해설/문제은행 흐름은
  /// 쎈과 동일하게 sub_key 단위로 동작한다. 업로드가 끝나면 필수유형(B)
  /// 문항은 본문 '풀이' 단락에서 정답·풀이 좌표를 자동 추출한다.
  Future<void> _uploadWonriRowFocus(_SubFocus focus, _SubRunState state) async {
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final edits = _manualEdits[_stateKeyFor(focus)];
    final itemsBySubKey = <String, List<TextbookCropUploadItem>>{};
    var skippedNoCategory = 0;
    // 필수유형은 유형 헤더가 있는 페이지에서만 content_group 이 잡히므로,
    // 그룹 정보가 빠진 후속 문항은 직전 유형 그룹을 승계한다 (쎈 B 와 동일).
    _ResolvedContentGroup? lastTypeGroup;
    final pageRows = state.pageResults.where((r) => r.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    for (final row in pageRows) {
      for (var i = 0; i < row.items.length; i += 1) {
        final vlm = row.items[i];
        final edited = edits?[_problemKey(row.rawPage, i)];
        final region = edited ?? vlm.itemRegion;
        if (region == null || region.length != 4) continue;
        final category = _wonriCategoryOfItem(vlm, row.section);
        if (category.isEmpty) {
          skippedNoCategory += 1;
          continue;
        }
        final subKey = _kWonriSubKeyByCategory[category]!;
        var group = const _ResolvedContentGroup.none();
        if (category == 'type_example') {
          final rawGroup = _rawContentGroupForItem(vlm, subKey, category);
          group =
              rawGroup.kind == 'type' ? rawGroup : (lastTypeGroup ?? rawGroup);
          if (rawGroup.kind == 'type') lastTypeGroup = rawGroup;
        }
        // 필수유형(B)은 소단원마다 번호(01,02...)가 새로 시작한다. 소단원별
        // 분리는 저장 시 sub_index(= 소단원 순번)로 처리하므로, 번호 자체는
        // 인쇄된 값을 그대로 쓴다. (익히기/확인체크/연습문제는 중단원 내 연속.)
        itemsBySubKey
            .putIfAbsent(subKey, () => <TextbookCropUploadItem>[])
            .add(TextbookCropUploadItem(
              rawPage: row.rawPage,
              displayPage: row.displayPage,
              section: category,
              problemNumber: vlm.number,
              // 개념서는 난이도가 없다. 난이도(label)는 비우고, 문항이름은
              // 전용 컬럼(itemName)에 저장한다.
              label: '',
              itemName: _wonriItemName(category, vlm.label),
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
    final totalItems =
        itemsBySubKey.values.fold<int>(0, (sum, list) => sum + list.length);
    if (totalItems == 0) {
      _toast('저장할 문항 영역이 없습니다', error: true);
      return;
    }

    setState(() {
      state.uploading = true;
      state.phase = '영역 저장 중... ($totalItems건)';
      state.error = null;
      state.uploadResult = null;
    });
    try {
      final allRows = <Map<String, dynamic>>[];
      var upserted = 0;
      // 필수유형(B)만 소단원별로 분리 저장한다 (번호가 소단원마다 새로 시작).
      // 익히기(A)/확인체크(C)/연습문제(D)는 중단원 내 연속 번호라 sub_index=0.
      final wonriIndex = _wonriRowIndex(focus) ?? 0;
      for (final subKey in const ['A', 'B', 'C', 'D']) {
        final items = itemsBySubKey[subKey];
        if (items == null || items.isEmpty) continue;
        final categoryName =
            _kWonriCategoryShortNames[_kWonriCategoryBySubKey[subKey]] ??
                subKey;
        final result = await _cropUploader.uploadCropBatch(
          academyId: widget.academyId,
          bookId: widget.bookId,
          gradeLabel: widget.gradeLabel,
          bigOrder: focus.bigIndex,
          midOrder: focus.midIndex,
          subKey: subKey,
          subIndex: subKey == 'B' ? wonriIndex : 0,
          bigName: big.nameCtrl.text.trim(),
          midName: mid.nameCtrl.text.trim(),
          items: items,
          regionsOnly: true,
          onProgress: (processed, total) {
            if (!mounted) return;
            setState(() {
              state.phase = '$categoryName 저장 중... $processed / $total';
            });
          },
        );
        upserted += result.upserted;
        allRows.addAll(result.rows);
      }
      if (!mounted) return;
      final skippedNote =
          skippedNoCategory > 0 ? ' · 카테고리 미상 $skippedNoCategory건 제외' : '';
      setState(() {
        state.uploading = false;
        state.uploadResult = TextbookCropBatchResult(
          upserted: upserted,
          bucket: 'textbook-crops',
          rows: allRows,
        );
        state.phase = '영역 저장 완료 · $upserted/$totalItems건$skippedNote';
      });
      _toast('${_subFocusLabel(focus)} 영역 $upserted건을 서버에 저장했습니다');
      unawaited(_loadStageStatuses());

      final typeRows = allRows
          .where((r) => '${r['sub_key'] ?? ''}'.trim().toUpperCase() == 'B')
          .toList();
      if (typeRows.isNotEmpty) {
        await _enqueueWonriBodySolutionChain(focus, typeRows);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        state.uploading = false;
        state.error = '$e';
        state.phase = '영역 저장 실패';
      });
    }
  }

  /// 개념원리 필수유형(B) 자동 체이닝 — 영역 저장 직후 본문 PDF의 "풀이"
  /// 단락에서 정답(굵은 글씨)과 풀이 좌표를 추출해 정답/해설 테이블에
  /// 저장한다 (source_kind='body'). 실패해도 영역 저장 자체는 유지된다.
  Future<void> _enqueueWonriBodySolutionChain(
    _SubFocus focus,
    List<Map<String, dynamic>> typeRows,
  ) {
    final next = _wonriBodyChainTail.then(
      (_) => _runWonriBodySolutionChain(focus, typeRows),
    );
    // 한 요청의 예외가 이후 대기 요청까지 끊지 않도록 tail 은 항상 정상화한다.
    _wonriBodyChainTail = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[wonri-body-chain] queued task failed: $error');
      },
    );
    return next;
  }

  Future<void> _runWonriBodySolutionChain(
    _SubFocus focus,
    List<Map<String, dynamic>> typeRows,
  ) async {
    final doc = await _ensurePdf();
    if (doc == null) return;
    final byPage = <int, List<Map<String, dynamic>>>{};
    for (final row in typeRows) {
      final rawPage = int.tryParse('${row['raw_page'] ?? ''}');
      final id = '${row['id'] ?? ''}'.trim();
      if (rawPage == null || rawPage <= 0 || id.isEmpty) continue;
      byPage.putIfAbsent(rawPage, () => <Map<String, dynamic>>[]).add(row);
    }
    if (byPage.isEmpty) return;

    final state = _ensureSubState(focus);
    setState(() {
      state.phase = '필수유형 본문 정답·풀이 추출 중...';
    });
    final answers = <TextbookAnswerUpload>[];
    final refs = <TextbookSolutionRefUpload>[];
    var failedPages = 0;
    try {
      final pages = byPage.keys.toList()..sort();
      for (final rawPage in pages) {
        if (mounted) {
          setState(() {
            state.phase = '필수유형 본문 정답·풀이 추출 중... p$rawPage';
          });
        }
        try {
          final png = await renderPdfPageToPng(
            document: doc,
            pageNumber: rawPage,
            longEdgePx: _kAnalysisLongEdgePx,
          );
          final rowsOnPage = byPage[rawPage]!;
          final result = await _solRefService.extractBodySolutionsOnPage(
            imageBytes: png,
            rawPage: rawPage,
            expectedNumbers: [
              for (final r in rowsOnPage) '${r['problem_number'] ?? ''}'.trim(),
            ],
          );
          final idByNumberKey = <String, String>{
            for (final r in rowsOnPage)
              textbookAnswerNumberKey('${r['problem_number'] ?? ''}'):
                  '${r['id']}'.trim(),
          };
          final displayPage = int.tryParse(
            '${rowsOnPage.first['display_page'] ?? ''}',
          );
          for (final item in result.items) {
            final cropId =
                idByNumberKey[textbookAnswerNumberKey(item.problemNumber)];
            if (cropId == null || cropId.isEmpty) continue;
            if (item.answerText.isNotEmpty || item.answerLatex2d.isNotEmpty) {
              answers.add(TextbookAnswerUpload(
                cropId: cropId,
                answerKind: item.answerKind,
                answerText: item.answerText,
                answerLatex2d:
                    item.answerLatex2d.isEmpty ? null : item.answerLatex2d,
              ));
            }
            refs.add(TextbookSolutionRefUpload(
              cropId: cropId,
              rawPage: rawPage,
              displayPage: displayPage,
              numberRegion1k: item.numberRegion1k,
              contentRegion1k: item.contentRegion1k,
              sourceKind: 'body',
            ));
          }
        } catch (e) {
          failedPages += 1;
          debugPrint('[wonri-body-chain] page $rawPage failed: $e');
        }
      }
      var answerCount = 0;
      var refCount = 0;
      if (answers.isNotEmpty) {
        answerCount = await _answerService.batchUpsertAnswers(
          academyId: widget.academyId,
          answers: answers,
        );
      }
      if (refs.isNotEmpty) {
        refCount = await _solRefService.batchUpsertSolutionRefs(
          academyId: widget.academyId,
          refs: refs,
        );
      }
      if (!mounted) return;
      final failNote = failedPages > 0 ? ' · 실패 ${failedPages}p' : '';
      setState(() {
        state.phase = '필수유형 본문 추출 완료 · 정답 $answerCount · 풀이 $refCount$failNote';
      });
      _toast('필수유형 본문 정답 $answerCount건 · 풀이 좌표 $refCount건 저장$failNote');
      unawaited(_loadStageStatuses());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        state.phase = '필수유형 본문 추출 실패';
        state.error = '$e';
      });
      _toast('필수유형 본문 추출 실패: $e', error: true);
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
    final bigName = big.nameCtrl.text.trim().isEmpty
        ? '대${focus.bigIndex + 1}'
        : big.nameCtrl.text.trim();
    final midName = mid.nameCtrl.text.trim().isEmpty
        ? '중${focus.midIndex + 1}'
        : mid.nameCtrl.text.trim();
    if (_isWonriRowFocus(focus)) {
      final row = _wonriRowFor(focus);
      final rowName = row?.nameCtrl.text.trim() ?? '';
      return '$bigName/$midName/${rowName.isEmpty ? '소단원' : rowName}';
    }
    final sub = mid.subs.firstWhere(
      (s) => s.preset.key == focus.subKey,
      orElse: () => mid.subs.first,
    );
    return '$bigName/$midName/${sub.preset.displayName}';
  }

  Future<void> _startPdfOnlyExtractForFocus(
    _SubFocus focus, {
    int? displayStartOverride,
    int? displayEndOverride,
    bool forceNewJob = false,
    bool pageScoped = false,
  }) async {
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];

    // 개념원리 소단원 포커스: 문항추출 런은 sub_key(A~D) 단위이므로,
    // 이 소단원 범위로 업로드된 카테고리마다 하나씩 큐에 넣는다.
    if (_isWonriRowFocus(focus)) {
      final row = _wonriRowFor(focus);
      if (row == null) return;
      final displayStart =
          displayStartOverride ?? _positiveInt(row.startCtrl.text);
      final displayEnd = displayEndOverride ?? _positiveInt(row.endCtrl.text);
      final state = _subStates[_stateKeyFor(focus)];
      final uploadedSubKeys = <String>{
        for (final r in state?.uploadResult?.rows ?? const [])
          '${r['sub_key'] ?? ''}'.trim().toUpperCase(),
      }..removeWhere((k) => !['A', 'B', 'C', 'D'].contains(k));
      if (uploadedSubKeys.isEmpty) return;
      // 필수유형(B)은 소단원별로 별도 추출 런/문서를 만든다 (번호가 소단원마다
      // 새로 시작). 나머지 카테고리는 중단원 연속이라 sub_index=0.
      final wonriIndex = _wonriRowIndex(focus) ?? 0;
      for (final subKey in uploadedSubKeys.toList()..sort()) {
        await _pbService.createTextbookPdfOnlyExtractRun(
          academyId: widget.academyId,
          bookId: widget.bookId,
          bookName: widget.bookName,
          gradeLabel: widget.gradeLabel,
          bigOrder: focus.bigIndex,
          midOrder: focus.midIndex,
          subKey: subKey,
          subIndex: subKey == 'B' ? wonriIndex : 0,
          seriesKey: _seriesKey,
          bigName: big.nameCtrl.text.trim(),
          midName: mid.nameCtrl.text.trim(),
          subName: _kWonriCategoryShortNames[_kWonriCategoryBySubKey[subKey]] ??
              subKey,
          rawPageFrom: displayStart == null
              ? null
              : _rawPageForDisplayPage(displayStart),
          rawPageTo:
              displayEnd == null ? null : _rawPageForDisplayPage(displayEnd),
          displayPageFrom: displayStart,
          displayPageTo: displayEnd,
          bodyLinkId: widget.linkId,
          forceNewJob: forceNewJob,
          pageScoped: pageScoped,
        );
        if (!mounted) return;
        setState(() {
          _pbExtractStatusBySub[_stateKeyFor(_SubFocus(
            bigIndex: focus.bigIndex,
            midIndex: focus.midIndex,
            subKey: subKey,
          ))] = 'queued';
        });
      }
      return;
    }

    final sub = mid.subs.firstWhere(
      (s) => s.preset.key == focus.subKey,
      orElse: () => mid.subs.first,
    );
    final displayStart =
        displayStartOverride ?? _positiveInt(sub.startCtrl.text);
    final displayEnd = displayEndOverride ?? _positiveInt(sub.endCtrl.text);
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
      seriesKey: _seriesKey,
      bigName: big.nameCtrl.text.trim(),
      midName: mid.nameCtrl.text.trim(),
      subName: sub.preset.displayName,
      rawPageFrom: rawStart,
      rawPageTo: rawEnd,
      displayPageFrom: displayStart,
      displayPageTo: displayEnd,
      bodyLinkId: widget.linkId,
      forceNewJob: forceNewJob,
      pageScoped: pageScoped,
    );
    if (!mounted) return;
    setState(() {
      _pbExtractStatusBySub[_stateKeyFor(focus)] = 'queued';
    });
  }

  Future<void> _promptAndStartProblemExtraction(_SubFocus focus) async {
    final (focusStart, focusEnd) = _focusRange(focus);
    final startCtrl =
        TextEditingController(text: focusStart == null ? '' : '$focusStart');
    final endCtrl =
        TextEditingController(text: focusEnd == null ? '' : '$focusEnd');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: _kPanel,
          title: const Text(
            '문항추출 실행',
            style: TextStyle(color: _kText, fontWeight: FontWeight.w800),
          ),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '저장된 크롭 정보를 기준으로 문제은행 문항추출을 큐에 넣습니다. 특정 페이지만 다시 추출하려면 범위를 조정하세요.',
                  style: TextStyle(color: _kTextSub, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _textInput(
                        startCtrl,
                        hint: '시작 페이지',
                        dense: true,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _textInput(
                        endCtrl,
                        hint: '끝 페이지',
                        dense: true,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(backgroundColor: _kAccent),
              child: const Text('실행'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    final displayStart = _positiveInt(startCtrl.text);
    final displayEnd = _positiveInt(endCtrl.text);
    if (displayStart == null ||
        displayEnd == null ||
        displayEnd < displayStart) {
      _toast('문항추출 페이지 범위를 확인하세요', error: true);
      return;
    }
    try {
      await _startPdfOnlyExtractForFocus(
        focus,
        displayStartOverride: displayStart,
        displayEndOverride: displayEnd,
        forceNewJob: true,
        pageScoped: true,
      );
      _toast('${_subFocusLabel(focus)} 문항추출을 큐에 넣었습니다');
      unawaited(_loadPbExtractRuns());
    } catch (e) {
      _toast('문항추출 시작 실패: $e', error: true);
    }
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
    final scopeKeys = <String>{};
    for (final focus in targets) {
      final state = _ensureSubState(focus);
      final seeds = _buildStageCropSeeds(focus, state);
      if (seeds.isEmpty) {
        _toast('${_subFocusLabel(focus)} 저장 문항이 없습니다', error: true);
        return;
      }
      allSeeds.addAll(seeds);
      if (_isWonriRowFocus(focus)) {
        // 개념원리: 소단원 하나가 카테고리 스코프(A/C/D) 여러 개로 전개된다.
        // 필수유형(B)은 본문 체이닝으로 정답·풀이가 이미 저장돼 제외.
        for (final scope in _wonriStageScopesFor(focus)) {
          // A/C/D는 sub_key를 중단원 전체가 공유한다. 실제 소단원 행까지
          // 포함해야 뒤 소단원의 정답·해설 범위가 중복으로 버려지지 않는다.
          final key = '${scope.bigOrder}/${scope.midOrder}/${scope.subKey}/'
              '${scope.unitRowIndex ?? -1}/'
              '${scope.bodyStartPage ?? 0}-${scope.bodyEndPage ?? 0}';
          if (scopeKeys.add(key)) scopes.add(scope);
        }
      } else {
        final scope = _stageScopeFor(focus);
        final key = '${scope.bigOrder}/${scope.midOrder}/${scope.subKey}';
        if (scopeKeys.add(key)) scopes.add(scope);
      }
      if (_runProblemExtractionAfterStage1) {
        unawaited(_startPdfOnlyExtractForFocus(focus).catchError((Object e) {
          debugPrint('[textbook-pb-extract] start failed: $e');
        }));
      }
    }
    if (scopes.isEmpty) {
      _toast('정답·해설 단계로 보낼 카테고리가 없습니다 (필수유형은 본문에서 자동 추출됨)');
      return;
    }
    final first = targets.first;
    final big = _bigUnits[first.bigIndex];
    final mid = big.middles[first.midIndex];
    setState(() {
      _embeddedStage = _EmbeddedStageArgs(
        bigOrder: first.bigIndex,
        midOrder: first.midIndex,
        subKey: scopes.first.subKey,
        bigName: big.nameCtrl.text.trim(),
        midName: mid.nameCtrl.text.trim(),
        initialCrops: allSeeds,
        batchScopes:
            scopes.length > 1 ? scopes : const <TextbookAuthoringStageScope>[],
        answerStartPage: scopes.first.answerStartPage,
        answerEndPage: scopes.first.answerEndPage,
        solutionStartPage: scopes.first.solutionStartPage,
        solutionEndPage: scopes.first.solutionEndPage,
      );
    });
  }

  /// 개념원리 소단원 포커스 → 정답·해설 단계 스코프 목록.
  /// 업로드된 카테고리 중 A(익히기)/C(확인체크)/D(연습문제)만 전개하고,
  /// 정답·해설 시작 페이지는 **소단원 행**에서 입력한 하나의 값을 공유한다
  /// (쎈은 소단원=A/B/C 이지만 개념서는 소단원 안에 카테고리가 섞여 있어
  /// 소단원 단위로 한 번만 입력받는다). B(필수유형)는 본문 '풀이' 체이닝으로
  /// 정답·풀이가 저장돼 답지/해설 단계가 필요 없다.
  List<TextbookAuthoringStageScope> _wonriStageScopesFor(_SubFocus focus) {
    final state = _subStates[_stateKeyFor(focus)];
    final present = <String>{
      for (final r in state?.uploadResult?.rows ?? const [])
        '${r['sub_key'] ?? ''}'.trim().toUpperCase(),
    };
    final row = _wonriRowFor(focus);
    if (row == null) return const <TextbookAuthoringStageScope>[];
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final rowName = row.nameCtrl.text.trim().isEmpty
        ? (row.isExercise ? '연습문제' : '소단원')
        : row.nameCtrl.text.trim();
    final answerStart = _positiveInt(row.answerStartCtrl.text);
    final solutionStart = _positiveInt(row.solutionStartCtrl.text);
    final answerEnd = _wonriNextRowStageStart(focus, answer: true);
    final solutionEnd = _wonriNextRowStageStart(focus, answer: false);
    final rowIndex = _wonriRowIndex(focus);
    final bodyStart = _positiveInt(row.startCtrl.text);
    final bodyEnd = _positiveInt(row.endCtrl.text);
    return [
      for (final subKey in const ['A', 'C', 'D'])
        if (present.contains(subKey))
          TextbookAuthoringStageScope(
            bigOrder: focus.bigIndex,
            midOrder: focus.midIndex,
            subKey: subKey,
            bigName: big.nameCtrl.text.trim(),
            midName: mid.nameCtrl.text.trim(),
            subName:
                '$rowName · ${_kWonriCategoryShortNames[_kWonriCategoryBySubKey[subKey]] ?? subKey}',
            unitRowIndex: rowIndex,
            bodyStartPage: bodyStart,
            bodyEndPage: bodyEnd,
            answerStartPage: answerStart,
            answerEndPage: answerEnd,
            solutionStartPage: solutionStart,
            solutionEndPage: solutionEnd,
          ),
    ];
  }

  /// 개념원리 — 이 소단원 행 다음에 정답/해설 시작 페이지가 입력된 소단원
  /// 행의 시작 페이지. 정답·해설 스캔 끝 페이지 유도에 쓴다.
  int? _wonriNextRowStageStart(_SubFocus focus, {required bool answer}) {
    final wonriIndex = _wonriRowIndex(focus);
    if (wonriIndex == null) return null;
    var passed = false;
    for (var b = 0; b < _bigUnits.length; b += 1) {
      for (var m = 0; m < _bigUnits[b].middles.length; m += 1) {
        final rows = _bigUnits[b].middles[m].subUnitRows;
        for (var i = 0; i < rows.length; i += 1) {
          final isCurrent =
              b == focus.bigIndex && m == focus.midIndex && i == wonriIndex;
          if (isCurrent) {
            passed = true;
            continue;
          }
          if (!passed) continue;
          final page = _positiveInt(answer
              ? rows[i].answerStartCtrl.text
              : rows[i].solutionStartCtrl.text);
          if (page != null) return page;
        }
      }
    }
    return null;
  }

  int? _wonriRowIndex(_SubFocus focus) {
    if (!_isWonriRowFocus(focus)) return null;
    final idx = int.tryParse(focus.subKey.substring(1));
    return idx;
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
      answerStartPage: _positiveInt(sub.answerStartCtrl.text),
      answerEndPage: _stageEndPageFor(focus, answer: true),
      solutionStartPage: _positiveInt(sub.solutionStartCtrl.text),
      solutionEndPage: _stageEndPageFor(focus, answer: false),
    );
  }

  int? _stageEndPageFor(_SubFocus focus, {required bool answer}) {
    final nextStart = _nextStageStartPageAfter(focus, answer: answer);
    if (nextStart == null || nextStart <= 1) return null;
    // 마지막 문제가 다음 단원 시작 페이지와 섞여 있는 교재가 있어
    // 다음 단원 첫 페이지까지 포함해 스캔한다.
    return nextStart;
  }

  int? _nextStageStartPageAfter(_SubFocus focus, {required bool answer}) {
    var passed = false;
    for (var b = 0; b < _bigUnits.length; b += 1) {
      final big = _bigUnits[b];
      for (var m = 0; m < big.middles.length; m += 1) {
        final mid = big.middles[m];
        for (final sub in mid.subs) {
          final isCurrent = b == focus.bigIndex &&
              m == focus.midIndex &&
              sub.preset.key == focus.subKey;
          if (isCurrent) {
            passed = true;
            continue;
          }
          if (!passed) continue;
          final page = _positiveInt(
            answer ? sub.answerStartCtrl.text : sub.solutionStartCtrl.text,
          );
          if (page != null) return page;
        }
      }
    }
    return null;
  }

  List<TextbookAuthoringStageCropSeed> _buildStageCropSeeds(
    _SubFocus focus,
    _SubRunState state,
  ) {
    final uploadRows =
        state.uploadResult?.rows ?? const <Map<String, dynamic>>[];
    if (uploadRows.isEmpty) return const <TextbookAuthoringStageCropSeed>[];
    if (_isWonriRowFocus(focus)) {
      return _buildWonriStageCropSeeds(focus, state, uploadRows);
    }
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

  /// 개념원리 소단원 포커스용 시드 — 문항 번호가 카테고리마다 1부터 다시
  /// 시작하므로 `sub_key|번호` 복합 키로 업로드 행과 매칭한다.
  /// 필수유형(B)은 본문 체이닝으로 정답·풀이가 끝나 시드에서 제외한다.
  List<TextbookAuthoringStageCropSeed> _buildWonriStageCropSeeds(
    _SubFocus focus,
    _SubRunState state,
    List<Map<String, dynamic>> uploadRows,
  ) {
    final mid = _bigUnits[focus.bigIndex].middles[focus.midIndex];
    final midName = mid.nameCtrl.text.trim().isEmpty
        ? '중${focus.midIndex + 1}'
        : mid.nameCtrl.text.trim();
    final idByKey = <String, String>{};
    for (final row in uploadRows) {
      final id = '${row['id'] ?? ''}'.trim();
      final number = '${row['problem_number'] ?? ''}'.trim();
      final subKey = '${row['sub_key'] ?? ''}'.trim().toUpperCase();
      if (id.isNotEmpty && number.isNotEmpty && subKey.isNotEmpty) {
        idByKey['$subKey|$number'] = id;
      }
    }
    if (idByKey.isEmpty) return const <TextbookAuthoringStageCropSeed>[];

    final seeds = <TextbookAuthoringStageCropSeed>[];
    final pageRows = state.pageResults.where((r) => r.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    for (final row in pageRows) {
      for (final item in row.items) {
        final category = _wonriCategoryOfItem(item, row.section);
        if (category.isEmpty || category == 'type_example') continue;
        final subKey = _kWonriSubKeyByCategory[category]!;
        final id = idByKey['$subKey|${item.number}'];
        if (id == null) continue;
        seeds.add(TextbookAuthoringStageCropSeed(
          id: id,
          problemNumber: item.number,
          rawPage: row.rawPage,
          displayPage: row.displayPage,
          section: category,
          isSetHeader: item.isSetHeader,
          scopeLabel:
              '$midName/${_kWonriCategoryShortNames[category] ?? category}',
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
                  answerStartPage: _embeddedStage!.answerStartPage,
                  answerEndPage: _embeddedStage!.answerEndPage,
                  solutionStartPage: _embeddedStage!.solutionStartPage,
                  solutionEndPage: _embeddedStage!.solutionEndPage,
                  seriesKey: _seriesKey,
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 10),
            child: Row(
              children: [
                Expanded(child: _buildSeriesDropdown()),
                const SizedBox(width: 8),
                Tooltip(
                  message: '본문 PDF의 목차(차례) 페이지를 VLM 으로 읽어 단원 이름과 '
                      '페이지 범위를 자동으로 채웁니다.\n적용 후 "단원 구조 저장"을 '
                      '눌러야 반영됩니다.',
                  child: OutlinedButton.icon(
                    onPressed: _tocParsing ? null : _runTocAutoParse,
                    icon: _tocParsing
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _kTextSub,
                            ),
                          )
                        : const Icon(Icons.auto_awesome,
                            size: 14, color: _kTextSub),
                    label: const Text(
                      '목차 자동 인식',
                      style: TextStyle(color: _kTextSub, fontSize: 11),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: _kBorder),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_tocStatus?.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
              child: Text(
                _tocStatus!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _tocStatus!.startsWith('실패') ? _kDanger : _kTextSub,
                  fontSize: 11,
                ),
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

  /// 교재 시리즈 선택. 위저드를 거치지 않고(신규행 추가 등) 만들어진 책은
  /// payload 에 series 가 없어 기본값(쎈)으로 열리므로, 여기서 바꿔서
  /// "단원 구조 저장"으로 함께 저장할 수 있게 한다.
  Widget _buildSeriesDropdown() {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: textbookSeriesByKey(_seriesKey) == null
              ? kTextbookSeriesCatalog.first.key
              : _seriesKey,
          dropdownColor: _kCard,
          isExpanded: true,
          isDense: true,
          style: const TextStyle(color: _kText, fontSize: 12),
          items: [
            for (final entry in kTextbookSeriesCatalog)
              DropdownMenuItem<String>(
                value: entry.key,
                child: Text('시리즈: ${entry.displayName}'),
              ),
          ],
          onChanged: _tocParsing
              ? null
              : (value) {
                  if (value == null || value == _seriesKey) return;
                  setState(() {
                    _seriesKey = value;
                    final entry = _currentSeries();
                    // 새 시리즈의 A~D 슬롯 프리셋으로 재구성한다.
                    // (같은 키의 슬롯에 입력된 페이지는 유지)
                    for (final big in _bigUnits) {
                      for (final mid in big.middles) {
                        mid.applyPreset(entry);
                      }
                    }
                    _focus = null;
                    _selectedProblemKey = null;
                  });
                },
        ),
      ),
    );
  }

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
          if (_seriesKey == 'wonri') ...[
            // 개념원리: 트리에는 책의 실제 소단원 행만 보인다.
            // 분석 단위도 소단원 행이다 — 행을 누르면 그 페이지 범위를
            // 단일 패스로 분석하고, 문항은 카테고리(A~D)별로 자동 분류된다.
            for (var s = 0; s < mid.subUnitRows.length; s += 1)
              _buildSubUnitRow(bigIndex, midIndex, mid, s),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () =>
                      setState(() => mid.subUnitRows.add(_SubUnitRowEdit())),
                  icon: const Icon(Icons.add, size: 13, color: _kTextSub),
                  label: const Text('소단원 추가',
                      style: TextStyle(color: _kTextSub, fontSize: 10)),
                ),
                TextButton.icon(
                  onPressed: () => setState(() => mid.subUnitRows
                      .add(_SubUnitRowEdit(name: '연습문제', isExercise: true))),
                  icon: const Icon(Icons.add_task, size: 13, color: _kTextSub),
                  label: const Text('연습문제 추가',
                      style: TextStyle(color: _kTextSub, fontSize: 10)),
                ),
              ],
            ),
          ] else ...[
            for (final sub in mid.subs) _buildSubRow(bigIndex, midIndex, sub),
          ],
        ],
      ),
    );
  }

  /// 개념원리 전용 — 책의 실제 소단원 한 행 (이름 + 시작/끝 페이지 + 삭제).
  /// 행을 누르면 이 소단원 페이지 범위가 분석 패널의 작업 단위가 된다.
  /// 페이지를 고치면 A~D 카테고리 슬롯 범위가 자동으로 다시 계산된다.
  Widget _buildSubUnitRow(
    int bigIndex,
    int midIndex,
    _MidUnitEdit mid,
    int index,
  ) {
    final row = mid.subUnitRows[index];
    final focus = _SubFocus(
      bigIndex: bigIndex,
      midIndex: midIndex,
      subKey: 'W$index',
    );
    final key = _stateKeyFor(focus);
    final selected = _focus != null && _stateKeyFor(_focus!) == key;
    final batchSelected = _batchSelection.contains(key);
    final state = _subStates[key];
    final analyzed = state == null
        ? 0
        : state.pageResults.where((r) => r.ok).fold<int>(
              0,
              (sum, r) =>
                  sum +
                  r.items
                      .where((it) => (it.itemRegion?.length ?? 0) == 4)
                      .length,
            );
    final uploaded = state?.uploadResult?.upserted ?? 0;
    final isRunning = state?.running == true || state?.uploading == true;
    // 정답·해설 진행 배지는 중단원의 카테고리(A/C/D/B) 상태를 합쳐 보여준다
    // (개념원리는 카테고리 단위로 저장되므로 소단원 행은 그 합계를 반영).
    final stageStatus = _wonriRowStageStatus(focus);
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
                  width: 44,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
                  decoration: BoxDecoration(
                    color: row.isExercise
                        ? const Color(0xFF241A1E)
                        : const Color(0xFF16211B),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    row.isExercise ? '연습' : '소단원',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: row.isExercise
                          ? const Color(0xFFE68AA9)
                          : const Color(0xFF8FD0AE),
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  flex: 3,
                  child: _textInput(
                    row.nameCtrl,
                    hint: row.isExercise ? '연습문제' : '소단원 이름',
                    dense: true,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 2,
                  child: _StageProgressChip(
                    status: stageStatus,
                    loading: _loadingStageStatuses,
                    onTap: () => _showStageStatusDialog(focus),
                  ),
                ),
                IconButton(
                  tooltip: '소단원 삭제',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() {
                    mid.subUnitRows.removeAt(index).dispose();
                    _recalcWonriSlotPages(mid);
                    // 행 삭제로 W 인덱스가 밀리므로 이 중단원의 소단원 상태는
                    // 통째로 버린다 (저장된 영역은 DB에 남아 재복원 가능).
                    final prefix = '$bigIndex/$midIndex/W';
                    _subStates.removeWhere((k, _) => k.startsWith(prefix));
                    _manualEdits.removeWhere((k, _) => k.startsWith(prefix));
                    _batchSelection.removeWhere((k) => k.startsWith(prefix));
                    if (_focus != null &&
                        _focus!.bigIndex == bigIndex &&
                        _focus!.midIndex == midIndex &&
                        _focus!.subKey.startsWith('W')) {
                      _focus = null;
                    }
                  }),
                  icon: const Icon(Icons.close, size: 12, color: _kTextSub),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const SizedBox(width: 38),
                Expanded(
                  child: _textInput(
                    row.startCtrl,
                    hint: '시작',
                    dense: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: () => _recalcWonriSlotPages(mid),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: _textInput(
                    row.endCtrl,
                    hint: '끝',
                    dense: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: () => _recalcWonriSlotPages(mid),
                  ),
                ),
                const SizedBox(width: 6),
                _SubRowStats(
                  analyzed: analyzed,
                  uploaded: uploaded,
                  running: isRunning,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const SizedBox(width: 38),
                Expanded(
                  child: _textInput(
                    row.answerStartCtrl,
                    hint: '정답 시작',
                    dense: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: _textInput(
                    row.solutionStartCtrl,
                    hint: '해설 시작',
                    dense: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
                const SizedBox(width: 58),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 개념원리 소단원 행의 정답·해설 진행 배지용 합계 상태.
  /// 카테고리(A/B/C/D)별 스테이지 상태를 합쳐 하나로 만든다. 없으면 null.
  TextbookStageScopeStatus? _wonriRowStageStatus(_SubFocus focus) {
    var found = false;
    var bd = 0, bt = 0, ad = 0, at = 0, sd = 0, st = 0;
    for (final k in const ['A', 'B', 'C', 'D']) {
      final s = _stageStatusBySub[_stateKeyFor(_SubFocus(
        bigIndex: focus.bigIndex,
        midIndex: focus.midIndex,
        subKey: k,
      ))];
      if (s == null) continue;
      found = true;
      bd += s.bodyDone;
      bt += s.bodyTotal;
      ad += s.answerDone;
      at += s.answerTotal;
      sd += s.solutionDone;
      st += s.solutionTotal;
    }
    if (!found) return null;
    return TextbookStageScopeStatus(
      bigOrder: focus.bigIndex,
      midOrder: focus.midIndex,
      subKey: 'W',
      bodyDone: bd,
      bodyTotal: bt,
      answerDone: ad,
      answerTotal: at,
      solutionDone: sd,
      solutionTotal: st,
    );
  }

  // 쎈/RPM 전용 — 개념원리(wonri)는 트리에 카테고리 행을 그리지 않는다
  // (분석 패널의 카테고리 칩으로 대체).
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
            const SizedBox(height: 4),
            Row(
              children: [
                const SizedBox(width: 38),
                Expanded(
                  child: _textInput(
                    sub.answerStartCtrl,
                    hint: '정답 시작',
                    dense: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: _textInput(
                    sub.solutionStartCtrl,
                    hint: '해설 시작',
                    dense: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
                const SizedBox(width: 82),
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
    final status = _isWonriRowFocus(focus)
        ? _wonriRowStageStatus(focus)
        : _stageStatusBySub[_stateKeyFor(focus)];
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
        // 개념원리: 카테고리(A~D) 크롭 삭제는 소단원(W) 작업 상태에도
        // 반영돼야 하므로 이 중단원의 W 상태를 모두 비운다.
        if (_seriesKey == 'wonri') {
          final prefix = '${focus.bigIndex}/${focus.midIndex}/W';
          _subStates.removeWhere((k, _) => k.startsWith(prefix));
          _manualEdits.removeWhere((k, _) => k.startsWith(prefix));
        }
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
    final (start, _) = _focusRange(focus);
    if (start == null) return;
    if (!_viewerController.isReady) return;
    final pageCount = _bodyDocument?.pages.length ?? 0;
    if (pageCount <= 0) return;
    final targetPage = _rawPageForDisplayPage(start).clamp(1, pageCount);
    try {
      _viewerController.goToPage(pageNumber: targetPage);
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
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _seriesKey == 'wonri'
                ? '왼쪽에서 소단원 행을 선택하면 분석 패널이 열립니다.\n'
                    '분석 한 번으로 익히기·필수유형·확인체크·연습문제가 자동 분류됩니다.'
                : '왼쪽에서 소단원(A/B/C)을 선택하면 분석 패널이 열립니다.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _kTextSub, fontSize: 13),
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
    final wonriRow = _wonriRowFor(focus);
    final focusName = wonriRow != null
        ? (wonriRow.nameCtrl.text.trim().isEmpty
            ? (wonriRow.isExercise ? '연습문제' : '소단원')
            : wonriRow.nameCtrl.text.trim())
        : sub.preset.displayName;

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
                  '› $focusName',
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
        // 개념원리: 소단원 페이지를 한 번만 분석하면 문항이 개념원리 익히기 /
        // 필수유형 / 확인 체크 / 연습문제로 자동 분류돼 문항이름으로 저장된다.
        // 정답·해설 시작 페이지는 왼쪽 소단원 행에서 입력한다 (쎈과 동일).
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
                _ProblemExtractCheckbox(
                  value: _runProblemExtractionAfterStage1,
                  enabled: !_batchRunning,
                  onChanged: (value) {
                    setState(() {
                      _runProblemExtractionAfterStage1 = value;
                    });
                  },
                ),
                const SizedBox(width: 10),
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
    final (start, end) = _focusRange(focus);
    final readyRange = start != null && end != null && end >= start;
    final hasFailures =
        (state.progress?.failedPages ?? const <int>{}).isNotEmpty;
    final totalRegions = _totalRegionsFor(state, focus);
    final edits = _manualEdits[_stateKeyFor(focus)];
    final manualCount = edits?.length ?? 0;
    final selectedCount = _selectedBatchFocuses().length;
    final runSelection = selectedCount > 0;
    final canRunAnalysis = runSelection ? !_batchRunning : readyRange;
    // 개념원리 W 포커스는 DB 스테이지 상태가 카테고리(A~D) 키로 잡혀 있어
    // 이 소단원의 업로드 결과 행 수로 대신 판단한다.
    final savedCropCount = _isWonriRowFocus(focus)
        ? (state.uploadResult?.rows.length ?? 0)
        : _stageStatusBySub[_stateKeyFor(focus)]?.bodyDone ?? 0;
    final canRunProblemExtract = savedCropCount > 0 &&
        !state.running &&
        !state.uploading &&
        !_batchRunning;
    final pbStatus = _pbExtractStatusBySub[_stateKeyFor(focus)] ?? '';
    final problemExtractLabel =
        pbStatus == 'completed' || pbStatus == 'review_required'
            ? '문항 재추출'
            : '문항추출';

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
          _ProblemExtractCheckbox(
            value: _runProblemExtractionAfterStage1,
            enabled: !state.running && !state.uploading && !_batchRunning,
            onChanged: (value) {
              setState(() {
                _runProblemExtractionAfterStage1 = value;
              });
            },
          ),
          const SizedBox(width: 6),
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
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: canRunProblemExtract
                  ? () => _promptAndStartProblemExtraction(focus)
                  : null,
              icon: const Icon(Icons.auto_awesome, size: 14, color: _kInfo),
              label: Text(
                problemExtractLabel,
                style: const TextStyle(color: _kInfo, fontSize: 12),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF2A3E5A)),
              ),
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
                ' · 현재 PDF ${progress.cursor}p',
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
        return <Widget>[
          Positioned(
            left: 12,
            top: 12,
            child: _ConceptPageMarker(
              text: row.wasAutoGuarded ? '자동 제외 · 개념 페이지' : '개념 페이지',
            ),
          ),
        ];
      }
      return const <Widget>[];
    }
    final pageSize = pageRect.size;
    final widgets = <Widget>[];
    if (row.wasAutoGuarded) {
      widgets.add(const Positioned(
        left: 12,
        top: 12,
        child: _AutoGuardMarker(),
      ));
    }
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
      final effectiveGroup = _effectiveContentGroupForItem(
        focus: focus,
        state: state,
        rawPage: pageNumber,
        itemIndex: i,
      );
      widgets.add(_NumberBadge(
        rect: rect,
        item: item,
        groupLabelOverride:
            effectiveGroup.kind == 'type' ? effectiveGroup.label : null,
        groupTitleOverride:
            effectiveGroup.kind == 'type' ? effectiveGroup.title : null,
        // 개념서는 난이도가 없으므로 뱃지에 문항이름을 표시한다.
        labelOverride: _seriesKey == 'wonri'
            ? _wonriItemName(_wonriCategoryOfItem(item, ''), item.label)
            : null,
      ));
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
    VoidCallback? onChanged,
    bool enabled = true,
  }) {
    return TextField(
      controller: controller,
      enabled: enabled,
      onChanged: (_) => setState(() {
        onChanged?.call();
      }),
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
  const _ConceptPageMarker({this.text = '개념 페이지'});

  final String text;

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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.lightbulb_outline,
              size: 13,
              color: Color(0xFFE6C07A),
            ),
            const SizedBox(width: 5),
            Text(
              text,
              style: const TextStyle(
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

class _AutoGuardMarker extends StatelessWidget {
  const _AutoGuardMarker();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF3A2F18).withValues(alpha: 0.92),
          border: Border.all(color: const Color(0xFFEAB968)),
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
            Icon(Icons.rule, size: 13, color: Color(0xFFEAB968)),
            SizedBox(width: 5),
            Text(
              'A 오인식 후보 자동 제외',
              style: TextStyle(
                color: Color(0xFFEAB968),
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
  const _NumberBadge(
      {required this.rect,
      required this.item,
      this.labelOverride,
      this.groupLabelOverride,
      this.groupTitleOverride});
  final Rect rect;
  final TextbookVlmItem item;

  /// 개념서 문항이름처럼 난이도(label) 대신 표시할 라벨. null 이면 item.label 사용.
  final String? labelOverride;
  final String? groupLabelOverride;
  final String? groupTitleOverride;

  @override
  Widget build(BuildContext context) {
    final color =
        item.isSetHeader ? const Color(0xFFFFB44A) : const Color(0xFFFF4D4F);
    final groupLabel =
        (groupLabelOverride ?? item.contentGroupLabel).trim();
    // 필수유형 유형명(content_group_title). 확인용으로 뱃지에 함께 표시한다.
    final groupTitle =
        (groupTitleOverride ?? item.contentGroupTitle).trim();
    final badgeLabel = labelOverride ?? item.label;
    final numberLabel =
        badgeLabel.isEmpty ? item.number : '${item.number} · $badgeLabel';
    final groupText = groupLabel.isEmpty
        ? groupTitle
        : (groupTitle.isEmpty ? groupLabel : '$groupLabel $groupTitle');
    final text = groupText.isEmpty ? numberLabel : '$groupText · $numberLabel';
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

class _ProblemExtractCheckbox extends StatelessWidget {
  const _ProblemExtractCheckbox({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: value
          ? 'Stage 1 저장 후 문제은행 문항추출도 자동으로 큐에 넣습니다.'
          : '문항번호와 크롭만 저장하고 문제은행 문항추출은 나중에 실행합니다.',
      child: InkWell(
        onTap: enabled ? () => onChanged(!value) : null,
        borderRadius: BorderRadius.circular(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: value,
              onChanged: enabled ? (v) => onChanged(v == true) : null,
              visualDensity: VisualDensity.compact,
              side: const BorderSide(color: Color(0xFFB3B3B3)),
            ),
            const Text(
              '문항추출',
              style: TextStyle(
                color: Color(0xFFB3B3B3),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
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
              child: FittedBox(
                fit: BoxFit.scaleDown,
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
    this.answerStartPage,
    this.answerEndPage,
    this.solutionStartPage,
    this.solutionEndPage,
  });

  final int bigOrder;
  final int midOrder;
  final String subKey;
  final String bigName;
  final String midName;
  final List<TextbookAuthoringStageCropSeed> initialCrops;
  final List<TextbookAuthoringStageScope> batchScopes;
  final int? answerStartPage;
  final int? answerEndPage;
  final int? solutionStartPage;
  final int? solutionEndPage;
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
    this.conceptDrillHeaderVisible = false,
    this.notes = '',
    List<TextbookVlmItem>? items,
  }) : items = items ?? const <TextbookVlmItem>[];

  factory _PageAnalysisRow.success({
    required int rawPage,
    required int displayPage,
    required String section,
    required String pageKind,
    bool conceptDrillHeaderVisible = false,
    required String notes,
    required List<TextbookVlmItem> items,
  }) {
    return _PageAnalysisRow(
      rawPage: rawPage,
      ok: true,
      displayPage: displayPage,
      section: section,
      pageKind: pageKind,
      conceptDrillHeaderVisible: conceptDrillHeaderVisible,
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
  final bool conceptDrillHeaderVisible;
  final String notes;
  final List<TextbookVlmItem> items;

  bool get isConceptPage =>
      ok &&
      items.isEmpty &&
      (pageKind == 'concept_page' ||
          notes.toLowerCase().contains('concept_page'));

  bool get wasAutoGuarded {
    final lower = notes.toLowerCase();
    return lower.contains('auto_guarded') ||
        lower.contains('basic_drill_candidate_filtered') ||
        lower.contains('basic_drill_sequence_filtered') ||
        lower.contains('basic_drill_start_page_filtered') ||
        lower.contains('wonri_before_concept_drill_header_filtered') ||
        lower.contains('basic_drill_expected_start_missing') ||
        lower.contains('basic_drill_expected_start_mismatch');
  }
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

  /// 개념서(개념원리)의 실제 소단원 행들 — 책의 소단원/연습문제 이름과
  /// 페이지 범위를 이 단위로 편집하고, A~D 문제 카테고리 슬롯의 페이지는
  /// 여기서 자동 유도된다 (A/B/C = 일반 소단원 전체 범위, D = 연습문제 범위).
  final List<_SubUnitRowEdit> subUnitRows = <_SubUnitRowEdit>[];

  /// 시리즈 변경 시 A~D 슬롯을 새 프리셋으로 재구성한다.
  /// 같은 키의 슬롯에 이미 입력된 페이지 텍스트는 유지한다.
  void applyPreset(TextbookSeriesCatalogEntry series) {
    final keyed = <String, _SubSectionEdit>{
      for (final s in subs) s.preset.key: s,
    };
    final rebuilt = <_SubSectionEdit>[];
    for (final preset in series.subPreset) {
      final existing = keyed.remove(preset.key);
      if (existing == null) {
        rebuilt.add(_SubSectionEdit(preset: preset));
        continue;
      }
      final next = _SubSectionEdit(preset: preset);
      next.startCtrl.text = existing.startCtrl.text;
      next.endCtrl.text = existing.endCtrl.text;
      next.answerStartCtrl.text = existing.answerStartCtrl.text;
      next.solutionStartCtrl.text = existing.solutionStartCtrl.text;
      existing.dispose();
      rebuilt.add(next);
    }
    for (final leftover in keyed.values) {
      leftover.dispose();
    }
    subs
      ..clear()
      ..addAll(rebuilt);
  }

  void dispose() {
    nameCtrl.dispose();
    for (final s in subs) {
      s.dispose();
    }
    for (final s in subUnitRows) {
      s.dispose();
    }
  }
}

/// 개념서(개념원리)의 소단원 한 행 — 이름 + 시작/끝 페이지.
/// "연습문제" 행은 STEP1/STEP2/실력UP이 있는 연습문제 페이지 범위다.
class _SubUnitRowEdit {
  _SubUnitRowEdit({String? name, this.isExercise = false}) {
    if (name != null) nameCtrl.text = name;
  }

  final TextEditingController nameCtrl = TextEditingController();
  final TextEditingController startCtrl = TextEditingController();
  final TextEditingController endCtrl = TextEditingController();
  // 정답/해설 시작 페이지는 소단원 단위로 사용자가 직접 입력한다 (쎈과 동일).
  // 소단원 안의 익히기·확인체크·연습문제 카테고리는 이 값을 공유한다.
  final TextEditingController answerStartCtrl = TextEditingController();
  final TextEditingController solutionStartCtrl = TextEditingController();
  final bool isExercise;

  void dispose() {
    nameCtrl.dispose();
    startCtrl.dispose();
    endCtrl.dispose();
    answerStartCtrl.dispose();
    solutionStartCtrl.dispose();
  }
}

class _SubSectionEdit {
  _SubSectionEdit({required this.preset});
  final TextbookSubSectionPreset preset;
  final TextEditingController startCtrl = TextEditingController();
  final TextEditingController endCtrl = TextEditingController();
  final TextEditingController answerStartCtrl = TextEditingController();
  final TextEditingController solutionStartCtrl = TextEditingController();
  void dispose() {
    startCtrl.dispose();
    endCtrl.dispose();
    answerStartCtrl.dispose();
    solutionStartCtrl.dispose();
  }
}

int? _positiveInt(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  final n = int.tryParse(t);
  if (n == null || n <= 0) return null;
  return n;
}
