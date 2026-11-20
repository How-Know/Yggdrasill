import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/school_exam_review_service.dart';
import '../../services/textbook_workflow_runner.dart';
import '../../services/textbook_workflow_service.dart';
import '../problem_roadmap/problem_roadmap_screen.dart';
import 'exam_review_widgets.dart';

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
            const Divider(height: 1, color: kExamBorder),
            ExamReviewGroupHeader(
              title: '내신기출',
              countText: '${controller.examCount}부',
              expanded: expanded,
              loading: controller.loading,
              onToggle: onToggle,
            ),
            if (expanded && controller.error != null)
              ExamReviewListError(message: controller.error!, onRetry: () => unawaited(controller.load()))
            else if (expanded && schools.isEmpty && !controller.loading)
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 14, 12),
                child: Text(
                  '등록된 시험지가 없습니다. 위의 "내신기출 업로드"로 올리세요.',
                  style: TextStyle(color: kExamTextMuted, fontSize: 12),
                ),
              )
            else if (expanded)
              for (final school in schools)
                ExamReviewListRow(
                  icon: Icons.school_outlined,
                  label: school.name,
                  selected: school.name == selectedSchool,
                  running: school.exams.any((e) => live[e.id]?.active ?? false),
                  countText: '${school.confirmedCount}/${school.exams.length}',
                  countTooltip: '확정 ${school.confirmedCount}부 / 전체 ${school.exams.length}부',
                  onTap: () => onSelect(school.name),
                ),
          ],
        );
      },
    );
  }
}

