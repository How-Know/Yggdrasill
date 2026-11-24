import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/mock_exam_review_service.dart';
import '../../services/textbook_workflow_runner.dart';
import '../../services/textbook_workflow_service.dart';
import '../problem_bank/mock_exam/mock_exam_models.dart';
import '../problem_roadmap/problem_roadmap_screen.dart';
import 'exam_review_widgets.dart';

/// 교재 메뉴의 모의고사 목록 상태. 검수 실행기의 작업이 끝날 때마다 목록을 다시 읽는다.
class MockExamReviewController extends ChangeNotifier {
  MockExamReviewController({MockExamReviewService? service}) : service = service ?? MockExamReviewService() {
    TextbookWorkflowRunner.instance.addListener(_onRunnerChanged);
  }

  static const List<int> grades = <int>[1, 2, 3];

  final MockExamReviewService service;

  String? academyId;
  List<MockExamReviewExam> exams = const [];
  bool loading = false;
  String? error;

  /// 업로드가 돌고 있는가와 그 진행 글(끝난 뒤에는 결과 글이 남는다)
  bool uploading = false;
  String uploadMessage = '';

  bool _resumeChecked = false;
  bool _disposed = false;
  int _loadSeq = 0;
  Set<String> _activeKeys = const {};

  List<MockExamReviewExam> examsOfGrade(int grade) => [
        for (final e in exams)
          if (e.grade == grade) e,
      ];

  /// 업로드 창에 넘기는 "이미 있는 회차" 키
  Set<String> get examKeys => {for (final e in exams) e.examKey};

  /// 지금 이 앱에서 돌고 있거나 방금 끝난 구간 작업. 키는 구간 문서 id.
  Map<String, TextbookWorkflowRunState> liveStates() => {
        for (final s in TextbookWorkflowRunner.instance.states)
          if (s.order.isMockExam) s.order.bookId: s,
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
      final list = await service.fetchExams(id);
      if (_disposed || seq != _loadSeq) return 0;
      academyId = id;
      exams = list;
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
      if (!silent || exams.isEmpty) error = MockExamReviewService.describeError(e);
      _notify();
      return 0;
    }
  }

  /// 고른 PDF 들을 회차별로 올리고 바로 검수를 시작한다. 이미 올리는 중이면 null.
  Future<({List<MockExamReviewStartResult> started, List<String> failures})?> upload(
    List<MockExamFileName> files,
  ) async {
    if (uploading || files.isEmpty) return null;
    uploading = true;
    uploadMessage = '업로드 준비 중';
    _notify();
    try {
      final id = academyId ?? await service.resolveAcademyId();
      academyId = id;
      final live = liveStates();
      final outcome = await service.uploadAndStart(
        academyId: id,
        files: files,
        examIdByKey: {for (final e in exams) e.examKey: e.id},
        activeExamIds: {
          for (final e in exams)
            if (e.sections.any((s) => live[s.documentId]?.active ?? false)) e.id,
        },
        onProgress: (m) {
          uploadMessage = m;
          _notify();
        },
      );
      uploadMessage = [
        if (outcome.started.isNotEmpty) '${outcome.started.length}회 업로드 완료 · 추출 뒤 바로 검수',
        if (outcome.failures.isNotEmpty) '실패 ${outcome.failures.length}회',
      ].join(' · ');
      return outcome;
    } catch (e) {
      uploadMessage = '업로드 실패: ${MockExamReviewService.describeError(e)}';
      rethrow;
    } finally {
      uploading = false;
      _notify();
      unawaited(load(silent: true));
    }
  }

  Set<String> _currentActiveKeys() => {
        for (final s in TextbookWorkflowRunner.instance.states)
          if (s.active && s.order.isMockExam) s.key,
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

/// 교재 목록에서 내신기출 아래의 "모의고사" 묶음: 접고 펼 수 있고, 아래에 학년(고1·고2·고3)이 나온다.
class MockExamListSection extends StatelessWidget {
  const MockExamListSection({
    super.key,
    required this.controller,
    required this.expanded,
    required this.selectedGrade,
    required this.onToggle,
    required this.onSelect,
  });

  final MockExamReviewController controller;
  final bool expanded;
  final int? selectedGrade;
  final VoidCallback onToggle;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final live = controller.liveStates();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Divider(height: 1, color: kExamBorder),
            ExamReviewGroupHeader(
              title: '모의고사',
              countText: '${controller.exams.length}회',
              expanded: expanded,
              loading: controller.loading,
              onToggle: onToggle,
            ),
            if (expanded && controller.uploadMessage.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (controller.uploading) ...[
                      const LinearProgressIndicator(color: kExamAccent, backgroundColor: kExamNeutralBg, minHeight: 2),
                      const SizedBox(height: 6),
                    ],
                    Text(
                      controller.uploadMessage,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kExamTextSub, fontSize: 11),
                    ),
                  ],
                ),
              ),
            if (expanded && controller.error != null)
              ExamReviewListError(message: controller.error!, onRetry: () => unawaited(controller.load()))
            else if (expanded && controller.exams.isEmpty && !controller.loading)
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 14, 12),
                child: Text(
                  '등록된 모의고사가 없습니다. 위의 "모의고사 업로드"로 올리세요.',
                  style: TextStyle(color: kExamTextMuted, fontSize: 12),
                ),
              )
            else if (expanded)
              for (final grade in MockExamReviewController.grades)
                _gradeRow(grade, live),
          ],
        );
      },
    );
  }

  Widget _gradeRow(int grade, Map<String, TextbookWorkflowRunState> live) {
    final exams = controller.examsOfGrade(grade);
    final sections = [for (final e in exams) ...e.sections];
    final confirmed = sections.where((s) => s.stage == MockExamReviewStage.confirmed).length;
    return ExamReviewListRow(
      icon: Icons.assignment_outlined,
      label: '고$grade',
      selected: grade == selectedGrade,
      running: sections.any((s) => live[s.documentId]?.active ?? false),
      countText: '$confirmed/${sections.length}',
      countTooltip: '확정 $confirmed구간 / 전체 ${sections.length}구간 (회차 ${exams.length}회)',
      onTap: () => onSelect(grade),
    );
  }
}

