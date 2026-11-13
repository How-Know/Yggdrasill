import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/textbook_book_registry.dart';
import '../../services/textbook_problem_review_service.dart';
import '../../services/textbook_review_pipeline.dart';
import '../../services/textbook_review_solution_image_service.dart';
import '../../services/textbook_vlm_answer_service.dart';
import '../../services/textbook_vlm_solution_ref_service.dart';
import '../../services/textbook_workflow_runner.dart';
import '../../services/textbook_workflow_service.dart';
import '../problem_bank/widgets/problem_bank_question_card.dart';
import 'textbook_pincette_extract_dialog.dart';
import 'textbook_review_engine_hold_panel.dart';
import 'textbook_source_pdf_pane.dart';

// 학습앱 글래스 카드와 같은 역할 색. 화면 배경은 검정, 카드는 #1C1C1E, 안쪽 칸은 #2C2C2E.
const Color _kBg = Color(0xFF000000);
const Color _kPanelBg = Color(0xFF1C1C1E);
const Color _kFieldBg = Color(0xFF2C2C2E);
const Color _kBorder = Color(0x22FFFFFF);
const Color _kText = Color(0xFFEAF2F2);
const Color _kTextSub = Color(0xFF9FB3B3);
const Color _kTextMuted = Color(0xFF6E7E7E);
const double _kPanelRadius = 28;
const double _kInnerRadius = 18;
const Color _kAccent = Color(0xFF33A373);
const Color _kChipSelected = Color(0xFF1B6B63);
const Color _kBlue = Color(0xFF64B5F6);
const Color _kError = Color(0xFFE57373);
const Color _kWarn = Color(0xFFE0B35A);

/// 시각 요소가 없는 문항의 태그. 다른 태그와 함께 두지 않는다(Edge textbook_visual_tags.ts 와 같다).
const String kVisualTagNone = '없음';

const List<String> kStandardVisualTags = [
  kVisualTagNone,
  '수직선',
  '좌표평면',
  '일차함수(직선)',
  '이차함수(포물선)',
  '삼차·사차함수',
  '유리·무리함수',
  '지수·로그함수',
  '삼각함수',
  '각·평행선',
  '삼각형',
  '직각삼각형',
  '이등변·정삼각형',
  '사각형',
  '다각형',
  '원·부채꼴·접선',
  '합동·닮음',
  '입체도형·회전체',
  '전개도·겨냥도',
  '표(Table)',
  '조건상자(보기)',
  '통계그래프(히스토그램·상자그림)',
  '수형도·경로망',
];

const int _kRenderCheckChunkSize = 4;
const int _kRenderCheckParallel = 3;
const int _kFixChunkSize = 3;

/// 2단계 작업 화면이 다루는 중단원(크롭 확정한 소단원만 보인다)
class TextbookWorkflowScope {
  const TextbookWorkflowScope({
    required this.academyId,
    required this.bookId,
    required this.bookName,
    required this.gradeLabel,
    required this.bigOrder,
    required this.midOrder,
    this.initialScopeKey,
    this.legacySubunits = const [],
  });

  final String academyId;
  final String bookId;
  final String bookName;
  final String gradeLabel;
  final int bigOrder;
  final int midOrder;
  final String? initialScopeKey;

  /// 같은 중단원에서 예전에 본문만 뽑아 두고 아직 2단계에 들어오지 않은 소단원
  final List<TextbookLegacySubunit> legacySubunits;

  /// 러너 작업 키 앞부분(`textbookWorkflowKey` 와 같은 순서)
  String get keyPrefix => '$bookId|$gradeLabel|$bigOrder|$midOrder|';
}

/// 예전 원스톱으로 본문(+정답)만 뽑아 둔 소단원. 작업 화면 소단원 띠 끝에 따로 보인다.
class TextbookLegacySubunit {
  const TextbookLegacySubunit({
    required this.scopeKey,
    required this.label,
    required this.bodies,
    required this.crops,
    this.reviewed = 0,
  });

  final String scopeKey;
  final String label;
  final int bodies;
  final int crops;

  /// 본문이 붙은 문항 중 예전 문항 검수(정답·품질 승인)를 마친 수
  final int reviewed;
  bool get allReviewed => bodies > 0 && reviewed >= bodies;
}

/// 2·3단계 작업 화면: 크롭 확정한 소단원의 문항 카드(추출·검수 진행도, 준비됨)를 보고 손본 뒤 소단원을 확정한다.
/// 기존 추출 소단원을 누르면 그 작업 단위(scope key)를 돌려주고 닫힌다.
Future<String?> showTextbookWorkflowDialog(
  BuildContext context, {
  required String academyId,
  required String bookId,
  required String bookName,
  required String gradeLabel,
  required int bigOrder,
  required int midOrder,
  String unitTitle = '',
  String? initialScopeKey,
  List<TextbookLegacySubunit> legacySubunits = const [],
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.85),
    builder: (ctx) => Dialog(
      backgroundColor: _kBg,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_kPanelRadius),
        side: const BorderSide(color: _kBorder, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: MediaQuery.of(ctx).size.width - 32,
        height: MediaQuery.of(ctx).size.height - 32,
        child: ProblemRoadmapScreen(
          workflow: TextbookWorkflowScope(
            academyId: academyId,
            bookId: bookId,
            bookName: bookName,
            gradeLabel: gradeLabel,
            bigOrder: bigOrder,
            midOrder: midOrder,
            initialScopeKey: initialScopeKey,
            legacySubunits: legacySubunits,
          ),
          headerTitle: unitTitle.isEmpty ? '2단계 · 추출·검수' : '2단계 · 추출·검수 · $unitTitle',
          onCloseModal: () => Navigator.of(ctx).pop(),
          onPickLegacySubunit: (scopeKey) => Navigator.of(ctx).pop(scopeKey),
        ),
      ),
    ),
  );
}

class ProblemRoadmapScreen extends StatefulWidget {
  const ProblemRoadmapScreen({
    super.key,
    this.service,
    this.initialBookId,
    this.initialGradeLabel,
    this.initialBigOrder,
    this.initialMidOrder,
    this.initialSubKey,
    this.conceptPages = const [],
    this.headerTitle,
    this.workflow,
    this.onCloseModal,
    this.onPickLegacySubunit,
  });

  final TextbookProblemReviewService? service;
  final String? initialBookId;
  final String? initialGradeLabel;
  final int? initialBigOrder;
  final int? initialMidOrder;
  final String? initialSubKey;
  final List<int> conceptPages;
  final String? headerTitle;

  /// 있으면 2단계 작업 화면: 이 중단원의 크롭 확정 소단원만 다루고, 준비됨이 모두 차면 소단원을 확정한다.
  final TextbookWorkflowScope? workflow;
  final VoidCallback? onCloseModal;

  /// 기존 추출 소단원을 눌렀다(단원·크롭 창으로 돌아가 "이어서 마무리"를 누르게 한다).
  final ValueChanged<String>? onPickLegacySubunit;

  @override
  State<ProblemRoadmapScreen> createState() => _ProblemRoadmapScreenState();
}

class _ProblemRoadmapScreenState extends State<ProblemRoadmapScreen> {
  late final TextbookProblemReviewService _svc = widget.service ?? TextbookProblemReviewService();

  bool _loadingUnits = true;
  bool _loadingItems = false;
  bool _loadingPreviews = false;
  bool _runningReview = false;
  bool _stopRequested = false;
  bool _saving = false;
  String? _error;
  String? _notice;
  String? _runProgress;

  List<TextbookReviewUnitScope> _units = const [];
  String? _selectedBookKey;
  TextbookReviewUnitScope? _selectedScope;
  List<TextbookProblemReviewItem> _items = const [];
  Map<String, String> _previewUrlsByCropId = const {};
  Future<void>? _previewLoad;
  String? _selectedCropId;

  /// V2 카드(정답+해설 · AI 풀이 · 대안 풀이) 서명 URL 캐시. 키: cropId|kind|본문 해시
  final Map<String, String> _cardUrlCache = {};
  final Set<String> _cardRendering = {};
  final Map<String, String> _cardErrors = {};

  /// 필터: 0 전체, 1 확인필요(오류·불일치), 2 새초안제안, 3 미검수, 4 승인완료, 5 엔진 보류, 6 승인 후 원본 차이,
  /// 7 준비 안 됨, 8 준비됨(7·8 은 2단계 작업 화면)
  int _filterTab = 0;
  String? _selectedSubKeyFilter;
  bool _initialScopeApplied = false;

  // ── 2단계 작업 화면(widget.workflow) ──
  final _wfService = TextbookWorkflowService();
  final _answerService = TextbookVlmAnswerService();
  final _solutionRefService = TextbookVlmSolutionRefService();
  List<TextbookSubunitWorkflow> _workflows = const [];
  String? _wfKey;
  Set<String> _wfActiveKeys = const {};
  bool _wfBusy = false;

  /// 오른쪽 칸: 0 학생 화면(V2) · 1 원본 PDF(정답·해설 직접 지정)
  int _rightPane = 0;

  final _answerEditCtrl = TextEditingController();
  final _solutionEditCtrl = TextEditingController();
  final _origSolutionCtrl = TextEditingController();
  final _origAnswerCtrl = TextEditingController();

  /// 본문·선지 수정 편집기(AI 제안이 있으면 제안으로, 없으면 현재 값으로 채운다). 선지는 한 줄에 "① 본문".
  final _stemEditCtrl = TextEditingController();
  final _choicesEditCtrl = TextEditingController();
  final _commonStemEditCtrl = TextEditingController();
  final _bulkErrors = <String>[];

  /// 그림 배치 편집기(선택 문항). 원본 대조 그림 제안이 있으면 제안 배치, 없으면 현재 배치(figure_layout.items).
  List<Map<String, dynamic>> _figureLayoutEdit = const [];

  /// 원본 대조가 제안한 "원본에서 잘라 등록할 그림"을 이번 저장에 쓸지(되돌리기로 끔)
  bool _useFigureCrops = true;

  /// 교재 원본 이미지 로드. 같은 Future 를 다시 써서 다시 그릴 때 깜빡이지 않게 한다. 키: crop|쪽|영역
  final Map<String, Future<TextbookReviewRenderedRegion?>> _originalFutures = {};
  List<String> _editingVisualTags = const [];
  List<Map<String, dynamic>> _editingAlternatives = const [];

  @override
  void initState() {
    super.initState();
    if (_workflowMode) {
      _wfActiveKeys = _activeWorkflowKeys();
      TextbookWorkflowRunner.instance.addListener(_onRunnerChanged);
    }
    unawaited(_loadUnits());
  }

  @override
  void dispose() {
    if (_workflowMode) TextbookWorkflowRunner.instance.removeListener(_onRunnerChanged);
    _answerEditCtrl.dispose();
    _solutionEditCtrl.dispose();
    _origSolutionCtrl.dispose();
    _origAnswerCtrl.dispose();
    _stemEditCtrl.dispose();
    _choicesEditCtrl.dispose();
    _commonStemEditCtrl.dispose();
    if (widget.service == null) _svc.dispose();
    super.dispose();
  }

  List<String> get _bookKeys {
    final seen = <String>{};
    final out = <String>[];
    for (final u in _units) {
      final k = '${u.bookId}|${u.gradeLabel}';
      if (seen.add(k)) out.add(k);
    }
    return out;
  }

  String _bookLabelOf(String bookKey) {
    final hit = _units.where((u) => '${u.bookId}|${u.gradeLabel}' == bookKey).firstOrNull;
    return hit?.bookTitle ?? bookKey;
  }

  (int done, int total) _bookProgress(String bookKey) {
    var done = 0;
    var total = 0;
    for (final u in _units) {
      if ('${u.bookId}|${u.gradeLabel}' != bookKey) continue;
      done += u.bothApprovedCount;
      total += u.problemCount;
    }
    return (done, total);
  }

  List<TextbookReviewUnitScope> get _unitsForSelectedBook => [
        for (final u in _units)
          if ('${u.bookId}|${u.gradeLabel}' == _selectedBookKey) u,
      ];

