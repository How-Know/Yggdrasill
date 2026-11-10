import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'problem_bank_service.dart';
import 'textbook_problem_review_service.dart';
import 'textbook_review_pipeline.dart';
import 'textbook_stage_batch_service.dart';
import 'textbook_vlm_answer_service.dart';
import 'textbook_workflow_service.dart';

/// 2단계 진행 단계. DB `pipeline_phase` 에 같은 값을 남겨 앱을 다시 켜면 그 단계부터 잇는다.
class TextbookWorkflowPhase {
  const TextbookWorkflowPhase._();

  static const queued = 'queued';

  /// 본문 추출(서버 워커)과 정답·해설 위치 찾기를 함께 돌린다.
  static const extract = 'extract';

  /// 채점 정답을 문제은행 문항에 연결
  static const sync = 'sync';

  /// V2 렌더·AI 풀이·검수·원본 대조 수정·재확인
  static const review = 'review';
  static const finalize = 'finalize';
  static const done = 'done';
  static const failed = 'failed';
  static const cancelled = 'cancelled';

  static String label(String phase) => switch (phase) {
        queued => '대기',
        extract => '본문 추출·정답 위치',
        sync => '정답 연결',
        review => 'AI 검수',
        finalize => '준비됨 판정',
        done => '완료',
        failed => '실패',
        cancelled => '중단',
        _ => phase,
      };

  /// DB 에 남은 단계 → 다시 시작할 단계
  static String resumeFrom(String phase) => switch (phase) {
        sync => sync,
        review => review,
        finalize => finalize,
        done => review,
        _ => extract,
      };
}

/// 본문 추출 런 하나의 진행도(`textbook_pb_extract_runs.progress`).
class TextbookWorkflowExtractProgress {
  const TextbookWorkflowExtractProgress({
    required this.subKey,
    required this.status,
    this.chunksTotal = 0,
    this.chunksDone = 0,
    this.expectedCount = 0,
    this.numbersDone = const {},
    this.error = '',
  });

  final String subKey;

  /// queued | extracting | completed | review_required | failed | cancelled
  final String status;
  final int chunksTotal;
  final int chunksDone;
  final int expectedCount;

  /// 모델이 이미 읽어 낸 문항 번호. 결과 저장은 런이 끝날 때 한 번이다.
  final Set<String> numbersDone;
  final String error;

  bool get finished => status == 'completed' || status == 'review_required';
  bool get failed => status == 'failed' || status == 'cancelled';
}

class TextbookWorkflowRunState {
  TextbookWorkflowRunState(this.order);

  final TextbookSubunitWorkOrder order;
  String phase = TextbookWorkflowPhase.queued;
  String detail = '';
  String error = '';
  bool cancelRequested = false;
  final Map<String, TextbookWorkflowExtractProgress> extract = {};
  bool extractSkipped = false;
  String matchDetail = '';
  bool matchDone = false;
  int total = 0;
  int ready = 0;
  int engineHeld = 0;
  final List<String> notes = [];
  DateTime? startedAt;
  DateTime? finishedAt;

  String get key => order.workflowKey;
  bool get active =>
      phase != TextbookWorkflowPhase.done && phase != TextbookWorkflowPhase.failed && phase != TextbookWorkflowPhase.cancelled;

  /// 본문 추출 중 이미 읽어 낸 문항 번호(sub_key 별)
  Set<String> numbersDone(String subKey) => {
        for (final e in extract.values)
          if (e.subKey == subKey) ...e.numbersDone,
      };

  String get summaryText {
    if (total <= 0) return detail;
    final parts = ['준비됨 $ready/$total'];
    if (engineHeld > 0) parts.add('코드 수정 필요 $engineHeld');
    return parts.join(' · ');
  }
}

class _QueuedRun {
  const _QueuedRun(
    this.order,
    this.fromPhase, {
    this.onlyCropIds,
    this.forceRerun = false,
    this.forceRenderCheck = false,
    this.since,
  });

  final TextbookSubunitWorkOrder order;
  final String fromPhase;
  final Set<String>? onlyCropIds;

