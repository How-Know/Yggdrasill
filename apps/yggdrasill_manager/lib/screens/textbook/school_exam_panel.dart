import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/school_exam_review_service.dart';
import '../../services/textbook_problem_review_service.dart';
import '../../services/textbook_workflow_runner.dart';
import '../../services/textbook_workflow_service.dart';
import '../problem_roadmap/problem_roadmap_screen.dart';

// 교재 화면(textbook_migration_pane.dart)이 쓰는 색 그대로.
const Color _kPanel = Color(0xFF131315);
const Color _kInner = Color(0xFF181818);
const Color _kBorder = Color(0xFF2A2A2A);
const Color _kAccent = Color(0xFF33A373);
const Color _kTextSub = Color(0xFF9FB3B3);
const Color _kTextMuted = Color(0xFF8A8A8A);
const Color _kListText = Color(0xFFD8E0E0);
const Color _kSelectedRow = Color(0xFF1B2B1B);
const Color _kGreen = Color(0xFF7CC67C);
const Color _kWarn = Color(0xFFEAB968);
const Color _kWarnBg = Color(0xFF2D2419);
const Color _kBlue = Color(0xFF7AA9E6);
const Color _kBlueBg = Color(0xFF1B2430);
const Color _kError = Color(0xFFE68A8A);
const Color _kNeutralBg = Color(0xFF222222);
const Color _kNeutralFg = Color(0xFF808080);

/// 교재 메뉴의 내신기출 목록 상태. 검수 실행기의 작업이 끝날 때마다 목록을 다시 읽는다.
class SchoolExamController extends ChangeNotifier {
  SchoolExamController({SchoolExamReviewService? service}) : service = service ?? SchoolExamReviewService() {
    TextbookWorkflowRunner.instance.addListener(_onRunnerChanged);
  }

  final SchoolExamReviewService service;

  String? academyId;
  List<SchoolExamSchool> schools = const [];
  bool loading = false;
  String? error;

  bool _resumeChecked = false;
  bool _disposed = false;
  int _loadSeq = 0;
  Set<String> _activeKeys = const {};

  int get examCount => schools.fold(0, (n, s) => n + s.exams.length);

  SchoolExamSchool? schoolNamed(String? name) {
    if (name == null) return null;
    for (final s in schools) {
      if (s.name == name) return s;
    }
    return null;
  }

  Iterable<SchoolExamDocument> get allExams => schools.expand((s) => s.exams);

  /// 지금 이 앱에서 돌고 있거나 방금 끝난 시험지 작업. 키는 문서 id.
  Map<String, TextbookWorkflowRunState> liveStates() => {
        for (final s in TextbookWorkflowRunner.instance.states)
          if (s.order.isSchoolExam) s.order.bookId: s,
      };

  /// 목록을 읽는다. 처음 읽을 때 앱을 닫아 멈춰 있던 검수를 이어 돌리고 그 수를 돌려준다.
  Future<int> load({bool silent = false}) async {
    final seq = ++_loadSeq;
    if (!silent) {
      loading = true;
      error = null;
      _notify();
    }
    try {
      final id = academyId ?? await service.resolveAcademyId();
      final list = await service.fetchSchools(id);
      if (_disposed || seq != _loadSeq) return 0;
      academyId = id;
      schools = list;
      loading = false;
      error = null;
      var resumed = 0;
      if (!_resumeChecked) {
        _resumeChecked = true;
        resumed = service.resumeUnfinished(list);
      }
      _activeKeys = _currentActiveKeys();
      _notify();
      return resumed;
    } catch (e) {
      if (_disposed || seq != _loadSeq) return 0;
      loading = false;
      if (!silent || schools.isEmpty) error = SchoolExamReviewService.describeError(e);
      _notify();
      return 0;
    }
  }

  Set<String> _currentActiveKeys() => {
        for (final s in TextbookWorkflowRunner.instance.states)
          if (s.active && s.order.isSchoolExam) s.key,
      };

  void _onRunnerChanged() {
    if (_disposed) return;
    final active = _currentActiveKeys();
    final finished = _activeKeys.difference(active);
    _activeKeys = active;
    _notify();
    if (finished.isNotEmpty) unawaited(load(silent: true));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    TextbookWorkflowRunner.instance.removeListener(_onRunnerChanged);
    super.dispose();
  }
}