ExamReviewStatus _statusOf(SchoolExamDocument doc, TextbookWorkflowRunState? live) {
  final wf = doc.workflow;
  if (live != null && live.active) {
    return ExamReviewStatus(TextbookWorkflowPhase.label(live.phase), kExamGreen, kExamSelectedRow, detail: live.detail, spinning: true);
  }
  final stage = doc.stage;
  if (stage == SchoolExamStage.confirmed) return const ExamReviewStatus('확정', kExamGreen, kExamSelectedRow);
  if (live != null && live.phase == TextbookWorkflowPhase.failed) {
    return ExamReviewStatus('실패', kExamError, kExamNeutralBg, detail: live.error.isNotEmpty ? live.error : live.detail);
  }
  if (live != null && live.phase == TextbookWorkflowPhase.cancelled) {
    return ExamReviewStatus('중단됨', kExamWarn, kExamWarnBg, detail: live.detail);
  }
  if (live != null && live.phase == TextbookWorkflowPhase.done && stage != SchoolExamStage.reviewing) {
    return ExamReviewStatus('검수 대기', kExamBlue, kExamBlueBg, detail: live.summaryText);
  }
  switch (stage) {
    case SchoolExamStage.noPdf:
      return const ExamReviewStatus('PDF 없음', kExamNeutralFg, kExamNeutralBg, detail: '문제은행에서 시험지 PDF 를 붙이면 검수할 수 있습니다');
    case SchoolExamStage.notStarted:
      return const ExamReviewStatus('검수 전', kExamNeutralFg, kExamNeutralBg);
    case SchoolExamStage.running:
      return ExamReviewStatus(
        '멈춤',
        kExamWarn,
        kExamWarnBg,
        detail: '${TextbookWorkflowPhase.label(wf?.pipelinePhase ?? '')} 단계에서 멈췄습니다',
      );
    case SchoolExamStage.failed:
      final err = (wf?.pipelineError ?? '').trim();
      return ExamReviewStatus('실패', kExamError, kExamNeutralBg, detail: err.isNotEmpty ? err : (wf?.pipelineDetail ?? ''));
    case SchoolExamStage.stopped:
      return ExamReviewStatus('중단됨', kExamWarn, kExamWarnBg, detail: wf?.pipelineDetail ?? '');
    case SchoolExamStage.reviewing:
      return ExamReviewStatus('검수 대기', kExamBlue, kExamBlueBg, detail: wf?.pipelineDetail ?? '');
    case SchoolExamStage.confirmed:
      return const ExamReviewStatus('확정', kExamGreen, kExamSelectedRow);
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
    final ok = await showExamReviewStartAllDialog(
      context,
      message: '${widget.schoolName}의 검수 전 시험지 ${docs.length}부를 검수 대기열에 넣습니다.\n'
          'AI 검수는 2부씩 차례로 돌고, 창을 닫아도 계속됩니다.',
      confirmLabel: '${docs.length}부 시작',
    );
    if (!ok || !mounted) return;
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
    try {
      await TextbookWorkflowService().noteReadyCounts(order);
    } catch (e) {
      debugPrint('[school-exam] ready note failed: $e');
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
          style: const TextStyle(color: kExamListText, fontSize: 13, height: 1.5),
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
            color: kExamPanel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kExamBorder),
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
                              child: CircularProgressIndicator(strokeWidth: 2, color: kExamAccent),
                            )
                          : const Icon(Icons.playlist_play_rounded, size: 16, color: kExamAccent),
                      label: Text(
                        '검수 전 ${notStarted.length}부 모두 시작',
                        style: const TextStyle(color: kExamAccent, fontSize: 12),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: kExamBorder),
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
                style: const TextStyle(color: kExamTextSub, fontSize: 12),
              ),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: kExamInner,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: kExamBorder),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: const Text(
                  '문제은행에 이미 등록된 시험지는 정답만 검수합니다(AI 풀이를 기록하고 정답표와 대조). '
                  '새로 올린 시험지는 그림 크기·위치까지 검수하고, 시험지를 확정하면 학습앱에 공개됩니다.',
                  style: TextStyle(color: kExamTextSub, fontSize: 12, height: 1.5),
                ),
              ),
              const SizedBox(height: 12),
              const Divider(height: 1, color: kExamBorder),
              Expanded(
                child: exams.isEmpty
                    ? const Center(
                        child: Text('시험지가 없습니다', style: TextStyle(color: kExamTextMuted, fontSize: 13)),
                      )
                    : ListView.separated(
                        itemCount: exams.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: kExamBorder),
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
                    ExamReviewBadge(
                      label: doc.published ? '정답만 검수' : '새 시험지 · 전체 검수',
                      fg: doc.published ? kExamNeutralFg : kExamBlue,
                      bg: doc.published ? kExamNeutralBg : kExamBlueBg,
                    ),
                    if (!doc.hasHwpx) ...[
                      const SizedBox(width: 4),
                      const ExamReviewBadge(label: 'PDF 만', fg: kExamNeutralFg, bg: kExamNeutralBg),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  doc.sourceFilename.isEmpty ? '(파일 이름 없음)' : doc.sourceFilename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kExamTextMuted, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(flex: 4, child: ExamReviewStatusLine(status: status)),
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
                    child: CircularProgressIndicator(strokeWidth: 2, color: kExamAccent),
                  ),
                )
              else ...[
                if (stage == SchoolExamStage.notStarted && !active)
                  ExamReviewRowAction(
                    icon: Icons.play_arrow_rounded,
                    label: '검수 시작',
                    accent: true,
                    onPressed: () => unawaited(_start(doc)),
                  ),
                if (canResume)
                  ExamReviewRowAction(
                    icon: Icons.play_arrow_rounded,
                    label: '이어서 진행',
                    accent: true,
                    onPressed: () => _retry(doc),
                  ),
                if (hasOrder)
                  ExamReviewRowAction(
                    icon: Icons.fact_check_outlined,
                    label: '검수 열기',
                    accent: stage == SchoolExamStage.reviewing && !active,
                    onPressed: () => unawaited(_open(doc)),
                  ),
                if (active)
                  ExamReviewRowAction(
                    icon: Icons.stop_circle_outlined,
                    label: live?.cancelRequested ?? false ? '중단하는 중' : '중단',
                    danger: true,
                    onPressed: live?.cancelRequested ?? false
                        ? null
                        : () => TextbookWorkflowRunner.instance.cancel(live!.key),
                  ),
                if (!doc.published)
                  ExamReviewRowAction(
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