  /// 이미 검수한 문항도 AI 풀이·해설 전사·품질 검수를 다시 한다(정답·해설 위치를 손으로 고친 뒤).
  final bool forceRerun;
  final bool forceRenderCheck;

  /// 이어 돌릴 때: 이 시각 이후 끝난 본문 추출 런은 다시 만들지 않는다.
  final DateTime? since;
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// 크롭 확정된 소단원의 2단계(본문 추출 → 정답·해설 위치 → 정답 연결 → AI 검수 → 준비됨 판정)를
/// 앱 전역에서 돌린다. 창을 닫아도 계속 돌고, 단계는 DB 에 남아 앱을 다시 켜면 이어 간다.
class TextbookWorkflowRunner extends ChangeNotifier {
  TextbookWorkflowRunner._();

  static final TextbookWorkflowRunner instance = TextbookWorkflowRunner._();

  static const int maxParallel = 2;
  static const Duration _pollEvery = Duration(seconds: 5);
  static const Duration _extractTimeout = Duration(minutes: 45);
  static const Duration _persistEvery = Duration(seconds: 4);

  final TextbookWorkflowService _workflows = TextbookWorkflowService();
  final ProblemBankService _pb = ProblemBankService();
  final TextbookStageBatchService _stage = TextbookStageBatchService();
  final TextbookVlmAnswerService _answers = TextbookVlmAnswerService();

  final Map<String, TextbookWorkflowRunState> _states = {};
  final List<_QueuedRun> _queue = [];
  final Set<String> _running = {};
  final Map<String, DateTime> _lastPersist = {};

  TextbookWorkflowRunState? stateFor(String key) => _states[key];
  bool isActive(String key) => _states[key]?.active ?? false;
  List<TextbookWorkflowRunState> get states => _states.values.toList(growable: false);
  int get activeCount => _states.values.where((s) => s.active).length;

  /// 크롭 확정 직후(본문 추출부터) 또는 다시 시도. 이미 돌고 있으면 넣지 않고 false.
  bool enqueue(
    TextbookSubunitWorkOrder order, {
    String fromPhase = TextbookWorkflowPhase.extract,
    Set<String>? onlyCropIds,
    bool forceRerun = false,
    bool forceRenderCheck = false,
    DateTime? since,
  }) {
    final key = order.workflowKey;
    if (isActive(key)) return false;
    _states[key] = TextbookWorkflowRunState(order);
    _queue.add(_QueuedRun(
      order,
      fromPhase,
      onlyCropIds: onlyCropIds,
      forceRerun: forceRerun,
      forceRenderCheck: forceRenderCheck,
      since: since,
    ));
    notifyListeners();
    _pump();
    return true;
  }

  void cancel(String key) {
    final st = _states[key];
    if (st == null || !st.active) return;
    final idx = _queue.indexWhere((q) => q.order.workflowKey == key);
    if (idx >= 0) {
      final job = _queue.removeAt(idx);
      st.phase = TextbookWorkflowPhase.cancelled;
      st.detail = '대기 중 취소';
      unawaited(_workflows
          .updatePipeline(job.order, status: 'idle', phase: TextbookWorkflowPhase.cancelled, detail: '대기 중 취소')
          .catchError((_) {}));
    } else {
      st.cancelRequested = true;
      st.detail = '중단하는 중…';
    }
    notifyListeners();
  }

  /// DB 에 진행 중으로 남았는데 이 앱에서 돌고 있지 않은 소단원을 이어 돌린다. 반환: 다시 넣은 수
  int resumeUnfinished(Iterable<TextbookSubunitWorkflow> workflows) {
    var n = 0;
    for (final wf in workflows) {
      final order = wf.workOrder;
      if (!wf.pipelineUnfinished || order == null || isActive(wf.key)) continue;
      enqueue(
        order,
        fromPhase: TextbookWorkflowPhase.resumeFrom(wf.pipelinePhase),
        since: wf.pipelineStartedAt,
      );
      n++;
    }
    return n;
  }

