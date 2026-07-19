import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/textbook_api.dart';
import '../widgets/math_expression_editor.dart';
import '../widgets/math_keypad.dart';
import '../widgets/pencil_input_pad.dart';

enum _InputMode { pencil, editor, keyboard }

enum _PaneMode { answers, question }

/// 교재 풀이 화면.
/// 좌: 단원트리(대→중→소→페이지), 우: 페이지 문항 + 정답 입력 + 일괄 채점.
class TextbookSolveScreen extends StatefulWidget {
  const TextbookSolveScreen({super.key, required this.book});

  final StudentTextbook book;

  @override
  State<TextbookSolveScreen> createState() => _TextbookSolveScreenState();
}

class _TextbookSolveScreenState extends State<TextbookSolveScreen> {
  static final Set<String> _warmedTextbooks = <String>{};

  TextbookUnitTree? _tree;
  String? _treeError;
  final Set<String> _expanded = <String>{};

  TbPageStat? _page;
  String _pagePathLabel = '';
  List<PageProblem>? _problems;
  bool _loadingProblems = false;

  /// crop_id → 현재 입력값
  final Map<String, String> _answers = <String, String>{};

  /// crop_id → 마지막 채점 당시 제출한 값 (중복 제출 방지)
  final Map<String, String> _gradedAnswers = <String, String>{};

  /// crop_id → 최근 채점 결과
  final Map<String, bool> _results = <String, bool>{};

  /// crop_id → 누적 채점 횟수
  final Map<String, int> _attemptCounts = <String, int>{};

  /// crop_id → 채점 플래그 (unit_hint/unit_caution/form_differs)
  final Map<String, List<String>> _flags = <String, List<String>>{};

  /// 셀프 채점으로 기록된 문항
  final Set<String> _selfGraded = <String>{};

  String? _selectedCropId;
  _InputMode _inputMode = _InputMode.pencil;
  _PaneMode _paneMode = _PaneMode.answers;
  StudentTextbookProblemView? _problemView;
  Object? _problemViewError;
  bool _loadingProblemView = false;
  int _problemViewRequestEpoch = 0;
  final Map<String, StudentTextbookProblemView> _problemViewCache =
      <String, StudentTextbookProblemView>{};
  final Map<String, Future<StudentTextbookProblemView>> _problemViewRequests =
      <String, Future<StudentTextbookProblemView>>{};
  final Set<String> _prefetchedCropIds = <String>{};
  final Set<String> _neighborQueueRequestedCropIds = <String>{};
  bool _grading = false;
  bool _treeOpen = false;

  GlobalKey<MathExpressionEditorState> _editorKey =
      GlobalKey<MathExpressionEditorState>();
  GlobalKey<PencilInputPadState> _pencilKey = GlobalKey<PencilInputPadState>();
  final TextEditingController _keyboardController = TextEditingController();

  @override
  void dispose() {
    _problemViewRequestEpoch++;
    _keyboardController.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    unawaited(_warmProblemViews());
    _loadTree(selectLastPage: true);
  }

  Future<void> _warmProblemViews() async {
    final key = '${widget.book.bookId}|${widget.book.gradeLabel}';
    if (!_warmedTextbooks.add(key)) return;
    try {
      await TextbookApi.instance.warmProblemViews(
        bookId: widget.book.bookId,
        gradeLabel: widget.book.gradeLabel,
      );
    } catch (_) {
      // 예열은 화면 진입을 막지 않는 best-effort 작업이다.
    }
  }

  Future<void> _loadTree({bool selectLastPage = false}) async {
    try {
      final tree = await TextbookApi.instance.unitTree(
        bookId: widget.book.bookId,
        gradeLabel: widget.book.gradeLabel,
      );
      if (!mounted) return;
      setState(() {
        _tree = tree;
        _treeError = null;
      });
      if (selectLastPage && widget.book.lastRawPage != null) {
        _selectPageByRawPage(widget.book.lastRawPage!);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _treeError = '단원 정보를 불러오지 못했어요.\n$e');
    }
  }

  void _selectPageByRawPage(int rawPage) {
    final tree = _tree;
    if (tree == null) return;
    for (final big in tree.bigUnits) {
      for (final mid in big.mids) {
        for (final small in mid.smalls) {
          for (final page in small.pages) {
            if (page.rawPage == rawPage) {
              _expanded
                ..add('b${big.order}')
                ..add('b${big.order}|m${mid.order}')
                ..add('b${big.order}|m${mid.order}|s${small.subKey}');
              _openPage(
                page,
                '${mid.name} · ${small.name.isEmpty ? small.subKey : small.name}',
              );
              return;
            }
          }
        }
      }
    }
  }

