import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/textbook_problem_review_service.dart';
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
const int _kRenderCheckChunkSize = 5;

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

  /// 필터: 0 전체, 1 확인필요(오류·불일치), 2 새초안제안, 3 미검수, 4 승인완료, 5 엔진 보류
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
        final cur = _selectedCropId != null ? items.where((x) => x.cropId == _selectedCropId).firstOrNull : null;
        final pick = cur ?? items.where((x) => x.hasIssue).firstOrNull ?? items.firstOrNull;
        if (pick != null) {
          _selectItem(pick);
        } else {
          _selectedCropId = null;
        }
      });
      if (reloadPreviews) {
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
    _answerEditCtrl.text = item.existingAnswer.isNotEmpty ? item.existingAnswer : (item.aiAnswer ?? '');
    _solutionEditCtrl.text = item.aiSolution ?? '';
    _origSolutionCtrl.text = item.solutionTranscribed ?? '';
    _origAnswerCtrl.text = item.solutionAnswer ?? '';
    // 편집기 기본값: AI/규칙 수정 제안 → 공통 발문 중복이면 공통 부분을 뺀 본문 → 현재 본문
    final dupFix = item.commonStemFix;
    _stemEditCtrl.text = item.hasPendingFixProposal ? (item.proposedStem ?? item.stem) : (dupFix?.stem ?? item.stem);
    _commonStemEditCtrl.text =
        item.hasPendingFixProposal ? (item.proposedCommonStem ?? item.commonStem) : (dupFix?.commonStem ?? item.commonStem);
    _choicesEditCtrl.text = _choicesToLines(item.hasPendingFixProposal ? (item.proposedChoices ?? item.rawChoices) : item.rawChoices);
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

  /// 편집기의 본문·선지가 저장된 문항과 다른가
  bool _problemEditDirty(TextbookProblemReviewItem item) =>
      _stemEditCtrl.text.trim() != item.stem.trim() ||
      _commonStemEditDirty(item) ||
      _choicesToLines(_linesToChoices(_choicesEditCtrl.text)) != _choicesToLines(item.rawChoices);

  bool _commonStemEditDirty(TextbookProblemReviewItem item) =>
      item.commonStem.isNotEmpty && _commonStemEditCtrl.text.trim() != item.commonStem.trim();

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

      // 2차: 정답·해설 카드를 V2로 찍어 학생 시점 렌더 검수
      if (mounted && !_stopRequested && _svc.hasGateway) {
        renderChecked = await _runRenderCheckPass(scope);
      }

      if (!mounted) return;
      await _loadUnits();
      setState(() {
        _notice = _stopRequested
            ? '요청에 따라 일시정지했습니다 ($totalProcessed문항 검수 완료).'
            : '중단원 검수가 완료되었습니다 ($totalProcessed문항 처리 · V2 렌더 검수 $renderChecked문항). 정상 문항은 일괄 승인하고 확인 필요 문항만 점검하세요.';
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
        payload.add({
          'crop_id': it.cropId,
          if ((problemUrl ?? '').isNotEmpty) 'problem_url': problemUrl,
          if (solUrl.isNotEmpty) 'answer_solution_url': solUrl,
          'solution_kind': it.primarySolutionKind,
        });
      }
      if (payload.isEmpty) continue;
      if (!mounted) break;
      setState(() {
        _runProgress = 'V2 렌더 검수: ${i + 1}~${i + chunk.length} / ${targets.length} 문항 — 학생 시점으로 읽히는지 판정 중...';
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
      setState(() => _notice = n > 0 ? '${item.problemNumber}번 V2 렌더 검수를 다시 했습니다.' : 'V2 카드 URL을 만들지 못해 검수하지 못했습니다.');
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

  /// 일괄 처리. 규칙으로 바로 고칠 수 있는 것은 고치고(수학: 해설·AI 일치 답 채택, 품질: 공통 발문 중복 제거),
  /// 정상 문항은 승인한다. 사람이 봐야 하는 것(품질은 렌더·엔진 문제)만 남긴다.
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
        final (done, synced) = await _adoptAgreedAnswers();
        if (done > 0) notes.add('해설·AI 일치 답 $done문항 채택(문제은행 정답 $synced문항 동기화)');
        // 채점 정답 = AI 답이면 해설 답이 없거나 달라도 2:1 로 채점 정답을 유지하고 승인한다.
        final confirmed = [for (final it in _items) if (it.mathStatus == 'issue' && it.existingConfirmedByAi) it.cropId];
        if (confirmed.isNotEmpty) {
          extraApprove.addAll(confirmed);
          notes.add('채점 정답 = AI 답 ${confirmed.length}문항 유지 승인');
        }
      } else {
        // 1) 규칙: 공통 발문 중복
        final (fixed, approvedByFix, again) = await _applyCommonStemDupFixes(scope);
        final recheck = <String>{...again};
        if (fixed > 0) notes.add('공통 발문 중복 $fixed문항 수정($approvedByFix문항 바로 승인)');
        // 2) 규칙: 문항 유형(객관식·주관식·서술형) 표시
        final kinds = await _applyQuestionKindFixes();
        if (kinds > 0) notes.add('문항 유형 표시 $kinds문항 수정');
        // 3) AI 데이터 수정안 적용 → V2 렌더 재검수로 확인
        final aiFixed = await _applyAiDataProposals();
        recheck.addAll(aiFixed);
        if (aiFixed.isNotEmpty) notes.add('AI 수정안 ${aiFixed.length}문항 적용');
        if (recheck.isNotEmpty && mounted) {
          await _loadItems(scope, reloadPreviews: false);
          final again2 = [for (final x in _items) if (recheck.contains(x.cropId)) x];
          await _loadEnginePreviews(scope, again2, merge: true);
          setState(() {
            _runningReview = true;
            _stopRequested = false;
          });
          try {
            await _runRenderCheckPass(scope, only: again2);
          } finally {
            if (mounted) {
              setState(() {
                _runningReview = false;
                _runProgress = null;
              });
            }
          }
          notes.add('수정 문항 ${again2.length}개 V2 렌더 재검수');
        }
      }
      if (!mounted) return;
      await _loadItems(scope, reloadPreviews: false);
      final ids = <String>{
        for (final it in _items)
          if (axis == 'math' ? it.mathStatus == 'clean' : it.qualityStatus == 'clean') it.cropId,
        ...extraApprove,
      }.toList();
      final count = ids.isEmpty ? 0 : await _svc.approveAxis(ids, axis);
      if (!mounted) return;
      await _loadItems(scope, reloadPreviews: false);
      await _loadUnits();
      final left = axis == 'math'
          ? _items.where((x) => x.mathStatus == 'issue').length
          : _items.where((x) => x.qualityStatus == 'issue').length;
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

  /// 품질 원터치: 편집기의 본문·선지를 문제은행 문항에 적용하고(바뀐 것만), 시각 태그·승인까지 한 번에 반영한다.
  /// approve=false 면 수정만 적용하고 V2 카드를 다시 찍어 확인하게 한다.
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
      final res = await _svc.applyProblemFix(
        cropId: item.cropId,
        stem: stemChanged ? stem : null,
        choices: choicesChanged ? choices : null,
        commonStem: commonChanged ? _commonStemEditCtrl.text.trim() : null,
        approveQuality: approve,
        note: item.hasPendingFixProposal ? 'AI 제안 ${stemChanged || choicesChanged || commonChanged ? '적용' : '검토'}' : null,
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
          ? '본문·선지 변경 없음'
          : '${changed.map((c) => c == 'stem' ? '본문' : c == 'common_stem' ? '공통 발문${members > 1 ? '(세트 $members문항)' : ''}' : '선지').join('·')} 수정을 문제은행에 적용';
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

  /// 공통 발문 중복 문항: 편집기에 공통 부분을 뺀 본문을 넣고 바로 적용(+승인)한다.
  Future<void> _fixCommonStemDup(TextbookProblemReviewItem item, {required bool approve}) async {
    final fix = item.commonStemFix;
    if (fix == null) return;
    _stemEditCtrl.text = fix.stem;
    _commonStemEditCtrl.text = fix.commonStem ?? item.commonStem;
    await _applyProblemFix(item, approve: approve);
  }

  /// 수학 원터치 일괄: 해설 정답과 AI 정답이 같고 채점 정답만 다른 문항은 그 답을 채택하고 수학 승인한다(문제은행 정답도 동기화).
  List<TextbookProblemReviewItem> get _agreedAnswerFixes =>
      [for (final it in _items) if (it.mathStatus == 'issue' && it.solutionAndAiAgreeAgainstExisting) it];

  /// 반환: (채택 문항 수, 문제은행 정답이 실제로 바뀐 문항 수)
  Future<(int, int)> _adoptAgreedAnswers() async {
    var done = 0;
    var synced = 0;
    for (final it in _agreedAnswerFixes) {
      final ans = (it.solutionAnswer ?? '').trim();
      if (ans.isEmpty) continue;
      final Map<String, dynamic>? sync;
      try {
        sync = await _svc.saveItemEdit(
          cropId: it.cropId,
          newAnswer: ans,
          visualTags: it.visualTags,
          approveMath: true,
        );
      } catch (e) {
        _bulkErrors.add('${it.problemNumber}번: $e');
        continue;
      }
      done++;
      if (((sync?['changed'] as List?) ?? const []).isNotEmpty) synced++;
    }
    return (done, synced);
  }

  /// 공통 발문 중복이 있는 문항(승인·보류 제외)
  List<TextbookProblemReviewItem> get _commonStemDups =>
      [for (final it in _items) if (it.commonStemDuplicated && it.qualityStatus != 'approved' && !it.isEngineHeld) it];

  /// 발문 중복 말고 다른 품질 문제가 없는가(2단계 나머지 플래그·정답/해설 카드 판정이 모두 정상)
  static bool _onlyIssueIsCommonStemDup(TextbookProblemReviewItem it) {
    final qc = it.qualityChecks;
    final rc = it.renderChecks;
    return qc['choices_ok'] != false &&
        qc['figure_ok'] != false &&
        qc['latex_v2_ok'] != false &&
        qc['fidelity_ok'] != false &&
        rc['answer_ok'] != false &&
        rc['solution_ok'] != false &&
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

  /// AI 가 낸 데이터 수정안(본문·선지·공통 발문)이 아직 적용되지 않은 오류 문항(규칙 제안·승인·보류 제외)
  List<TextbookProblemReviewItem> get _aiDataProposals => [
        for (final it in _items)
          if (it.qualityStatus == 'issue' && it.hasPendingFixProposal && !it.fixProposalIsCommonStemDup && !it.commonStemDuplicated) it,
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

  /// AI 수정안을 그대로 적용한다(승인은 하지 않음). 적용한 crop id 를 돌려주고, 호출한 쪽이 V2 렌더 재검수로 확인한다.
  Future<List<String>> _applyAiDataProposals() async {
    final out = <String>[];
    for (final it in _aiDataProposals) {
      try {
        final res = await _svc.applyProblemFix(
          cropId: it.cropId,
          stem: it.proposedStem,
          choices: it.proposedChoices,
          commonStem: it.proposedCommonStem,
          note: 'AI 수정안 일괄 적용',
        );
        if (((res['changed'] as List?) ?? const []).isNotEmpty) out.add(it.cropId);
      } catch (e) {
        _bulkErrors.add('${it.problemNumber}번 AI 수정안: $e');
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
            (_filterTab == 5 && it.isEngineHeld))
          it,
    ];
  }

  int get _mathConfirmedCount => _items.where((it) => it.mathStatus == 'issue' && it.existingConfirmedByAi).length;

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
    final actions = <Widget>[
      if (_runningReview)
        OutlinedButton.icon(
          onPressed: _stopRequested ? null : () => setState(() => _stopRequested = true),
          style: _outlineButtonStyle(color: _kError),
          icon: const Icon(Icons.pause_circle_outline, size: 18, color: _kError),
          label: Text(_stopRequested ? '이번 묶음 후 멈춤' : '일시정지', style: const TextStyle(color: _kError)),
        )
      else ...[
        if (mathCleanCount + _agreedAnswerFixes.length + _mathConfirmedCount > 0)
          OutlinedButton.icon(
            onPressed: _saving ? null : () => unawaited(_bulkApproveClean('math')),
            style: _outlineButtonStyle(color: _kAccent),
            icon: const Icon(Icons.done_all_rounded, size: 18, color: _kAccent),
            label: Text('수학 일괄 처리 (${mathCleanCount + _agreedAnswerFixes.length + _mathConfirmedCount})'),
          ),
        if (qualCleanCount + _commonStemDups.length + _kindFixes.length + _aiDataProposals.length > 0)
          OutlinedButton.icon(
            onPressed: _saving ? null : () => unawaited(_bulkApproveClean('quality')),
            style: _outlineButtonStyle(color: _kBlue),
            icon: const Icon(Icons.auto_fix_high_rounded, size: 18, color: _kBlue),
            label: Text('품질 일괄 처리 (정상 $qualCleanCount'
                '${_commonStemDups.isNotEmpty ? ' · 발문 중복 ${_commonStemDups.length}' : ''}'
                '${_aiDataProposals.isNotEmpty ? ' · AI 수정안 ${_aiDataProposals.length}' : ''}'
                '${_kindFixes.isNotEmpty ? ' · 유형 ${_kindFixes.length}' : ''})'),
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
            if (v == 'render_check' && _selectedScope != null) {
              unawaited(() async {
                setState(() {
                  _runningReview = true;
                  _stopRequested = false;
                });
                try {
                  final n = await _runRenderCheckPass(_selectedScope!, only: _items.toList());
                  if (mounted) setState(() => _notice = 'V2 렌더 검수를 $n문항에 다시 했습니다.');
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
              }());
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rerun_all', child: Text('전체 강제 재검수', style: TextStyle(color: _kText, fontSize: 13))),
            PopupMenuItem(value: 'render_check', child: Text('V2 렌더 검수만 전체 다시', style: TextStyle(color: _kText, fontSize: 13))),
          ],
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
              _filterTabChip(1, '오류·불일치 $issueCount', highlightError: issueCount > 0),
              if (draftCount > 0) _filterTabChip(2, '새 초안 $draftCount'),
              _filterTabChip(3, '미검수 ${_items.where((x) => x.mathStatus == 'pending').length}'),
              _filterTabChip(4, '승인완료 ${_items.where((x) => x.isFullyApproved).length}'),
              if (_engineHeldCount > 0) _filterTabChip(5, '엔진 보류 $_engineHeldCount'),
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
    final problemIssue = item.qualityStatus == 'issue' &&
        (qc['stem_ok'] == false || qc['choices_ok'] == false || qc['figure_ok'] == false || qc['latex_v2_ok'] == false ||
            qc['fidelity_ok'] == false || rc['problem_ok'] == false);
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
                  _v2CardSection(
                    title: '① 문항 카드',
                    subtitle: item.isSetQuestion ? '세트 공통 발문 포함 · 문제은행 카드와 동일 렌더' : '문제은행 카드와 동일 렌더',
                    url: problemUrl,
                    loading: _loadingPreviews && (problemUrl ?? '').isEmpty,
                    issue: problemIssue,
                    issueText: qc['issue_title'] != null ? '${qc['issue_title']}: ${qc['issue_detail'] ?? ''}' : null,
                    badges: [
                      if (qc['judged_from_v2_image'] == true) ('AI가 이 화면을 보고 판정', _kAccent),
                      if (qc['judged_from_v2_image'] == false && item.qualityStatus != 'pending') ('텍스트만으로 판정됨', _kWarn),
                      if (qc['fidelity_ok'] == false) ('원본과 내용 불일치', _kError),
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
            children: [
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
                onPressed: _saving ? null : () => unawaited(_saveAndApproveSingle(item, approveMath: true)),
                style: _primaryButtonStyle(),
                icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                label: Text(item.mathStatus == 'approved' ? '수학 재승인 저장' : '수학적 검수 승인'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final saved = _answerCompareTile(
                '기존 저장 정답 (직접 수정 가능)',
                child: TextField(
                  controller: _answerEditCtrl,
                  style: const TextStyle(color: _kText, fontSize: 14, fontWeight: FontWeight.w800),
                  decoration: _inputDecoration('정답 입력'),
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
                decoration: BoxDecoration(
                  color: _kChipSelected.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(_kInnerRadius),
                  border: Border.all(color: _kAccent, width: 0.5),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _pillBadge(
                          dp['target'] == 'arithmetic' ? '새 연산 초안' : '새 사고 초안',
                          _kAccent,
                        ),
                        ElevatedButton.icon(
                          onPressed: _saving
                              ? null
                              : () => unawaited(_acceptDraftProposal(item, '${dp['code'] ?? ''}')),
                          style: _primaryButtonStyle(),
                          icon: const Icon(Icons.add_task_rounded, size: 16),
                          label: const Text('사전 등록 + 앞 문항 백필'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${dp['title']} (${dp['category']} · ${dp['unit_score']}점) — ${dp['criteria'] ?? dp['trigger_cond'] ?? ''}',
                      style: const TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w600, height: 1.35),
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
                    ? (item.solutionSource == 'manual' ? '원본 직접 입력' : '원본 Vision 전사${visionConf != null ? ' · $visionConf' : ''}')
                    : (item.hasSolutionRef ? '원본 미전사' : '해설 좌표 없음'),
                item.hasOriginalSolution ? _kBlue : (item.hasSolutionRef ? _kWarn : _kTextMuted),
              ),
              ElevatedButton.icon(
                onPressed: _saving ? null : () => unawaited(_saveAndApproveSingle(item)),
                style: _primaryButtonStyle(),
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('해설 저장'),
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
          const Text('원본 해설 (교재 해설 PDF 전사 · 수정 가능)', style: TextStyle(color: _kTextSub, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _origAnswerCtrl,
            style: const TextStyle(color: _kText, fontSize: 14, fontWeight: FontWeight.w700),
            decoration: _inputDecoration('해설 정답'),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _origSolutionCtrl,
            maxLines: 6,
            minLines: 3,
            style: const TextStyle(color: _kText, fontSize: 13, height: 1.45),
            decoration: _inputDecoration(item.hasSolutionRef ? '검수를 실행하면 해설 PDF 영역에서 전사됩니다. 직접 입력해도 됩니다.' : '해설 좌표가 없는 문항입니다. 직접 입력할 수 있습니다.'),
          ),
          const SizedBox(height: 12),
          Text('AI 독립 풀이 (정답 ${item.aiAnswer ?? '-'} · 수정 가능)', style: const TextStyle(color: _kTextSub, fontSize: 12)),
          const SizedBox(height: 6),
          TextField(
            controller: _solutionEditCtrl,
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
                if (item.commonStemDuplicated && item.qualityStatus != 'approved')
                  ElevatedButton.icon(
                    onPressed: _saving ? null : () => unawaited(_fixCommonStemDup(item, approve: true)),
                    style: _primaryButtonStyle(),
                    icon: const Icon(Icons.content_cut_rounded, size: 18),
                    label: const Text('공통 발문 중복 제거 + 품질 승인'),
                  )
                else if (dirty || item.hasPendingFixProposal)
                  ElevatedButton.icon(
                    onPressed: _saving ? null : () => unawaited(_applyProblemFix(item, approve: true)),
                    style: _primaryButtonStyle(),
                    icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                    label: Text(dirty ? '본문·선지 수정 적용 + 품질 승인' : 'AI 수정안 적용 + 품질 승인'),
                  )
                else
                  ElevatedButton.icon(
                    onPressed: _saving ? null : () => unawaited(_saveAndApproveSingle(item, approveQuality: true)),
                    style: _primaryButtonStyle(),
                    icon: const Icon(Icons.verified_outlined, size: 18),
                    label: Text(item.qualityStatus == 'approved' ? '품질·시각태그 재저장' : '품질 검수 승인'),
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
          if (qc['issue_title'] != null) ...[
            const SizedBox(height: 10),
            _buildBanner('문항 카드 — ${qc['issue_title']}: ${qc['issue_detail'] ?? ''}', _kError, Icons.warning_amber_rounded),
          ],
          if (rc['issue_title'] != null) ...[
            const SizedBox(height: 8),
            _buildBanner('정답·해설 카드 — ${rc['issue_title']}: ${rc['issue_detail'] ?? ''}', _kError, Icons.warning_amber_rounded),
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

  /// 본문·선지 편집기. AI 수정안이 있으면 제안으로 채워져 있고, 원문과 다른 부분을 아래에 보여 준다.
  Widget _buildProblemFixEditor(TextbookProblemReviewItem item, {required bool dirty}) {
    final fp = item.fixProposal;
    final hasProposal = item.hasPendingFixProposal;
    final dup = item.commonStemDuplicated;
    final reason = '${fp['reason'] ?? ''}'.trim();
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
                    ? '공통 발문 중복 제거안 (문제은행 문항에 적용됨)'
                    : hasProposal
                        ? 'AI 데이터 수정안 (문제은행 문항에 적용됨)'
                        : '본문·선지 직접 수정 (문제은행 문항에 적용됨)',
                style: const TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w800),
              ),
              if (dup) _pillBadge('규칙 판정: 공통 발문 중복', _kAccent)
              else if (hasProposal) _pillBadge(item.fixProposalIsCommonStemDup ? '규칙 제안' : '원본 크롭 대조 제안', _kAccent),
              if (dirty) _pillBadge('저장 전 변경 있음', _kWarn),
              if (fp['applied_at'] != null) _pillBadge('이전 수정안 적용됨', _kTextMuted),
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
            Text('제안 이유: $reason', style: const TextStyle(color: _kTextSub, fontSize: 12, height: 1.35)),
          ],
          if (item.commonStem.isNotEmpty) ...[
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
                '현재 저장값: ${item.commonStem.trim()}',
                style: const TextStyle(color: _kTextMuted, fontSize: 11.5, height: 1.35),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
          const SizedBox(height: 10),
          Text(
            item.commonStem.isNotEmpty ? '개별 발문 (공통 발문 제외 · 마크업 [문단]·\$수식\$ 유지)' : '발문 (마크업 [문단]·\$수식\$ 유지)',
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
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _saving || !_svc.hasGateway ? null : () => unawaited(_previewProblemFix(item)),
                style: _outlineButtonStyle(color: _kBlue),
                icon: const Icon(Icons.preview_rounded, size: 16, color: _kBlue),
                label: const Text('수정안 V2 미리보기 (오른쪽에 표시)'),
              ),
              OutlinedButton.icon(
                onPressed: _saving || !dirty ? null : () => unawaited(_applyProblemFix(item, approve: false)),
                style: _outlineButtonStyle(color: _kAccent),
                icon: const Icon(Icons.save_outlined, size: 16, color: _kAccent),
                label: const Text('수정만 적용 (재렌더 후 확인)'),
              ),
              if (hasProposal || dirty)
                TextButton.icon(
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                            _stemEditCtrl.text = item.stem;
                            _commonStemEditCtrl.text = item.commonStem;
                            _choicesEditCtrl.text = _choicesToLines(item.rawChoices);
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