  Future<void> _loadUnits() async {
    if (_workflowMode) {
      await _loadWorkflowScope();
      return;
    }
    setState(() {
      _loadingUnits = true;
      _error = null;
    });
    try {
      final list = await _svc.fetchUnits();
      if (!mounted) return;
      setState(() {
        _units = list;
        _loadingUnits = false;
        if (list.isNotEmpty) {
          TextbookReviewUnitScope? initialMatch;
          if (!_initialScopeApplied && widget.initialBookId != null) {
            _initialScopeApplied = true;
            _selectedSubKeyFilter = widget.initialSubKey?.trim().isNotEmpty == true ? widget.initialSubKey!.trim() : null;
            initialMatch = list.where((u) {
              if (u.bookId != widget.initialBookId) return false;
              if (widget.initialGradeLabel != null && u.gradeLabel != widget.initialGradeLabel) return false;
              if (widget.initialBigOrder != null && u.bigOrder != widget.initialBigOrder) return false;
              if (widget.initialMidOrder != null && u.midOrder != widget.initialMidOrder) return false;
              return true;
            }).firstOrNull;
          }
          final currentKey = _selectedScope?.key;
          final matched = initialMatch ?? (currentKey != null ? list.where((u) => u.key == currentKey).firstOrNull : null);
          _selectedScope = matched ?? list.first;
          _selectedBookKey = '${_selectedScope!.bookId}|${_selectedScope!.gradeLabel}';
        }
      });
      if (_selectedScope != null) {
        await _loadItems(_selectedScope!);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingUnits = false;
        _error = '단원 목록을 읽지 못했습니다: $e';
      });
    }
  }

  // ── 2단계 작업 화면 ─────────────────────────────────────────────────────

  bool get _workflowMode => widget.workflow != null;

  TextbookSubunitWorkflow? get _selectedWorkflow => _workflows.where((w) => w.key == _wfKey).firstOrNull;

  TextbookSubunitWorkOrder? get _selectedOrder {
    final key = _wfKey;
    if (key == null) return null;
    return _selectedWorkflow?.workOrder ?? TextbookWorkflowRunner.instance.stateFor(key)?.order;
  }

  Set<String> _activeWorkflowKeys() {
    final prefix = widget.workflow?.keyPrefix;
    if (prefix == null) return const {};
    return {
      for (final s in TextbookWorkflowRunner.instance.states)
        if (s.active && s.key.startsWith(prefix)) s.key,
    };
  }

  static int _scopeKeyOrder(String k) {
    final m = RegExp(r'^W(\d+)$').firstMatch(k);
    if (m != null) return 1000 + int.parse(m.group(1)!);
    return k.isEmpty ? 0 : k.codeUnitAt(0);
  }

  /// 이 중단원의 소단원 작업 상태를 읽고, 고른 소단원의 작업 지시로 문항 범위를 정한다.
  Future<void> _loadWorkflowScope() async {
    final wf = widget.workflow!;
    setState(() {
      _loadingUnits = _selectedScope == null;
      _error = null;
    });
    try {
      final list = await _wfService.fetchForBook(
        academyId: wf.academyId,
        bookId: wf.bookId,
        gradeLabel: wf.gradeLabel,
        bigOrder: wf.bigOrder,
        midOrder: wf.midOrder,
      );
      final shown = [for (final w in list) if (w.cropConfirmed || w.isConfirmed) w]
        ..sort((a, b) => _scopeKeyOrder(a.scopeKey).compareTo(_scopeKeyOrder(b.scopeKey)));
      if (!mounted) return;
      final prevScope = _selectedScope;
      setState(() {
        _workflows = shown;
        if (_wfKey == null || !shown.any((w) => w.key == _wfKey)) {
          final initial = shown.where((w) => w.scopeKey == wf.initialScopeKey).firstOrNull;
          _wfKey = (initial ?? shown.firstOrNull)?.key;
        }
        final order = _selectedOrder;
        if (order != null) _selectedScope = order.reviewScope;
        _loadingUnits = false;
      });
      final scope = _selectedScope;
      if (scope != null && (prevScope == null || _items.isEmpty)) await _loadItems(scope);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingUnits = false;
        _error = '소단원 작업 상태를 읽지 못했습니다: $e';
      });
    }
  }

  void _onRunnerChanged() {
    if (!mounted) return;
    final active = _activeWorkflowKeys();
    final finished = _wfActiveKeys.difference(active);
    _wfActiveKeys = active;
    setState(() {});
    if (finished.isEmpty) return;
    unawaited(_loadWorkflowScope());
    final scope = _selectedScope;
    if (scope == null || _runningReview || _saving) return;
    final sel = _items.where((x) => x.cropId == _selectedCropId).firstOrNull;
    if (sel != null && (_problemEditDirty(sel) || _mathEditDirty(sel) || _solutionEditDirty(sel))) {
      setState(() => _notice = '2단계 작업이 끝났습니다. 고치던 내용을 저장한 뒤 새로고침하면 결과가 보입니다.');
      return;
    }
    unawaited(_loadItems(scope));
  }

  void _selectWorkflow(TextbookSubunitWorkflow wf) {
    if (wf.key == _wfKey) return;
    setState(() {
      _wfKey = wf.key;
      _filterTab = 0;
      final order = wf.workOrder;
      if (order != null) _selectedScope = order.reviewScope;
      final visible = _scopedItems;
      final pick = visible.where((x) => !x.isWorkflowReady).firstOrNull ?? visible.firstOrNull;
      if (pick != null) {
        _selectItem(pick);
      } else {
        _selectedCropId = null;
      }
    });
  }

  (int ready, int total, int held) _readyCountsOf(TextbookSubunitWorkOrder order) {
    var ready = 0;
    var total = 0;
    var held = 0;
    for (final it in _items) {
      if (!order.matches(it)) continue;
      total++;
      if (it.isWorkflowReady) ready++;
      if (it.isEngineHeld) held++;
    }
    return (ready, total, held);
  }

  /// 소단원을 다시 돌린다. [fromPhase] 기본은 AI 검수부터(본문·정답 위치는 빈 것만 다시 찾는다).
  void _enqueueWorkflow(
    TextbookSubunitWorkOrder order, {
    String fromPhase = TextbookWorkflowPhase.review,
    Set<String>? onlyCropIds,
    bool forceRerun = false,
    bool forceRenderCheck = false,
    String? doneNote,
  }) {
    final queued = TextbookWorkflowRunner.instance.enqueue(
      order,
      fromPhase: fromPhase,
      onlyCropIds: onlyCropIds,
      forceRerun: forceRerun,
      forceRenderCheck: forceRenderCheck,
    );
    _wfActiveKeys = _activeWorkflowKeys();
    setState(() {
      _notice = queued
          ? (doneNote ?? '${order.label} 2단계를 다시 돌립니다.')
          : '${order.label} 2단계가 이미 돌고 있습니다. 끝난 뒤 "다시 검수"를 눌러 주세요.';
    });
  }

  /// "코드 수정 필요" 문항을 Cursor 에 붙여 넣을 수 있게 정리해 복사한다.
  Future<void> _copyEngineHeldReport(TextbookSubunitWorkOrder order) async {
    final held = [for (final it in _items) if (order.matches(it) && it.isEngineHeld) it];
    if (held.isEmpty) return;
    final buf = StringBuffer()
      ..writeln('[렌더 엔진 수정 요청] ${order.bookName} · ${order.bigName} › ${order.midName} › ${order.label}')
      ..writeln('V2 렌더(XeLaTeX) 결과가 교재 원본과 달라 "코드 수정 필요"로 보류된 문항입니다.')
      ..writeln('book_id=${order.bookId} grade=${order.gradeLabel} big=${order.bigOrder} mid=${order.midOrder}')
      ..writeln();
    for (final it in held) {
      final rc = it.renderChecks;
      final symptom = [
        if (it.engineSymptom.isNotEmpty) it.engineSymptom,
        if (rc['issue_title'] != null) '${rc['issue_title']}${rc['issue_detail'] != null ? ': ${rc['issue_detail']}' : ''}',
      ].join(' / ');
      buf.writeln('- ${it.problemNumber}번 (PDF ${it.rawPage}쪽, crop_id=${it.cropId}, pb_question_id=${it.pbQuestionId})');
      if (symptom.isNotEmpty) buf.writeln('  증상: $symptom');
      final note = (it.engineHoldNote ?? '').trim();
      if (note.isNotEmpty) buf.writeln('  메모: $note');
    }
    await Clipboard.setData(ClipboardData(text: buf.toString().trimRight()));
    if (!mounted) return;
    setState(() => _notice = '코드 수정 필요 ${held.length}문항을 복사했습니다. Cursor 에 붙여 넣어 렌더 엔진을 고친 뒤 "코드 수정 후 재확인"을 누르세요.');
  }

  /// 3단계: 모든 카드가 준비됨이면 소단원을 확정한다(교재 탭 진행률에도 남긴다).
  Future<void> _setSubunitConfirmed(TextbookSubunitWorkflow wf, {required bool confirmed}) async {
    final order = wf.workOrder;
    var applyNote = '';
    if (confirmed) {
      if (order == null) return;
      final (ready, total, _) = _readyCountsOf(order);
      if (total == 0 || ready < total) {
        setState(() => _notice = '준비됨이 아닌 카드가 ${total - ready}개 있어 확정할 수 없습니다.');
        return;
      }
      final scope = _selectedScope;
      setState(() => _wfBusy = true);
      try {
        final items = [for (final it in _items) if (order.matches(it)) it];
        final stop = scope == null ? null : await _svc.consistencyGateForConfirm(scope, items);
        if (stop != null) {
          await _loadItems(scope!, reloadPreviews: false);
          if (mounted) setState(() => _notice = '확정하지 않았습니다: $stop');
          return;
        }
        // 수정안을 문제은행·정답에 한 번에 반영한다. 실패하면 아무것도 반영되지 않고 확정하지 않는다.
        final applied = await _svc.applyForConfirm(items);
        applyNote = [
          if (applied.applied > 0) '수정안 ${applied.applied}문항 반영',
          if (applied.generated > 0) '객관식 보기 ${applied.generated}문항 생성',
          ...applied.errors,
        ].join(' · ');
        if (scope != null) await _loadItems(scope, reloadPreviews: false);
      } catch (e) {
        if (mounted) setState(() => _notice = '확정 반영 실패(아무것도 반영하지 않음): $e');
        return;
      } finally {
        if (mounted) setState(() => _wfBusy = false);
      }
      if (!mounted) return;
    }
    setState(() => _wfBusy = true);
    try {
      await _wfService.confirmSubunit(wf, confirmed: confirmed);
      await TextbookBookRegistry().setScopeConfirmed(
        academyId: wf.academyId,
        bookId: wf.bookId,
        gradeLabel: wf.gradeLabel,
        scopeKey: wf.stateKey,
        confirmed: confirmed,
      );
      if (!mounted) return;
      await _loadWorkflowScope();
      if (!mounted) return;
      setState(() => _notice = confirmed
          ? '${order?.label ?? wf.scopeKey} 소단원을 확정했습니다.${applyNote.isEmpty ? '' : ' ($applyNote)'}'
          : '${order?.label ?? wf.scopeKey} 소단원 확정을 풀었습니다.');
    } catch (e) {
      if (mounted) setState(() => _notice = '소단원 ${confirmed ? '확정' : '확정 취소'} 실패: $e');
    } finally {
      if (mounted) setState(() => _wfBusy = false);
    }
  }

  /// 원본 PDF 에서 직접 지정한 정답·해설을 저장한 뒤 이 문항만 AI 가 다시 확인하게 한다.
  Future<void> _afterManualSourceFix(TextbookProblemReviewItem item, String what) async {
    final scope = _selectedScope;
    if (scope == null) return;
    await _loadItems(scope, reloadPreviews: false);
    _cardUrlCache.removeWhere((k, _) => k.startsWith('${item.cropId}|'));
    final order = _selectedOrder;
    if (order == null || !mounted) return;
    _enqueueWorkflow(
      order,
      fromPhase: TextbookWorkflowPhase.sync,
      onlyCropIds: {item.cropId},
      forceRerun: true,
      forceRenderCheck: true,
      doneNote: '${item.problemNumber}번 $what을 저장했습니다. 이 문항만 AI 가 다시 풀고 검수합니다.',
    );
  }

  Future<void> _saveManualAnswer(
    TextbookProblemReviewItem item,
    TextbookSourceSelection sel, {
    String? text,
    String kind = 'subjective',
  }) async {
    final scope = _selectedScope;
    if (scope == null || _saving) return;
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      final TextbookAnswerUpload upload;
      if (text == null) {
        final crop = await _svc.renderSourceRegion(
          scope: scope,
          sourceKind: sel.sourceKind,
          rawPage: sel.rawPage,
          region1k: sel.region1k,
        );
        if (crop == null) throw Exception('고른 영역을 그리지 못했습니다');
        upload = TextbookAnswerUpload(
          cropId: item.cropId,
          answerKind: 'image',
          answerText: '[그림]',
          answerSource: 'manual',
          rawPage: sel.rawPage,
          bbox1k: sel.region1k,
          answerImagePngBytes: crop.bytes,
          answerImageRegion1k: crop.region1k,
          answerImageWidthPx: crop.widthPx,
          answerImageHeightPx: crop.heightPx,
        );
      } else {
        upload = TextbookAnswerUpload(
          cropId: item.cropId,
          answerKind: kind,
          answerText: text,
          answerLatex2d: kind == 'subjective' ? text : null,
          answerSource: 'manual',
          rawPage: sel.rawPage,
          bbox1k: sel.region1k,
        );
      }
      await _answerService.batchUpsertAnswers(academyId: scope.academyId, answers: [upload]);
      await _answerService.syncAnswersToProblemBank(
        academyId: scope.academyId,
        bookId: scope.bookId,
        gradeLabel: scope.gradeLabel,
        bigOrder: scope.bigOrder,
        midOrder: scope.midOrder,
        subKey: item.subKey,
        subIndex: item.subIndex,
      );
      if (!mounted) return;
      setState(() => _saving = false);
      await _afterManualSourceFix(item, text == null ? '그림 정답' : '정답');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '정답 저장 실패: $e';
      });
    }
  }

  Future<void> _saveManualSolution(TextbookProblemReviewItem item, TextbookSourceSelection? sel) async {
    final scope = _selectedScope;
    if (scope == null || _saving) return;
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      await _solutionRefService.batchUpsertSolutionRefs(
        academyId: scope.academyId,
        refs: [
          if (sel == null)
            TextbookSolutionRefUpload(
              cropId: item.cropId,
              rawPage: 0,
              numberRegion1k: const [0, 0, 0, 0],
              source: 'manual',
              sourceKind: 'none',
            )
          else
            TextbookSolutionRefUpload(
              cropId: item.cropId,
              rawPage: sel.rawPage,
              numberRegion1k: sel.region1k,
              contentRegion1k: sel.region1k,
              source: 'manual',
              sourceKind: sel.sourceKind == 'body' ? 'body' : 'sol',
            ),
        ],
      );
      if (!mounted) return;
      setState(() => _saving = false);
      await _afterManualSourceFix(item, sel == null ? '"해설 없음"' : '해설 위치');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '해설 위치 저장 실패: $e';
      });
    }
  }

  Future<void> _loadItems(TextbookReviewUnitScope scope, {bool reloadPreviews = true}) async {
    setState(() {
      _loadingItems = true;
      _error = null;
    });
    try {
      final rawItems = await _svc.fetchUnitItems(scope);
      final items = [...rawItems]..sort(compareItemsByPageAndNumber);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loadingItems = false;
        if (_selectedSubKeyFilter != null && !items.any((x) => x.subKey == _selectedSubKeyFilter)) {
          _selectedSubKeyFilter = null;
        }
        if (_filterTab == 5 && !items.any((x) => x.isEngineHeld)) _filterTab = 0;
        if (_filterTab == 6 && !items.any((x) => x.approvedButDiffers)) _filterTab = 0;
        final visible = _scopedItems;
        final cur = _selectedCropId != null ? visible.where((x) => x.cropId == _selectedCropId).firstOrNull : null;
        final pick = cur ?? visible.where((x) => x.hasIssue).firstOrNull ?? visible.firstOrNull;
        if (pick != null) {
          _selectItem(pick);
        } else {
          _selectedCropId = null;
        }
      });
      if (reloadPreviews) {
        _originalFutures.clear();
        _previewLoad = _loadEnginePreviews(scope, items);
        unawaited(_previewLoad);
      }
      final sel = _items.where((x) => x.cropId == _selectedCropId).firstOrNull;
      if (sel != null) _ensureSelectedCards(sel);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingItems = false;
        _error = '문항 목록을 불러오지 못했습니다: $e';
      });
    }
  }

  Future<void> _loadEnginePreviews(
    TextbookReviewUnitScope scope,
    List<TextbookProblemReviewItem> items, {
    bool merge = false,
  }) async {
    if (items.isEmpty) return;
    setState(() => _loadingPreviews = true);
    try {
      final urls = await _svc.fetchEnginePreviewUrls(
        academyId: scope.academyId,
        items: items,
      );
      if (!mounted) return;
      setState(() {
        _previewUrlsByCropId = merge ? {..._previewUrlsByCropId, ...urls} : urls;
        _loadingPreviews = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingPreviews = false);
    }
  }

  void _selectItem(TextbookProblemReviewItem item) {
    _selectedCropId = item.cropId;
    _answerEditCtrl.text = item.isImageAnswer
        ? item.existingAnswer
        : item.mathStatus == 'issue'
            ? (item.resolvedMathAnswer ?? (item.existingAnswer.isNotEmpty ? item.existingAnswer : (item.aiAnswer ?? '')))
            : (item.existingAnswer.isNotEmpty ? item.existingAnswer : (item.aiAnswer ?? ''));
    _solutionEditCtrl.text = item.proposedAiSolution ?? item.aiSolution ?? '';
    _origSolutionCtrl.text = item.proposedSolutionTranscribed ?? item.solutionTranscribed ?? '';
    _origAnswerCtrl.text = item.proposedSolutionAnswer ?? item.solutionAnswer ?? '';
    // 편집기 기본값: AI/규칙 수정 제안 → 공통 발문 중복이면 공통 부분을 뺀 본문 → 현재 본문
    final dupFix = item.commonStemFix;
    _stemEditCtrl.text = item.hasPendingFixProposal ? (item.proposedStem ?? item.stem) : (dupFix?.stem ?? item.stem);
    _commonStemEditCtrl.text =
        item.hasPendingFixProposal ? (item.proposedCommonStem ?? item.commonStem) : (dupFix?.commonStem ?? item.commonStem);
    _choicesEditCtrl.text = _choicesToLines(item.hasPendingFixProposal ? (item.proposedChoices ?? item.rawChoices) : item.rawChoices);
    _figureLayoutEdit = figureLayoutItems(item.hasPendingFigureProposal ? item.proposedFigureLayout : item.pbFigureLayout);
    _useFigureCrops = true;
    _editingVisualTags = [...item.visualTags];
    _editingAlternatives = [for (final a in item.alternativeSolutions) Map<String, dynamic>.from(a)];
    _ensureSelectedCards(item);
  }

  static String _choicesToLines(List<Map<String, dynamic>> choices) =>
      [for (final c in choices) '${c['label'] ?? ''} ${c['text'] ?? ''}'.trim()].join('\n');

  /// "① 본문" 줄 → [{label, text}]. 원문자·ㄱㄴㄷ·숫자) 로 시작하는 줄만 선지로 본다.
  static List<Map<String, dynamic>> _linesToChoices(String text) {
    final out = <Map<String, dynamic>>[];
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final m = RegExp(r'^([①-⑩ㄱ-ㅎ]|\(?[0-9]{1,2}\)|[0-9]{1,2}\.)\s*(.*)$').firstMatch(line);
      if (m == null) {
        if (out.isNotEmpty) out.last['text'] = '${out.last['text']}\n$line';
        continue;
      }
      out.add({'label': m.group(1)!, 'text': (m.group(2) ?? '').trim()});
    }
    return out;
  }

  /// 편집기의 본문·선지·그림 배치가 저장된 문항과 다르거나, 원본에서 잘라 등록할 그림이 남아 있는가
  bool _problemEditDirty(TextbookProblemReviewItem item) =>
      _stemEditCtrl.text.trim() != item.stem.trim() ||
      _commonStemEditDirty(item) ||
      _choicesToLines(_linesToChoices(_choicesEditCtrl.text)) != _choicesToLines(item.rawChoices) ||
      _figureLayoutDirty(item) ||
      _pendingFigureCrops(item).isNotEmpty;

  /// 수학 정답 입력칸이 DB 저장 정답과 다른가
  bool _mathEditDirty(TextbookProblemReviewItem item) =>
      _answerEditCtrl.text.trim() != item.existingAnswer.trim();

  /// 해설 편집칸(해설 정답·원본 해설·AI 풀이)이 DB 저장값과 다른가
  bool _solutionEditDirty(TextbookProblemReviewItem item) =>
      _origAnswerCtrl.text.trim() != (item.solutionAnswer ?? '').trim() ||
      _origSolutionCtrl.text.trim() != (item.solutionTranscribed ?? '').trim() ||
      _solutionEditCtrl.text.trim() != (item.aiSolution ?? '').trim();

  /// 시각 태그 선택이 DB 저장값과 다른가
  bool _visualTagsDirty(TextbookProblemReviewItem item) {
    final a = [..._editingVisualTags]..sort();
    final b = [...item.visualTags]..sort();
    return a.join('\u0001') != b.join('\u0001');
  }

  bool _commonStemEditDirty(TextbookProblemReviewItem item) =>
      (item.isSetQuestion || _commonStemEditCtrl.text.trim().isNotEmpty) &&
      _commonStemEditCtrl.text.trim() != item.commonStem.trim();

  bool _figureLayoutDirty(TextbookProblemReviewItem item) =>
      figureLayoutSignature({'items': _figureLayoutEdit}) != figureLayoutSignature(item.pbFigureLayout);

  List<Map<String, dynamic>> _pendingFigureCrops(TextbookProblemReviewItem item) =>
      _useFigureCrops && item.hasPendingFigureProposal ? item.proposedFigureCrops : const [];

  Map<String, dynamic> _editedFigureLayout(TextbookProblemReviewItem item) => {
        'version': 1,
        'items': _figureLayoutEdit,
        'groups': item.proposedFigureLayout?['groups'] ?? item.pbFigureLayout['groups'] ?? const [],
      };

  Future<TextbookReviewRenderedRegion?> _originalFuture(
    TextbookReviewUnitScope scope,
    TextbookProblemReviewItem item, {
    bool setHeader = false,
  }) {
    final key = setHeader
        ? 'hdr|${item.setHeaderRawPage}|${item.setHeaderRegion1k.join(',')}'
        : '${item.cropId}|${item.rawPage}|${item.itemRegion1k.join(',')}';
    return _originalFutures.putIfAbsent(key, () => setHeader ? _svc.setHeaderImage(scope, item) : _svc.originalImage(scope, item));
  }

  // ── V2 카드 렌더 (정답+해설 · AI 풀이 · 대안 풀이) ───────────────────────

  String _cardKey(String cropId, String kind, String text) => '$cropId|$kind|${text.trim().hashCode}';

  void _ensureSelectedCards(TextbookProblemReviewItem item) {
    final scope = _selectedScope;
    if (scope == null || !_svc.hasGateway) return;
    // ① 정답 + 해설(원본 우선, 없으면 AI 풀이)
    if (item.primarySolutionText.isNotEmpty || item.displayAnswer.isNotEmpty) {
      unawaited(_renderCard(
        item,
        kind: 'answer_solution',
        text: item.answerSolutionCardSource,
        build: () => _svc.renderAnswerSolutionCard(
          academyId: scope.academyId,
          item: item,
          solutionText: item.primarySolutionText,
          solutionKind: item.primarySolutionKind,
        ),
      ));
    }
    // ② 원본 해설이 따로 있을 때 AI 풀이 카드
    if (item.hasOriginalSolution && item.hasAiSolution) {
      unawaited(_renderCard(
        item,
        kind: 'ai_solution',
        text: item.aiSolution!,
        build: () => _svc.renderSolutionOnlyCard(
          academyId: scope.academyId,
          item: item,
          solutionText: item.aiSolution!,
          kindKey: 'ai',
        ),
      ));
    }
    // ③ 대안 풀이
    for (var i = 0; i < item.alternativeSolutions.length; i += 1) {
      final alt = item.alternativeSolutions[i];
      final text = '${alt['solution'] ?? ''}'.trim();
      if (text.isEmpty) continue;
      unawaited(_renderCard(
        item,
        kind: 'alt_$i',
        text: text,
        build: () => _svc.renderSolutionOnlyCard(
          academyId: scope.academyId,
          item: item,
          solutionText: text,
          kindKey: 'alt$i',
        ),
      ));
    }
  }

  Future<String> _renderCard(
    TextbookProblemReviewItem item, {
    required String kind,
    required String text,
    required Future<String> Function() build,
  }) async {
    final key = _cardKey(item.cropId, kind, text);
    final cached = _cardUrlCache[key];
    if (cached != null) return cached;
    if (_cardRendering.contains(key)) return '';
    _cardRendering.add(key);
    if (mounted) setState(() {});
    try {
      final url = await build();
      if (url.isNotEmpty) _cardUrlCache[key] = url;
      _cardErrors.remove(key);
      return url;
    } catch (e) {
      _cardErrors[key] = '$e';
      return '';
    } finally {
      _cardRendering.remove(key);
      if (mounted) setState(() {});
    }
  }

  // ── 검수 실행 ────────────────────────────────────────────────────────────

  Future<void> _runUnitReview({bool forceRerun = false}) async {
    final scope = _selectedScope;
    if (scope == null || _runningReview) return;
    setState(() {
      _runningReview = true;
      _stopRequested = false;
      _notice = null;
      _runProgress = '해설 PDF·V2 문항 카드를 준비하는 중...';
    });
    try {
      // 소단원 작업 흐름과 같은 파이프라인. 수정안은 반영 대기 값으로만 쌓이고, 반영·승인은 소단원 확정 때 한다.
      final scopedIds = {for (final x in _scopedItems) x.cropId};
      final pipeline = TextbookReviewPipeline(
        service: _svc,
        scope: scope,
        matches: (it) => scopedIds.isEmpty || scopedIds.contains(it.cropId),
        onProgress: (m) {
          if (mounted) setState(() => _runProgress = m);
        },
        isCancelled: () => !mounted || _stopRequested,
      );
      final summary = await pipeline.runAll(forceRerun: forceRerun);
      if (!mounted) return;
      await _loadItems(scope, reloadPreviews: true);
      await _loadUnits();
      final firstIssue = _items.where((x) => x.hasIssue).firstOrNull;
      if (firstIssue != null) _selectItem(firstIssue);
      final ready = _scopedItems.where((x) => x.isWorkflowReady).length;
      final heldCount = _scopedItems.where((x) => x.isEngineHeld).length;
      setState(() {
        _notice = _stopRequested
            ? '요청에 따라 일시정지했습니다 (${summary.reviewed}문항 검수 완료).'
            : '검수가 끝났습니다 (준비됨 $ready/${_scopedItems.length} · V2 검수 ${summary.renderChecked}'
                '${heldCount > 0 ? ' · 엔진 보류 $heldCount' : ''}'
                '${summary.notes.isEmpty ? '' : ' · ${summary.notes.join(' · ')}'}'
                '${summary.errors.isEmpty ? '' : ' · 실패 ${summary.errors.length}건(${summary.errors.first})'}'
                '). 수정안은 소단원 확정 때 반영됩니다.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _notice = '검수 실행 중 오류: $e');
    } finally {
      if (mounted) {
        setState(() {
          _runningReview = false;
          _runProgress = null;
        });
      }
    }
  }

  /// 메타 보충: 단원 기준 개념 후보로 개념·사고 태그를 다시 고르고, 빈 시각 태그를 고른다. 제안만 쌓고 소단원 확정 때 반영한다.
  Future<void> _runMetaFill() async {
    final scope = _selectedScope;
    if (scope == null || _runningReview) return;
    final scopedIds = {for (final x in _scopedItems) x.cropId};
    final wasConfirmed = _workflowMode && (_selectedWorkflow?.isConfirmed ?? false);
    setState(() {
      _runningReview = true;
      _stopRequested = false;
      _notice = null;
      _runProgress = '메타 보충 준비';
    });
    try {
      final pipeline = TextbookReviewPipeline(
        service: _svc,
        scope: scope,
        matches: (it) => scopedIds.isEmpty || scopedIds.contains(it.cropId),
        onProgress: (m) {
          if (mounted) setState(() => _runProgress = m);
        },
        isCancelled: () => !mounted || _stopRequested,
      );
      final filled = await pipeline.runMetaOnly();
      if (!mounted) return;
      await _loadItems(scope, reloadPreviews: false);
      if (!mounted) return;
      final missing = _scopedItems.where((x) => x.missingMeta.isNotEmpty).length;
      setState(() {
        _notice = '${pipeline.consistency.summary} · 메타 보충 $filled문항'
            '${missing > 0 ? ' · 메타 누락 남음 $missing' : ''}'
            '${pipeline.errors.isEmpty ? '' : ' · 실패 ${pipeline.errors.length}건(${pipeline.errors.first})'}'
            '. 수정안과 개념·사고 태그, 새 개념은 소단원 확정 때 반영됩니다.'
            '${wasConfirmed ? ' 이미 확정한 소단원은 확정 취소 후 다시 확정하면 반영됩니다.' : ''}';
      });
    } catch (e) {
      if (mounted) setState(() => _notice = '메타 보충 중 오류: $e');
    } finally {
      if (mounted) {
        setState(() {
          _runningReview = false;
          _runProgress = null;
        });
      }
    }
  }

  /// 코드 정합성 점검(AI 없음, 사양 5-2). 고칠 것은 반영 대기 값으로 쌓고, 나머지는 준비됨을 막는 지적으로 남긴다.
  Future<void> _runConsistencyCheck() async {
    final scope = _selectedScope;
    if (scope == null || _runningReview) return;
    setState(() {
      _runningReview = true;
      _stopRequested = false;
      _notice = null;
      _runProgress = '정합성 점검 · ${scope.bigOrder}-${scope.midOrder} ${scope.midName}';
    });
    try {
      final report = await _svc.runConsistencyCheck(scope, cropIds: [for (final x in _scopedItems) x.cropId]);
      if (!mounted) return;
      await _loadItems(scope, reloadPreviews: false);
      if (!mounted) return;
      setState(() {
        _notice = '${report.summary}'
            '${report.errors.isEmpty ? '' : ' (${report.errors.first})'}'
            '${report.fixed.isEmpty ? '' : '. 수정안은 소단원 확정 때 반영됩니다'}.';
      });
    } catch (e) {
      if (mounted) setState(() => _notice = '정합성 점검 실패: $e');
    } finally {
      if (mounted) {
        setState(() {
          _runningReview = false;
          _runProgress = null;
        });
      }
    }
  }

  /// 아직 V2 렌더 검수를 안 한 문항을 묶어 정답+해설 카드를 찍고 ai_think 에 학생 시점 판정을 맡긴다.
  Future<int> _runRenderCheckPass(TextbookReviewUnitScope scope, {List<TextbookProblemReviewItem>? only}) async {
    var checked = 0;
    final targets = (only ?? _items.where((x) => x.needsRenderCheck)).toList();
    if (targets.isEmpty) return 0;

    Future<Map<String, dynamic>?> buildPayload(TextbookProblemReviewItem it) async {
      final problemUrl = _previewUrlsByCropId[it.cropId];
      String solUrl = '';
      if (it.primarySolutionText.isNotEmpty || it.displayAnswer.isNotEmpty) {
        solUrl = await _renderCard(
          it,
          kind: 'answer_solution',
          text: it.answerSolutionCardSource,
          build: () => _svc.renderAnswerSolutionCard(
            academyId: scope.academyId,
            item: it,
            solutionText: it.primarySolutionText,
            solutionKind: it.primarySolutionKind,
          ),
        );
      }
      if ((problemUrl ?? '').isEmpty && solUrl.isEmpty) return null;
      // 교재 원본(본문 PDF 문항 영역)을 같이 보내 V2 카드와 직접 대조한다(글자·그림 위치·그림 크기).
      final original = (problemUrl ?? '').isEmpty ? const <String, dynamic>{} : await _svc.originalImagesJson(scope, it);
      final solutionOriginal = solUrl.isEmpty ? const <String, dynamic>{} : await _svc.solutionOriginalJson(scope, it);
      return {
        'crop_id': it.cropId,
        if ((problemUrl ?? '').isNotEmpty) 'problem_url': problemUrl,
        if (solUrl.isNotEmpty) 'answer_solution_url': solUrl,
        'solution_kind': it.primarySolutionKind,
        'has_solution_figures': it.solutionFigureAssets.isNotEmpty,
        'is_fill_in_blank': it.isFillInBlank,
        ...original,
        ...solutionOriginal,
      };
    }

    final chunks = <List<TextbookProblemReviewItem>>[
      for (var i = 0; i < targets.length; i += _kRenderCheckChunkSize)
        targets.skip(i).take(_kRenderCheckChunkSize).toList(),
    ];
    var done = 0;
    var next = 0;
    Future<void> worker() async {
      while (next < chunks.length) {
        if (!mounted || _stopRequested) return;
        final chunk = chunks[next++];
        final payload = [
          for (final p in await Future.wait(chunk.map(buildPayload)))
            if (p != null) p,
        ];
        if (payload.isNotEmpty && mounted) {
          final res = await _svc.runRenderCheck(academyId: scope.academyId, items: payload);
          checked += (res['processed'] as num?)?.toInt() ?? 0;
        }
        done += chunk.length;
        if (mounted) {
          setState(() {
            _runProgress = 'V2 렌더 검수: $done / ${targets.length} 문항 — 카드를 V2로 찍어 교재 원본과 대조하는 중...';
          });
        }
      }
    }

    setState(() {
      _runProgress = 'V2 렌더 검수: 0 / ${targets.length} 문항 — 카드를 V2로 찍어 교재 원본과 대조하는 중...';
    });
    await Future.wait([
      for (var w = 0; w < _kRenderCheckParallel && w < chunks.length; w++) worker(),
    ]);
    if (mounted) await _loadItems(scope, reloadPreviews: false);
    return checked;
  }

  Future<void> _renderCheckSingle(TextbookProblemReviewItem item) async {
    final scope = _selectedScope;
    if (scope == null || _runningReview) return;
    setState(() {
      _runningReview = true;
      _stopRequested = false;
      _notice = null;
    });
    try {
      final n = await _runRenderCheckPass(scope, only: [item]);
      if (!mounted) return;
      final cur = _items.where((x) => x.cropId == item.cropId).firstOrNull;
      var resized = false;
      if (cur != null && cur.figureNeedsResize && !cur.isEngineHeld) {
        final sized = await _resizeFiguresFromRenderCheck(includeApproved: true);
        if (sized.contains(item.cropId) && mounted) {
          resized = true;
          await _loadItems(scope, reloadPreviews: false);
          final fresh = _items.where((x) => x.cropId == item.cropId).firstOrNull;
          if (fresh != null) {
            await _loadEnginePreviews(scope, [fresh], merge: true);
            await _runRenderCheckPass(scope, only: [fresh]);
          }
        }
      }
      if (!mounted) return;
      setState(() => _notice = n > 0
          ? '${item.problemNumber}번 V2 렌더 검수를 다시 했습니다${resized ? ' (그림 크기 자동 조정 완료)' : ''}.'
          : 'V2 카드 URL을 만들지 못해 검수하지 못했습니다.');
    } catch (e) {
      if (mounted) setState(() => _notice = 'V2 렌더 검수 실패: $e');
    } finally {
      if (mounted) {
        setState(() {
          _runningReview = false;
          _runProgress = null;
        });
      }
    }
  }

  /// 렌더 검수 진행 표시(_runningReview)를 켠 채로 실행한다. 이미 켜져 있으면 그대로 둔다.
  Future<T> _whileRunning<T>(Future<T> Function() run) async {
    final outer = _runningReview;
    if (!outer) {
      setState(() {
        _runningReview = true;
        _stopRequested = false;
      });
    }
    try {
      return await run();
    } finally {
      if (mounted && !outer) {
        setState(() {
          _runningReview = false;
          _runProgress = null;
        });
      }
    }
  }

  /// 원본 대조 수정 단계(textbook_problem_fix). 문항별 교재 원본·세트 머리·V2 카드를 보내고 fix_proposal 을 받는다.
  /// 반환: 수정안을 만든 문항 수
  Future<int> _runFixPass(TextbookReviewUnitScope scope, List<TextbookProblemReviewItem> targets) async {
    var done = 0;
    final chunks = <List<TextbookProblemReviewItem>>[
      for (var i = 0; i < targets.length; i += _kFixChunkSize)
        targets.skip(i).take(_kFixChunkSize).toList(),
    ];
    for (var b = 0; b < chunks.length; b += 2) {
      if (!mounted || _stopRequested) break;
      final batch = chunks.skip(b).take(2).toList();
      final startIdx = b * _kFixChunkSize + 1;
      final endIdx = (b * _kFixChunkSize + batch.fold<int>(0, (s, c) => s + c.length)).clamp(1, targets.length);
      final range = '$startIdx~$endIdx / ${targets.length} 문항';
      setState(() => _runProgress = '원본 대조 수정안: $range — 원본과 저장된 본문·선지·그림을 대조해 수정안을 만드는 중...');
      final counts = await Future.wait([
        for (final chunk in batch)
          () async {
            final images = await _svc.prepareChunkImages(
              scope: scope,
              items: chunk,
              previewUrlsByCropId: _previewUrlsByCropId,
              includeSolution: true,
              includeSolutionPageFallback: true,
              allItems: _items,
            );
            final ids = <String>[];
            for (final it in chunk) {
              if (images[it.cropId]?.original != null) {
                ids.add(it.cropId);
              } else {
                _bulkErrors.add('${it.problemNumber}번: 본문 PDF 원본을 찍지 못함');
              }
            }
            if (ids.isEmpty || !mounted) return 0;
            try {
              final res = await _svc.runFixPass(
                scope,
                cropIds: ids,
                images: {for (final id in ids) id: images[id]!},
              );
              return (res['processed'] as num?)?.toInt() ?? 0;
            } catch (e) {
              _bulkErrors.add('${chunk.map((x) => x.problemNumber).join(',')}번 원본 대조: $e');
              return 0;
            }
          }(),
      ]);
      for (final c in counts) {
        done += c;
      }
    }
    return done;
  }

  /// 원본 대조 수정 단계만 이 문항에 돌리고, 수정안이 나오면 반영 대기에 넣은 뒤 그 값으로 V2 카드를 찍어 교재 원본과 대조 재검수까지 마친다.
  Future<void> _fixPassSingle(TextbookProblemReviewItem item) async {
    final scope = _selectedScope;
    if (scope == null || _runningReview) return;
    setState(() => _notice = null);
    _bulkErrors.clear();
    try {
      final (n, applied) = await _whileRunning(() async {
        final count = await _runFixPass(scope, [item]);
        if (!mounted || count <= 0) return (count, false);
        await _loadItems(scope, reloadPreviews: false);
        final cur = _items.where((x) => x.cropId == item.cropId).firstOrNull;
        if (cur == null) return (count, false);
        final text = _textProposalUsable(cur);
        final figure = cur.hasPendingFigureProposal;
        if (!text && !figure) return (count, false);
        setState(() => _runProgress = '${item.problemNumber}번 수정안 적용 중...');
        final res = await _applyFixFor(
          scope,
          cur,
          stem: text ? cur.proposedStem : null,
          choices: text ? cur.proposedChoices : null,
          commonStem: text ? cur.proposedCommonStem : null,
          figureLayout: figure ? cur.proposedFigureLayout : null,
          figureCrops: figure ? cur.proposedFigureCrops : const [],
          source: 'ai',
          note: '원본 대조 수정안',
        );
        final changed = ((res['changed'] as List?) ?? const []).isNotEmpty;
        if (!changed || !mounted) return (count, false);
        await _loadItems(scope, reloadPreviews: false);
        final fresh = _items.where((x) => x.cropId == item.cropId).firstOrNull;
        if (fresh != null) {
          await _loadEnginePreviews(scope, [fresh], merge: true);
          await _runRenderCheckPass(scope, only: [fresh]);
        }
        return (count, true);
      });
      if (!mounted) return;
      await _loadItems(scope, reloadPreviews: false);
      await _loadUnits();
      final fresh = _items.where((x) => x.cropId == item.cropId).firstOrNull;
      if (fresh != null) _selectItem(fresh);
      final solRecovered = fresh != null &&
          (fresh.hasOriginalSolution != item.hasOriginalSolution ||
              fresh.solutionAnswer != item.solutionAnswer ||
              fresh.proposedAnswer != item.proposedAnswer);
      setState(() {
        _notice = applied
            ? '${item.problemNumber}번 원본 대조 수정안을 반영 대기에 넣고 V2 카드를 다시 찍어 재검수했습니다${solRecovered ? ' (해설/정답 복구 포함)' : ''}. 문제은행 반영은 소단원 확정 때 합니다.'
            : n > 0
                ? '${item.problemNumber}번 원본·해설 대조 완료${solRecovered ? ' (해설 페이지에서 정답·해설을 찾아 반영했습니다)' : ' (고칠 내용이 없거나 이미 원본과 같습니다)'}.'
                : '${item.problemNumber}번 원본 대조 실패${_bulkErrors.isEmpty ? '' : ': ${_bulkErrors.first}'}';
      });
    } catch (e) {
      if (mounted) setState(() => _notice = '원본 대조 실패: $e');
    }
  }

  /// 원본 대조에서 V2 그림 크기가 원본 비율을 벗어난 문항: 폭(widthEm)을 1/비율 배로 고쳐 적용한다(승인 문항은 승인 유지).
  /// 기존 figure_layout 이 비어 있던 문항도 기본 폭(20em)에서 1/비율 배로 줄인 배치를 새로 만들어 적용한다.
  /// 반환: 적용한 crop id
  Future<List<String>> _resizeFiguresFromRenderCheck({bool includeApproved = true, Set<String>? onlyCropIds}) async {
    final out = <String>[];
    for (final it in _items) {
      if (!mounted || _stopRequested) break;
      if (onlyCropIds != null && !onlyCropIds.contains(it.cropId)) continue;
      if (it.isEngineHeld || !it.figureNeedsResize) continue;
      if (!includeApproved && it.qualityStatus == 'approved') continue;
      final scaled = scaleFigureLayout(
        it.pbFigureLayout,
        1 / it.figureSizeRatio!,
        fallbackAssets: it.pbFigureAssets,
        fallbackCount: figureMarkerCount(it.stem),
      );
      if (figureLayoutItems(scaled).isEmpty) continue;
      try {
        final changed = await _svc.stageChanges(
          cropId: it.cropId,
          patch: {'figure_layout': scaled},
          note: '그림 크기를 원본 글자 비율에 맞춰 재조정',
        );
        if (changed.isNotEmpty) out.add(it.cropId);
      } catch (e) {
        _bulkErrors.add('${it.problemNumber}번 그림 크기: $e');
      }
    }
    return out;
  }

  /// 수정 한 건을 반영 대기 값으로 쌓는다(문제은행 반영은 소단원 확정 때). approve 면 품질을 통과(clean)로 둔다.
  /// 반환: {'changed': 바뀐 반영 대기 항목 키}
  Future<Map<String, dynamic>> _applyFixFor(
    TextbookReviewUnitScope scope,
    TextbookProblemReviewItem item, {
    String? stem,
    List<Map<String, dynamic>>? choices,
    String? commonStem,
    Map<String, dynamic>? figureLayout,
    List<Map<String, dynamic>> figureCrops = const [],
    List<Map<String, dynamic>>? figureAssets,
    bool approve = false,
    String source = 'owner',
    String? note,
  }) async {
    final changed = await _svc.stageProblemFix(
      scope: scope,
      item: item,
      stem: stem,
      choices: choices,
      commonStem: commonStem,
      figureLayout: figureLayout,
      figureCrops: figureCrops,
      figureAssets: figureAssets,
      source: source,
      note: note,
      qualityStatus: approve ? 'clean' : null,
    );
    return {'changed': changed};
  }

  /// AI 본문 수정안(본문·선지·공통 발문)을 그대로 쓸 수 있는가. 공통 발문 중복 규칙 제안은 규칙 수정이 먼저 처리한다.
  static bool _textProposalUsable(TextbookProblemReviewItem it) =>
      it.hasPendingFixProposal && !it.fixProposalIsCommonStemDup && !it.commonStemDuplicated;

  Future<void> _saveAndApproveSingle(
    TextbookProblemReviewItem item, {
    bool approveMath = false,
    bool approveQuality = false,
    String? overrideAnswer,
  }) async {
    setState(() => _saving = true);
    try {
      final origSol = _origSolutionCtrl.text.trim();
      final origAns = _origAnswerCtrl.text.trim();
      final origChanged = origSol != (item.solutionTranscribed ?? '').trim() || origAns != (item.solutionAnswer ?? '').trim();
      final answer = (overrideAnswer ?? _answerEditCtrl.text).trim();
      if (overrideAnswer != null) _answerEditCtrl.text = overrideAnswer;
      // 검수 기록(AI 풀이·시각 태그·다른 풀이)만 바로 저장하고, 정답·원본 해설은 확정 때 반영할 값으로 쌓는다.
      await _svc.saveItemEdit(
        cropId: item.cropId,
        aiSolution: _solutionEditCtrl.text.trim(),
        visualTags: _editingVisualTags,
        alternativeSolutions: _editingAlternatives,
        syncPbAnswer: false,
      );
      final staged = await _svc.stageChanges(
        cropId: item.cropId,
        patch: {
          if (answer.isNotEmpty && answer != '판단불가') 'answer': answer,
          if (origChanged) 'solution_transcribed': origSol,
          if (origChanged) 'solution_answer': origAns,
        },
        source: 'owner',
        note: '사장님 수정',
        mathStatus: approveMath ? 'clean' : null,
        qualityStatus: approveQuality ? 'clean' : null,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '문항 ${item.problemNumber}번: '
            '${staged.isEmpty ? '바뀐 값 없음' : '${staged.length}개 항목을 확정 때 반영할 값으로 저장'}'
            '${approveMath || approveQuality ? ' · ${[if (approveMath) '정답', if (approveQuality) '문항'].join('·')} 검수 통과로 표시' : ''}.';
      });
      if (_selectedScope != null) await _loadItems(_selectedScope!, reloadPreviews: false);
      await _loadUnits();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '저장 실패: $e';
      });
    }
  }

  /// 품질 원터치: 편집기의 본문·선지·공통 발문·그림 배치(바뀐 것만)를 확정 때 반영할 값으로 저장하고, 원본에서 잘라야 할
  /// 그림은 잘라 올린다. approve 면 문항 검수 통과로 표시하고, 아니면 그 값으로 V2 카드를 다시 찍어 확인하게 한다.
  Future<void> _applyProblemFix(TextbookProblemReviewItem item, {required bool approve}) async {
    final scope = _selectedScope;
    if (scope == null) return;
    setState(() => _saving = true);
    try {
      final stem = _stemEditCtrl.text.trim();
      final choices = _linesToChoices(_choicesEditCtrl.text);
      final stemChanged = stem != item.stem.trim();
      final choicesChanged = _choicesToLines(choices) != _choicesToLines(item.rawChoices);
      final commonChanged = _commonStemEditDirty(item);
      final crops = _pendingFigureCrops(item);
      final layoutChanged = _figureLayoutDirty(item) || crops.isNotEmpty;
      if (crops.isNotEmpty) {
        setState(() => _notice = '${item.problemNumber}번 그림 ${crops.length}개를 교재 원본에서 잘라 등록하는 중...');
      }
      final res = await _applyFixFor(
        scope,
        item,
        stem: stemChanged ? stem : null,
        choices: choicesChanged ? choices : null,
        commonStem: commonChanged ? _commonStemEditCtrl.text.trim() : null,
        figureLayout: layoutChanged ? _editedFigureLayout(item) : null,
        figureCrops: crops,
        approve: approve,
        note: item.hasPendingFixProposal || item.hasPendingFigureProposal
            ? '수정안 ${stemChanged || choicesChanged || commonChanged || layoutChanged ? '적용' : '검토'}'
            : null,
      );
      if (approve) {
        // 시각 태그·해설 편집도 같이 저장한다(정답은 건드리지 않는다).
        await _svc.saveItemEdit(
          cropId: item.cropId,
          aiSolution: _solutionEditCtrl.text.trim(),
          visualTags: _editingVisualTags,
          alternativeSolutions: _editingAlternatives,
          syncPbAnswer: false,
        );
      }
      if (!mounted) return;
      final changed = (res['changed'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
      final what = changed.isEmpty
          ? '본문·선지·그림 변경 없음'
          : '${changed.map((c) => switch (c) {
                'stem' => '본문',
                'common_stem' => '공통 발문(세트 전체)',
                'figure_assets' => '원본 크롭 그림 등록',
                'figure_layout' => '그림 크기·위치',
                _ => '선지',
              }).join('·')} 수정을 확정 때 반영할 값으로 저장';
      setState(() {
        _saving = false;
        _notice = '문항 ${item.problemNumber}번: $what${approve ? ' · 문항 검수 통과로 표시' : ' · V2 카드를 다시 찍습니다'}';
      });
      // 본문이 바뀌었으면 이 문항의 카드(V2)만 다시 찍는다.
      await _loadItems(scope, reloadPreviews: false);
      final fresh = _items.where((x) => x.cropId == item.cropId).firstOrNull;
      if (changed.isNotEmpty && fresh != null) await _loadEnginePreviews(scope, [fresh], merge: true);
      await _loadUnits();
      if (!approve && changed.isNotEmpty && mounted && fresh != null) {
        await _renderCheckSingle(fresh);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '본문 수정 적용 실패: $e';
      });
    }
  }

  /// 수정 단계가 문항 그림이 아니라고 본 그림을 사장님 확인 후 문제은행 문항에서 뺀다(배치에서도 뺀다).
  Future<void> _removeProposedFigures(TextbookProblemReviewItem item, List<int> indexes) async {
    final scope = _selectedScope;
    if (scope == null) return;
    setState(() => _saving = true);
    try {
      final next = withoutFigures(item.pbFigureAssets, item.pbFigureLayout, indexes.toSet());
      await _applyFixFor(
        scope,
        item,
        figureAssets: next.assets,
        figureLayout: next.layout,
        note: '문항 그림 아님(${indexes.join(', ')}번) 빼기',
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '문항 ${item.problemNumber}번: 그림 ${indexes.join(', ')}번을 뺐습니다 · V2 카드를 다시 찍습니다';
      });
      await _loadItems(scope, reloadPreviews: false);
      final fresh = _items.where((x) => x.cropId == item.cropId).firstOrNull;
      if (fresh != null) await _loadEnginePreviews(scope, [fresh], merge: true);
      await _loadUnits();
      if (mounted && fresh != null) await _renderCheckSingle(fresh);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '그림 빼기 실패: $e';
      });
    }
  }

  /// 본문에 자리가 없어 자동 등록하지 않은 원본 그림을 사장님 확인 뒤 붙인다(본문 끝에 [그림] 자리를 더한다).
  Future<void> _addUnslottedFigures(TextbookProblemReviewItem item, List<Map<String, dynamic>> crops) async {
    final scope = _selectedScope;
    if (scope == null) return;
    setState(() => _saving = true);
    final labels = crops.map((c) => '${c['figure_index']}번').join(', ');
    try {
      final items = [
        for (final x in (item.pbFigureLayout['items'] is List ? item.pbFigureLayout['items'] as List : const []))
          if (x is Map) Map<String, dynamic>.from(x),
        for (final c in crops)
          {
            'assetKey': 'idx:${c['figure_index']}',
            'widthEm': 16,
            'position': 'below-stem',
            'anchor': 'center',
            'offsetXEm': 0,
            'offsetYEm': 0,
            'heightEm': 1.6,
          },
      ];
      await _applyFixFor(
        scope,
        item,
        stem: '${item.stem.trimRight()}${'\n[그림]' * crops.length}',
        figureLayout: {...item.pbFigureLayout, 'version': 1, 'items': items, 'groups': item.pbFigureLayout['groups'] ?? const []},
        figureCrops: crops,
        note: '자리 없던 원본 그림($labels) 추가',
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '문항 ${item.problemNumber}번: 그림 $labels을 붙였습니다 · V2 카드를 다시 찍습니다';
      });
      await _loadItems(scope, reloadPreviews: false);
      final fresh = _items.where((x) => x.cropId == item.cropId).firstOrNull;
      if (fresh != null) await _loadEnginePreviews(scope, [fresh], merge: true);
      await _loadUnits();
      if (mounted && fresh != null) await _renderCheckSingle(fresh);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '그림 추가 실패: $e';
      });
    }
  }

  Future<void> _setQuestionKind(TextbookProblemReviewItem item, String kind) async {
    final scope = _selectedScope;
    if (scope == null) return;
    setState(() => _saving = true);
    try {
      final changed = await _svc.stageChanges(
        cropId: item.cropId,
        patch: {
          'question_kind': kind,
          if (kind == 'objective' && item.answerChoiceCount > 0) 'allow_subjective': item.subjectiveAlsoPossible,
        },
        source: 'owner',
        note: '사장님 유형 지정',
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = changed.isNotEmpty
            ? '${item.problemNumber}번 유형을 ${_kindLabel(kind)}(으)로 바꿨습니다(확정 때 반영).'
            : '${item.problemNumber}번 유형이 이미 ${_kindLabel(kind)}입니다.';
      });
      await _loadItems(scope, reloadPreviews: false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '유형 변경 실패: $e';
      });
    }
  }

  Future<void> _closeCorrectionNote(TextbookProblemReviewItem item, Map<String, dynamic> finding, {required bool dismiss}) async {
    final scope = _selectedScope;
    if (scope == null) return;
    setState(() => _saving = true);
    try {
      await _svc.closeCorrectionNote(findingId: '${finding['id']}', dismiss: dismiss);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = dismiss
            ? '${item.problemNumber}번 교정 의견을 기각했습니다(교재 오류 아님).'
            : '${item.problemNumber}번 교정 의견을 교재 오류로 기록했습니다. 교재 원본은 그대로 둡니다.';
      });
      await _loadItems(scope, reloadPreviews: false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '교정 의견 처리 실패: $e';
      });
    }
  }

  Widget _correctionNoteBanner(TextbookProblemReviewItem item, Map<String, dynamic> f) {
    final detail = '${f['detail'] ?? ''}'.trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: _kWarn.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(_kInnerRadius),
        border: Border.all(color: _kWarn.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Row(
        children: [
          const Icon(Icons.edit_note_rounded, color: _kWarn, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '교정 의견 — ${f['title'] ?? '교재 원본 오류 의심'}${detail.isEmpty ? '' : ': $detail'}',
              style: const TextStyle(color: _kText, fontSize: 12.5, height: 1.4),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _saving ? null : () => _closeCorrectionNote(item, f, dismiss: true),
            child: const Text('교재 오류 아님', style: TextStyle(color: _kTextSub, fontSize: 12)),
          ),
          TextButton(
            onPressed: _saving ? null : () => _closeCorrectionNote(item, f, dismiss: false),
            child: const Text('교재 오류로 기록', style: TextStyle(color: _kWarn, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Future<void> _dismissConsistencyIssue(TextbookProblemReviewItem item, Map<String, dynamic> finding) async {
    final scope = _selectedScope;
    if (scope == null) return;
    setState(() => _saving = true);
    try {
      await _svc.dismissConsistencyIssue(findingId: '${finding['id']}', note: '사장님 확인: 문제 없음');
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '${item.problemNumber}번 정합성 지적(${finding['title'] ?? ''})을 문제 없음으로 닫았습니다. 문항 내용이 바뀌면 다시 점검합니다.';
      });
      await _loadItems(scope, reloadPreviews: false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '정합성 지적 처리 실패: $e';
      });
    }
  }

  Widget _consistencyIssueBanner(TextbookProblemReviewItem item, Map<String, dynamic> f) {
    final detail = '${f['detail'] ?? ''}'.trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: _kWarn.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(_kInnerRadius),
        border: Border.all(color: _kWarn.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Row(
        children: [
          const Icon(Icons.fact_check_outlined, color: _kWarn, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '정합성 — ${f['title'] ?? ''}${detail.isEmpty ? '' : ': $detail'}',
              style: const TextStyle(color: _kText, fontSize: 12.5, height: 1.4),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _saving ? null : () => _dismissConsistencyIssue(item, f),
            child: const Text('문제 없음', style: TextStyle(color: _kTextSub, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  static String _kindLabel(String k) => switch (k) {
        'objective' => '객관식',
        'subjective' => '주관식',
        'essay' => '서술형',
        _ => '미분류',
      };

  /// 수정안(편집기 내용)을 적용 전에 V2 로 찍어 오른쪽 스택에 보여 준다.
  Future<void> _previewProblemFix(TextbookProblemReviewItem item) async {
    final scope = _selectedScope;
    if (scope == null) return;
    final stem = _stemEditCtrl.text.trim();
    final choices = _linesToChoices(_choicesEditCtrl.text);
    final common = _commonStemEditCtrl.text.trim();
    await _renderCard(
      item,
      kind: 'fix_preview',
      text: '$common\n$stem\n${_choicesToLines(choices)}',
      build: () => _svc.renderProposedProblemCard(
        academyId: scope.academyId,
        item: item,
        stem: stem,
        choices: choices,
        commonStem: item.commonStem.isNotEmpty ? common : null,
      ),
    );
  }

  Future<void> _setEngineHold(List<TextbookProblemReviewItem> items, {required bool hold, String? note}) async {
    if (items.isEmpty) return;
    setState(() => _saving = true);
    try {
      final n = await _svc.setEngineHold([for (final x in items) x.cropId], hold: hold, note: note);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = hold
            ? '$n문항을 렌더 엔진 문제로 보류했습니다. 엔진 수정 후 "렌더 엔진 목록"에서 다시 렌더링해 확인하세요.'
            : '$n문항의 엔진 보류를 해제했습니다(오류 상태로 돌아감).';
      });
      if (_selectedScope != null) await _loadItems(_selectedScope!, reloadPreviews: false);
      await _loadUnits();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '엔진 보류 변경 실패: $e';
      });
    }
  }

  Future<void> _openEngineHoldPanel() async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => TextbookReviewEngineHoldPanel(service: _svc),
    );
    if (!mounted) return;
    await _loadUnits();
  }

  Future<void> _acceptDraftProposal(TextbookProblemReviewItem item, String code) async {
    setState(() => _saving = true);
    try {
      final backfilled = await _svc.acceptDraftProposal(
        cropId: item.cropId,
        proposalCode: code,
        backfillMidunit: true,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '초안($code)을 사전에 정식 등록하고 이 중단원 $backfilled개 문항에 자동 반영했습니다.';
      });
      if (_selectedScope != null) await _loadItems(_selectedScope!, reloadPreviews: false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '초안 등록 실패: $e';
      });
    }
  }

  Future<void> _addAlternativeSolution(TextbookProblemReviewItem item) async {
    final titleCtrl = TextEditingController();
    final solCtrl = TextEditingController();
    final ansCtrl = TextEditingController(text: item.displayAnswer);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kPanelBg,
        title: const Text('대안 풀이 추가', style: TextStyle(color: _kText, fontSize: 16, fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                style: const TextStyle(color: _kText, fontSize: 13),
                decoration: _inputDecoration('풀이 이름 (예: 대입법, 그래프 이용)'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: solCtrl,
                maxLines: 8,
                style: const TextStyle(color: _kText, fontSize: 13, height: 1.45),
                decoration: _inputDecoration('풀이 본문 (LaTeX \$...\$ 지원)'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ansCtrl,
                style: const TextStyle(color: _kText, fontSize: 13),
                decoration: _inputDecoration('이 풀이의 정답'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('취소')),
          ElevatedButton(
            style: _primaryButtonStyle(),
            onPressed: () => Navigator.of(ctx).pop(solCtrl.text.trim().isNotEmpty),
            child: const Text('추가'),
          ),
        ],
      ),
    );
    final newAlt = ok == true
        ? <String, dynamic>{
            'id': DateTime.now().microsecondsSinceEpoch.toString(),
            'source': 'manual',
            'title': titleCtrl.text.trim().isEmpty ? '대안 풀이 ${_editingAlternatives.length + 1}' : titleCtrl.text.trim(),
            'solution': solCtrl.text.trim(),
            'answer': ansCtrl.text.trim(),
            'created_at': DateTime.now().toIso8601String(),
          }
        : null;
    titleCtrl.dispose();
    solCtrl.dispose();
    ansCtrl.dispose();
    if (newAlt == null || !mounted) return;
    setState(() => _editingAlternatives = [..._editingAlternatives, newAlt]);
    await _saveAndApproveSingle(item);
  }

  Future<void> _removeAlternativeSolution(TextbookProblemReviewItem item, int index) async {
    if (index < 0 || index >= _editingAlternatives.length) return;
    setState(() {
      _editingAlternatives = [
        for (var i = 0; i < _editingAlternatives.length; i += 1)
          if (i != index) _editingAlternatives[i],
      ];
    });
    await _saveAndApproveSingle(item);
  }

  List<String> get _availableSubKeys {
    final s = <String>{for (final it in _items) if (it.subKey.trim().isNotEmpty) it.subKey.trim()};
    return s.toList()..sort();
  }

  List<TextbookProblemReviewItem> get _scopedItems {
    if (_workflowMode) {
      final order = _selectedOrder;
      if (order == null) return const [];
      return [for (final it in _items) if (order.matches(it)) it];
    }
    final sub = _selectedSubKeyFilter;
    if (sub == null || sub.isEmpty) return _items;
    return [for (final it in _items) if (it.subKey == sub) it];
  }

  List<TextbookProblemReviewItem> get _filteredItems {
    return [
      for (final it in _scopedItems)
        if (_filterTab == 0 ||
            (_filterTab == 1 && it.hasIssue) ||
            (_filterTab == 2 && it.hasDrafts) ||
            (_filterTab == 3 && (it.mathStatus == 'pending' || it.qualityStatus == 'pending')) ||
            (_filterTab == 4 && it.isFullyApproved) ||
            (_filterTab == 5 && it.isEngineHeld) ||
            (_filterTab == 6 && it.approvedButDiffers) ||
            (_filterTab == 7 && !it.isWorkflowReady) ||
            (_filterTab == 8 && it.isWorkflowReady))
          it,
    ];
  }

  /// 핀셋 추출 1: AI 고정밀 타겟 재추출(본문 PDF 원본 + 세트 머리 + 해설 전체 페이지를 고해상도·상위 추론으로 다시 읽어 DB 에 즉시 반영)
  Future<void> _runAiPincetteExtract(TextbookProblemReviewItem item) async {
    final scope = _selectedScope;
    if (scope == null || _runningReview) return;
    setState(() => _notice = null);
    _bulkErrors.clear();
    try {
      await _whileRunning(() async {
        setState(() => _runProgress = '핀셋 정밀 추출 중: ${item.problemNumber}번 (${item.rawPage}쪽) — 본문·세트머리·해설 전체 페이지 고해상도 로드 중...');
        final images = await _svc.prepareChunkImages(
          scope: scope,
          items: [item],
          previewUrlsByCropId: _previewUrlsByCropId,
          includeSolution: true,
          includeSolutionPageFallback: true,
          forceSolutionPageFallback: true,
          allItems: _items,
        );
        if (!mounted) return;
        setState(() => _runProgress = '핀셋 정밀 추출 중: ${item.problemNumber}번 — 상위 추론(high)으로 본문·수식·AI 정답·해설 위치 정밀 추출 및 DB 반영 중...');
        await _svc.runFixPass(
          scope,
          cropIds: [item.cropId],
          images: images,
          pincette: true,
        );
        if (!mounted) return;
        await _loadItems(scope, reloadPreviews: false);
        final fresh = _items.where((x) => x.cropId == item.cropId).firstOrNull;
        if (fresh != null) {
          if (fresh.proposedFigureCrops.isNotEmpty) {
            setState(() => _runProgress = '핀셋 정밀 추출 중: ${item.problemNumber}번 — 도형 ${fresh.proposedFigureCrops.length}개 크롭·업로드 중...');
            await _applyFixFor(
              scope,
              fresh,
              figureLayout: fresh.proposedFigureLayout,
              figureCrops: fresh.proposedFigureCrops,
              note: '핀셋 추출 도형 크롭 반영',
            );
            await _loadItems(scope, reloadPreviews: false);
          }
          final updated = _items.where((x) => x.cropId == item.cropId).firstOrNull ?? fresh;
          setState(() => _runProgress = '핀셋 정밀 추출 중: ${item.problemNumber}번 — 과제형 V2 카드 렌더링 및 원본 대조 검수 중...');
          await _loadEnginePreviews(scope, [updated], merge: true);
          _cardUrlCache.removeWhere((k, _) => k.startsWith('${item.cropId}|'));
          await _runRenderCheckPass(scope, only: [updated]);
        }
      });
      if (!mounted) return;
      await _loadItems(scope, reloadPreviews: false);
      await _loadUnits();
      final fresh = _items.where((x) => x.cropId == item.cropId).firstOrNull;
      if (fresh != null) _selectItem(fresh);
      setState(() {
        _notice = '${item.problemNumber}번 고정밀 핀셋 추출 및 V2 카드 재검수를 완료했습니다.';
      });
    } catch (e) {
      if (mounted) setState(() => _notice = '핀셋 추출 실패: $e');
    }
  }

  /// 핀셋 추출 2: PDF 페이지에서 마우스 드래그로 직접 영역을 지정해 빠진 문항을 추가하거나 이상 문항을 재추출한다.
  Future<void> _openDragPincetteDialog({
    TextbookProblemReviewItem? existingItem,
    MissingProblemGap? gap,
  }) async {
    final scope = _selectedScope;
    if (scope == null || _runningReview) return;
    final order = _workflowMode ? _selectedOrder : null;
    final defaultPage = existingItem?.rawPage ?? gap?.rawPage ?? (_scopedItems.firstOrNull?.rawPage ?? order?.rawPageFrom ?? 1);
    final defaultDisplayPage = existingItem?.displayPage ?? gap?.displayPage;
    final defaultNum = existingItem?.problemNumber ?? gap?.missingNumber ?? '';
    final defaultSubKey =
        existingItem?.subKey ?? gap?.subKey ?? (_selectedSubKeyFilter ?? order?.reviewSubKeys.firstOrNull ?? 'A');
    final defaultSubIndex = existingItem?.subIndex ??
        gap?.subIndex ??
        (order != null && order.indexedSubKeys.contains(defaultSubKey) ? order.reviewSubIndex : 0);

    final dragResult = await showTextbookPincetteDragDialog(
      context,
      service: _svc,
      scope: scope,
      initialRawPage: defaultPage,
      initialDisplayPage: defaultDisplayPage,
      initialProblemNumber: defaultNum,
      initialSubKey: defaultSubKey,
      initialSubIndex: defaultSubIndex,
      initialRegion1k: existingItem?.itemRegion1k,
      isNewMissingProblem: existingItem == null,
    );
    if (dragResult == null || !mounted) return;

    setState(() => _notice = null);
    try {
      String targetCropId = existingItem?.cropId ?? '';
      await _whileRunning(() async {
        setState(() => _runProgress = '핀셋 영역 저장 중: ${dragResult.problemNumber}번 (PDF ${dragResult.rawPage}쪽)...');
        targetCropId = await _svc.upsertPincetteCrop(
          scope: scope,
          subKey: dragResult.subKey,
          subIndex: dragResult.subIndex,
          rawPage: dragResult.rawPage,
          displayPage: dragResult.displayPage,
          problemNumber: dragResult.problemNumber,
          itemRegion1k: dragResult.region1k,
          cropId: existingItem?.cropId,
        );
        await _loadItems(scope, reloadPreviews: false);
      });
      if (!mounted || targetCropId.isEmpty) return;
      final targetItem = _items.where((x) => x.cropId == targetCropId).firstOrNull;
      if (targetItem != null) {
        _selectItem(targetItem);
        await _runAiPincetteExtract(targetItem);
      }
    } catch (e) {
      if (mounted) setState(() => _notice = '핀셋 영역 추출 실패: $e');
    }
  }

  int get _approvedDiffCount => _items.where((x) => x.approvedButDiffers).length;

  /// 고른 문항만 교재 원본과 대조해 V2 렌더 검수를 다시 한다(승인 문항은 승인 유지, 그림 크기 차이가 나오면 바로 자동 조정 후 재렌더·재대조).
  Future<void> _renderCheckMany(List<TextbookProblemReviewItem> items, String label) async {
    final scope = _selectedScope;
    if (scope == null || items.isEmpty || _runningReview) return;
    setState(() => _notice = null);
    try {
      final (n, resizedCount) = await _whileRunning(() async {
        final count = await _runRenderCheckPass(scope, only: items);
        if (!mounted || _stopRequested) return (count, 0);
        final sized = await _resizeFiguresFromRenderCheck(includeApproved: true);
        if (sized.isNotEmpty && mounted && !_stopRequested) {
          await _loadItems(scope, reloadPreviews: false);
          final sizedItems = [for (final x in _items) if (sized.contains(x.cropId)) x];
          await _loadEnginePreviews(scope, sizedItems, merge: true);
          await _runRenderCheckPass(scope, only: sizedItems);
        }
        return (count, sized.length);
      });
      if (!mounted) return;
      final diff = _approvedDiffCount;
      setState(() => _notice = '$label: $n문항 완료'
          '${resizedCount > 0 ? ' · 그림 크기 자동 조정 $resizedCount문항' : ''}'
          '${diff > 0 ? ' · 승인 후 원본 차이 $diff문항("승인 후 원본 차이" 탭)' : ''}');
    } catch (e) {
      if (mounted) setState(() => _notice = '$label 실패: $e');
    }
  }

  List<TextbookProblemReviewItem> get _engineSuspects => [for (final it in _items) if (it.aiSuspectsEngine) it];
  int get _engineHeldCount => _items.where((x) => x.isEngineHeld).length;
  int get _engineHeldTotal => _units.fold(0, (s, u) => s + u.qualityHeldCount);

  @override
  Widget build(BuildContext context) {
    final mathCleanCount = _scopedItems.where((x) => x.mathStatus == 'clean').length;
    final qualCleanCount = _scopedItems.where((x) => x.qualityStatus == 'clean').length;
    final countBase = _workflowMode ? _scopedItems : _items;
    final issueCount = countBase.where((x) => x.hasIssue).length;
    final draftCount = countBase.where((x) => x.hasDrafts).length;

    return Container(
      color: _kBg,
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTopHeader(mathCleanCount, qualCleanCount),
          const SizedBox(height: 12),
          if (_workflowMode) _buildWorkflowBar() else _buildScopeSelectorBar(),
          if (_runProgress != null) ...[
            const SizedBox(height: 10),
            _buildBanner(_runProgress!, _kAccent, Icons.autorenew_rounded),
          ],
          if (_notice != null) ...[
            const SizedBox(height: 10),
            _buildBanner(_notice!, _kAccent, Icons.check_circle_outline_rounded),
          ],
          const SizedBox(height: 14),
          Expanded(
            child: _loadingUnits || (_loadingItems && _items.isEmpty)
                ? const Center(child: CircularProgressIndicator(color: _kAccent))
                : _error != null
                    ? Center(child: Text(_error!, style: const TextStyle(color: _kError, fontSize: 14)))
                    : _workflowMode && _workflows.isEmpty
                        ? _emptyPanel('이 중단원에 크롭을 확정한 소단원이 없습니다. 1단계에서 크롭을 확정하면 여기서 이어집니다.')
                        : _buildMainWorkspace(issueCount, draftCount),
          ),
        ],
      ),
    );
  }

  Widget _buildTopHeader(int mathCleanCount, int qualCleanCount) {
    final actions = <Widget>[
      if (_runningReview)
        OutlinedButton.icon(
          onPressed: _stopRequested ? null : () => setState(() => _stopRequested = true),
          style: _outlineButtonStyle(color: _kError),
          icon: const Icon(Icons.pause_circle_outline, size: 18, color: _kError),
          label: Text(_stopRequested ? '이번 묶음 후 멈춤' : '일시정지', style: const TextStyle(color: _kError)),
        )
      else ...[
        if (_engineSuspects.isNotEmpty)
          OutlinedButton.icon(
            onPressed: _saving ? null : () => unawaited(_setEngineHold(_engineSuspects, hold: true)),
            style: _outlineButtonStyle(color: _kWarn),
            icon: const Icon(Icons.build_circle_outlined, size: 18, color: _kWarn),
            label: Text('AI 엔진 의심 일괄 보류 (${_engineSuspects.length})'),
          ),
        OutlinedButton.icon(
          onPressed: _saving ? null : () => unawaited(_openEngineHoldPanel()),
          style: _outlineButtonStyle(color: _engineHeldTotal > 0 ? _kWarn : _kTextSub),
          icon: Icon(Icons.format_list_bulleted_rounded, size: 18, color: _engineHeldTotal > 0 ? _kWarn : _kTextSub),
          label: Text('렌더 엔진 목록${_engineHeldTotal > 0 ? ' ($_engineHeldTotal)' : ''}'),
        ),
        if (!_workflowMode)
          ElevatedButton.icon(
            onPressed: _selectedScope == null || _saving ? null : () => unawaited(_runUnitReview()),
            style: _primaryButtonStyle(),
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('중단원 문항 검수 실행'),
          ),
        PopupMenuButton<String>(
          tooltip: '추가 작업',
          color: _kPanelBg,
          icon: const Icon(Icons.more_vert_rounded, color: _kTextSub, size: 20),
          onSelected: (v) {
            if (v == 'rerun_all') unawaited(_runUnitReview(forceRerun: true));
            if (v == 'meta_fill') unawaited(_runMetaFill());
            if (v == 'consistency') unawaited(_runConsistencyCheck());
            if (v == 'render_check') unawaited(_renderCheckMany(_items.toList(), 'V2 렌더 검수(교재 원본 대조)'));
            if (v == 'recheck_approved') {
              unawaited(_renderCheckMany([for (final x in _items) if (x.needsOriginalRecheck) x], '승인 문항 원본 재대조'));
            }
          },
          itemBuilder: (_) {
            final approvedTodo = _items.where((x) => x.needsOriginalRecheck).length;
            final metaTodo = _scopedItems.where((x) => x.needsMetaPass).length;
            return [
              const PopupMenuItem(value: 'rerun_all', child: Text('전체 강제 재검수', style: TextStyle(color: _kText, fontSize: 13))),
              PopupMenuItem(
                value: 'meta_fill',
                enabled: metaTodo > 0 && _selectedScope != null,
                child: Text(
                  '메타 보충 — 개념·사고·빈 시각 태그 고르기 ($metaTodo)',
                  style: TextStyle(color: metaTodo > 0 ? _kText : _kTextMuted, fontSize: 13),
                ),
              ),
              if (!_workflowMode)
                PopupMenuItem(
                  value: 'consistency',
                  enabled: _selectedScope != null,
                  child: const Text('정합성 점검 — 보이는 문항 (AI 없음)', style: TextStyle(color: _kText, fontSize: 13)),
                ),
              const PopupMenuItem(
                value: 'render_check',
                child: Text('V2 렌더 검수만 전체 다시(원본 대조)', style: TextStyle(color: _kText, fontSize: 13)),
              ),
              PopupMenuItem(
                value: 'recheck_approved',
                enabled: approvedTodo > 0,
                child: Text(
                  '승인 문항 원본 재대조 ($approvedTodo) — 승인 유지, 차이만 표시',
                  style: TextStyle(color: approvedTodo > 0 ? _kText : _kTextMuted, fontSize: 13),
                ),
              ),
            ];
          },
        ),
      ],
      IconButton(
        tooltip: '새로고침',
        onPressed: _loadingUnits || _runningReview
            ? null
            : () {
                unawaited(_loadUnits());
                final scope = _selectedScope;
                if (_workflowMode && scope != null) unawaited(_loadItems(scope));
              },
        icon: const Icon(Icons.refresh_rounded, color: _kTextSub, size: 20),
      ),
      if (widget.onCloseModal != null)
        OutlinedButton.icon(
          onPressed: _saving || _runningReview ? null : widget.onCloseModal,
          style: _outlineButtonStyle(color: _kTextSub),
          icon: const Icon(Icons.close_rounded, size: 18, color: _kTextSub),
          label: const Text('닫기'),
        ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final title = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.headerTitle ?? '문항검수',
              style: const TextStyle(color: _kText, fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              _workflowMode
                  ? '카드가 모두 "준비됨"이 되면 소단원을 확정합니다. 렌더 엔진 문제는 "코드 수정 필요"로 따로 모아 고친 뒤 재확인합니다.'
                  : '페이지·문항 흐름순 검수 · 과제형 V2 렌더링(학생 화면) · AI 선풀이 정답 대조 · 고정밀 핀셋 재추출',
              style: const TextStyle(color: _kTextSub, fontSize: 14, fontWeight: FontWeight.w600, height: 1.35),
            ),
          ],
        );
        final actionWrap = Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: actions,
        );
        if (constraints.maxWidth < 920) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              title,
              const SizedBox(height: 12),
              actionWrap,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.fact_check_outlined, color: _kAccent, size: 24),
            const SizedBox(width: 10),
            Expanded(child: title),
            const SizedBox(width: 16),
            Flexible(child: actionWrap),
          ],
        );
      },
    );
  }

  /// 2단계 작업 화면 상단: 소단원 진행 막대 + 고른 소단원의 상태·작업 버튼
  Widget _buildWorkflowBar() {
    final runner = TextbookWorkflowRunner.instance;
    final wf = _selectedWorkflow;
    final order = _selectedOrder;
    final key = _wfKey;
    final st = key == null ? null : runner.stateFor(key);
    final active = key != null && runner.isActive(key);
    final (ready, total, held) = order == null ? (0, 0, 0) : _readyCountsOf(order);
    final notExtracted = order == null ? 0 : _items.where((it) => order.matches(it) && it.pbQuestionId.isEmpty).length;
    final confirmed = wf?.isConfirmed ?? false;
    final failed = !active && (st?.phase == TextbookWorkflowPhase.failed || (st == null && wf?.pipelineStatus == 'failed'));
    final stopped = !active && st == null && (wf?.pipelineUnfinished ?? false);
    final allReady = total > 0 && ready == total;
    final busy = _wfBusy || _saving || _runningReview;
    final legacy = widget.workflow?.legacySubunits ?? const <TextbookLegacySubunit>[];

    final String statusText;
    final Color statusColor;
    if (active) {
      final detail = st?.detail ?? '';
      statusText = '${TextbookWorkflowPhase.label(st?.phase ?? TextbookWorkflowPhase.queued)}${detail.isEmpty ? '' : ' · $detail'}';
      statusColor = _kAccent;
    } else if (failed) {
      final err = (st?.error.isNotEmpty ?? false) ? st!.error : (wf?.pipelineError ?? '');
      statusText = '${wf?.pipelineDetail.isNotEmpty ?? false ? wf!.pipelineDetail : '2단계 실패'}${err.isEmpty ? '' : ' — $err'}';
      statusColor = _kError;
    } else if (stopped) {
      statusText = '앱이 닫혀 ${TextbookWorkflowPhase.label(wf!.pipelinePhase)} 단계에서 멈췄습니다. "이어서 진행"을 누르세요.';
      statusColor = _kWarn;
    } else {
      statusText = [
        '준비됨 $ready/$total',
        if (held > 0) '코드 수정 필요 $held',
        if (notExtracted > 0) '본문 추출 전 $notExtracted',
        if (confirmed) '확정됨',
      ].join(' · ');
      statusColor = allReady ? _kAccent : _kTextSub;
    }

    final actions = <Widget>[
      if (active)
        OutlinedButton.icon(
          onPressed: st?.cancelRequested ?? false ? null : () => runner.cancel(key),
          style: _outlineButtonStyle(color: _kError),
          icon: const Icon(Icons.stop_circle_outlined, size: 18, color: _kError),
          label: Text(st?.cancelRequested ?? false ? '중단하는 중' : '중단', style: const TextStyle(color: _kError)),
        )
      else if (order != null) ...[
        if (failed || stopped)
          ElevatedButton.icon(
            onPressed: busy
                ? null
                : () => _enqueueWorkflow(
                      order,
                      fromPhase: TextbookWorkflowPhase.resumeFrom(wf?.pipelinePhase ?? ''),
                      doneNote: '${order.label} 2단계를 멈춘 단계부터 이어서 진행합니다.',
                    ),
            style: _primaryButtonStyle(),
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('이어서 진행'),
          ),
        OutlinedButton.icon(
          onPressed: busy || confirmed ? null : () => _enqueueWorkflow(order, doneNote: '${order.label} 문항을 다시 검수합니다.'),
          style: _outlineButtonStyle(color: _kAccent),
          icon: const Icon(Icons.replay_rounded, size: 18, color: _kAccent),
          label: const Text('다시 검수'),
        ),
        if (held > 0) ...[
          OutlinedButton.icon(
            onPressed: () => unawaited(_copyEngineHeldReport(order)),
            style: _outlineButtonStyle(color: _kWarn),
            icon: const Icon(Icons.content_copy_rounded, size: 17, color: _kWarn),
            label: Text('코드 수정 필요 $held · 복사'),
          ),
          OutlinedButton.icon(
            onPressed: busy || confirmed
                ? null
                : () => _enqueueWorkflow(
                      order,
                      onlyCropIds: {for (final it in _items) if (order.matches(it) && it.isEngineHeld) it.cropId},
                      forceRenderCheck: true,
                      doneNote: '코드 수정 필요 $held문항을 V2 로 다시 찍어 원본과 대조합니다.',
                    ),
            style: _outlineButtonStyle(color: _kWarn),
            icon: const Icon(Icons.build_circle_outlined, size: 18, color: _kWarn),
            label: const Text('코드 수정 후 재확인'),
          ),
        ],
        PopupMenuButton<String>(
          tooltip: '추가 작업',
          color: _kPanelBg,
          icon: const Icon(Icons.more_horiz_rounded, color: _kTextSub, size: 20),
          onSelected: (v) {
            if (v == 'extract') {
              _enqueueWorkflow(
                order,
                fromPhase: TextbookWorkflowPhase.extract,
                doneNote: '${order.label}: 본문이 없는 문항 추출과 비어 있는 정답·해설 위치 찾기부터 다시 합니다.',
              );
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'extract',
              enabled: !confirmed,
              child: const Text('본문 추출부터 다시(빈 것만)', style: TextStyle(color: _kText, fontSize: 13)),
            ),
          ],
        ),
        if (wf != null && confirmed)
          OutlinedButton.icon(
            onPressed: busy ? null : () => unawaited(_setSubunitConfirmed(wf, confirmed: false)),
            style: _outlineButtonStyle(color: _kTextSub),
            icon: const Icon(Icons.lock_open_rounded, size: 18, color: _kTextSub),
            label: const Text('확정 취소'),
          )
        else if (wf != null)
          Tooltip(
            message: allReady ? '모든 카드가 준비됨입니다' : '준비됨이 아닌 카드 ${total - ready}개를 먼저 정리하세요',
            child: ElevatedButton.icon(
              onPressed: busy || !allReady ? null : () => unawaited(_setSubunitConfirmed(wf, confirmed: true)),
              style: _primaryButtonStyle(),
              icon: const Icon(Icons.verified_rounded, size: 18),
              label: Text(allReady ? '소단원 확정' : '소단원 확정 ($ready/$total)'),
            ),
          ),
      ],
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final w in _workflows) ...[
                  _workflowTab(w),
                  const SizedBox(width: 8),
                ],
                if (legacy.isNotEmpty) ...[
                  Container(width: 0.5, height: 32, color: _kBorder),
                  const SizedBox(width: 8),
                  for (final l in legacy) ...[
                    _legacyTab(l),
                    const SizedBox(width: 8),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (active)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: _kAccent)),
                      ),
                    Flexible(
                      child: Text(
                        statusText,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: statusColor, fontSize: 13, fontWeight: FontWeight.w700, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: actions,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _workflowTab(TextbookSubunitWorkflow w) {
    final runner = TextbookWorkflowRunner.instance;
    final sel = w.key == _wfKey;
    final st = runner.stateFor(w.key);
    final active = runner.isActive(w.key);
    final order = w.workOrder;
    final String status;
    final Color color;
    if (active) {
      status = TextbookWorkflowPhase.label(st?.phase ?? TextbookWorkflowPhase.queued);
      color = _kAccent;
    } else if (w.isConfirmed) {
      status = '확정';
      color = _kAccent;
    } else if (st?.phase == TextbookWorkflowPhase.failed || (st == null && w.pipelineStatus == 'failed')) {
      status = '실패';
      color = _kError;
    } else if (st == null && w.pipelineUnfinished) {
      status = '멈춤';
      color = _kWarn;
    } else if (order != null) {
      final (ready, total, held) = _readyCountsOf(order);
      status = total == 0 ? (st?.summaryText.isNotEmpty ?? false ? st!.summaryText : w.pipelineDetail) : '준비됨 $ready/$total${held > 0 ? ' · 코드 $held' : ''}';
      color = total > 0 && ready == total ? _kAccent : (held > 0 ? _kWarn : _kTextSub);
    } else {
      status = w.pipelineDetail;
      color = _kTextSub;
    }
    return InkWell(
      borderRadius: BorderRadius.circular(_kInnerRadius),
      onTap: () => _selectWorkflow(w),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: sel ? _kChipSelected.withValues(alpha: 0.35) : _kFieldBg,
          borderRadius: BorderRadius.circular(_kInnerRadius),
          border: Border.all(color: sel ? _kAccent : _kBorder, width: sel ? 1 : 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                order?.label.isNotEmpty ?? false ? order!.label : w.scopeKey,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: sel ? _kText : _kTextSub, fontSize: 13, fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (active) ...[
                  const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: _kAccent)),
                  const SizedBox(width: 6),
                ] else if (w.isConfirmed) ...[
                  const Icon(Icons.verified_rounded, size: 12, color: _kAccent),
                  const SizedBox(width: 4),
                ],
                Text(status.isEmpty ? '대기' : status, style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 예전에 본문만 뽑아 둔 소단원. 2단계 카드가 없으므로 누르면 단원·크롭 창으로 돌아간다.
  Widget _legacyTab(TextbookLegacySubunit l) {
    final onPick = widget.onPickLegacySubunit;
    return Tooltip(
      message: '예전에 뽑아 둔 소단원입니다 · 본문 ${l.bodies}/${l.crops} · 검수 ${l.reviewed}/${l.bodies}\n'
          '누르면 단원·크롭 창으로 돌아갑니다. 크롭을 확인하고 "이어서 마무리"를 누르면 '
          '본문과 검수 결과는 그대로 두고 다음 단계부터 진행합니다.',
      child: InkWell(
        borderRadius: BorderRadius.circular(_kInnerRadius),
        onTap: onPick == null ? null : () => onPick(l.scopeKey),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_kInnerRadius),
            border: Border.all(color: _kBorder, width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  l.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _kTextMuted, fontSize: 13, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    l.allReviewed ? Icons.verified_outlined : Icons.history_rounded,
                    size: 12,
                    color: l.allReviewed ? _kAccent : _kTextSub,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    l.allReviewed
                        ? '검수 완료 · 이어서 마무리'
                        : l.reviewed > 0
                            ? '기존 추출 · 검수 ${l.reviewed}/${l.bodies}'
                            : '기존 추출 · 이어서 마무리',
                    style: TextStyle(
                      color: l.allReviewed ? _kAccent : _kTextSub,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 카드 준비 상태 배지(2단계 작업 화면). 준비됨이 아니면 첫 번째 막힌 이유를 보인다.
  Widget _readyPill(TextbookProblemReviewItem item) {
    if (item.isWorkflowReady) return _pillBadge('준비됨', _kAccent);
    final blockers = item.readyBlockers;
    final first = blockers.first;
    final more = blockers.length > 1 ? ' 외 ${blockers.length - 1}' : '';
    final Widget pill;
    if (first == '본문 추출 전') {
      final key = _wfKey;
      final st = key == null ? null : TextbookWorkflowRunner.instance.stateFor(key);
      if (st != null && st.active && st.phase == TextbookWorkflowPhase.extract) {
        String norm(String s) => s.trim().replaceFirst(RegExp(r'^0+(?=\d)'), '');
        final read = st.numbersDone(item.subKey).map(norm).contains(norm(item.problemNumber));
        pill = read ? _pillBadge('본문 읽음 · 저장 대기', _kBlue) : _pillBadge('본문 추출 중', _kTextSub);
      } else {
        pill = _pillBadge(first, _kTextMuted);
      }
    } else if (item.isEngineHeld) {
      pill = _pillBadge('코드 수정 필요$more', _kWarn);
    } else {
      pill = _pillBadge('$first$more', _kError);
    }
    return Tooltip(message: blockers.join('\n'), child: pill);
  }

  Widget _buildScopeSelectorBar() {
    final books = _bookKeys;
    final units = _unitsForSelectedBook;
    final mathApproved = _items.where((x) => x.mathStatus == 'approved').length;
    final qualApproved = _items.where((x) => x.qualityStatus == 'approved').length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: _panelDecoration(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final bookField = _scopeDropdown<String>(
            width: constraints.maxWidth < 860 ? constraints.maxWidth : 300,
            value: books.contains(_selectedBookKey) ? _selectedBookKey : books.firstOrNull,
            items: [
              for (final k in books)
                DropdownMenuItem(
                  value: k,
                  child: _scopeProgressLabel(_bookLabelOf(k), _bookProgress(k)),
                ),
            ],
            onChanged: _runningReview
                ? null
                : (v) {
                    if (v == null) return;
                    setState(() {
                      _selectedBookKey = v;
                      _selectedScope = _unitsForSelectedBook.firstOrNull;
                      _selectedCropId = null;
                    });
                    if (_selectedScope != null) unawaited(_loadItems(_selectedScope!));
                  },
          );
          final unitField = _scopeDropdown<String>(
            value: units.any((u) => u.key == _selectedScope?.key) ? _selectedScope?.key : units.firstOrNull?.key,
            items: [
              for (final u in units)
                DropdownMenuItem(
                  value: u.key,
                  child: _scopeProgressLabel(u.unitTitle, (u.bothApprovedCount, u.problemCount)),
                ),
            ],
            onChanged: _runningReview
                ? null
                : (k) {
                    final hit = units.where((u) => u.key == k).firstOrNull;
                    if (hit == null) return;
                    setState(() {
                      _selectedScope = hit;
                      _selectedCropId = null;
                    });
                    unawaited(_loadItems(hit));
                  },
          );
          final held = _engineHeldCount;
          final subKeys = _availableSubKeys;
          final gaps = detectMissingProblemGaps(_scopedItems);
          final badges = Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (subKeys.length > 1) ...[
                _subKeyFilterChip(null, '전체 슬롯'),
                for (final sk in subKeys) _subKeyFilterChip(sk, '슬롯 $sk'),
              ],
              if (widget.conceptPages.isNotEmpty)
                _pillBadge('개념 페이지 ${widget.conceptPages.length}쪽', _kBlue),
              if (gaps.isNotEmpty)
                _pillBadge('누락 의심 ${gaps.length}건', _kWarn),
              _pillBadge('수학 승인 $mathApproved / ${_scopedItems.length}', _kAccent),
              _pillBadge('품질 승인 $qualApproved / ${_scopedItems.length - held}', _kBlue),
              if (held > 0) _pillBadge('엔진 보류 $held (별도 관리)', _kWarn),
            ],
          );
          final bookLabel = _scopeLabel(Icons.menu_book_rounded, _kAccent, '교재');
          final unitLabel = _scopeLabel(Icons.folder_open_rounded, _kBlue, '중단원');
          if (constraints.maxWidth < 860) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                bookLabel,
                const SizedBox(height: 8),
                bookField,
                const SizedBox(height: 12),
                unitLabel,
                const SizedBox(height: 8),
                unitField,
                const SizedBox(height: 12),
                badges,
              ],
            );
          }
          return Row(
            children: [
              bookLabel,
              const SizedBox(width: 10),
              bookField,
              const SizedBox(width: 16),
              unitLabel,
              const SizedBox(width: 10),
              Expanded(child: unitField),
              const SizedBox(width: 12),
              badges,
            ],
          );
        },
      ),
    );
  }

  Widget _scopeLabel(IconData icon, Color color, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Text(text, style: const TextStyle(color: _kTextSub, fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }

  /// 드롭다운 항목: 이름과 (수학·품질 모두 승인)/(전체) 퍼센트.
  Widget _scopeProgressLabel(String title, (int done, int total) progress) {
    final pct = percentOf(progress.$1, progress.$2);
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: '수학·품질 모두 승인 ${progress.$1} / ${progress.$2}',
          child: Text(
            '$pct%',
            style: TextStyle(
              color: pct >= 100 ? _kAccent : _kTextSub,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }

  Widget _scopeDropdown<T>({
    double? width,
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?>? onChanged,
  }) {
    final field = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: _innerDecoration(),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          isExpanded: true,
          dropdownColor: _kPanelBg,
          style: const TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w700),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
    if (width == null) return field;
    return SizedBox(width: width, child: field);
  }

  BoxDecoration _panelDecoration({Color? borderColor}) {
    return BoxDecoration(
      color: _kPanelBg,
      borderRadius: BorderRadius.circular(_kPanelRadius),
      border: Border.all(color: borderColor ?? _kBorder, width: 0.5),
    );
  }

  BoxDecoration _innerDecoration({Color? borderColor}) {
    return BoxDecoration(
      color: _kFieldBg,
      borderRadius: BorderRadius.circular(_kInnerRadius),
      border: Border.all(color: borderColor ?? _kBorder, width: 0.5),
    );
  }

  Widget _buildMainWorkspace(int issueCount, int draftCount) {
    final filtered = _filteredItems;
    final selected = _items.where((x) => x.cropId == _selectedCropId).firstOrNull;

    final list = _buildProblemListPanel(filtered, issueCount, draftCount);
    final detail = selected == null
        ? _emptyPanel('좌측 목록에서 문항을 선택하세요.')
        : SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildPincetteToolbarCard(selected),
                const SizedBox(height: 12),
                _buildMathReviewCard(selected),
                const SizedBox(height: 12),
                _buildSolutionEditCard(selected),
                const SizedBox(height: 12),
                _buildQualityReviewCard(selected),
              ],
            ),
          );
    final preview = selected == null ? _emptyPanel('V2 렌더 카드') : _buildRightPane(selected);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 1080) {
          return Column(
            children: [
              SizedBox(height: 280, child: list),
              const SizedBox(height: 12),
              Expanded(
                child: selected == null
                    ? detail
                    : SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildPincetteToolbarCard(selected),
                            const SizedBox(height: 12),
                            _buildMathReviewCard(selected),
                            const SizedBox(height: 12),
                            _buildSolutionEditCard(selected),
                            const SizedBox(height: 12),
                            _buildQualityReviewCard(selected),
                            const SizedBox(height: 12),
                            SizedBox(height: 640, child: preview),
                          ],
                        ),
                      ),
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 360, child: list),
            const SizedBox(width: 12),
            Expanded(child: detail),
            const SizedBox(width: 12),
            SizedBox(width: 440, child: preview),
          ],
        );
      },
    );
  }

  Widget _subKeyFilterChip(String? subKey, String label) {
    final sel = _selectedSubKeyFilter == subKey;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => setState(() {
        _selectedSubKeyFilter = subKey;
        final visible = _scopedItems;
        if (_selectedCropId == null || !visible.any((x) => x.cropId == _selectedCropId)) {
          final pick = visible.where((x) => x.hasIssue).firstOrNull ?? visible.firstOrNull;
          if (pick != null) _selectItem(pick);
        }
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? _kChipSelected : _kFieldBg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: sel ? _kAccent : _kBorder, width: 0.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: sel ? _kText : _kTextSub,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  /// 가운데 상단: 핀셋 추출(정확도 우선 재시도 — AI 고정밀 타겟 재추출 + PDF 마우스 드래그 영역 직접 지정) 카드
  Widget _buildPincetteToolbarCard(TextbookProblemReviewItem item) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: _panelDecoration(borderColor: _kAccent.withValues(alpha: 0.45)),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.center_focus_strong_rounded, color: _kAccent, size: 20),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '핀셋 정밀 추출 (${item.problemNumber}번 · PDF ${item.rawPage}쪽)',
                    style: const TextStyle(color: _kText, fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                  const Text(
                    '이상하거나 빠진 문항을 고해상도·상위 추론(high) 또는 PDF 직접 드래그로 정확하게 다시 뽑습니다.',
                    style: TextStyle(color: _kTextSub, fontSize: 11.5, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: _saving || _runningReview || !item.canRenderOriginal
                    ? null
                    : () => unawaited(_runAiPincetteExtract(item)),
                style: _primaryButtonStyle(),
                icon: const Icon(Icons.auto_fix_high_rounded, size: 17),
                label: const Text('AI 고정밀 핀셋 재추출'),
              ),
              OutlinedButton.icon(
                onPressed: _saving || _runningReview
                    ? null
                    : () => unawaited(_openDragPincetteDialog(existingItem: item)),
                style: _outlineButtonStyle(color: _kAccent),
                icon: const Icon(Icons.crop_free_rounded, size: 17, color: _kAccent),
                label: const Text('PDF 영역 직접 드래그 추출'),
              ),
              OutlinedButton.icon(
                onPressed: _saving || _runningReview
                    ? null
                    : () => unawaited(_openDragPincetteDialog()),
                style: _outlineButtonStyle(color: _kBlue),
                icon: const Icon(Icons.add_box_outlined, size: 17, color: _kBlue),
                label: const Text('빠진 문항 직접 추가'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProblemListPanel(
    List<TextbookProblemReviewItem> filtered,
    int issueCount,
    int draftCount,
  ) {
    final scoped = _scopedItems;
    final gaps = _filterTab == 0 ? detectMissingProblemGaps(scoped) : const <MissingProblemGap>[];
    final gapsByAfterId = <String, List<MissingProblemGap>>{};
    for (final g in gaps) {
      gapsByAfterId.putIfAbsent(g.afterCropId, () => []).add(g);
    }

    // 페이지 흐름순으로 [페이지 구획 헤더 / 개념 페이지 안내 / 문항 타일 / 누락 의심 핀셋 카드] 목록을 구성한다.
    final rows = <Widget>[];
    final conceptSet = widget.conceptPages.toSet();
    final emittedConceptPages = <int>{};
    int? lastPage;
    for (final it in filtered) {
      for (final cp in widget.conceptPages) {
        if (cp < it.rawPage && emittedConceptPages.add(cp)) {
          rows.add(_pageSectionHeader(cp, null, isConceptOnly: true));
        }
      }
      if (lastPage != it.rawPage) {
        lastPage = it.rawPage;
        emittedConceptPages.add(it.rawPage);
        rows.add(_pageSectionHeader(
          it.rawPage,
          it.displayPage,
          isConceptOnly: false,
          hasConceptMark: conceptSet.contains(it.rawPage),
        ));
      }
      rows.add(_problemListTile(it));
      final afterGaps = gapsByAfterId[it.cropId];
      if (afterGaps != null) {
        for (final g in afterGaps) {
          rows.add(_missingProblemGapTile(g));
        }
      }
    }
    for (final cp in widget.conceptPages) {
      if (emittedConceptPages.add(cp)) {
        rows.add(_pageSectionHeader(cp, null, isConceptOnly: true));
      }
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.format_list_numbered_rounded, color: _kAccent, size: 17),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  '페이지·문항번호 흐름순 목록',
                  style: TextStyle(color: _kText, fontSize: 13.5, fontWeight: FontWeight.w800),
                ),
              ),
              TextButton.icon(
                onPressed: _saving || _runningReview ? null : () => unawaited(_openDragPincetteDialog()),
                style: TextButton.styleFrom(
                  foregroundColor: _kAccent,
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('빠진 문항 추가', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _filterTabChip(0, '전체 ${scoped.length}'),
              if (_workflowMode) ...[
                _filterTabChip(7, '준비 안 됨 ${scoped.where((x) => !x.isWorkflowReady).length}'),
                _filterTabChip(8, '준비됨 ${scoped.where((x) => x.isWorkflowReady).length}'),
              ],
              _filterTabChip(
                1,
                '오류·불일치 $issueCount'
                '${issueCount > 0 ? ' (수학 ${scoped.where((x) => x.mathStatus == 'issue').length}'
                    ' · 품질 ${scoped.where((x) => x.qualityStatus == 'issue').length})' : ''}',
                highlightError: issueCount > 0,
              ),
              if (draftCount > 0) _filterTabChip(2, '새 초안 $draftCount'),
              _filterTabChip(3, '미검수 ${scoped.where((x) => x.mathStatus == 'pending').length}'),
              _filterTabChip(4, '승인완료 ${scoped.where((x) => x.isFullyApproved).length}'),
              if (_workflowMode && scoped.any((x) => x.isEngineHeld))
                _filterTabChip(5, '코드 수정 필요 ${scoped.where((x) => x.isEngineHeld).length}')
              else if (!_workflowMode && _engineHeldCount > 0)
                _filterTabChip(5, '엔진 보류 $_engineHeldCount'),
              if (_approvedDiffCount > 0) _filterTabChip(6, '승인 후 원본 차이 $_approvedDiffCount'),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: _kBorder, height: 1),
          Expanded(
            child: rows.isEmpty
                ? const Center(child: Text('해당 조건의 문항이 없습니다.', style: TextStyle(color: _kTextSub, fontSize: 14, fontWeight: FontWeight.w600)))
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => rows[i],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _pageSectionHeader(int rawPage, int? displayPage, {required bool isConceptOnly, bool hasConceptMark = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: isConceptOnly ? _kBlue.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isConceptOnly ? _kBlue.withValues(alpha: 0.45) : _kBorder, width: 0.5),
      ),
      child: Row(
        children: [
          Icon(
            isConceptOnly ? Icons.auto_stories_outlined : Icons.description_outlined,
            size: 14,
            color: isConceptOnly ? _kBlue : _kTextSub,
          ),
          const SizedBox(width: 6),
          Text(
            'PDF $rawPage쪽${displayPage != null && displayPage > 0 && displayPage != rawPage ? ' (교재 $displayPage쪽)' : ''}',
            style: TextStyle(
              color: isConceptOnly ? _kBlue : _kText,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
          if (isConceptOnly)
            _pillBadge('개념 페이지 (문항 없음)', _kBlue)
          else if (hasConceptMark)
            _pillBadge('개념+문항 페이지', _kBlue),
        ],
      ),
    );
  }

  Widget _missingProblemGapTile(MissingProblemGap gap) {
    return InkWell(
      borderRadius: BorderRadius.circular(_kInnerRadius),
      onTap: _saving || _runningReview ? null : () => unawaited(_openDragPincetteDialog(gap: gap)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _kWarn.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(_kInnerRadius),
          border: Border.all(color: _kWarn.withValues(alpha: 0.65), width: 1),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: _kWarn, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${gap.missingNumber}번 누락 의심 (PDF ${gap.rawPage}쪽)',
                style: const TextStyle(color: _kWarn, fontSize: 12.5, fontWeight: FontWeight.w800),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _kAccent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text(
                '+ 핀셋 추출로 추가',
                style: TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyPanel(String text) => Container(
        decoration: _panelDecoration(),
        child: Center(child: Text(text, style: const TextStyle(color: _kTextSub, fontSize: 14, fontWeight: FontWeight.w600))),
      );

  Widget _filterTabChip(int index, String label, {bool highlightError = false}) {
    final sel = _filterTab == index;
    final activeColor = highlightError ? _kError : _kAccent;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => setState(() => _filterTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: sel ? (highlightError ? _kError.withValues(alpha: 0.22) : _kChipSelected) : _kFieldBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: sel ? activeColor : _kBorder, width: 0.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: sel ? _kText : (highlightError ? _kError : _kTextSub),
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  (String, Color) _statusBadge(String st, String prefix) => switch (st) {
        'approved' => ('$prefix 승인', _kAccent),
        'clean' => ('$prefix 정상', _kBlue),
        'issue' => ('$prefix 오류', _kError),
        'held' => ('$prefix 엔진 보류', _kWarn),
        _ => ('$prefix 대기', _kTextMuted),
      };

  (String, Color)? _issueKindBadge(TextbookProblemReviewItem item) {
    if (item.commonStemDuplicated && item.qualityStatus != 'approved') return ('데이터: 공통 발문 중복', _kError);
    if (item.approvedButDiffers) return ('승인 후 원본 차이', _kWarn);
    if (item.qualityStatus != 'issue' && !item.isEngineHeld) return null;
    return switch (item.issueKind) {
      'engine' => ('AI 분류: 엔진${item.engineSymptom.isNotEmpty ? ' · ${item.engineSymptom}' : ''}', _kWarn),
      'figure' => ('AI 분류: 도형 자산', _kBlue),
      'data' => ('AI 분류: 데이터${item.hasPendingFixProposal ? ' · 수정안 있음' : ''}', _kError),
      _ => null,
    };
  }

  Widget _problemListTile(TextbookProblemReviewItem item) {
    final selected = item.cropId == _selectedCropId;
    final (mLabel, mColor) = _statusBadge(item.mathStatus, '수학');
    final (qLabel, qColor) = _statusBadge(item.qualityStatus, '품질');

    return InkWell(
      borderRadius: BorderRadius.circular(_kInnerRadius),
      onTap: () => setState(() => _selectItem(item)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? _kChipSelected.withValues(alpha: 0.28) : _kFieldBg,
          borderRadius: BorderRadius.circular(_kInnerRadius),
          border: Border.all(
            color: selected
                ? _kAccent
                : item.hasIssue
                    ? _kError.withValues(alpha: 0.55)
                    : _kBorder,
            width: selected ? 1 : 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: _kPanelBg,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: _kBorder, width: 0.5),
                  ),
                  child: Text(
                    '${item.problemNumber}번',
                    style: const TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w800),
                  ),
                ),
                if (_workflowMode) _readyPill(item),
                if (item.isSetQuestion)
                  _pillBadge(
                    item.setHeaderNumber.isNotEmpty ? '세트 ${item.setHeaderNumber}' : '세트형',
                    _kBlue,
                  ),
                if (item.isFillInBlank) _pillBadge('빈칸형', _kAccent),
                Text(
                  'PDF ${item.rawPage}쪽',
                  style: const TextStyle(color: _kTextSub, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                _pillBadge(mLabel, mColor),
                _pillBadge(qLabel, qColor),
              ],
            ),
            if (item.commonStem.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '[공통] ${item.commonStem.replaceAll('\n', ' ')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _kBlue, fontSize: 11.5, fontWeight: FontWeight.w600),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              item.stem.isEmpty ? '(개별 발문 없음)' : item.stem.replaceAll('\n', ' '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _kTextSub, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (item.totalDifficulty > 0)
                  _pillBadge(
                    '난이도 ${item.totalDifficulty.toStringAsFixed(1)} (개 ${item.conceptScore.toStringAsFixed(1)} · 사 ${item.thinkingScore.toStringAsFixed(1)} · 연 ${item.arithmeticScore.toStringAsFixed(2)})',
                    _kAccent,
                  ),
                _pillBadge(
                  item.hasOriginalSolution
                      ? (item.solutionSource == 'manual' ? '원본 해설 (직접 입력)' : '원본 해설 전사됨')
                      : item.isAnswerOnlyOriginalSolution
                          ? '원본 정답 확인됨 (풀이 생략)'
                          : item.hasSolutionRef
                              ? '원본 해설 미전사'
                              : '해설 좌표 없음',
                  (item.hasOriginalSolution || item.isAnswerOnlyOriginalSolution)
                      ? _kBlue
                      : (item.hasSolutionRef ? _kWarn : _kTextMuted),
                ),
                if (item.renderCheckedAt != null)
                  _pillBadge(
                    !item.renderHasIssue ? 'V2 렌더 정상' : 'V2 렌더 이상',
                    !item.renderHasIssue ? _kAccent : _kError,
                  ),
                if (item.openCorrectionNotes.isNotEmpty) _pillBadge('교정 의견 ${item.openCorrectionNotes.length}', _kWarn),
                if (item.missingMeta.isNotEmpty) _pillBadge('메타 누락 ${item.missingMeta.length}', _kWarn),
                if (_issueKindBadge(item) case final kb?) _pillBadge(kb.$1, kb.$2),
                if (item.hasStagedChanges) _pillBadge('확정 때 반영 ${item.stagedFields.length}', _kBlue),
                if (item.pbAnswerDiffers) _pillBadge('문제은행 정답 다름', _kWarn),
                for (final vt in item.visualTags.take(2)) _pillBadge(vt, _kTextSub),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── 우측: V2 카드 스택 / 원본 PDF ──────────────────────────────────────────

  /// 2단계 작업 화면에서는 학생 화면(V2)과 원본 PDF(정답·해설 직접 지정)를 같은 칸에서 바꿔 본다.
  Widget _buildRightPane(TextbookProblemReviewItem item) {
    final scope = _selectedScope;
    if (!_workflowMode || scope == null) return _buildV2CardStack(item);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _paneToggle(0, '학생 화면(V2)', Icons.smartphone_rounded),
            const SizedBox(width: 8),
            _paneToggle(1, '원본 PDF', Icons.picture_as_pdf_outlined),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _rightPane == 0
              ? _buildV2CardStack(item)
              : TextbookSourcePdfPane(
                  service: _svc,
                  scope: scope,
                  item: item,
                  allItems: _items,
                  busy: _saving || _runningReview,
                  onSaveAnswerImage: (sel) => _saveManualAnswer(item, sel),
                  onSaveAnswerText: (sel, text, kind) => _saveManualAnswer(item, sel, text: text, kind: kind),
                  onSaveSolution: (sel) => _saveManualSolution(item, sel),
                  onMarkNoSolution: () => _saveManualSolution(item, null),
                ),
        ),
      ],
    );
  }

  Widget _paneToggle(int index, String label, IconData icon) {
    final sel = _rightPane == index;
    return InkWell(
      borderRadius: BorderRadius.circular(_kInnerRadius),
      onTap: () => setState(() => _rightPane = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: sel ? _kChipSelected : _kFieldBg,
          borderRadius: BorderRadius.circular(_kInnerRadius),
          border: Border.all(color: sel ? _kAccent : _kBorder, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: sel ? _kText : _kTextSub),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(color: sel ? _kText : _kTextSub, fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildV2CardStack(TextbookProblemReviewItem item) {
    final problemUrl = _previewUrlsByCropId[item.cropId];
    final qc = item.qualityChecks;
    final rc = item.renderChecks;
    final originalIssue =
        rc['problem_ok'] == false || rc['fidelity_ok'] == false || rc['figure_position_ok'] == false || item.figureNeedsResize;
    final stage2Issue = !item.stage2Superseded &&
        (qc['stem_ok'] == false || qc['choices_ok'] == false || qc['figure_ok'] == false || qc['latex_v2_ok'] == false ||
            qc['fidelity_ok'] == false);
    final problemIssue = (item.qualityStatus == 'issue' || item.approvedButDiffers) && (originalIssue || stage2Issue);
    final solutionIssue = rc['answer_ok'] == false || rc['solution_ok'] == false;

    final primaryKey = _cardKey(item.cropId, 'answer_solution', '${item.displayAnswer}\n${item.primarySolutionText}');
    final aiKey = item.hasAiSolution ? _cardKey(item.cropId, 'ai_solution', item.aiSolution!) : null;
    final fixKey = _cardKey(
      item.cropId,
      'fix_preview',
      '${_stemEditCtrl.text.trim()}\n${_choicesToLines(_linesToChoices(_choicesEditCtrl.text))}',
    );
    final showFixPreview = _cardUrlCache.containsKey(fixKey) || _cardRendering.contains(fixKey) || _cardErrors.containsKey(fixKey);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _panelDecoration(
        borderColor: (problemIssue || solutionIssue) ? _kError.withValues(alpha: 0.7) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.smartphone_rounded, color: _kAccent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '학생이 보는 화면 (V2 엔진) — ${item.problemNumber}번',
                  style: const TextStyle(color: _kText, fontSize: 14.5, fontWeight: FontWeight.w800),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_loadingPreviews || _cardRendering.isNotEmpty)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: _kAccent)),
              IconButton(
                tooltip: 'V2 렌더 검수 다시',
                onPressed: _runningReview || !_svc.hasGateway ? null : () => unawaited(_renderCheckSingle(item)),
                icon: const Icon(Icons.rule_rounded, color: _kTextSub, size: 18),
              ),
            ],
          ),
          if (!_svc.hasGateway) ...[
            const SizedBox(height: 8),
            _buildBanner('게이트웨이가 연결되지 않아 V2 카드를 만들 수 없습니다.', _kWarn, Icons.cloud_off_rounded),
          ],
          if (item.stagedSummary case final staged?) ...[
            const SizedBox(height: 8),
            _buildBanner(
              '$staged (아래 카드는 반영할 값으로 찍은 것이고, 문제은행은 소단원 확정 때 바뀝니다'
              '${item.stagedFields.any(item.stagedByOwner) ? ' · 사장님 수정 포함' : ''})',
              _kBlue,
              Icons.pending_actions_rounded,
            ),
          ],
          for (final f in item.openCorrectionNotes) ...[
            const SizedBox(height: 8),
            _correctionNoteBanner(item, f),
          ],
          for (final f in item.consistencyIssues) ...[
            const SizedBox(height: 8),
            _consistencyIssueBanner(item, f),
          ],
          if (item.missingMeta.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildBanner('메타 누락: ${item.missingMeta.join(', ')} (메타 AI 제안 후 확정 때 반영)', _kWarn, Icons.label_off_outlined),
          ],
          if (rc['issue_title'] != null) ...[
            const SizedBox(height: 8),
            _buildBanner('V2 렌더 검수 — ${rc['issue_title']}: ${rc['issue_detail'] ?? ''}', _kError, Icons.warning_amber_rounded),
          ],
          const SizedBox(height: 10),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildOriginalSection(item),
                  const SizedBox(height: 12),
                  _v2CardSection(
                    title: '① 문항 카드',
                    subtitle: item.isSetQuestion ? '세트 공통 발문 포함 · 문제은행 카드와 동일 렌더' : '문제은행 카드와 동일 렌더',
                    url: problemUrl,
                    loading: _loadingPreviews && (problemUrl ?? '').isEmpty,
                    issue: problemIssue,
                    issueText: qc['issue_title'] != null && !item.stage2TextSuperseded
                        ? '${qc['issue_title']}: ${qc['issue_detail'] ?? ''}'
                        : null,
                    badges: [
                      if (item.originalCompared) ('AI가 ⓪ 원본과 대조', _kAccent),
                      if (!item.originalCompared && qc['judged_from_v2_image'] == true) ('AI가 이 화면을 보고 판정', _kAccent),
                      if (qc['judged_from_v2_image'] == false && item.qualityStatus != 'pending') ('텍스트만으로 판정됨', _kWarn),
                      if (rc['fidelity_ok'] == false || (!item.stage2TextSuperseded && qc['fidelity_ok'] == false))
                        ('원본과 내용 불일치', _kError),
                      if (rc['figure_position_ok'] == false) ('그림 위치 원본과 다름', _kError),
                      if (item.figureNeedsResize) ('그림 크기 원본 대비 ×${item.figureSizeRatio!.toStringAsFixed(2)}', _kError),
                      if (item.isEngineHeld) ('엔진 보류 중', _kWarn),
                    ],
                  ),
                  if (showFixPreview) ...[
                    const SizedBox(height: 12),
                    _v2CardSection(
                      title: '①′ 수정안 미리보기',
                      subtitle: '편집기의 본문·선지를 V2 로 찍은 것 · 적용 전',
                      url: _cardUrlCache[fixKey],
                      loading: _cardRendering.contains(fixKey),
                      error: _cardErrors[fixKey],
                      issue: false,
                      issueText: null,
                      badges: const [('적용하면 ① 문항 카드가 이 모양이 됩니다', _kAccent)],
                    ),
                  ],
                  const SizedBox(height: 12),
                  _v2CardSection(
                    title: '② 정답 + ${item.hasOriginalSolution ? '원본 해설' : 'AI 풀이'}',
                    subtitle: item.hasOriginalSolution
                        ? (item.solutionSource == 'manual'
                            ? '운영자가 입력한 해설'
                            : '해설 PDF ${item.solutionRawPage ?? '-'}쪽 영역을 Vision으로 전사')
                        : item.isAnswerOnlyOriginalSolution
                            ? '해설지(${item.solutionRawPage ?? '-'}쪽)에 답만 인쇄된 문항 · 학생 화면에는 AI 풀이를 표시'
                            : (item.hasSolutionRef ? '원본 해설이 아직 없어 AI 풀이를 표시' : '해설 좌표 없음 · AI 풀이'),
                    url: _cardUrlCache[primaryKey],
                    loading: _cardRendering.contains(primaryKey),
                    error: _cardErrors[primaryKey],
                    issue: solutionIssue,
                    issueText: null,
                    emptyText: item.primarySolutionText.isEmpty && item.displayAnswer.isEmpty ? '정답·해설이 아직 없습니다. 검수를 실행하세요.' : null,
                    badges: [
                      ('정답 ${item.displayAnswer.isEmpty ? '-' : item.displayAnswer}', _kBlue),
                      if (rc['answer_ok'] == false) ('정답 표기 안 보임', _kError),
                      if (rc['solution_ok'] == false) ('해설 읽기 문제', _kError),
                    ],
                  ),
                  if (item.hasOriginalSolution && item.hasAiSolution && aiKey != null) ...[
                    const SizedBox(height: 12),
                    _v2CardSection(
                      title: '③ AI 독립 풀이',
                      subtitle: 'AI 정답 ${item.aiAnswer ?? '-'} · 원본 해설과 비교용',
                      url: _cardUrlCache[aiKey],
                      loading: _cardRendering.contains(aiKey),
                      error: _cardErrors[aiKey],
                      issue: false,
                      issueText: null,
                      badges: const [],
                    ),
                  ],
                  for (var i = 0; i < item.alternativeSolutions.length; i += 1) ...[
                    const SizedBox(height: 12),
                    Builder(builder: (_) {
                      final alt = item.alternativeSolutions[i];
                      final text = '${alt['solution'] ?? ''}'.trim();
                      final k = _cardKey(item.cropId, 'alt_$i', text);
                      return _v2CardSection(
                        title: '${_circledNumber(i + (item.hasOriginalSolution && item.hasAiSolution ? 4 : 3))} ${alt['title'] ?? '대안 풀이 ${i + 1}'}',
                        subtitle: '${alt['source'] == 'ai' ? 'AI 제안' : '직접 입력'} · 정답 ${alt['answer'] ?? '-'}',
                        url: _cardUrlCache[k],
                        loading: _cardRendering.contains(k),
                        error: _cardErrors[k],
                        issue: false,
                        issueText: null,
                        badges: const [],
                        onRemove: _saving ? null : () => unawaited(_removeAlternativeSolution(item, i)),
                      );
                    }),
                  ],
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : () => unawaited(_addAlternativeSolution(item)),
                    style: _outlineButtonStyle(color: _kTextSub),
                    icon: const Icon(Icons.add_rounded, size: 16, color: _kTextSub),
                    label: const Text('대안 풀이 추가'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// ⓪ 교재 원본: 본문 PDF 문항 영역(세트면 세트 머리도). AI 가 V2 카드와 대조하는 바로 그 이미지다.
  Widget _buildOriginalSection(TextbookProblemReviewItem item) {
    final scope = _selectedScope;
    const titleStyle = TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w800);
    const subStyle = TextStyle(color: _kTextSub, fontSize: 11.5);
    if (scope == null || !item.canRenderOriginal) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('⓪ 교재 원본', style: titleStyle),
          Text('이 문항은 본문 PDF 좌표가 없어 원본을 표시·대조할 수 없습니다.', style: subStyle),
        ],
      );
    }
    Widget image(Future<TextbookReviewRenderedRegion?> future) => FutureBuilder<TextbookReviewRenderedRegion?>(
          future: future,
          builder: (context, snap) {
            final r = snap.data;
            return ProblemBankQuestionCard(
              radius: _kInnerRadius,
              backgroundColor: Colors.white,
              borderColor: const Color(0xFFD5DDDD),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 72),
                child: r != null
                    ? Image.memory(r.bytes, fit: BoxFit.fitWidth, alignment: Alignment.topCenter, gaplessPlayback: true)
                    : SizedBox(
                        height: 72,
                        child: Center(
                          child: snap.connectionState == ConnectionState.done
                              ? const Text(
                                  '본문 PDF에서 원본을 찍지 못했습니다.',
                                  style: TextStyle(color: Color(0xFF9A3B3B), fontSize: 12),
                                )
                              : const CircularProgressIndicator(strokeWidth: 2, color: _kAccent),
                        ),
                      ),
              ),
            );
          },
        );
    final showHeader = item.isSetQuestion && item.canRenderSetHeader;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('⓪ 교재 원본', style: titleStyle),
        Text('본문 PDF ${item.rawPage}쪽 문항 영역 · AI가 ① 문항 카드와 대조하는 이미지', style: subStyle),
        const SizedBox(height: 6),
        if (showHeader) ...[
          Text('세트 머리 (${item.setHeaderRawPage}쪽 · 공통 지시문)', style: subStyle),
          const SizedBox(height: 4),
          image(_originalFuture(scope, item, setHeader: true)),
          const SizedBox(height: 6),
        ],
        image(_originalFuture(scope, item)),
      ],
    );
  }

  Widget _v2CardSection({
    required String title,
    required String subtitle,
    required String? url,
    required bool loading,
    required bool issue,
    required String? issueText,
    required List<(String, Color)> badges,
    String? error,
    String? emptyText,
    VoidCallback? onRemove,
  }) {
    final hasUrl = (url ?? '').isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title, style: const TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w800)),
            ),
            if (onRemove != null)
              IconButton(
                tooltip: '이 풀이 삭제',
                onPressed: onRemove,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: const Icon(Icons.close_rounded, size: 16, color: _kTextMuted),
              ),
          ],
        ),
        Text(subtitle, style: const TextStyle(color: _kTextSub, fontSize: 11.5)),
        if (badges.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: [for (final b in badges) _pillBadge(b.$1, b.$2)]),
        ],
        if (issueText != null) ...[
          const SizedBox(height: 6),
          Text(issueText, style: const TextStyle(color: _kError, fontSize: 11.5, height: 1.35)),
        ],
        const SizedBox(height: 6),
        ProblemBankQuestionCard(
          radius: _kInnerRadius,
          backgroundColor: Colors.white,
          borderColor: issue ? _kError : const Color(0xFFD5DDDD),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 96),
            child: hasUrl
                ? Image.network(
                    url!,
                    fit: BoxFit.fitWidth,
                    alignment: Alignment.topCenter,
                    loadingBuilder: (_, child, progress) => progress == null
                        ? child
                        : const SizedBox(
                            height: 96,
                            child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: _kAccent)),
                          ),
                    errorBuilder: (_, __, ___) => const SizedBox(
                      height: 96,
                      child: Center(
                        child: Text('V2 카드 이미지를 불러오지 못했습니다.', style: TextStyle(color: Color(0xFF9A3B3B), fontSize: 12)),
                      ),
                    ),
                  )
                : SizedBox(
                    height: 96,
                    child: Center(
                      child: loading
                          ? const CircularProgressIndicator(strokeWidth: 2, color: _kAccent)
                          : Text(
                              error != null
                                  ? 'V2 렌더 실패: $error'
                                  : (emptyText ?? (_svc.hasGateway ? 'V2 카드를 아직 만들지 않았습니다.' : '게이트웨이 미연결')),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Color(0xFF6B7A7A), fontSize: 12),
                            ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  String _circledNumber(int n) {
    const nums = ['①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨'];
    return (n >= 1 && n <= nums.length) ? nums[n - 1] : '$n)';
  }

  // ── 가운데: 수학적 검수 카드 ─────────────────────────────────────────────

  Widget _buildMathReviewCard(TextbookProblemReviewItem item) {
    final (mLabel, mColor) = _statusBadge(item.mathStatus, '수학 검수');
    final matched = item.answerMatched;
    final mathDirty = _mathEditDirty(item);
    final needMathSave = item.mathStatus != 'approved' || mathDirty || item.pbAnswerDiffers;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _panelDecoration(
        borderColor: item.mathStatus == 'issue' ? _kError.withValues(alpha: 0.7) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.functions_rounded, color: _kAccent, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '수학적 검수 (${item.matchMode == '3way' ? '기존답 · 해설답 · AI답 3자 대조' : '기존답 · AI답 2자 대조'})',
                  style: const TextStyle(color: _kText, fontSize: 16, fontWeight: FontWeight.w800, height: 1.35),
                ),
              ),
              const SizedBox(width: 8),
              _pillBadge(mLabel, mColor),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (item.mathStatus == 'approved' && !needMathSave)
                _pillBadge(
                  item.answerManual ? '✓ 수정 정답·문제은행 DB 반영 완료' : '✓ 채점 정답·문제은행 DB 반영 완료',
                  _kAccent,
                ),
              if (mathDirty) _pillBadge('저장 전 정답 변경 있음', _kWarn),
              if (matched == false && (item.aiAnswer ?? '').isNotEmpty && item.aiAnswer != '판단불가')
                OutlinedButton.icon(
                  onPressed: _saving
                      ? null
                      : () => unawaited(_saveAndApproveSingle(
                            item,
                            approveMath: true,
                            overrideAnswer: item.aiAnswer,
                          )),
                  style: _outlineButtonStyle(color: _kAccent),
                  icon: const Icon(Icons.auto_fix_high_rounded, size: 16, color: _kAccent),
                  label: Text('AI 답(${item.aiAnswer}) 채택 후 승인'),
                ),
              if (matched == false && (item.solutionAnswer ?? '').isNotEmpty && item.solutionAnswer != item.aiAnswer)
                OutlinedButton.icon(
                  onPressed: _saving
                      ? null
                      : () => unawaited(_saveAndApproveSingle(
                            item,
                            approveMath: true,
                            overrideAnswer: item.solutionAnswer,
                          )),
                  style: _outlineButtonStyle(color: _kBlue),
                  icon: const Icon(Icons.menu_book_rounded, size: 16, color: _kBlue),
                  label: Text('해설 답(${item.solutionAnswer}) 채택 후 승인'),
                ),
              ElevatedButton.icon(
                onPressed: _saving || !needMathSave ? null : () => unawaited(_saveAndApproveSingle(item, approveMath: true)),
                style: _primaryButtonStyle(),
                icon: Icon(
                  item.mathStatus == 'approved' && !needMathSave ? Icons.task_alt_rounded : Icons.check_circle_outline_rounded,
                  size: 18,
                ),
                label: Text(
                  item.mathStatus == 'approved'
                      ? (mathDirty
                          ? '정답 수정 저장 (승인 유지)'
                          : item.pbAnswerDiffers
                              ? '문제은행 정답 동기화 저장'
                              : '정답 반영·승인 완료 (변경 없음)')
                      : '수학적 검수 승인${mathDirty ? ' (정답 수정 포함)' : ''}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final saved = _answerCompareTile(
                item.mathStatus == 'approved' && !mathDirty
                    ? '현재 DB 저장 정답 (바꾸면 저장 버튼이 켜집니다)'
                    : '기존 저장 정답 (직접 수정 가능)',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _answerEditCtrl,
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(color: _kText, fontSize: 14, fontWeight: FontWeight.w800),
                      decoration: _inputDecoration('정답 입력'),
                    ),
                    if (mathDirty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '현재 DB 저장값: ${item.existingAnswer.trim().isEmpty ? '(비어 있음)' : item.existingAnswer.trim()}',
                        style: const TextStyle(color: _kTextMuted, fontSize: 11.5),
                      ),
                    ],
                  ],
                ),
              );
              final fromBook = _answerCompareTile(
                '원본 해설 정답 (Vision 전사)',
                value: item.hasSolutionRef ? (item.solutionAnswer ?? (item.hasOriginalSolution ? '(답 표기 없음)' : '(전사 전)')) : '(해설 좌표 없음 · 2자 대조)',
                accent: _kBlue,
              );
              final fromAi = _answerCompareTile(
                'AI 블라인드 풀이 정답',
                value: item.aiAnswer ?? '(검수 전)',
                accent: matched == false ? _kError : _kAccent,
              );
              if (constraints.maxWidth < 720) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    saved,
                    const SizedBox(height: 8),
                    fromBook,
                    const SizedBox(height: 8),
                    fromAi,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: saved),
                  const SizedBox(width: 10),
                  Expanded(child: fromBook),
                  const SizedBox(width: 10),
                  Expanded(child: fromAi),
                ],
              );
            },
          ),
          if (item.mathStatus == 'issue' && item.resolvedMathAnswer != null) ...[
            const SizedBox(height: 10),
            _buildBanner(
              '원본·해설 PDF 대조 수정안: ${item.resolvedMathAnswer}'
              '${item.proposedMathReason != null ? ' — ${item.proposedMathReason}' : ' (입력칸에 미리 채워 두었습니다. 수학 일괄 처리 또는 승인을 누르면 DB에 반영됩니다)'}',
              _kAccent,
              Icons.auto_fix_high_rounded,
            ),
          ],
          if (matched == false && (item.mismatchReason ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            _buildBanner('불일치 분석: ${item.mismatchReason}', _kError, Icons.warning_amber_rounded),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (item.pbQuestionId.isEmpty)
                _pillBadge('문제은행 사본 없음', _kTextMuted)
              else ...[
                _pillBadge(
                  '문제은행 ${item.pbAllowObjective && item.pbObjectiveAnswerKey.isNotEmpty ? '객관식 ${item.pbObjectiveAnswerKey}' : '주관식 ${item.pbSubjectiveAnswer.isEmpty ? '(비어 있음)' : item.pbSubjectiveAnswer}'}',
                  item.pbAnswerDiffers ? _kWarn : _kTextSub,
                ),
                _pillBadge(
                  item.pbAnswerDiffers ? '채점 정답과 다름 → 승인 시 함께 맞춤' : '승인 시 문제은행 정답도 함께 저장',
                  item.pbAnswerDiffers ? _kWarn : _kTextMuted,
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: _innerDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text(
                      '메타 · 3축 난이도',
                      style: TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w800),
                    ),
                    _pillBadge('총점 ${item.totalDifficulty.toStringAsFixed(2)}점', _kAccent),
                    _pillBadge('개념 ${item.conceptScore.toStringAsFixed(2)}점', _kBlue),
                    _pillBadge('사고 ${item.thinkingScore.toStringAsFixed(2)}점', _kAccent),
                    _pillBadge('연산 ${item.arithmeticScore.toStringAsFixed(2)}점', _kTextSub),
                    _pillBadge('교재 라벨 ${item.labelDisplay}', _kTextSub),
                    if (item.metaCheckedAt == null && item.concepts.isNotEmpty)
                      _pillBadge('개념 태그 재선정 전 (예전 후보 목록)', _kWarn),
                  ],
                ),
                if (item.concepts.isNotEmpty || item.thinkings.isNotEmpty || item.arithmetics.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final c in item.concepts)
                        _pillBadge('[개념] ${c['name']} (${c['score']}점)', _kBlue),
                      for (final t in item.thinkings)
                        _pillBadge(
                          '[${t['kind'] == 'frame' ? '사고틀' : '알고리즘'}] ${t['title']} (${t['score']}점)',
                          _kAccent,
                        ),
                      for (final a in item.arithmetics)
                        _pillBadge(
                          '[연산] ${a['title']} ×${a['count']} (${a['subtotal']}점)',
                          _kTextSub,
                        ),
                    ],
                  ),
                ],
                for (final p in item.conceptProposals) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _pillBadge('[새 개념 · 확정 때 생성] ${p['name'] ?? ''} (${p['type'] ?? ''})', _kBlue),
                      if ('${p['reason'] ?? ''}'.trim().isNotEmpty)
                        Text('${p['reason']}', style: const TextStyle(color: _kTextMuted, fontSize: 11.5)),
                    ],
                  ),
                  if ('${p['content'] ?? ''}'.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${p['content']}',
                      style: const TextStyle(color: _kTextSub, fontSize: 12.5, height: 1.35),
                    ),
                  ],
                ],
              ],
            ),
          ),
          if (item.draftProposals.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final dp in item.draftProposals)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(14),
                decoration: _innerDecoration(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _pillBadge(
                          dp['target'] == 'arithmetic' ? '선택 사항 · 새 연산 사전 제안' : '선택 사항 · 새 사고 사전 제안',
                          _kTextSub,
                        ),
                        const Text(
                          '문항 검수 완료와는 무관합니다 (사전에 추가하고 싶을 때만 클릭)',
                          style: TextStyle(color: _kTextMuted, fontSize: 11.5),
                        ),
                        OutlinedButton.icon(
                          onPressed: _saving
                              ? null
                              : () => unawaited(_acceptDraftProposal(item, '${dp['code'] ?? ''}')),
                          style: _outlineButtonStyle(color: _kTextSub),
                          icon: const Icon(Icons.add_task_rounded, size: 16, color: _kTextSub),
                          label: const Text('사전 등록 + 앞 문항 백필'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${dp['title']} (${dp['category']} · ${dp['unit_score']}점) — ${dp['criteria'] ?? dp['trigger_cond'] ?? ''}',
                      style: const TextStyle(color: _kTextSub, fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.35),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  // ── 가운데: 해설 편집 카드 (원본 해설 · AI 풀이 분리 저장) ───────────────

  Widget _buildSolutionEditCard(TextbookProblemReviewItem item) {
    final sv = item.qualityChecks['solution_vision'];
    final visionNote = sv is Map ? sv['note'] : null;
    final visionConf = sv is Map ? sv['confidence'] : null;
    final visionFailed =
        item.hasSolutionRef && !item.hasOriginalSolution && !item.isAnswerOnlyOriginalSolution && item.hasAiSolution;
    final solDirty = _solutionEditDirty(item);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _panelDecoration(
        borderColor: visionFailed ? _kWarn.withValues(alpha: 0.7) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.menu_book_rounded, color: _kBlue, size: 22),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '해설 — 원본 해설(교재)과 AI 독립 풀이를 따로 저장',
                  style: TextStyle(color: _kText, fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _pillBadge(
                item.hasOriginalSolution
                    ? (item.solutionSource == 'manual'
                        ? '원본 직접 입력 (DB 저장됨)'
                        : '원본 Vision 전사${visionConf != null ? ' · $visionConf' : ''} (DB 저장됨)')
                    : item.isAnswerOnlyOriginalSolution
                        ? '원본 정답 확인됨 · 해설지 풀이 생략${visionConf != null ? ' · $visionConf' : ''} (AI 풀이 사용)'
                        : (item.hasSolutionRef ? '원본 미전사' : '해설 좌표 없음'),
                (item.hasOriginalSolution || item.isAnswerOnlyOriginalSolution)
                    ? _kBlue
                    : (item.hasSolutionRef ? _kWarn : _kTextMuted),
              ),
              if (solDirty) _pillBadge('저장 전 해설 변경 있음', _kWarn),
              if (item.canRenderOriginal && (visionFailed || !item.hasOriginalSolution))
                OutlinedButton.icon(
                  onPressed: _saving || _runningReview ? null : () => unawaited(_fixPassSingle(item)),
                  style: _outlineButtonStyle(color: _kBlue),
                  icon: const Icon(Icons.find_in_page_rounded, size: 17, color: _kBlue),
                  label: const Text('해설 페이지 전체에서 다시 찾기'),
                ),
              ElevatedButton.icon(
                onPressed: _saving || !solDirty ? null : () => unawaited(_saveAndApproveSingle(item)),
                style: _primaryButtonStyle(),
                icon: Icon(solDirty ? Icons.save_outlined : Icons.task_alt_rounded, size: 18),
                label: Text(solDirty ? '해설 수정 저장' : '해설 DB 반영 완료 (변경 없음)'),
              ),
            ],
          ),
          if (visionFailed) ...[
            const SizedBox(height: 10),
            _buildBanner(
              '해설 PDF ${item.solutionRawPage ?? '-'}쪽 좌표 영역에서 원본 해설을 읽지 못했습니다${visionNote != null ? ' — $visionNote' : ''}. '
              '"해설 페이지 전체에서 다시 찾기"를 누르면 쪽 전체에서 문항 블록을 찾아 전사·좌표 보정합니다. 그 전까지 학생 화면에는 AI 풀이가 표시됩니다.',
              _kWarn,
              Icons.warning_amber_rounded,
            ),
          ],
          const SizedBox(height: 12),
          const Text('원본 해설 (교재 해설 PDF 전사 · 고치면 저장 버튼이 켜집니다)', style: TextStyle(color: _kTextSub, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _origAnswerCtrl,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(color: _kText, fontSize: 14, fontWeight: FontWeight.w700),
            decoration: _inputDecoration('해설 정답'),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _origSolutionCtrl,
            onChanged: (_) => setState(() {}),
            maxLines: 6,
            minLines: 3,
            style: const TextStyle(color: _kText, fontSize: 13, height: 1.45),
            decoration: _inputDecoration(
              item.isAnswerOnlyOriginalSolution
                  ? '해설지에 정답만 인쇄되어 있고 풀이 과정은 생략된 문항입니다(학생 화면에는 아래 AI 풀이가 표시됩니다). 직접 입력해도 됩니다.'
                  : item.hasSolutionRef
                      ? '검수를 실행하면 해설 PDF 영역에서 전사됩니다. 직접 입력해도 됩니다.'
                      : '해설 좌표가 없는 문항입니다. 직접 입력할 수 있습니다.',
            ),
          ),
          const SizedBox(height: 12),
          Text('AI 독립 풀이 (정답 ${item.aiAnswer ?? '-'} · 고치면 저장 버튼이 켜집니다)', style: const TextStyle(color: _kTextSub, fontSize: 12)),
          const SizedBox(height: 6),
          TextField(
            controller: _solutionEditCtrl,
            onChanged: (_) => setState(() {}),
            maxLines: 6,
            minLines: 3,
            style: const TextStyle(color: _kText, fontSize: 13, height: 1.45),
            decoration: _inputDecoration('AI 독립 풀이 텍스트'),
          ),
        ],
      ),
    );
  }

  Widget _answerCompareTile(String label, {String? value, Widget? child, Color accent = _kText}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _innerDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: _kTextSub, fontSize: 11.5)),
          const SizedBox(height: 6),
          child ??
              Text(
                value ?? '',
                style: TextStyle(color: accent, fontSize: 14, fontWeight: FontWeight.w800),
              ),
        ],
      ),
    );
  }

  // ── 가운데: 품질 · V2 렌더링 · 시각 태그 검수 카드 ──────────────────────

  Widget _buildQualityReviewCard(TextbookProblemReviewItem item) {
    final (qLabel, qColor) = _statusBadge(item.qualityStatus, '품질 검수');
    final qc = item.qualityChecks;
    final rc = item.renderChecks;
    final stemOk = qc['stem_ok'] != false;
    final choicesOk = qc['choices_ok'] != false;
    final figureOk = qc['figure_ok'] != false;
    final latexOk = qc['latex_v2_ok'] != false;
    final fidelityOk = qc['fidelity_ok'] != false;
    final judgedFromImage = qc['judged_from_v2_image'] == true;
    final kindBadge = _issueKindBadge(item);
    final dirty = _problemEditDirty(item);
    final tagsDirty = _visualTagsDirty(item);
    final anyQualityDirty = dirty || tagsDirty;
    final canSaveQuality = !_saving && !_runningReview && (item.qualityStatus != 'approved' || anyQualityDirty);
    final appliedSummary = item.appliedFixSummary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _panelDecoration(
        borderColor: item.qualityStatus == 'issue'
            ? _kError.withValues(alpha: 0.7)
            : item.isEngineHeld
                ? _kWarn.withValues(alpha: 0.7)
                : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.high_quality_rounded, color: _kBlue, size: 22),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '품질 검수 — 학생 시점 V2 렌더 기준',
                  style: TextStyle(color: _kText, fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _pillBadge(qLabel, qColor),
              if (kindBadge != null) _pillBadge(kindBadge.$1, kindBadge.$2),
              if (appliedSummary != null && !dirty) _pillBadge('✓ AI·규칙 수정 DB 반영됨', _kAccent),
              if (anyQualityDirty) _pillBadge('저장 전 변경 있음', _kWarn),
              if (item.isEngineHeld) ...[
                OutlinedButton.icon(
                  onPressed: _saving ? null : () => unawaited(_setEngineHold([item], hold: false)),
                  style: _outlineButtonStyle(color: _kTextSub),
                  icon: const Icon(Icons.undo_rounded, size: 16, color: _kTextSub),
                  label: const Text('보류 해제'),
                ),
                ElevatedButton.icon(
                  onPressed: _saving ? null : () => unawaited(_saveAndApproveSingle(item, approveQuality: true)),
                  style: _primaryButtonStyle(),
                  icon: const Icon(Icons.task_alt_rounded, size: 18),
                  label: const Text('엔진 수정 확인됨 → 품질 승인'),
                ),
              ] else ...[
                // 승인 버튼은 하나: 이미 승인된 문항은 본문·그림·시각태그를 바꿨을 때만 버튼이 활성화된다.
                ElevatedButton.icon(
                  onPressed: !canSaveQuality
                      ? null
                      : () => unawaited(
                            dirty ? _applyProblemFix(item, approve: true) : _saveAndApproveSingle(item, approveQuality: true),
                          ),
                  style: _primaryButtonStyle(),
                  icon: Icon(
                    item.qualityStatus == 'approved' && !anyQualityDirty ? Icons.task_alt_rounded : Icons.verified_outlined,
                    size: 18,
                  ),
                  label: Text(
                    item.qualityStatus == 'approved'
                        ? (dirty
                            ? '본문·그림 수정 저장 (승인 유지)'
                            : tagsDirty
                                ? '시각태그 수정 저장 (승인 유지)'
                                : '품질 반영·승인 완료 (변경 없음)')
                        : '품질 검수 승인${dirty ? ' (수정 저장 포함)' : ''}',
                  ),
                ),
                if (item.qualityStatus == 'issue')
                  OutlinedButton.icon(
                    onPressed: _saving ? null : () => unawaited(_setEngineHold([item], hold: true)),
                    style: _outlineButtonStyle(color: _kWarn),
                    icon: const Icon(Icons.build_circle_outlined, size: 16, color: _kWarn),
                    label: const Text('엔진 문제로 보류'),
                  ),
              ],
            ],
          ),
          if (appliedSummary != null && !dirty) ...[
            const SizedBox(height: 10),
            _buildBanner(
              '$appliedSummary · 아래 입력칸과 오른쪽 ① 문항 카드가 DB에 반영된 최종 상태입니다.',
              _kAccent,
              Icons.task_alt_rounded,
            ),
          ],
          if (item.isEngineHeld) ...[
            const SizedBox(height: 10),
            _buildBanner(
              '렌더 엔진 보류 — ${item.engineHoldNote ?? ''}'
              '${item.engineHeldAt != null ? ' (${_fmtDate(item.engineHeldAt!)})' : ''}'
              '${item.renderCheckedAt != null && item.engineHeldAt != null && item.renderCheckedAt!.isAfter(item.engineHeldAt!) ? (item.renderHasIssue ? ' · 재검수에서도 이상' : ' · 보류 후 재검수 정상 → 승인 가능') : ''}',
              _kWarn,
              Icons.build_circle_outlined,
            ),
          ],
          if (qc['issue_title'] != null && !item.stage2TextSuperseded) ...[
            const SizedBox(height: 10),
            _buildBanner('문항 카드 — ${qc['issue_title']}: ${qc['issue_detail'] ?? ''}', _kError, Icons.warning_amber_rounded),
          ],
          if (rc['issue_title'] != null) ...[
            const SizedBox(height: 8),
            _buildBanner(
              '${item.approvedButDiffers ? '승인 후 원본 대조 차이 (승인 유지)' : item.originalCompared ? 'V2 카드 ↔ 교재 원본' : '정답·해설 카드'}'
              ' — ${rc['issue_title']}: ${rc['issue_detail'] ?? ''}',
              item.approvedButDiffers ? _kWarn : _kError,
              Icons.warning_amber_rounded,
            ),
          ],
          const SizedBox(height: 12),
          _buildQuestionKindRow(item),
          const SizedBox(height: 12),
          _buildProblemFixEditor(item, dirty: dirty),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _pillBadge(
                item.qualityStatus == 'pending'
                    ? '문항 카드 판정 전'
                    : judgedFromImage
                        ? '문항 카드: V2 화면을 보고 판정'
                        : '문항 카드: 텍스트만으로 판정(V2 이미지 없었음)',
                item.qualityStatus == 'pending' ? _kTextMuted : (judgedFromImage ? _kAccent : _kWarn),
              ),
              _pillBadge(stemOk ? '발문 온전' : '발문 절단/겹침 의심', stemOk ? _kAccent : _kError),
              _pillBadge(choicesOk ? '선지·보기 완비' : '선지·보기 누락 의심', choicesOk ? _kAccent : _kError),
              _pillBadge(figureOk ? '도형 표시 정상' : '도형 잘림/누락 의심', figureOk ? _kAccent : _kError),
              _pillBadge(latexOk ? '수식 조판 정상' : '수식 깨짐/LaTeX 노출', latexOk ? _kAccent : _kError),
              _pillBadge(fidelityOk ? '원본과 내용 일치' : '원본과 내용 불일치', fidelityOk ? _kAccent : _kError),
              _pillBadge(
                item.renderCheckedAt == null
                    ? '정답·해설 카드 검수 전'
                    : (rc['answer_ok'] != false && rc['solution_ok'] != false ? '정답·해설 카드 읽힘' : '정답·해설 카드 이상'),
                item.renderCheckedAt == null ? _kTextMuted : (rc['answer_ok'] != false && rc['solution_ok'] != false ? _kAccent : _kError),
              ),
              if (!item.originalCompared)
                _pillBadge(item.canRenderOriginal ? '교재 원본 대조 전' : '원본 좌표 없음(원본 대조 불가)', _kTextMuted)
              else ...[
                _pillBadge(
                  rc['fidelity_ok'] != false ? 'V2 ↔ 원본 내용 일치' : 'V2 ↔ 원본 내용 차이',
                  rc['fidelity_ok'] != false ? _kAccent : _kError,
                ),
                if (item.hasFigures)
                  _pillBadge(
                    rc['figure_position_ok'] != false ? '그림 위치 원본과 같음' : '그림 위치 원본과 다름',
                    rc['figure_position_ok'] != false ? _kAccent : _kError,
                  ),
                if (item.figureSizeRatio != null)
                  _pillBadge(
                    '그림 크기 원본 대비 ×${item.figureSizeRatio!.toStringAsFixed(2)}',
                    item.figureNeedsResize ? _kError : _kAccent,
                  ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            '도형 · 시각 요소 태그 (추후 자체 도형/그래프 생성 프로그램 연동용 · 클릭하여 토글)',
            style: TextStyle(color: _kTextSub, fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in kStandardVisualTags)
                _visualTagChip(
                  tag,
                  selected: _editingVisualTags.contains(tag),
                  onTap: () {
                    setState(() {
                      if (_editingVisualTags.contains(tag)) {
                        _editingVisualTags = _editingVisualTags.where((x) => x != tag).toList();
                      } else if (tag == kVisualTagNone) {
                        _editingVisualTags = [kVisualTagNone];
                      } else {
                        _editingVisualTags = [..._editingVisualTags.where((x) => x != kVisualTagNone), tag];
                      }
                    });
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _fmtDate(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.month}/${l.day} ${two(l.hour)}:${two(l.minute)}';
  }

  /// 문항 유형(객관식·주관식·서술형): 문제은행 표시값, 규칙 기준, AI 판단을 보여 주고 눌러서 바꾼다.
  Widget _buildQuestionKindRow(TextbookProblemReviewItem item) {
    final cur = item.currentQuestionKind;
    final want = item.expectedQuestionKind;
    final ai = item.aiQuestionKind;
    final mismatch = item.questionKindMismatch;
    final kw = item.essayKeyword;
    final reason = want == 'essay'
        ? "'$kw' 포함 → 서술형"
        : want == 'objective'
            ? '선지 ${item.rawChoices.length}개 → 객관식'
            : '선지 없음 → 주관식';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _innerDecoration(borderColor: mismatch ? _kError.withValues(alpha: 0.6) : null),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('문항 유형', style: TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w800)),
          for (final k in const ['objective', 'subjective', 'essay'])
            ChoiceChip(
              label: Text(_kindLabel(k)),
              selected: cur == k,
              onSelected: _saving || item.pbQuestionId.isEmpty || cur == k ? null : (_) => unawaited(_setQuestionKind(item, k)),
              selectedColor: (mismatch ? _kError : _kAccent).withValues(alpha: 0.25),
              backgroundColor: _kPanelBg,
              labelStyle: TextStyle(
                color: cur == k ? (mismatch ? _kError : _kAccent) : _kTextSub,
                fontSize: 12.5,
                fontWeight: cur == k ? FontWeight.w800 : FontWeight.w600,
              ),
              side: BorderSide(color: cur == k ? (mismatch ? _kError : _kAccent) : _kBorder),
            ),
          _pillBadge('규칙: $reason', mismatch ? _kError : _kTextMuted),
          if (item.isFillInBlank) _pillBadge('빈칸형 (발문·수식 □ 빈칸 정상)', _kAccent),
          if (ai != null) _pillBadge('AI: ${_kindLabel(ai)}', ai == want ? _kTextMuted : _kWarn),
          if (mismatch)
            ElevatedButton.icon(
              onPressed: _saving ? null : () => unawaited(_setQuestionKind(item, want)),
              style: _primaryButtonStyle(),
              icon: const Icon(Icons.auto_fix_high_rounded, size: 16),
              label: Text('${_kindLabel(want)}(으)로 맞추기'),
            ),
          if (cur.isEmpty || mismatch)
            Text(
              '문제은행 표시: ${cur.isEmpty ? '미분류' : _kindLabel(cur)} · 객관식 허용 ${item.pbAllowObjective ? 'O' : 'X'} · 주관식 허용 ${item.pbAllowSubjective ? 'O' : 'X'} · 서술형 ${item.pbAllowEssay ? 'O' : 'X'}',
              style: const TextStyle(color: _kTextMuted, fontSize: 11.5),
            ),
        ],
      ),
    );
  }

  /// 본문·선지·그림 편집기. 수정안(원본 대조·규칙)이 있으면 제안으로 채워져 있고, 원문과 다른 부분을 아래에 보여 준다.
  Widget _buildProblemFixEditor(TextbookProblemReviewItem item, {required bool dirty}) {
    final fp = item.fixProposal;
    final hasProposal = item.hasPendingFixProposal || item.hasPendingFigureProposal;
    final dup = item.commonStemDuplicated;
    final reason = '${fp['reason'] ?? ''}'.trim();
    final fromFixPass = fp['source'] == 'fix_pass';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _innerDecoration(borderColor: hasProposal || dup ? _kAccent.withValues(alpha: 0.6) : null),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                dup
                    ? '공통 발문 중복 제거안 (승인 시 문제은행 문항에 저장)'
                    : hasProposal
                        ? '수정안 (승인 시 문제은행 문항에 저장)'
                        : dirty
                            ? '본문·선지·그림 직접 수정 중 (위 저장 버튼을 누르면 DB에 반영)'
                            : '현재 DB 저장 본문·선지·그림 (추가로 고치면 위 저장 버튼이 켜집니다)',
                style: const TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w800),
              ),
              if (dup)
                _pillBadge('규칙 판정: 공통 발문 중복', _kAccent)
              else if (hasProposal)
                _pillBadge(
                  item.fixProposalIsCommonStemDup
                      ? '규칙 제안'
                      : fromFixPass
                          ? '교재 원본 대조 제안'
                          : '2단계 검수 제안',
                  _kAccent,
                ),
              if (fromFixPass && fp['text_matches_original'] == true) _pillBadge('본문·선지는 원본과 같음', _kTextMuted),
              if (fromFixPass && '${fp['engine_issue'] ?? ''}'.trim().isNotEmpty)
                _pillBadge('엔진 의심: ${fp['engine_issue']}', _kWarn),
              if (dirty) _pillBadge('저장 전 변경 있음', _kWarn) else _pillBadge('현재 입력칸 = DB 저장본', _kTextMuted),
              if (fp['applied_at'] != null && !dirty) _pillBadge('✓ 수정안 DB 반영 완료', _kAccent),
            ],
          ),
          if (dup) ...[
            const SizedBox(height: 6),
            Text(
              item.commonStemFix?.commonStem != null
                  ? '공통 발문에 이 문항의 본문까지 통째로 들어 있어 학생 화면에 지시문·답란이 두 번 보입니다. '
                      '공통 발문은 첫 문단(지시문)만 남기고(같은 세트 문항 모두에 적용), 개별 발문은 지시문을 뺀 나머지로 채워 두었습니다.'
                  : '공통 발문 "${item.commonStem.length > 60 ? '${item.commonStem.substring(0, 60)}…' : item.commonStem}" 이(가) 개별 발문에도 들어 있어 '
                      '학생 화면에 두 번 보입니다. 편집기에는 공통 부분을 뺀 본문을 채워 두었습니다. 공통 발문은 그대로 유지됩니다.',
              style: const TextStyle(color: _kTextSub, fontSize: 12, height: 1.35),
            ),
          ] else if (reason.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              fp['applied_at'] != null && !dirty ? 'DB 반영된 수정 내역: $reason' : '제안 이유: $reason',
              style: const TextStyle(color: _kTextSub, fontSize: 12, height: 1.35),
            ),
          ],
          if (item.isSetQuestion) ...[
            const SizedBox(height: 10),
            const Text(
              '공통 발문 (세트 전체가 공유 · 바꾸면 같은 세트 문항 모두에 적용)',
              style: TextStyle(color: _kTextSub, fontSize: 12, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _commonStemEditCtrl,
              minLines: 1,
              maxLines: 5,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(color: _kText, fontSize: 13, height: 1.4),
              decoration: _inputDecoration('공통 발문'),
            ),
            if (_commonStemEditDirty(item)) ...[
              const SizedBox(height: 6),
              Text(
                '현재 저장값: ${item.commonStem.trim().isEmpty ? '(비어 있음)' : item.commonStem.trim()}',
                style: const TextStyle(color: _kTextMuted, fontSize: 11.5, height: 1.35),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
          const SizedBox(height: 10),
          Text(
            item.isSetQuestion ? '개별 발문 (공통 발문 제외 · 마크업 [문단]·\$수식\$ 유지)' : '발문 (마크업 [문단]·\$수식\$ 유지)',
            style: const TextStyle(color: _kTextSub, fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _stemEditCtrl,
            minLines: 2,
            maxLines: 8,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(color: _kText, fontSize: 13, height: 1.4),
            decoration: _inputDecoration('발문'),
          ),
          if (item.stem.trim() != _stemEditCtrl.text.trim()) ...[
            const SizedBox(height: 6),
            Text(
              '현재 저장값: ${item.stem.trim().isEmpty ? '(비어 있음)' : item.stem.trim()}',
              style: const TextStyle(color: _kTextMuted, fontSize: 11.5, height: 1.35),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 10),
          const Text('선지 (한 줄에 하나, "① 본문" 형식 · 없으면 비움)', style: TextStyle(color: _kTextSub, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          TextField(
            controller: _choicesEditCtrl,
            minLines: 1,
            maxLines: 6,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(color: _kText, fontSize: 13, height: 1.4),
            decoration: _inputDecoration('① ...\n② ...'),
          ),
          if (item.hasFigures || _figureLayoutEdit.isNotEmpty || item.hasPendingFigureProposal) ...[
            const SizedBox(height: 12),
            _buildFigureLayoutEditor(item),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _saving || _runningReview || !item.canRenderOriginal ? null : () => unawaited(_fixPassSingle(item)),
                style: _outlineButtonStyle(color: _kAccent),
                icon: const Icon(Icons.compare_rounded, size: 16, color: _kAccent),
                label: Text(item.fixPassAt == null ? '원본 대조로 AI가 바로 고치기' : '원본 대조로 AI가 다시 고치기'),
              ),
              OutlinedButton.icon(
                onPressed: _saving || !_svc.hasGateway || !dirty ? null : () => unawaited(_previewProblemFix(item)),
                style: _outlineButtonStyle(color: _kBlue),
                icon: const Icon(Icons.preview_rounded, size: 16, color: _kBlue),
                label: const Text('본문·선지 V2 미리보기 (수정 시 활성화)'),
              ),
              OutlinedButton.icon(
                onPressed: _saving || _runningReview || !dirty ? null : () => unawaited(_applyProblemFix(item, approve: false)),
                style: _outlineButtonStyle(color: _kAccent),
                icon: const Icon(Icons.save_outlined, size: 16, color: _kAccent),
                label: const Text('수정만 적용 (재렌더 후 원본 대조)'),
              ),
              if (hasProposal || dirty)
                TextButton.icon(
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                            _stemEditCtrl.text = item.stem;
                            _commonStemEditCtrl.text = item.commonStem;
                            _choicesEditCtrl.text = _choicesToLines(item.rawChoices);
                            _figureLayoutEdit = figureLayoutItems(item.pbFigureLayout);
                            _useFigureCrops = false;
                          }),
                  icon: const Icon(Icons.restore_rounded, size: 16, color: _kTextSub),
                  label: const Text('현재 저장값으로 되돌리기', style: TextStyle(color: _kTextSub)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static const _kFigurePositions = <String, String>{
    'below-stem': '본문 아래',
    'inline-right': '본문 오른쪽(글 감싸기)',
    'inline-left': '본문 왼쪽(글 감싸기)',
    'between-stem-choices': '본문·선지 사이',
    'above-choices': '선지 바로 위',
    'inline-text': '글 줄 안',
  };
  static const _kFigureAnchors = <String, String>{'left': '왼쪽', 'center': '가운데', 'right': '오른쪽', 'top': '위'};

  /// 그림 크기·위치(figure_layout) 편집. 원본 대조 수정안이 있으면 원본에서 잰 폭(글자 대비)·위치로 채워져 있다.
  Widget _buildFigureLayoutEditor(TextbookProblemReviewItem item) {
    final assets = orderedFigureAssets(item.pbFigureAssets);
    final crops = _pendingFigureCrops(item);
    final removals = item.proposedFigureRemovals;
    final unslotted = item.unslottedFigureCrops;
    final measure = item.fixProposal['figure_measure'] is Map ? item.fixProposal['figure_measure'] as Map : const {};
    final emPx = (measure['em_px'] as num?)?.toDouble();
    final markers = figureMarkerCount(_stemEditCtrl.text);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _innerDecoration(borderColor: item.hasPendingFigureProposal ? _kAccent.withValues(alpha: 0.5) : null),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('그림 크기·위치', style: TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w800)),
              _pillBadge(
                '그림 자산 ${assets.length}개 · 본문 그림 자리 $markers개',
                assets.length + crops.length == markers ? _kTextMuted : _kWarn,
              ),
              if (item.hasPendingFigureProposal) _pillBadge('원본에서 잰 값', _kAccent),
              if (emPx != null) _pillBadge('원본 글자 1em ≈ ${emPx.toStringAsFixed(1)}px', _kTextMuted),
            ],
          ),
          if (crops.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildBanner(
              '원본에서 잘라 새로 등록할 그림: '
              '${crops.map((c) => '${c['figure_index']}번(${c['reason'] == 'missing' ? '누락' : '잘림'})').join(', ')}'
              ' — 승인하거나 적용하면 교재 본문 PDF에서 잘라 문제은행 그림으로 등록합니다.',
              _kBlue,
              Icons.crop_rounded,
            ),
          ],
          if (removals.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildBanner(
              '원본에서 문항 그림이 아닌 것으로 보이는 그림: ${removals.map((i) => '$i번').join(', ')}'
              ' — 풀이 안내(해)·해설·다른 문항의 그림이면 빼세요. 자동으로 빼지 않습니다.',
              _kWarn,
              Icons.hide_image_outlined,
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _saving || _runningReview ? null : () => unawaited(_removeProposedFigures(item, removals)),
                icon: const Icon(Icons.hide_image_outlined, size: 16),
                label: Text('이 그림 빼기(${removals.map((i) => '$i번').join(', ')})'),
              ),
            ),
          ],
          if (unslotted.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildBanner(
              '확인 필요 — 원본에는 있지만 본문에 그림 자리가 없어 자동으로 붙이지 않은 그림: '
              '${unslotted.map((c) => '${c['figure_index']}번').join(', ')}'
              ' — 풀이 안내(해) 속 그림이면 그대로 두고, 문항 그림이 맞으면 붙이세요.',
              _kWarn,
              Icons.add_photo_alternate_outlined,
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _saving || _runningReview ? null : () => unawaited(_addUnslottedFigures(item, unslotted)),
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
                label: Text('문항 그림이 맞음 — 붙이기(${unslotted.map((c) => '${c['figure_index']}번').join(', ')})'),
              ),
            ),
          ],
          if (_figureLayoutEdit.isEmpty) ...[
            const SizedBox(height: 8),
            Text(
              item.canRenderOriginal
                  ? '저장된 그림 배치가 없어 기존 배율로 표시됩니다. "교재 원본 대조 수정안 만들기"를 누르면 원본에서 잰 크기·위치로 채웁니다.'
                  : '저장된 그림 배치가 없고 원본 좌표도 없어 기존 배율로 표시됩니다.',
              style: const TextStyle(color: _kTextMuted, fontSize: 12, height: 1.35),
            ),
          ],
          for (var i = 0; i < _figureLayoutEdit.length; i++) _figureLayoutRow(i),
          if (_figureLayoutEdit.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Text(
              '폭은 글자 크기(em) 기준입니다. 그림 배치는 텍스트 미리보기에 나오지 않으니 "수정만 적용"으로 V2 카드를 다시 찍어 원본과 대조하세요.',
              style: TextStyle(color: _kTextMuted, fontSize: 11.5, height: 1.35),
            ),
          ],
        ],
      ),
    );
  }

  Widget _figureLayoutRow(int i) {
    final it = _figureLayoutEdit[i];
    final w = (it['widthEm'] as num?)?.toDouble() ?? 20;
    final pos = '${it['position'] ?? 'below-stem'}';
    final anchor = '${it['anchor'] ?? 'center'}';
    void update(Map<String, dynamic> patch) => setState(() {
          _figureLayoutEdit = [
            for (var j = 0; j < _figureLayoutEdit.length; j++) j == i ? {..._figureLayoutEdit[j], ...patch} : _figureLayoutEdit[j],
          ];
        });
    double clampW(double v) => (v.clamp(2.0, 50.0) * 2).roundToDouble() / 2;
    const style = TextStyle(color: _kText, fontSize: 12.5);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _pillBadge('${it['assetKey']}', _kBlue),
          IconButton(
            tooltip: '폭 줄이기',
            visualDensity: VisualDensity.compact,
            onPressed: _saving ? null : () => update({'widthEm': clampW(w - 1)}),
            icon: const Icon(Icons.remove_rounded, size: 16, color: _kTextSub),
          ),
          Text('폭 ${w.toStringAsFixed(1)}em', style: style),
          IconButton(
            tooltip: '폭 늘리기',
            visualDensity: VisualDensity.compact,
            onPressed: _saving ? null : () => update({'widthEm': clampW(w + 1)}),
            icon: const Icon(Icons.add_rounded, size: 16, color: _kTextSub),
          ),
          DropdownButton<String>(
            value: _kFigurePositions.containsKey(pos) ? pos : 'below-stem',
            dropdownColor: _kPanelBg,
            style: style,
            underline: const SizedBox.shrink(),
            items: [
              for (final e in _kFigurePositions.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: _saving ? null : (v) => v == null ? null : update({'position': v}),
          ),
          DropdownButton<String>(
            value: _kFigureAnchors.containsKey(anchor) ? anchor : 'center',
            dropdownColor: _kPanelBg,
            style: style,
            underline: const SizedBox.shrink(),
            items: [
              for (final e in _kFigureAnchors.entries) DropdownMenuItem(value: e.key, child: Text('정렬 ${e.value}')),
            ],
            onChanged: _saving ? null : (v) => v == null ? null : update({'anchor': v}),
          ),
        ],
      ),
    );
  }

  Widget _visualTagChip(String label, {required bool selected, required VoidCallback onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? _kChipSelected : _kFieldBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? _kAccent : _kBorder, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? Icons.check_circle_rounded : Icons.add_circle_outline_rounded,
              size: 14,
              color: selected ? _kAccent : _kTextMuted,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: selected ? _kText : _kTextSub,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pillBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 0.5),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildBanner(String text, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(_kInnerRadius),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: _kText, fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  ButtonStyle _primaryButtonStyle() => ElevatedButton.styleFrom(
        backgroundColor: _kAccent,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      );

  ButtonStyle _outlineButtonStyle({required Color color}) => OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.6)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      );

  InputDecoration _inputDecoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: _kTextMuted, fontSize: 13, fontWeight: FontWeight.w600),
        filled: true,
        fillColor: _kFieldBg,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_kInnerRadius),
          borderSide: const BorderSide(color: _kBorder, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_kInnerRadius),
          borderSide: const BorderSide(color: _kAccent, width: 1),
        ),
      );
}