  void _pump() {
    while (_running.length < maxParallel && _queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      final key = job.order.workflowKey;
      _running.add(key);
      unawaited(_run(job));
    }
  }

  void _setPhase(TextbookWorkflowRunState st, String phase, String detail) {
    st.phase = phase;
    st.detail = detail;
    notifyListeners();
  }

  void _detail(TextbookWorkflowRunState st, String detail) {
    st.detail = detail;
    notifyListeners();
    final last = _lastPersist[st.key];
    final now = DateTime.now();
    if (last != null && now.difference(last) < _persistEvery) return;
    _lastPersist[st.key] = now;
    unawaited(_workflows.updatePipeline(st.order, detail: detail).catchError((_) {}));
  }

  Future<void> _persistPhase(TextbookWorkflowRunState st, {bool markStarted = false}) async {
    _lastPersist[st.key] = DateTime.now();
    await _workflows.updatePipeline(
      st.order,
      status: 'running',
      phase: st.phase,
      detail: st.detail,
      error: '',
      markStarted: markStarted,
    );
  }

  Future<void> _run(_QueuedRun job) async {
    final order = job.order;
    final st = _states[order.workflowKey]!;
    st.startedAt = DateTime.now();
    final review = TextbookProblemReviewService();
    var phase = job.fromPhase;
    try {
      if (phase == TextbookWorkflowPhase.extract) {
        _setPhase(st, phase, '본문 추출·정답 위치 확인');
        await _persistPhase(st, markStarted: job.since == null);
        await _extractAndMatch(st, review, since: job.since);
        if (st.cancelRequested) throw const _Cancelled();
        phase = TextbookWorkflowPhase.sync;
      }
      if (phase == TextbookWorkflowPhase.sync) {
        _setPhase(st, phase, '채점 정답을 문제은행 문항에 연결');
        await _persistPhase(st);
        await _syncAnswers(order);
        if (st.cancelRequested) throw const _Cancelled();
        phase = TextbookWorkflowPhase.review;
      }
      if (phase == TextbookWorkflowPhase.review) {
        _setPhase(st, phase, 'AI 검수 준비');
        await _persistPhase(st);
        final only = job.onlyCropIds;
        final pipeline = TextbookReviewPipeline(
          service: review,
          scope: order.reviewScope,
          matches: (it) => order.matches(it) && (only == null || only.contains(it.cropId)),
          onProgress: (m) => _detail(st, m),
          isCancelled: () => st.cancelRequested,
        );
        final summary = await pipeline.runAll(forceRerun: job.forceRerun, forceRenderCheck: job.forceRenderCheck);
        st.notes
          ..clear()
          ..addAll(summary.notes);
        if (summary.errors.isNotEmpty) st.error = summary.errors.take(6).join('\n');
        if (st.cancelRequested) throw const _Cancelled();
        phase = TextbookWorkflowPhase.finalize;
      }
      if (phase == TextbookWorkflowPhase.finalize) {
        _setPhase(st, phase, '준비됨 판정');
        final items = [for (final it in await review.fetchUnitItems(order.reviewScope)) if (order.matches(it)) it];
        st.total = items.length;
        st.ready = items.where((x) => x.isWorkflowReady).length;
        st.engineHeld = items.where((x) => x.isEngineHeld).length;
      }
      st.finishedAt = DateTime.now();
      _setPhase(st, TextbookWorkflowPhase.done, st.summaryText);
      await _workflows.updatePipeline(
        order,
        status: 'done',
        phase: TextbookWorkflowPhase.done,
        detail: st.summaryText,
        error: st.error,
        markFinished: true,
      );
    } on _Cancelled {
      st.finishedAt = DateTime.now();
      _setPhase(st, TextbookWorkflowPhase.cancelled, '${TextbookWorkflowPhase.label(phase)} 단계에서 중단');
      await _workflows
          .updatePipeline(order, status: 'idle', phase: phase, detail: st.detail, markFinished: true)
          .catchError((_) {});
    } catch (e) {
      st.finishedAt = DateTime.now();
      st.error = '$e';
      _setPhase(st, TextbookWorkflowPhase.failed, '${TextbookWorkflowPhase.label(phase)} 단계 실패');
      await _workflows
          .updatePipeline(order, status: 'failed', phase: phase, detail: st.detail, error: '$e', markFinished: true)
          .catchError((_) {});
    } finally {
      review.dispose();
      _running.remove(order.workflowKey);
      notifyListeners();
      _pump();
    }
  }

