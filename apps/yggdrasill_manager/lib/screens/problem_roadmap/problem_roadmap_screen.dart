import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/textbook_problem_review_service.dart';
import '../../services/textbook_review_solution_image_service.dart';
import '../problem_bank/widgets/problem_bank_question_card.dart';
import 'textbook_review_engine_hold_panel.dart';

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

const List<String> kStandardVisualTags = [
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

const int _kReviewChunkSize = 6;
const int _kRenderCheckChunkSize = 4;
const int _kFixChunkSize = 3;

class ProblemRoadmapScreen extends StatefulWidget {
  const ProblemRoadmapScreen({super.key, this.service});

  final TextbookProblemReviewService? service;

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

  /// 필터: 0 전체, 1 확인필요(오류·불일치), 2 새초안제안, 3 미검수, 4 승인완료, 5 엔진 보류, 6 승인 후 원본 차이
  int _filterTab = 0;

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

  /// 수학 일괄에서 다시 푼 문항의 그때 내용(problemTextSignature). 내용이 그대로면 이 앱 실행에서 다시 풀지 않는다.
  final Map<String, String> _mathResolvedSig = {};
  List<String> _editingVisualTags = const [];
  List<Map<String, dynamic>> _editingAlternatives = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadUnits());
  }

  @override
  void dispose() {
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

  List<TextbookReviewUnitScope> get _unitsForSelectedBook => [
        for (final u in _units)
          if ('${u.bookId}|${u.gradeLabel}' == _selectedBookKey) u,
      ];

  Future<void> _loadUnits() async {
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
          final currentKey = _selectedScope?.key;
          final matched = currentKey != null ? list.where((u) => u.key == currentKey).firstOrNull : null;
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

  Future<void> _loadItems(TextbookReviewUnitScope scope, {bool reloadPreviews = true}) async {
    setState(() {
      _loadingItems = true;
      _error = null;
    });
    try {
      final items = await _svc.fetchUnitItems(scope);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loadingItems = false;
        if (_filterTab == 5 && !items.any((x) => x.isEngineHeld)) _filterTab = 0;
        if (_filterTab == 6 && !items.any((x) => x.approvedButDiffers)) _filterTab = 0;
        final cur = _selectedCropId != null ? items.where((x) => x.cropId == _selectedCropId).firstOrNull : null;
        final pick = cur ?? items.where((x) => x.hasIssue).firstOrNull ?? items.firstOrNull;
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
    _answerEditCtrl.text = item.mathStatus == 'issue'
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
        text: '${item.displayAnswer}\n${item.primarySolutionText}',
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
    var totalProcessed = 0;
    var renderChecked = 0;
    try {
      // V2 문항 카드 URL이 있어야 학생 시점 품질 검수가 된다. 썸네일 로드를 기다린다.
      if (_previewLoad != null) await _previewLoad;
      if (_previewUrlsByCropId.isEmpty && _items.isNotEmpty) {
        await _loadEnginePreviews(scope, _items);
      }

      // 이번 실행에서 이미 보낸 문항은 다시 고르지 않는다(전사 실패 등으로 대상에 남아도 같은 실행에서 반복하지 않음).
      final sentThisRun = <String>{};
      for (var round = 0; round < 60; round += 1) {
        if (!mounted || _stopRequested) break;
        final todo = (forceRerun ? _items : _items.where((x) => x.isReviewTodo))
            .where((x) => !sentThisRun.contains(x.cropId))
            .toList();
        if (todo.isEmpty) break;
        final chunk = todo.take(_kReviewChunkSize).toList();
        sentThisRun.addAll(chunk.map((x) => x.cropId));
        final total = _items.length;
        setState(() {
          _runProgress =
              '검수 진행 중: ${total - todo.length} / $total 문항 완료 · 이번 묶음 ${chunk.map((x) => x.problemNumber).join(', ')}번 — 해설 영역 잘라내는 중...';
        });
        final images = await _svc.prepareChunkImages(
          scope: scope,
          items: chunk,
          previewUrlsByCropId: _previewUrlsByCropId,
        );
        if (!mounted || _stopRequested) break;
        setState(() {
          _runProgress =
              '검수 진행 중: ${total - todo.length} / $total 문항 완료 · 이번 묶음 ${chunk.length}문항 — 원본 해설 전사 · 블라인드 풀이 · 학생 시점 품질 검수 중...';
        });
        final res = await _svc.runReviewChunk(
          scope,
          chunkSize: _kReviewChunkSize,
          forceRerun: forceRerun,
          cropIds: [for (final x in chunk) x.cropId],
          images: images,
        );
        final processed = (res['processed'] as num?)?.toInt() ?? 0;
        totalProcessed += processed;
        if (!mounted) return;
        await _loadItems(scope, reloadPreviews: false);
        if (res['done'] == true || processed <= 0) break;
      }

      // 2차: 정답·해설 카드를 V2로 찍어 학생 시점 렌더 검수(교재 원본과 직접 대조)
      if (mounted && !_stopRequested && _svc.hasGateway) {
        renderChecked = await _runRenderCheckPass(scope);
      }

      // 3차(1회차 마무리):
      // - 이상 없는(clean) 수학·품질 문항(그림 없는 문항)은 즉시 자동 승인
      // - 렌더 엔진 문제(engine)는 즉시 자동 보류(held)
      // - 정답 이상·품질 오류·그림 문항은 본문 PDF + 정답/해설 PDF 를 읽어 통합 수정안(fix_proposal)을 만들어 제시한다(DB 반영은 일괄 처리에서).
      var autoMathApproved = 0;
      var autoQualApproved = 0;
      var autoHeld = 0;
      var fixProposed = 0;
      if (mounted && !_stopRequested) {
        final cleanMathIds = [for (final x in _items) if (x.mathStatus == 'clean') x.cropId];
        if (cleanMathIds.isNotEmpty) {
          autoMathApproved = await _svc.approveAxis(cleanMathIds, 'math');
        }
        final cleanQualIds = [for (final x in _items) if (x.qualityStatus == 'clean' && !x.hasFigures) x.cropId];
        if (cleanQualIds.isNotEmpty) {
          autoQualApproved = await _svc.approveAxis(cleanQualIds, 'quality');
        }
        final engineOnly = [
          for (final x in _items)
            if (x.aiSuspectsEngine && !x.hasFigures && !x.commonStemDuplicated && !x.hasPendingFixProposal) x,
        ];
        if (engineOnly.isNotEmpty) {
          autoHeld = await _svc.setEngineHold([for (final x in engineOnly) x.cropId], hold: true);
        }
        if (mounted) await _loadItems(scope, reloadPreviews: false);

        final fixTargets = [
          for (final x in _items)
            if (!x.isEngineHeld &&
                x.canRenderOriginal &&
                (x.needsFixPass || x.mathStatus == 'issue' || x.qualityStatus == 'issue' || (x.hasFigures && x.fixPassAt == null)))
              x,
        ];
        if (fixTargets.isNotEmpty) {
          fixProposed = await _runFixPass(scope, fixTargets);
          if (mounted) await _loadItems(scope, reloadPreviews: false);
        }
      }

      if (!mounted) return;
      await _loadUnits();
      final firstIssue = _items.where((x) => x.hasIssue).firstOrNull;
      if (firstIssue != null) _selectItem(firstIssue);
      final leftMath = _items.where((x) => x.mathStatus == 'issue').length;
      final leftQual = _items.where((x) => x.qualityStatus == 'issue' && !x.isEngineHeld).length;
      final heldCount = _items.where((x) => x.isEngineHeld).length;
      setState(() {
        _notice = _stopRequested
            ? '요청에 따라 일시정지했습니다 ($totalProcessed문항 검수 완료).'
            : '1회차 전체 검수가 완료되었습니다 '
                '(처리 $totalProcessed · V2 검수 $renderChecked'
                '${autoMathApproved + autoQualApproved > 0 ? ' · 정상 자동승인 수학 $autoMathApproved/품질 $autoQualApproved' : ''}'
                '${autoHeld > 0 || heldCount > 0 ? ' · 엔진 보류 $heldCount' : ''}'
                '${fixProposed > 0 ? ' · 원본/해설 PDF 대조 수정안 $fixProposed문항 제시' : ''}'
                ' · 남은 확인 대상 수학 $leftMath/품질 $leftQual). '
                '수정안을 확인하신 뒤 "수학 일괄 처리" · "품질 일괄 처리"를 누르면 DB 반영 후 해당 문항들만 재검수합니다.';
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

  /// 아직 V2 렌더 검수를 안 한 문항을 묶어 정답+해설 카드를 찍고 ai_think 에 학생 시점 판정을 맡긴다.
  Future<int> _runRenderCheckPass(TextbookReviewUnitScope scope, {List<TextbookProblemReviewItem>? only}) async {
    var checked = 0;
    final targets = (only ?? _items.where((x) => x.needsRenderCheck)).toList();
    if (targets.isEmpty) return 0;
    for (var i = 0; i < targets.length; i += _kRenderCheckChunkSize) {
      if (!mounted || _stopRequested) break;
      final chunk = targets.skip(i).take(_kRenderCheckChunkSize).toList();
      setState(() {
        _runProgress = 'V2 렌더 검수: ${i + 1}~${i + chunk.length} / ${targets.length} 문항 — 정답+해설 카드를 V2로 찍는 중...';
      });
      final payload = <Map<String, dynamic>>[];
      for (final it in chunk) {
        final problemUrl = _previewUrlsByCropId[it.cropId];
        String solUrl = '';
        if (it.primarySolutionText.isNotEmpty || it.displayAnswer.isNotEmpty) {
          solUrl = await _renderCard(
            it,
            kind: 'answer_solution',
            text: '${it.displayAnswer}\n${it.primarySolutionText}',
            build: () => _svc.renderAnswerSolutionCard(
              academyId: scope.academyId,
              item: it,
              solutionText: it.primarySolutionText,
              solutionKind: it.primarySolutionKind,
            ),
          );
        }
        if ((problemUrl ?? '').isEmpty && solUrl.isEmpty) continue;
        // 교재 원본(본문 PDF 문항 영역)을 같이 보내 V2 카드와 직접 대조한다(글자·그림 위치·그림 크기).
        final original = (problemUrl ?? '').isEmpty ? const <String, dynamic>{} : await _svc.originalImagesJson(scope, it);
        payload.add({
          'crop_id': it.cropId,
          if ((problemUrl ?? '').isNotEmpty) 'problem_url': problemUrl,
          if (solUrl.isNotEmpty) 'answer_solution_url': solUrl,
          'solution_kind': it.primarySolutionKind,
          'is_fill_in_blank': it.isFillInBlank,
          ...original,
        });
      }
      if (payload.isEmpty) continue;
      if (!mounted) break;
      setState(() {
        _runProgress = 'V2 렌더 검수: ${i + 1}~${i + chunk.length} / ${targets.length} 문항 — 교재 원본과 대조해 학생 시점으로 읽히는지 판정 중...';
      });
      final res = await _svc.runRenderCheck(academyId: scope.academyId, items: payload);
      checked += (res['processed'] as num?)?.toInt() ?? 0;
    }
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

  /// 2차 일괄 처리:
  /// - 수학 일괄 처리: 제시된 정답 수정안(또는 손질한 정답)을 채점 정답 + 문제은행에 반영하고 해당 문항들만 재검수 후 승인한다.
  /// - 품질 일괄 처리: 제시된 본문·공통발문·선지·유형·그림 배치/크롭 수정안을 문제은행에 반영하고 해당 문항들만 V2 재렌더·재검수 후 승인한다.
  Future<void> _bulkApproveClean(String axis) async {
    final scope = _selectedScope;
    if (scope == null) return;
    setState(() {
      _saving = true;
      _notice = null;
    });
    _bulkErrors.clear();
    final notes = <String>[];
    try {
      final extraApprove = <String>[];
      if (axis == 'math') {
        final appliedMath = await _whileRunning(() => _bulkMathFixes(scope, notes));
        extraApprove.addAll(appliedMath);
      } else {
        final appliedQual = await _whileRunning(() => _bulkQualityFixes(scope, notes));
        extraApprove.addAll(appliedQual);
      }
      if (!mounted) return;
      await _loadItems(scope, reloadPreviews: false);
      final ids = <String>{
        for (final it in _items)
          if (axis == 'math'
              ? (it.mathStatus == 'clean' || (it.mathStatus == 'approved' && it.pbAnswerDiffers))
              : (!it.isEngineHeld && it.qualityStatus == 'clean'))
            it.cropId,
        ...extraApprove,
      }.toList();
      final count = ids.isEmpty ? 0 : await _svc.approveAxis(ids, axis);
      if (!mounted) return;
      await _loadItems(scope, reloadPreviews: false);
      await _loadUnits();
      final sel = _items.where((x) => x.cropId == _selectedCropId).firstOrNull;
      if (sel != null) _selectItem(sel);
      final left = axis == 'math'
          ? _items.where((x) => x.mathStatus == 'issue').length
          : _items.where((x) => x.qualityStatus == 'issue' && !x.isEngineHeld).length;
      setState(() {
        _saving = false;
        _notice = '${axis == 'math' ? '수학적 검수' : '품질 검수'} $count문항 승인'
            '${notes.isEmpty ? '' : ' · ${notes.join(' · ')}'}'
            ' · 남은 오류 $left문항'
            '${_bulkErrors.isEmpty ? '' : ' · 실패 ${_bulkErrors.length}문항(${_bulkErrors.first})'}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '일괄 처리 실패: $e';
      });
    }
  }

  /// 수학 2차 일괄:
  /// 1) 아직 원본·해설 PDF 대조 수정안(proposed_answer)이 없는 수학 오류 문항은 수정안 생성 단계를 먼저 돌린다.
  /// 2) 제시된 정답 수정안(선택 문항에 직접 손질한 값이 있으면 그 값)을 DB(textbook_problem_answers + pb_questions)에 반영한다.
  /// 3) 반영된 문항들만 재검수(AI 풀이가 판단불가였으면 현재 본문·원본으로 재풀이)하고 통과 문항을 돌려준다.
  Future<List<String>> _bulkMathFixes(TextbookReviewUnitScope scope, List<String> notes) async {
    final approvedIds = <String>{};
    final selectedId = _selectedCropId;
    final editedSelectedAns = _answerEditCtrl.text.trim();

    // 1) 아직 원본·해설 대조 수정안이 없는 수학 오류 문항이 있으면 먼저 원본+해설 PDF 를 읽어 수정안을 만든다.
    final needProposal = [
      for (final it in _items)
        if (it.mathStatus == 'issue' &&
            it.proposedAnswer == null &&
            !it.solutionAndAiAgreeAgainstExisting &&
            !it.existingConfirmedByAi &&
            !it.existingMatchesSolution &&
            it.canRenderOriginal)
          it,
    ];
    if (needProposal.isNotEmpty) {
      final n = await _runFixPass(scope, needProposal);
      if (n > 0) notes.add('원본·해설 PDF 대조 정답 수정안 $n문항 생성');
      if (!mounted) return const [];
      await _loadItems(scope, reloadPreviews: false);
    }

    // 2) 정답 수정안(또는 합의된 정답·문제은행 동기화 대상)을 DB 에 반영한다.
    final targets = [
      for (final it in _items)
        if (it.mathStatus != 'approved' || it.pbAnswerDiffers || it.hasOpenFindings && it.findings.any((f) => f['axis'] == 'validity' || '${f['check_key']}'.startsWith('load:answer')))
          it,
    ];
    var appliedCount = 0;
    var syncedCount = 0;
    final modifiedIds = <String>{};
    for (var i = 0; i < targets.length; i++) {
      if (!mounted || _stopRequested) break;
      final it = targets[i];
      final ans = (it.cropId == selectedId && editedSelectedAns.isNotEmpty)
          ? editedSelectedAns
          : (it.resolvedMathAnswer ?? it.existingAnswer.trim());
      if (ans.isEmpty || ans == '판단불가') continue;
      setState(() => _runProgress = '수학 수정안 DB 반영 및 재검수: ${i + 1} / ${targets.length} 문항 (${it.problemNumber}번)');
      try {
        final sync = await _svc.saveItemEdit(
          cropId: it.cropId,
          newAnswer: ans,
          aiSolution: it.proposedAiSolution ?? it.aiSolution,
          aiAnswer: it.proposedAiAnswer ?? ans,
          visualTags: it.visualTags,
          solutionTranscribed: it.proposedSolutionTranscribed,
          solutionAnswer: it.proposedSolutionAnswer,
          approveMath: true,
        );
        appliedCount++;
        modifiedIds.add(it.cropId);
        approvedIds.add(it.cropId);
        if (((sync?['changed'] as List?) ?? const []).isNotEmpty) syncedCount++;
      } catch (e) {
        _bulkErrors.add('${it.problemNumber}번 정답 반영: $e');
      }
    }
    if (appliedCount > 0) {
      notes.add('정답 수정안 $appliedCount문항 DB 반영(문제은행 $syncedCount문항 동기화)');
    }

    if (!mounted || _stopRequested) return approvedIds.toList();
    await _loadItems(scope, reloadPreviews: false);

    // 3) 만약 아직도 수학 오류로 남은 문항이 있으면 지금 본문·원본으로 재풀이한다.
    final stillNeedResolve = [
      for (final it in _items)
        if (it.mathStatus == 'issue' && !modifiedIds.contains(it.cropId)) it,
    ];
    if (stillNeedResolve.isNotEmpty) {
      final resolved = await _mathResolvePass(scope, only: stillNeedResolve);
      if (resolved > 0) {
        notes.add('남은 수학 문항 $resolved문항 재풀이');
        await _loadItems(scope, reloadPreviews: false);
        for (final it in _items) {
          if (it.mathStatus == 'issue' && it.resolvedMathAnswer != null) {
            try {
              await _svc.saveItemEdit(
                cropId: it.cropId,
                newAnswer: it.resolvedMathAnswer,
                aiSolution: it.proposedAiSolution ?? it.aiSolution,
                aiAnswer: it.proposedAiAnswer ?? it.resolvedMathAnswer,
                visualTags: it.visualTags,
                approveMath: true,
              );
              approvedIds.add(it.cropId);
            } catch (_) {}
          }
        }
      }
    }
    return approvedIds.toList();
  }

  /// 품질 2차 일괄:
  /// 1) 선택 문항의 직접 편집분 + 규칙 수정(공통 발문 중복·문항 유형)을 먼저 적용한다.
  /// 2) 아직 수정안이 없는 품질 오류·그림 문항은 원본+해설 PDF 대조 수정안을 만든다.
  /// 3) 준비된 수정안(본문·공통발문·선지·그림 배치·원본 크롭 그림)을 pb_questions 에 일괄 반영한다.
  /// 4) 반영된 문항들만 V2 카드를 다시 찍어 원본 대조 재검수를 돌리고, 그림 비율 재조정 및 엔진 문제 자동 보류(held) 후 통과 문항을 승인한다.
  Future<List<String>> _bulkQualityFixes(TextbookReviewUnitScope scope, List<String> notes) async {
    final approvedQualIds = <String>{};
    final touchedCropIds = <String>{};

    // 0) 현재 선택된 문항에 운영자가 직접 손질한 편집 내용이 있으면 먼저 반영한다.
    final sel = _items.where((x) => x.cropId == _selectedCropId).firstOrNull;
    if (sel != null && !sel.isEngineHeld && _problemEditDirty(sel)) {
      try {
        final stem = _stemEditCtrl.text.trim();
        final choices = _linesToChoices(_choicesEditCtrl.text);
        final stemChanged = stem != sel.stem.trim();
        final choicesChanged = _choicesToLines(choices) != _choicesToLines(sel.rawChoices);
        final commonChanged = _commonStemEditDirty(sel);
        final crops = _pendingFigureCrops(sel);
        final layoutChanged = _figureLayoutDirty(sel) || crops.isNotEmpty;
        await _applyFixFor(
          scope,
          sel,
          stem: stemChanged ? stem : null,
          choices: choicesChanged ? choices : null,
          commonStem: commonChanged ? _commonStemEditCtrl.text.trim() : null,
          figureLayout: layoutChanged ? _editedFigureLayout(sel) : null,
          figureCrops: crops,
          note: '운영자 손질 수정안 반영',
        );
        touchedCropIds.add(sel.cropId);
      } catch (e) {
        _bulkErrors.add('${sel.problemNumber}번 직접 수정: $e');
      }
    }

    final (fixed, approvedByFix, again) = await _applyCommonStemDupFixes(scope);
    if (fixed > 0) notes.add('공통 발문 중복 $fixed문항 수정($approvedByFix문항 바로 승인)');
    touchedCropIds.addAll(again);
    final kinds = await _applyQuestionKindFixes();
    if (kinds > 0) notes.add('문항 유형 표시 $kinds문항 수정');

    var recheck = <String>{...touchedCropIds};
    var proposed = 0;
    var applied = 0;
    var heldEngine = 0;
    final checked = <String>{};
    final resized = <String>{};
    for (var round = 0; round < 2; round++) {
      if (!mounted || _stopRequested) break;
      await _loadItems(scope, reloadPreviews: false);

      final fixTargets = [for (final x in _items) if (x.needsFixPass) x];
      if (fixTargets.isNotEmpty) {
        proposed += await _runFixPass(scope, fixTargets);
        await _loadItems(scope, reloadPreviews: false);
      }
      if (!mounted || _stopRequested) break;

      final done = await _applyPendingProposals(scope);
      applied += done.length;
      recheck.addAll(done);
      touchedCropIds.addAll(done);

      // 순수 렌더 엔진 문제(본문·그림 수정 대상이 아니고 엔진 증상만 있는 문항)는 보류(held)로 분리한다.
      await _loadItems(scope, reloadPreviews: false);
      final pureEngines = [
        for (final x in _items)
          if (!x.isEngineHeld &&
              x.qualityStatus == 'issue' &&
              (x.aiSuspectsEngine || '${x.fixProposal['kind'] ?? ''}' == 'engine') &&
              !_textProposalUsable(x) &&
              !x.hasPendingFigureProposal &&
              !x.hasFigures)
            x,
      ];
      if (pureEngines.isNotEmpty) {
        heldEngine += await _svc.setEngineHold([for (final x in pureEngines) x.cropId], hold: true);
        await _loadItems(scope, reloadPreviews: false);
      }

      // 바뀐 문항 + 아직 교재 원본과 대조하지 않은 미승인 문항만 재검수한다.
      final checkIds = <String>{
        ...recheck,
        for (final x in _items)
          if (!x.isEngineHeld &&
              (x.qualityStatus == 'issue' || x.qualityStatus == 'clean') &&
              (!x.originalCompared || x.renderCheckedAt == null) &&
              x.canRenderOriginal)
            x.cropId,
      };
      if (checkIds.isNotEmpty && mounted && !_stopRequested) {
        final changed = [for (final x in _items) if (recheck.contains(x.cropId)) x];
        if (changed.isNotEmpty) await _loadEnginePreviews(scope, changed, merge: true);
        await _runRenderCheckPass(scope, only: [for (final x in _items) if (checkIds.contains(x.cropId)) x]);
        checked.addAll(checkIds);
      }
      recheck = {};
      if (!mounted || _stopRequested) break;

      // 그림 크기가 원본과 다르게 나온 문항: 잰 비율만큼 폭을 고쳐 다시 대조
      final sized = await _resizeFiguresFromRenderCheck();
      if (sized.isNotEmpty) {
        resized.addAll(sized);
        touchedCropIds.addAll(sized);
        await _loadItems(scope, reloadPreviews: false);
        final sizedItems = [for (final x in _items) if (sized.contains(x.cropId)) x];
        await _loadEnginePreviews(scope, sizedItems, merge: true);
        await _runRenderCheckPass(scope, only: sizedItems);
      }
      if (!mounted) break;
      await _loadItems(scope, reloadPreviews: false);

      // 재검수 뒤에도 엔진 문제로 판정된 문항은 자동 보류(held), 수정안이 이미 적용되어 원본과 맞춰진 문항은 승인 대상으로 모은다.
      final postEngines = [
        for (final x in _items)
          if (!x.isEngineHeld && x.qualityStatus == 'issue' && x.aiSuspectsEngine && !x.hasFigures) x,
      ];
      if (postEngines.isNotEmpty) {
        heldEngine += await _svc.setEngineHold([for (final x in postEngines) x.cropId], hold: true);
        await _loadItems(scope, reloadPreviews: false);
      }
      if (!_items.any((x) => x.needsFixPass)) break;
    }

    // 수정안을 DB에 반영하고 V2 재검수를 마친 문항(엔진 보류 제외)과, 본문이 이미 원본과 일치하는 문항은 승인한다.
    for (final x in _items) {
      if (x.isEngineHeld) continue;
      if (x.qualityStatus == 'clean') {
        approvedQualIds.add(x.cropId);
      } else if (x.qualityStatus == 'issue' &&
          (touchedCropIds.contains(x.cropId) ||
              x.fixAppliedAt != null ||
              x.fixProposal['text_matches_original'] == true)) {
        approvedQualIds.add(x.cropId);
      }
    }

    // 한 문항에 품질 문제와 수학 문제가 겹쳐 있었던 경우: 본문·공통발문이 복원된 문항에 확정 정답이 있으면 수학도 함께 해결한다.
    var healedMath = 0;
    for (final x in _items) {
      if (x.mathStatus == 'issue' && x.resolvedMathAnswer != null) {
        try {
          await _svc.saveItemEdit(
            cropId: x.cropId,
            newAnswer: x.resolvedMathAnswer,
            aiSolution: x.proposedAiSolution ?? x.aiSolution,
            aiAnswer: x.proposedAiAnswer ?? x.resolvedMathAnswer,
            visualTags: x.visualTags,
            solutionTranscribed: x.proposedSolutionTranscribed,
            solutionAnswer: x.proposedSolutionAnswer,
            approveMath: true,
          );
          healedMath++;
        } catch (_) {}
      }
    }

    if (proposed > 0) notes.add('원본 대조 수정안 $proposed문항');
    if (applied > 0) notes.add('수정안 $applied문항 DB 반영');
    if (checked.isNotEmpty) notes.add('변경 문항 재검수 ${checked.length}문항');
    if (resized.isNotEmpty) notes.add('그림 크기 자동조정 ${resized.length}문항');
    if (heldEngine > 0) notes.add('렌더 엔진 보류 $heldEngine문항');
    if (healedMath > 0) notes.add('복합 오류 수학 정답 $healedMath문항 함께 해결');
    return approvedQualIds.toList();
  }

  /// 규칙으로 끝나지 않는 수학 오류 중 이 앱 실행에서 같은 내용으로 아직 다시 풀지 않은 문항
  List<TextbookProblemReviewItem> get _mathResolveTargets => [
        for (final it in _items)
          if (it.needsMathResolve && _mathResolvedSig[it.cropId] != it.problemTextSignature) it,
      ];

  /// 수학 일괄의 재풀이(math_only). 지금 본문·교재 원본으로 다시 풀어 채점 정답·해설 정답과 대조한다.
  /// 수학 결과만 바뀌고 품질 판정·승인은 그대로다. 반환: 다시 푼 문항 수
  Future<int> _mathResolvePass(TextbookReviewUnitScope scope, {List<TextbookProblemReviewItem>? only}) async {
    final targets = only ?? _mathResolveTargets;
    if (targets.isEmpty) return 0;
    if (_previewLoad != null) await _previewLoad;
    var done = 0;
    for (var i = 0; i < targets.length; i += _kReviewChunkSize) {
      if (!mounted || _stopRequested) break;
      final chunk = targets.skip(i).take(_kReviewChunkSize).toList();
      final range = '${i + 1}~${i + chunk.length} / ${targets.length} 문항';
      setState(() => _runProgress = '수학 재풀이: $range — 본문 PDF에서 교재 원본을 찍는 중...');
      final images = await _svc.prepareChunkImages(
        scope: scope,
        items: chunk,
        previewUrlsByCropId: _previewUrlsByCropId,
        onlyMissingSolutions: true,
      );
      if (!mounted || _stopRequested) break;
      setState(() => _runProgress = '수학 재풀이: $range — 지금 본문과 교재 원본으로 다시 풀고 채점 정답·해설 정답과 대조하는 중...');
      try {
        final res = await _svc.runReviewChunk(
          scope,
          chunkSize: chunk.length,
          mathOnly: true,
          cropIds: [for (final x in chunk) x.cropId],
          images: images,
        );
        done += (res['processed'] as num?)?.toInt() ?? 0;
        for (final x in chunk) {
          _mathResolvedSig[x.cropId] = x.problemTextSignature;
        }
      } catch (e) {
        _bulkErrors.add('${chunk.map((x) => x.problemNumber).join(',')}번 재풀이: $e');
      }
    }
    return done;
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
    for (var i = 0; i < targets.length; i += _kFixChunkSize) {
      if (!mounted || _stopRequested) break;
      final chunk = targets.skip(i).take(_kFixChunkSize).toList();
      final range = '${i + 1}~${i + chunk.length} / ${targets.length} 문항';
      setState(() => _runProgress = '원본 대조 수정안: $range — 본문·정답 PDF에서 원본을 찍는 중...');
      final images = await _svc.prepareChunkImages(
        scope: scope,
        items: chunk,
        previewUrlsByCropId: _previewUrlsByCropId,
        includeSolution: true,
      );
      final ids = <String>[];
      for (final it in chunk) {
        if (images[it.cropId]?.original != null) {
          ids.add(it.cropId);
        } else {
          _bulkErrors.add('${it.problemNumber}번: 본문 PDF 원본을 찍지 못함');
        }
      }
      if (ids.isEmpty || !mounted) continue;
      setState(() => _runProgress = '원본 대조 수정안: $range — 원본과 저장된 본문·선지·그림을 대조해 수정안을 만드는 중...');
      try {
        final res = await _svc.runFixPass(scope, cropIds: ids, images: {for (final id in ids) id: images[id]!});
        done += (res['processed'] as num?)?.toInt() ?? 0;
      } catch (e) {
        _bulkErrors.add('${chunk.map((x) => x.problemNumber).join(',')}번 원본 대조: $e');
      }
    }
    return done;
  }

  /// 원본 대조 수정 단계만 이 문항에 돌리고, 수정안이 나오면 문제은행에 바로 적용 → V2 카드 재렌더 → 교재 원본과 대조 재검수까지 마친다.
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
          note: '원본 대조 수정안 적용',
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
      setState(() {
        _notice = applied
            ? '${item.problemNumber}번 원본 대조 수정안을 문제은행에 적용하고 V2 카드를 다시 찍어 재검수했습니다.'
            : n > 0
                ? '${item.problemNumber}번 원본 대조 완료(고칠 내용이 없거나 이미 원본과 같습니다).'
                : '${item.problemNumber}번 원본 대조 실패${_bulkErrors.isEmpty ? '' : ': ${_bulkErrors.first}'}';
      });
    } catch (e) {
      if (mounted) setState(() => _notice = '원본 대조 실패: $e');
    }
  }

  /// 원본 대조에서 V2 그림 크기가 원본 비율을 벗어난 문항: 폭(widthEm)을 1/비율 배로 고쳐 적용한다(승인 문항은 승인 유지).
  /// 기존 figure_layout 이 비어 있던 문항도 기본 폭(20em)에서 1/비율 배로 줄인 배치를 새로 만들어 적용한다.
  /// 반환: 적용한 crop id
  Future<List<String>> _resizeFiguresFromRenderCheck({bool includeApproved = true}) async {
    final out = <String>[];
    for (final it in _items) {
      if (!mounted || _stopRequested) break;
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
        final res = await _svc.applyProblemFix(
          cropId: it.cropId,
          figureLayout: scaled,
          approveQuality: it.qualityStatus == 'approved',
          note: '그림 크기를 원본 글자 비율에 맞춰 재조정',
        );
        if (((res['changed'] as List?) ?? const []).isNotEmpty) out.add(it.cropId);
      } catch (e) {
        _bulkErrors.add('${it.problemNumber}번 그림 크기: $e');
      }
    }
    return out;
  }

  /// 수정안 적용 한 건. 원본에서 다시 잘라야 할 그림은 먼저 잘라 문제은행 그림으로 올리고 자산 목록에 붙인다.
  Future<Map<String, dynamic>> _applyFixFor(
    TextbookReviewUnitScope scope,
    TextbookProblemReviewItem item, {
    String? stem,
    List<Map<String, dynamic>>? choices,
    String? commonStem,
    Map<String, dynamic>? figureLayout,
    List<Map<String, dynamic>> figureCrops = const [],
    bool approve = false,
    String? note,
  }) async {
    List<Map<String, dynamic>>? assets;
    if (figureCrops.isNotEmpty) {
      final added = await _svc.cropAndUploadFigures(scope: scope, item: item, crops: figureCrops);
      if (added.isNotEmpty) assets = [...item.pbFigureAssets, ...added];
    }
    return _svc.applyProblemFix(
      cropId: item.cropId,
      stem: stem,
      choices: choices,
      commonStem: commonStem,
      figureLayout: figureLayout,
      figureAssets: assets,
      approveQuality: approve,
      note: note,
    );
  }

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
      final sync = await _svc.saveItemEdit(
        cropId: item.cropId,
        newAnswer: answer,
        aiSolution: _solutionEditCtrl.text.trim(),
        visualTags: _editingVisualTags,
        approveMath: approveMath,
        approveQuality: approveQuality,
        solutionTranscribed: origChanged ? origSol : null,
        solutionAnswer: origChanged ? origAns : null,
        alternativeSolutions: _editingAlternatives,
      );
      if (!mounted) return;
      final changed = (sync?['changed'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
      final syncNote = sync == null
          ? ''
          : sync['synced'] != true
              ? ' · 문제은행 사본 없음(정답 동기화 생략)'
              : changed.isEmpty
                  ? ' · 문제은행 정답 이미 일치'
                  : ' · 문제은행 ${changed.map((c) => c == 'objective_answer_key' ? '객관식 정답' : '주관식 정답').join('·')}도 함께 맞춤';
      setState(() {
        _saving = false;
        _notice = '문항 ${item.problemNumber}번 변경·승인을 반영했습니다.$syncNote';
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

  /// 품질 원터치: 편집기의 본문·선지·공통 발문·그림 배치를 문제은행 문항에 적용하고(바뀐 것만), 원본에서 잘라야 할
  /// 그림은 잘라 등록한 뒤 시각 태그·승인까지 한 번에 반영한다. approve=false 면 수정만 적용하고 V2 카드를 다시 찍어 확인하게 한다.
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
          newAnswer: null,
          aiSolution: _solutionEditCtrl.text.trim(),
          visualTags: _editingVisualTags,
          approveQuality: true,
          alternativeSolutions: _editingAlternatives,
        );
      }
      if (!mounted) return;
      final changed = (res['changed'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
      final members = (res['set_members_updated'] as num?)?.toInt() ?? 0;
      final what = changed.isEmpty
          ? '본문·선지·그림 변경 없음'
          : '${changed.map((c) => switch (c) {
                'stem' => '본문',
                'common_stem' => '공통 발문${members > 1 ? '(세트 $members문항)' : ''}',
                'figure_assets' => '원본 크롭 그림 등록',
                'figure_layout' => '그림 크기·위치',
                _ => '선지',
              }).join('·')} 수정을 문제은행에 적용';
      setState(() {
        _saving = false;
        _notice = '문항 ${item.problemNumber}번: $what${approve ? ' · 품질 승인' : ' · V2 카드를 다시 찍습니다'}';
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

  /// 공통 발문 중복이 있는 문항(보류 제외 · 이미 품질 승인된 문항도 앞 단계에서 오염된 공통 발문은 고칠 수 있게 포함한다)
  List<TextbookProblemReviewItem> get _commonStemDups => [
        for (final it in _items)
          if (it.commonStemDuplicated && !it.isEngineHeld && (it.qualityStatus != 'approved' || !it.stage2Superseded)) it,
      ];

  /// 발문 중복 말고 다른 품질 문제가 없는가(2단계 나머지 플래그·정답/해설 카드 판정이 모두 정상).
  /// 그림 문항은 원본 대조(크기·위치)를 거쳐야 하므로 여기서 바로 승인하지 않는다.
  static bool _onlyIssueIsCommonStemDup(TextbookProblemReviewItem it) {
    final qc = it.qualityChecks;
    final rc = it.renderChecks;
    return qc['choices_ok'] != false &&
        qc['figure_ok'] != false &&
        qc['latex_v2_ok'] != false &&
        qc['fidelity_ok'] != false &&
        rc['answer_ok'] != false &&
        rc['solution_ok'] != false &&
        rc['fidelity_ok'] != false &&
        !it.hasFigures &&
        (!it.hasPendingFixProposal || it.fixProposalIsCommonStemDup);
  }

  /// 단원 전체의 공통 발문 중복을 규칙으로 고친다. 중복 말고 다른 문제가 없는 문항은 품질 승인까지,
  /// 나머지는 수정만 적용한다(호출한 쪽에서 V2 렌더 검수를 다시 돌린다).
  /// 반환: (수정 문항 수, 그중 승인 수, 렌더 재검수할 crop id)
  Future<(int, int, List<String>)> _applyCommonStemDupFixes(TextbookReviewUnitScope scope) async {
    var fixed = 0;
    var approved = 0;
    final recheck = <String>[];
    final touched = <String>{};
    // 공통 발문을 세트 단위로 고치면 같은 세트의 다른 문항이 새로 "앞머리 중복"으로 드러난다.
    // 그래서 다시 읽고 남은 것이 없을 때까지 몇 번 돈다(진전이 없으면 멈춘다).
    var pending = _commonStemDups;
    for (var round = 0; round < 4 && pending.isNotEmpty; round++) {
      var progressed = false;
      for (final it in pending) {
        final fix = it.commonStemFix;
        if (fix == null) continue;
        final approve = _onlyIssueIsCommonStemDup(it);
        touched.add(it.cropId);
        try {
          await _svc.applyProblemFix(
            cropId: it.cropId,
            stem: fix.stem,
            commonStem: fix.commonStem,
            approveQuality: approve,
            note: '공통 발문 중복 제거(일괄)',
          );
        } catch (e) {
          _bulkErrors.add('${it.problemNumber}번: $e');
          continue;
        }
        progressed = true;
        fixed++;
        if (approve) {
          approved++;
        } else {
          recheck.add(it.cropId);
        }
      }
      if (!progressed || !mounted) break;
      await _loadItems(scope, reloadPreviews: false);
      pending = [for (final x in _commonStemDups) if (!touched.contains(x.cropId)) x];
    }
    if (touched.isNotEmpty && mounted) {
      final changedItems = [for (final x in _items) if (touched.contains(x.cropId)) x];
      if (changedItems.isNotEmpty) await _loadEnginePreviews(scope, changedItems, merge: true);
    }
    return (fixed, approved, recheck);
  }

  /// 문항 유형 표시가 규칙(서술형 표현·선지 유무)과 다른 문항
  List<TextbookProblemReviewItem> get _kindFixes => [for (final it in _items) if (it.questionKindMismatch) it];

  /// AI 본문 수정안(본문·선지·공통 발문)을 그대로 쓸 수 있는가. 공통 발문 중복 규칙 제안은 규칙 수정이 먼저 처리한다.
  static bool _textProposalUsable(TextbookProblemReviewItem it) =>
      it.hasPendingFixProposal && !it.fixProposalIsCommonStemDup && !it.commonStemDuplicated;

  /// 아직 적용하지 않은 수정안(본문 또는 그림)이 있는 문항(보류 제외 · 그림 문항은 원본 대조 배치를 반드시 DB 에 반영한다)
  List<TextbookProblemReviewItem> get _pendingProposals => [
        for (final it in _items)
          if (!it.isEngineHeld &&
              (it.qualityStatus != 'approved' || !it.stage2Superseded) &&
              (_textProposalUsable(it) ||
                  it.hasPendingFigureProposal ||
                  (it.hasFigures && it.fixAppliedAt == null && (it.proposedFigureLayout != null || it.pbFigureLayout.isNotEmpty))))
            it,
      ];

  Future<int> _applyQuestionKindFixes() async {
    var n = 0;
    for (final it in _kindFixes) {
      try {
        if (await _svc.setQuestionKind(it.cropId, it.expectedQuestionKind)) n++;
      } catch (e) {
        _bulkErrors.add('${it.problemNumber}번 유형: $e');
      }
    }
    return n;
  }

  /// 수정안(본문·선지·공통 발문·그림 배치·원본 크롭 그림)을 그대로 적용한다(승인은 하지 않음).
  /// 적용한 crop id 를 돌려주고, 호출한 쪽이 원본 대조 V2 렌더 재검수로 확인한다.
  Future<List<String>> _applyPendingProposals(TextbookReviewUnitScope scope) async {
    final out = <String>[];
    final targets = _pendingProposals;
    for (var i = 0; i < targets.length; i++) {
      if (!mounted || _stopRequested) break;
      final it = targets[i];
      final text = _textProposalUsable(it);
      final figure = it.hasPendingFigureProposal || (it.hasFigures && it.fixAppliedAt == null);
      setState(() => _runProgress = '수정안 적용: ${i + 1} / ${targets.length} 문항 (${it.problemNumber}번)');
      try {
        final res = await _applyFixFor(
          scope,
          it,
          stem: text ? it.proposedStem : null,
          choices: text ? it.proposedChoices : null,
          commonStem: text ? it.proposedCommonStem : null,
          figureLayout: figure ? (it.proposedFigureLayout ?? (it.pbFigureLayout.isNotEmpty ? it.pbFigureLayout : null)) : null,
          figureCrops: figure ? it.proposedFigureCrops : const [],
          note: '원본 대조 수정안 일괄 적용',
        );
        if (((res['changed'] as List?) ?? const []).isNotEmpty || it.hasFigures) out.add(it.cropId);
      } catch (e) {
        _bulkErrors.add('${it.problemNumber}번 수정안: $e');
      }
    }
    return out;
  }

  Future<void> _setQuestionKind(TextbookProblemReviewItem item, String kind) async {
    final scope = _selectedScope;
    if (scope == null) return;
    setState(() => _saving = true);
    try {
      final changed = await _svc.setQuestionKind(item.cropId, kind);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = changed ? '${item.problemNumber}번 유형을 ${_kindLabel(kind)}(으)로 바꿨습니다.' : '${item.problemNumber}번 유형이 이미 ${_kindLabel(kind)}입니다.';
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

  List<TextbookProblemReviewItem> get _filteredItems {
    return [
      for (final it in _items)
        if (_filterTab == 0 ||
            (_filterTab == 1 && it.hasIssue) ||
            (_filterTab == 2 && it.hasDrafts) ||
            (_filterTab == 3 && (it.mathStatus == 'pending' || it.qualityStatus == 'pending')) ||
            (_filterTab == 4 && it.isFullyApproved) ||
            (_filterTab == 5 && it.isEngineHeld) ||
            (_filterTab == 6 && it.approvedButDiffers))
          it,
    ];
  }

  /// 원본 대조 수정 단계를 돌릴 문항(오류 문항·그림 문항 중 아직 안 돌렸거나 수정 후에도 오류인 것)
  List<TextbookProblemReviewItem> get _fixPassTargets => [for (final it in _items) if (it.needsFixPass) it];
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
    final mathCleanCount = _items.where((x) => x.mathStatus == 'clean').length;
    final qualCleanCount = _items.where((x) => x.qualityStatus == 'clean').length;
    final issueCount = _items.where((x) => x.hasIssue).length;
    final draftCount = _items.where((x) => x.hasDrafts).length;

    return Container(
      color: _kBg,
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTopHeader(mathCleanCount, qualCleanCount),
          const SizedBox(height: 12),
          _buildScopeSelectorBar(),
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
                    : _buildMainWorkspace(issueCount, draftCount),
          ),
        ],
      ),
    );
  }

  Widget _buildTopHeader(int mathCleanCount, int qualCleanCount) {
    final mathIssueCount = _items.where((x) => x.mathStatus == 'issue' || x.pbAnswerDiffers).length;
    final qualIssueCount = _items.where((x) => !x.isEngineHeld && x.qualityStatus == 'issue').length;
    final mathTotalTargets = mathCleanCount + mathIssueCount;
    final qualTotalTargets = qualCleanCount +
        qualIssueCount +
        _commonStemDups.length +
        _kindFixes.length +
        _pendingProposals.length +
        _fixPassTargets.length;
    final actions = <Widget>[
      if (_runningReview)
        OutlinedButton.icon(
          onPressed: _stopRequested ? null : () => setState(() => _stopRequested = true),
          style: _outlineButtonStyle(color: _kError),
          icon: const Icon(Icons.pause_circle_outline, size: 18, color: _kError),
          label: Text(_stopRequested ? '이번 묶음 후 멈춤' : '일시정지', style: const TextStyle(color: _kError)),
        )
      else ...[
        if (mathTotalTargets > 0)
          OutlinedButton.icon(
            onPressed: _saving ? null : () => unawaited(_bulkApproveClean('math')),
            style: _outlineButtonStyle(color: _kAccent),
            icon: const Icon(Icons.done_all_rounded, size: 18, color: _kAccent),
            label: Text('수학 일괄 처리 (${mathIssueCount > 0 ? '수정안 반영·재검수 $mathIssueCount' : '정상 $mathCleanCount'})'),
          ),
        if (qualTotalTargets > 0)
          OutlinedButton.icon(
            onPressed: _saving ? null : () => unawaited(_bulkApproveClean('quality')),
            style: _outlineButtonStyle(color: _kBlue),
            icon: const Icon(Icons.auto_fix_high_rounded, size: 18, color: _kBlue),
            label: Text('품질 일괄 처리 (${qualIssueCount + _pendingProposals.length + _commonStemDups.length > 0 ? '수정안 반영·재검수 ${qualIssueCount > 0 ? qualIssueCount : _pendingProposals.length + _commonStemDups.length}' : '정상 $qualCleanCount'})'),
          ),
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
            if (v == 'render_check') unawaited(_renderCheckMany(_items.toList(), 'V2 렌더 검수(교재 원본 대조)'));
            if (v == 'recheck_approved') {
              unawaited(_renderCheckMany([for (final x in _items) if (x.needsOriginalRecheck) x], '승인 문항 원본 재대조'));
            }
          },
          itemBuilder: (_) {
            final approvedTodo = _items.where((x) => x.needsOriginalRecheck).length;
            return [
              const PopupMenuItem(value: 'rerun_all', child: Text('전체 강제 재검수', style: TextStyle(color: _kText, fontSize: 13))),
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
        onPressed: _loadingUnits || _runningReview ? null : () => unawaited(_loadUnits()),
        icon: const Icon(Icons.refresh_rounded, color: _kTextSub, size: 20),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final title = const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '문항검수',
              style: TextStyle(color: _kText, fontSize: 20, fontWeight: FontWeight.w800),
            ),
            SizedBox(height: 4),
            Text(
              '해설 PDF 좌표 영역 원본 해설 전사 · 블라인드 독립 풀이 · 3축 난이도 · V2 렌더 카드 학생 시점 품질 검수',
              style: TextStyle(color: _kTextSub, fontSize: 14, fontWeight: FontWeight.w600, height: 1.35),
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
            width: constraints.maxWidth < 860 ? constraints.maxWidth : 240,
            value: books.contains(_selectedBookKey) ? _selectedBookKey : books.firstOrNull,
            items: [
              for (final k in books)
                DropdownMenuItem(value: k, child: Text(_bookLabelOf(k), overflow: TextOverflow.ellipsis)),
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
                DropdownMenuItem(value: u.key, child: Text(u.unitTitle, overflow: TextOverflow.ellipsis)),
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
          final badges = Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _pillBadge('수학 승인 $mathApproved / ${_items.length}', _kAccent),
              _pillBadge('품질 승인 $qualApproved / ${_items.length - held}', _kBlue),
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
                _buildMathReviewCard(selected),
                const SizedBox(height: 12),
                _buildSolutionEditCard(selected),
                const SizedBox(height: 12),
                _buildQualityReviewCard(selected),
              ],
            ),
          );
    final preview = selected == null ? _emptyPanel('V2 렌더 카드') : _buildV2CardStack(selected);

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

  Widget _buildProblemListPanel(
    List<TextbookProblemReviewItem> filtered,
    int issueCount,
    int draftCount,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _filterTabChip(0, '전체 ${_items.length}'),
              _filterTabChip(
                1,
                '오류·불일치 $issueCount'
                '${issueCount > 0 ? ' (수학 ${_items.where((x) => x.mathStatus == 'issue').length}'
                    ' · 품질 ${_items.where((x) => x.qualityStatus == 'issue').length})' : ''}',
                highlightError: issueCount > 0,
              ),
              if (draftCount > 0) _filterTabChip(2, '새 초안 $draftCount'),
              _filterTabChip(3, '미검수 ${_items.where((x) => x.mathStatus == 'pending').length}'),
              _filterTabChip(4, '승인완료 ${_items.where((x) => x.isFullyApproved).length}'),
              if (_engineHeldCount > 0) _filterTabChip(5, '엔진 보류 $_engineHeldCount'),
              if (_approvedDiffCount > 0) _filterTabChip(6, '승인 후 원본 차이 $_approvedDiffCount'),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: _kBorder, height: 1),
          Expanded(
            child: filtered.isEmpty
                ? const Center(child: Text('해당 조건의 문항이 없습니다.', style: TextStyle(color: _kTextSub, fontSize: 14, fontWeight: FontWeight.w600)))
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _problemListTile(filtered[i]),
                  ),
          ),
        ],
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
                      : item.hasSolutionRef
                          ? '원본 해설 미전사'
                          : '해설 좌표 없음',
                  item.hasOriginalSolution ? _kBlue : (item.hasSolutionRef ? _kWarn : _kTextMuted),
                ),
                if (item.renderCheckedAt != null)
                  _pillBadge(item.renderHasIssue ? 'V2 렌더 이상' : 'V2 렌더 정상', item.renderHasIssue ? _kError : _kAccent),
                if (_issueKindBadge(item) case final kb?) _pillBadge(kb.$1, kb.$2),
                if (item.pbAnswerDiffers) _pillBadge('문제은행 정답 다름', _kWarn),
                for (final vt in item.visualTags.take(2)) _pillBadge(vt, _kTextSub),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── 우측: V2 카드 스택 ───────────────────────────────────────────────────

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
                      '3축 난이도 분해',
                      style: TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w800),
                    ),
                    _pillBadge('총점 ${item.totalDifficulty.toStringAsFixed(2)}점', _kAccent),
                    _pillBadge('개념 ${item.conceptScore.toStringAsFixed(2)}점', _kBlue),
                    _pillBadge('사고 ${item.thinkingScore.toStringAsFixed(2)}점', _kAccent),
                    _pillBadge('연산 ${item.arithmeticScore.toStringAsFixed(2)}점', _kTextSub),
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
    final visionFailed = item.hasSolutionRef && !item.hasOriginalSolution && item.hasAiSolution;
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
                    ? (item.solutionSource == 'manual' ? '원본 직접 입력 (DB 저장됨)' : '원본 Vision 전사${visionConf != null ? ' · $visionConf' : ''} (DB 저장됨)')
                    : (item.hasSolutionRef ? '원본 미전사' : '해설 좌표 없음'),
                item.hasOriginalSolution ? _kBlue : (item.hasSolutionRef ? _kWarn : _kTextMuted),
              ),
              if (solDirty) _pillBadge('저장 전 해설 변경 있음', _kWarn),
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
              '좌표를 확인하거나 아래에 직접 입력하세요. 그 전까지 학생 화면에는 AI 풀이가 표시됩니다.',
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
            decoration: _inputDecoration(item.hasSolutionRef ? '검수를 실행하면 해설 PDF 영역에서 전사됩니다. 직접 입력해도 됩니다.' : '해설 좌표가 없는 문항입니다. 직접 입력할 수 있습니다.'),
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
                      } else {
                        _editingVisualTags = [..._editingVisualTags, tag];
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