/// 교재 목록 맨 아래의 "내신기출" 묶음: 접고 펼 수 있고, 아래에 학교가 나온다.
class SchoolExamListSection extends StatelessWidget {
  const SchoolExamListSection({
    super.key,
    required this.controller,
    required this.expanded,
    required this.selectedSchool,
    required this.onToggle,
    required this.onSelect,
  });

  final SchoolExamController controller;
  final bool expanded;
  final String? selectedSchool;
  final VoidCallback onToggle;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final live = controller.liveStates();
        final schools = controller.schools;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Divider(height: 1, color: _kBorder),
            InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 12, 14, 10),
                child: Row(
                  children: [
                    Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 16, color: _kTextSub),
                    const SizedBox(width: 4),
                    const Expanded(
                      child: Text(
                        '내신기출',
                        style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800),
                      ),
                    ),
                    if (controller.loading)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2, color: _kAccent),
                      )
                    else
                      Text(
                        '${controller.examCount}부',
                        style: const TextStyle(color: _kTextMuted, fontSize: 11),
                      ),
                  ],
                ),
              ),
            ),
            if (expanded && controller.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '목록을 읽지 못했습니다: ${controller.error}',
                      style: const TextStyle(color: _kError, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: () => unawaited(controller.load()),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 24),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('다시 시도', style: TextStyle(color: _kError, fontSize: 12)),
                    ),
                  ],
                ),
              )
            else if (expanded && schools.isEmpty && !controller.loading)
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 14, 12),
                child: Text(
                  '등록된 시험지가 없습니다. 위의 "내신기출 업로드"로 올리세요.',
                  style: TextStyle(color: _kTextMuted, fontSize: 12),
                ),
              )
            else if (expanded)
              for (final school in schools)
                _SchoolRow(
                  school: school,
                  selected: school.name == selectedSchool,
                  running: school.exams.any((e) => live[e.id]?.active ?? false),
                  onTap: () => onSelect(school.name),
                ),
          ],
        );
      },
    );
  }
}

class _SchoolRow extends StatelessWidget {
  const _SchoolRow({required this.school, required this.selected, required this.running, required this.onTap});