  /// 본문이 아직 없는 sub_key 만 추출하고, 정답·해설 위치가 빈 sub_key 만 다시 찾는다.
  Future<void> _extractAndMatch(
    TextbookWorkflowRunState st,
    TextbookProblemReviewService review, {
    DateTime? since,
  }) async {
    final order = st.order;
    final items = [for (final it in await review.fetchUnitItems(order.reviewScope)) if (order.matches(it)) it];
    if (items.isEmpty) throw Exception('저장된 크롭이 없습니다. 1단계에서 크롭을 다시 저장하세요');
    final extractRuns = <(TextbookWorkflowExtractRun, List<String>)>[
      if (order.supportsExtraction)
        for (final r in order.extractRuns)
          if (extractTargetsOf([
                for (final it in items)
                  if (it.subKey == r.subKey) (number: it.problemNumber, hasBody: it.pbQuestionId.isNotEmpty),
              ])
              case final only?)
            (r, only),
    ];
    final stageRuns = [
      for (final r in order.stageRuns)
        if (items.any((it) =>
            it.subKey == r.subKey && (it.existingAnswer.trim().isEmpty || (!it.hasSolutionRef && !it.solutionMarkedNone))))
          r,
    ];
    final bodyChainKeys = [
      if (_bodySolutionSeries.contains(order.seriesKey)) ...order.reviewSubKeys,
    ];
    st.extractSkipped = extractRuns.isEmpty;
    st.matchDone = stageRuns.isEmpty && bodyChainKeys.isEmpty;
    notifyListeners();
    await Future.wait([
      _runExtracts(st, extractRuns, since: since),
      _runMatches(st, stageRuns, bodyChainKeys),
    ]);
  }

  /// 추출 런 하나가 읽을 번호. null 이면 건너뛰고(빠진 본문 없음), 빈 목록이면 처음 추출이라
  /// 전부 읽고, 목록이면 그 번호만 읽는다. 본문이 하나라도 있으면 전체 추출을 하지 않는다:
  /// 전체 추출은 그 문서의 문항을 모두 지우고 새로 넣어 사람이 고친 본문까지 사라진다.
  static List<String>? extractTargetsOf(List<({String number, bool hasBody})> items) {
    if (!items.any((it) => !it.hasBody)) return null;
    if (!items.any((it) => it.hasBody)) return const [];
    final missing = <String>{
      for (final it in items)
        if (!it.hasBody && it.number.trim().isNotEmpty) it.number.trim(),
    };
    return missing.isEmpty ? null : missing.toList();
  }

  /// 본문 "풀이" 단락에서 정답·풀이를 읽는 문항이 있는 시리즈
  static const Set<String> _bodySolutionSeries = {'wonri', 'gaeyu', 'gaeyu_high'};

  Future<List<Map<String, dynamic>>> _loadRunRows(TextbookSubunitWorkOrder order) async {
    final rows = await Supabase.instance.client
        .from('textbook_pb_extract_runs')
        .select()
        .eq('academy_id', order.academyId)
        .eq('book_id', order.bookId)
        .eq('grade_label', order.gradeLabel)
        .eq('big_order', order.bigOrder)
        .eq('mid_order', order.midOrder);
    return [for (final r in (rows as List).whereType<Map>()) Map<String, dynamic>.from(r)];
  }

