import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/textbook_problem_review_service.dart';
import '../../widgets/latex_text_renderer.dart';
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
  String? _selectedCropId;

  /// 필터: 0 전체, 1 확인필요(오류·불일치), 2 새초안제안, 3 미검수, 4 승인완료
  int _filterTab = 0;

  final _answerEditCtrl = TextEditingController();
  final _solutionEditCtrl = TextEditingController();
  List<String> _editingVisualTags = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadUnits());
  }

  @override
  void dispose() {
    _answerEditCtrl.dispose();
    _solutionEditCtrl.dispose();
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

  Future<void> _loadItems(TextbookReviewUnitScope scope) async {
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
      unawaited(_loadEnginePreviews(scope, items));
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
    _editingVisualTags = [...item.visualTags];
  }

  Future<void> _runUnitReview({bool forceRerun = false}) async {
    final scope = _selectedScope;
    if (scope == null || _runningReview) return;
    setState(() {
      _runningReview = true;
      _stopRequested = false;
      _notice = null;
      _runProgress = '중단원 문항 검수를 시작하는 중 (세트 공통 발문 결합 · 블라인드 풀이 · 3축 난이도 · 품질 검사)...';
    });
    var totalProcessed = 0;
    try {
      for (var round = 0; round < 30; round += 1) {
        if (!mounted || _stopRequested) break;
        final res = await _svc.runReviewChunk(
          scope,
          chunkSize: 8,
          forceRerun: forceRerun && round == 0,
        );
        final processed = (res['processed'] as num?)?.toInt() ?? 0;
        final remaining = (res['remaining'] as num?)?.toInt() ?? 0;
        final total = (res['total'] as num?)?.toInt() ?? scope.problemCount;
        totalProcessed += processed;
        if (!mounted) return;
        await _loadItems(scope);
        setState(() {
          _runProgress = '검수 진행 중: ${total - remaining} / $total 문항 완료 (이번 묶음 $processed문항 처리)';
        });
        if (res['done'] == true || remaining <= 0 || processed <= 0) break;
      }
      if (!mounted) return;
      await _loadUnits();
      setState(() {
        _notice = _stopRequested
            ? '요청에 따라 일시정지했습니다 ($totalProcessed문항 검수 완료).'
            : '중단원 검수가 완료되었습니다 ($totalProcessed문항 처리). 정상 문항은 일괄 승인하고 확인 필요 문항만 점검하세요.';
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
      await _svc.saveItemEdit(
        cropId: item.cropId,
        newAnswer: overrideAnswer ?? _answerEditCtrl.text.trim(),
        aiSolution: _solutionEditCtrl.text.trim(),
        visualTags: _editingVisualTags,
        approveMath: approveMath,
        approveQuality: approveQuality,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '문항 ${item.problemNumber}번 변경·승인을 반영했습니다.';
      });
      if (_selectedScope != null) await _loadItems(_selectedScope!);
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
      if (_selectedScope != null) await _loadItems(_selectedScope!);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '초안 등록 실패: $e';
      });
    }
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
            child: _loadingUnits || _loadingItems
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
              '세트 공통 발문 결합 · 블라인드 독립 풀이 · 3축 난이도(개념/사고/연산) · V2 엔진 렌더링 카드 대조',
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
                          setState(() => _selectedScope = hit);
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
        // 좌측: 문항 리스트 패널 (신형 다크 틸 스타일)
        SizedBox(
          width: 390,
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
        // 우측: 선택된 문항의 [우리 엔진 렌더링 프리뷰 + 수학 검수 + 품질 검수] 상세 영역
        Expanded(
          child: selected == null
              ? Container(
                  decoration: BoxDecoration(
                    color: _kPanelBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _kBorder),
                  ),
                  child: const Center(child: Text('좌측 목록에서 문항을 선택하세요.', style: TextStyle(color: _kTextSub))),
                )
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildRenderedEnginePreviewSection(selected),
                      const SizedBox(height: 14),
                      _buildMathReviewCard(selected),
                      const SizedBox(height: 14),
                      _buildQualityReviewCard(selected),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

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
            if (item.totalDifficulty > 0 || item.visualTags.isNotEmpty) ...[
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
                  for (final vt in item.visualTags.take(2)) _pillBadge(vt, _kTextSub),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 상단: 학습앱 문제은행 카드와 동일한 우리 엔진(V2 서버 PDF 썸네일 + LatexTextRenderer) 렌더링 카드 뷰
  Widget _buildRenderedEnginePreviewSection(TextbookProblemReviewItem item) {
    final previewUrl = _previewUrlsByCropId[item.cropId];
    final qc = item.qualityChecks;
    final hasQualityIssue = item.qualityStatus == 'issue' || qc['issue_title'] != null;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kPanelBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: hasQualityIssue ? _kError.withValues(alpha: 0.7) : _kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.preview_rounded, color: _kAccent, size: 19),
              const SizedBox(width: 8),
              Text(
                '우리 엔진 렌더링 미리보기 — ${item.problemNumber}번',
                style: const TextStyle(color: _kText, fontSize: 15.5, fontWeight: FontWeight.w800),
              ),
              if (item.isSetQuestion) ...[
                const SizedBox(width: 8),
                _pillBadge(
                  item.setHeaderNumber.isNotEmpty
                      ? '독립/종속 세트 (${item.setHeaderNumber}) · 공통 발문 연결됨'
                      : '세트 문항 · 공통 발문 연결됨',
                  _kBlue,
                ),
              ],
              const Spacer(),
              if (_loadingPreviews)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: _kAccent),
                ),
            ],
          ),
          if (hasQualityIssue && qc['issue_title'] != null) ...[
            const SizedBox(height: 10),
            _buildBanner(
              '렌더링·전사 점검 사유 — ${qc['issue_title']}: ${qc['issue_detail'] ?? ''}',
              _kError,
              Icons.warning_amber_rounded,
            ),
          ],
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 좌측: 학습앱 문제은행 카드(서버 PDF V2 썸네일 이미지 그대로 표시)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '① 학습앱 문제은행 카드 이미지 (서버 PDF V2 엔진)',
                      style: TextStyle(color: _kTextSub, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    ProblemBankQuestionCard(
                      backgroundColor: Colors.white,
                      borderColor: hasQualityIssue ? _kError : const Color(0xFFD5DDDD),
                      child: SizedBox(
                        height: 230,
                        width: double.infinity,
                        child: previewUrl != null && previewUrl.isNotEmpty
                            ? Image.network(
                                previewUrl,
                                fit: BoxFit.fitWidth,
                                alignment: Alignment.topCenter,
                                errorBuilder: (_, __, ___) => _buildLatexEngineCardFallback(item),
                              )
                            : _buildLatexEngineCardFallback(item),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              // 우측: 수식 렌더러(LatexTextRenderer) 실시간 조판 및 공통 발문/개별 발문 분리 확인
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '② 공통 발문 + 개별 문항 수식 엔진(LatexTextRenderer) 조판',
                      style: TextStyle(color: _kTextSub, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    ProblemBankQuestionCard(
                      backgroundColor: Colors.white,
                      borderColor: const Color(0xFFD5DDDD),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 230),
                        padding: const EdgeInsets.all(10),
                        child: _buildLatexEngineCardFallback(item),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 학습앱/매니저앱 수식 렌더러(LatexTextRenderer)로 실제 문제은행 종이 카드 위에서 그리는 화면
  Widget _buildLatexEngineCardFallback(TextbookProblemReviewItem item) {
    final cleanCommon = _cleanMarkupForRender(item.commonStem);
    final cleanStem = _cleanMarkupForRender(item.stem);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cleanCommon.isNotEmpty && !cleanStem.contains(cleanCommon)) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F6F5),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFB8D4CE)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.setHeaderNumber.isNotEmpty
                        ? '[${item.setHeaderNumber} 공통 발문]'
                        : '[세트 공통 발문]',
                    style: const TextStyle(
                      color: Color(0xFF1B6B63),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  LatexTextRenderer(
                    cleanCommon,
                    softWrap: true,
                    enableDisplayMath: true,
                    style: const TextStyle(
                      color: Color(0xFF1E2929),
                      fontSize: 13.2,
                      fontWeight: FontWeight.w700,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${item.problemNumber}. ',
                style: const TextStyle(
                  color: Color(0xFF1B6B63),
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Expanded(
                child: LatexTextRenderer(
                  cleanStem.isEmpty ? '(발문 텍스트 없음)' : cleanStem,
                  softWrap: true,
                  enableDisplayMath: true,
                  style: const TextStyle(
                    color: Color(0xFF232323),
                    fontSize: 13.8,
                    height: 1.58,
                  ),
                ),
              ),
            ],
          ),
          if (item.choices.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                for (var i = 0; i < item.choices.length; i += 1)
                  LatexTextRenderer(
                    '${_circledNumber(i + 1)} ${_cleanMarkupForRender(item.choices[i])}',
                    style: const TextStyle(
                      color: Color(0xFF232323),
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _cleanMarkupForRender(String raw) {
    return raw
        .replaceAll('[문단]', '\n')
        .replaceAll('[박스시작]', '\n┌ ')
        .replaceAll('[박스끝]', ' ┘\n')
        .replaceAll('[표시작]', '\n')
        .replaceAll('[표끝]', '\n')
        .replaceAll(RegExp(r'\[\[?공백:\d+\]?\]'), ' □ ')
        .replaceAll(RegExp(r'\\text\{box\{~~\}\}'), ' □ ')
        .replaceAll('box{~~}', ' □ ')
        .trim();
  }

  String _circledNumber(int n) {
    const nums = ['①', '②', '③', '④', '⑤'];
    return (n >= 1 && n <= nums.length) ? nums[n - 1] : '$n)';
  }

  /// 1) 수학적 검수 카드 (신형 다크 틸 디자인)
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
              Text(
                '수학적 검수 (${item.matchMode == '3way' ? '기존답 · 해설답 · AI답 3자 대조' : '기존답 · AI답 2자 대조'})',
                style: const TextStyle(color: _kText, fontSize: 15.5, fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 8),
              _pillBadge(mLabel, mColor),
              const Spacer(),
              if (matched == false && (item.aiAnswer ?? '').isNotEmpty && item.aiAnswer != '판단불가') ...[
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
                const SizedBox(width: 8),
              ],
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
                  '2단계 AI 블라인드 풀이 정답',
                  value: item.aiAnswer ?? '(검수 전)',
                  accent: matched == false ? _kError : _kAccent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _answerCompareTile(
                  '1단계 해설지 추출 정답',
                  value: item.hasSolutionRef ? (item.solutionAnswer ?? '(추출 전)') : '(해설 좌표 없음 · 2자 대조)',
                  accent: _kBlue,
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
                Row(
                  children: [
                    const Text(
                      '3축 난이도 분해',
                      style: TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(width: 10),
                    _pillBadge('총점 ${item.totalDifficulty.toStringAsFixed(2)}점', _kAccent),
                    const SizedBox(width: 6),
                    _pillBadge('개념 ${item.conceptScore.toStringAsFixed(2)}점', _kBlue),
                    const SizedBox(width: 6),
                    _pillBadge('사고 ${item.thinkingScore.toStringAsFixed(2)}점', _kAccent),
                    const SizedBox(width: 6),
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
          const SizedBox(height: 12),
          const Text('AI 독립 풀이 과정 (LaTeX 지원 · 수정 가능)', style: TextStyle(color: _kTextSub, fontSize: 12)),
          const SizedBox(height: 6),
          TextField(
            controller: _solutionEditCtrl,
            maxLines: 4,
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
              LatexTextRenderer(
                value ?? '',
                style: TextStyle(color: accent, fontSize: 14, fontWeight: FontWeight.w800),
              ),
        ],
      ),
    );
  }

  /// 2) 품질 · V2 렌더링 · 시각 태그 검수 카드 (신형 다크 틸 디자인)
  Widget _buildQualityReviewCard(TextbookProblemReviewItem item) {
    final (qLabel, qColor) = _statusBadge(item.qualityStatus, '품질 검수');
    final qc = item.qualityChecks;
    final stemOk = qc['stem_ok'] != false;
    final choicesOk = qc['choices_ok'] != false;
    final figureOk = qc['figure_ok'] != false;
    final latexOk = qc['latex_v2_ok'] != false;

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
              const Text(
                '품질 · V2 렌더링 · 시각 요소 태그 검수',
                style: TextStyle(color: _kText, fontSize: 15.5, fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 8),
              _pillBadge(qLabel, qColor),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _saving ? null : () => unawaited(_saveAndApproveSingle(item, approveQuality: true)),
                style: _primaryButtonStyle(),
                icon: const Icon(Icons.verified_outlined, size: 18),
                label: Text(item.qualityStatus == 'approved' ? '품질·시각태그 재저장' : '품질 검수 승인'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _pillBadge(stemOk ? '발문·공통지시문 정상' : '발문 전사 확인필요', stemOk ? _kAccent : _kError),
              _pillBadge(choicesOk ? '선지·보기 완비' : '선지·보기 누락 의심', choicesOk ? _kAccent : _kError),
              _pillBadge(figureOk ? '도형 위치·크기 정상' : '도형 잘림/누락 의심', figureOk ? _kAccent : _kError),
              _pillBadge(latexOk ? 'V2 수식 문법 정상' : 'V2 수식·빈칸 표기 확인', latexOk ? _kAccent : _kError),
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