  Future<void> _openPage(TbPageStat page, String pathLabel) async {
    setState(() {
      _page = page;
      _pagePathLabel = pathLabel;
      _problems = null;
      _loadingProblems = true;
      _answers.clear();
      _gradedAnswers.clear();
      _results.clear();
      _attemptCounts.clear();
      _flags.clear();
      _selfGraded.clear();
      _selectedCropId = null;
      _problemViewRequestEpoch++;
      _problemView = null;
      _problemViewError = null;
      _loadingProblemView = false;
      _treeOpen = false;
    });
    try {
      final problems = await TextbookApi.instance.pageProblems(
        bookId: widget.book.bookId,
        gradeLabel: widget.book.gradeLabel,
        rawPage: page.rawPage,
      );
      if (!mounted) return;
      setState(() {
        _problems = problems;
        _loadingProblems = false;
        for (final p in problems) {
          if (p.myAnswer != null && p.myAnswer!.isNotEmpty) {
            _answers[p.cropId] = p.myAnswer!;
            _gradedAnswers[p.cropId] = p.myAnswer!;
          }
          if (p.myCorrect != null) {
            _results[p.cropId] = p.myCorrect!;
          }
          if (p.attemptCount != null) {
            _attemptCounts[p.cropId] = p.attemptCount!;
          }
          if (p.flags.isNotEmpty) {
            _flags[p.cropId] = p.flags;
          }
          if (p.gradedBy == 'self') {
            _selfGraded.add(p.cropId);
          }
        }
        // 첫 미채점 주관식 문제 자동 선택
        for (final p in problems) {
          if (!p.isObjective && !p.isSelfCheck && p.myCorrect == null) {
            _selectPro(p);
            break;
          }
        }
        if (_selectedCropId == null && problems.isNotEmpty) {
          _selectPro(problems.first);
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _problems = const [];
        _loadingProblems = false;
      });
      TopGlassSnackBar.show(
        context,
        message: '문항을 불러오지 못했어요.',
        icon: Icons.error_outline_rounded,
      );
    }
  }

  Future<void> _grade() async {
    if (_grading) return;
    final problems = _problems;
    if (problems == null) return;

    // 자동 채점 문항 중 새로 입력했거나 값이 바뀐 것만 제출
    final toSubmit = <String, String>{};
    final incomplete = <String>[];
    for (final p in problems) {
      if (p.isSelfCheck) continue;
      final answer = _answers[p.cropId]?.trim() ?? '';
      if (answer.isEmpty) continue;
      if (answer.contains('()')) {
        incomplete.add(p.problemNumber);
        continue; // 수식 에디터 빈칸이 남은 답은 제출하지 않음
      }
      if (_gradedAnswers[p.cropId] == answer &&
          _results.containsKey(p.cropId)) {
        continue;
      }
      toSubmit[p.cropId] = answer;
    }
    if (incomplete.isNotEmpty) {
      TopGlassSnackBar.show(
        context,
        message: '${incomplete.join(', ')}번 답에 빈칸이 남아 있어요.',
        icon: Icons.crop_free_rounded,
      );
      if (toSubmit.isEmpty) return;
    }
    if (toSubmit.isEmpty) {
      TopGlassSnackBar.show(
        context,
        message: '채점할 새 답이 없어요. 답을 입력해 주세요.',
        icon: Icons.edit_outlined,
      );
      return;
    }

    setState(() => _grading = true);
    try {
      final result = await TextbookApi.instance.gradePage(
        bookId: widget.book.bookId,
        gradeLabel: widget.book.gradeLabel,
        answersByCropId: toSubmit,
      );
      if (!mounted) return;
      setState(() {
        _results.addAll(result.correctByCropId);
        _flags.addAll(result.flagsByCropId);
        _gradedAnswers.addAll(toSubmit);
        for (final cropId in result.correctByCropId.keys) {
          _attemptCounts[cropId] = (_attemptCounts[cropId] ?? 0) + 1;
        }
      });
      TopGlassSnackBar.show(
        context,
        message: result.wrongCount == 0
            ? '${result.correctCount}문제 모두 맞았어요!'
            : '${result.correctCount}개 맞고 ${result.wrongCount}개 틀렸어요.',
        icon: result.wrongCount == 0
            ? Icons.celebration_rounded
            : Icons.fact_check_outlined,
      );
      // 트리의 페이지 현황 갱신
      _loadTree();
    } catch (_) {
      if (mounted) {
        TopGlassSnackBar.show(
          context,
          message: '채점에 실패했어요. 다시 시도해 주세요.',
          icon: Icons.wifi_off_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _grading = false);
    }
  }

  // ------------------------------------------------------------- 셀프 채점

  /// 정답 공개 → 학생이 스스로 O/X → 서버 기록.
  Future<void> _selfCheck(PageProblem problem) async {
    RevealedAnswer revealed;
    try {
      revealed =
          await TextbookApi.instance.revealAnswer(cropId: problem.cropId);
    } catch (_) {
      if (mounted) {
        TopGlassSnackBar.show(
          context,
          message: '정답을 불러오지 못했어요.',
          icon: Icons.error_outline_rounded,
        );
      }
      return;
    }
    if (!mounted) return;

    final marked = await showDialog<bool>(
      context: context,
      builder: (ctx) => _SelfCheckDialog(
        problemNumber: problem.problemNumber,
        revealed: revealed,
        myAnswer: _answers[problem.cropId],
      ),
    );
    if (marked == null || !mounted) return;

    try {
      await TextbookApi.instance.selfMark(
        bookId: widget.book.bookId,
        gradeLabel: widget.book.gradeLabel,
        cropId: problem.cropId,
        correct: marked,
        answer: _answers[problem.cropId],
      );
      if (!mounted) return;
      setState(() {
        _results[problem.cropId] = marked;
        _gradedAnswers[problem.cropId] = _answers[problem.cropId] ?? '';
        _selfGraded.add(problem.cropId);
        _attemptCounts[problem.cropId] =
            (_attemptCounts[problem.cropId] ?? 0) + 1;
      });
      _loadTree();
    } catch (_) {
      if (mounted) {
        TopGlassSnackBar.show(
          context,
          message: '기록에 실패했어요. 다시 시도해 주세요.',
          icon: Icons.wifi_off_rounded,
        );
      }
    }
  }

  // ------------------------------------------------------------- 입력 조작

  void _setAnswer(String cropId, String value) {
    if (_results[cropId] == true) return;
    setState(() => _answers[cropId] = value);
  }

  /// 문항 선택 (입력 패널 대상 변경 — 에디터/키보드 상태 재생성).
  void _selectPro(PageProblem problem) {
    _selectedCropId = problem.cropId;
    _editorKey = GlobalKey<MathExpressionEditorState>();
    _pencilKey = GlobalKey<PencilInputPadState>();
    _keyboardController.text = _answers[problem.cropId] ?? '';
    if (_paneMode == _PaneMode.question) {
      _startProblemViewLoad(problem.cropId);
    }
  }

  List<String> _neighborCropIds(String cropId) {
    final problems = _problems ?? const <PageProblem>[];
    final index = problems.indexWhere((problem) => problem.cropId == cropId);
    if (index < 0) return const <String>[];
    final start = (index - 2).clamp(0, problems.length);
    final end = (index + 3).clamp(0, problems.length);
    return <String>[
      for (var i = start; i < end; i++)
        if (problems[i].cropId != cropId) problems[i].cropId,
    ];
  }

  void _startProblemViewLoad(String cropId) {
    final requestEpoch = ++_problemViewRequestEpoch;
    final cached = _problemViewCache[cropId];
    _problemView = cached;
    _problemViewError = null;
    _loadingProblemView = cached == null;

    final neighbors = _neighborCropIds(cropId);
    final shouldQueueNeighbors = _neighborQueueRequestedCropIds.add(cropId);
    if (cached != null) {
      if (shouldQueueNeighbors) {
        unawaited(_prefetchProblemView(
          cropId,
          neighborCropIds: neighbors,
        ));
      }
      return;
    }
    unawaited(_resolveSelectedProblemView(
      cropId: cropId,
      neighborCropIds: shouldQueueNeighbors ? neighbors : const <String>[],
      requestEpoch: requestEpoch,
    ));
    for (final neighborId in neighbors) {
      if (_prefetchedCropIds.add(neighborId)) {
        unawaited(_prefetchProblemView(neighborId));
      }
    }
  }

  Future<void> _prefetchProblemView(
    String cropId, {
    List<String> neighborCropIds = const <String>[],
  }) async {
    try {
      await _fetchProblemView(
        cropId,
        neighborCropIds: neighborCropIds,
      );
    } catch (_) {
      // 선택 문항 로딩과 무관한 best-effort 프리패치다.
    }
  }

  Future<StudentTextbookProblemView> _fetchProblemView(
    String cropId, {
    List<String> neighborCropIds = const <String>[],
  }) async {
    final cached = _problemViewCache[cropId];
    if (cached != null && neighborCropIds.isEmpty) return cached;
    final pending = _problemViewRequests[cropId];
    if (pending != null && neighborCropIds.isEmpty) return pending;

    final request = TextbookApi.instance.problemView(
      cropId: cropId,
      neighborCropIds: neighborCropIds,
    );
    _problemViewRequests[cropId] = request;
    try {
      final result = await request;
      if (!result.isQueued) {
        _problemViewCache[cropId] = result;
      }
      return result;
    } finally {
      if (identical(_problemViewRequests[cropId], request)) {
        _problemViewRequests.remove(cropId);
      }
    }
  }

  Future<void> _resolveSelectedProblemView({
    required String cropId,
    required List<String> neighborCropIds,
    required int requestEpoch,
  }) async {
    try {
      StudentTextbookProblemView? result;
      for (var attempt = 0; attempt < 3; attempt++) {
        result = await _fetchProblemView(
          cropId,
          neighborCropIds: attempt == 0 ? neighborCropIds : const <String>[],
        );
        if (!mounted ||
            requestEpoch != _problemViewRequestEpoch ||
            cropId != _selectedCropId) {
          return;
        }
        if (!result.isQueued) break;
        if (attempt < 2) {
          final delayMs = (result.pollAfterMs ?? 1800).clamp(300, 5000).toInt();
          await Future<void>.delayed(Duration(milliseconds: delayMs));
        }
      }
      if (result?.isQueued == true && result?.bodyPdfUrl != null) {
        result = StudentTextbookProblemView(
          status: StudentTextbookProblemViewStatus.fallback,
          bodyPdfUrl: result!.bodyPdfUrl,
          rawPage: result.rawPage,
          itemRegion1k: result.itemRegion1k,
          expiresIn: result.expiresIn,
        );
      }
      if (!mounted ||
          requestEpoch != _problemViewRequestEpoch ||
          cropId != _selectedCropId) {
        return;
      }
      setState(() {
        _problemView = result;
        _problemViewError = null;
        _loadingProblemView = false;
      });
    } catch (error) {
      if (!mounted ||
          requestEpoch != _problemViewRequestEpoch ||
          cropId != _selectedCropId) {
        return;
      }
      setState(() {
        _problemView = null;
        _problemViewError = error;
        _loadingProblemView = false;
      });
    }
  }

  void _toggleObjective(String cropId, int number) {
    if (_results[cropId] == true) return;
    final current = _answers[cropId] ?? '';
    final startsRevision =
        _results[cropId] == false && _gradedAnswers[cropId] == current;
    final selected = startsRevision
        ? <int>{}
        : current
            .split(',')
            .where((s) => s.trim().isNotEmpty)
            .map(int.parse)
            .toSet();
    if (!selected.remove(number)) selected.add(number);
    final sorted = selected.toList()..sort();
    setState(() {
      if (startsRevision) {
        _results.remove(cropId);
        _flags.remove(cropId);
      }
      _answers[cropId] = sorted.join(',');
    });
  }

  int get _pendingGradeCount {
    final problems = _problems ?? const <PageProblem>[];
    var count = 0;
    for (final problem in problems) {
      if (problem.isSelfCheck) continue;
      final answer = _answers[problem.cropId]?.trim() ?? '';
      if (answer.isEmpty || answer.contains('()')) continue;
      if (_gradedAnswers[problem.cropId] == answer &&
          _results.containsKey(problem.cropId)) {
        continue;
      }
      count++;
    }
    return count;
  }

  void _moveProblem(int delta) {
    final problems = _problems ?? const <PageProblem>[];
    if (problems.isEmpty) return;
    var index =
        problems.indexWhere((problem) => problem.cropId == _selectedCropId);
    if (index < 0) index = delta > 0 ? -1 : problems.length;
    final next = (index + delta).clamp(0, problems.length - 1);
    if (next == index) return;
    setState(() => _selectPro(problems[next]));
  }

  void _togglePaneMode() {
    setState(() {
      _paneMode = _paneMode == _PaneMode.answers
          ? _PaneMode.question
          : _PaneMode.answers;
      if (_paneMode == _PaneMode.question) {
        final problems = _problems ?? const <PageProblem>[];
        if (problems.isNotEmpty) {
          final selected = problems.firstWhere(
            (problem) => problem.cropId == _selectedCropId,
            orElse: () => problems.first,
          );
          _selectPro(selected);
        }
      } else {
        _problemViewRequestEpoch++;
        _problemView = null;
        _problemViewError = null;
        _loadingProblemView = false;
      }
    });
  }

  void _cycleInputMode() {
    setState(() {
      _inputMode = switch (_inputMode) {
        _InputMode.pencil => _InputMode.editor,
        _InputMode.editor => _InputMode.keyboard,
        _InputMode.keyboard => _InputMode.pencil,
      };
      final cropId = _selectedCropId;
      if (cropId != null) {
        _keyboardController.text = _answers[cropId] ?? '';
      }
    });
  }

  void _eraseCurrentInput() {
    final cropId = _selectedCropId;
    if (cropId == null || _results[cropId] == true) return;
    switch (_inputMode) {
      case _InputMode.pencil:
        final hasStrokes = _pencilKey.currentState?.undoStroke() ?? false;
        if (!hasStrokes) _setAnswer(cropId, '');
        break;
      case _InputMode.editor:
        _editorKey.currentState?.backspace();
        break;
      case _InputMode.keyboard:
        final chars = _keyboardController.text.characters.toList();
        if (chars.isEmpty) return;
        chars.removeLast();
        final value = chars.join();
        _keyboardController.text = value;
        _setAnswer(cropId, value);
        break;
    }
  }

  void _clearCurrentInput() {
    final cropId = _selectedCropId;
    if (cropId == null || _results[cropId] == true) return;
    switch (_inputMode) {
      case _InputMode.pencil:
        _pencilKey.currentState?.clearStrokes();
        break;
      case _InputMode.editor:
        _editorKey.currentState?.clearAll();
        break;
      case _InputMode.keyboard:
        _keyboardController.clear();
        break;
    }
    _setAnswer(cropId, '');
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final page = _page;
    return Scaffold(
      backgroundColor: context.yggSurfaceBase,
      appBar: AppBar(
        leadingWidth: 300,
        leading: Row(
          children: [
            IconButton(
              tooltip: '뒤로',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            Expanded(
              child: Text(
                widget.book.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        centerTitle: true,
        title: _buildPaneModeButton(),
        actions: [
          if (page != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'p.${page.shownPage}',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      _pagePathLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          IconButton(
            tooltip: '소단원·페이지 선택',
            onPressed: () => setState(() => _treeOpen = !_treeOpen),
            icon: const Icon(Icons.segment_rounded),
          ),
          const SizedBox(width: 6),
        ],
        backgroundColor: context.yggSurfaceBase,
        elevation: 0,
      ),
      body: Stack(
        children: [
          Positioned.fill(child: _buildPagePanel(theme)),
          if (_treeOpen)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _treeOpen = false),
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.18),
                ),
              ),
            ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            right: _treeOpen ? 0 : -310,
            top: 0,
            bottom: 0,
            width: 310,
            child: IgnorePointer(
              ignoring: !_treeOpen,
              child: Material(
                color: context.yggSurfaceBase,
                elevation: 14,
                child: _buildTreePanel(theme),
              ),
            ),
          ),
          if (!_treeOpen)
            Positioned(
              top: 0,
              right: 0,
              bottom: 0,
              width: 28,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: (details) {
                  if ((details.primaryVelocity ?? 0) < -180) {
                    setState(() => _treeOpen = true);
                  }
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTreePanel(ThemeData theme) {
    final tree = _tree;
    if (_treeError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_treeError!, textAlign: TextAlign.center),
        ),
      );
    }
    if (tree == null) {
      return const Center(child: YggLoadingIndicator());
    }
    if (tree.bigUnits.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '이 교재에는 아직 풀 수 있는 문항이 없어요.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }

    final rows = <Widget>[];
    for (final big in tree.bigUnits) {
      final bigId = 'b${big.order}';
      rows.add(_treeRow(
        theme,
        id: bigId,
        label: big.name,
        depth: 0,
        bold: true,
        hasChildren: true,
      ));
      if (!_expanded.contains(bigId)) continue;
      for (final mid in big.mids) {
        final midId = '$bigId|m${mid.order}';
        rows.add(_treeRow(
          theme,
          id: midId,
          label: mid.name,
          depth: 1,
          hasChildren: true,
        ));
        if (!_expanded.contains(midId)) continue;
        for (final small in mid.smalls) {
          final smallId = '$midId|s${small.subKey}';
          rows.add(_treeRow(
            theme,
            id: smallId,
            label: small.name.isEmpty ? small.subKey : small.name,
            depth: 2,
            hasChildren: true,
          ));
          if (!_expanded.contains(smallId)) continue;
          for (final page in small.pages) {
            rows.add(_pageRow(
              theme,
              page,
              '${mid.name} · ${small.name.isEmpty ? small.subKey : small.name}',
            ));
          }
        }
      }
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      children: rows,
    );
  }

  Widget _treeRow(
    ThemeData theme, {
    required String id,
    required String label,
    required int depth,
    bool bold = false,
    bool hasChildren = false,
  }) {
    final expanded = _expanded.contains(id);
    return Padding(
      padding: EdgeInsets.only(left: depth * 14.0, bottom: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          setState(() {
            if (!_expanded.remove(id)) _expanded.add(id);
          });
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              if (hasChildren)
                Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 18,
                  color: theme.hintColor,
                )
              else
                const SizedBox(width: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pageRow(ThemeData theme, TbPageStat page, String pathLabel) {
    final selected = _page?.rawPage == page.rawPage &&
        _page?.subKey == page.subKey &&
        _page?.midOrder == page.midOrder;
    const accent = YggGlassTokens.confirmActionColor;
    final done = page.done;
    return Padding(
      padding: const EdgeInsets.only(left: 42, bottom: 2, right: 4),
      child: Material(
        color: selected ? accent.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _openPage(page, pathLabel),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(
                  done
                      ? Icons.check_circle_rounded
                      : (page.graded > 0
                          ? Icons.timelapse_rounded
                          : Icons.circle_outlined),
                  size: 16,
                  color: done
                      ? accent
                      : (page.graded > 0 ? accent : theme.hintColor),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'p.${page.shownPage}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? accent : null,
                    ),
                  ),
                ),
                Text(
                  '${page.correct}/${page.total}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPagePanel(ThemeData theme) {
    final page = _page;
    if (page == null) {
      return Center(
        child: Text(
          '왼쪽에서 풀고 싶은 페이지를 선택해 주세요.',
          style: theme.textTheme.bodyLarge?.copyWith(color: theme.hintColor),
        ),
      );
    }
    if (_loadingProblems) {
      return const Center(child: YggLoadingIndicator());
    }
    final problems = _problems ?? const <PageProblem>[];
    if (problems.isEmpty) {
      return Center(
        child: Text(
          '이 페이지에는 풀 수 있는 문항이 없어요.',
          style: theme.textTheme.bodyLarge?.copyWith(color: theme.hintColor),
        ),
      );
    }

    PageProblem? selectedProblem;
    for (final p in problems) {
      if (p.cropId == _selectedCropId) {
        selectedProblem = p;
        break;
      }
    }

    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 2,
              child: _paneMode == _PaneMode.answers
                  ? ListView.builder(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
                      itemCount: problems.length,
                      itemBuilder: (context, i) =>
                          _problemRow(theme, problems[i]),
                    )
                  : _buildQuestionPane(theme, selectedProblem),
            ),
            const SizedBox(
              height: 0.5,
              child: ColoredBox(color: Color(0x14000000)),
            ),
            Expanded(
              flex: 1,
              child: selectedProblem != null && !selectedProblem.isObjective
                  ? _buildInputPanel(theme, selectedProblem)
                  : const _EmptyInputCard(
                      message: '이 문항은 카드에서 답을 선택해 주세요.',
                    ),
            ),
          ],
        ),
        if (selectedProblem != null && !selectedProblem.isObjective)
          Positioned(
            left: 16,
            bottom: bottomInset / 2 + 6,
            child: _buildInputModeButton(),
          ),
        Positioned(
          right: 16,
          bottom: bottomInset / 2 + 6,
          child: _TextbookSolveFabBar(
            pendingCount: _pendingGradeCount,
            grading: _grading,
            canEdit: selectedProblem != null &&
                _results[selectedProblem.cropId] != true,
            hasAnswer: selectedProblem != null &&
                (_answers[selectedProblem.cropId]?.isNotEmpty ?? false),
            onPrevious: () => _moveProblem(-1),
            onNext: () => _moveProblem(1),
            onErase: _eraseCurrentInput,
            onClear: _clearCurrentInput,
            onGrade: _grade,
          ),
        ),
      ],
    );
  }

  Widget _buildPaneModeButton() {
    final showQuestion = _paneMode == _PaneMode.question;
    return _SolveGlassButton(
      tooltip: showQuestion ? '정답 목록으로 돌아가기' : '문항 보기',
      icon:
          showQuestion ? Icons.fact_check_outlined : Icons.description_outlined,
      label: showQuestion ? '정답' : '문항',
      onPressed: _togglePaneMode,
    );
  }

  Widget _buildInputModeButton() {
    final (icon, tooltip) = switch (_inputMode) {
      _InputMode.pencil => (Icons.edit_rounded, '수식 입력으로 전환'),
      _InputMode.editor => (Icons.functions_rounded, '키보드 입력으로 전환'),
      _InputMode.keyboard => (Icons.keyboard_outlined, '펜슬 입력으로 전환'),
    };
    return _SolveGlassCircleButton(
      tooltip: tooltip,
      icon: icon,
      onPressed: _cycleInputMode,
    );
  }

  Widget _buildQuestionPane(ThemeData theme, PageProblem? problem) {
    if (problem == null) {
      return const Center(child: Text('표시할 문항이 없어요.'));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 10),
      child: Column(
        children: [
          _problemRow(theme, problem),
          const SizedBox(height: 12),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius:
                    BorderRadius.circular(YggGroupedLayoutTokens.cardRadius),
                border: Border.all(color: const Color(0x1F000000)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius:
                    BorderRadius.circular(YggGroupedLayoutTokens.cardRadius),
                child: _buildProblemPdf(theme),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProblemPdf(ThemeData theme) {
    if (_loadingProblemView) {
      return const Center(child: YggLoadingIndicator());
    }
    final error = _problemViewError;
    if (error != null) {
      return _problemViewMessage(
        theme,
        _problemViewErrorMessage(error),
        icon: Icons.error_outline_rounded,
      );
    }
    final view = _problemView;
    if (view == null) {
      return _problemViewMessage(theme, '문항을 선택해 주세요.');
    }
    if (view.isQueued) {
      return _problemViewMessage(
        theme,
        '문항 PDF를 준비하고 있어요.\n잠시 후 문항을 다시 선택해 주세요.',
        icon: Icons.hourglass_top_rounded,
      );
    }
    final url =
        view.isFallback ? (view.bodyPdfUrl ?? view.pdfUrl) : view.pdfUrl;
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null) {
      return _problemViewMessage(
        theme,
        view.isFallback ? '원본 교재 PDF를 열 수 없어요.' : '준비된 문항 PDF를 열 수 없어요.',
        icon: Icons.error_outline_rounded,
      );
    }
    return _ProblemPdfView(
      key: ValueKey<String>(
        '${view.status.name}|$url|${view.rawPage}|${view.itemRegion1k}',
      ),
      uri: uri,
      fallbackPage: view.isFallback ? view.rawPage : null,
      itemRegion1k: view.isFallback ? view.itemRegion1k : null,
    );
  }

  Widget _problemViewMessage(
    ThemeData theme,
    String message, {
    IconData? icon,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 30, color: theme.hintColor),
              const SizedBox(height: 10),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _problemViewErrorMessage(Object error) {
    if (error is! StudentTextbookProblemViewException) {
      return '문항 PDF를 불러오지 못했어요.';
    }
    return switch (error.code) {
      'unauthorized' || 'student_account_not_found' => '로그인 정보를 다시 확인해 주세요.',
      'crop_not_assigned' => '이 문항의 교재 정보를 찾지 못했어요.',
      'question_not_mapped' => '이 문항은 아직 PDF로 준비되지 않았어요.',
      _ => '문항 PDF를 불러오지 못했어요. (${error.code})',
    };
  }

  static const Map<String, String> _flagMessages = {
    'unit_hint': '정답이에요! 다음엔 단위도 함께 써 보세요.',
    'unit_caution': '단위를 다시 확인해 보세요.',
    'form_differs': '정답! 답지와 표기는 조금 달라요.',
  };

  Widget _problemRow(ThemeData theme, PageProblem problem) {
    final isDark = theme.brightness == Brightness.dark;
    final answer = _answers[problem.cropId] ?? '';
    final result = _results[problem.cropId];
    final attemptCount = _attemptCounts[problem.cropId] ?? 0;
    final graded = result != null &&
        (_selfGraded.contains(problem.cropId) ||
            _gradedAnswers[problem.cropId] == answer);
    final selected = _selectedCropId == problem.cropId;
    const accent = YggGlassTokens.confirmActionColor;
    const wrongColor = Color(0xFFE57373);
    const cautionColor = Color(0xFFE0A63C);

    Color borderColor;
    if (graded) {
      borderColor = result ? accent : wrongColor;
    } else if (selected) {
      borderColor = accent.withValues(alpha: 0.6);
    } else {
      borderColor = theme.dividerColor.withValues(alpha: 0.4);
    }

    final flagNotes = graded
        ? (_flags[problem.cropId] ?? const <String>[])
            .map((f) => _flagMessages[f])
            .whereType<String>()
            .toList(growable: false)
        : const <String>[];

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: isDark ? Colors.white.withValues(alpha: 0.03) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: problem.isObjective || result == true
              ? null
              : () => setState(() => _selectPro(problem)),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor, width: graded ? 2 : 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 64,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            problem.problemNumber,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          if (problem.label.isNotEmpty)
                            Text(
                              problem.label,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.hintColor),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: problem.isObjective
                          ? _objectiveButtons(theme, problem)
                          : Text(
                              answer.isEmpty
                                  ? (problem.isSelfCheck
                                      ? '공책에 풀고 정답을 확인해 보세요'
                                      : '답을 입력해 주세요')
                                  : answer,
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: answer.isEmpty ? theme.hintColor : null,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                    const SizedBox(width: 12),
                    if (problem.isSelfCheck) ...[
                      OutlinedButton.icon(
                        onPressed:
                            result == true ? null : () => _selfCheck(problem),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: graded ? theme.hintColor : accent,
                          side: BorderSide(
                            color: (graded ? theme.hintColor : accent)
                                .withValues(alpha: 0.5),
                          ),
                        ),
                        icon: const Icon(Icons.visibility_outlined, size: 18),
                        label: Text(result == true
                            ? '완료'
                            : graded
                                ? '다시 확인'
                                : '정답 확인'),
                      ),
                      const SizedBox(width: 10),
                    ],
                    if (graded && result && attemptCount > 1) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '수정 · $attemptCount회 만에',
                          style: const TextStyle(
                            color: accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 9),
                    ] else if (graded && !result) ...[
                      const Text(
                        '다시 풀기',
                        style: TextStyle(
                          color: wrongColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 9),
                    ],
                    if (graded)
                      Icon(
                        result ? Icons.circle_outlined : Icons.close_rounded,
                        size: 26,
                        color: result ? accent : wrongColor,
                      )
                    else if (answer.isNotEmpty)
                      Icon(Icons.edit_rounded,
                          size: 18, color: theme.hintColor),
                  ],
                ),
                for (final note in flagNotes)
                  Padding(
                    padding: const EdgeInsets.only(left: 72, top: 6),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline_rounded,
                            size: 15, color: cautionColor),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            note,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cautionColor),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _objectiveButtons(ThemeData theme, PageProblem problem) {
    const circled = ['①', '②', '③', '④', '⑤'];
    final answer = _answers[problem.cropId] ?? '';
    final selected = answer
        .split(',')
        .where((s) => s.trim().isNotEmpty)
        .map(int.parse)
        .toSet();
    const accent = YggGlassTokens.confirmActionColor;

    return Wrap(
      spacing: 8,
      children: [
        for (var n = 1; n <= 5; n++)
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => _toggleObjective(problem.cropId, n),
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected.contains(n)
                    ? accent.withValues(alpha: 0.18)
                    : Colors.transparent,
                border: Border.all(
                  color: selected.contains(n)
                      ? accent
                      : theme.dividerColor.withValues(alpha: 0.6),
                  width: selected.contains(n) ? 2 : 1,
                ),
              ),
              child: Center(
                child: Text(
                  circled[n - 1],
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: selected.contains(n) ? accent : theme.hintColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildInputPanel(ThemeData theme, PageProblem problem) {
    final answer = _answers[problem.cropId] ?? '';
    final inputTheme = ThemeData.light(useMaterial3: true).copyWith(
      colorScheme: ColorScheme.fromSeed(
        seedColor: YggGlassTokens.confirmActionColor,
        brightness: Brightness.light,
      ),
      textTheme: theme.textTheme.apply(
        bodyColor: const Color(0xFF17201F),
        displayColor: const Color(0xFF17201F),
      ),
    );

    return Theme(
      data: inputTheme,
      child: Container(
        color: Colors.white,
        child: Stack(
          children: [
            Positioned.fill(
              child: switch (_inputMode) {
                _InputMode.pencil => LayoutBuilder(
                    builder: (context, constraints) => PencilInputPad(
                      key: _pencilKey,
                      height: constraints.maxHeight,
                      showControls: false,
                      showEmptyHint: false,
                      embedded: true,
                      onRecognized: (text) => _setAnswer(problem.cropId, text),
                    ),
                  ),
                _InputMode.editor => SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 56, 20, 90),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MathExpressionEditor(
                          key: _editorKey,
                          initialLinear: answer,
                          onChanged: (linear) =>
                              _setAnswer(problem.cropId, linear),
                        ),
                        const SizedBox(height: 8),
                        MathKeypad(
                          onInsert: (t) =>
                              _editorKey.currentState?.insertText(t),
                          onFraction: () =>
                              _editorKey.currentState?.insertFraction(),
                          onSqrt: () => _editorKey.currentState?.insertSqrt(),
                          onNthRoot: () =>
                              _editorKey.currentState?.insertNthRoot(),
                          onPower: () => _editorKey.currentState?.insertPower(),
                          onRepeatingDot: () =>
                              _editorKey.currentState?.insertRepeatingDot(),
                          onBackspace: () =>
                              _editorKey.currentState?.backspace(),
                          onClear: () => _editorKey.currentState?.clearAll(),
                        ),
                      ],
                    ),
                  ),
                _InputMode.keyboard => Padding(
                    padding: const EdgeInsets.fromLTRB(20, 56, 20, 90),
                    child: TextField(
                      controller: _keyboardController,
                      autofocus: true,
                      expands: true,
                      minLines: null,
                      maxLines: null,
                      textAlignVertical: TextAlignVertical.top,
                      onChanged: (text) => _setAnswer(problem.cropId, text),
                      style: theme.textTheme.titleMedium,
                      decoration: const InputDecoration(
                        hintText: '한글 답(예: 제2사분면, 유한소수)을 입력해 주세요',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
              },
            ),
            Positioned(
              top: 12,
              left: 20,
              right: 20,
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xD91F2928),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      child: Text(
                        '${problem.problemNumber}번 답  ·  '
                        '${answer.isEmpty ? '입력 전' : answer}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProblemPdfView extends StatelessWidget {
  const _ProblemPdfView({
    super.key,
    required this.uri,
    this.fallbackPage,
    this.itemRegion1k,
  });

  final Uri uri;
  final int? fallbackPage;
  final List<int>? itemRegion1k;

  @override
  Widget build(BuildContext context) {
    if (fallbackPage != null) {
      return _FallbackProblemPdfPage(
        uri: uri,
        pageNumber: fallbackPage!,
        itemRegion1k: itemRegion1k,
      );
    }
    return PdfViewer.uri(
      uri,
      params: PdfViewerParams(
        backgroundColor: Colors.white,
        margin: 12,
        pageAnchor: PdfPageAnchor.center,
        pageAnchorEnd: PdfPageAnchor.center,
        panEnabled: true,
        scaleEnabled: true,
        panAxis: PanAxis.free,
        minScale: 0.1,
        maxScale: 8,
        loadingBannerBuilder: (context, downloaded, total) =>
            const Center(child: YggLoadingIndicator()),
        errorBannerBuilder: (context, error, stackTrace, documentRef) =>
            const Center(child: Text('문항 PDF를 표시할 수 없어요.')),
      ),
    );
  }
}

class _FallbackProblemPdfPage extends StatefulWidget {
  const _FallbackProblemPdfPage({
    required this.uri,
    required this.pageNumber,
    this.itemRegion1k,
  });

  final Uri uri;
  final int pageNumber;
  final List<int>? itemRegion1k;

  @override
  State<_FallbackProblemPdfPage> createState() =>
      _FallbackProblemPdfPageState();
}

class _FallbackProblemPdfPageState extends State<_FallbackProblemPdfPage> {
  PdfDocument? _document;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final document = await PdfDocument.openUri(widget.uri);
      if (!mounted) {
        await document.dispose();
        return;
      }
      setState(() => _document = document);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    final document = _document;
    if (document != null) unawaited(document.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return const Center(child: Text('원본 교재 PDF를 표시할 수 없어요.'));
    }
    final document = _document;
    if (document == null) {
      return const Center(child: YggLoadingIndicator());
    }
    final pageNumber =
        widget.pageNumber.clamp(1, document.pages.length).toInt();
    final region = widget.itemRegion1k;
    if (region == null || region.length != 4) {
      return InteractiveViewer(
        minScale: 1,
        maxScale: 6,
        child: PdfPageView(
          document: document,
          pageNumber: pageNumber,
          decoration: const BoxDecoration(color: Colors.white),
        ),
      );
    }
    return _CroppedPdfPage(
      document: document,
      pageNumber: pageNumber,
      itemRegion1k: region,
    );
  }
}

class _CroppedPdfPage extends StatelessWidget {
  const _CroppedPdfPage({
    required this.document,
    required this.pageNumber,
    required this.itemRegion1k,
  });

  final PdfDocument document;
  final int pageNumber;
  final List<int> itemRegion1k;

  @override
  Widget build(BuildContext context) {
    final page = document.pages[pageNumber - 1];
    const padding = 16.0;
    final top = ((itemRegion1k[0] - padding) / 1000).clamp(0.0, 1.0).toDouble();
    final left =
        ((itemRegion1k[1] - padding) / 1000).clamp(0.0, 1.0).toDouble();
    final bottom =
        ((itemRegion1k[2] + padding) / 1000).clamp(0.0, 1.0).toDouble();
    final right =
        ((itemRegion1k[3] + padding) / 1000).clamp(0.0, 1.0).toDouble();
    final regionWidth = right - left;
    final regionHeight = bottom - top;
    if (regionWidth <= 0.01 || regionHeight <= 0.01) {
      return InteractiveViewer(
        minScale: 1,
        maxScale: 6,
        child: PdfPageView(
          document: document,
          pageNumber: pageNumber,
          decoration: const BoxDecoration(color: Colors.white),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final widthScale = constraints.maxWidth / (page.width * regionWidth);
        final heightScale =
            constraints.maxHeight / (page.height * regionHeight);
        final scale = widthScale < heightScale ? widthScale : heightScale;
        final pageWidth = page.width * scale;
        final pageHeight = page.height * scale;
        final cropWidth = pageWidth * regionWidth;
        final cropHeight = pageHeight * regionHeight;
        final offsetX =
            (constraints.maxWidth - cropWidth) / 2 - pageWidth * left;
        final offsetY =
            (constraints.maxHeight - cropHeight) / 2 - pageHeight * top;

        return InteractiveViewer(
          minScale: 1,
          maxScale: 6,
          boundaryMargin: const EdgeInsets.all(80),
          child: SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned(
                    left: offsetX,
                    top: offsetY,
                    width: pageWidth,
                    height: pageHeight,
                    child: PdfPageView(
                      document: document,
                      pageNumber: pageNumber,
                      decoration: const BoxDecoration(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EmptyInputCard extends StatelessWidget {
  const _EmptyInputCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      alignment: Alignment.center,
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFF6B7280),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SolveGlassButton extends StatelessWidget {
  const _SolveGlassButton({
    required this.tooltip,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Tooltip(
          message: tooltip,
          child: Material(
            color: isDark
                ? const Color(0xE62A3333)
                : Colors.white.withValues(alpha: 0.92),
            child: InkWell(
              onTap: onPressed,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 20),
                    const SizedBox(width: 7),
                    Text(
                      label,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SolveGlassCircleButton extends StatelessWidget {
  const _SolveGlassCircleButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipOval(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: isDark
              ? const Color(0xE62A3333)
              : Colors.white.withValues(alpha: 0.92),
          child: IconButton(
            tooltip: tooltip,
            onPressed: onPressed,
            icon: Icon(icon, size: 22),
            constraints: const BoxConstraints.tightFor(width: 56, height: 56),
          ),
        ),
      ),
    );
  }
}

class _TextbookSolveFabBar extends StatelessWidget {
  const _TextbookSolveFabBar({
    required this.pendingCount,
    required this.grading,
    required this.canEdit,
    required this.hasAnswer,
    required this.onPrevious,
    required this.onNext,
    required this.onErase,
    required this.onClear,
    required this.onGrade,
  });

  final int pendingCount;
  final bool grading;
  final bool canEdit;
  final bool hasAnswer;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onErase;
  final VoidCallback onClear;
  final VoidCallback onGrade;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xE62A3333)
                : Colors.white.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: isDark ? Colors.white12 : Colors.black12,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x24000000),
                blurRadius: 18,
                offset: Offset(0, 7),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SolveFabIconButton(
                tooltip: '이전 문제',
                icon: Icons.chevron_left_rounded,
                onPressed: onPrevious,
              ),
              _SolveFabIconButton(
                tooltip: '다음 문제',
                icon: Icons.chevron_right_rounded,
                onPressed: onNext,
              ),
              const SizedBox(
                height: 26,
                child: VerticalDivider(width: 12),
              ),
              _SolveFabIconButton(
                tooltip: '한 단계 지우기',
                icon: Icons.backspace_outlined,
                onPressed: canEdit ? onErase : null,
              ),
              _SolveFabIconButton(
                tooltip: '모두 지우기',
                icon: Icons.delete_sweep_outlined,
                onPressed: canEdit && hasAnswer ? onClear : null,
              ),
              const SizedBox(width: 5),
              FilledButton.icon(
                onPressed: pendingCount > 0 && !grading ? onGrade : null,
                style: FilledButton.styleFrom(
                  backgroundColor: YggGlassTokens.confirmActionColor,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(112, 44),
                  shape: const StadiumBorder(),
                ),
                icon: grading
                    ? const YggLoadingIndicator(size: 18)
                    : Badge(
                        isLabelVisible: pendingCount > 0,
                        label: Text('$pendingCount'),
                        child: const Icon(
                          Icons.fact_check_outlined,
                          size: 20,
                        ),
                      ),
                label: const Text(
                  '채점',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SolveFabIconButton extends StatelessWidget {
  const _SolveFabIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 22),
      constraints: const BoxConstraints.tightFor(width: 43, height: 43),
      padding: EdgeInsets.zero,
    );
  }
}

/// 셀프 채점 다이얼로그 — 정답을 보여주고 학생이 O/X 선택.
class _SelfCheckDialog extends StatelessWidget {
  const _SelfCheckDialog({
    required this.problemNumber,
    required this.revealed,
    this.myAnswer,
  });

  final String problemNumber;
  final RevealedAnswer revealed;
  final String? myAnswer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    const accent = YggGlassTokens.confirmActionColor;
    const wrongColor = Color(0xFFE57373);
    final answerText = (revealed.answerText?.trim().isNotEmpty ?? false)
        ? revealed.answerText!.trim()
        : revealed.answerLatex2d?.trim() ?? '';

    return Dialog(
      backgroundColor: isDark ? const Color(0xFF1F2A2A) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '$problemNumber번 정답',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              if (revealed.imageUrl != null)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    // 답지 크롭/렌더 PNG는 밝은 종이 배경 기준 → 항상 흰 배경
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Image.network(
                    revealed.imageUrl!,
                    fit: BoxFit.contain,
                    loadingBuilder: (context, child, progress) => progress ==
                            null
                        ? child
                        : const SizedBox(
                            height: 80,
                            child: Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                    errorBuilder: (_, __, ___) => Text(
                      answerText.isEmpty ? '(정답 이미지를 불러오지 못했어요)' : answerText,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: Colors.black87),
                    ),
                  ),
                )
              else
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.black.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(
                    answerText.isEmpty ? '(등록된 정답 표기가 없어요)' : answerText,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600, height: 1.5),
                  ),
                ),
              if (myAnswer != null && myAnswer!.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  '내가 쓴 답: ${myAnswer!.trim()}',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.hintColor),
                ),
              ],
              const SizedBox(height: 20),
              Text(
                '내 풀이와 비교해서 스스로 채점해 주세요.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.hintColor),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: wrongColor,
                        side: BorderSide(
                            color: wrongColor.withValues(alpha: 0.55)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      icon: const Icon(Icons.close_rounded),
                      label: const Text('틀렸어요',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.of(context).pop(true),
                      style: FilledButton.styleFrom(
                        backgroundColor: accent,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      icon: const Icon(Icons.circle_outlined),
                      label: const Text('맞았어요',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  '나중에 채점하기',
                  style: TextStyle(color: theme.hintColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
