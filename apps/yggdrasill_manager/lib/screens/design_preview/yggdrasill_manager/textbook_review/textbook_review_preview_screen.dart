import 'package:flutter/material.dart';

import '../../../think/think_style.dart';
import 'textbook_review_preview_mock.dart';

/// 매니저앱 '문항검수' 탭 Preview. 목업 데이터와 화면 안 상태만 쓴다(실제 저장 없음).
class TextbookReviewPreviewScreen extends StatelessWidget {
  const TextbookReviewPreviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kThinkBg,
      appBar: AppBar(
        backgroundColor: kThinkBg,
        foregroundColor: kThinkText,
        title: const Text('Preview · 문항검수'),
      ),
      body: const TextbookReviewPreviewBody(),
    );
  }
}

const _fieldStyle = TextStyle(color: kThinkText, fontSize: 13);

enum _ListFilter { decision, held, clean, all }

String _filterLabel(_ListFilter f) => switch (f) {
      _ListFilter.decision => '결정 필요',
      _ListFilter.held => '보류',
      _ListFilter.clean => '문제 없음',
      _ListFilter.all => '전체',
    };

IconData _filterIcon(_ListFilter f) => switch (f) {
      _ListFilter.decision => Icons.flag_outlined,
      _ListFilter.held => Icons.pause_circle_outline,
      _ListFilter.clean => Icons.check_circle_outline,
      _ListFilter.all => Icons.list_alt_outlined,
    };

bool _passes(ReviewItem item, _ListFilter f) => switch (f) {
      _ListFilter.decision => item.needsDecision,
      _ListFilter.held => item.held,
      _ListFilter.clean => !item.findings.any((x) => x.isActive),
      _ListFilter.all => true,
    };

Color _axisColor(AxisState s) => switch (s) {
      AxisState.pass => kThinkSuccess,
      AxisState.issue => kThinkError,
      AxisState.held => kThinkLink,
      AxisState.unchecked => kThinkHint,
    };

String _axisText(AxisState s) => switch (s) {
      AxisState.pass => '통과',
      AxisState.issue => '문제 있음',
      AxisState.held => '보류',
      AxisState.unchecked => '검사 전',
    };

IconData _targetIcon(ManualTarget t) => switch (t) {
      ManualTarget.answer => Icons.check_box_outlined,
      ManualTarget.solutionRef => Icons.description_outlined,
      ManualTarget.correctionNote => Icons.sticky_note_2_outlined,
    };

class _EditSession {
  _EditSession({
    required this.itemId,
    required this.findingId,
    required this.target,
    required this.objective,
    required String answer,
    required String note,
  })  : answer = TextEditingController(text: answer),
        note = TextEditingController(text: note);

  final String itemId;
  final String? findingId;
  ManualTarget target;
  bool objective;
  bool refNone = true;
  String noteAbout = 'solution';
  final TextEditingController answer;
  final TextEditingController note;
  final TextEditingController reason = TextEditingController();

  void dispose() {
    answer.dispose();
    note.dispose();
    reason.dispose();
  }
}

class TextbookReviewPreviewBody extends StatefulWidget {
  const TextbookReviewPreviewBody({super.key});

  @override
  State<TextbookReviewPreviewBody> createState() => _TextbookReviewPreviewBodyState();
}

class _TextbookReviewPreviewBodyState extends State<TextbookReviewPreviewBody> {
  final List<ReviewItem> _items = buildReviewMockItems();
  final Map<String, TextEditingController> _memos = {};
  _ListFilter _filter = _ListFilter.decision;
  int? _stage;
  String _selectedId = 'b3';
  _EditSession? _edit;

  @override
  void dispose() {
    for (final c in _memos.values) {
      c.dispose();
    }
    _edit?.dispose();
    super.dispose();
  }

  ReviewItem get _selected => _items.firstWhere((i) => i.id == _selectedId);

  Iterable<ReviewFinding> get _allFindings => _items.expand((i) => i.findings);

  TextEditingController _memo(String findingId) => _memos.putIfAbsent(findingId, TextEditingController.new);

  bool _matches(ReviewItem item) {
    final stage = _stage;
    return _passes(item, _filter) &&
        (stage == null || item.findings.any((f) => f.stage == stage && f.isActive));
  }

  ReviewItem? _nextPending(ReviewItem from) {
    final start = _items.indexOf(from);
    for (var k = 1; k < _items.length; k++) {
      final candidate = _items[(start + k) % _items.length];
      if (candidate.needsDecision) return candidate;
    }
    return null;
  }

