import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/textbook_problem_review_service.dart';
import '../problem_bank/widgets/problem_bank_question_card.dart';

// ── 신형 다크 틸(학습앱 디자인 시스템 §2.2 kDlg* 토큰) 팔레트
const Color _kBg = Color(0xFF0B1112);
const Color _kPanelBg = Color(0xFF10171A);
const Color _kFieldBg = Color(0xFF15171C);
const Color _kBorder = Color(0xFF223131);
const Color _kText = Color(0xFFEAF2F2);
const Color _kTextSub = Color(0xFF9FB3B3);
const Color _kTextMuted = Color(0xFF6B8080);
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

  /// 필터: 0 전체, 1 확인필요(오류·불일치), 2 새초안제안, 3 미검수, 4 승인완료
  int _filterTab = 0;

  final _answerEditCtrl = TextEditingController();
  final _solutionEditCtrl = TextEditingController();
  final _origSolutionCtrl = TextEditingController();
  final _origAnswerCtrl = TextEditingController();
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
    List<TextbookProblemReviewItem> items,
  ) async {
    if (items.isEmpty) return;
    setState(() => _loadingPreviews = true);
    try {
      final urls = await _svc.fetchEnginePreviewUrls(
        academyId: scope.academyId,
        items: items,
      );
      if (!mounted) return;
      setState(() {
        _previewUrlsByCropId = urls;
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
    _editingVisualTags = [...item.visualTags];
    _editingAlternatives = [for (final a in item.alternativeSolutions) Map<String, dynamic>.from(a)];
    _ensureSelectedCards(item);
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

  Future<void> _bulkApproveClean(String axis) async {
    final ids = [
      for (final it in _items)
        if (axis == 'math' && it.mathStatus == 'clean')
          it.cropId
        else if (axis == 'quality' && it.qualityStatus == 'clean')
          it.cropId,
    ];
    if (ids.isEmpty) return;
    setState(() => _saving = true);
    try {
      final count = await _svc.approveAxis(ids, axis);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '${axis == 'math' ? '수학적 검수' : '품질 검수'} 정상 문항 $count개를 일괄 승인했습니다.';
      });
      await _loadUnits();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '일괄 승인 실패: $e';
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
      await _svc.saveItemEdit(
        cropId: item.cropId,
        newAnswer: overrideAnswer ?? _answerEditCtrl.text.trim(),
        aiSolution: _solutionEditCtrl.text.trim(),
        visualTags: _editingVisualTags,
        approveMath: approveMath,
        approveQuality: approveQuality,
        solutionTranscribed: origChanged ? origSol : null,
        solutionAnswer: origChanged ? origAns : null,
        alternativeSolutions: _editingAlternatives,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '문항 ${item.problemNumber}번 변경·승인을 반영했습니다.';
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
            (_filterTab == 4 && it.isFullyApproved))
          it,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final mathCleanCount = _items.where((x) => x.mathStatus == 'clean').length;
    final qualCleanCount = _items.where((x) => x.qualityStatus == 'clean').length;
    final issueCount = _items.where((x) => x.hasIssue).length;
    final draftCount = _items.where((x) => x.hasDrafts).length;

    return Container(
      color: _kBg,
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
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
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: _kChipSelected.withValues(alpha: 0.32),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _kAccent.withValues(alpha: 0.45)),
          ),
          child: const Icon(Icons.fact_check_outlined, color: _kAccent, size: 20),
        ),
        const SizedBox(width: 12),
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '문항검수',
              style: TextStyle(color: _kText, fontSize: 21, fontWeight: FontWeight.w900, letterSpacing: -0.3),
            ),
            SizedBox(height: 2),
            Text(
              '해설 PDF 좌표 영역 원본 해설 전사 · 블라인드 독립 풀이 · 3축 난이도 · V2 렌더 카드 학생 시점 품질 검수',
              style: TextStyle(color: _kTextSub, fontSize: 12.5),
            ),
          ],
        ),
        const Spacer(),
        if (_runningReview) ...[
          OutlinedButton.icon(
            onPressed: _stopRequested ? null : () => setState(() => _stopRequested = true),
            style: _outlineButtonStyle(color: _kError),
            icon: const Icon(Icons.pause_circle_outline, size: 17, color: _kError),
            label: Text(_stopRequested ? '이번 묶음 후 멈춤' : '일시정지', style: const TextStyle(color: _kError)),
          ),
          const SizedBox(width: 8),
        ] else ...[
          if (mathCleanCount > 0) ...[
            OutlinedButton.icon(
              onPressed: _saving ? null : () => unawaited(_bulkApproveClean('math')),
              style: _outlineButtonStyle(color: _kAccent),
              icon: const Icon(Icons.done_all_rounded, size: 17, color: _kAccent),
              label: Text('수학 정상 일괄 승인 ($mathCleanCount)'),
            ),
            const SizedBox(width: 8),
          ],
          if (qualCleanCount > 0) ...[
            OutlinedButton.icon(
              onPressed: _saving ? null : () => unawaited(_bulkApproveClean('quality')),
              style: _outlineButtonStyle(color: _kBlue),
              icon: const Icon(Icons.verified_outlined, size: 17, color: _kBlue),
              label: Text('품질 정상 일괄 승인 ($qualCleanCount)'),
            ),
            const SizedBox(width: 8),
          ],
          ElevatedButton.icon(
            onPressed: _selectedScope == null || _saving ? null : () => unawaited(_runUnitReview()),
            style: _primaryButtonStyle(),
            icon: const Icon(Icons.play_arrow_rounded, size: 19),
            label: const Text('중단원 문항 검수 실행'),
          ),
          const SizedBox(width: 6),
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
      ],
    );
  }

  Widget _buildScopeSelectorBar() {
    final books = _bookKeys;
    final units = _unitsForSelectedBook;
    final mathApproved = _items.where((x) => x.mathStatus == 'approved').length;
    final qualApproved = _items.where((x) => x.qualityStatus == 'approved').length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: _kPanelBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.menu_book_rounded, size: 17, color: _kAccent),
          const SizedBox(width: 8),
          const Text('교재', style: TextStyle(color: _kTextSub, fontSize: 12.5, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          Container(
            width: 240,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _kFieldBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _kBorder),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: books.contains(_selectedBookKey) ? _selectedBookKey : books.firstOrNull,
                isDense: true,
                isExpanded: true,
                dropdownColor: _kPanelBg,
                style: const TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w700),
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
              ),
            ),
          ),
          const SizedBox(width: 16),
          const Icon(Icons.folder_open_rounded, size: 17, color: _kBlue),
          const SizedBox(width: 8),
          const Text('중단원', style: TextStyle(color: _kTextSub, fontSize: 12.5, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _kFieldBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _kBorder),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: units.any((u) => u.key == _selectedScope?.key) ? _selectedScope?.key : units.firstOrNull?.key,
                  isDense: true,
                  isExpanded: true,
                  dropdownColor: _kPanelBg,
                  style: const TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w700),
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
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          _pillBadge('수학 승인 $mathApproved / ${_items.length}', _kAccent),
          const SizedBox(width: 8),
          _pillBadge('품질 승인 $qualApproved / ${_items.length}', _kBlue),
        ],
      ),
    );
  }

  Widget _buildMainWorkspace(int issueCount, int draftCount) {
    final filtered = _filteredItems;
    final selected = _items.where((x) => x.cropId == _selectedCropId).firstOrNull;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 좌측: 문항 리스트 패널
        SizedBox(
          width: 360,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _kPanelBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _kBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _filterTabChip(0, '전체 ${_items.length}'),
                    _filterTabChip(1, '오류·불일치 $issueCount', highlightError: issueCount > 0),
                    if (draftCount > 0) _filterTabChip(2, '새 초안 $draftCount'),
                    _filterTabChip(3, '미검수 ${_items.where((x) => x.mathStatus == 'pending').length}'),
                    _filterTabChip(4, '승인완료 ${_items.where((x) => x.isFullyApproved).length}'),
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(color: _kBorder, height: 1),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(child: Text('해당 조건의 문항이 없습니다.', style: TextStyle(color: _kTextSub)))
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 6),
                          itemBuilder: (_, i) => _problemListTile(filtered[i]),
                        ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 14),
        // 가운데: 수학 검수 · 품질 검수 · 해설 편집
        Expanded(
          child: selected == null
              ? _emptyPanel('좌측 목록에서 문항을 선택하세요.')
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildMathReviewCard(selected),
                      const SizedBox(height: 14),
                      _buildSolutionEditCard(selected),
                      const SizedBox(height: 14),
                      _buildQualityReviewCard(selected),
                    ],
                  ),
                ),
        ),
        const SizedBox(width: 14),
        // 우측: 학생이 보는 그대로 — V2 엔진 카드 세로 배치 (문항 → 정답+해설 → AI 풀이 → 대안 풀이)
        SizedBox(
          width: 440,
          child: selected == null ? _emptyPanel('V2 렌더 카드') : _buildV2CardStack(selected),
        ),
      ],
    );
  }

  Widget _emptyPanel(String text) => Container(
        decoration: BoxDecoration(
          color: _kPanelBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _kBorder),
        ),
        child: Center(child: Text(text, style: const TextStyle(color: _kTextSub))),
      );

  Widget _filterTabChip(int index, String label, {bool highlightError = false}) {
    final sel = _filterTab == index;
    final activeColor = highlightError ? _kError : _kAccent;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _filterTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? (highlightError ? _kError.withValues(alpha: 0.22) : _kChipSelected) : _kFieldBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: sel ? activeColor : _kBorder),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: sel ? _kText : (highlightError ? _kError : _kTextSub),
            fontSize: 12,
            fontWeight: sel ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ),
    );
  }

  (String, Color) _statusBadge(String st, String prefix) => switch (st) {
        'approved' => ('$prefix 승인', _kAccent),
        'clean' => ('$prefix 정상', _kBlue),
        'issue' => ('$prefix 오류', _kError),
        _ => ('$prefix 대기', _kTextMuted),
      };

  Widget _problemListTile(TextbookProblemReviewItem item) {
    final selected = item.cropId == _selectedCropId;
    final (mLabel, mColor) = _statusBadge(item.mathStatus, '수학');
    final (qLabel, qColor) = _statusBadge(item.qualityStatus, '품질');

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() => _selectItem(item)),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? _kChipSelected.withValues(alpha: 0.28) : _kFieldBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? _kAccent
                : item.hasIssue
                    ? _kError.withValues(alpha: 0.55)
                    : _kBorder,
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _kPanelBg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: _kBorder),
                  ),
                  child: Text(
                    '${item.problemNumber}번',
                    style: const TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w900),
                  ),
                ),
                const SizedBox(width: 8),
                if (item.isSetQuestion) ...[
                  _pillBadge(
                    item.setHeaderNumber.isNotEmpty ? '세트 ${item.setHeaderNumber}' : '세트형',
                    _kBlue,
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  'PDF ${item.rawPage}쪽',
                  style: const TextStyle(color: _kTextSub, fontSize: 11.5),
                ),
                const Spacer(),
                _pillBadge(mLabel, mColor),
                const SizedBox(width: 4),
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
                  _pillBadge(
                    item.renderChecks['problem_ok'] == false ||
                            item.renderChecks['answer_ok'] == false ||
                            item.renderChecks['solution_ok'] == false
                        ? 'V2 렌더 이상'
                        : 'V2 렌더 정상',
                    item.renderChecks['problem_ok'] == false ||
                            item.renderChecks['answer_ok'] == false ||
                            item.renderChecks['solution_ok'] == false
                        ? _kError
                        : _kAccent,
                  ),
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

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kPanelBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: (problemIssue || solutionIssue) ? _kError.withValues(alpha: 0.7) : _kBorder),
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
                    ],
                  ),
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
      decoration: BoxDecoration(
        color: _kPanelBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: item.mathStatus == 'issue' ? _kError.withValues(alpha: 0.7) : _kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.functions_rounded, color: _kAccent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '수학적 검수 (${item.matchMode == '3way' ? '기존답 · 해설답 · AI답 3자 대조' : '기존답 · AI답 2자 대조'})',
                  style: const TextStyle(color: _kText, fontSize: 15.5, fontWeight: FontWeight.w800),
                  overflow: TextOverflow.ellipsis,
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
          Row(
            children: [
              Expanded(
                child: _answerCompareTile(
                  '기존 저장 정답 (직접 수정 가능)',
                  child: SizedBox(
                    height: 36,
                    child: TextField(
                      controller: _answerEditCtrl,
                      style: const TextStyle(color: _kText, fontSize: 13.5, fontWeight: FontWeight.w800),
                      decoration: _inputDecoration('정답 입력'),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _answerCompareTile(
                  '원본 해설 정답 (Vision 전사)',
                  value: item.hasSolutionRef ? (item.solutionAnswer ?? (item.hasOriginalSolution ? '(답 표기 없음)' : '(전사 전)')) : '(해설 좌표 없음 · 2자 대조)',
                  accent: _kBlue,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _answerCompareTile(
                  'AI 블라인드 풀이 정답',
                  value: item.aiAnswer ?? '(검수 전)',
                  accent: matched == false ? _kError : _kAccent,
                ),
              ),
            ],
          ),
          if (matched == false && (item.mismatchReason ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            _buildBanner('불일치 분석: ${item.mismatchReason}', _kError, Icons.warning_amber_rounded),
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _kFieldBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _kBorder),
            ),
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
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _kChipSelected.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _kAccent),
                ),
                child: Row(
                  children: [
                    _pillBadge(
                      dp['target'] == 'arithmetic' ? '새 연산 초안' : '새 사고 초안',
                      _kAccent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${dp['title']} (${dp['category']} · ${dp['unit_score']}점) — ${dp['criteria'] ?? dp['trigger_cond'] ?? ''}',
                        style: const TextStyle(color: _kText, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 8),
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
      decoration: BoxDecoration(
        color: _kPanelBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: visionFailed ? _kWarn.withValues(alpha: 0.7) : _kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.menu_book_rounded, color: _kBlue, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '해설 — 원본 해설(교재)과 AI 독립 풀이를 따로 저장',
                  style: TextStyle(color: _kText, fontSize: 15.5, fontWeight: FontWeight.w800),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              _pillBadge(
                item.hasOriginalSolution
                    ? (item.solutionSource == 'manual' ? '원본 직접 입력' : '원본 Vision 전사${visionConf != null ? ' · $visionConf' : ''}')
                    : (item.hasSolutionRef ? '원본 미전사' : '해설 좌표 없음'),
                item.hasOriginalSolution ? _kBlue : (item.hasSolutionRef ? _kWarn : _kTextMuted),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _saving ? null : () => unawaited(_saveAndApproveSingle(item)),
                style: _primaryButtonStyle(),
                icon: const Icon(Icons.save_outlined, size: 17),
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
          Row(
            children: [
              const Expanded(
                child: Text('원본 해설 (교재 해설 PDF 전사 · 수정 가능)', style: TextStyle(color: _kTextSub, fontSize: 12)),
              ),
              SizedBox(
                width: 180,
                height: 34,
                child: TextField(
                  controller: _origAnswerCtrl,
                  style: const TextStyle(color: _kText, fontSize: 12.5, fontWeight: FontWeight.w700),
                  decoration: _inputDecoration('해설 정답'),
                ),
              ),
            ],
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kFieldBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kBorder),
      ),
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

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kPanelBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: item.qualityStatus == 'issue' ? _kError.withValues(alpha: 0.7) : _kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.high_quality_rounded, color: _kBlue, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '품질 검수 — 학생 시점 V2 렌더 기준',
                  style: TextStyle(color: _kText, fontSize: 15.5, fontWeight: FontWeight.w800),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              _pillBadge(qLabel, qColor),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _saving ? null : () => unawaited(_saveAndApproveSingle(item, approveQuality: true)),
                style: _primaryButtonStyle(),
                icon: const Icon(Icons.verified_outlined, size: 18),
                label: Text(item.qualityStatus == 'approved' ? '품질·시각태그 재저장' : '품질 검수 승인'),
              ),
            ],
          ),
          if (qc['issue_title'] != null) ...[
            const SizedBox(height: 10),
            _buildBanner('문항 카드 — ${qc['issue_title']}: ${qc['issue_detail'] ?? ''}', _kError, Icons.warning_amber_rounded),
          ],
          if (rc['issue_title'] != null) ...[
            const SizedBox(height: 8),
            _buildBanner('정답·해설 카드 — ${rc['issue_title']}: ${rc['issue_detail'] ?? ''}', _kError, Icons.warning_amber_rounded),
          ],
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

  Widget _visualTagChip(String label, {required bool selected, required VoidCallback onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? _kChipSelected : _kFieldBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? _kAccent : _kBorder),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w800),
      ),
    );
  }

  Widget _buildBanner(String text, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
      );

  ButtonStyle _outlineButtonStyle({required Color color}) => OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.6)),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
      );

  InputDecoration _inputDecoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: _kTextMuted, fontSize: 12.5),
        filled: true,
        fillColor: _kFieldBg,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _kBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _kAccent, width: 1.4),
        ),
      );
}