/// 구간 하나의 목록 표시 상태. [live] 는 이 앱에서 돌고 있거나 방금 끝난 실행 상태다.
ExamReviewStatus mockExamSectionStatus(MockExamReviewSection section, TextbookWorkflowRunState? live) {
  final wf = section.workflow;
  if (live != null && live.active) {
    return ExamReviewStatus(
      TextbookWorkflowPhase.label(live.phase),
      kExamGreen,
      kExamSelectedRow,
      detail: live.detail,
      spinning: true,
    );
  }
  final stage = section.stage;
  if (stage == MockExamReviewStage.confirmed) return const ExamReviewStatus('확정', kExamGreen, kExamSelectedRow);
  if (live != null && live.phase == TextbookWorkflowPhase.failed) {
    return ExamReviewStatus('실패', kExamError, kExamNeutralBg, detail: live.error.isNotEmpty ? live.error : live.detail);
  }
  if (live != null && live.phase == TextbookWorkflowPhase.cancelled) {
    return ExamReviewStatus('중단됨', kExamWarn, kExamWarnBg, detail: live.detail);
  }
  if (live != null && live.phase == TextbookWorkflowPhase.done && stage != MockExamReviewStage.reviewing) {
    return ExamReviewStatus('검수 대기', kExamBlue, kExamBlueBg, detail: live.summaryText);
  }
  switch (stage) {
    case MockExamReviewStage.notStarted:
      return const ExamReviewStatus('검수 전', kExamNeutralFg, kExamNeutralBg);
    case MockExamReviewStage.running:
      return ExamReviewStatus(
        '멈춤',
        kExamWarn,
        kExamWarnBg,
        detail: '${TextbookWorkflowPhase.label(wf?.pipelinePhase ?? '')} 단계에서 멈췄습니다',
      );
    case MockExamReviewStage.failed:
      final err = (wf?.pipelineError ?? '').trim();
      return ExamReviewStatus('실패', kExamError, kExamNeutralBg, detail: err.isNotEmpty ? err : (wf?.pipelineDetail ?? ''));
    case MockExamReviewStage.stopped:
      return ExamReviewStatus('중단됨', kExamWarn, kExamWarnBg, detail: wf?.pipelineDetail ?? '');
    case MockExamReviewStage.reviewing:
      return ExamReviewStatus('검수 대기', kExamBlue, kExamBlueBg, detail: wf?.pipelineDetail ?? '');
    case MockExamReviewStage.confirmed:
      return const ExamReviewStatus('확정', kExamGreen, kExamSelectedRow);
  }
}