  static TextbookWorkflowExtractProgress _progressOf(Map<String, dynamic> row, String subKey) {
    final p = row['progress'] is Map ? Map<String, dynamic>.from(row['progress'] as Map) : const <String, dynamic>{};
    return TextbookWorkflowExtractProgress(
      subKey: subKey,
      status: '${row['status'] ?? 'queued'}'.trim().toLowerCase(),
      chunksTotal: (p['chunks_total'] as num?)?.toInt() ?? 0,
      chunksDone: (p['chunks_done'] as num?)?.toInt() ?? 0,
      expectedCount: (p['expected_count'] as num?)?.toInt() ?? 0,
      numbersDone: {for (final n in (p['numbers_done'] as List?) ?? const []) '$n'},
      error: '${row['error_message'] ?? ''}'.trim(),
    );
  }

  Future<void> _runExtracts(
    TextbookWorkflowRunState st,
    List<(TextbookWorkflowExtractRun, List<String>)> runs, {
    DateTime? since,
  }) async {
    if (runs.isEmpty) return;
    final order = st.order;
    final jobIds = <String, String>{};
    final subKeyOf = <String, String>{};
    final existing = since == null ? const <Map<String, dynamic>>[] : await _loadRunRows(order);
    for (final (r, onlyNumbers) in runs) {
      final runKey = '${r.subKey}|${r.subIndex}';
      subKeyOf[runKey] = r.subKey;
      Map<String, dynamic>? row;
      for (final x in existing) {
        if ('${x['sub_key']}' == r.subKey && (x['sub_index'] as num?)?.toInt() == r.subIndex) row = x;
      }
      if (row != null) {
        final status = '${row['status'] ?? ''}';
        final jobId = '${row['extract_job_id'] ?? ''}';
        final updated = DateTime.tryParse('${row['updated_at'] ?? ''}');
        final inFlight = status == 'queued' || status == 'extracting';
        final finishedSince =
            (status == 'completed' || status == 'review_required') && updated != null && !updated.isBefore(since!);
        if (jobId.isNotEmpty && (inFlight || finishedSince)) {
          jobIds[runKey] = jobId;
          st.extract[runKey] = _progressOf(row, r.subKey);
          continue;
        }
      }
      final res = await _pb.createTextbookPdfOnlyExtractRun(
        academyId: order.academyId,
        bookId: order.bookId,
        bookName: order.bookName,
        gradeLabel: order.gradeLabel,
        bigOrder: order.bigOrder,
        midOrder: order.midOrder,
        subKey: r.subKey,
        subIndex: r.subIndex,
        seriesKey: order.seriesKey,
        bigName: order.bigName,
        midName: order.midName,
        subName: r.subName,
        rawPageFrom: r.rawPageFrom,
        rawPageTo: r.rawPageTo,
        displayPageFrom: r.displayPageFrom,
        displayPageTo: r.displayPageTo,
        bodyLinkId: order.bodyLinkId,
        forceNewJob: true,
        onlyProblemNumbers: onlyNumbers,
      );
      jobIds[runKey] = res.extractJobId;
      st.extract[runKey] = TextbookWorkflowExtractProgress(subKey: r.subKey, status: 'queued');
      notifyListeners();
    }

    final deadline = DateTime.now().add(_extractTimeout);
    while (true) {
      if (st.cancelRequested) return;
      final rows = await _loadRunRows(order);
      var allDone = true;
      var expected = 0;
      var read = 0;
      for (final entry in jobIds.entries) {
        Map<String, dynamic>? row;
        for (final x in rows) {
          if ('${x['extract_job_id']}' == entry.value) row = x;
        }
        if (row == null) {
          allDone = false;
          continue;
        }
        final p = _progressOf(row, subKeyOf[entry.key]!);
        st.extract[entry.key] = p;
        if (p.failed) {
          throw Exception('${p.subKey} 본문 추출 실패${p.error.isEmpty ? '' : ': ${p.error}'}');
        }
        if (!p.finished) allDone = false;
        expected += p.expectedCount;
        read += p.numbersDone.length;
      }
      if (allDone) {
        _detail(st, '본문 추출 완료${st.matchDone ? '' : ' · 정답·해설 위치 찾는 중'}');
        return;
      }
      _detail(
        st,
        expected > 0 ? '본문 추출 $read/$expected문항${st.matchDone ? '' : ' · ${st.matchDetail}'}' : '본문 추출 대기 중',
      );
      if (DateTime.now().isAfter(deadline)) {
        throw Exception('본문 추출이 ${_extractTimeout.inMinutes}분 안에 끝나지 않았습니다');
      }
      await Future<void>.delayed(_pollEvery);
    }
  }