  void _snack(String message, {bool error = false}) => showThinkSnack(context, message, error: error);

  void _select(ReviewItem item) {
    if (_edit != null && _edit!.itemId != item.id) _closeEditor();
    setState(() => _selectedId = item.id);
  }

  void _record(ReviewItem item, String action, String detail, {String? findingId}) {
    final memo = findingId == null ? '' : _memo(findingId).text.trim();
    item.history.insert(
      0,
      ReviewDecision(when: '방금', action: action, detail: memo.isEmpty ? detail : '$detail · $memo'),
    );
    if (findingId != null) _memo(findingId).clear();
  }

  void _apply(ReviewItem item, ReviewFinding f, ReviewProposal p) {
    setState(() {
      switch (p.target) {
        case ManualTarget.answer:
          item.answer = p.after;
          item.answerManual = true;
          f.state = FindingState.applied;
        case ManualTarget.solutionRef:
          item.solutionNone = true;
          f.state = FindingState.applied;
        case ManualTarget.correctionNote:
          f.state = FindingState.noted;
      }
      _record(item, '제안대로 반영', '${p.target.label} ${p.before} → ${p.after}', findingId: f.id);
    });
    _snack('반영했습니다. Preview라 실제로 저장하지 않습니다.');
  }

  void _quickFix(ReviewItem item, ReviewFinding f) {
    setState(() {
      item.solutionNone = true;
      f.state = FindingState.edited;
      _record(item, '직접 고침', '해설 위치 → 해설 없음', findingId: f.id);
    });
  }

  void _mark(ReviewItem item, ReviewFinding f, FindingState next, String action) {
    setState(() {
      f.heldNote = next == FindingState.held ? _memo(f.id).text.trim() : '';
      f.state = next;
      _record(item, action, f.title, findingId: f.id);
    });
  }

  void _openEditor(ReviewItem item, ReviewFinding? f) {
    final proposal = f?.proposal;
    final old = _edit;
    setState(() {
      _edit = _EditSession(
        itemId: item.id,
        findingId: f?.id,
        target: proposal?.target ?? f?.manualTarget ?? ManualTarget.answer,
        objective: RegExp(r'^[①-⑩,\s]+$').hasMatch(item.answer),
        answer: proposal?.target == ManualTarget.answer ? proposal!.after : item.answer,
        note: proposal?.target == ManualTarget.correctionNote ? proposal!.after : '',
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
  }

  void _closeEditor() {
    final old = _edit;
    setState(() => _edit = null);
    WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
  }

  void _saveEdit(ReviewItem item, ReviewFinding? f) {
    final e = _edit;
    if (e == null) return;
    var detail = '';
    switch (e.target) {
      case ManualTarget.answer:
        final value = e.answer.text.trim();
        if (value.isEmpty) {
          _snack('채점 정답을 입력하세요.', error: true);
          return;
        }
        detail = '채점 정답 ${item.answer} → $value';
      case ManualTarget.solutionRef:
        if (!e.refNone) {
          _snack('해설 위치는 교재 단계 창에서 상자로 지정합니다.', error: true);
          return;
        }
        detail = '해설 위치 → 해설 없음';
      case ManualTarget.correctionNote:
        final value = e.note.text.trim();
        if (value.isEmpty) {
          _snack('교정 의견을 입력하세요.', error: true);
          return;
        }
        detail = '교정 의견: $value';
    }
    final reason = e.reason.text.trim();
    setState(() {
      if (e.target == ManualTarget.answer) {
        item.answer = e.answer.text.trim();
        item.answerManual = true;
      } else if (e.target == ManualTarget.solutionRef) {
        item.solutionNone = true;
      }
      if (f != null) {
        f.state = e.target == ManualTarget.correctionNote ? FindingState.noted : FindingState.edited;
      }
      item.history.insert(
        0,
        ReviewDecision(when: '방금', action: '직접 고침', detail: reason.isEmpty ? detail : '$detail · $reason'),
      );
    });
    _closeEditor();
    _snack('저장했습니다. Preview라 실제로 저장하지 않습니다.');
  }

  Future<void> _releaseManual(ReviewItem item) async {
    final ok = await confirmThink(
      context,
      title: '수동 보호를 풀까요?',
      message: '${item.label}의 채점 정답 값은 그대로 둡니다. 보호를 풀면 다음 VLM 재실행이 이 값을 덮을 수 있습니다.',
      confirmLabel: '보호 풀기',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() {
      item.answerManual = false;
      item.history.insert(
        0,
        const ReviewDecision(when: '방금', action: '수동 보호 해제', detail: '값은 그대로, VLM 재실행이 다시 덮을 수 있음'),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = _selected;
    return Container(
      color: kThinkBg,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          const SizedBox(height: 16),
          _stageStrip(),
          const SizedBox(height: 12),
          _todoNotice(),
          const SizedBox(height: 16),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 320, child: _listPanel()),
                const SizedBox(width: 16),
                Expanded(child: _detailPanel(item)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 머리: 제목, 범위, 적재 확인 ─────────────────────────────────────────

  Widget _header() {
    return Row(
      children: [
        const Text('문항검수', style: TextStyle(color: kThinkText, fontSize: 24, fontWeight: FontWeight.w900)),
        const SizedBox(width: 12),
        const Tooltip(
          message: '원본 충실도 · 수학적 타당성 · 출력 품질로 문항을 확인합니다. 고칠지 말지는 사장님이 정합니다.',
          child: ThinkBadge('시범 범위 · 전수 검수', color: kThinkLink),
        ),
        const Spacer(),
        _scopeButton(Icons.menu_book_outlined, reviewScopeBook),
        const SizedBox(width: 8),
        _scopeButton(Icons.account_tree_outlined, reviewScopeUnit),
        const SizedBox(width: 16),
        Tooltip(
          message: '마지막 적재 확인 3분 전 · 10문항',
          child: OutlinedButton.icon(
            onPressed: () => _snack('Preview라 실행하지 않습니다. 실제 화면에서는 정답·해설 위치·문제은행 연결을 다시 확인합니다.'),
            style: thinkOutlineButton(),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('적재 확인 다시 실행'),
          ),
        ),
      ],
    );
  }

  Widget _scopeButton(IconData icon, String label) {
    return Material(
      color: kThinkPanel,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _snack('Preview라 범위는 바꾸지 않습니다.'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kThinkBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: kThinkSub),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              const Icon(Icons.expand_more, size: 16, color: kThinkHint),
            ],
          ),
        ),
      ),
    );
  }

  // ── 단계 진행 ──────────────────────────────────────────────────────────

  Widget _stageStrip() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final stage in reviewStages) ...[
          if (stage.index > 0) const SizedBox(width: 8),
          Expanded(child: _stageCard(stage)),
        ],
      ],
    );
  }