/// 이 학년 목록에 있는 달. 작은 달부터.
List<int> mockExamMonths(Iterable<MockExamReviewExam> exams) {
  final months = <int>{
    for (final exam in exams)
      if (exam.exam.month >= 1 && exam.exam.month <= 12) exam.exam.month,
  };
  final list = months.toList()..sort();
  return list;
}

/// 고른 달이 목록에 있으면 그 달, 없으면 가장 이른 달.
int? mockExamSelectedMonth(List<int> months, int? selected) {
  if (months.isEmpty) return null;
  if (selected != null && months.contains(selected)) return selected;
  return months.first;
}

/// 고른 학년의 회차 목록: 회차마다 구간(공통·선택과목)별 검수 시작·열기·이어서 진행.
class MockExamGradePanel extends StatefulWidget {
  const MockExamGradePanel({
    super.key,
    required this.controller,
    required this.grade,
    required this.onToast,
  });

  final MockExamReviewController controller;
  final int grade;
  final void Function(String message, {bool error}) onToast;

  @override
  State<MockExamGradePanel> createState() => _MockExamGradePanelState();
}

class _MockExamGradePanelState extends State<MockExamGradePanel> {
  final Set<String> _busy = <String>{};
  bool _bulkBusy = false;
  int? _selectedMonth;

  MockExamReviewController get _c => widget.controller;

  Future<MockExamReviewStartResult?> _startOne(MockExamReviewExam exam) async {
    final academyId = _c.academyId;
    if (academyId == null) return null;
    return _c.service.startReview(academyId: academyId, examId: exam.id);
  }