  final SchoolExamSchool school;
  final bool selected;
  final bool running;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 8, 14, 8),
        color: selected ? _kSelectedRow : Colors.transparent,
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.school_outlined,
              size: 16,
              color: selected ? _kGreen : _kTextSub,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                school.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? Colors.white : _kListText,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ),
            if (running) ...[
              const SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 2, color: _kAccent),
              ),
              const SizedBox(width: 8),
            ],
            Tooltip(
              message: '확정 ${school.confirmedCount}부 / 전체 ${school.exams.length}부',
              child: Text(
                '${school.confirmedCount}/${school.exams.length}',
                style: const TextStyle(color: _kTextMuted, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExamStatus {
  const _ExamStatus(this.label, this.fg, this.bg, {this.detail = '', this.spinning = false});

  final String label;
  final Color fg;
  final Color bg;
  final String detail;
  final bool spinning;
}

_ExamStatus _statusOf(SchoolExamDocument doc, TextbookWorkflowRunState? live) {
  final wf = doc.workflow;
  if (live != null && live.active) {
    return _ExamStatus(TextbookWorkflowPhase.label(live.phase), _kGreen, _kSelectedRow, detail: live.detail, spinning: true);
  }
  final stage = doc.stage;
  if (stage == SchoolExamStage.confirmed) return const _ExamStatus('확정', _kGreen, _kSelectedRow);
  if (live != null && live.phase == TextbookWorkflowPhase.failed) {
    return _ExamStatus('실패', _kError, _kNeutralBg, detail: live.error.isNotEmpty ? live.error : live.detail);
  }
  if (live != null && live.phase == TextbookWorkflowPhase.cancelled) {
    return _ExamStatus('중단됨', _kWarn, _kWarnBg, detail: live.detail);
  }
  if (live != null && live.phase == TextbookWorkflowPhase.done && stage != SchoolExamStage.reviewing) {
    return _ExamStatus('검수 대기', _kBlue, _kBlueBg, detail: live.summaryText);
  }
  switch (stage) {
    case SchoolExamStage.noPdf:
      return const _ExamStatus('PDF 없음', _kNeutralFg, _kNeutralBg, detail: '문제은행에서 시험지 PDF 를 붙이면 검수할 수 있습니다');
    case SchoolExamStage.notStarted:
      return const _ExamStatus('검수 전', _kNeutralFg, _kNeutralBg);
    case SchoolExamStage.running:
      return _ExamStatus(
        '멈춤',
        _kWarn,
        _kWarnBg,
        detail: '${TextbookWorkflowPhase.label(wf?.pipelinePhase ?? '')} 단계에서 멈췄습니다',
      );
    case SchoolExamStage.failed:
      final err = (wf?.pipelineError ?? '').trim();
      return _ExamStatus('실패', _kError, _kNeutralBg, detail: err.isNotEmpty ? err : (wf?.pipelineDetail ?? ''));
    case SchoolExamStage.stopped:
      return _ExamStatus('중단됨', _kWarn, _kWarnBg, detail: wf?.pipelineDetail ?? '');
    case SchoolExamStage.reviewing:
      return _ExamStatus('검수 대기', _kBlue, _kBlueBg, detail: wf?.pipelineDetail ?? '');
    case SchoolExamStage.confirmed:
      return const _ExamStatus('확정', _kGreen, _kSelectedRow);
  }
}

/// 고른 학교의 시험지 목록: 검수 시작·열기·이어서 진행, 초안 삭제.
class SchoolExamSchoolPanel extends StatefulWidget {
  const SchoolExamSchoolPanel({
    super.key,
    required this.controller,
    required this.schoolName,
    required this.onToast,
  });

  final SchoolExamController controller;
  final String schoolName;
  final void Function(String message, {bool error}) onToast;

  @override
  State<SchoolExamSchoolPanel> createState() => _SchoolExamSchoolPanelState();
}

class _SchoolExamSchoolPanelState extends State<SchoolExamSchoolPanel> {
  final Set<String> _busy = <String>{};
  bool _bulkBusy = false;

  SchoolExamController get _c => widget.controller;

  Future<bool> _startOne(SchoolExamDocument doc) async {
    final academyId = _c.academyId;
    if (academyId == null) return false;
    await _c.service.startReview(academyId: academyId, documentId: doc.id, published: doc.published);
    return true;
  }

  Future<void> _start(SchoolExamDocument doc) async {
    if (_busy.contains(doc.id)) return;
    setState(() => _busy.add(doc.id));
    try {
      if (await _startOne(doc)) {
        await _c.load(silent: true);
        widget.onToast('${doc.title} 검수를 시작했습니다');
      }
    } catch (e) {
      widget.onToast('검수 시작 실패: ${SchoolExamReviewService.describeError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(doc.id));
    }
  }

  Future<void> _startAll(List<SchoolExamDocument> docs) async {
    if (docs.isEmpty || _bulkBusy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B1B1D),
        title: const Text('검수 시작', style: TextStyle(color: Colors.white)),
        content: Text(
          '${widget.schoolName}의 검수 전 시험지 ${docs.length}부를 검수 대기열에 넣습니다.\n'
          'AI 검수는 2부씩 차례로 돌고, 창을 닫아도 계속됩니다.',
          style: const TextStyle(color: _kListText, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('취소')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: _kAccent),
            child: Text('${docs.length}부 시작'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _bulkBusy = true);
    var started = 0;
    final failures = <String>[];
    for (final doc in docs) {
      try {
        if (await _startOne(doc)) started++;
      } catch (e) {
        failures.add('${doc.title}: ${SchoolExamReviewService.describeError(e)}');
      }
    }
    await _c.load(silent: true);
    if (!mounted) return;
    setState(() => _bulkBusy = false);
    widget.onToast(
      failures.isEmpty
          ? '시험지 $started부 검수를 시작했습니다'
          : '시작 $started부 · 실패 ${failures.length}부 (${failures.first})',
      error: failures.isNotEmpty,
    );
  }

  Future<void> _open(SchoolExamDocument doc) async {
    final order = doc.workflow?.workOrder;
    if (order == null) return;
    await showTextbookWorkflowDialog(
      context,
      academyId: doc.academyId,
      bookId: doc.id,
      bookName: order.bookName,
      gradeLabel: order.gradeLabel,
      bigOrder: order.bigOrder,
      midOrder: order.midOrder,
      unitTitle: '${doc.schoolName} ${doc.title}',
      initialScopeKey: order.scopeKey,
    );
    await _refreshReadyNote(order);
    await _c.load(silent: true);
  }

  /// 작업 화면에서 손본 뒤의 준비됨 수를 목록에 남긴다(검수가 돌고 있으면 실행기가 남긴다).
  Future<void> _refreshReadyNote(TextbookSubunitWorkOrder order) async {
    if (TextbookWorkflowRunner.instance.isActive(order.workflowKey)) return;
    final review = TextbookProblemReviewService();
    try {
      final items = [for (final it in await review.fetchUnitItems(order.reviewScope)) if (order.matches(it)) it];
      if (items.isEmpty) return;
      final ready = items.where((x) => x.isWorkflowReady).length;
      final held = items.where((x) => x.isEngineHeld).length;
      await TextbookWorkflowService().updatePipeline(
        order,
        detail: ['준비됨 $ready/${items.length}', if (held > 0) '코드 수정 필요 $held'].join(' · '),
      );
    } catch (e) {
      debugPrint('[school-exam] ready note failed: $e');
    } finally {
      review.dispose();
    }
  }

  void _retry(SchoolExamDocument doc) {
    final queued = _c.service.retry(doc);
    widget.onToast(queued ? '${doc.title} 검수를 멈춘 단계부터 이어서 진행합니다' : '${doc.title} 검수가 이미 돌고 있습니다');
  }

  Future<void> _delete(SchoolExamDocument doc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B1B1D),
        title: const Text('초안 삭제', style: TextStyle(color: Colors.white)),
        content: Text(
          '"${doc.schoolName} ${doc.title}" 초안을 지웁니다.\n'
          '올린 파일, 추출한 문항, 검수 기록이 모두 지워지고 되돌릴 수 없습니다.',
          style: const TextStyle(color: _kListText, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('취소')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB53A3A)),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy.add(doc.id));
    try {
      await _c.service.deleteDraft(doc);
      await _c.load(silent: true);
      widget.onToast('${doc.title} 초안을 지웠습니다');
    } catch (e) {
      widget.onToast('초안 삭제 실패: ${SchoolExamReviewService.describeError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(doc.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final school = _c.schoolNamed(widget.schoolName);
        final exams = school?.exams ?? const <SchoolExamDocument>[];
        final live = _c.liveStates();
        final notStarted = [
          for (final e in exams)
            if (e.stage == SchoolExamStage.notStarted && !(live[e.id]?.active ?? false)) e,
        ];
        final counts = <String, int>{};
        for (final e in exams) {
          final label = _statusOf(e, live[e.id]).spinning ? '진행 중' : _statusOf(e, live[e.id]).label;
          counts[label] = (counts[label] ?? 0) + 1;
        }
        return Container(
          decoration: BoxDecoration(
            color: _kPanel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _kBorder),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      '내신기출 · ${widget.schoolName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (notStarted.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: _bulkBusy ? null : () => unawaited(_startAll(notStarted)),
                      icon: _bulkBusy
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2, color: _kAccent),
                            )
                          : const Icon(Icons.playlist_play_rounded, size: 16, color: _kAccent),
                      label: Text(
                        '검수 전 ${notStarted.length}부 모두 시작',
                        style: const TextStyle(color: _kAccent, fontSize: 12),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: _kBorder),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                [
                  '시험지 ${exams.length}부',
                  for (final e in counts.entries) '${e.key} ${e.value}',
                ].join(' · '),
                style: const TextStyle(color: _kTextSub, fontSize: 12),
              ),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: _kInner,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _kBorder),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: const Text(
                  '문제은행에 이미 등록된 시험지는 정답만 검수합니다(AI 풀이를 기록하고 정답표와 대조). '
                  '새로 올린 시험지는 그림 크기·위치까지 검수하고, 시험지를 확정하면 학습앱에 공개됩니다.',
                  style: TextStyle(color: _kTextSub, fontSize: 12, height: 1.5),
                ),
              ),
              const SizedBox(height: 12),
              const Divider(height: 1, color: _kBorder),
              Expanded(
                child: exams.isEmpty
                    ? const Center(
                        child: Text('시험지가 없습니다', style: TextStyle(color: _kTextMuted, fontSize: 13)),
                      )
                    : ListView.separated(
                        itemCount: exams.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: _kBorder),
                        itemBuilder: (context, index) {
                          final doc = exams[index];
                          return _buildRow(doc, live[doc.id]);
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRow(SchoolExamDocument doc, TextbookWorkflowRunState? live) {
    final status = _statusOf(doc, live);
    final busy = _busy.contains(doc.id) || _bulkBusy;
    final active = live?.active ?? false;
    final hasOrder = doc.workflow?.workOrder != null;
    final stage = doc.stage;
    final canResume = !active &&
        hasOrder &&
        (stage == SchoolExamStage.running || stage == SchoolExamStage.failed || stage == SchoolExamStage.stopped);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        doc.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _Badge(
                      label: doc.published ? '정답만 검수' : '새 시험지 · 전체 검수',
                      fg: doc.published ? _kNeutralFg : _kBlue,
                      bg: doc.published ? _kNeutralBg : _kBlueBg,
                    ),
                    if (!doc.hasHwpx) ...[
                      const SizedBox(width: 4),
                      const _Badge(label: 'PDF 만', fg: _kNeutralFg, bg: _kNeutralBg),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  doc.sourceFilename.isEmpty ? '(파일 이름 없음)' : doc.sourceFilename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _kTextMuted, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 4,
            child: Row(
              children: [
                if (status.spinning) ...[
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _kAccent),
                  ),
                  const SizedBox(width: 8),
                ],
                _Badge(label: status.label, fg: status.fg, bg: status.bg),
                if (status.detail.trim().isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Tooltip(
                      message: status.detail.trim(),
                      child: Text(
                        status.detail.trim().split('\n').first,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _kTextSub, fontSize: 12, height: 1.35),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (busy)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _kAccent),
                  ),
                )
              else ...[
                if (stage == SchoolExamStage.notStarted && !active)
                  _RowAction(
                    icon: Icons.play_arrow_rounded,
                    label: '검수 시작',
                    accent: true,
                    onPressed: () => unawaited(_start(doc)),
                  ),
                if (canResume)
                  _RowAction(
                    icon: Icons.play_arrow_rounded,
                    label: '이어서 진행',
                    accent: true,
                    onPressed: () => _retry(doc),
                  ),
                if (hasOrder)
                  _RowAction(
                    icon: Icons.fact_check_outlined,
                    label: '검수 열기',
                    accent: stage == SchoolExamStage.reviewing && !active,
                    onPressed: () => unawaited(_open(doc)),
                  ),
                if (active)
                  _RowAction(
                    icon: Icons.stop_circle_outlined,
                    label: live?.cancelRequested ?? false ? '중단하는 중' : '중단',
                    danger: true,
                    onPressed: live?.cancelRequested ?? false
                        ? null
                        : () => TextbookWorkflowRunner.instance.cancel(live!.key),
                  ),
                if (!doc.published)
                  _RowAction(
                    icon: Icons.delete_outline,
                    label: '초안 삭제',
                    danger: true,
                    onPressed: () => unawaited(_delete(doc)),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.fg, required this.bg});

  final String label;
  final Color fg;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(label, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w800)),
    );
  }
}

class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.accent = false,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool accent;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final Color fg = onPressed == null
        ? const Color(0xFF4A4A4A)
        : (danger ? _kError : (accent ? _kAccent : const Color(0xFFE0E0E0)));
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 14, color: fg),
      label: Text(
        label,
        style: TextStyle(color: fg, fontSize: 12, fontWeight: accent ? FontWeight.w800 : FontWeight.w600),
      ),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        backgroundColor: accent && onPressed != null ? _kAccent.withValues(alpha: 0.14) : null,
        shape: accent
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
                side: BorderSide(color: _kAccent.withValues(alpha: 0.45)),
              )
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