  ({String label, Color color}) _stageStatus(ReviewStage stage, int open, int held) {
    if (open > 0) return (label: '결정 $open건 남음', color: kThinkAccent);
    if (held > 0) return (label: '보류 $held건', color: kThinkLink);
    return switch (stage.state) {
      StageState.done || StageState.decision => (label: '완료', color: kThinkSuccess),
      StageState.running => (label: '진행 중', color: kThinkLink),
      StageState.waiting => (label: '대기', color: kThinkSub),
      StageState.notReady => (label: '준비 전', color: kThinkHint),
    };
  }

  Widget _stageCard(ReviewStage stage) {
    final open = _allFindings.where((f) => f.stage == stage.index && f.state == FindingState.open).length;
    final held = _allFindings.where((f) => f.stage == stage.index && f.state == FindingState.held).length;
    final status = _stageStatus(stage, open, held);
    final selected = _stage == stage.index;
    final tip = [
      stage.caption,
      if (stage.note.isNotEmpty) stage.note,
      selected ? '누르면 단계 거르기를 풉니다' : '누르면 이 단계에서 나온 항목만 봅니다',
    ].join('\n');
    return Tooltip(
      message: tip,
      child: Material(
        color: kThinkPanel,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() {
            _stage = selected ? null : stage.index;
            if (!selected) _filter = _ListFilter.all;
          }),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: selected ? kThinkAccent : kThinkBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      '${stage.index}',
                      style: TextStyle(color: status.color, fontSize: 13, fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        stage.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: stage.total == 0 ? 0 : stage.done / stage.total,
                        minHeight: 4,
                        backgroundColor: kThinkBorder,
                        color: status.color,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${stage.done}/${stage.total}',
                      style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  status.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: status.color, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _todoNotice() {
    final pending = _items.where((i) => i.needsDecision).length;
    final held = _items.where((i) => i.held).length;
    if (pending == 0) {
      return ThinkNotice(
        text: held > 0
            ? '결정이 필요한 문항은 없고 보류 $held개가 남았습니다. 마감 전에 정해 주세요.'
            : '지금 결정할 문항이 없습니다. 다음 단계(렌더 검수)를 기다립니다.',
        color: kThinkSuccess,
        icon: Icons.check_circle_outline,
      );
    }
    return ThinkNotice(
      text: '사장님 결정이 필요한 문항 $pending개${held > 0 ? ' · 보류 $held개' : ''}. 목록에서 하나씩 열어 결정하세요.',
      color: kThinkAccent,
      icon: Icons.flag_outlined,
    );
  }

  // ── 문항 목록 ──────────────────────────────────────────────────────────

  Widget _listPanel() {
    final visible = _items.where(_matches).toList();
    final stage = _stage;
    return ThinkPanel(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in _ListFilter.values)
                ThinkToggleChip(
                  label: '${_filterLabel(f)} ${_items.where((i) => _passes(i, f)).length}',
                  icon: _filterIcon(f),
                  selected: _filter == f,
                  onChanged: (_) => setState(() => _filter = f),
                ),
            ],
          ),
          if (stage != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$stage. ${reviewStages[stage].title} 단계 항목만',
                    style: const TextStyle(color: kThinkAccent, fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _stage = null),
                  style: TextButton.styleFrom(foregroundColor: kThinkSub),
                  child: const Text('단계 거르기 풀기'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: visible.isEmpty
                ? const Center(
                    child: Text('이 조건에 맞는 문항이 없습니다.', style: TextStyle(color: kThinkHint, fontSize: 13)),
                  )
                : ListView.separated(
                    itemCount: visible.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 4),
                    itemBuilder: (context, index) => _itemRow(visible[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _itemRow(ReviewItem item) {
    final selected = item.id == _selectedId;
    return Material(
      color: selected ? kThinkAccent.withValues(alpha: 0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _select(item),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text('${item.page}쪽', style: const TextStyle(color: kThinkHint, fontSize: 12)),
                        if (item.answerManual) ...[
                          const SizedBox(width: 4),
                          const Tooltip(
                            message: '사람이 고친 정답 · 수동 보호',
                            child: Icon(Icons.lock_outline, size: 14, color: kThinkSub),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.stem,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kThinkHint, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              for (final axis in ReviewAxis.values) ...[
                if (axis.index > 0) const SizedBox(width: 4),
                _axisDot(axis, item.axisState(axis)),
              ],
              const SizedBox(width: 8),
              SizedBox(
                width: 44,
                child: Align(alignment: Alignment.centerRight, child: _itemMark(item)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _axisDot(ReviewAxis axis, AxisState state) {
    return Tooltip(
      message: '${axis.label}: ${_axisText(state)}',
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: _axisColor(state), shape: BoxShape.circle),
      ),
    );
  }

  Widget _itemMark(ReviewItem item) {
    if (item.needsDecision) return const ThinkBadge('결정', color: kThinkAccent);
    if (item.held) return const ThinkBadge('보류', color: kThinkLink);
    return const Tooltip(
      message: '지금까지 문제 없음',
      child: Icon(Icons.check_circle_outline, size: 16, color: kThinkSuccess),
    );
  }

  // ── 문항 상세 ──────────────────────────────────────────────────────────

  Widget _detailPanel(ReviewItem item) {
    int order(ReviewFinding f) => switch (f.state) {
          FindingState.open => 0,
          FindingState.held => 1,
          _ => 2,
        };
    final findings = [...item.findings]..sort((a, b) => order(a).compareTo(order(b)));
    final active = findings.where((f) => f.isActive).length;
    final edit = _edit;
    final itemEdit = edit != null && edit.itemId == item.id && edit.findingId == null;
    return ThinkPanel(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _detailHeader(item, _nextPending(item)),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 248, child: _evidenceColumn(item)),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (itemEdit) ...[
                        _editor(item, null),
                        const SizedBox(height: 16),
                      ],
                      _sectionTitle('검수 항목', active > 0 ? '결정할 것 $active건' : '남은 결정 없음'),
                      const SizedBox(height: 8),
                      if (findings.isEmpty)
                        const Text(
                          '이 문항에서 나온 검수 항목이 없습니다.',
                          style: TextStyle(color: kThinkHint, fontSize: 13),
                        )
                      else
                        for (final f in findings) ...[
                          _findingCard(item, f),
                          const SizedBox(height: 12),
                        ],
                      const SizedBox(height: 12),
                      _sectionTitle('결정 기록', '${item.history.length}건 · 지우지 않고 쌓입니다'),
                      const SizedBox(height: 8),
                      _history(item),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailHeader(ReviewItem item, ReviewItem? next) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.label,
                style: const TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                '${item.unit} · 본문 ${item.page}쪽',
                style: const TextStyle(color: kThinkSub, fontSize: 13),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final axis in ReviewAxis.values) _axisChip(item, axis)],
              ),
            ],
          ),
        ),
        if (item.answerManual) ...[
          Tooltip(
            message: '값은 그대로 두고, VLM 재실행이 다시 덮을 수 있게 합니다',
            child: TextButton.icon(
              onPressed: () => _releaseManual(item),
              style: TextButton.styleFrom(foregroundColor: kThinkSub),
              icon: const Icon(Icons.lock_open_outlined, size: 16),
              label: const Text('수동 보호 풀기'),
            ),
          ),
          const SizedBox(width: 8),
        ],
        OutlinedButton.icon(
          onPressed: () => _openEditor(item, null),
          style: thinkOutlineButton(),
          icon: const Icon(Icons.edit_outlined, size: 16),
          label: const Text('직접 고치기'),
        ),
        if (next != null) ...[
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: () => _select(next),
            style: TextButton.styleFrom(foregroundColor: kThinkAccent),
            icon: const Icon(Icons.skip_next_outlined, size: 16),
            label: const Text('다음 결정'),
          ),
        ],
      ],
    );
  }

  Widget _axisChip(ReviewItem item, ReviewAxis axis) {
    final state = item.axisState(axis);
    final count = item.findings.where((f) => f.axis == axis && f.isActive).length;
    final color = _axisColor(state);
    final text = switch (state) {
      AxisState.issue => '문제 $count건',
      AxisState.held => '보류 $count건',
      _ => _axisText(state),
    };
    return Tooltip(
      message: axis.hint,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: kThinkBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: state == AxisState.issue ? kThinkError.withValues(alpha: 0.5) : kThinkBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(axis.label, style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Text(
              text,
              style: TextStyle(
                color: state == AxisState.unchecked ? kThinkSub : color,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _evidenceColumn(ReviewItem item) {
    final differs = item.aiAnswer != item.answer;
    final solution = item.solutionNone
        ? '해설 없음 (사람이 확정)'
        : item.solutionPage == null
            ? '위치 없음'
            : '해설지 ${item.solutionPage}쪽';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _evidenceBox(
          title: '문항 · 본문 ${item.page}쪽',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 120,
                decoration: BoxDecoration(
                  color: kThinkBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kThinkBorder),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.image_outlined, size: 24, color: kThinkHint),
                    const SizedBox(height: 4),
                    Text('본문 ${item.page}쪽 문항 영역', style: const TextStyle(color: kThinkHint, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(item.stem, style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.4)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _evidenceBox(
          title: '채점 정답',
          trailing: ThinkBadge(
            item.answerManual ? '수동 보호' : 'VLM',
            color: item.answerManual ? kThinkSuccess : kThinkSub,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.answer,
                style: const TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                item.answerManual ? '사람이 고친 값. VLM 재실행이 덮지 않습니다.' : '정답 단계에서 VLM이 읽은 값',
                style: const TextStyle(color: kThinkHint, fontSize: 12, height: 1.4),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _evidenceBox(
          title: 'AI 독립 풀이',
          trailing: const Tooltip(
            message: '정답·해설을 보지 않고 먼저 풉니다',
            child: Icon(Icons.visibility_off_outlined, size: 16, color: kThinkHint),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.aiAnswer,
                style: TextStyle(
                  color: differs ? kThinkAccent : kThinkText,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(item.aiNote, style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.4)),
              if (differs) ...[
                const SizedBox(height: 4),
                const Text(
                  '채점 정답과 다름',
                  style: TextStyle(color: kThinkAccent, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        _evidenceBox(
          title: '해설',
          child: Text(solution, style: const TextStyle(color: kThinkText, fontSize: 13)),
        ),
      ],
    );
  }

  Widget _evidenceBox({required String title, required Widget child, Widget? trailing}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: kThinkQuote, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, String trailing) {
    return Row(
      children: [
        Text(title, style: const TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(trailing, style: const TextStyle(color: kThinkHint, fontSize: 13)),
        ),
      ],
    );
  }

  // ── 검수 항목: 무엇이 문제인가 / 어떻게 고칠까 / 결정 ───────────────────

  Widget _findingCard(ReviewItem item, ReviewFinding f) {
    if (!f.isActive) return _closedFinding(item, f);
    final held = f.state == FindingState.held;
    final proposal = f.proposal;
    final staleNote = f.staleNote;
    final edit = _edit;
    final editing = edit != null && edit.findingId == f.id;
    final borderColor = held
        ? kThinkLink.withValues(alpha: 0.4)
        : f.blocker
            ? kThinkError.withValues(alpha: 0.5)
            : kThinkBorder;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kThinkBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (f.blocker) ...[
                const ThinkBadge('꼭 고칠 것', color: kThinkError),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  '${f.axis.label} · ${reviewStages[f.stage].title} 단계 · ${f.source}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kThinkHint, fontSize: 12),
                ),
              ),
              ThinkBadge(held ? '보류' : '결정 필요', color: held ? kThinkLink : kThinkAccent),
            ],
          ),
          const SizedBox(height: 10),
          Text(f.title, style: const TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800)),
          if (held && f.heldNote.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('보류 메모 · ${f.heldNote}', style: const TextStyle(color: kThinkLink, fontSize: 12)),
          ],
          if (staleNote != null) ...[
            const SizedBox(height: 12),
            ThinkNotice(text: staleNote, color: kThinkError, icon: Icons.history),
          ],
          const SizedBox(height: 16),
          _label('무엇이 문제인가'),
          const SizedBox(height: 8),
          Text(f.detail, style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
          if (f.evidence.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final e in f.evidence) _evidenceChip(e)],
            ),
          ],
          const SizedBox(height: 16),
          _label('어떻게 고칠까'),
          const SizedBox(height: 8),
          if (proposal != null) _proposalBox(proposal) else _howTo(f),
          const SizedBox(height: 16),
          if (editing)
            _editor(item, f)
          else ...[
            TextField(
              controller: _memo(f.id),
              style: _fieldStyle,
              decoration: thinkInputDecoration(hint: '결정 메모 (선택) · 결정 기록에 함께 남습니다', dense: true),
            ),
            const SizedBox(height: 12),
            _actions(item, f, proposal, stale: staleNote != null),
          ],
        ],
      ),
    );
  }

  Widget _label(String text) {
    return Text(text, style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w800));
  }

  Widget _evidenceChip(ReviewEvidence e) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: kThinkQuote,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkBorder),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '${e.label}  ', style: const TextStyle(color: kThinkHint, fontSize: 12)),
            TextSpan(
              text: e.value,
              style: const TextStyle(color: kThinkText, fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _proposalBox(ReviewProposal p) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: kThinkQuote, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 96,
                child: Text(
                  p.target.label,
                  style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
              Flexible(
                child: Text(
                  p.before,
                  style: const TextStyle(
                    color: kThinkHint,
                    fontSize: 14,
                    decoration: TextDecoration.lineThrough,
                    decorationColor: kThinkHint,
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.arrow_forward, size: 16, color: kThinkSub),
              ),
              Flexible(
                flex: 2,
                child: Text(
                  p.after,
                  style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _kv('근거', p.reason),
          const SizedBox(height: 4),
          _kv('바뀌는 것', p.changes),
          const SizedBox(height: 4),
          _kv('그대로 두는 것', p.keeps),
        ],
      ),
    );
  }

  Widget _kv(String key, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 96, child: Text(key, style: const TextStyle(color: kThinkHint, fontSize: 12))),
        Expanded(child: Text(value, style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.4))),
      ],
    );
  }