  Future<void> _start(MockExamReviewExam exam) async {
    if (_busy.contains(exam.id)) return;
    setState(() => _busy.add(exam.id));
    try {
      final res = await _startOne(exam);
      if (res != null) {
        await _c.load(silent: true);
        widget.onToast(
          res.started == 0
              ? '${exam.title}: 새로 시작할 구간이 없습니다'
              : '${exam.title} 구간 ${res.started}개 검수를 시작했습니다'
                  '${res.extractionRequested ? ' (추출부터 합니다)' : ''}',
        );
      }
    } catch (e) {
      widget.onToast('검수 시작 실패: ${MockExamReviewService.describeError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(exam.id));
    }
  }

  Future<void> _startAll(List<MockExamReviewExam> exams, {required int? month}) async {
    if (exams.isEmpty || _bulkBusy) return;
    final sections = exams.fold<int>(0, (n, e) => n + e.notStartedSections.length);
    final scope = month == null ? '고${widget.grade}' : '고${widget.grade} $month월';
    final ok = await showExamReviewStartAllDialog(
      context,
      message: '$scope 검수 전 회차 ${exams.length}회(구간 $sections개)를 검수 대기열에 넣습니다.\n'
          '아직 추출하지 않은 회차는 추출부터 합니다.\n'
          'AI 검수는 구간 2개씩 차례로 돌고, 창을 닫아도 계속됩니다.',
      confirmLabel: '${exams.length}회 시작',
    );
    if (!ok || !mounted) return;
    setState(() => _bulkBusy = true);
    var started = 0;
    final failures = <String>[];
    for (final exam in exams) {
      try {
        final res = await _startOne(exam);
        if (res != null && res.started > 0) started++;
      } catch (e) {
        failures.add('${exam.title}: ${MockExamReviewService.describeError(e)}');
      }
    }
    await _c.load(silent: true);
    if (!mounted) return;
    setState(() => _bulkBusy = false);
    widget.onToast(
      failures.isEmpty
          ? '모의고사 $started회 검수를 시작했습니다'
          : '시작 $started회 · 실패 ${failures.length}회 (${failures.first})',
      error: failures.isNotEmpty,
    );
  }

  Future<void> _open(MockExamReviewExam exam, MockExamReviewSection section) async {
    final order = section.workflow?.workOrder;
    if (order == null) return;
    await showTextbookWorkflowDialog(
      context,
      academyId: order.academyId,
      bookId: order.bookId,
      bookName: order.bookName,
      gradeLabel: order.gradeLabel,
      bigOrder: order.bigOrder,
      midOrder: order.midOrder,
      unitTitle: '${exam.title} ${section.label}',
      initialScopeKey: order.scopeKey,
    );
    // 작업 화면에서 손본 뒤의 준비됨 수를 목록에 남긴다(검수가 돌고 있으면 실행기가 남긴다).
    if (!TextbookWorkflowRunner.instance.isActive(order.workflowKey)) {
      try {
        await TextbookWorkflowService().noteReadyCounts(order);
      } catch (e) {
        debugPrint('[mock-exam] ready note failed: $e');
      }
    }
    await _c.load(silent: true);
  }

  void _retry(MockExamReviewExam exam, MockExamReviewSection section) {
    final queued = _c.service.retry(section);
    final name = '${exam.title} ${section.label}';
    widget.onToast(queued ? '$name 검수를 멈춘 단계부터 이어서 진행합니다' : '$name 검수가 이미 돌고 있습니다');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final gradeExams = _c.examsOfGrade(widget.grade);
        final months = mockExamMonths(gradeExams);
        final month = mockExamSelectedMonth(months, _selectedMonth);
        final exams = [
          for (final e in gradeExams)
            if (month == null || e.exam.month == month) e,
        ];
        final live = _c.liveStates();
        bool active(MockExamReviewSection s) => live[s.documentId]?.active ?? false;
        final startable = [
          for (final e in exams)
            if (e.notStartedSections.any((s) => !active(s))) e,
        ];
        final counts = <String, int>{};
        var sectionCount = 0;
        for (final e in exams) {
          for (final s in e.sections) {
            sectionCount++;
            final status = mockExamSectionStatus(s, live[s.documentId]);
            final label = status.spinning ? '진행 중' : status.label;
            counts[label] = (counts[label] ?? 0) + 1;
          }
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
                  Text(
                    '모의고사 · 고${widget.grade}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                  if (months.isEmpty)
                    const Spacer()
                  else ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (var i = 0; i < months.length; i++) ...[
                              if (i > 0) const SizedBox(width: 4),
                              _MockExamMonthTab(
                                label: '${months[i]}월',
                                selected: months[i] == month,
                                onTap: () => setState(() => _selectedMonth = months[i]),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 12),
                  if (startable.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: _bulkBusy ? null : () => unawaited(_startAll(startable, month: month)),
                      icon: _bulkBusy
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2, color: kExamAccent),
                            )
                          : const Icon(Icons.playlist_play_rounded, size: 16, color: kExamAccent),
                      label: Text(
                        '검수 전 ${startable.length}회 모두 시작',
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
                  if (month != null) '$month월',
                  '회차 ${exams.length}회',
                  '구간 $sectionCount개',
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
                child: Text(
                  widget.grade == 3
                      ? '구간(공통·선택과목)마다 따로 검수합니다. 아직 추출하지 않은 회차는 검수를 시작하면 추출부터 하고, '
                          '구간을 확정하면 그 구간 문항이 학습앱에 공개됩니다. '
                          '이미 공개된 회차는 공개한 채로 검수하고, 고친 내용은 구간을 확정할 때 반영됩니다.'
                      : '아직 추출하지 않은 회차는 검수를 시작하면 추출부터 하고, 확정하면 문항이 학습앱에 공개됩니다. '
                          '이미 공개된 회차는 공개한 채로 검수하고, 고친 내용은 확정할 때 반영됩니다.',
                  style: const TextStyle(color: kExamTextSub, fontSize: 12, height: 1.5),
                ),
              ),
              const SizedBox(height: 12),
              const Divider(height: 1, color: kExamBorder),
              Expanded(
                child: exams.isEmpty
                    ? Center(
                        child: Text(
                          month == null ? '등록된 회차가 없습니다' : '$month월에 등록된 회차가 없습니다',
                          style: const TextStyle(color: kExamTextMuted, fontSize: 13),
                        ),
                      )
                    : ListView.separated(
                        itemCount: exams.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: kExamBorder),
                        itemBuilder: (context, index) => _buildExam(exams[index], live),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 회차의 추출 상태 배지. 추출을 마친 회차는 따로 표시하지 않는다.
  Widget? _extractBadge(MockExamReviewExam exam) {
    switch (exam.exam.status) {
      case 'queued':
        return const ExamReviewBadge(label: '추출 대기', fg: kExamBlue, bg: kExamBlueBg);
      case 'running':
        return const ExamReviewBadge(label: '추출 중', fg: kExamBlue, bg: kExamBlueBg);
      case 'failed':
        return Tooltip(
          message: exam.exam.lastError.trim().isEmpty ? '추출에 실패했습니다' : exam.exam.lastError.trim(),
          child: const ExamReviewBadge(label: '추출 실패', fg: kExamError, bg: kExamNeutralBg),
        );
    }
    return exam.notExtracted ? const ExamReviewBadge(label: '추출 전', fg: kExamNeutralFg, bg: kExamNeutralBg) : null;
  }

  /// 구간이 학습앱에 나가 있는가. 문서가 아직 없는 구간은 표시하지 않는다.
  Widget? _publishBadge(MockExamReviewSection section) {
    if (section.documentId == null) return null;
    return section.publishOnConfirm
        ? const ExamReviewBadge(label: '확정 때 공개', fg: kExamBlue, bg: kExamBlueBg)
        : const ExamReviewBadge(label: '공개 중', fg: kExamNeutralFg, bg: kExamNeutralBg);
  }

  Widget _title(MockExamReviewExam exam, {Widget? trailingBadge}) {
    final extract = _extractBadge(exam);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                exam.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
            if (extract != null) ...[const SizedBox(width: 8), extract],
            if (trailingBadge != null) ...[SizedBox(width: extract == null ? 8 : 4), trailingBadge],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          [
            '${mockExamSchoolYear(exam.grade, exam.exam.examYear)}학년도',
            '문제지 ${exam.problemPaperCount}',
            exam.solutionPaperCount > 0 ? '해설 ${exam.solutionPaperCount}' : '해설 없음',
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: kExamTextMuted, fontSize: 11),
        ),
      ],
    );
  }

  Widget _busySpinner() => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: kExamAccent),
        ),
      );

  /// 구간 하나의 동작: 이어서 진행·검수 열기·중단
  List<Widget> _sectionActions(
    MockExamReviewExam exam,
    MockExamReviewSection section,
    TextbookWorkflowRunState? live,
  ) {
    final active = live?.active ?? false;
    final hasOrder = section.workflow?.workOrder != null;
    final stage = section.stage;
    final canResume = !active &&
        hasOrder &&
        (stage == MockExamReviewStage.running ||
            stage == MockExamReviewStage.failed ||
            stage == MockExamReviewStage.stopped);
    return [
      if (canResume)
        ExamReviewRowAction(
          icon: Icons.play_arrow_rounded,
          label: '이어서 진행',
          accent: true,
          onPressed: () => _retry(exam, section),
        ),
      if (hasOrder)
        ExamReviewRowAction(
          icon: Icons.fact_check_outlined,
          label: '검수 열기',
          accent: stage == MockExamReviewStage.reviewing && !active,
          onPressed: () => unawaited(_open(exam, section)),
        ),
      if (active)
        ExamReviewRowAction(
          icon: Icons.stop_circle_outlined,
          label: live?.cancelRequested ?? false ? '중단하는 중' : '중단',
          danger: true,
          onPressed:
              live?.cancelRequested ?? false ? null : () => TextbookWorkflowRunner.instance.cancel(live!.key),
        ),
    ];
  }

  Widget _buildExam(MockExamReviewExam exam, Map<String, TextbookWorkflowRunState> live) {
    final busy = _busy.contains(exam.id) || _bulkBusy;
    final pending = [
      for (final s in exam.notStartedSections)
        if (!(live[s.documentId]?.active ?? false)) s,
    ];
    final startAction = pending.isEmpty
        ? null
        : ExamReviewRowAction(
            icon: Icons.play_arrow_rounded,
            label: pending.length == exam.sections.length ? '검수 시작' : '남은 구간 검수 시작',
            accent: true,
            onPressed: () => unawaited(_start(exam)),
          );

    // 구간이 하나인 회차(고1·고2)는 한 줄로 보인다.
    if (exam.sections.length == 1) {
      final section = exam.sections.first;
      final state = live[section.documentId];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(flex: 5, child: _title(exam, trailingBadge: _publishBadge(section))),
            const SizedBox(width: 12),
            Expanded(flex: 4, child: ExamReviewStatusLine(status: mockExamSectionStatus(section, state))),
            const SizedBox(width: 12),
            Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: busy
                  ? [_busySpinner()]
                  : [if (startAction != null) startAction, ..._sectionActions(exam, section, state)],
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: _title(exam)),
              const SizedBox(width: 12),
              if (busy) _busySpinner() else if (startAction != null) startAction,
            ],
          ),
          if (exam.sections.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '문제지 PDF 가 없어 검수할 구간이 없습니다',
                style: TextStyle(color: kExamTextMuted, fontSize: 12),
              ),
            ),
          for (final section in exam.sections) _buildSectionRow(exam, section, live[section.documentId], busy),
        ],
      ),
    );
  }

  Widget _buildSectionRow(
    MockExamReviewExam exam,
    MockExamReviewSection section,
    TextbookWorkflowRunState? live,
    bool busy,
  ) {
    final publish = _publishBadge(section);
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 5,
            child: Row(
              children: [
                const Icon(Icons.subdirectory_arrow_right_rounded, size: 14, color: kExamTextMuted),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    section.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kExamListText, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                if (section.sharedSlotNote.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    section.sharedSlotNote,
                    maxLines: 1,
                    style: const TextStyle(color: kExamTextMuted, fontSize: 12),
                  ),
                ],
                if (publish != null) ...[const SizedBox(width: 8), publish],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(flex: 4, child: ExamReviewStatusLine(status: mockExamSectionStatus(section, live))),
          const SizedBox(width: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 30),
            child: Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: busy ? const [] : _sectionActions(exam, section, live),
            ),
          ),
        ],
      ),
    );
  }
}

class _MockExamMonthTab extends StatelessWidget {
  const _MockExamMonthTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? kExamAccent : kExamTextSub;
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        backgroundColor: selected ? kExamAccent.withValues(alpha: 0.14) : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
          side: BorderSide(
            color: selected ? kExamAccent.withValues(alpha: 0.45) : kExamBorder,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 12,
          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
        ),
      ),
    );
  }
}