  Future<void> _runMatches(
    TextbookWorkflowRunState st,
    List<TextbookWorkflowStageRun> runs,
    List<String> bodyChainKeys,
  ) async {
    if (runs.isEmpty && bodyChainKeys.isEmpty) return;
    final order = st.order;
    final missingAnswers = <String>[];
    final missingSolutions = <String>[];
    for (var i = 0; i < runs.length; i++) {
      if (st.cancelRequested) return;
      final r = runs[i];
      final prefix = runs.length > 1 ? '${r.subKey} ' : '';
      st.matchDetail = '$prefix정답·해설 위치 찾는 중';
      notifyListeners();
      final res = await _stage.runStage23ForSubunit(
        academyId: order.academyId,
        bookId: order.bookId,
        gradeLabel: order.gradeLabel,
        bigOrder: order.bigOrder,
        midOrder: order.midOrder,
        subKey: r.subKey,
        subIndex: r.subIndex,
        seriesKey: order.seriesKey,
        answerStartPage: r.answerStartPage,
        answerEndPage: r.answerEndPage,
        solutionStartPage: r.solutionStartPage,
        solutionEndPage: r.solutionEndPage,
        bodyPageFrom: r.bodyPageFrom,
        bodyPageTo: r.bodyPageTo,
        onStatus: (s) {
          st.matchDetail = '$prefix$s';
          notifyListeners();
        },
      );
      missingAnswers.addAll(res.answerMissing.map((n) => '$prefix$n'));
      missingSolutions.addAll(res.solutionMissing.map((n) => '$prefix$n'));
    }
    for (final subKey in bodyChainKeys) {
      if (st.cancelRequested) return;
      st.matchDetail = '본문 풀이에서 정답 찾는 중';
      notifyListeners();
      final res = await _stage.runBodySolutionChainForSubunit(
        academyId: order.academyId,
        bookId: order.bookId,
        gradeLabel: order.gradeLabel,
        bigOrder: order.bigOrder,
        midOrder: order.midOrder,
        subKey: subKey,
        subIndex: order.indexedSubKeys.contains(subKey) ? order.reviewSubIndex : 0,
        seriesKey: order.seriesKey,
        bodyPageFrom: order.rawPageFrom,
        bodyPageTo: order.rawPageTo,
        onStatus: (s) {
          st.matchDetail = s;
          notifyListeners();
        },
      );
      missingAnswers.addAll(res.answerMissing.map((n) => '$subKey $n'));
      missingSolutions.addAll(res.solutionMissing.map((n) => '$subKey $n'));
    }
    st.matchDone = true;
    st.matchDetail = [
      '정답·해설 위치 완료',
      if (missingAnswers.isNotEmpty) '정답 못 찾음 ${missingAnswers.length}',
      if (missingSolutions.isNotEmpty) '해설 못 찾음 ${missingSolutions.length}',
    ].join(' · ');
    notifyListeners();
  }

  /// 답지에서 찾은 정답과 본문 풀이에서 이어 받은 정답(개념서 필수유형 등)을 모두 문제은행에 옮긴다.
  Future<void> _syncAnswers(TextbookSubunitWorkOrder order) async {
    final targets = <(String, int)>{
      for (final r in order.stageRuns) (r.subKey, r.subIndex),
      for (final k in order.reviewSubKeys) (k, order.indexedSubKeys.contains(k) ? order.reviewSubIndex : 0),
    };
    for (final (subKey, subIndex) in targets) {
      await _answers.syncAnswersToProblemBank(
        academyId: order.academyId,
        bookId: order.bookId,
        gradeLabel: order.gradeLabel,
        bigOrder: order.bigOrder,
        midOrder: order.midOrder,
        subKey: subKey,
        subIndex: subIndex,
      );
    }
  }
}