  Widget _howTo(ReviewFinding f) {
    final lines = f.howTo.isEmpty ? const ['정해진 고침 값이 없습니다. 원본을 보고 직접 판정하세요.'] : f.howTo;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: kThinkQuote, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '제안 값 없음 · 사장님이 판단',
            style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('·  ', style: TextStyle(color: kThinkHint, fontSize: 13)),
                  Expanded(
                    child: Text(line, style: const TextStyle(color: kThinkSub, fontSize: 13, height: 1.5)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _actions(ReviewItem item, ReviewFinding f, ReviewProposal? proposal, {required bool stale}) {
    final held = f.state == FindingState.held;
    final quickFix = f.quickFix;
    final textStyle = TextButton.styleFrom(foregroundColor: kThinkSub);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (proposal != null)
          Tooltip(
            message: stale ? '옛 값 기준 제안이라 막았습니다' : '제안 값을 사람이 고친 값으로 저장합니다',
            child: ElevatedButton.icon(
              onPressed: stale ? null : () => _apply(item, f, proposal),
              style: thinkPrimaryButton(),
              icon: const Icon(Icons.check, size: 16),
              label: const Text('제안대로 반영'),
            ),
          ),
        if (quickFix != null)
          ElevatedButton.icon(
            onPressed: () => _quickFix(item, f),
            style: thinkPrimaryButton(),
            icon: const Icon(Icons.do_not_disturb_on_outlined, size: 16),
            label: Text(quickFix),
          ),
        Tooltip(
          message: '값을 직접 입력해 고칩니다',
          child: OutlinedButton.icon(
            onPressed: () => _openEditor(item, f),
            style: thinkOutlineButton(),
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('직접 고치기'),
          ),
        ),
        Tooltip(
          message: '값을 바꾸지 않고 닫습니다. 그 값이 바뀌기 전에는 다시 열리지 않습니다',
          child: OutlinedButton.icon(
            onPressed: () => _mark(item, f, FindingState.dismissed, '문제 없음'),
            style: thinkOutlineButton(),
            icon: const Icon(Icons.check_circle_outline, size: 16),
            label: const Text('문제 없음'),
          ),
        ),
        if (held)
          TextButton.icon(
            onPressed: () => _mark(item, f, FindingState.open, '보류 풀기'),
            style: textStyle,
            icon: const Icon(Icons.replay, size: 16),
            label: const Text('보류 풀기'),
          )
        else
          Tooltip(
            message: '나중에 정합니다. 메모를 남기면 보류 사유로 보입니다',
            child: TextButton.icon(
              onPressed: () => _mark(item, f, FindingState.held, '보류'),
              style: textStyle,
              icon: const Icon(Icons.pause_circle_outline, size: 16),
              label: const Text('보류'),
            ),
          ),
        if (stale)
          TextButton.icon(
            onPressed: () => _snack('Preview라 실행하지 않습니다. 실제 화면에서는 지금 값으로 이 문항만 다시 대조합니다.'),
            style: TextButton.styleFrom(foregroundColor: kThinkLink),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('지금 값으로 다시 검사'),
          ),
      ],
    );
  }

  Widget _closedFinding(ReviewItem item, ReviewFinding f) {
    final (label, color, icon) = switch (f.state) {
      FindingState.applied => ('제안대로 반영', kThinkSuccess, Icons.check_circle),
      FindingState.edited => ('직접 고침', kThinkSuccess, Icons.edit),
      FindingState.noted => ('교정 의견 저장', kThinkSuccess, Icons.sticky_note_2_outlined),
      _ => ('문제 없음', kThinkSub, Icons.remove_circle_outline),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: kThinkBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kThinkBorder),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              f.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kThinkSub, fontSize: 13),
            ),
          ),
          if (f.state == FindingState.dismissed)
            TextButton(
              onPressed: () => _mark(item, f, FindingState.open, '다시 열기'),
              style: TextButton.styleFrom(foregroundColor: kThinkSub),
              child: const Text('다시 열기'),
            )
          else
            const Tooltip(
              message: '되돌리려면 직접 고치기로 새 값을 저장합니다',
              child: Icon(Icons.info_outline, size: 16, color: kThinkHint),
            ),
        ],
      ),
    );
  }

  Widget _history(ReviewItem item) {
    if (item.history.isEmpty) {
      return const Text('아직 결정 기록이 없습니다.', style: TextStyle(color: kThinkHint, fontSize: 13));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final d in item.history)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 96, child: Text(d.when, style: const TextStyle(color: kThinkHint, fontSize: 12))),
                SizedBox(
                  width: 96,
                  child: Text(
                    d.action,
                    style: const TextStyle(color: kThinkText, fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
                Expanded(
                  child: Text(d.detail, style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.4)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ── 직접 고치기 ────────────────────────────────────────────────────────

  Widget _editor(ReviewItem item, ReviewFinding? f) {
    final e = _edit!;
    final protects = e.target != ManualTarget.correctionNote;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kThinkPanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kThinkAccent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.edit_outlined, size: 16, color: kThinkAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '직접 고치기 · ${item.label}',
                  style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: '닫기',
                onPressed: _closeEditor,
                icon: const Icon(Icons.close, size: 16, color: kThinkSub),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in ManualTarget.values)
                ThinkToggleChip(
                  label: t.label,
                  icon: _targetIcon(t),
                  selected: e.target == t,
                  onChanged: (_) => setState(() => e.target = t),
                ),
            ],
          ),
          const SizedBox(height: 16),
          ...switch (e.target) {
            ManualTarget.answer => _answerFields(item, e),
            ManualTarget.solutionRef => _refFields(e),
            ManualTarget.correctionNote => _noteFields(e),
          },
          const SizedBox(height: 16),
          TextField(
            controller: e.reason,
            style: _fieldStyle,
            decoration: thinkInputDecoration(
              label: '고친 이유',
              hint: '예: 정답지 34쪽 3번 확인 · 결정 기록에 남습니다',
              dense: true,
            ),
          ),
          const SizedBox(height: 12),
          ThinkNotice(
            text: protects
                ? '저장하면 사람이 고친 값으로 보호됩니다. VLM을 다시 돌려도 덮지 않고, '
                    '학생 채점 캐시와 정답 그림은 새 값으로 다시 만듭니다. 이미 채점된 기록은 그대로입니다.'
                : '교정 의견은 교재 원본과 채점 정답을 바꾸지 않습니다. 직원 화면에만 보입니다.',
            color: protects ? kThinkSuccess : kThinkBlue,
            icon: protects ? Icons.shield_outlined : Icons.info_outline,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: () => _saveEdit(item, f),
                style: thinkPrimaryButton(),
                icon: const Icon(Icons.save_outlined, size: 16),
                label: const Text('저장'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _closeEditor,
                style: thinkOutlineButton(),
                child: const Text('취소'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _answerFields(ReviewItem item, _EditSession e) {
    final value = e.answer.text.trim();
    return [
      Row(
        children: [
          ThinkToggleChip(
            label: '객관식',
            icon: Icons.looks_one_outlined,
            selected: e.objective,
            onChanged: (_) => setState(() => e.objective = true),
          ),
          const SizedBox(width: 8),
          ThinkToggleChip(
            label: '주관식',
            icon: Icons.short_text,
            selected: !e.objective,
            onChanged: (_) => setState(() => e.objective = false),
          ),
        ],
      ),
      const SizedBox(height: 12),
      TextField(
        controller: e.answer,
        onChanged: (_) => setState(() {}),
        style: _fieldStyle,
        decoration: thinkInputDecoration(
          label: '채점 정답',
          hint: e.objective ? '예: ③ 또는 ②, ④' : r'예: 2^2 \times 3',
          dense: true,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        '지금 ${item.answer}  →  저장 ${value.isEmpty ? '(비어 있음)' : value}',
        style: const TextStyle(color: kThinkSub, fontSize: 12),
      ),
    ];
  }

  List<Widget> _refFields(_EditSession e) {
    return [
      Row(
        children: [
          ThinkToggleChip(
            label: '해설 없음으로 표시',
            icon: Icons.do_not_disturb_on_outlined,
            selected: e.refNone,
            onChanged: (_) => setState(() => e.refNone = true),
          ),
          const SizedBox(width: 8),
          ThinkToggleChip(
            label: '위치 다시 지정',
            icon: Icons.crop_free,
            selected: !e.refNone,
            onChanged: (_) => setState(() => e.refNone = false),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (e.refNone)
        const Text(
          '학생 화면의 해설 보기가 "해설 없음"으로 바뀝니다. 채점 정답은 그대로입니다.',
          style: TextStyle(color: kThinkSub, fontSize: 12, height: 1.4),
        )
      else
        Row(
          children: [
            const Expanded(
              child: Text(
                '해설 위치는 해설지 화면에서 상자로 그려야 합니다. 교재 단계 창에서 이 문항을 열어 지정하세요.',
                style: TextStyle(color: kThinkSub, fontSize: 12, height: 1.4),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => _snack('Preview라 열지 않습니다. 실제 화면에서는 교재 단계 창의 해설 단계를 이 문항으로 엽니다.'),
              style: thinkOutlineButton(),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('교재 단계 창 열기'),
            ),
          ],
        ),
    ];
  }

  List<Widget> _noteFields(_EditSession e) {
    const abouts = {'solution': '해설', 'answer': '정답', 'problem': '문항'};
    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final entry in abouts.entries)
            ThinkToggleChip(
              label: '${entry.value}에 대한 의견',
              icon: Icons.sticky_note_2_outlined,
              selected: e.noteAbout == entry.key,
              onChanged: (_) => setState(() => e.noteAbout = entry.key),
            ),
        ],
      ),
      const SizedBox(height: 12),
      TextField(
        controller: e.note,
        minLines: 2,
        maxLines: 4,
        style: _fieldStyle,
        decoration: thinkInputDecoration(label: '교정 의견', hint: '예: 해설 셋째 줄 2×3² = 36 → 18 (원본 오기)'),
      ),
    ];
  }
}
