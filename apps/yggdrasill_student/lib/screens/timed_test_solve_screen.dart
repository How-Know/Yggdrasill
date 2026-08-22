import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/student_api.dart';
import '../services/textbook_api.dart';
import 'textbook_solve_screen.dart';

class TimedTestSolveScreen extends StatefulWidget {
  const TimedTestSolveScreen({
    super.key,
    required this.group,
    required this.problems,
    required this.session,
  });

  final HomeworkGroup group;
  final List<HomeworkProblem> problems;
  final TimedTestSession session;

  @override
  State<TimedTestSolveScreen> createState() => _TimedTestSolveScreenState();
}

class _TimedTestSolveScreenState extends State<TimedTestSolveScreen>
    with WidgetsBindingObserver {
  final _answerController = TextEditingController();
  final _activeWatch = Stopwatch();
  final _wallWatch = Stopwatch();
  Timer? _timer;
  late TimedTestSession _session;
  TimedTestExposure? _exposure;
  StudentTextbookProblemView? _view;
  PageProblem? _pageProblem;
  DateTime? _shownAt;
  Object? _error;
  int _index = 0;
  bool _busy = true;
  bool _finishing = false;
  late Duration _serverClockOffset;

  int get _remainingSeconds {
    final serverNow = DateTime.now().add(_serverClockOffset);
    final milliseconds =
        _session.deadlineAt.difference(serverNow).inMilliseconds;
    return milliseconds <= 0 ? 0 : (milliseconds / 1000).ceil();
  }

  void _syncServerClock(DateTime deadline, int remainingSeconds) {
    final estimatedServerNow =
        deadline.subtract(Duration(seconds: remainingSeconds));
    _serverClockOffset = estimatedServerNow.difference(DateTime.now());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session = widget.session;
    _syncServerClock(_session.deadlineAt, _session.remainingSeconds);
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || _finishing) return;
      if (_remainingSeconds <= 0) {
        unawaited(_finish());
      } else {
        setState(() {});
      }
    });
    if (_session.isOpen) {
      unawaited(_resumeAndOpen());
    } else {
      _busy = false;
    }
  }

  Future<void> _resumeAndOpen() async {
    try {
      final position = await TextbookApi.instance.timedTestNextPosition(
        _session.sessionId,
      );
      _index = (position - 1).clamp(0, widget.problems.length);
      await _openNext();
    } catch (error) {
      if (_isClosedError(error)) {
        await _finish();
      } else if (mounted) {
        setState(() {
          _error = error;
          _busy = false;
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _activeWatch.stop();
    _wallWatch.stop();
    _answerController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_shownAt != null && !_finishing) _activeWatch.start();
      if (_remainingSeconds <= 0) unawaited(_finish());
    } else {
      _activeWatch.stop();
    }
  }

  TimedTestGradeContext _timingContext() {
    final exposure = _exposure!;
    final wall = _wallWatch.elapsedMilliseconds;
    final active = _activeWatch.elapsedMilliseconds;
    return TimedTestGradeContext(
      sessionId: _session.sessionId,
      exposureId: exposure.exposureId,
      durationMs: active,
      position: exposure.position,
      wallDurationMs: wall,
      interruptionMs: (wall - active).clamp(0, wall),
    );
  }

  Future<StudentTextbookProblemView> _loadReadyView(String cropId) async {
    var view = await TextbookApi.instance.problemView(cropId: cropId);
    for (var attempt = 0; view.isQueued && attempt < 8; attempt++) {
      await Future<void>.delayed(
        Duration(milliseconds: view.pollAfterMs?.clamp(400, 2500) ?? 900),
      );
      view = await TextbookApi.instance.problemView(cropId: cropId);
    }
    return view;
  }

  Future<void> _openNext() async {
    if (_finishing) return;
    setState(() {
      _busy = true;
      _error = null;
      _view = null;
      _pageProblem = null;
    });
    try {
      while (_index < widget.problems.length) {
        if (_remainingSeconds <= 0) {
          await _finish();
          return;
        }
        final problem = widget.problems[_index];
        final pageProblems = await TextbookApi.instance.pageProblems(
          bookId: problem.bookId,
          gradeLabel: problem.gradeLabel,
          rawPage: problem.rawPage!,
        );
        final pageProblem = pageProblems.cast<PageProblem?>().firstWhere(
              (item) => item?.cropId == problem.cropId,
              orElse: () => null,
            );
        if (pageProblem == null || pageProblem.isSelfCheck) {
          throw StateError('timed_test_problem_not_auto_gradable');
        }
        final view = await _loadReadyView(problem.cropId);
        final exposure = await StudentApi.instance.exposeTimedTestProblem(
          sessionId: _session.sessionId,
          problem: problem,
          position: _index + 1,
        );
        if (exposure.expired || exposure.remainingSeconds <= 0) {
          await _finish();
          return;
        }
        _syncServerClock(exposure.deadlineAt, exposure.remainingSeconds);
        final probe = TimedTestGradeContext(
          sessionId: _session.sessionId,
          exposureId: exposure.exposureId,
          durationMs: 0,
          position: exposure.position,
        );
        if (await TextbookApi.instance.timedTestExposureAnswered(
          timedTest: probe,
        )) {
          _index++;
          continue;
        }
        _answerController.clear();
        _activeWatch
          ..reset()
          ..start();
        _wallWatch
          ..reset()
          ..start();
        if (!mounted) return;
        setState(() {
          _exposure = exposure;
          _pageProblem = pageProblem;
          _view = view;
          _shownAt = DateTime.now();
          _busy = false;
        });
        return;
      }
      await _finish();
    } catch (error) {
      if (_isClosedError(error)) {
        await _finish();
        return;
      }
      if (mounted) {
        setState(() {
          _error = error;
          _busy = false;
        });
      }
    }
  }

  bool _isClosedError(Object error) =>
      error is TextbookGradeException &&
      error.code == 'timed_test_session_closed';

  Future<void> _submit({required bool pass}) async {
    if (_busy || _finishing || _exposure == null || _shownAt == null) return;
    final answer = _answerController.text.trim();
    if (!pass && answer.isEmpty) return;
    if (_remainingSeconds <= 0) {
      await _finish();
      return;
    }
    setState(() => _busy = true);
    _activeWatch.stop();
    _wallWatch.stop();
    try {
      final timing = _timingContext();
      if (pass) {
        await TextbookApi.instance.passTimedTest(timedTest: timing);
      } else {
        final problem = widget.problems[_index];
        await TextbookApi.instance.gradeTimedTest(
          bookId: problem.bookId,
          gradeLabel: problem.gradeLabel,
          cropId: problem.cropId,
          answer: answer,
          timedTest: timing,
        );
      }
      _index++;
      _exposure = null;
      _shownAt = null;
      await _openNext();
    } catch (error) {
      if (_isClosedError(error)) {
        await _finish();
      } else if (mounted) {
        setState(() {
          _error = error;
          _busy = false;
          _activeWatch.start();
        });
      }
    }
  }

  Future<void> _finish({String status = 'completed'}) async {
    if (_finishing) return;
    _finishing = true;
    _activeWatch.stop();
    _wallWatch.stop();
    if (mounted) setState(() => _busy = true);
    try {
      _session = await StudentApi.instance.finishTimedTest(
        _session.sessionId,
        status: status,
      );
      _exposure = null;
      _shownAt = null;
      if (mounted) setState(() => _busy = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _busy = false;
        });
      }
    } finally {
      _finishing = false;
    }
  }

  Future<void> _requestExit() async {
    if (!_session.isOpen) {
      Navigator.of(context).pop();
      return;
    }
    final abandon = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('테스트를 종료할까요?'),
        content: const Text('종료하면 다시 풀 수 없어요. 지금까지 제출한 답으로 결과가 확정돼요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('계속 풀기'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('종료'),
          ),
        ],
      ),
    );
    if (abandon == true) await _finish(status: 'abandoned');
  }

  String get _clockLabel {
    final seconds = _remainingSeconds;
    final minutes = seconds ~/ 60;
    return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_requestExit());
      },
      child: Scaffold(
        backgroundColor: context.yggSurfaceBase,
        appBar: AppBar(
          leading: IconButton(
            onPressed: _requestExit,
            icon: const Icon(Icons.close_rounded),
          ),
          title: Text(
              widget.group.title.isEmpty ? '시간제한 테스트' : widget.group.title),
          actions: [
            Center(
              child: Text(
                _clockLabel,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: _remainingSeconds <= 60 ? Colors.red : null,
                    ),
              ),
            ),
            const SizedBox(width: 20),
          ],
        ),
        body: _session.isOpen ? _buildSolve() : _buildResult(),
      ),
    );
  }

  Widget _buildSolve() {
    if (_busy) return const Center(child: YggLoadingIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 40),
            const SizedBox(height: 12),
            const Text('문항을 불러오지 못했어요.'),
            const SizedBox(height: 12),
            FilledButton(onPressed: _openNext, child: const Text('다시 시도')),
          ],
        ),
      );
    }
    final view = _view;
    final pageProblem = _pageProblem;
    if (view == null || pageProblem == null) {
      return const Center(child: YggLoadingIndicator());
    }
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${_index + 1} / ${widget.problems.length} · ${pageProblem.problemNumber}번',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: SingleChildScrollView(
                child: TextbookProblemDocumentView(view: view),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _answerController,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: '답 입력',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => unawaited(_submit(pass: false)),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _submit(pass: true),
                  child: const Text('패스'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _busy || _answerController.text.trim().isEmpty
                      ? null
                      : () => _submit(pass: false),
                  child: const Text('답 제출'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildResult() {
    final accuracy = _session.accuracy;
    return Center(
      child: Card(
        margin: const EdgeInsets.all(24),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.fact_check_rounded, size: 52),
              const SizedBox(height: 12),
              Text('테스트 결과', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 20),
              Text('정답 ${_session.correct} · 오답 ${_session.wrong}'),
              Text('패스 ${_session.pass} · 시간초과 ${_session.timeout}'),
              Text('노출 문항 ${_session.exposed}'),
              Text(
                '정답률 ${accuracy == null ? '-' : '${(accuracy * 100).round()}%'}',
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('닫기'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
