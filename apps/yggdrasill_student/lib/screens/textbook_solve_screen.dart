import 'dart:async';
import 'dart:convert' show base64Encode;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerDeviceKind,
        PointerScaleEvent,
        PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:pdfrx/pdfrx.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/apple_pencil_undo.dart';
import '../services/display_physical_ppi.dart';
import '../services/question_view_scale.dart';
import '../services/handwriting_candidates.dart';
import '../services/homework_session.dart';
import '../services/student_api.dart';
import '../services/student_point_session.dart';
import '../services/textbook_api.dart';
import '../widgets/math_expression_editor.dart';
import '../widgets/math_keypad.dart';
import '../widgets/math_latex_view.dart';
import '../widgets/pencil_ink_history.dart';
import '../widgets/pencil_input_pad.dart';
import '../widgets/solve_view_menu.dart';
import '../widgets/student_back_button.dart';
import '../widgets/student_confirm_sheet.dart';
import '../widgets/student_page_title.dart';
import '../widgets/student_status_island.dart';

enum _InputMode { pencil, editor, keyboard }

enum _PaneMode { answers, question, body }

/// 페이지를 열 때 어떤 문항을 선택할지.
enum _PageEntrySelect { auto, first, last }

const double _kPageSheetWidth = 318;

/// 페이지 시트 왼쪽 그림자가 닫힌 뒤에도 화면에 남지 않도록 추가 오프셋.
const double _kPageSheetShadowBleed = 40;

/// 연습장 위쪽 라운드 그림자가 잘리지 않도록 확보하는 여백.
const double _kScratchTopShadow = 20;

/// 과제로 배정된 문항만 풀도록 범위를 좁히는 컨텍스트.
/// null 이면 교재 풀기 탭에서 들어온 자유 풀이다.
class HomeworkSolveScope {
  const HomeworkSolveScope({
    required this.groupId,
    required this.title,
    required this.cropIds,
    required this.rawPages,
    this.orderedCropIds = const <String>[],
  });

  final String groupId;
  final String title;

  /// 배정된 문항 crop id. 페이지에 다른 문항이 섞여 있어도 이것만 보여준다.
  final Set<String> cropIds;

  /// 배정 순서대로 나열된 crop id (과제 독립 번호 1, 2, 3… 부여 기준).
  final List<String> orderedCropIds;

  /// 배정 문항이 있는 페이지. 이 페이지들 사이에서만 이동한다.
  final Set<int> rawPages;

  bool get isEmpty => cropIds.isEmpty;
}

/// 기존 교재 풀이 UI를 그대로 사용하는 시간제한 시험 컨텍스트.
class TimedTestSolveConfig {
  const TimedTestSolveConfig({
    required this.group,
    required this.problems,
  });

  final HomeworkGroup group;
  final List<HomeworkProblem> problems;
}

/// 교재 풀이 화면.
/// 좌: 단원트리(대→중→소→페이지), 우: 페이지 문항 + 정답 입력 + 일괄 채점.
///
/// [homework] 가 주어지면 과제 스코프로 동작한다. 배정 문항만 노출하고,
/// 채점 결과를 과제에 연결해 기록하며, 전부 맞히면 과제를 통과시킨다.
class TextbookSolveScreen extends StatefulWidget {
  const TextbookSolveScreen({
    super.key,
    required this.book,
    this.homework,
    this.timedTest,
  });

  final StudentTextbook book;
  final HomeworkSolveScope? homework;
  final TimedTestSolveConfig? timedTest;

  @override
  State<TextbookSolveScreen> createState() => _TextbookSolveScreenState();
}

/// 페이지 버튼 오른쪽, 뒤로가기 왼쪽, 채점 버튼 오른쪽이 공유하는 화면 끝 여백.
const double _solveEdgeInset = 6;

class _TextbookSolveScreenState extends State<TextbookSolveScreen>
    with WidgetsBindingObserver {
  TextbookUnitTree? _tree;
  String? _treeError;
  final Set<String> _expanded = <String>{};

  TbPageStat? _page;
  String _pagePathLabel = '';
  List<PageProblem>? _problems;
  bool _loadingProblems = false;

  /// 이 화면에서 열어 본 모든 문항 (crop_id →). 페이지를 넘어가도 답이
  /// 사라지지 않게, 일괄 채점이 다른 페이지의 미채점 답까지 모을 수 있게 한다.
  final Map<String, PageProblem> _seenProblems = <String, PageProblem>{};

  /// 이번 방문에서 채점(자동·셀프)이 한 번이라도 있었는가.
  /// 과제 모드에서 나갈 때 "안 푼 문항 미수행 기록"을 할지 판단한다.
  bool _gradedThisVisit = false;

  /// 나가기 처리(잔여 답 채점 + 미수행 기록)가 도는 중.
  bool _exitFlushing = false;

  /// crop_id → 현재 입력값
  final Map<String, String> _answers = <String, String>{};

  /// 답 상태 키 → MyScript 원본 LaTeX.
  ///
  /// 채점·저장은 [_answers]의 선형 표기를 사용하고, 학생 화면만 이 구조 보존
  /// 원문으로 그린다. 수동 입력으로 답을 고치면 해당 원문은 폐기한다.
  final Map<String, String> _answerDisplayLatex = <String, String>{};

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

  /// crop_id → 신고 상태 (open: 검토 중, accepted: 신고 인정, rejected: 반려)
  final Map<String, String> _reportStatuses = <String, String>{};

  /// crop_id → 마지막 필기 인식 스냅샷. 입력 모드 전환이나 문항 이동으로
  /// 필기 패드가 언마운트된 뒤에도 신고(필기 인식 불량)에 첨부할 수 있다.
  final Map<String, Map<String, dynamic>> _handwritingSnapshots =
      <String, Map<String, dynamic>>{};

  /// crop_id → 선지 번호 → 펜슬로 그은 체크. 손가락으로 고른 번호는
  /// 여기 두지 않고 초록 체크만 그린다.
  final Map<String, Map<int, List<Offset>>> _objectivePencilMarks =
      <String, Map<int, List<Offset>>>{};

  /// 펼쳐진 세트형 문항 카드
  final Set<String> _expandedSetCrops = <String>{};

  String? _selectedCropId;

  /// 세트형 문항에서 선택된 파트 키('(1)'). 일반 문항은 null.
  String? _selectedPartKey;
  _InputMode _inputMode = _InputMode.pencil;
  _PaneMode _paneMode = _PaneMode.answers;
  StudentTextbookProblemView? _problemView;
  Object? _problemViewError;
  bool _loadingProblemView = false;
  StudentTextbookProblemSetView? _problemSetView;
  Object? _problemSetViewError;
  bool _loadingProblemSetView = false;
  String? _activeSetCacheKey;
  int _problemViewRequestEpoch = 0;
  final Map<String, StudentTextbookProblemView> _problemViewCache =
      <String, StudentTextbookProblemView>{};
  final Map<String, Future<StudentTextbookProblemView>> _problemViewRequests =
      <String, Future<StudentTextbookProblemView>>{};
  final Map<String, StudentTextbookProblemView> _bodyViewCache =
      <String, StudentTextbookProblemView>{};
  final Map<int, StudentTextbookProblemView> _bodyViewByPage =
      <int, StudentTextbookProblemView>{};
  final Map<String, ({Uri uri, DateTime expiresAt})> _bodyBookUrlCache =
      <String, ({Uri uri, DateTime expiresAt})>{};
  bool _bodyFullDocReady = false;
  final Map<String, StudentTextbookProblemSetView> _problemSetViewCache =
      <String, StudentTextbookProblemSetView>{};
  final Map<String, Future<StudentTextbookProblemSetView>>
      _problemSetViewRequests = <String, Future<StudentTextbookProblemSetView>>{};
  final Map<String, ProblemSetInfo> _problemSetInfoByCrop =
      <String, ProblemSetInfo>{};
  final Map<String, GlobalKey<PencilInputPadState>> _setPencilKeys =
      <String, GlobalKey<PencilInputPadState>>{};
  final Map<int, GlobalKey<MultiTargetPencilOverlayState>> _bodyPencilKeys =
      <int, GlobalKey<MultiTargetPencilOverlayState>>{};
  final Map<int, Map<String, List<int>>> _bodyRegionsByPage =
      <int, Map<String, List<int>>>{};
  final Map<int, Map<String, List<int>>> _bodyNumberBoxesByPage =
      <int, Map<String, List<int>>>{};
  final Map<int, Map<String, Map<int, List<int>>>> _bodyChoiceRegionsByPage =
      <int, Map<String, Map<int, List<int>>>>{};
  final Set<String> _prefetchedCropIds = <String>{};
  final Set<String> _neighborQueueRequestedCropIds = <String>{};

  /// 페이지를 열 때마다 증가. 예열은 백그라운드로 길게 도니까, 페이지가 바뀌면
  /// 지난 페이지의 예열이 계속 돌지 않도록 이 값으로 끊는다.
  int _pageEpoch = 0;

  /// 이미 다음 페이지 예열을 요청한 페이지 (rawPage|subKey).
  final Set<String> _nextPageWarmedKeys = <String>{};
  bool _grading = false;
  bool _treeOpen = false;

  /// 상단 바 배경은 스크롤에 따라 옅어진다.
  /// 뒤로가기·모음·페이지 버튼은 번호 목록 위에 그대로 남는다.
  double _titleOpacity = 1;

  /// 첫 진입·위로 스크롤하면 교재명, 아래로 스크롤하면 문항번호.
  bool _titleShowsBook = true;
  double _titleScrollPixels = 0;
  double _titleScrollAccum = 0;
  final ScrollController _answersScrollController = ScrollController();

  /// 번호 카드 목록에서 스크롤 0이 가리키는 문항.
  /// 이 문항이 화면 맨 위에 오고, 앞 페이지는 위로, 뒤 페이지는 아래로 붙는다.
  int _anchorIndex = 0;
  final GlobalKey _feedCenterKey = GlobalKey();
  final GlobalKey _selectedCardKey = GlobalKey();
  final Set<int> _loadedCardRawPages = <int>{};
  final Map<int, Future<void>> _cardPageLoads = <int, Future<void>>{};
  final Map<String, ({TbPageStat page, String pathLabel})> _problemPageMeta =
      <String, ({TbPageStat page, String pathLabel})>{};

  /// 과제 회차 기록. 페이지를 이어 붙일 때마다 같은 목록을 다시 받지 않는다.
  Map<String, HomeworkProblem>? _homeworkRoundByCrop;
  final ScrollController _questionScrollController = ScrollController();
  final ScrollController _bodyScrollController = ScrollController();

  /// 임시 연습장 (저장·채점 없음).
  bool _scratchOpen = false;
  double _scratchHeight = 0;
  double _scratchRestoredHeight = 0;
  bool _scratchCollapsed = false;

  /// 하단 입력 패널 높이 측정용 (접힌 연습장 높이 = 이 패널을 딱 가림).
  final GlobalKey _inputPanelKey = GlobalKey();

  GlobalKey<MathExpressionEditorState> _editorKey =
      GlobalKey<MathExpressionEditorState>();
  GlobalKey<PencilInputPadState> _pencilKey = GlobalKey<PencilInputPadState>();

  /// 필기 인식이 돌고 있는 답 키. 문항을 넘긴 뒤에도 인식은 계속되므로
  /// 결과가 올 때까지 해당 카드에 "인식 중"을 띄운다.
  final Set<String> _recognizingAnswerKeys = <String>{};
  final GlobalKey<_ScratchPracticeSheetState> _scratchKey =
      GlobalKey<_ScratchPracticeSheetState>();
  final TextEditingController _keyboardController = TextEditingController();

  Timer? _timedTimer;
  TimedTestSession? _timedSession;
  TimedTestExposure? _timedExposure;
  late Duration _timedServerClockOffset;
  final Stopwatch _timedActiveWatch = Stopwatch();
  final Stopwatch _timedWallWatch = Stopwatch();
  int _timedIndex = 0;
  bool _timedPreparing = false;
  bool _timedFinishing = false;

  bool get _isTimedTest => widget.timedTest != null;

  late final Map<String, int> _homeworkOrderByCrop = <String, int>{
    for (var i = 0;
        i < (widget.homework?.orderedCropIds.length ?? 0);
        i++)
      if (widget.homework!.orderedCropIds[i].trim().isNotEmpty)
        widget.homework!.orderedCropIds[i]: i,
  };

  /// 화면에 표시할 문항 번호. 과제는 배정 순서 독립 번호(1, 2, 3…), 교재는 원본 번호.
  String _displayProblemNumber(PageProblem problem) {
    if (_isTimedTest) return '제 ${_timedIndex + 1}문제';
    if (widget.homework != null) {
      final order = _homeworkOrderByCrop[problem.cropId];
      if (order != null) return '${order + 1}';
    }
    return problem.problemNumber;
  }

  /// 독립형 세트에 속한 문항이면 현재 목록에서 함께 묶어 보여줄 하위 문항들을 돌려준다.
  /// 시간제한 테스트에서는 한 화면에 1문항만 띄우므로 현재 문항만 묶어(공통 발문 + 하위 1문항) 반환한다.
  List<PageProblem>? _independentSetGroupFor(PageProblem problem) {
    final info = _problemSetInfoByCrop[problem.cropId];
    if (info == null || !info.isIndependentSet) return null;
    if (_isTimedTest) return <PageProblem>[problem];
    final problems = _problems ?? const <PageProblem>[];
    final index = problems.indexWhere((p) => p.cropId == problem.cropId);
    if (index < 0) return <PageProblem>[problem];
    if (widget.homework != null) {
      var start = index;
      while (start > 0 &&
          _problemSetInfoByCrop[problems[start - 1].cropId]?.setKey ==
              info.setKey) {
        start--;
      }
      var end = index;
      while (end + 1 < problems.length &&
          _problemSetInfoByCrop[problems[end + 1].cropId]?.setKey ==
              info.setKey) {
        end++;
      }
      return problems.sublist(start, end + 1);
    }
    final group = <PageProblem>[
      for (final p in problems)
        if (_problemSetInfoByCrop[p.cropId]?.setKey == info.setKey) p,
    ];
    return group.isEmpty ? <PageProblem>[problem] : group;
  }

  String _formatSetRangeHeading(List<PageProblem> group) {
    if (group.isEmpty) return '';
    if (group.length == 1) {
      final number = _displayProblemNumber(group.single).trim();
      return number.isEmpty ? '' : '$number번';
    }
    final labels = group
        .map((p) => _displayProblemNumber(p).trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (labels.isEmpty) return '';
    if (labels.length == 1) return '${labels.first}번';
    final ints = labels
        .map((s) => int.tryParse(s.replaceAll(RegExp(r'\D'), '')))
        .toList(growable: false);
    final continuous = ints.every((n) => n != null) &&
        List.generate(ints.length - 1, (i) => ints[i + 1]! == ints[i]! + 1)
            .every((ok) => ok);
    if (continuous) return '[${labels.first}~${labels.last}]';
    return '[${labels.join(', ')}]';
  }

  GlobalKey<PencilInputPadState> _setPencilKeyFor(String cropId) {
    return _setPencilKeys.putIfAbsent(
      cropId,
      () => GlobalKey<PencilInputPadState>(),
    );
  }

  GlobalKey<MultiTargetPencilOverlayState> _bodyPencilKeyFor(int rawPage) {
    return _bodyPencilKeys.putIfAbsent(
      rawPage,
      () => GlobalKey<MultiTargetPencilOverlayState>(),
    );
  }

  @override
  void dispose() {
    ApplePencilUndo.unbindErase(this);
    WidgetsBinding.instance.removeObserver(this);
    _problemViewRequestEpoch++;
    _answersScrollController.removeListener(_onAnswersScroll);
    _questionScrollController.removeListener(_onQuestionScroll);
    _bodyScrollController.removeListener(_onBodyScroll);
    _answersScrollController.dispose();
    _questionScrollController.dispose();
    _bodyScrollController.dispose();
    _keyboardController.dispose();
    _timedTimer?.cancel();
    _timedActiveWatch.stop();
    _timedWallWatch.stop();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_isTimedTest || _timedExposure == null || _timedFinishing) return;
    if (state == AppLifecycleState.resumed) {
      if (_timedRemainingSeconds <= 0) {
        unawaited(_finishTimedTest());
      } else {
        _timedActiveWatch.start();
        if (mounted) setState(() {});
      }
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _timedActiveWatch.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _answersScrollController.addListener(_onAnswersScroll);
    _questionScrollController.addListener(_onQuestionScroll);
    _bodyScrollController.addListener(_onBodyScroll);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    ApplePencilUndo.bindErase(owner: this, onErase: _eraseFromApplePencil);
    if (_isTimedTest) {
      _paneMode = _PaneMode.question;
      unawaited(_prepareTimedTest());
    } else {
      _loadTree(selectLastPage: true);
    }
  }

  /// 현재 페이지 문항을 렌더 큐에 넣는다.
  ///
  /// 교재 전체 예열은 콜드 교재에서 지금 볼 문항을 큐 뒤로 밀어내므로 쓰지
  /// 않고, 페이지 단위로만 예열한다.
  Future<void> _warmCurrentPageProblemViews(
    List<PageProblem> problems, {
    bool enqueue = true,
  }) async {
    final cropIds = <String>[
      for (final problem in problems) problem.cropId,
    ];
    if (cropIds.isEmpty) return;
    try {
      final sets = await TextbookApi.instance.warmPageProblemViews(
        cropIds: cropIds,
        selectedCropId: _selectedCropId,
        enqueue: enqueue,
      );
      if (!mounted || sets.isEmpty) return;
      final selected = _selectedProblem();
      setState(() {
        _problemSetInfoByCrop.addAll(sets);
      });
      if (_paneMode == _PaneMode.question && !_isTimedTest && selected != null) {
        final group = _independentSetGroupFor(selected);
        if (group != null) {
          final nextKey = _problemSetCacheKey(group);
          if (_activeSetCacheKey != nextKey ||
              (_problemSetView == null && !_loadingProblemSetView)) {
            _startProblemSetViewLoad(group);
          }
        }
      }
    } catch (_) {
      // 페이지 예열은 best-effort.
    }
  }

  /// 페이지를 열 때 문항 렌더를 미리 준비한다.
  ///
  /// 정답 카드 모드에서도 돌린다 — 문항 보기로 전환하는 순간에야 준비를
  /// 시작하면 매번 로딩을 보게 되기 때문이다. 순서는 현재 페이지를 먼저 끝내고
  /// 다음 페이지로 넘어간다 (지금 볼 문항이 다음 페이지 예열에 밀리지 않도록).
  Future<void> _primePageRenders(List<PageProblem> problems, int epoch) async {
    await _warmCurrentPageProblemViews(problems);
    if (!mounted || epoch != _pageEpoch) return;
    await _primeSelectedWindow(epoch);
    if (!mounted || epoch != _pageEpoch) return;
    await _warmNextPageProblemViews(epoch);
  }

  /// 선택 문항과 그 앞뒤 이웃을 실제로 내려받아 캐시에 올린다.
  Future<void> _primeSelectedWindow(int epoch) async {
    final cropId = _selectedCropId;
    if (cropId == null || cropId.isEmpty) return;
    final neighbors = _neighborCropIds(cropId);
    final withNeighbors = _neighborQueueRequestedCropIds.add(cropId);
    await _prefetchProblemViewUntilReady(
      cropId,
      neighborCropIds: withNeighbors ? neighbors : const <String>[],
      epoch: epoch,
    );
    for (final neighborId in neighbors) {
      if (!mounted || epoch != _pageEpoch) return;
      if (!_prefetchedCropIds.add(neighborId)) continue;
      await _prefetchProblemViewUntilReady(neighborId, epoch: epoch);
    }
  }

  /// 렌더가 아직 큐에 있으면 잠시 뒤 다시 확인한다.
  ///
  /// 큐 응답은 캐시에 남지 않으므로, 한 번만 찔러보고 끝내면 콜드 페이지에서는
  /// 예열이 아무 효과가 없다. 사용자가 그 문항에 도달하기 전에 완료본을 받아
  /// 두는 것이 목적이라 재시도 간격을 넉넉히 둔다.
  Future<void> _prefetchProblemViewUntilReady(
    String cropId, {
    List<String> neighborCropIds = const <String>[],
    required int epoch,
  }) async {
    const retryDelays = <Duration>[
      Duration(milliseconds: 1500),
      Duration(seconds: 4),
      Duration(seconds: 8),
    ];
    for (var attempt = 0; attempt <= retryDelays.length; attempt += 1) {
      if (!mounted || epoch != _pageEpoch) return;
      final StudentTextbookProblemView view;
      try {
        view = await _fetchProblemView(
          cropId,
          neighborCropIds: attempt == 0 ? neighborCropIds : const <String>[],
        );
      } catch (_) {
        return; // 예열 실패는 조용히 넘어간다. 실제 조회 때 다시 시도된다.
      }
      if (!view.isQueued) return;
      if (attempt == retryDelays.length) return;
      await Future<void>.delayed(retryDelays[attempt]);
    }
  }

  /// 다음 페이지 문항을 렌더 큐에 미리 넣는다 (내려받기까지는 하지 않는다).
  Future<void> _warmNextPageProblemViews(int epoch) async {
    final current = _page;
    if (current == null) return;
    final key = '${current.rawPage}|${current.subKey}|${current.midOrder}';
    if (!_nextPageWarmedKeys.add(key)) return;

    final pages = _flattenedPages();
    final index = pages.indexWhere(
      (entry) =>
          entry.page.rawPage == current.rawPage &&
          entry.page.subKey == current.subKey &&
          entry.page.midOrder == current.midOrder,
    );
    if (index < 0 || index + 1 >= pages.length) return;
    final next = pages[index + 1].page;

    try {
      final problems = await TextbookApi.instance.pageProblems(
        bookId: widget.book.bookId,
        gradeLabel: widget.book.gradeLabel,
        rawPage: next.rawPage,
      );
      if (!mounted || epoch != _pageEpoch) return;
      final cropIds = <String>[for (final problem in problems) problem.cropId];
      if (cropIds.isEmpty) return;
      await TextbookApi.instance.warmPageProblemViews(cropIds: cropIds);
    } catch (_) {
      // 다음 페이지 예열도 best-effort.
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
        _expandTreeThroughBigs();
      });
      if (selectLastPage) {
        if (widget.homework != null) {
          // 과제 스코프: 배정된 첫 페이지부터. 이어풀기는 적용하지 않는다.
          _selectFirstPage();
        } else {
          // 첫 진입: 이어서 풀던 페이지 → 없거나 못 찾으면 첫 페이지.
          final resumed = widget.book.lastRawPage != null &&
              _selectPageByRawPage(widget.book.lastRawPage!);
          if (!resumed) _selectFirstPage();
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _treeError = '단원 정보를 불러오지 못했어요.\n$e');
    }
  }

  int get _timedRemainingSeconds {
    final session = _timedSession;
    if (session == null) {
      return (widget.timedTest?.group.timeLimitMinutes ?? 0) * 60;
    }
    final serverNow = DateTime.now().add(_timedServerClockOffset);
    final milliseconds =
        session.deadlineAt.difference(serverNow).inMilliseconds;
    return milliseconds <= 0 ? 0 : (milliseconds / 1000).ceil();
  }

  String get _timedClockLabel {
    final seconds = _timedRemainingSeconds;
    final minutes = seconds ~/ 60;
    return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  void _syncTimedServerClock(DateTime deadline, int remainingSeconds) {
    final estimatedServerNow =
        deadline.subtract(Duration(seconds: remainingSeconds));
    _timedServerClockOffset = estimatedServerNow.difference(DateTime.now());
  }

  ({TbPageStat page, String pathLabel})? _timedPageEntry(int rawPage) {
    for (final entry in _flattenedPages()) {
      if (entry.page.rawPage == rawPage) return entry;
    }
    return null;
  }

  Future<({
    StudentTextbookProblemView? single,
    StudentTextbookProblemSetView? setView,
    String? setKey,
  })> _loadTimedReadyView(
    String cropId,
  ) async {
    var view = await TextbookApi.instance.problemView(cropId: cropId);
    if (view.setInfo != null && view.setInfo!.isIndependentSet) {
      final setInfo = view.setInfo!;
      _problemSetInfoByCrop[cropId] = setInfo;
      var setView = await TextbookApi.instance.problemSetView(
        cropIds: <String>[cropId],
        commonCropId: cropId,
      );
      for (var attempt = 0; !setView.isReady && attempt < 16; attempt++) {
        await Future<void>.delayed(
          Duration(
            milliseconds: setView.pollAfterMs?.clamp(400, 2500) ?? 900,
          ),
        );
        setView = await TextbookApi.instance.problemSetView(
          cropIds: <String>[cropId],
          commonCropId: cropId,
        );
      }
      if (!setView.isReady && setView.bodyPdfUrl == null) {
        throw StateError('timed_test_problem_not_ready');
      }
      if (setView.commonPdfUrl != null) {
        await _QuestionPdfCache.prefetch(setView.commonPdfUrl);
      }
      for (final item in setView.items) {
        if (item.pdfUrl != null) {
          await _QuestionPdfCache.prefetch(item.pdfUrl);
        }
      }
      if (!setView.isReady && setView.bodyPdfUrl != null) {
        await _QuestionPdfCache.prefetch(setView.bodyPdfUrl);
      }
      return (single: null, setView: setView, setKey: setInfo.setKey);
    }

    for (var attempt = 0; view.isQueued && attempt < 8; attempt++) {
      await Future<void>.delayed(
        Duration(milliseconds: view.pollAfterMs?.clamp(400, 2500) ?? 900),
      );
      view = await TextbookApi.instance.problemView(cropId: cropId);
    }
    if (view.isQueued && view.bodyPdfUrl != null) {
      view = _fallbackFromQueued(view);
    }
    if (view.isQueued) {
      throw StateError('timed_test_problem_not_ready');
    }
    if (view.isReady) {
      await _QuestionPdfCache.prefetch(view.pdfUrl);
    } else if (view.isFallback && view.bodyPdfUrl != null) {
      await _QuestionPdfCache.prefetch(view.bodyPdfUrl);
    }
    return (single: view, setView: null, setKey: null);
  }

  Future<void> _loadTimedProblemAt(int index) async {
    final timed = widget.timedTest!;
    if (index < 0 || index >= timed.problems.length) {
      await _finishTimedTest();
      return;
    }
    _timedActiveWatch.stop();
    _timedWallWatch.stop();
    _timedIndex = index;
    final target = timed.problems[index];
    final rawPage = target.rawPage;
    if (rawPage == null) {
      throw StateError('timed_test_problem_page_missing');
    }
    final entry = _timedPageEntry(rawPage);
    if (entry == null) {
      throw StateError('timed_test_problem_page_not_found');
    }
    final ready = await _loadTimedReadyView(target.cropId);
    String? setCacheKey;
    if (ready.single != null) {
      _problemViewCache[target.cropId] = ready.single!;
    } else if (ready.setView != null) {
      setCacheKey = '${ready.setKey ?? target.cropId}|${target.cropId}';
      _problemSetViewCache[setCacheKey] = ready.setView!;
    }
    _answers.clear();
    _objectivePencilMarks.clear();
    _answerDisplayLatex.clear();
    _gradedAnswers.clear();
    _results.clear();
    _flags.clear();
    _seenProblems.clear();
    await _openPage(
      entry.page,
      entry.pathLabel,
      select: _PageEntrySelect.first,
    );
    if (!mounted) return;
    setState(() {
      _paneMode = _PaneMode.question;
      _problemView = ready.single;
      _problemSetView = ready.setView;
      _activeSetCacheKey = setCacheKey;
      _problemViewError = null;
      _problemSetViewError = null;
      _loadingProblemView = false;
      _loadingProblemSetView = false;
    });
  }

  Future<void> _exposeTimedCurrentProblem() async {
    final session = _timedSession;
    final timed = widget.timedTest;
    if (session == null ||
        timed == null ||
        _timedIndex >= timed.problems.length) {
      return;
    }
    final exposure = await StudentApi.instance.exposeTimedTestProblem(
      sessionId: session.sessionId,
      problem: timed.problems[_timedIndex],
      position: _timedIndex + 1,
    );
    if (exposure.expired || exposure.remainingSeconds <= 0) {
      await _finishTimedTest();
      return;
    }
    _syncTimedServerClock(exposure.deadlineAt, exposure.remainingSeconds);
    _timedExposure = exposure;
    _timedActiveWatch
      ..reset()
      ..start();
    _timedWallWatch
      ..reset()
      ..start();
  }

  Future<void> _prepareTimedTest() async {
    if (_timedPreparing) return;
    setState(() => _timedPreparing = true);
    try {
      // 첫 문항의 메타데이터·렌더 PDF를 모두 준비한 다음 서버 세션을 시작한다.
      // 따라서 최초 로딩 시간은 제한시간에서 차감되지 않는다.
      await _loadTree();
      if (!mounted) return;
      await _loadTimedProblemAt(0);
      if (!mounted) return;

      final session = await StudentApi.instance.startOrResumeTimedTest(
        widget.timedTest!.group.groupId,
      );
      _timedSession = session;
      _syncTimedServerClock(session.deadlineAt, session.remainingSeconds);
      if (!session.isOpen || session.remainingSeconds <= 0) {
        await _finishTimedTest();
        return;
      }

      _timedTimer?.cancel();
      _timedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _timedFinishing) return;
        if (_timedRemainingSeconds <= 0) {
          unawaited(_finishTimedTest());
        } else {
          setState(() {});
        }
      });

      final position = await TextbookApi.instance.timedTestNextPosition(
        session.sessionId,
      );
      final nextIndex =
          (position - 1).clamp(0, widget.timedTest!.problems.length);
      if (nextIndex >= widget.timedTest!.problems.length) {
        await _finishTimedTest();
        return;
      }
      if (nextIndex != _timedIndex) {
        await _loadTimedProblemAt(nextIndex);
      }
      await _exposeTimedCurrentProblem();
      if (mounted) setState(() => _timedPreparing = false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _timedPreparing = false);
      TopGlassSnackBar.show(
        context,
        message: '시간제한 테스트를 준비하지 못했어요. 다시 시도해 주세요.',
        icon: Icons.error_outline_rounded,
      );
    }
  }

  TimedTestGradeContext? _timedGradeContext() {
    final exposure = _timedExposure;
    final session = _timedSession;
    if (exposure == null || session == null) return null;
    final wall = _timedWallWatch.elapsedMilliseconds;
    final active = _timedActiveWatch.elapsedMilliseconds;
    return TimedTestGradeContext(
      sessionId: session.sessionId,
      exposureId: exposure.exposureId,
      durationMs: active,
      position: exposure.position,
      wallDurationMs: wall,
      interruptionMs: (wall - active).clamp(0, wall),
    );
  }

  void _selectFirstPage() {
    final pages = _flattenedPages();
    if (pages.isEmpty) return;
    var first = pages.first;
    final scope = widget.homework;
    if (scope != null && scope.rawPages.isNotEmpty) {
      final firstRaw = scope.rawPages.first;
      for (final candidate in pages) {
        if (candidate.page.rawPage == firstRaw) {
          first = candidate;
          break;
        }
      }
    }
    _expandTreeForPage(first.page);
    unawaited(_openPage(first.page, first.pathLabel));
  }

  /// 해당 rawPage 를 열어 성공하면 true.
  bool _selectPageByRawPage(int rawPage) {
    final tree = _tree;
    if (tree == null) return false;
    for (final big in tree.bigUnits) {
      for (final mid in big.mids) {
        for (final small in mid.smalls) {
          for (final page in small.pages) {
            if (page.rawPage == rawPage) {
              _expanded
                ..add('b${big.order}')
                ..add('b${big.order}|m${mid.order}')
                ..add('b${big.order}|m${mid.order}|s${small.subKey}');
              unawaited(_openPage(
                page,
                '${mid.name} · ${small.name.isEmpty ? small.subKey : small.name}',
              ));
              return true;
            }
          }
        }
      }
    }
    return false;
  }

  /// 트리 순서를 따른 전체 페이지 목록 (이전/다음 페이지 이동용).
  /// 과제 스코프면 배정 문항이 있는 페이지만 남긴다 (단 원본보기에서는 그 소단원의 개념 페이지도 포함).
  List<({TbPageStat page, String pathLabel})> _flattenedPages({
    bool includeConcept = false,
  }) {
    final tree = _tree;
    if (tree == null) return const [];
    final scope = widget.homework;
    final out = <({TbPageStat page, String pathLabel})>[];
    for (final big in tree.bigUnits) {
      for (final mid in big.mids) {
        for (final small in mid.smalls) {
          final smallHasScopedProblem = scope == null ||
              small.pages.any(
                (p) => !p.isConceptPage && scope.rawPages.contains(p.rawPage),
              );
          if (!smallHasScopedProblem) continue;
          final pathLabel =
              '${mid.name} · ${small.name.isEmpty ? small.subKey : small.name}';
          for (final page in small.pages) {
            if (page.isConceptPage) {
              if (!includeConcept) continue;
            } else if (scope != null && !scope.rawPages.contains(page.rawPage)) {
              continue;
            }
            out.add((page: page, pathLabel: pathLabel));
          }
        }
      }
    }
    return out;
  }

  /// 과제 스코프면 배정된 문항만 남긴다.
  List<PageProblem> _scopedProblems(List<PageProblem> problems) {
    if (_isTimedTest) {
      final timed = widget.timedTest!;
      if (_timedIndex < 0 || _timedIndex >= timed.problems.length) {
        return const <PageProblem>[];
      }
      final cropId = timed.problems[_timedIndex].cropId;
      return problems
          .where((problem) => problem.cropId == cropId)
          .toList(growable: false);
    }
    final scope = widget.homework;
    if (scope == null) return problems;
    final filtered = problems
        .where((p) => scope.cropIds.contains(p.cropId))
        .toList(growable: true);
    if (_homeworkOrderByCrop.isNotEmpty) {
      filtered.sort(
        (a, b) => (_homeworkOrderByCrop[a.cropId] ?? 1 << 20)
            .compareTo(_homeworkOrderByCrop[b.cropId] ?? 1 << 20),
      );
    }
    return filtered;
  }

  /// 과제 모드에서는 답 캐시 대신 "이 배정에서 남긴 시도"를 상태로 쓴다.
  ///
  /// 답 캐시(student_textbook_answer_records)는 회차를 모르는 학생×문항 한
  /// 줄이라, 이전 회차(예전 과제·자유 풀이)에서 맞힌 문항이 새 과제에서도
  /// 이미 맞은 것처럼 보인다. 이 배정에서 안 풀었으면 비어 있어야 한다.
  Future<List<PageProblem>> _withHomeworkRoundState(
    List<PageProblem> problems,
  ) async {
    if (_isTimedTest) {
      return [
        for (final problem in problems) problem.withSolveState(),
      ];
    }
    final scope = widget.homework;
    if (scope == null || problems.isEmpty) return problems;

    Map<String, HomeworkProblem> byCrop;
    final cached = _homeworkRoundByCrop;
    if (cached != null) {
      byCrop = cached;
    } else {
      try {
        final rows =
            await StudentApi.instance.listHomeworkProblems(scope.groupId);
        byCrop = {
          for (final row in rows)
            if (row.cropId.isNotEmpty) row.cropId: row,
        };
        _homeworkRoundByCrop = byCrop;
      } catch (_) {
        // 조회 실패 시 캐시 상태로라도 보여준다. 이전 회차가 비칠 수 있지만
        // 화면이 막히는 것보다 낫다.
        return problems;
      }
    }

    return [
      for (final p in problems)
        () {
          final hp = byCrop[p.cropId];
          final attempts = hp?.attemptCount ?? 0;
          if (hp == null || attempts <= 0) {
            // 이 배정에서 아직 안 푼 문항 — 빈 상태로 시작한다.
            return p.withSolveState();
          }
          // skipped 만 있으면 빈 문항. 그 전에 스스로/자동 채점한
          // 정오가 있으면 그걸 보여 준다 (이탈 플러시가 skipped 를
          // 덧씌워도 정오가 사라지지 않게).
          final lastGraded = hp.lastGradedResult ??
              (hp.lastResult == 'skipped' ? null : hp.lastResult);
          final gradedAttempts =
              hp.gradedAttemptCount ?? (lastGraded == null ? 0 : attempts);
          if (lastGraded == null && hp.passed) {
            // last_graded 컬럼이 아직 없는 서버에서도, 한 번이라도
            // 맞힌 문항은 정답으로 복원한다.
            return p.withSolveState(
              myCorrect: true,
              attemptCount: attempts,
              gradedBy: hp.lastScoredBy ?? (p.isSelfCheck ? 'self' : null),
              partResults: p.partResults,
            );
          }
          if (gradedAttempts <= 0 || lastGraded == null) {
            return p.withSolveState();
          }
          final answer = (hp.lastGradedAnswer ?? hp.lastAnswer ?? '').trim();
          final bool? myCorrect = lastGraded == 'correct'
              ? true
              : lastGraded == 'wrong' || lastGraded == 'partial'
                  ? false
                  : hp.passed
                      ? true
                      : null;
          final gradedBy = hp.lastGradedScoredBy ??
              hp.lastScoredBy ??
              (p.isSelfCheck ? 'self' : null);
          return p.withSolveState(
            myAnswer: answer.isEmpty ? null : answer,
            myCorrect: myCorrect,
            attemptCount: attempts,
            gradedBy: gradedBy,
            // 파트별 기록은 캐시에만 있다. 이 배정에서 시도한 문항이면
            // 최신 캐시가 곧 이 회차의 기록이다.
            partResults: p.partResults,
          );
        }(),
    ];
  }

  void _expandTreeForPage(TbPageStat page) {
    final tree = _tree;
    if (tree == null) return;
    for (final big in tree.bigUnits) {
      for (final mid in big.mids) {
        for (final small in mid.smalls) {
          if (small.pages.any((p) => p.rawPage == page.rawPage)) {
            _expanded
              ..add('b${big.order}')
              ..add('b${big.order}|m${mid.order}')
              ..add('b${big.order}|m${mid.order}|s${small.subKey}');
            return;
          }
        }
      }
    }
  }

  /// 대단원까지만 펼침 (중단원·소단원·페이지는 접힌 채 — 현재 페이지만 `_expandTreeForPage`로 연다).
  void _expandTreeThroughBigs() {
    final tree = _tree;
    if (tree == null) return;
    for (final big in tree.bigUnits) {
      _expanded.add('b${big.order}');
    }
  }

  void _setTreeOpen(bool open) {
    setState(() {
      _treeOpen = open;
      if (open) {
        _expandTreeThroughBigs();
        final page = _page;
        if (page != null) _expandTreeForPage(page);
      }
    });
  }

  /// 교재 풀기 탭과 동일: AppBar 높이(+8 연장).
  double _solveTitleExtent(BuildContext context) =>
      StudentStatusIslandToolbarSlot.preferredHeight(context) + 8;

  /// 타이틀 아래로 카드·문항이 시작하는 위치.
  double _answerListTop(double titleExtent) => titleExtent + 12;

  /// 문항보기·원본보기는 같은 전체 화면 레이아웃이다. 차이는 구운 PDF와 원본 페이지만.
  bool get _solvePaneImmersive =>
      _paneMode == _PaneMode.question || _paneMode == _PaneMode.body;

  /// 상태 아일랜드 캡슐의 화면상 아랫변. 원본 PDF는 이 바로 아래에서 시작한다.
  double _islandBottom(BuildContext context) {
    final paddingTop = MediaQuery.paddingOf(context).top;
    return paddingTop +
        (kToolbarHeight - StudentStatusIsland.height) / 2 +
        StudentStatusIsland.centerOffsetY +
        StudentStatusIsland.height;
  }

  void _onAnswersScroll() {
    if (!mounted || _paneMode != _PaneMode.answers) return;
    _updateTitleFromScroll(_answersScrollController.offset);
  }

  void _onQuestionScroll() {
    if (!mounted || _paneMode != _PaneMode.question) return;
    _updateTitleFromScroll(_questionScrollController.offset);
  }

  void _onBodyScroll() {
    if (!mounted || _paneMode != _PaneMode.body) return;
    _updateTitleFromScroll(_bodyScrollController.offset);
  }

  void _updateTitleFromScroll(double pixels) {
    final delta = pixels - _titleScrollPixels;
    _titleScrollPixels = pixels;
    final nextOpacity =
        (1 - pixels / StudentCollapsingTitlePage.fadeDistance).clamp(0.0, 1.0);
    var showBook = _titleShowsBook;
    if (pixels <= 2) {
      _titleScrollAccum = 0;
      showBook = true;
    } else if (delta != 0) {
      if (_titleScrollAccum != 0 && delta.sign != _titleScrollAccum.sign) {
        _titleScrollAccum = 0;
      }
      _titleScrollAccum += delta;
      // 방향이 조금 쌓여야 바뀐다. 맨 위 바운스는 교재명으로 둔다.
      if (_titleScrollAccum >= 16) {
        showBook = false;
        _titleScrollAccum = 0;
      } else if (_titleScrollAccum <= -16) {
        showBook = true;
        _titleScrollAccum = 0;
      }
    }
    if ((nextOpacity - _titleOpacity).abs() > 0.01 ||
        showBook != _titleShowsBook) {
      setState(() {
        _titleOpacity = nextOpacity;
        _titleShowsBook = showBook;
      });
    }
  }

  void _resetTitleCollapse() {
    _titleOpacity = 1;
    _titleShowsBook = true;
    _titleScrollPixels = 0;
    _titleScrollAccum = 0;
    if (_answersScrollController.hasClients) {
      _answersScrollController.jumpTo(0);
    }
    if (_questionScrollController.hasClients) {
      _questionScrollController.jumpTo(0);
    }
    if (_bodyScrollController.hasClients) {
      _bodyScrollController.jumpTo(0);
    }
  }

  bool _localAnswerDirty(String key) {
    final value = _answers[key]?.trim() ?? '';
    return value.isNotEmpty && value != (_gradedAnswers[key]?.trim() ?? '');
  }

  /// 페이지 문항의 서버 기록(답·정오·시도)을 화면 상태에 반영한다.
  void _absorbProblemRecords(Iterable<PageProblem> problems) {
    for (final p in problems) {
      _seenProblems[p.cropId] = p;
      if (p.myAnswer != null && p.myAnswer!.isNotEmpty) {
        if (!_localAnswerDirty(p.cropId)) {
          _answers[p.cropId] = p.myAnswer!;
        }
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
      // 공책 풀이(셀프)는 답이 비어 있어도 정오를 보여야 한다.
      // graded_by 가 비어 있어도 이 배정에서 채점된 셀프 문항이면 복원한다.
      if (p.gradedBy == 'self' ||
          p.gradedBy == 'teacher' ||
          (p.isSelfCheck &&
              p.myCorrect != null &&
              (p.attemptCount ?? 0) > 0)) {
        _selfGraded.add(p.cropId);
      }
      if (p.reportStatus != null) {
        _reportStatuses[p.cropId] = p.reportStatus!;
      }
      for (final pr in p.partResults) {
        final k = _answerKeyOf(p.cropId, pr.key);
        final partAnswer = pr.answer?.trim() ?? '';
        if (partAnswer.isNotEmpty) {
          if (!_localAnswerDirty(k)) {
            _answers[k] = partAnswer;
          }
          _gradedAnswers[k] = partAnswer;
        }
        _results[k] = pr.correct;
        if (pr.flags.isNotEmpty) {
          _flags[k] = pr.flags;
        }
        if (pr.gradedBy == 'self') {
          _selfGraded.add(k);
        }
      }
    }
  }

  void _tagProblemPage(
    Iterable<PageProblem> problems,
    TbPageStat page,
    String pathLabel,
  ) {
    final meta = (page: page, pathLabel: pathLabel);
    for (final problem in problems) {
      _problemPageMeta[problem.cropId] = meta;
    }
  }

  void _selectEntry(List<PageProblem> problems, _PageEntrySelect select) {
    if (problems.isEmpty) return;
    switch (select) {
      case _PageEntrySelect.first:
        _selectPro(problems.first);
      case _PageEntrySelect.last:
        _selectPro(problems.last);
      case _PageEntrySelect.auto:
        for (final p in problems) {
          if (_isOnHold(p.cropId)) continue;
          final selectable = p.hasParts
              ? p.myCorrect != true
              : !p.isObjective && !p.isSelfCheck && p.myCorrect != true;
          if (selectable) {
            _selectPro(p);
            break;
          }
        }
        if (_selectedCropId == null ||
            !problems.any((p) => p.cropId == _selectedCropId)) {
          _selectPro(problems.first);
        }
    }
  }

  void _reanchorToSelection() {
    final problems = _problems;
    final selected = _selectedCropId;
    if (problems == null || selected == null) return;
    final index = problems.indexWhere((problem) => problem.cropId == selected);
    if (index >= 0) _anchorIndex = index;
  }

  void _jumpFeedToAnchor() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_answersScrollController.hasClients) return;
      if (_paneMode != _PaneMode.answers) return;
      _answersScrollController.jumpTo(0);
    });
  }

  /// 이미 받아 둔 페이지면 다시 받지 않고, 그 페이지의 선택 문항을 맨 위로 올린다.
  bool _revealLoadedPage(
    TbPageStat page,
    String pathLabel,
    _PageEntrySelect select,
  ) {
    if (_isTimedTest) return false;
    if (page.isConceptPage) {
      if (_paneMode != _PaneMode.body) return false;
      setState(() {
        _page = page;
        _pagePathLabel = pathLabel;
        _treeOpen = false;
        _selectedCropId = null;
        _selectedPartKey = null;
        _problems ??= const <PageProblem>[];
        _loadingProblems = false;
      });
      _startBodyViewForPage(page.rawPage);
      return true;
    }
    if (!_loadedCardRawPages.contains(page.rawPage)) {
      return false;
    }
    final problems = _problems;
    if (problems == null) return false;
    final onPage = <PageProblem>[
      for (final problem in problems)
        if (_problemPageMeta[problem.cropId]?.page.rawPage == page.rawPage)
          problem,
    ];
    if (onPage.isEmpty) return false;
    setState(() {
      _page = page;
      _pagePathLabel = pathLabel;
      _treeOpen = false;
      _selectEntry(onPage, select);
      _reanchorToSelection();
    });
    _jumpFeedToAnchor();
    return true;
  }

  Future<void> _openPage(
    TbPageStat page,
    String pathLabel, {
    _PageEntrySelect select = _PageEntrySelect.auto,
  }) async {
    _expandTreeForPage(page);
    if (_revealLoadedPage(page, pathLabel, select)) return;
    if (page.isConceptPage) {
      setState(() {
        _page = page;
        _pagePathLabel = pathLabel;
        _treeOpen = false;
        _selectedCropId = null;
        _selectedPartKey = null;
        _problems ??= const <PageProblem>[];
        _loadingProblems = false;
      });
      _startBodyViewForPage(page.rawPage);
      return;
    }
    final epoch = ++_pageEpoch;
    setState(() {
      _page = page;
      _pagePathLabel = pathLabel;
      _problems = null;
      _anchorIndex = 0;
      _loadedCardRawPages.clear();
      _cardPageLoads.clear();
      _problemPageMeta.clear();
      _homeworkRoundByCrop = null;
      _loadingProblems = true;
      // 답 상태(_answers 등)는 crop_id 키라 페이지가 바뀌어도 지우지 않는다.
      // 미채점 답을 들고 다니다가 일괄 채점 때 한 번에 모은다.
      _expandedSetCrops.clear();
      _selectedCropId = null;
      _selectedPartKey = null;
      _problemViewRequestEpoch++;
      _problemView = null;
      _problemViewError = null;
      _loadingProblemView = false;
      _problemSetView = null;
      _problemSetViewError = null;
      _loadingProblemSetView = false;
      _activeSetCacheKey = null;
      _setPencilKeys.clear();
      _treeOpen = false;
    });
    try {
      final loaded = await TextbookApi.instance.pageProblems(
        bookId: widget.book.bookId,
        gradeLabel: widget.book.gradeLabel,
        rawPage: page.rawPage,
      );
      if (!mounted || epoch != _pageEpoch) return;
      final problems = await _withHomeworkRoundState(_scopedProblems(loaded));
      if (!mounted || epoch != _pageEpoch) return;
      setState(() {
        _problems = List<PageProblem>.of(problems);
        _loadingProblems = false;
        _absorbProblemRecords(problems);
        _tagProblemPage(problems, page, pathLabel);
        _loadedCardRawPages.add(page.rawPage);
        if (problems.isEmpty) return;
        _selectEntry(problems, select);
        _reanchorToSelection();
      });
      if (!_isTimedTest) {
        unawaited(_feedRemainingCardPages(epoch));
      }
      // 정답 카드 모드로 머물러 있어도 렌더를 미리 준비해 둔다. 현재 페이지를
      // 끝낸 뒤 다음 페이지까지 예열해 로딩을 볼 일을 없앤다.
      unawaited(_primePageRenders(problems, epoch));
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

  /// 지금까지 본 모든 문항에서 새로 입력했거나 값이 바뀐 답을 모은다.
  /// 페이지를 넘어가도 답을 들고 다니므로 여러 페이지 분량이 한 번에 나온다.
  ({
    Map<String, String> answers,
    Map<String, Map<String, String>> parts,
    List<String> incomplete,
  }) _collectPendingSubmissions() {
    final toSubmit = <String, String>{};
    final partSubmit = <String, Map<String, String>>{};
    final incomplete = <String>[];
    for (final p in _seenProblems.values) {
      if (_isOnHold(p.cropId)) continue; // 보류 문항은 채점 제외
      if (p.hasParts) {
        // 세트형: auto 파트별로 새 답만 제출
        for (final part in p.setParts) {
          if (part.isSelfCheck) continue;
          final k = _answerKeyOf(p.cropId, part.key);
          final answer = _answers[k]?.trim() ?? '';
          if (answer.isEmpty) continue;
          if (answer.contains('()')) {
            incomplete.add('${_displayProblemNumber(p)}${part.key}');
            continue;
          }
          if (_gradedAnswers[k] == answer && _results.containsKey(k)) {
            continue;
          }
          (partSubmit[p.cropId] ??= <String, String>{})[part.key] = answer;
        }
        continue;
      }
      if (p.isSelfCheck) continue;
      final answer = _answers[p.cropId]?.trim() ?? '';
      if (answer.isEmpty) continue;
      if (answer.contains('()')) {
        incomplete.add(_displayProblemNumber(p));
        continue; // 수식 에디터 빈칸이 남은 답은 제출하지 않음
      }
      if (_gradedAnswers[p.cropId] == answer &&
          _results.containsKey(p.cropId)) {
        continue;
      }
      toSubmit[p.cropId] = answer;
    }
    return (answers: toSubmit, parts: partSubmit, incomplete: incomplete);
  }

  Future<void> _submitTimedAnswer({required bool skipped}) async {
    if (_grading || _timedFinishing || _timedPreparing) return;
    final timing = _timedGradeContext();
    final timed = widget.timedTest;
    if (timing == null ||
        timed == null ||
        _timedIndex >= timed.problems.length) {
      return;
    }
    await _flushPencilInput();
    if (!mounted) return;
    final answerKey = _activeAnswerKey;
    final answer = answerKey == null ? '' : (_answers[answerKey] ?? '').trim();
    if (!skipped && answer.isEmpty) {
      TopGlassSnackBar.show(
        context,
        message: '답을 입력해 주세요.',
        icon: Icons.edit_outlined,
      );
      return;
    }
    if (_timedRemainingSeconds <= 0) {
      await _finishTimedTest();
      return;
    }

    setState(() => _grading = true);
    _timedActiveWatch.stop();
    _timedWallWatch.stop();
    try {
      final target = timed.problems[_timedIndex];
      if (skipped) {
        await TextbookApi.instance.passTimedTest(timedTest: timing);
      } else {
        await TextbookApi.instance.gradeTimedTest(
          bookId: target.bookId,
          gradeLabel: target.gradeLabel,
          cropId: target.cropId,
          answer: answer,
          timedTest: timing,
        );
      }
      _timedExposure = null;
      final nextIndex = _timedIndex + 1;
      if (nextIndex >= timed.problems.length) {
        await _finishTimedTest();
        return;
      }
      if (mounted) setState(() => _timedPreparing = true);
      await _loadTimedProblemAt(nextIndex);
      await _exposeTimedCurrentProblem();
      if (mounted) {
        setState(() {
          _timedPreparing = false;
          _grading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _grading = false);
      _timedActiveWatch.start();
      TopGlassSnackBar.show(
        context,
        message: '답을 제출하지 못했어요. 다시 시도해 주세요.',
        icon: Icons.wifi_off_rounded,
      );
    }
  }

  Future<void> _finishTimedTest({String status = 'completed'}) async {
    if (_timedFinishing) return;
    final session = _timedSession;
    if (session == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    _timedFinishing = true;
    _timedTimer?.cancel();
    _timedActiveWatch.stop();
    _timedWallWatch.stop();
    try {
      final result = await StudentApi.instance.finishTimedTest(
        session.sessionId,
        status: status,
      );
      await HomeworkSession.instance.refresh();
      if (!mounted) return;
      final accuracy = result.accuracy;
      TopGlassSnackBar.show(
        context,
        message: '테스트 종료 · 정답 ${result.correct} · 오답 ${result.wrong} · '
            '넘김 ${result.pass}'
            '${accuracy == null ? '' : ' · 정답률 ${(accuracy * 100).round()}%'}',
        icon: Icons.fact_check_rounded,
      );
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      _timedFinishing = false;
      setState(() {});
      TopGlassSnackBar.show(
        context,
        message: '테스트를 종료하지 못했어요. 다시 시도해 주세요.',
        icon: Icons.wifi_off_rounded,
      );
    }
  }

  Future<void> _grade() async {
    if (_isTimedTest) {
      await _submitTimedAnswer(skipped: false);
      return;
    }
    if (_grading) return;
    // 방금 쓴 필기가 아직 인식 전일 수 있다. 답을 모으기 전에 마무리한다.
    await _flushPencilInput();
    if (!mounted) return;
    if (_problems == null) return;

    final pending = _collectPendingSubmissions();
    final toSubmit = pending.answers;
    final partSubmit = pending.parts;
    final incomplete = pending.incomplete;
    if (incomplete.isNotEmpty) {
      TopGlassSnackBar.show(
        context,
        message: '${incomplete.join(', ')}번 답에 빈칸이 남아 있어요.',
        icon: Icons.crop_free_rounded,
      );
      if (toSubmit.isEmpty && partSubmit.isEmpty) return;
    }
    if (toSubmit.isEmpty && partSubmit.isEmpty) {
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
        partAnswersByCropId: partSubmit,
        homeworkGroupId: widget.homework?.groupId,
      );
      if (!mounted) return;
      _gradedThisVisit = true;
      setState(() {
        _results.addAll(result.correctByCropId);
        _flags.addAll(result.flagsByCropId);
        _gradedAnswers.addAll(toSubmit);
        for (final entry in partSubmit.entries) {
          for (final part in entry.value.entries) {
            _gradedAnswers[_answerKeyOf(entry.key, part.key)] = part.value;
          }
        }
        // 서버가 누적 계산한 파트별 결과 반영
        result.partResultsByCropId.forEach((cropId, parts) {
          for (final pr in parts) {
            final k = _answerKeyOf(cropId, pr.key);
            _results[k] = pr.correct;
            if (pr.flags.isNotEmpty) {
              _flags[k] = pr.flags;
            } else {
              _flags.remove(k);
            }
            if (pr.gradedBy == 'self') _selfGraded.add(k);
          }
        });
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
      HomeworkSession.instance.notifyPlanProgress();
      _noteFreePracticeGrant(result.pointsGranted);
      await _maybeCompleteHomework();
    } catch (e) {
      if (mounted && !_notifyIfBookSubmitted(e)) {
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

  /// 뒤로 나가기 전 잔여 처리.
  ///
  /// 1) 아직 채점 안 한 답이 남아 있으면 조용히 일괄 채점해 유실을 막는다.
  /// 2) 과제 모드에서 이번 방문에 채점이 한 번이라도 있었다면, 이 배정에서
  ///    한 번도 안 푼 문항을 미수행(skipped)으로 기록한다 — 학생이 스스로
  ///    검사를 받고 나간 것과 같은 셈이다. 학습앱 회차 이력에도 남는다.
  Future<void> _handleExit() async {
    if (_isTimedTest) {
      if (_timedFinishing) return;
      final end = await showStudentConfirmSheet(
        context: context,
        title: '테스트를 종료할까요?',
        message: '종료하면 다시 응시할 수 없어요. 지금까지 제출한 답으로 결과가 확정됩니다.',
        confirmLabel: '테스트 종료',
        cancelLabel: '계속 풀기',
        confirmIcon: Icons.stop_circle_outlined,
        cancelIcon: Icons.play_arrow_rounded,
      );
      if (end) await _finishTimedTest(status: 'abandoned');
      return;
    }
    if (_exitFlushing) return;
    setState(() => _exitFlushing = true);
    try {
      await _flushPencilInput();
      final pending = _collectPendingSubmissions();
      if (pending.answers.isNotEmpty || pending.parts.isNotEmpty) {
        try {
          await TextbookApi.instance.gradePage(
            bookId: widget.book.bookId,
            gradeLabel: widget.book.gradeLabel,
            answersByCropId: pending.answers,
            partAnswersByCropId: pending.parts,
            homeworkGroupId: widget.homework?.groupId,
          );
          _gradedThisVisit = true;
          _loadTree();
        } catch (_) {
          // 나가는 길의 채점 실패가 이탈을 막지는 않는다.
        }
      }
      final scope = widget.homework;
      if (scope != null && _gradedThisVisit) {
        try {
          final rows =
              await StudentApi.instance.listHomeworkProblems(scope.groupId);
          for (final row in rows) {
            if (row.cropId.isEmpty || row.attemptCount > 0) continue;
            // 방금 스스로 채점한 문항은 서버 집계가 늦어도 미수행으로
            // 덮지 않는다. 덮이면 재진입 때 정오가 사라지고 다시
            // 정답 확인을 요구한다.
            if (_selfGraded.contains(row.cropId) ||
                _results.containsKey(row.cropId) ||
                (_attemptCounts[row.cropId] ?? 0) > 0) {
              continue;
            }
            await StudentApi.instance.logHomeworkSkipped(
              groupId: scope.groupId,
              cropId: row.cropId,
            );
          }
        } catch (_) {
          // 미수행 기록 실패도 이탈을 막지 않는다.
        }
        try {
          await StudentApi.instance.recordHomeworkSelfInspection(scope.groupId);
        } catch (_) {
          // 시도 +1 실패가 이탈을 막지는 않는다.
        }
        HomeworkSession.instance.notifyPlanProgress();
      }
    } finally {
      if (mounted) setState(() => _exitFlushing = false);
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// 교재 탭 자유 풀이로 과제가 자동 통과된 경우 포인트 스낵바.
  void _noteFreePracticeGrant(int points) {
    if (points <= 0 || widget.homework != null) return;
    StudentPointSession.instance.noteHomeworkGrant(points);
  }

  /// 실물 교재 제출(검사 대기) 중 잠금 에러면 안내하고 true.
  bool _notifyIfBookSubmitted(Object error) {
    if (error is! TextbookGradeException || !error.bookSubmitted) return false;
    TopGlassSnackBar.show(
      context,
      message: '교재를 제출해서 검사를 기다리고 있어요. 검사가 끝나면 다시 풀 수 있어요.',
      icon: Icons.lock_clock_rounded,
    );
    return true;
  }

  // ----------------------------------------------------------- 과제 통과 판정

  /// 과제 스코프에서 배정 문항을 전부 맞혔으면 서버에 통과를 요청한다.
  /// 조건 판정은 전적으로 서버가 한다 (클라이언트는 신뢰하지 않는다).
  Future<void> _maybeCompleteHomework() async {
    final scope = widget.homework;
    if (scope == null) return;
    try {
      final result =
          await StudentApi.instance.completeHomeworkIfMastered(scope.groupId);
      if (!mounted) return;
      HomeworkSession.instance.notifyPlanProgress();
      if (result['ok'] != true) {
        final remaining = (result['remaining'] as num?)?.toInt() ?? 0;
        if (remaining > 0) {
          TopGlassSnackBar.show(
            context,
            message: '$remaining문제 남았어요.',
            icon: Icons.flag_outlined,
          );
        }
        return;
      }
      unawaited(HomeworkSession.instance.refresh());
      final points = (result['points_granted'] as num?)?.toInt() ?? 0;
      if (points > 0) {
        StudentPointSession.instance.noteHomeworkGrant(points);
      } else {
        TopGlassSnackBar.show(
          context,
          message: '과제를 모두 맞혔어요! 통과 처리했어요.',
          icon: Icons.verified_rounded,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      // 통과 판정 실패가 채점 결과를 되돌리지는 않는다. 다음 채점 때 재시도된다.
    }
  }

  // ------------------------------------------------------------- 셀프 채점

  /// 정답 공개 → 학생이 스스로 O/X → 서버 기록.
  Future<void> _selfCheck(PageProblem problem) async {
    if (_isOnHold(problem.cropId)) return;
    RevealedAnswer revealed;
    try {
      revealed =
          await TextbookApi.instance.revealAnswer(cropId: problem.cropId);
    } catch (e) {
      if (mounted && !_notifyIfBookSubmitted(e)) {
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
        title: '${_displayProblemNumber(problem)}번 정답',
        revealed: revealed,
        myAnswer: _answers[problem.cropId],
      ),
    );
    if (marked == null || !mounted) return;

    var saveStage = 'self_mark';
    try {
      final res = await TextbookApi.instance.selfMark(
        bookId: widget.book.bookId,
        gradeLabel: widget.book.gradeLabel,
        cropId: problem.cropId,
        correct: marked,
        answer: _answers[problem.cropId],
        homeworkGroupId: widget.homework?.groupId,
      );
      if (!mounted) return;
      _gradedThisVisit = true;
      setState(() {
        _results[problem.cropId] = marked;
        _gradedAnswers[problem.cropId] = _answers[problem.cropId] ?? '';
        _selfGraded.add(problem.cropId);
        _attemptCounts[problem.cropId] =
            (_attemptCounts[problem.cropId] ?? 0) + 1;
      });
      _loadTree();
      HomeworkSession.instance.notifyPlanProgress();
      _noteFreePracticeGrant(res.pointsGranted);
      if (res.homeworkLinked != true) {
        saveStage = 'homework_link';
        await _ensureHomeworkSelfMarkLinked(
          cropId: problem.cropId,
          correct: marked,
          answer: _answers[problem.cropId],
          expectedAttemptCount: _attemptCounts[problem.cropId] ?? 1,
          verifyFirst: res.homeworkLinked == null,
        );
      }
      saveStage = 'complete_check';
      await _maybeCompleteHomework();
    } catch (e, stackTrace) {
      debugPrint('[HW_SELF_MARK][$saveStage] $e');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted && !_notifyIfBookSubmitted(e)) {
        TopGlassSnackBar.show(
          context,
          message: '기록에 실패했어요. 다시 시도해 주세요.',
          icon: Icons.wifi_off_rounded,
        );
      }
    }
  }

  /// 답지에 저장된 정답 확인 (보기 전용) — "답지와 표기는 조금 달라요"
  /// 안내를 눌렀을 때. 이미 정답 처리된 문항이라 서버가 공개를 허용한다.
  Future<void> _showServedAnswer(PageProblem problem) async {
    RevealedAnswer revealed;
    try {
      revealed =
          await TextbookApi.instance.revealAnswer(cropId: problem.cropId);
    } catch (_) {
      if (mounted) {
        TopGlassSnackBar.show(
          context,
          message: '답지 정답을 불러오지 못했어요.',
          icon: Icons.error_outline_rounded,
        );
      }
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _SelfCheckDialog(
        title: '${_displayProblemNumber(problem)}번 답지 정답',
        revealed: revealed,
        myAnswer: _answers[problem.cropId],
        viewOnly: true,
      ),
    );
  }

  /// 세트형 파트 자기 채점 — 해당 파트 정답만 공개하고 O/X를 기록한다.
  Future<void> _selfCheckPart(PageProblem problem, String partKey) async {
    if (_isOnHold(problem.cropId)) return;
    RevealedAnswer revealed;
    try {
      revealed =
          await TextbookApi.instance.revealAnswer(cropId: problem.cropId);
    } catch (e) {
      if (mounted && !_notifyIfBookSubmitted(e)) {
        TopGlassSnackBar.show(
          context,
          message: '정답을 불러오지 못했어요.',
          icon: Icons.error_outline_rounded,
        );
      }
      return;
    }
    if (!mounted) return;

    RevealedAnswerPart? part;
    for (final p in revealed.parts) {
      if (p.key == partKey) {
        part = p;
        break;
      }
    }
    final partText = part?.text?.trim() ?? '';

    final answerKey = _answerKeyOf(problem.cropId, partKey);
    final marked = await showDialog<bool>(
      context: context,
      builder: (ctx) => _SelfCheckDialog(
        title: '${_displayProblemNumber(problem)}번 $partKey 정답',
        revealed: RevealedAnswer(
          answerKind: 'subjective',
          answerText: partText.isEmpty ? null : partText,
        ),
        myAnswer: _answers[answerKey],
      ),
    );
    if (marked == null || !mounted) return;

    var saveStage = 'self_mark_part';
    try {
      final res = await TextbookApi.instance.selfMark(
        bookId: widget.book.bookId,
        gradeLabel: widget.book.gradeLabel,
        cropId: problem.cropId,
        correct: marked,
        partMarks: {partKey: marked},
        homeworkGroupId: widget.homework?.groupId,
      );
      if (!mounted) return;
      _gradedThisVisit = true;
      setState(() {
        _results[answerKey] = marked;
        _selfGraded.add(answerKey);
        _results[problem.cropId] = res.correct;
        for (final pr in res.partResults) {
          final k = _answerKeyOf(problem.cropId, pr.key);
          _results[k] = pr.correct;
          if (pr.gradedBy == 'self') _selfGraded.add(k);
        }
        _attemptCounts[problem.cropId] =
            (_attemptCounts[problem.cropId] ?? 0) + 1;
      });
      _loadTree();
      HomeworkSession.instance.notifyPlanProgress();
      _noteFreePracticeGrant(res.pointsGranted);
      if (res.homeworkLinked != true) {
        saveStage = 'homework_link';
        await _ensureHomeworkSelfMarkLinked(
          cropId: problem.cropId,
          correct: res.correct,
          answer: _answers[problem.cropId],
          expectedAttemptCount: _attemptCounts[problem.cropId] ?? 1,
          verifyFirst: res.homeworkLinked == null,
        );
      }
      saveStage = 'complete_check';
      await _maybeCompleteHomework();
    } catch (e, stackTrace) {
      debugPrint('[HW_SELF_MARK][$saveStage] $e');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted && !_notifyIfBookSubmitted(e)) {
        TopGlassSnackBar.show(
          context,
          message: '기록에 실패했어요. 다시 시도해 주세요.',
          icon: Icons.wifi_off_rounded,
        );
      }
    }
  }

  /// 과제 모드에서 셀프 채점이 배정 문항(learning_attempts)에 안 남았으면
  /// 한 번 더 잇는다. 안 남으면 재진입 때 빈 문항으로 보인다.
  Future<void> _ensureHomeworkSelfMarkLinked({
    required String cropId,
    required bool correct,
    String? answer,
    required int expectedAttemptCount,
    required bool verifyFirst,
  }) async {
    final scope = widget.homework;
    if (scope == null || cropId.isEmpty) return;
    if (verifyFirst) {
      try {
        final rows =
            await StudentApi.instance.listHomeworkProblems(scope.groupId);
        for (final row in rows) {
          if (row.cropId != cropId || row.attemptCount < expectedAttemptCount) {
            continue;
          }
          final lastGraded = row.lastGradedResult ??
              (row.lastResult == 'skipped' ? null : row.lastResult);
          if (lastGraded == (correct ? 'correct' : 'wrong')) return;
        }
      } catch (_) {
        // 확인 실패 시 아래 직접 기록으로 보완한다.
      }
    }
    // 과제 정오 원장 연결은 선택 사항이 아니다. 이것까지 실패하면 성공처럼
    // 보이지 않고 호출부에서 기록 실패를 안내한다.
    await StudentApi.instance.logHomeworkSelfMark(
      groupId: scope.groupId,
      cropId: cropId,
      correct: correct,
      answer: answer,
    );
  }

  // ------------------------------------------------------------- 입력 조작

  /// 답 상태 키 — 일반 문항은 crop_id, 세트형 파트는 'crop_id::(1)'.
  String _answerKeyOf(String cropId, String? partKey) =>
      partKey == null ? cropId : '$cropId::$partKey';

  /// 현재 입력 패널이 쓰는 답 상태 키.
  String? get _activeAnswerKey {
    final cropId = _selectedCropId;
    if (cropId == null) return null;
    return _answerKeyOf(cropId, _selectedPartKey);
  }

  void _setAnswer(
    String answerKey,
    String value, {
    String? displayLatex,
  }) {
    if (_results[answerKey] == true) return;
    setState(() {
      _answers[answerKey] = value;
      final latex = displayLatex?.trim() ?? '';
      if (latex.isEmpty || value.isEmpty) {
        _answerDisplayLatex.remove(answerKey);
      } else {
        _answerDisplayLatex[answerKey] = latex;
      }
    });
  }

  /// 채점용 선형 답은 그대로 두고, MyScript 원본 LaTeX가 있으면 화면만
  /// 구조 보존 형태(연립·행렬 등)로 조판한다.
  Widget _answerMathView(
    String answerKey,
    String linear, {
    required double fontSize,
    Color? color,
  }) {
    final latex = _answerDisplayLatex[answerKey];
    if (latex != null && latex.trim().isNotEmpty) {
      return MathLatexView(
        latex: latex,
        fontSize: fontSize,
        color: color,
      );
    }
    return MathLatexView.linear(
      linear,
      fontSize: fontSize,
      color: color,
    );
  }

  /// 필기를 인식하는 동안 답 자리에 보여줄 표시.
  Widget _recognizingView({required double fontSize, Color? color}) {
    final tint = color ?? YggGlassTokens.confirmActionColor;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: fontSize * 0.8,
          height: fontSize * 0.8,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(tint),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '인식 중…',
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            color: tint,
          ),
        ),
      ],
    );
  }

  /// 아직 맞지 못한 첫 파트 키.
  /// 하단 입력이 가능한 auto 파트를 우선하고, 없으면 self 파트, 모두 정답이면 첫 파트.
  String? _firstPendingPartKey(PageProblem problem) {
    if (!problem.hasParts) return null;
    String? firstSelfPending;
    for (final part in problem.setParts) {
      if (_results[_answerKeyOf(problem.cropId, part.key)] == true) continue;
      if (!part.isSelfCheck) return part.key;
      firstSelfPending ??= part.key;
    }
    return firstSelfPending ?? problem.setParts.first.key;
  }

  /// 필기 인식 진행 표시 — 패드가 사라진 뒤에도 불리므로 mounted를 본다.
  void _setRecognizing(String answerKey, bool busy) {
    if (!mounted) return;
    final changed = busy
        ? _recognizingAnswerKeys.add(answerKey)
        : _recognizingAnswerKeys.remove(answerKey);
    if (changed) setState(() {});
  }

  bool _isRecognizing(String answerKey) =>
      _recognizingAnswerKeys.contains(answerKey);

  /// 대기 중인 필기를 2초 기다리지 않고 지금 인식시킨다.
  /// 문항을 옮기거나 채점하기 직전에 불러야 마지막 획이 답에 들어간다.
  Future<void> _flushPencilInput() async {
    final tasks = <Future<void>>[];
    final pad = _pencilKey.currentState;
    if (pad != null) tasks.add(pad.flushRecognition());
    for (final key in _setPencilKeys.values) {
      final setPad = key.currentState;
      if (setPad != null && !identical(setPad, pad)) {
        tasks.add(setPad.flushRecognition());
      }
    }
    for (final key in _bodyPencilKeys.values) {
      final bodyPad = key.currentState;
      if (bodyPad != null) {
        tasks.add(bodyPad.flushRecognition());
      }
    }
    if (tasks.isNotEmpty) await Future.wait(tasks);
  }

  /// 원본 보기에서 같은 페이지의 다른 문항으로 필기·선택이 옮겨졌을 때
  /// 페이지 뷰·필기 오버레이는 유지한 채 활성 문항 대상만 바꾼다.
  void _focusBodyProblem(PageProblem problem) {
    final targetPart =
        problem.hasParts ? _firstPendingPartKey(problem) : null;
    if (_selectedCropId == problem.cropId && _selectedPartKey == targetPart) {
      return;
    }
    setState(() {
      _selectedCropId = problem.cropId;
      _selectedPartKey = targetPart;
      if (problem.hasParts) _expandedSetCrops.add(problem.cropId);
      _editorKey = GlobalKey<MathExpressionEditorState>();
      _keyboardController.text =
          _answers[_answerKeyOf(problem.cropId, _selectedPartKey)] ?? '';
    });
  }

  /// 같은 독립형 세트 안의 다른 하위 문항에 필기·선택이 옮겨졌을 때
  /// 기존 필기 패드·세트 뷰는 유지한 채 활성 문항 대상만 바꾼다.
  void _focusSetSubProblem(PageProblem problem) {
    if (_selectedCropId == problem.cropId && _selectedPartKey == null) return;
    setState(() {
      _selectedCropId = problem.cropId;
      _selectedPartKey = null;
      _editorKey = GlobalKey<MathExpressionEditorState>();
      _keyboardController.text = _answers[problem.cropId] ?? '';
    });
  }

  /// 문항 선택 (입력 패널 대상 변경 — 에디터/키보드 상태 재생성).
  void _selectPro(PageProblem problem, {String? partKey}) {
    // 패드는 아래에서 새 키로 교체되므로, 그 전에 남은 필기를 넘긴다.
    unawaited(_flushPencilInput());
    _selectedCropId = problem.cropId;
    if (problem.hasParts) {
      _expandedSetCrops.add(problem.cropId);
      _selectedPartKey = partKey ?? _firstPendingPartKey(problem);
    } else {
      _selectedPartKey = null;
    }
    _editorKey = GlobalKey<MathExpressionEditorState>();
    _pencilKey = GlobalKey<PencilInputPadState>();
    _keyboardController.text =
        _answers[_answerKeyOf(problem.cropId, _selectedPartKey)] ?? '';
    if (_paneMode == _PaneMode.body) {
      _startBodyViewLoad(problem.cropId);
    } else if (_paneMode == _PaneMode.question) {
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

  Uri? _stableBodyBookUri(StudentTextbookProblemView view) {
    final raw = view.bodyPdfUrl?.trim() ?? '';
    if (raw.isEmpty) return null;
    final parsed = Uri.tryParse(raw);
    if (parsed == null) return null;
    final cacheKey = view.bodyCacheKey?.trim() ?? '';
    if (cacheKey.isEmpty) return parsed;
    final now = DateTime.now();
    final existing = _bodyBookUrlCache[cacheKey];
    if (existing != null && existing.expiresAt.isAfter(now)) {
      return existing.uri;
    }
    final ttlSec = (view.expiresIn ?? 3600).clamp(120, 7200);
    final safeTtl = Duration(seconds: math.max(60, ttlSec - 300));
    _bodyBookUrlCache[cacheKey] = (uri: parsed, expiresAt: now.add(safeTtl));
    return parsed;
  }

  List<int> _bodyPrefetchPagesFor(int rawPage) {
    final unit = _currentUnitBodyPages(forRawPage: rawPage).pages;
    final out = <int>[
      if (rawPage > 1) rawPage - 1,
      rawPage + 1,
    ];
    final seen = <int>{rawPage, ...out};
    final rest = <int>[
      for (final p in unit)
        if (!seen.contains(p.rawPage) && p.rawPage > 0) p.rawPage,
    ]..sort((a, b) => (a - rawPage).abs().compareTo((b - rawPage).abs()));
    for (final p in rest) {
      if (seen.add(p)) out.add(p);
    }
    return out.take(24).toList(growable: false);
  }

  void _prefetchBodyPageUrls(StudentTextbookProblemView view) {
    if (view.hasBodyPagePdf) {
      unawaited(_BodyPageBytesCache.prefetch(view.bodyPagePdfUrl));
    }
    if (view.prefetchPageUrls.isNotEmpty) {
      for (final url in view.prefetchPageUrls.values) {
        unawaited(_BodyPageBytesCache.prefetch(url));
      }
    }
  }

  void _startBodyViewLoad(String cropId) {
    final requestEpoch = ++_problemViewRequestEpoch;
    final rawPage = _problemPageMeta[cropId]?.page.rawPage ?? _page?.rawPage;
    var cached =
        _bodyViewCache[cropId] ?? (rawPage != null ? _bodyViewByPage[rawPage] : null);
    if (cached != null) {
      _bodyViewCache[cropId] ??= cached;
    }
    _problemSetView = null;
    _problemSetViewError = null;
    _loadingProblemSetView = false;
    _activeSetCacheKey = null;
    _bodyFullDocReady = false;
    _problemView = cached;
    _problemViewError = null;
    _loadingProblemView = cached == null;
    final prefetchPages =
        rawPage != null && rawPage > 0 ? _bodyPrefetchPagesFor(rawPage) : const <int>[];
    if (cached != null) {
      _absorbBodyPageRegions(cached);
      _prefetchBodyPageUrls(cached);
      if (cached.hasBodyPagePdf) {
        // 캐시된 페이지라도 앞뒤·소단원 예열을 백그라운드로 유지한다.
        unawaited(
          TextbookApi.instance
              .bodyProblemView(cropId: cropId, prefetchPages: prefetchPages)
              .then((fresh) {
            if (!mounted ||
                requestEpoch != _problemViewRequestEpoch ||
                _paneMode != _PaneMode.body) {
              return;
            }
            _absorbBodyPageRegions(fresh);
            _prefetchBodyPageUrls(fresh);
          }).catchError((_) {}),
        );
        return;
      }
    }
    unawaited(() async {
      try {
        final first = await TextbookApi.instance.bodyProblemView(
          cropId: cropId,
          prefetchPages: prefetchPages,
        );
        if (!mounted ||
            requestEpoch != _problemViewRequestEpoch ||
            cropId != _selectedCropId ||
            _paneMode != _PaneMode.body) {
          return;
        }
        _bodyViewCache[cropId] = first;
        if (first.rawPage != null) _bodyViewByPage[first.rawPage!] = first;
        _absorbBodyPageRegions(first);
        _prefetchBodyPageUrls(first);

        // 책 원본이 게이트웨이에 있으면 1쪽 분리가 ~1.3초에 끝나므로
        // 250MB 통파일 폴백을 곧바로 열지 않고 최대 ~2.1초만 짧게 기다린다.
        var current = first;
        var fellBackToFull = false;
        if (current.hasBodyPagePdf || current.bodyPageStatus != 'queued') {
          setState(() {
            _problemView = current;
            _problemViewError = null;
            _loadingProblemView = false;
          });
          if (current.hasBodyPagePdf) return;
        }
        if (!current.hasBodyPagePdf && current.bodyPageStatus == 'queued') {
          final delayMs = (current.pollAfterMs ?? 700).clamp(400, 1200).toInt();
          for (var attempt = 0; attempt < 15; attempt++) {
            await Future<void>.delayed(Duration(milliseconds: delayMs));
            if (!mounted ||
                requestEpoch != _problemViewRequestEpoch ||
                cropId != _selectedCropId ||
                _paneMode != _PaneMode.body) {
              return;
            }
            try {
              final next = await TextbookApi.instance.bodyProblemView(
                cropId: cropId,
                prefetchPages: prefetchPages,
              );
              if (!mounted ||
                  requestEpoch != _problemViewRequestEpoch ||
                  cropId != _selectedCropId ||
                  _paneMode != _PaneMode.body) {
                return;
              }
              _absorbBodyPageRegions(next);
              _prefetchBodyPageUrls(next);
              if (next.hasBodyPagePdf) {
                _bodyViewCache[cropId] = next;
                if (next.rawPage != null) {
                  _bodyViewByPage[next.rawPage!] = next;
                }
                if (!_bodyFullDocReady) {
                  setState(() {
                    _problemView = next;
                    _problemViewError = null;
                    _loadingProblemView = false;
                  });
                }
                return;
              }
            } catch (_) {}
            // ~2.1초 지나도 1쪽 PDF가 안 왔으면(콜드 책 다운로드 중) Range 폴백으로 연다.
            if (!fellBackToFull && attempt >= 2) {
              fellBackToFull = true;
              setState(() {
                _problemView = current;
                _problemViewError = null;
                _loadingProblemView = false;
              });
            }
          }
        }
      } catch (error) {
        if (!mounted ||
            requestEpoch != _problemViewRequestEpoch ||
            cropId != _selectedCropId ||
            _paneMode != _PaneMode.body) {
          return;
        }
        setState(() {
          _problemView = null;
          _problemViewError = error;
          _loadingProblemView = false;
        });
      }
    }());
  }

  void _startBodyViewForPage(int rawPage) {
    final requestEpoch = ++_problemViewRequestEpoch;
    final cached = _bodyViewByPage[rawPage];
    _problemSetView = null;
    _problemSetViewError = null;
    _loadingProblemSetView = false;
    _activeSetCacheKey = null;
    _bodyFullDocReady = false;
    _problemView = cached;
    _problemViewError = null;
    _loadingProblemView = cached == null;
    final prefetchPages = _bodyPrefetchPagesFor(rawPage);
    if (cached != null) {
      _absorbBodyPageRegions(cached);
      _prefetchBodyPageUrls(cached);
      if (cached.hasBodyPagePdf) {
        unawaited(
          TextbookApi.instance
              .bodyProblemView(
                bookId: widget.book.bookId,
                gradeLabel: widget.book.gradeLabel,
                rawPage: rawPage,
                prefetchPages: prefetchPages,
              )
              .then((fresh) {
            if (!mounted ||
                requestEpoch != _problemViewRequestEpoch ||
                _paneMode != _PaneMode.body) {
              return;
            }
            _absorbBodyPageRegions(fresh);
            _prefetchBodyPageUrls(fresh);
          }).catchError((_) {}),
        );
        return;
      }
    }
    unawaited(() async {
      try {
        final first = await TextbookApi.instance.bodyProblemView(
          bookId: widget.book.bookId,
          gradeLabel: widget.book.gradeLabel,
          rawPage: rawPage,
          prefetchPages: prefetchPages,
        );
        if (!mounted ||
            requestEpoch != _problemViewRequestEpoch ||
            _page?.rawPage != rawPage ||
            _paneMode != _PaneMode.body) {
          return;
        }
        _bodyViewByPage[rawPage] = first;
        _absorbBodyPageRegions(first);
        _prefetchBodyPageUrls(first);

        var fellBackToFull = false;
        if (first.hasBodyPagePdf || first.bodyPageStatus != 'queued') {
          setState(() {
            _problemView = first;
            _problemViewError = null;
            _loadingProblemView = false;
          });
          if (first.hasBodyPagePdf) return;
        }
        if (!first.hasBodyPagePdf && first.bodyPageStatus == 'queued') {
          final delayMs = (first.pollAfterMs ?? 700).clamp(400, 1200).toInt();
          for (var attempt = 0; attempt < 15; attempt++) {
            await Future<void>.delayed(Duration(milliseconds: delayMs));
            if (!mounted ||
                requestEpoch != _problemViewRequestEpoch ||
                _page?.rawPage != rawPage ||
                _paneMode != _PaneMode.body) {
              return;
            }
            try {
              final next = await TextbookApi.instance.bodyProblemView(
                bookId: widget.book.bookId,
                gradeLabel: widget.book.gradeLabel,
                rawPage: rawPage,
                prefetchPages: prefetchPages,
              );
              if (!mounted ||
                  requestEpoch != _problemViewRequestEpoch ||
                  _page?.rawPage != rawPage ||
                  _paneMode != _PaneMode.body) {
                return;
              }
              _absorbBodyPageRegions(next);
              _prefetchBodyPageUrls(next);
              if (next.hasBodyPagePdf) {
                _bodyViewByPage[rawPage] = next;
                if (!_bodyFullDocReady) {
                  setState(() {
                    _problemView = next;
                    _problemViewError = null;
                    _loadingProblemView = false;
                  });
                }
                return;
              }
            } catch (_) {}
            if (!fellBackToFull && attempt >= 2) {
              fellBackToFull = true;
              setState(() {
                _problemView = first;
                _problemViewError = null;
                _loadingProblemView = false;
              });
            }
          }
        }
      } catch (error) {
        if (!mounted ||
            requestEpoch != _problemViewRequestEpoch ||
            _page?.rawPage != rawPage ||
            _paneMode != _PaneMode.body) {
          return;
        }
        setState(() {
          _problemView = null;
          _problemViewError = error;
          _loadingProblemView = false;
        });
      }
    }());
  }

  void _absorbBodyPageRegions(StudentTextbookProblemView view) {
    final rawPage = view.rawPage;
    if (rawPage == null || view.pageRegions.isEmpty) return;
    final map = _bodyRegionsByPage.putIfAbsent(
      rawPage,
      () => <String, List<int>>{},
    );
    final numberMap = _bodyNumberBoxesByPage.putIfAbsent(
      rawPage,
      () => <String, List<int>>{},
    );
    final choiceMap = _bodyChoiceRegionsByPage.putIfAbsent(
      rawPage,
      () => <String, Map<int, List<int>>>{},
    );
    for (final r in view.pageRegions) {
      map[r.cropId] = r.region1k;
      if (r.numberBox1k != null) {
        numberMap[r.cropId] = r.numberBox1k!;
      }
      if (r.choiceRegions1k.isNotEmpty) {
        choiceMap[r.cropId] = r.choiceRegions1k;
      }
    }
  }

  void _startProblemViewLoad(String cropId) {
    var cached = _problemViewCache[cropId];
    if (cached?.setInfo != null) {
      _problemSetInfoByCrop[cropId] ??= cached!.setInfo!;
    }
    if (_paneMode == _PaneMode.question) {
      PageProblem? target;
      for (final p in _problems ?? const <PageProblem>[]) {
        if (p.cropId == cropId) {
          target = p;
          break;
        }
      }
      if (target != null) {
        final group = _independentSetGroupFor(target);
        if (group != null) {
          _startProblemSetViewLoad(group);
          return;
        }
      }
    }
    final requestEpoch = ++_problemViewRequestEpoch;
    // 본문모드는 body_pdf_url이 필요. ready 캐시에 없으면 폐기 후 재요청.
    if (_paneMode == _PaneMode.body &&
        cached != null &&
        (cached.bodyPdfUrl == null || cached.bodyPdfUrl!.isEmpty)) {
      _problemViewCache.remove(cropId);
      cached = null;
    }
    _problemView = cached;
    _problemViewError = null;
    _loadingProblemView = cached == null;
    _problemSetView = null;
    _problemSetViewError = null;
    _loadingProblemSetView = false;
    _activeSetCacheKey = null;

    final neighbors = _neighborCropIds(cropId);
    final shouldQueueNeighbors = _neighborQueueRequestedCropIds.add(cropId);
    if (cached != null) {
      if (shouldQueueNeighbors) {
        unawaited(_prefetchProblemView(
          cropId,
          neighborCropIds: neighbors,
        ));
      }
      unawaited(_prefetchNeighborProblemViews(neighbors));
      return;
    }
    // 선택 문항을 먼저 처리하고, 이웃 prefetch는 그 뒤에 돌려 워커/네트워크 경쟁을 줄인다.
    unawaited(() async {
      await _resolveSelectedProblemView(
        cropId: cropId,
        neighborCropIds: shouldQueueNeighbors ? neighbors : const <String>[],
        requestEpoch: requestEpoch,
      );
      if (!mounted ||
          requestEpoch != _problemViewRequestEpoch ||
          cropId != _selectedCropId) {
        return;
      }
      await _prefetchNeighborProblemViews(neighbors);
    }());
  }

  String _problemSetCacheKey(List<PageProblem> group) {
    final setKey =
        _problemSetInfoByCrop[group.first.cropId]?.setKey ?? group.first.cropId;
    final parts = <String>[for (final p in group) p.cropId];
    return '$setKey|${parts.join(',')}';
  }

  Future<StudentTextbookProblemSetView> _fetchProblemSetView(
    List<PageProblem> group,
  ) async {
    final key = _problemSetCacheKey(group);
    final cached = _problemSetViewCache[key];
    if (cached != null && cached.isReady) return cached;
    final pending = _problemSetViewRequests[key];
    if (pending != null) return pending;

    final cropIds = <String>[for (final p in group) p.cropId];
    final request = TextbookApi.instance.problemSetView(
      cropIds: cropIds,
      commonCropId: group.first.cropId,
    );
    _problemSetViewRequests[key] = request;
    try {
      final result = await request;
      if (result.commonPdfUrl != null) {
        unawaited(_QuestionPdfCache.prefetch(result.commonPdfUrl));
      }
      for (final item in result.items) {
        if (item.pdfUrl != null) {
          unawaited(_QuestionPdfCache.prefetch(item.pdfUrl));
        }
      }
      if (result.isReady) {
        _problemSetViewCache[key] = result;
      }
      return result;
    } finally {
      if (identical(_problemSetViewRequests[key], request)) {
        _problemSetViewRequests.remove(key);
      }
    }
  }

  void _startProblemSetViewLoad(List<PageProblem> group) {
    final requestEpoch = ++_problemViewRequestEpoch;
    final key = _problemSetCacheKey(group);
    final cached = _problemSetViewCache[key];
    _problemView = null;
    _problemViewError = null;
    _loadingProblemView = false;
    _activeSetCacheKey = key;
    _problemSetView = cached;
    _problemSetViewError = null;
    _loadingProblemSetView = cached == null;
    if (cached != null && cached.isReady) return;

    final groupCropIds = <String>{for (final p in group) p.cropId};
    unawaited(() async {
      try {
        final first = await _fetchProblemSetView(group);
        if (!mounted ||
            requestEpoch != _problemViewRequestEpoch ||
            !groupCropIds.contains(_selectedCropId)) {
          return;
        }
        setState(() {
          _problemSetView = first;
          _problemSetViewError = null;
          _loadingProblemSetView = false;
        });
        if (!first.isReady) {
          final delayMs = (first.pollAfterMs ?? 1200).clamp(300, 5000).toInt();
          for (var attempt = 0; attempt < 90; attempt++) {
            await Future<void>.delayed(Duration(milliseconds: delayMs));
            if (!mounted ||
                requestEpoch != _problemViewRequestEpoch ||
                !groupCropIds.contains(_selectedCropId)) {
              return;
            }
            try {
              final next = await _fetchProblemSetView(group);
              if (!mounted ||
                  requestEpoch != _problemViewRequestEpoch ||
                  !groupCropIds.contains(_selectedCropId)) {
                return;
              }
              setState(() {
                _problemSetView = next;
                _problemSetViewError = null;
                _loadingProblemSetView = false;
              });
              if (next.isReady) return;
            } catch (_) {}
          }
        }
      } catch (error) {
        if (!mounted ||
            requestEpoch != _problemViewRequestEpoch ||
            !groupCropIds.contains(_selectedCropId)) {
          return;
        }
        setState(() {
          _problemSetView = null;
          _problemSetViewError = error;
          _loadingProblemSetView = false;
        });
      }
    }());
  }

  Future<void> _prefetchNeighborProblemViews(List<String> neighborIds) async {
    for (final neighborId in neighborIds) {
      if (!_prefetchedCropIds.add(neighborId)) continue;
      unawaited(_prefetchProblemView(neighborId));
    }
  }

  StudentTextbookProblemView _fallbackFromQueued(
    StudentTextbookProblemView queued,
  ) {
    return StudentTextbookProblemView(
      status: StudentTextbookProblemViewStatus.fallback,
      bodyPdfUrl: queued.bodyPdfUrl,
      rawPage: queued.rawPage,
      itemRegion1k: queued.itemRegion1k,
      expiresIn: queued.expiresIn,
    );
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
      if (result.setInfo != null) {
        _problemSetInfoByCrop[cropId] ??= result.setInfo!;
      }
      if (!result.isQueued) {
        _problemViewCache[cropId] = result;
        if (result.isReady) {
          unawaited(_QuestionPdfCache.prefetch(result.pdfUrl));
        }
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
      final first = await _fetchProblemView(
        cropId,
        neighborCropIds: neighborCropIds,
      );
      if (!mounted ||
          requestEpoch != _problemViewRequestEpoch ||
          cropId != _selectedCropId) {
        return;
      }

      if (first.setInfo != null) {
        _problemSetInfoByCrop[cropId] = first.setInfo!;
        if (_paneMode == _PaneMode.question &&
            first.setInfo!.isIndependentSet) {
          final group = _independentSetGroupFor(
            (_problems ?? const <PageProblem>[]).firstWhere(
              (p) => p.cropId == cropId,
              orElse: () => PageProblem(
                cropId: cropId,
                problemNumber: '',
                label: '',
                answerKind: 'subjective',
                gradingMode: 'auto',
              ),
            ),
          );
          if (group != null) {
            _startProblemSetViewLoad(group);
            return;
          }
        }
      }

      if (!first.isQueued) {
        setState(() {
          _problemView = first;
          _problemViewError = null;
          _loadingProblemView = false;
        });
        return;
      }

      // 렌더 대기 중이면 폴백을 바로 보여 주고, 완료되면 뒤에서 교체한다.
      // (이전: 폴링 3회를 끝난 뒤에야 폴백 → 체감 20~30초)
      if (first.bodyPdfUrl != null) {
        setState(() {
          _problemView = _fallbackFromQueued(first);
          _problemViewError = null;
          _loadingProblemView = false;
        });
        await _upgradeProblemViewWhenReady(
          cropId: cropId,
          requestEpoch: requestEpoch,
          pollAfterMs: first.pollAfterMs,
        );
        return;
      }

      // 폴백 URL이 없으면 준비 메시지를 유지한 채 조금 더 폴링한다.
      setState(() {
        _problemView = first;
        _problemViewError = null;
        _loadingProblemView = false;
      });
      await _upgradeProblemViewWhenReady(
        cropId: cropId,
        requestEpoch: requestEpoch,
        pollAfterMs: first.pollAfterMs,
      );
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

  /// 큐에 올라간 문항이 렌더 완료되면 폴백/대기 화면을 ready PDF로 교체한다.
  Future<void> _upgradeProblemViewWhenReady({
    required String cropId,
    required int requestEpoch,
    int? pollAfterMs,
  }) async {
    final delayMs = (pollAfterMs ?? 1200).clamp(300, 5000).toInt();
    // 콜드 교재는 예열 큐가 길 수 있으므로, 같은 문항을 보는 동안은
    // 최대 ~3분까지 ready 로 승격될 때까지 폴링한다.
    for (var attempt = 0; attempt < 90; attempt++) {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      if (!mounted ||
          requestEpoch != _problemViewRequestEpoch ||
          cropId != _selectedCropId) {
        return;
      }
      try {
        final result = await _fetchProblemView(cropId);
        if (!mounted ||
            requestEpoch != _problemViewRequestEpoch ||
            cropId != _selectedCropId) {
          return;
        }
        if (result.isReady) {
          setState(() {
            _problemView = result;
            _problemViewError = null;
            _loadingProblemView = false;
          });
          return;
        }
        // queued/fallback 응답은 대기 UI를 유지한 채 계속 폴링한다.
        if (result.isFallback && result.bodyPdfUrl != null) {
          final current = _problemView;
          final sameFallback = current != null &&
              current.isFallback &&
              current.bodyPdfUrl == result.bodyPdfUrl;
          if (!sameFallback) {
            setState(() {
              _problemView = result;
              _problemViewError = null;
              _loadingProblemView = false;
            });
          }
        }
      } catch (_) {
        // 백그라운드 업그레이드는 best-effort. 폴백/대기 화면을 유지한다.
      }
    }
  }

  void _toggleObjective(
    String cropId,
    int number, {
    List<Offset>? pencilStroke,
  }) {
    if (_results[cropId] == true) return;
    if (_isOnHold(cropId)) return;
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
    final marks = _objectivePencilMarks.putIfAbsent(
      cropId,
      () => <int, List<Offset>>{},
    );
    if (startsRevision) marks.clear();
    final added = !selected.remove(number);
    if (added) {
      selected.add(number);
      if (pencilStroke != null && pencilStroke.length >= 2) {
        marks[number] = List<Offset>.of(pencilStroke);
      } else {
        marks.remove(number);
      }
    } else {
      marks.remove(number);
    }
    final sorted = selected.toList()..sort();
    PageProblem? problem;
    for (final p in _problems ?? const <PageProblem>[]) {
      if (p.cropId == cropId) {
        problem = p;
        break;
      }
    }
    setState(() {
      if (startsRevision) {
        _results.remove(cropId);
        _flags.remove(cropId);
      }
      _answers[cropId] = sorted.join(',');
      // 번호를 고른 카드가 입력·문항 보기 대상이 되도록 함께 선택한다.
      if (problem != null) {
        final sameBodyPage = _paneMode == _PaneMode.body &&
            _problemPageMeta[problem.cropId]?.page.rawPage ==
                (_problemView?.rawPage ?? _page?.rawPage);
        if (sameBodyPage) {
          _focusBodyProblem(problem);
        } else {
          _selectPro(problem);
        }
      }
    });
  }

  int get _pendingGradeCount {
    if (_isTimedTest) {
      final answerKey = _activeAnswerKey;
      if (answerKey == null) return 0;
      return (_answers[answerKey]?.trim().isNotEmpty ?? false) ? 1 : 0;
    }
    // 실제 일괄 채점과 같은 범위(_seenProblems)를 센다.
    // 현재 페이지만 보면 다음 페이지로 넘어간 순간 배지가 사라진다.
    final pending = _collectPendingSubmissions();
    var count = pending.answers.length;
    for (final parts in pending.parts.values) {
      count += parts.length;
    }
    return count;
  }

  /// 연 페이지를 먼저 보여 준 뒤, 나머지 페이지의 번호·답·채점 기록만 이어 붙인다.
  /// 문항 PDF 예열은 하지 않는다.
  Future<void> _feedRemainingCardPages(int epoch) async {
    final pages = _flattenedPages();
    final currentRaw = _page?.rawPage;
    final start = pages.indexWhere((entry) => entry.page.rawPage == currentRaw);
    if (start < 0) return;
    for (var i = start + 1; i < pages.length; i++) {
      if (!mounted || epoch != _pageEpoch) return;
      await _loadCardPage(pages[i], epoch);
    }
    for (var i = start - 1; i >= 0; i--) {
      if (!mounted || epoch != _pageEpoch) return;
      await _loadCardPage(pages[i], epoch);
    }
  }

  Future<void> _loadCardPage(
    ({TbPageStat page, String pathLabel}) entry,
    int epoch,
  ) {
    final rawPage = entry.page.rawPage;
    if (_loadedCardRawPages.contains(rawPage)) return Future<void>.value();
    final inflight = _cardPageLoads[rawPage];
    if (inflight != null) return inflight;
    final future = _loadCardPageBody(entry, epoch);
    _cardPageLoads[rawPage] = future;
    return future.whenComplete(() {
      if (identical(_cardPageLoads[rawPage], future)) {
        _cardPageLoads.remove(rawPage);
      }
    });
  }

  Future<void> _loadCardPageBody(
    ({TbPageStat page, String pathLabel}) entry,
    int epoch,
  ) async {
    try {
      final loaded = await TextbookApi.instance.pageProblems(
        bookId: widget.book.bookId,
        gradeLabel: widget.book.gradeLabel,
        rawPage: entry.page.rawPage,
      );
      if (!mounted || epoch != _pageEpoch) return;
      final problems = await _withHomeworkRoundState(_scopedProblems(loaded));
      if (!mounted || epoch != _pageEpoch || _problems == null) return;
      setState(() {
        if (epoch != _pageEpoch || _problems == null) return;
        _mergeCardPage(problems, entry);
      });
      if (problems.isNotEmpty) {
        // 나머지 카드 페이지에서는 세트 묶음 메타데이터만 읽고 렌더 잡은 넣지 않는다.
        unawaited(_warmCurrentPageProblemViews(problems, enqueue: false));
      }
    } catch (_) {
      // 한 페이지가 실패해도 나머지 번호 카드는 계속 붙인다.
    }
  }

  /// 책 순서를 유지한 채 한 페이지를 끼워 넣고, 앵커 문항은 그 자리에 둔다.
  void _mergeCardPage(
    List<PageProblem> incoming,
    ({TbPageStat page, String pathLabel}) entry,
  ) {
    final stored = _problems;
    if (stored == null) return;
    final problems = List<PageProblem>.of(stored);
    _problems = problems;
    _tagProblemPage(incoming, entry.page, entry.pathLabel);
    _absorbProblemRecords(incoming);
    _loadedCardRawPages.add(entry.page.rawPage);
    final known = <String>{for (final problem in problems) problem.cropId};
    final fresh = <PageProblem>[
      for (final problem in incoming)
        if (known.add(problem.cropId)) problem,
    ];
    if (fresh.isEmpty) return;
    final pages = _flattenedPages();
    final myIndex =
        pages.indexWhere((item) => item.page.rawPage == entry.page.rawPage);
    var insertAt = problems.length;
    for (var i = 0; i < problems.length; i++) {
      final otherRaw = _problemPageMeta[problems[i].cropId]?.page.rawPage;
      final otherIndex =
          pages.indexWhere((item) => item.page.rawPage == otherRaw);
      if (otherIndex > myIndex) {
        insertAt = i;
        break;
      }
    }
    final anchorCrop = (_anchorIndex >= 0 && _anchorIndex < problems.length)
        ? problems[_anchorIndex].cropId
        : _selectedCropId;
    problems.insertAll(insertAt, fresh);
    if (widget.homework != null && _homeworkOrderByCrop.isNotEmpty) {
      problems.sort(
        (a, b) => (_homeworkOrderByCrop[a.cropId] ?? 1 << 20)
            .compareTo(_homeworkOrderByCrop[b.cropId] ?? 1 << 20),
      );
    }
    if (anchorCrop != null) {
      final nextAnchor =
          problems.indexWhere((problem) => problem.cropId == anchorCrop);
      if (nextAnchor >= 0) _anchorIndex = nextAnchor;
    }
  }

  /// 다음/이전으로 화면 밖으로 나간 입력 카드를 보이는 가장자리로 붙인다.
  void _stickSelectedCard({required bool toBottom, int attempt = 0}) {
    if (!mounted || _paneMode != _PaneMode.answers) return;
    final cardContext = _selectedCardKey.currentContext;
    final card = cardContext?.findRenderObject();
    if (card is! RenderBox || !card.hasSize || !card.attached) {
      if (attempt >= 8) return;
      // 화면 밖에 있으면 아직 안 그려져 있다. 그쪽으로 한 칸 옮긴 뒤 다시 맞춘다.
      if (attempt >= 1 && _answersScrollController.hasClients) {
        final position = _answersScrollController.position;
        if (position.hasContentDimensions) {
          final nudge = toBottom ? 320.0 : -320.0;
          final jumped = (position.pixels + nudge)
              .clamp(position.minScrollExtent, position.maxScrollExtent);
          if ((jumped - position.pixels).abs() >= 1) {
            position.jumpTo(jumped.toDouble());
          }
        }
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _stickSelectedCard(toBottom: toBottom, attempt: attempt + 1);
      });
      return;
    }
    final revealed = RenderAbstractViewport.maybeOf(card);
    if (revealed is! RenderBox) return;
    final viewport = revealed as RenderBox;
    if (!viewport.hasSize) return;
    final position = _answersScrollController.hasClients
        ? _answersScrollController.position
        : null;
    if (position == null || !position.hasContentDimensions) return;

    final cardTop = card.localToGlobal(Offset.zero).dy;
    final cardBottom = cardTop + card.size.height;
    final viewTop = viewport.localToGlobal(Offset.zero).dy;
    final viewBottom = viewTop + viewport.size.height;
    final contentTop =
        viewTop + _answerListTop(_solveTitleExtent(context));
    final visibleHeight = viewBottom - contentTop;
    if (visibleHeight <= 0) return;

    double delta;
    if (card.size.height >= visibleHeight) {
      delta = cardTop - contentTop;
    } else if (toBottom) {
      if (cardBottom <= viewBottom + 1) return;
      delta = cardBottom - viewBottom;
    } else {
      if (cardTop >= contentTop - 1) return;
      delta = cardTop - contentTop;
    }
    final target = (position.pixels + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 1) return;
    position.animateTo(
      target.toDouble(),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _moveBodyPage(int delta) async {
    if (_loadingProblems || delta == 0) return;
    final pages = _flattenedPages(includeConcept: true);
    final current = _page;
    if (pages.isEmpty || current == null) return;
    var pageIndex =
        pages.indexWhere((entry) => entry.page.rawPage == current.rawPage);
    if (pageIndex < 0) return;
    final nextIndex = pageIndex + delta;
    if (nextIndex < 0 || nextIndex >= pages.length) return;
    final entry = pages[nextIndex];
    if (entry.page.isConceptPage) {
      await _openPage(entry.page, entry.pathLabel);
    } else {
      await _openPage(
        entry.page,
        entry.pathLabel,
        select: _PageEntrySelect.first,
      );
    }
    if (_bodyScrollController.hasClients) {
      _bodyScrollController.jumpTo(0);
    }
  }

  Future<void> _moveProblem(int delta) async {
    if (_isTimedTest) {
      if (delta > 0) {
        await _submitTimedAnswer(skipped: true);
      }
      return;
    }
    if (_paneMode == _PaneMode.body) {
      await _moveBodyPage(delta);
      return;
    }
    if (_loadingProblems || delta == 0) return;
    final problems = _problems ?? const <PageProblem>[];
    if (problems.isEmpty) return;
    var index =
        problems.indexWhere((problem) => problem.cropId == _selectedCropId);

    // 독립형 세트(문항 보기): 같은 세트 문항이 한 화면에 모두 있으므로 세트 전체를 건너뛴다.
    if (!_isTimedTest && _paneMode == _PaneMode.question && index >= 0) {
      final group = _independentSetGroupFor(problems[index]);
      if (group != null && group.length > 1) {
        final groupIds = <String>{for (final p in group) p.cropId};
        index = delta > 0
            ? problems.lastIndexWhere((p) => groupIds.contains(p.cropId))
            : problems.indexWhere((p) => groupIds.contains(p.cropId));
      }
    }

    // 세트형: 같은 문항의 하위 파트(1)→(2)…를 먼저 이동한 뒤 다음 문제로.
    if (index >= 0) {
      final current = problems[index];
      if (current.hasParts) {
        final parts = current.setParts;
        var partIndex = parts.indexWhere((p) => p.key == _selectedPartKey);
        if (partIndex < 0) partIndex = delta > 0 ? -1 : parts.length;
        final nextPart = partIndex + delta;
        if (nextPart >= 0 && nextPart < parts.length) {
          setState(
            () => _selectPro(current, partKey: parts[nextPart].key),
          );
          return;
        }
      }
    }

    if (index < 0) index = delta > 0 ? -1 : problems.length;
    var next = index + delta;
    if (next < 0 || next >= problems.length) {
      final pages = _flattenedPages();
      final current = _page;
      if (pages.isEmpty || current == null) return;
      var pageIndex =
          pages.indexWhere((entry) => entry.page.rawPage == current.rawPage);
      if (pageIndex < 0) return;
      final epoch = _pageEpoch;
      while (next < 0 || next >= (_problems?.length ?? 0)) {
        pageIndex += delta > 0 ? 1 : -1;
        if (pageIndex < 0 || pageIndex >= pages.length) return;
        final entry = pages[pageIndex];
        await _loadCardPage(entry, epoch);
        if (!mounted || epoch != _pageEpoch) return;
        if (!_loadedCardRawPages.contains(entry.page.rawPage)) return;
        final refreshed = _problems ?? const <PageProblem>[];
        final again = refreshed
            .indexWhere((problem) => problem.cropId == _selectedCropId);
        next = (again < 0 ? index : again) + delta;
        if (next >= 0 && next < refreshed.length) break;
      }
    }
    final target = (_problems ?? const <PageProblem>[])[next];
    final changedProblem = target.cropId != _selectedCropId;
    setState(() {
      if (target.hasParts) {
        // 다음 문제로 진입 → 첫 파트, 이전 문제로 진입 → 마지막 파트.
        final partKey =
            delta > 0 ? target.setParts.first.key : target.setParts.last.key;
        _selectPro(target, partKey: partKey);
      } else {
        _selectPro(target);
      }
      final meta = _problemPageMeta[target.cropId];
      if (meta != null) {
        _page = meta.page;
        _pagePathLabel = meta.pathLabel;
        _expandTreeForPage(meta.page);
      }
    });
    if (changedProblem && _paneMode == _PaneMode.answers) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _stickSelectedCard(toBottom: delta > 0);
      });
    }
  }

  void _setPaneMode(_PaneMode mode) {
    if (_isTimedTest || mode == _paneMode) return;
    final leavingConceptPage =
        mode != _PaneMode.body && (_page?.isConceptPage == true);
    setState(() {
      _resetTitleCollapse();
      _paneMode = mode;
      if (_paneMode == _PaneMode.question || _paneMode == _PaneMode.body) {
        final problems = _problems ?? const <PageProblem>[];
        if (problems.isNotEmpty && !(_paneMode == _PaneMode.body && _page?.isConceptPage == true)) {
          final selected = problems.firstWhere(
            (problem) => problem.cropId == _selectedCropId,
            orElse: () => problems.first,
          );
          _selectPro(selected);
        } else if (_paneMode == _PaneMode.body && _page != null) {
          _startBodyViewForPage(_page!.rawPage);
        }
      } else {
        _problemViewRequestEpoch++;
        _problemView = null;
        _problemViewError = null;
        _loadingProblemView = false;
        _problemSetView = null;
        _problemSetViewError = null;
        _loadingProblemSetView = false;
        _activeSetCacheKey = null;
        // 정답 카드로 돌아오면 지금 입력 중인 문항이 맨 위에 온다.
        _reanchorToSelection();
      }
    });
    if (leavingConceptPage) {
      final problemPages = _flattenedPages(includeConcept: false);
      if (problemPages.isNotEmpty) {
        final curRaw = _page!.rawPage;
        final match = problemPages.firstWhere(
          (e) => e.page.rawPage >= curRaw,
          orElse: () => problemPages.last,
        );
        unawaited(_openPage(match.page, match.pathLabel));
      }
    }
  }

  void _cycleInputMode() {
    setState(() {
      _inputMode = switch (_inputMode) {
        _InputMode.pencil => _InputMode.editor,
        _InputMode.editor => _InputMode.keyboard,
        _InputMode.keyboard => _InputMode.pencil,
      };
      final answerKey = _activeAnswerKey;
      if (answerKey != null) {
        _keyboardController.text = _answers[answerKey] ?? '';
      }
    });
  }

  double _scratchExpandedDefault(BuildContext context) =>
      MediaQuery.sizeOf(context).height * 0.5;

  /// 접힌 연습장 높이 = 하단 입력 패널을 딱 가리는 높이.
  /// (시트 위쪽 그림자 스트립 `_kScratchTopShadow` 포함)
  double _scratchCollapsedHeight(BuildContext context) {
    final box = _inputPanelKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize && box.size.height > 0) {
      return box.size.height + _kScratchTopShadow;
    }
    // 레이아웃 전 폴백 ≈ flex 1/3.
    final screen = MediaQuery.sizeOf(context).height;
    return screen / 3 + _kScratchTopShadow;
  }

  /// 두 손가락 위로 쓸기 — 닫혀 있으면 펼치고, 낮게 접혀 있으면 다시 크게 펼친다.
  void _openScratchFromSwipe() {
    setState(() {
      final expanded = _scratchExpandedDefault(context);
      final target =
          _scratchRestoredHeight > 0 ? _scratchRestoredHeight : expanded;
      if (!_scratchOpen) {
        _scratchOpen = true;
        _scratchCollapsed = false;
        _scratchHeight = target;
        _scratchRestoredHeight = _scratchHeight;
        return;
      }
      if (_scratchCollapsed) {
        _scratchCollapsed = false;
        _scratchHeight = target;
      }
    });
  }

  /// 두 손가락 아래로 쓸기 — 연습장을 화면 아래로 접어 닫는다.
  void _closeScratchFromSwipe() {
    if (!_scratchOpen) return;
    setState(() => _scratchOpen = false);
  }

  void _onScratchHandleTap() {
    setState(() {
      if (_scratchCollapsed) {
        _scratchCollapsed = false;
        _scratchHeight = _scratchRestoredHeight > 0
            ? _scratchRestoredHeight
            : _scratchExpandedDefault(context);
      } else {
        _scratchRestoredHeight = _scratchHeight;
        _scratchCollapsed = true;
        _scratchHeight = _scratchCollapsedHeight(context);
      }
    });
  }

  void _onScratchHeightDrag(double delta) {
    final screen = MediaQuery.sizeOf(context).height;
    final minH = _scratchCollapsedHeight(context);
    final maxH = screen * 0.88;
    setState(() {
      _scratchCollapsed = false;
      _scratchHeight = (_scratchHeight - delta).clamp(minH, maxH);
      _scratchRestoredHeight = _scratchHeight;
    });
  }

  void _eraseFromApplePencil() {
    final cropId = _selectedCropId;
    if (cropId != null) {
      for (final problem in _problems ?? const <PageProblem>[]) {
        if (problem.cropId != cropId) continue;
        if (_usesSelfCheckInput(problem)) return;
        break;
      }
    }
    _eraseCurrentInput();
  }

  void _eraseCurrentInput() {
    final answerKey = _activeAnswerKey;
    if (answerKey == null || _results[answerKey] == true) return;
    switch (_inputMode) {
      case _InputMode.pencil:
        final cropId = _selectedCropId;
        if (_paneMode == _PaneMode.body) {
          final rawPage =
              (cropId != null ? _problemPageMeta[cropId]?.page.rawPage : null) ??
                  _problemView?.rawPage ??
                  _page?.rawPage;
          final bodyPad =
              rawPage != null ? _bodyPencilKeys[rawPage]?.currentState : null;
          final hasStrokes = bodyPad?.undoTarget(cropId) ?? false;
          if (!hasStrokes) _setAnswer(answerKey, '');
          break;
        }
        final pad = (cropId != null ? _setPencilKeys[cropId]?.currentState : null) ??
            _pencilKey.currentState;
        final hasStrokes = pad?.undoStroke() ?? false;
        if (!hasStrokes) _setAnswer(answerKey, '');
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
        _setAnswer(answerKey, value);
        break;
    }
  }

  // ------------------------------------------------------------- 신고·보류

  /// 신고로 보류(검토 중/인정)되어 채점·통계에서 제외된 문항인지.
  bool _isOnHold(String cropId) {
    final status = _reportStatuses[cropId];
    return status == 'open' || status == 'accepted';
  }

  Future<void> _reportProblem(PageProblem problem) async {
    if (_isOnHold(problem.cropId)) {
      TopGlassSnackBar.show(
        context,
        message: '이미 신고한 문항이에요. 선생님이 확인 중이에요.',
        icon: Icons.flag_outlined,
      );
      return;
    }
    final input = await showDialog<_ReportProblemInput>(
      context: context,
      builder: (_) => _ReportProblemDialog(
        problemNumber: _displayProblemNumber(problem),
      ),
    );
    if (input == null || !mounted) return;

    // 「필기 인식이 잘 안돼요」 신고면 필기 원본 데이터를 함께 첨부한다.
    // 지금 패드에 있는 필기를 우선 쓰고, 모드 전환·문항 이동으로 패드가
    // 사라졌으면 문항별로 보관해 둔 마지막 인식 스냅샷을 쓴다.
    final wantsHandwriting =
        input.issueTypes.contains('handwriting_recognition');
    Map<String, dynamic>? handwriting;
    if (wantsHandwriting) {
      final rawPage = _problemPageMeta[problem.cropId]?.page.rawPage ??
          _problemView?.rawPage ??
          _page?.rawPage;
      Map<String, dynamic>? payload =
          _setPencilKeys[problem.cropId]?.currentState?.handwritingReportPayload;
      if (payload == null && rawPage != null) {
        payload = _bodyPencilKeys[rawPage]
            ?.currentState
            ?.handwritingReportPayloadFor(problem.cropId);
      }
      if (payload == null && problem.cropId == _selectedCropId) {
        payload = _pencilKey.currentState?.handwritingReportPayload;
      }
      payload ??= _handwritingSnapshots[problem.cropId];
      if (payload != null) {
        final answerKey = _answerKeyOf(
          problem.cropId,
          problem.hasParts ? _selectedPartKey : null,
        );
        final candidates =
            (payload['recognized_candidates'] as List?) ?? const [];
        final recognizedText = '${payload['recognized_text'] ?? ''}'.trim();
        handwriting = <String, dynamic>{
          ...payload,
          'recognized_text': recognizedText.isNotEmpty
              ? recognizedText
              : (candidates.isEmpty ? '' : candidates.first.toString()),
          'submitted_answer': _answers[answerKey] ?? '',
          'input_mode': '${payload['input_mode'] ?? _inputMode.name}',
        };
      }
    }

    // 필기 단독 신고인데 보낼 필기 데이터가 없으면 서버에 빈 신고를
    // 보내는 대신 바로 안내한다.
    final handwritingOnly = wantsHandwriting && input.issueTypes.length == 1;
    if (handwritingOnly && handwriting == null) {
      TopGlassSnackBar.show(
        context,
        message: '보낼 필기 데이터가 없어요. 정답 칸에 필기한 뒤 다시 신고해 주세요.',
        icon: Icons.draw_rounded,
      );
      return;
    }

    final Map<String, dynamic> result;
    try {
      result = await TextbookApi.instance.reportProblem(
        bookId: widget.book.bookId,
        gradeLabel: widget.book.gradeLabel,
        cropId: problem.cropId,
        issueTypes: input.issueTypes,
        note: input.note,
        handwriting: handwriting,
      );
    } catch (_) {
      if (mounted) {
        TopGlassSnackBar.show(
          context,
          message: '신고 접수에 실패했어요. 다시 시도해 주세요.',
          icon: Icons.wifi_off_rounded,
        );
      }
      return;
    }
    if (!mounted) return;

    if (result['held'] != true) {
      // 필기 단독 신고 — 문항은 보류되지 않는다.
      TopGlassSnackBar.show(
        context,
        message: '필기 데이터를 보냈어요. 인식 개선에 사용할게요.',
        icon: Icons.draw_rounded,
      );
      return;
    }
    setState(() => _reportStatuses[problem.cropId] = 'open');
    TopGlassSnackBar.show(
      context,
      message: '신고를 접수했어요. 선생님 확인 전까지 이 문항은 채점에서 제외돼요.',
      icon: Icons.flag_rounded,
    );
    // 트리의 페이지 현황(보류 제외 통계) 갱신
    _loadTree();
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleExtent = _solveTitleExtent(context);
    return PopScope(
      // 시스템 뒤로가기도 잔여 답 채점·미수행 기록을 거친 뒤 나간다.
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_handleExit());
      },
      child: Scaffold(
        backgroundColor:
            _solvePaneImmersive ? Colors.white : context.yggSurfaceBase,
        body: Stack(
          children: [
            Positioned.fill(
              child: _buildPagePanel(theme, topInset: titleExtent),
            ),
            // 딤 배리어 — 타이틀 바 아래(시트와 같은 top)만 덮고 opacity 로 페이드.
            Positioned(
              top: titleExtent,
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: _isTimedTest || !_treeOpen,
                child: AnimatedOpacity(
                  opacity: !_isTimedTest && _treeOpen ? 1 : 0,
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _setTreeOpen(false),
                    child: const ColoredBox(
                      color: Color(0x66000000),
                    ),
                  ),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              // 시트 폭 + 왼쪽 그림자 blur 만큼 더 내보내 접힌 상태 잔상 제거.
              right: !_isTimedTest && _treeOpen
                  ? 0
                  : -(_kPageSheetWidth + _kPageSheetShadowBleed),
              // 타이틀 바 높이만큼 내려 이전 AppBar 아래 정렬과 동일하게 맞춤.
              top: titleExtent,
              bottom: 0,
              width: _kPageSheetWidth,
              child: IgnorePointer(
                ignoring: !_treeOpen,
                child: _IosPageSheet(
                  onClose: () => _setTreeOpen(false),
                  child: _buildTreePanel(theme),
                ),
              ),
            ),
            if (!_isTimedTest && !_treeOpen)
              Positioned(
                top: titleExtent,
                right: 0,
                bottom: 0,
                width: 28,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragEnd: (details) {
                    if ((details.primaryVelocity ?? 0) < -180) {
                      _setTreeOpen(true);
                    }
                  },
                ),
              ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _buildSolveTitleBar(theme),
            ),
            // 나가기 처리(잔여 답 채점·미수행 기록) 중 입력 차단.
            if (_exitFlushing)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x33000000),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
            if (_timedPreparing)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x33000000),
                  child: Center(child: YggLoadingIndicator()),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 배경만 옅어진다. 제목 문구와 버튼은 그대로 남긴다.
  Widget _fadeWithTitle(Widget child) {
    return IgnorePointer(
      ignoring: _titleOpacity < 0.05,
      child: Opacity(
        opacity: _titleOpacity,
        child: Transform.translate(
          offset: Offset(0, -(1 - _titleOpacity) * 12),
          child: child,
        ),
      ),
    );
  }

  PageProblem? _selectedProblem() {
    final id = _selectedCropId;
    final problems = _problems;
    if (id == null || problems == null) return null;
    for (final problem in problems) {
      if (problem.cropId == id) return problem;
    }
    return null;
  }

  /// 지금 입력 중인 문항. 세트형은 선택된 파트까지, 독립형 세트는 묶인 번호 범위를 붙인다.
  String _currentProblemHeading() {
    if (_isTimedTest) return '제 ${_timedIndex + 1}문제';
    if (_paneMode == _PaneMode.body && (_page?.isConceptPage == true)) {
      return 'p.${_page!.shownPage} 개념';
    }
    final problem = _selectedProblem();
    if (problem == null) return '';
    if (_paneMode == _PaneMode.question) {
      final group = _independentSetGroupFor(problem);
      if (group != null) {
        final range = _formatSetRangeHeading(group);
        if (range.isNotEmpty) return range;
      }
    }
    final number = _displayProblemNumber(problem).trim();
    if (number.isEmpty) return '';
    final part = problem.hasParts ? _selectedPartKey?.trim() : null;
    if (part == null || part.isEmpty) return '$number번';
    return '$number번 $part';
  }

  /// 경로 라벨 `중단원 · 소단원`에서 소단원명만 꺼낸다.
  String _smallUnitNameOf(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    final cut = trimmed.lastIndexOf(' · ');
    if (cut < 0) return trimmed;
    return trimmed.substring(cut + 3).trim();
  }

  /// 지금 푸는 문항이 속한 페이지. 이어 붙인 목록에서도 그 문항 페이지를 따른다.
  ({TbPageStat page, String pathLabel})? _currentPageMeta() {
    if (_paneMode == _PaneMode.body && _page != null) {
      return (page: _page!, pathLabel: _pagePathLabel);
    }
    final id = _selectedCropId;
    if (id != null) {
      final tagged = _problemPageMeta[id];
      if (tagged != null) return tagged;
    }
    final page = _page;
    if (page == null) return null;
    return (page: page, pathLabel: _pagePathLabel);
  }

  String _bookHeading() {
    if (_isTimedTest) {
      final title = widget.timedTest!.group.title.trim();
      return title.isEmpty ? '시간제한 테스트' : title;
    }
    return widget.book.name;
  }

  bool? _gradedResultOf(PageProblem problem) {
    if (_isOnHold(problem.cropId)) return null;
    if (problem.hasParts) {
      var allCorrect = problem.setParts.isNotEmpty;
      var anyGradedWrong = false;
      for (final part in problem.setParts) {
        final k = _answerKeyOf(problem.cropId, part.key);
        final ans = _answers[k] ?? '';
        final res = _results[k];
        final partGraded = res != null &&
            (part.isSelfCheck ||
                _selfGraded.contains(k) ||
                _gradedAnswers[k] == ans);
        if (!partGraded) {
          allCorrect = false;
        } else if (!res) {
          allCorrect = false;
          anyGradedWrong = true;
        }
      }
      if (allCorrect) return true;
      if (anyGradedWrong) return false;
      return null;
    }
    final answer = _answers[problem.cropId] ?? '';
    final result = _results[problem.cropId];
    final attemptCount = _attemptCounts[problem.cropId] ?? 0;
    final graded = result != null &&
        (_selfGraded.contains(problem.cropId) ||
            (problem.isSelfCheck && attemptCount > 0) ||
            _gradedAnswers[problem.cropId] == answer);
    return graded ? result : null;
  }

  Widget _buildSolveHeading(ThemeData theme) {
    final problem = _currentProblemHeading();
    final showBook =
        !_solvePaneImmersive && (_titleShowsBook || problem.isEmpty);
    final label = showBook
        ? _bookHeading()
        : (problem.isEmpty ? _bookHeading() : problem);
    final selected = _selectedProblem();
    final bool? headingGradedResult = (_paneMode == _PaneMode.question &&
            !showBook &&
            selected != null &&
            _independentSetGroupFor(selected) == null)
        ? _gradedResultOf(selected)
        : null;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.centerLeft,
          children: [
            ...previousChildren,
            if (currentChild != null) currentChild,
          ],
        );
      },
      child: _RedPencilGradeMark(
        key: ValueKey(
          '${showBook ? 'book:$label' : 'problem:$label'}|$headingGradedResult',
        ),
        gradedResult: headingGradedResult,
        seed: selected?.cropId.hashCode ?? 0,
        scaleFactor: 0.84,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontSize: StudentPageTitle.fontSize,
            fontWeight: FontWeight.w700,
            height: 1.15,
          ),
        ),
      ),
    );
  }

  /// 모음·페이지 버튼 바로 왼쪽. 페이지 번호와 소단원명을 오른쪽 정렬로 붙인다.
  Widget _buildPageMeta(ThemeData theme) {
    final meta = _currentPageMeta();
    if (meta == null) return const SizedBox.shrink();
    final page = meta.page;
    final small = _smallUnitNameOf(meta.pathLabel);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          'p.${page.shownPage}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.end,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        if (small.isNotEmpty)
          Text(
            small,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.hintColor,
            ),
          ),
      ],
    );
  }

  Widget _buildSolveTitleBar(ThemeData theme) {
    // 상태 아일랜드는 이 화면 위에 가운데로 그려진다.
    // 가운데 폭을 비워 두어야 모음·페이지 버튼이 아일랜드 아래로 들어가지 않는다.
    final backdropColor =
        _solvePaneImmersive ? Colors.white : context.yggSurfaceBase;
    final titleBackdrop = _fadeWithTitle(
      ColoredBox(color: backdropColor),
    );
    final sheetOpen = !_isTimedTest && _treeOpen;
    return Stack(
      children: [
        if (_paneMode == _PaneMode.body)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: _islandBottom(context),
            child: titleBackdrop,
          )
        else
          Positioned.fill(child: titleBackdrop),
        // 페이지 시트를 열 때는 스크롤 상태·원본보기 여부와 무관하게
        // 상단 영역(0..titleExtent) 배경을 시트 상단선까지 채운다.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !sheetOpen,
            child: AnimatedOpacity(
              opacity: sheetOpen ? 1 : 0,
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              child: ColoredBox(color: backdropColor),
            ),
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            StudentStatusIslandToolbarSlot(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Padding(
                      // 페이지 버튼 오른쪽과 같은 화면 끝 여백.
                      padding: const EdgeInsets.only(
                        left: _solveEdgeInset,
                        right: 12,
                      ),
                      child: Row(
                        children: [
                          StudentBackButton(
                            onPressed: () => unawaited(_handleExit()),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: IgnorePointer(
                              child: _buildSolveHeading(theme),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const IgnorePointer(
                    child: SizedBox(width: StudentStatusIsland.minWidth),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(
                        left: 12,
                        right: _solveEdgeInset,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (_isTimedTest)
                            _fadeWithTitle(
                              Text(
                                '남은 시간 $_timedClockLabel',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: _timedRemainingSeconds <= 60
                                      ? Colors.red
                                      : null,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            )
                          else ...[
                            if (_paneMode != _PaneMode.body) ...[
                              Flexible(
                                child: IgnorePointer(
                                  child: _buildPageMeta(theme),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            SolidCapsuleActionBar(
                              children: [
                                SolveViewMenuButton(
                                  selected: switch (_paneMode) {
                                    _PaneMode.answers => SolveViewKind.numbers,
                                    _PaneMode.question =>
                                      SolveViewKind.question,
                                    _PaneMode.body => SolveViewKind.original,
                                  },
                                  onSelected: (kind) => _setPaneMode(
                                    switch (kind) {
                                      SolveViewKind.numbers =>
                                        _PaneMode.answers,
                                      SolveViewKind.question =>
                                        _PaneMode.question,
                                      SolveViewKind.original => _PaneMode.body,
                                    },
                                  ),
                                ),
                                SolidCapsuleActionButton(
                                  tooltip: '소단원·페이지 선택',
                                  icon: Icons.segment_rounded,
                                  selected: _treeOpen,
                                  onPressed: () => _setTreeOpen(!_treeOpen),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const IgnorePointer(child: SizedBox(height: 8)),
          ],
        ),
      ],
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

    // 과제 스코프면 배정 문항이 있는 페이지만 보여준다.
    // 원본보기 모드일 때는 해당 소단원의 개념 페이지도 함께 보여준다.
    final scope = widget.homework;
    final includeConcept = _paneMode == _PaneMode.body;
    bool smallHasVisiblePages(TbSmallUnit small) => small.pages.any(
          (p) => !p.isConceptPage && (scope == null || scope.rawPages.contains(p.rawPage)),
        );
    bool inScope(TbSmallUnit small, TbPageStat page) {
      if (page.isConceptPage) {
        return includeConcept && smallHasVisiblePages(small);
      }
      return scope == null || scope.rawPages.contains(page.rawPage);
    }

    final rows = <Widget>[];
    for (final big in tree.bigUnits) {
      if (!big.mids.any((m) => m.smalls.any((s) => s.pages.any((p) => inScope(s, p))))) {
        continue;
      }
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
        if (!mid.smalls.any((s) => s.pages.any((p) => inScope(s, p)))) continue;
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
          if (!small.pages.any((p) => inScope(small, p))) continue;
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
            if (!inScope(small, page)) continue;
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
                  page.isConceptPage
                      ? Icons.menu_book_outlined
                      : done
                          ? Icons.check_circle_rounded
                          : (page.graded > 0
                              ? Icons.timelapse_rounded
                              : Icons.circle_outlined),
                  size: 16,
                  color: selected
                      ? accent
                      : page.isConceptPage
                          ? theme.hintColor
                          : done
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
                  page.isConceptPage ? '개념' : '${page.correct}/${page.total}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: selected ? accent : theme.hintColor,
                    fontWeight: page.isConceptPage ? FontWeight.w700 : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 스크롤 0이 지금 앵커 문항이다. 앞 페이지는 위로, 뒤 페이지는 아래로 붙는다.
  Widget _buildAnswerFeed(
    ThemeData theme,
    List<PageProblem> problems,
    double titleExtent,
  ) {
    final anchor = problems.isEmpty
        ? 0
        : _anchorIndex.clamp(0, problems.length - 1);
    final contentTop = _answerListTop(titleExtent);
    return CustomScrollView(
      controller: _answersScrollController,
      center: _feedCenterKey,
      slivers: [
        if (anchor > 0)
          SliverPadding(
            // 역방향 슬라이버에서 top은 책의 맨 앞(화면 위쪽 끝) 여백이다.
            padding: EdgeInsets.fromLTRB(24, contentTop, 24, 0),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _feedProblemCard(
                  theme,
                  problems,
                  anchor - 1 - index,
                ),
                childCount: anchor,
              ),
            ),
          ),
        SliverPadding(
          key: _feedCenterKey,
          padding: EdgeInsets.fromLTRB(24, contentTop, 24, 16),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) =>
                  _feedProblemCard(theme, problems, anchor + index),
              childCount: problems.length - anchor,
            ),
          ),
        ),
      ],
    );
  }

  Widget _feedProblemCard(
    ThemeData theme,
    List<PageProblem> problems,
    int index,
  ) {
    final problem = problems[index];
    final divider = _feedSectionDivider(theme, problems, index);
    final card = _problemRow(
      theme,
      problem,
      showObjectiveButtons: false,
    );
    final child = divider == null
        ? card
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              divider,
              card,
            ],
          );
    if (problem.cropId != _selectedCropId) return child;
    return KeyedSubtree(key: _selectedCardKey, child: child);
  }

  String _feedTypeKey(PageProblem problem) {
    return '${problem.contentGroupKind}|${problem.contentGroupLabel}|${problem.contentGroupTitle}';
  }

  int? _feedPageKey(PageProblem problem) {
    return _problemPageMeta[problem.cropId]?.page.rawPage;
  }

  String? _feedPageLabel(PageProblem problem) {
    final page = _problemPageMeta[problem.cropId]?.page;
    if (page == null) return null;
    return 'p.${page.shownPage}';
  }

  /// 번호 목록 구분선. 유형은 왼쪽, 페이지는 오른쪽.
  /// 페이지 글자는 쪽이 바뀔 때만 붙인다.
  Widget? _feedSectionDivider(
    ThemeData theme,
    List<PageProblem> problems,
    int index,
  ) {
    if (index < 0 || index >= problems.length) return null;
    final current = problems[index];
    final previous = index > 0 ? problems[index - 1] : null;
    final typeChanged =
        previous == null || _feedTypeKey(current) != _feedTypeKey(previous);
    final pageChanged =
        previous == null || _feedPageKey(current) != _feedPageKey(previous);
    final typeLabel = typeChanged ? current.sectionTypeLabel : null;
    final pageLabel = pageChanged ? _feedPageLabel(current) : null;
    if ((typeLabel == null || typeLabel.isEmpty) &&
        (pageLabel == null || pageLabel.isEmpty)) {
      return null;
    }
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.hintColor,
      fontSize: 12,
      fontWeight: FontWeight.w700,
    );
    final lineColor = theme.dividerColor.withValues(alpha: 0.55);
    final typeMaxWidth = MediaQuery.sizeOf(context).width * 0.62;
    return Padding(
      padding: EdgeInsets.only(top: index == 0 ? 0 : 6, bottom: 8),
      child: Row(
        children: [
          if (typeLabel != null && typeLabel.isNotEmpty) ...[
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: typeMaxWidth),
              child: Text(
                typeLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Container(height: 1, color: lineColor),
          ),
          if (pageLabel != null && pageLabel.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(pageLabel, style: style),
          ],
        ],
      ),
    );
  }

  Widget _buildPagePanel(ThemeData theme, {required double topInset}) {
    final page = _page;
    if (page == null) {
      return Padding(
        padding: EdgeInsets.only(top: topInset),
        child: Center(
          child: Text(
            '왼쪽에서 풀고 싶은 페이지를 선택해 주세요.',
            style: theme.textTheme.bodyLarge?.copyWith(color: theme.hintColor),
          ),
        ),
      );
    }
    if (_loadingProblems) {
      return Padding(
        padding: EdgeInsets.only(top: topInset),
        child: const Center(child: YggLoadingIndicator()),
      );
    }
    final problems = _problems ?? const <PageProblem>[];
    if (problems.isEmpty && !(_paneMode == _PaneMode.body && _page != null)) {
      return Padding(
        padding: EdgeInsets.only(top: topInset),
        child: Center(
          child: Text(
            '이 페이지에는 풀 수 있는 문항이 없어요.',
            style: theme.textTheme.bodyLarge?.copyWith(color: theme.hintColor),
          ),
        ),
      );
    }

    PageProblem? selectedProblem;
    if (!(_paneMode == _PaneMode.body && (page.isConceptPage))) {
      for (final p in problems) {
        if (p.cropId == _selectedCropId) {
          selectedProblem = p;
          break;
        }
      }
    }

    final bottomInset = MediaQuery.paddingOf(context).bottom;
    const dividerH = 0.5;
    // GlobalKey 는 모드 전환 시 위젯 타입이 바뀌지 않도록 공통 래퍼에 둔다.
    final inputPanel = ColoredBox(
      key: _inputPanelKey,
      color: Colors.white,
      child: _TwoFingerHorizontalSwipe(
        onSwipe: (delta) => unawaited(_moveProblem(delta)),
        onSwipeUp: _openScratchFromSwipe,
        onSwipeDown: _closeScratchFromSwipe,
        child: selectedProblem == null
            ? const _EmptyInputCard(message: '문항을 선택해 주세요.')
            : _isOnHold(selectedProblem.cropId)
                ? const _EmptyInputCard(
                    message: '신고한 문항이에요.\n선생님 확인 전까지 채점에서 제외돼요.',
                  )
                : selectedProblem.isObjective
                    ? _buildObjectiveInputPanel(theme, selectedProblem)
                    // 세트형은 문항 전체가 self로 올 수 있어도, 파트별 mode만 본다.
                    : _usesSelfCheckInput(selectedProblem)
                        ? const _EmptyInputCard(
                            message: '이 문항은 카드의 정답 확인 버튼으로\n스스로 채점해 주세요.',
                          )
                        : _buildInputPanel(theme, selectedProblem),
      ),
    );
    const divider = SizedBox(
      height: dividerH,
      child: ColoredBox(color: Color(0x14000000)),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final body = switch (_paneMode) {
          _PaneMode.answers => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 2,
                  child: _buildAnswerFeed(theme, problems, topInset),
                ),
                divider,
                Expanded(
                  flex: 1,
                  child: inputPanel,
                ),
              ],
            ),
          _PaneMode.question => _buildQuestionPane(
              theme,
              selectedProblem,
              topInset: topInset,
              bottomInset: bottomInset,
            ),
          _PaneMode.body => _buildBodyPane(
              theme,
              selectedProblem,
              topInset: topInset,
              bottomInset: bottomInset,
            ),
        };

        return Stack(
          children: [
            body,
            // 연습장은 FAB 아래·콘텐츠 위에 깔고, FAB은 위에 남겨 노트로 닫을 수 있게 한다.
            AnimatedPositioned(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              left: 0,
              right: 0,
              bottom: 0,
              height: _scratchOpen ? _scratchHeight : 0,
              child: IgnorePointer(
                ignoring: !_scratchOpen,
                child: _TwoFingerHorizontalSwipe(
                  onSwipe: (delta) => unawaited(_moveProblem(delta)),
                  onSwipeUp: _openScratchFromSwipe,
                  onSwipeDown: _closeScratchFromSwipe,
                  child: _ScratchPracticeSheet(
                    key: _scratchKey,
                    onHandleTap: _onScratchHandleTap,
                    onHeightDrag: _onScratchHeightDrag,
                    onClose: () => setState(() => _scratchOpen = false),
                  ),
                ),
              ),
            ),
            if ((_paneMode == _PaneMode.question ||
                    _paneMode == _PaneMode.body) &&
                selectedProblem != null)
              Positioned(
                left: _solveEdgeInset,
                right: _solveEdgeInset + 132,
                bottom: bottomInset / 2 + 6,
                height: 52,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _buildQuestionBottomControls(theme, selectedProblem),
                ),
              ),
            Positioned(
              right: _solveEdgeInset,
              bottom: bottomInset / 2 + 6,
              child: _TextbookSolveFabBar(
                pendingCount: _pendingGradeCount,
                grading: _grading,
                onGrade: _grade,
                gradeLabel: _isTimedTest ? '제출' : '채점',
              ),
            ),
          ],
        );
      },
    );
  }

  /// 선택된 세트형 파트가 자기 채점(self) 파트인지.
  bool _selectedPartIsSelfCheck(PageProblem problem) {
    final partKey = _selectedPartKey;
    if (!problem.hasParts || partKey == null) return false;
    for (final part in problem.setParts) {
      if (part.key == partKey) return part.isSelfCheck;
    }
    return false;
  }

  /// 하단 입력을 막고 카드의 정답 확인을 쓸지.
  /// 세트형은 문항 전체 grading_mode(self)를 무시하고 선택 파트 mode만 본다.
  bool _usesSelfCheckInput(PageProblem problem) {
    if (problem.hasParts) return _selectedPartIsSelfCheck(problem);
    return problem.isSelfCheck;
  }

  Widget _buildInputModeButton() {
    final (svg, tooltip) = switch (_inputMode) {
      _InputMode.pencil => (_pencilModeSvg, '수식 입력으로 전환'),
      _InputMode.editor => (_formulaModeSvg, '키보드 입력으로 전환'),
      _InputMode.keyboard => (_keyboardModeSvg, '펜슬 입력으로 전환'),
    };
    return _SolveHeaderIconButton(
      tooltip: tooltip,
      svg: svg,
      onPressed: _cycleInputMode,
    );
  }

  Widget _buildReportIconButton(PageProblem problem) {
    return _SolveHeaderIconButton(
      tooltip: '신고',
      svg: _reportFlagSvg,
      onPressed: () => _reportProblem(problem),
    );
  }

  Widget _buildQuestionBottomControls(ThemeData theme, PageProblem problem) {
    const accent = YggGlassTokens.confirmActionColor;
    const wrongColor = Color(0xFFE57373);
    const cautionColor = Color(0xFFE0A63C);
    final held = _isOnHold(problem.cropId);
    final partKey = problem.hasParts ? _selectedPartKey : null;
    final answerKey = _answerKeyOf(problem.cropId, partKey);
    final answer = _answers[answerKey] ?? '';
    final result = _results[answerKey];
    final attemptCount = _attemptCounts[problem.cropId] ?? 0;
    final usesSelfCheck = _usesSelfCheckInput(problem);
    final graded = result != null &&
        (_selfGraded.contains(answerKey) ||
            (usesSelfCheck && attemptCount > 0) ||
            _gradedAnswers[answerKey] == answer);
    final revisionColor = attemptCount >= 5
        ? wrongColor
        : attemptCount >= 3
            ? cautionColor
            : accent;
    final setGroup = _independentSetGroupFor(problem);
    final inGroupedSet =
        (setGroup != null && setGroup.length > 1) || _paneMode == _PaneMode.body;
    final activeNumberPrefix = inGroupedSet
        ? '${_displayProblemNumber(problem)}번  '
        : '';

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildReportIconButton(problem),
        if (_paneMode != _PaneMode.body &&
            !held &&
            !problem.isObjective &&
            !usesSelfCheck) ...[
          const SizedBox(width: 2),
          _buildInputModeButton(),
        ],
        if (inGroupedSet && !_isRecognizing(answerKey) && answer.isEmpty && !held && !problem.isSelfCheck && !graded) ...[
          const SizedBox(width: 8),
          IgnorePointer(
            child: Text(
              '${_displayProblemNumber(problem)}번',
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.45),
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
        if (held) ...[
          const SizedBox(width: 8),
          IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: cautionColor.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$activeNumberPrefix검토 중',
                style: const TextStyle(
                  color: cautionColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ] else ...[
          if (!problem.hasParts && problem.isSelfCheck) ...[
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: result == true ? null : () => _selfCheck(problem),
              style: OutlinedButton.styleFrom(
                foregroundColor: graded ? theme.hintColor : accent,
                side: BorderSide(
                  color: (graded ? theme.hintColor : accent)
                      .withValues(alpha: 0.5),
                ),
              ),
              icon: const Icon(Icons.visibility_outlined, size: 18),
              label: Text(result == true
                  ? '$activeNumberPrefix' '완료'
                  : graded
                      ? '$activeNumberPrefix' '다시 확인'
                      : '$activeNumberPrefix' '정답 확인'),
            ),
          ],
          if (_isRecognizing(answerKey)) ...[
            const SizedBox(width: 10),
            Flexible(
              child: IgnorePointer(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (activeNumberPrefix.isNotEmpty)
                      Text(
                        activeNumberPrefix,
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    _recognizingView(
                      fontSize: 17,
                      color: Colors.black,
                    ),
                  ],
                ),
              ),
            ),
          ] else if (answer.isNotEmpty) ...[
            const SizedBox(width: 10),
            Flexible(
              child: IgnorePointer(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (activeNumberPrefix.isNotEmpty)
                      Text(
                        activeNumberPrefix,
                        style: const TextStyle(
                          color: Colors.black54,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    Flexible(
                      child: problem.isObjective
                          ? Text(
                              _objectiveAnswerText(answer),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.black,
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                height: 1.1,
                              ),
                            )
                          : FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: _answerMathView(
                                answerKey,
                                answer,
                                fontSize: 19,
                                color: Colors.black,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (graded && result && attemptCount > 1) ...[
            const SizedBox(width: 8),
            IgnorePointer(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: revisionColor.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '수정 · $attemptCount회',
                  style: TextStyle(
                    color: revisionColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ] else if (graded && !result) ...[
            const SizedBox(width: 8),
            const IgnorePointer(
              child: Text(
                '다시 풀기',
                style: TextStyle(
                  color: wrongColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildQuestionPane(
    ThemeData theme,
    PageProblem? problem, {
    required double topInset,
    required double bottomInset,
  }) {
    if (problem == null) {
      return ColoredBox(
        color: Colors.white,
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: const Center(child: Text('표시할 문항이 없어요.')),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final baseBehavior = ScrollConfiguration.of(context);
        final scrollDragDevices = _inputMode == _InputMode.pencil
            ? baseBehavior.dragDevices
                .where((kind) =>
                    kind != PointerDeviceKind.stylus &&
                    kind != PointerDeviceKind.invertedStylus)
                .toSet()
            : baseBehavior.dragDevices;
        final setGroup = _independentSetGroupFor(problem);
        final zoomResetToken = setGroup != null
            ? 'qset|${setGroup.first.cropId}'
            : 'q|${problem.cropId}';
        return ColoredBox(
          color: Colors.white,
          child: ScrollConfiguration(
            behavior: baseBehavior.copyWith(
              scrollbars: false,
              dragDevices: scrollDragDevices,
            ),
            child: _ZoomableSolvePane(
              scrollController: _questionScrollController,
              viewportWidth: constraints.maxWidth,
              viewportHeight: constraints.maxHeight,
              resetToken: zoomResetToken,
              onSwipe: (delta) => unawaited(_moveProblem(delta)),
              onSwipeUp: _openScratchFromSwipe,
              onSwipeDown: _closeScratchFromSwipe,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: constraints.maxWidth,
                  minHeight: constraints.maxHeight,
                ),
                child: _buildQuestionSolveCard(
                  theme,
                  problem,
                  topInset: topInset,
                  bottomInset: bottomInset,
                  viewportHeight: constraints.maxHeight,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildQuestionSolveCard(
    ThemeData theme,
    PageProblem problem, {
    required double topInset,
    required double bottomInset,
    required double viewportHeight,
  }) {
    final setGroup = _independentSetGroupFor(problem);
    if (setGroup != null) {
      return _buildIndependentSetQuestionCard(
        theme,
        setGroup,
        selectedProblem: problem,
        topInset: topInset,
        bottomInset: bottomInset,
        viewportHeight: viewportHeight,
      );
    }
    const cautionColor = Color(0xFFE0A63C);
    final held = _isOnHold(problem.cropId);
    final partKey = problem.hasParts ? _selectedPartKey : null;
    final answerKey = _answerKeyOf(problem.cropId, partKey);
    final answer = _answers[answerKey] ?? '';
    final result = _results[answerKey];
    final usesSelfCheck = _usesSelfCheckInput(problem);
    final canInputSubjective =
        !held && !problem.isObjective && !usesSelfCheck && result != true;
    final canInputObjective = !held && problem.isObjective && result != true;
    final selectedObjectives = !problem.isObjective
        ? const <int>{}
        : (_answers[problem.cropId] ?? '')
            .split(',')
            .map((s) => int.tryParse(s.trim()))
            .whereType<int>()
            .toSet();

    final pdfContent = _buildProblemPdf(
      theme,
      isObjective: problem.isObjective,
      selectedChoices: selectedObjectives,
      onToggleChoice: canInputObjective
          ? (choice, {List<Offset>? pencilStroke}) => _toggleObjective(
                problem.cropId,
                choice,
                pencilStroke: pencilStroke,
              )
          : null,
      pencilMarks:
          _objectivePencilMarks[problem.cropId] ?? const <int, List<Offset>>{},
      fallbackChoiceSelector: problem.isObjective
          ? Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 16),
              child: Center(
                child: Transform.translate(
                  offset: Offset.zero,
                  child: _objectiveButtons(theme, problem, translateY: 0),
                ),
              ),
            )
          : null,
    );

    final noteFlags = (!held && result != null)
        ? (_flags[answerKey] ?? const <String>[])
            .where(_flagMessages.containsKey)
            .toList(growable: false)
        : const <String>[];

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

    final topPad = _answerListTop(topInset);
    final bottomPad = bottomInset + 84;
    final hasTopRows = noteFlags.isNotEmpty || (problem.hasParts && !held);
    final canvasMinHeight = math.max(
      240.0,
      viewportHeight - (hasTopRows ? topPad + 120 : 0),
    );

    Widget pdfSection = Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        hasTopRows ? 12 : topPad,
        24,
        bottomPad,
      ),
      child: pdfContent,
    );

    if (canInputSubjective && _inputMode == _InputMode.pencil) {
      pdfSection = Stack(
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: double.infinity,
              minHeight: canvasMinHeight,
            ),
            child: pdfSection,
          ),
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) => PencilInputPad(
                key: _pencilKey,
                height: constraints.maxHeight,
                showControls: false,
                showEmptyHint: false,
                embedded: true,
                stylusOnly: true,
                candidateSelector: (candidates) =>
                    pickPlausibleHandwritingCandidate(
                  candidates,
                  answerKind: problem.answerKind,
                ),
                remoteRecognizer: (png) =>
                    TextbookApi.instance.recognizeHandwriting(
                  imageBase64: base64Encode(png),
                  answerKind: problem.answerKind,
                ),
                onSnapshot: (payload) {
                  _handwritingSnapshots[problem.cropId] = <String, dynamic>{
                    ...payload,
                    'input_mode': _InputMode.pencil.name,
                  };
                },
                onRecognizingChanged: (busy) =>
                    _setRecognizing(answerKey, busy),
                onRecognized: (text, {sourceLatex}) => _setAnswer(
                  answerKey,
                  text,
                  displayLatex: sourceLatex,
                ),
              ),
            ),
          ),
        ],
      );
    }

    return ColoredBox(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasTopRows) SizedBox(height: topPad),
          for (final flag in noteFlags)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: _flagNote(theme, flag, problem, color: cautionColor),
            ),
          if (problem.hasParts && !held) ...[
            for (final part in problem.setParts)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: _setPartRow(theme, problem, part),
              ),
            const SizedBox(height: 4),
          ],
          pdfSection,
          if (canInputSubjective && _inputMode == _InputMode.editor) ...[
            Divider(
              height: 1,
              thickness: 0.5,
              color: theme.dividerColor.withValues(alpha: 0.25),
            ),
            Theme(
              data: inputTheme,
              child: Padding(
                padding: EdgeInsets.fromLTRB(24, 16, 24, bottomPad),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MathExpressionEditor(
                      key: _editorKey,
                      initialLinear: answer,
                      onChanged: (linear) => _setAnswer(answerKey, linear),
                    ),
                    const SizedBox(height: 8),
                    MathKeypad(
                      onInsert: (t) => _editorKey.currentState?.insertText(t),
                      onFraction: () =>
                          _editorKey.currentState?.insertFraction(),
                      onSqrt: () => _editorKey.currentState?.insertSqrt(),
                      onNthRoot: () => _editorKey.currentState?.insertNthRoot(),
                      onPower: () => _editorKey.currentState?.insertPower(),
                      onRepeatingDot: () =>
                          _editorKey.currentState?.insertRepeatingDot(),
                      onBackspace: () => _editorKey.currentState?.backspace(),
                      onClear: () => _editorKey.currentState?.clearAll(),
                    ),
                  ],
                ),
              ),
            ),
          ] else if (canInputSubjective &&
              _inputMode == _InputMode.keyboard) ...[
            Divider(
              height: 1,
              thickness: 0.5,
              color: theme.dividerColor.withValues(alpha: 0.25),
            ),
            Theme(
              data: inputTheme,
              child: Padding(
                padding: EdgeInsets.fromLTRB(24, 12, 24, bottomPad),
                child: TextField(
                  controller: _keyboardController,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 4,
                  onChanged: (text) => _setAnswer(answerKey, text),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: const Color(0xFF17201F),
                  ),
                  decoration: const InputDecoration(
                    hintText: '한글 답(예: 제2사분면, 유한소수)을 입력해 주세요',
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildIndependentSetQuestionCard(
    ThemeData theme,
    List<PageProblem> group, {
    required PageProblem selectedProblem,
    required double topInset,
    required double bottomInset,
    required double viewportHeight,
  }) {
    final topPad = _answerListTop(topInset);
    final bottomPad = bottomInset + 84;
    final setView = _problemSetView;

    if (_loadingProblemSetView && setView == null) {
      return ColoredBox(
        color: Colors.white,
        child: Padding(
          padding: EdgeInsets.only(top: topPad),
          child: const SizedBox(
            height: 200,
            child: Center(child: YggLoadingIndicator()),
          ),
        ),
      );
    }
    final error = _problemSetViewError;
    if (error != null && setView == null) {
      return ColoredBox(
        color: Colors.white,
        child: Padding(
          padding: EdgeInsets.only(top: topPad),
          child: _problemViewMessage(
            theme,
            _problemViewErrorMessage(error),
            icon: Icons.error_outline_rounded,
          ),
        ),
      );
    }

    final itemViewByCropId = <String, StudentTextbookProblemSetItemView>{
      for (final item in setView?.items ?? const <StudentTextbookProblemSetItemView>[])
        item.cropId: item,
    };
    final commonUrl = setView?.commonPdfUrl;
    final commonUri = commonUrl == null ? null : Uri.tryParse(commonUrl);

    final selectedHeld = _isOnHold(selectedProblem.cropId);
    final selectedAnswer = _answers[selectedProblem.cropId] ?? '';
    final selectedResult = _results[selectedProblem.cropId];
    final canInputSelectedSubjective = !selectedHeld &&
        !selectedProblem.isObjective &&
        !selectedProblem.isSelfCheck &&
        selectedResult != true;

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

    var firstPencilIdx = -1;
    if (_inputMode == _InputMode.pencil) {
      for (var i = 0; i < group.length; i++) {
        final it = group[i];
        final held = _isOnHold(it.cropId);
        final res = _results[it.cropId];
        if (!held && !it.isObjective && !it.isSelfCheck && res != true) {
          firstPencilIdx = i;
          break;
        }
      }
    }

    return ColoredBox(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: topPad),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
            child: commonUri != null
                ? _RenderedProblemPdfPage(
                    key: ValueKey<String>(
                      'set-common|${setView!.commonCropId}|$commonUrl',
                    ),
                    uri: commonUri,
                    isObjective: false,
                    verticalInset: 0,
                  )
                : const SizedBox(
                    height: 60,
                    child: Center(child: YggLoadingIndicator()),
                  ),
          ),
          for (var idx = 0; idx < group.length; idx++)
            _buildIndependentSetSubItem(
              theme,
              group[idx],
              itemView: itemViewByCropId[group[idx].cropId],
              bodyPdfUrl: setView?.bodyPdfUrl,
              isLast: idx == group.length - 1,
              bottomPad: bottomPad,
              showPencilError: idx == firstPencilIdx,
            ),
          if (canInputSelectedSubjective && _inputMode == _InputMode.editor) ...[
            Divider(
              height: 1,
              thickness: 0.5,
              color: theme.dividerColor.withValues(alpha: 0.25),
            ),
            Theme(
              data: inputTheme,
              child: Padding(
                padding: EdgeInsets.fromLTRB(24, 16, 24, bottomPad),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MathExpressionEditor(
                      key: _editorKey,
                      initialLinear: selectedAnswer,
                      onChanged: (linear) =>
                          _setAnswer(selectedProblem.cropId, linear),
                    ),
                    const SizedBox(height: 8),
                    MathKeypad(
                      onInsert: (t) => _editorKey.currentState?.insertText(t),
                      onFraction: () =>
                          _editorKey.currentState?.insertFraction(),
                      onSqrt: () => _editorKey.currentState?.insertSqrt(),
                      onNthRoot: () => _editorKey.currentState?.insertNthRoot(),
                      onPower: () => _editorKey.currentState?.insertPower(),
                      onRepeatingDot: () =>
                          _editorKey.currentState?.insertRepeatingDot(),
                      onBackspace: () => _editorKey.currentState?.backspace(),
                      onClear: () => _editorKey.currentState?.clearAll(),
                    ),
                  ],
                ),
              ),
            ),
          ] else if (canInputSelectedSubjective &&
              _inputMode == _InputMode.keyboard) ...[
            Divider(
              height: 1,
              thickness: 0.5,
              color: theme.dividerColor.withValues(alpha: 0.25),
            ),
            Theme(
              data: inputTheme,
              child: Padding(
                padding: EdgeInsets.fromLTRB(24, 12, 24, bottomPad),
                child: TextField(
                  controller: _keyboardController,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 4,
                  onChanged: (text) => _setAnswer(selectedProblem.cropId, text),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: const Color(0xFF17201F),
                  ),
                  decoration: InputDecoration(
                    hintText:
                        '${_displayProblemNumber(selectedProblem)}번 답을 입력해 주세요',
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildIndependentSetSubItem(
    ThemeData theme,
    PageProblem item, {
    required StudentTextbookProblemSetItemView? itemView,
    required String? bodyPdfUrl,
    required bool isLast,
    required double bottomPad,
    required bool showPencilError,
  }) {
    const accent = YggGlassTokens.confirmActionColor;
    const cautionColor = Color(0xFFE0A63C);
    final held = _isOnHold(item.cropId);
    final answer = _answers[item.cropId] ?? '';
    final result = _results[item.cropId];
    final attemptCount = _attemptCounts[item.cropId] ?? 0;
    final graded = result != null &&
        (_selfGraded.contains(item.cropId) ||
            (item.isSelfCheck && attemptCount > 0) ||
            _gradedAnswers[item.cropId] == answer);
    final canInputSubjective =
        !held && !item.isObjective && !item.isSelfCheck && result != true;
    final canInputObjective = !held && item.isObjective && result != true;
    final selectedObjectives = !item.isObjective
        ? const <int>{}
        : answer
            .split(',')
            .map((s) => int.tryParse(s.trim()))
            .whereType<int>()
            .toSet();
    final noteFlags = (!held && result != null)
        ? (_flags[item.cropId] ?? const <String>[])
            .where(_flagMessages.containsKey)
            .toList(growable: false)
        : const <String>[];

    final fallbackSelector = item.isObjective
        ? Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 12),
            child: Center(
              child: Transform.translate(
                offset: Offset.zero,
                child: _objectiveButtons(theme, item, translateY: 0),
              ),
            ),
          )
        : null;

    final numberText =
        _isTimedTest ? null : '${_displayProblemNumber(item).trim()}.';
    final itemUrl = itemView?.pdfUrl;
    final itemUri = itemUrl == null ? null : Uri.tryParse(itemUrl);
    final fallbackBodyUri =
        bodyPdfUrl == null ? null : Uri.tryParse(bodyPdfUrl);
    final hasPdfSurface =
        itemUri != null || (fallbackBodyUri != null && itemView?.rawPage != null);
    final Widget pdfWidget;
    if (itemUri != null) {
      pdfWidget = _RenderedProblemPdfPage(
        key: ValueKey<String>(
          'set-item|${item.cropId}|$itemUrl',
        ),
        uri: itemUri,
        isObjective: item.isObjective,
        selectedChoices: selectedObjectives,
        onToggleChoice: canInputObjective
            ? (choice, {List<Offset>? pencilStroke}) => _toggleObjective(
                  item.cropId,
                  choice,
                  pencilStroke: pencilStroke,
                )
            : null,
        pencilMarks:
            _objectivePencilMarks[item.cropId] ?? const <int, List<Offset>>{},
        fallbackChoiceSelector: fallbackSelector,
        verticalInset: 0,
        headerLabel: numberText,
        gradedResult: graded ? result : null,
        gradeSeed: item.cropId.hashCode,
      );
    } else if (fallbackBodyUri != null && itemView?.rawPage != null) {
      pdfWidget = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (numberText != null)
            Padding(
              padding: const EdgeInsets.only(left: 10, bottom: 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _RedPencilGradeMark(
                  gradedResult: graded ? result : null,
                  seed: item.cropId.hashCode,
                  child: Text(
                    numberText,
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          _FallbackProblemPdfPage(
            uri: fallbackBodyUri,
            pageNumber: itemView!.rawPage!,
            itemRegion1k: itemView.itemRegion1k,
            isObjective: item.isObjective,
            selectedChoices: selectedObjectives,
            onToggleChoice: canInputObjective
                ? (choice, {List<Offset>? pencilStroke}) => _toggleObjective(
                      item.cropId,
                      choice,
                      pencilStroke: pencilStroke,
                    )
                : null,
            pencilMarks:
                _objectivePencilMarks[item.cropId] ?? const <int, List<Offset>>{},
            fallbackChoiceSelector: fallbackSelector,
          ),
        ],
      );
    } else {
      pdfWidget = const SizedBox(
        height: 54,
        child: Center(child: YggLoadingIndicator()),
      );
    }

    final itemGapBottom = isLast ? bottomPad : 44.0;
    final content = Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, itemGapBottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final flag in noteFlags)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _flagNote(theme, flag, item, color: cautionColor),
            ),
          pdfWidget,
        ],
      ),
    );

    final recognizing = _isRecognizing(item.cropId);
    final showStatusPill = held ||
        recognizing ||
        (item.isSelfCheck && result != true) ||
        (!item.isObjective && answer.isNotEmpty);

    return Stack(
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: double.infinity,
            minHeight: isLast ? 140.0 : 58.0,
          ),
          child: content,
        ),
        if (hasPdfSurface && canInputSubjective && _inputMode == _InputMode.pencil)
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) => PencilInputPad(
                key: _setPencilKeyFor(item.cropId),
                height: constraints.maxHeight,
                showControls: false,
                showEmptyHint: false,
                showModelError: showPencilError,
                embedded: true,
                stylusOnly: true,
                onStrokeStart: () => _focusSetSubProblem(item),
                candidateSelector: (candidates) =>
                    pickPlausibleHandwritingCandidate(
                  candidates,
                  answerKind: item.answerKind,
                ),
                remoteRecognizer: (png) =>
                    TextbookApi.instance.recognizeHandwriting(
                  imageBase64: base64Encode(png),
                  answerKind: item.answerKind,
                ),
                onSnapshot: (payload) {
                  _handwritingSnapshots[item.cropId] = <String, dynamic>{
                    ...payload,
                    'input_mode': _InputMode.pencil.name,
                  };
                },
                onRecognizingChanged: (busy) =>
                    _setRecognizing(item.cropId, busy),
                onRecognized: (text, {sourceLatex}) => _setAnswer(
                  item.cropId,
                  text,
                  displayLatex: sourceLatex,
                ),
              ),
            ),
          )
        else
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _focusSetSubProblem(item),
            ),
          ),
        if (showStatusPill)
          Positioned(
            right: 24,
            bottom: isLast ? math.max(12.0, bottomPad - 28) : 4,
            child: IgnorePointer(
              ignoring: !item.isSelfCheck || result == true || held,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (held)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: cautionColor.withValues(alpha: 0.13),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        '검토 중',
                        style: TextStyle(
                          color: cautionColor,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    )
                  else ...[
                    if (recognizing)
                      _recognizingView(fontSize: 13, color: Colors.black54)
                    else if (!item.isObjective && answer.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: _answerMathView(
                          item.cropId,
                          answer,
                          fontSize: 15,
                          color: Colors.black87,
                        ),
                      ),
                    if (item.isSelfCheck && result != true) ...[
                      const SizedBox(width: 6),
                      OutlinedButton(
                        onPressed: () => _selfCheck(item),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: graded ? theme.hintColor : accent,
                          side: BorderSide(
                            color: (graded ? theme.hintColor : accent)
                                .withValues(alpha: 0.45),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          graded ? '다시 확인' : '정답 확인',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  ({List<TbPageStat> pages, String pathLabel}) _currentUnitBodyPages({
    int? forRawPage,
  }) {
    final tree = _tree;
    final targetRaw = forRawPage ?? _page?.rawPage;
    if (tree == null || targetRaw == null) {
      return (pages: const <TbPageStat>[], pathLabel: _pagePathLabel);
    }
    final scope = widget.homework;
    final current = _page;
    for (final big in tree.bigUnits) {
      for (final mid in big.mids) {
        for (final small in mid.smalls) {
          final matchesUnit = forRawPage != null ||
              current == null ||
              (big.order == current.bigOrder &&
                  mid.order == current.midOrder &&
                  small.subKey == current.subKey);
          if (matchesUnit &&
              small.pages.any((p) => p.rawPage == targetRaw)) {
            final pathLabel =
                '${mid.name} · ${small.name.isEmpty ? small.subKey : small.name}';
            final visible = <TbPageStat>[
              for (final p in small.pages)
                if (p.isConceptPage ||
                    scope == null ||
                    scope.rawPages.contains(p.rawPage))
                  p,
            ];
            return (pages: visible, pathLabel: pathLabel);
          }
        }
      }
    }
    return (pages: const <TbPageStat>[], pathLabel: _pagePathLabel);
  }

  /// 원본보기: 문항보기와 동일한 제스쳐·입력 구조로 원본 PDF 페이지를 보여 주고
  /// 문항 좌표(`item_region_1k`) 근처 필기·선지 체크를 해당 문항에 매칭한다.
  Widget _buildBodyPane(
    ThemeData theme,
    PageProblem? problem, {
    required double topInset,
    required double bottomInset,
  }) {
    final currentPage = _page;
    if (problem == null && currentPage == null) {
      return ColoredBox(
        color: Colors.white,
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: const Center(child: Text('표시할 문항이 없어요.')),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final baseBehavior = ScrollConfiguration.of(context);
        final scrollDragDevices = baseBehavior.dragDevices
            .where((kind) =>
                kind != PointerDeviceKind.stylus &&
                kind != PointerDeviceKind.invertedStylus)
            .toSet();
        final bottomPad = bottomInset + 84;

        return ColoredBox(
          color: Colors.white,
          child: ScrollConfiguration(
            behavior: baseBehavior.copyWith(
              scrollbars: false,
              dragDevices: scrollDragDevices,
            ),
            child: _ZoomableSolvePane(
              scrollController: _bodyScrollController,
              viewportWidth: constraints.maxWidth,
              viewportHeight: constraints.maxHeight,
              resetToken: 'body|${currentPage?.rawPage}',
              onSwipe: (delta) => unawaited(_moveProblem(delta)),
              onSwipeUp: _openScratchFromSwipe,
              onSwipeDown: _closeScratchFromSwipe,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: constraints.maxWidth,
                  minHeight: constraints.maxHeight,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: _islandBottom(context)),
                    _buildBodyPdf(
                      theme,
                      selectedProblem: problem,
                      viewportWidth: constraints.maxWidth,
                    ),
                    SizedBox(height: bottomPad),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  List<PageProblem> _bodyProblemsOnPage(int rawPage) {
    if (_page?.rawPage == rawPage && _page?.isConceptPage == true) {
      return const <PageProblem>[];
    }
    final problems = _problems ?? const <PageProblem>[];
    final out = <PageProblem>[
      for (final p in problems)
        if (_problemPageMeta[p.cropId]?.page.rawPage == rawPage) p,
    ];
    if (out.isNotEmpty) return out;
    final selected = _selectedProblem();
    return selected == null ? const <PageProblem>[] : <PageProblem>[selected];
  }

  Widget _buildBodyPdf(
    ThemeData theme, {
    required PageProblem? selectedProblem,
    required double viewportWidth,
  }) {
    if (_loadingProblemView) {
      return const SizedBox(
        height: 220,
        child: Center(child: YggLoadingIndicator()),
      );
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
    if (view.isQueued &&
        (view.bodyPdfUrl == null || view.bodyPdfUrl!.isEmpty)) {
      return _problemViewMessage(
        theme,
        '교재 PDF를 준비하고 있어요.\n잠시 후 다시 시도해 주세요.',
        icon: Icons.hourglass_top_rounded,
      );
    }
    final pageUri = view.hasBodyPagePdf
        ? Uri.tryParse(view.bodyPagePdfUrl!)
        : null;
    final rawPage = view.rawPage ?? _page?.rawPage;
    if (rawPage == null || rawPage < 1) {
      return _problemViewMessage(
        theme,
        '원본 교재 PDF를 열 수 없어요.',
        icon: Icons.menu_book_outlined,
      );
    }
    final Uri? uri;
    final int targetPage;
    final bool isSinglePagePdf;
    final String keyId;
    if (pageUri != null) {
      uri = pageUri;
      targetPage = 1;
      isSinglePagePdf = true;
      keyId = 'body-page|${view.bodyPagePdfUrl}';
    } else {
      uri = _stableBodyBookUri(view);
      if (uri == null) {
        return _problemViewMessage(
          theme,
          '원본 교재 PDF를 열 수 없어요.',
          icon: Icons.menu_book_outlined,
        );
      }
      targetPage = rawPage;
      isSinglePagePdf = false;
      final cacheId = view.bodyCacheKey ?? uri.toString();
      keyId = 'body-full|$cacheId|$rawPage';
    }

    final pageProblems = _bodyProblemsOnPage(rawPage);
    final regionsByCrop = <String, List<int>>{
      ...?_bodyRegionsByPage[rawPage],
    };
    if (selectedProblem != null &&
        view.itemRegion1k != null &&
        view.itemRegion1k!.length == 4) {
      regionsByCrop[selectedProblem.cropId] ??= view.itemRegion1k!;
    }
    final problemByCrop = <String, PageProblem>{
      for (final p in pageProblems) p.cropId: p,
    };

    return _BodyPageSolveView(
      key: ValueKey<String>(keyId),
      uri: uri,
      pageNumber: targetPage,
      rawPage: rawPage,
      isSinglePagePdf: isSinglePagePdf,
      viewportWidth: viewportWidth,
      problemsOnPage: pageProblems,
      regionsByCrop: regionsByCrop,
      numberBoxesByCrop: _bodyNumberBoxesByPage[rawPage] ??
          const <String, List<int>>{},
      choiceRegionsByCrop: _bodyChoiceRegionsByPage[rawPage] ??
          const <String, Map<int, List<int>>>{},
      bodyPencilKey: _bodyPencilKeyFor(rawPage),
      answers: _answers,
      results: _results,
      gradedResultOf: _gradedResultOf,
      attemptCounts: _attemptCounts,
      recognizingAnswerKeys: _recognizingAnswerKeys,
      objectivePencilMarks: _objectivePencilMarks,
      isOnHold: _isOnHold,
      usesSelfCheck: _usesSelfCheckInput,
      displayNumberOf: _displayProblemNumber,
      answerKeyOf: (cropId) {
        final p = problemByCrop[cropId];
        return _answerKeyOf(
          cropId,
          p != null && p.hasParts ? _selectedPartKey : null,
        );
      },
      answerMathBuilder: (key, ans) => _answerMathView(
        key,
        ans,
        fontSize: 13.5,
        color: Colors.black87,
      ),
      onSelfCheck: (p) => unawaited(_selfCheck(p)),
      onFocusProblem: _focusBodyProblem,
      onToggleChoice: (cropId, choice, {List<Offset>? pencilStroke}) =>
          _toggleObjective(cropId, choice, pencilStroke: pencilStroke),
      onRecognizingChanged: _setRecognizing,
      onSnapshot: (cropId, payload) {
        _handwritingSnapshots[cropId] = <String, dynamic>{
          ...payload,
          'input_mode': _InputMode.pencil.name,
        };
      },
      onRecognized: (cropId, text, {sourceLatex}) {
        final p = problemByCrop[cropId];
        final key = _answerKeyOf(
          cropId,
          p != null && p.hasParts ? _selectedPartKey : null,
        );
        _setAnswer(key, text, displayLatex: sourceLatex);
      },
      onDocumentReady: isSinglePagePdf
          ? null
          : () {
              _bodyFullDocReady = true;
            },
    );
  }

  Widget _buildProblemPdf(
    ThemeData theme, {
    bool isObjective = false,
    Set<int> selectedChoices = const <int>{},
    _ObjectiveChoiceToggle? onToggleChoice,
    Map<int, List<Offset>> pencilMarks = const <int, List<Offset>>{},
    Widget? fallbackChoiceSelector,
  }) {
    if (_loadingProblemView) {
      return const SizedBox(
        height: 160,
        child: Center(child: YggLoadingIndicator()),
      );
    }
    final error = _problemViewError;
    if (error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _problemViewMessage(
            theme,
            _problemViewErrorMessage(error),
            icon: Icons.error_outline_rounded,
          ),
          if (fallbackChoiceSelector != null) fallbackChoiceSelector,
        ],
      );
    }
    final view = _problemView;
    if (view == null) {
      return _problemViewMessage(theme, '문항을 선택해 주세요.');
    }
    if (view.isQueued) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _problemViewMessage(
            theme,
            '문항 PDF를 준비하고 있어요.\n잠시 후 문항을 다시 선택해 주세요.',
            icon: Icons.hourglass_top_rounded,
          ),
          if (fallbackChoiceSelector != null) fallbackChoiceSelector,
        ],
      );
    }
    final useSingleBodyPage = view.isFallback && view.hasBodyPagePdf;
    final url = useSingleBodyPage
        ? view.bodyPagePdfUrl
        : (view.isFallback ? (view.bodyPdfUrl ?? view.pdfUrl) : view.pdfUrl);
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _problemViewMessage(
            theme,
            view.isFallback ? '원본 교재 PDF를 열 수 없어요.' : '준비된 문항 PDF를 열 수 없어요.',
            icon: Icons.error_outline_rounded,
          ),
          if (fallbackChoiceSelector != null) fallbackChoiceSelector,
        ],
      );
    }
    final fallbackPage = useSingleBodyPage
        ? 1
        : (view.isFallback ? view.rawPage : null);
    return _ProblemPdfView(
      key: ValueKey<String>(
        '${view.status.name}|$url|$fallbackPage|${view.itemRegion1k}',
      ),
      uri: uri,
      fallbackPage: fallbackPage,
      itemRegion1k: view.isFallback ? view.itemRegion1k : null,
      isObjective: isObjective,
      selectedChoices: selectedChoices,
      onToggleChoice: onToggleChoice,
      pencilMarks: pencilMarks,
      fallbackChoiceSelector: fallbackChoiceSelector,
    );
  }

  Widget _problemViewMessage(
    ThemeData theme,
    String message, {
    IconData? icon,
  }) {
    // 스크롤 뷰(높이 비제한) 안에서도 시트가 콘텐츠 높이만 갖도록 Center 확장 금지.
    return Padding(
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

  /// 채점 플래그 안내 한 줄. form_differs 는 눌러서 답지 정답을
  /// 다이얼로그로 확인할 수 있다.
  Widget _flagNote(
    ThemeData theme,
    String flag,
    PageProblem problem, {
    required Color color,
    double iconSize = 15,
  }) {
    final note = _flagMessages[flag];
    if (note == null) return const SizedBox.shrink();
    final tappable = flag == 'form_differs';
    final row = Row(
      children: [
        Icon(Icons.info_outline_rounded, size: iconSize, color: color),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            note,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
        if (tappable)
          Text(
            '정답 확인하기',
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w800,
              decoration: TextDecoration.underline,
              decorationColor: color,
            ),
          ),
      ],
    );
    if (!tappable) return row;
    return InkWell(
      onTap: () => _showServedAnswer(problem),
      borderRadius: BorderRadius.circular(6),
      child: row,
    );
  }

  /// 개념원리·개념+유형 고등만 문항분류(필수유형 등)를 난이도/유형코드와 같은
  /// 회색 글씨로 표시.
  bool get _showCategoryLabel => const {'wonri', 'wonri_middle', 'gaeyu_high'}
      .contains(widget.book.series);

  /// 같은 문항을 다시 푸는 중이면 몇 번째인지 알려 준다.
  /// 처음 푸는 문항(1회차)은 굳이 표시하지 않는다.
  Widget _roundChip(ThemeData theme, PageProblem problem) {
    if (problem.roundNo < 2) return const SizedBox.shrink();
    const roundColor = Color(0xFF7E9CC9);
    return Padding(
      padding: const EdgeInsets.only(right: 9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: roundColor.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          '${problem.roundNo}회차',
          style: const TextStyle(
            color: roundColor,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  Widget _problemRow(
    ThemeData theme,
    PageProblem problem, {
    bool showObjectiveButtons = true,
  }) {
    if (problem.hasParts && !_isOnHold(problem.cropId)) {
      return _setProblemRow(theme, problem);
    }
    final isDark = theme.brightness == Brightness.dark;
    final answer = _answers[problem.cropId] ?? '';
    final result = _results[problem.cropId];
    final attemptCount = _attemptCounts[problem.cropId] ?? 0;
    final graded = result != null &&
        (_selfGraded.contains(problem.cropId) ||
            (problem.isSelfCheck &&
                (_attemptCounts[problem.cropId] ?? 0) > 0) ||
            _gradedAnswers[problem.cropId] == answer);
    final selected = _selectedCropId == problem.cropId;
    final held = _isOnHold(problem.cropId);
    const accent = YggGlassTokens.confirmActionColor;
    const wrongColor = Color(0xFFE57373);
    const cautionColor = Color(0xFFE0A63C);
    final revisionColor = attemptCount >= 5
        ? wrongColor
        : attemptCount >= 3
            ? cautionColor
            : accent;

    Color borderColor;
    if (held) {
      borderColor = cautionColor.withValues(alpha: 0.7);
    } else if (graded) {
      borderColor = result ? accent : wrongColor;
    } else if (selected) {
      borderColor = accent.withValues(alpha: 0.6);
    } else {
      borderColor = theme.dividerColor.withValues(alpha: 0.4);
    }

    final noteFlags = graded && !held
        ? (_flags[problem.cropId] ?? const <String>[])
            .where(_flagMessages.containsKey)
            .toList(growable: false)
        : const <String>[];

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: isDark ? Colors.white.withValues(alpha: 0.03) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          // 객관식도 선택 가능 — 하단/문항모드 대상이 바뀌어야 한다.
          // (객관식 답 자체는 카드·하단의 ①~⑤로 입력)
          onTap: held || result == true
              ? null
              : () => setState(() => _selectPro(problem)),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              // 두께는 항상 2 — 채점 시 1→2로 바뀌면 리스트가 흔들린다.
              border: Border.all(color: borderColor, width: 2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: _isTimedTest ? 96 : 64,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isTimedTest
                                ? '제 ${_timedIndex + 1}문제'
                                : _displayProblemNumber(problem),
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          if (!_isTimedTest && problem.label.isNotEmpty)
                            Text(
                              problem.label,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.hintColor),
                            ),
                          if (!_isTimedTest &&
                              _showCategoryLabel &&
                              problem.categoryLabel != null)
                            Text(
                              problem.categoryLabel!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.hintColor),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: held
                          ? Text(
                              '신고한 문항 · 선생님이 확인 중이에요',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: theme.hintColor,
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          : _isRecognizing(problem.cropId)
                              ? Align(
                                  alignment: Alignment.centerLeft,
                                  child: _recognizingView(
                                    fontSize:
                                        theme.textTheme.titleMedium?.fontSize ??
                                            16,
                                  ),
                                )
                              : problem.isObjective && showObjectiveButtons
                                  ? _objectiveButtons(theme, problem)
                                  : !problem.isObjective && answer.isNotEmpty
                                      // 주관식 답은 2D 조판 수식으로 보여준다.
                                      ? Align(
                                          alignment: Alignment.centerLeft,
                                          child: _answerMathView(
                                            problem.cropId,
                                            answer,
                                            fontSize: theme.textTheme
                                                    .titleMedium?.fontSize ??
                                                16,
                                          ),
                                        )
                                      : Text(
                                          problem.isObjective
                                              ? (answer.isEmpty
                                                  ? '객관식'
                                                  : _objectiveAnswerText(
                                                      answer))
                                              : (problem.isSelfCheck
                                                  ? '공책에 풀고 정답을 확인해 보세요'
                                                  : '답을 입력해 주세요'),
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                            color: answer.isEmpty
                                                ? theme.hintColor
                                                : null,
                                            fontWeight: FontWeight.w600,
                                            fontSize: problem.isObjective &&
                                                    answer.isNotEmpty
                                                ? (theme.textTheme.titleMedium
                                                            ?.fontSize ??
                                                        16) *
                                                    1.35
                                                : null,
                                          ),
                                        ),
                    ),
                    const SizedBox(width: 12),
                    if (held) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: cautionColor.withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          '검토 중',
                          style: TextStyle(
                            color: cautionColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 9),
                      const Icon(
                        Icons.flag_rounded,
                        size: 22,
                        color: cautionColor,
                      ),
                    ] else ...[
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
                      _roundChip(theme, problem),
                      if (graded && result && attemptCount > 1) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: revisionColor.withValues(alpha: 0.13),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '수정 · $attemptCount회',
                            style: TextStyle(
                              color: revisionColor,
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
                  ],
                ),
                for (final flag in noteFlags)
                  Padding(
                    padding: const EdgeInsets.only(left: 72, top: 6),
                    child: _flagNote(theme, flag, problem, color: cautionColor),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 세트형(종속형) 문항 카드 — 기본 접힘(요약 칩), 탭하면 파트별 행이 펼쳐진다.
  Widget _setProblemRow(ThemeData theme, PageProblem problem) {
    final isDark = theme.brightness == Brightness.dark;
    const accent = YggGlassTokens.confirmActionColor;
    const wrongColor = Color(0xFFE57373);
    const cautionColor = Color(0xFFE0A63C);
    final attemptCount = _attemptCounts[problem.cropId] ?? 0;
    final selected = _selectedCropId == problem.cropId;
    final expanded = _expandedSetCrops.contains(problem.cropId);

    var gradedParts = 0;
    var correctParts = 0;
    for (final part in problem.setParts) {
      final result = _results[_answerKeyOf(problem.cropId, part.key)];
      if (result != null) {
        gradedParts++;
        if (result) correctParts++;
      }
    }
    final totalParts = problem.setParts.length;
    final allCorrect = correctParts == totalParts;
    final anyWrong = correctParts < gradedParts;

    Color borderColor;
    if (allCorrect) {
      borderColor = accent;
    } else if (anyWrong) {
      borderColor = wrongColor;
    } else if (selected) {
      borderColor = accent.withValues(alpha: 0.6);
    } else {
      borderColor = theme.dividerColor.withValues(alpha: 0.4);
    }
    final revisionColor = attemptCount >= 5
        ? wrongColor
        : attemptCount >= 3
            ? cautionColor
            : accent;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: isDark ? Colors.white.withValues(alpha: 0.03) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          // 스플래시는 헤더가 아니라 카드 전체(화살표 포함)를 기준으로 퍼진다.
          // 이미 펼쳐진 입력 대상이면 다시 눌러 접고, 그 외에는 선택하며 펼친다.
          onTap: () => setState(() {
            final selected = _selectedCropId == problem.cropId;
            if (expanded && selected) {
              _expandedSetCrops.remove(problem.cropId);
              return;
            }
            _selectPro(problem);
          }),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              // 두께는 항상 2 — 채점 시 두께 변화로 레이아웃이 흔들리지 않게.
              border: Border.all(color: borderColor, width: 2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 64,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _displayProblemNumber(problem),
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                              fontWeight: FontWeight.w800),
                                    ),
                                    if (problem.label.isNotEmpty)
                                      Text(
                                        problem.label,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(color: theme.hintColor),
                                      ),
                                    if (_showCategoryLabel &&
                                        problem.categoryLabel != null)
                                      Text(
                                        problem.categoryLabel!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(color: theme.hintColor),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(child: _setSummaryChips(theme, problem)),
                              const SizedBox(width: 12),
                              _roundChip(theme, problem),
                              if (allCorrect && attemptCount > 1) ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                        revisionColor.withValues(alpha: 0.13),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    '수정 · $attemptCount회',
                                    style: TextStyle(
                                      color: revisionColor,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 9),
                              ],
                              if (allCorrect)
                                const Icon(
                                  Icons.circle_outlined,
                                  size: 26,
                                  color: accent,
                                )
                              else if (gradedParts > 0)
                                Text(
                                  '$correctParts/$totalParts',
                                  style: TextStyle(
                                    color: anyWrong ? wrongColor : accent,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: expanded ? '접기' : '펼치기',
                        onPressed: () => setState(() {
                          if (!_expandedSetCrops.remove(problem.cropId)) {
                            _expandedSetCrops.add(problem.cropId);
                          }
                        }),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                        icon: Icon(
                          expanded
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 22,
                          color: theme.hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
                if (expanded) ...[
                  Divider(
                    height: 1,
                    thickness: 0.5,
                    color: theme.dividerColor.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 8),
                  for (final part in problem.setParts)
                    _setPartRow(theme, problem, part),
                  const SizedBox(height: 4),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 접힌 세트형 카드의 파트 현황 요약 칩.
  Widget _setSummaryChips(ThemeData theme, PageProblem problem) {
    const accent = YggGlassTokens.confirmActionColor;
    const wrongColor = Color(0xFFE57373);
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: theme.hintColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '세트형 ${problem.setParts.length}',
            style: TextStyle(
              color: theme.hintColor,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        for (final part in problem.setParts)
          Builder(builder: (context) {
            final result = _results[_answerKeyOf(problem.cropId, part.key)];
            final color = result == null
                ? theme.hintColor
                : result
                    ? accent
                    : wrongColor;
            final mark = result == null ? '—' : (result ? '○' : '✕');
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: result == null
                    ? Colors.transparent
                    : color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: color.withValues(alpha: 0.45)),
              ),
              child: Text(
                '${part.key} $mark',
                style: TextStyle(
                  color: color,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            );
          }),
      ],
    );
  }

  /// 세트형 카드의 파트 행 — 탭하면 하단 입력이 이 파트를 대상으로 잡힌다.
  Widget _setPartRow(ThemeData theme, PageProblem problem, SetPartMeta part) {
    const accent = YggGlassTokens.confirmActionColor;
    const cautionColor = Color(0xFFE0A63C);
    final k = _answerKeyOf(problem.cropId, part.key);
    final answer = _answers[k] ?? '';
    final result = _results[k];
    final graded = result != null &&
        (part.isSelfCheck ||
            _selfGraded.contains(k) ||
            _gradedAnswers[k] == answer);
    final partSelected =
        _selectedCropId == problem.cropId && _selectedPartKey == part.key;

    final noteFlags = graded
        ? (_flags[k] ?? const <String>[])
            .where(_flagMessages.containsKey)
            .toList(growable: false)
        : const <String>[];

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: result == true
            ? null
            : () => setState(() => _selectPro(problem, partKey: part.key)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: partSelected
                ? accent.withValues(alpha: 0.06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: partSelected
                  ? accent.withValues(alpha: 0.55)
                  : theme.dividerColor.withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _RedPencilGradeMark(
                        gradedResult: graded ? result : null,
                        seed: k.hashCode,
                        scaleFactor: 0.78,
                        child: Text(
                          part.key,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: _isRecognizing(k)
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: _recognizingView(
                              fontSize:
                                  theme.textTheme.titleSmall?.fontSize ?? 14,
                            ),
                          )
                        : !part.isSelfCheck && answer.isNotEmpty
                            // 파트 답도 2D 조판 수식으로 보여준다.
                            ? Align(
                                alignment: Alignment.centerLeft,
                                child: _answerMathView(
                                  k,
                                  answer,
                                  fontSize:
                                      theme.textTheme.titleSmall?.fontSize ??
                                          14,
                                ),
                              )
                            : Text(
                                part.isSelfCheck
                                    ? (graded
                                        ? (result
                                            ? '맞았어요'
                                            : '틀렸어요 · 다시 확인해 보세요')
                                        : '공책에 풀고 정답을 확인해 보세요')
                                    : '답을 입력해 주세요',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: theme.hintColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                  ),
                  const SizedBox(width: 10),
                  if (part.isSelfCheck && result != true) ...[
                    OutlinedButton(
                      onPressed: () => _selfCheckPart(problem, part.key),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: graded ? theme.hintColor : accent,
                        side: BorderSide(
                          color: (graded ? theme.hintColor : accent)
                              .withValues(alpha: 0.5),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        minimumSize: const Size(0, 34),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text(graded ? '다시 확인' : '정답 확인'),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (!graded && answer.isNotEmpty)
                    Icon(Icons.edit_rounded, size: 16, color: theme.hintColor),
                ],
              ),
              for (final flag in noteFlags)
                Padding(
                  padding: const EdgeInsets.only(left: 44, top: 5),
                  child: _flagNote(
                    theme,
                    flag,
                    problem,
                    color: cautionColor,
                    iconSize: 14,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _objectiveButtons(
    ThemeData theme,
    PageProblem problem, {
    double translateY = -12,
  }) {
    final answer = _answers[problem.cropId] ?? '';
    final selected = answer
        .split(',')
        .where((s) => s.trim().isNotEmpty)
        .map(int.parse)
        .toSet();
    const accent = YggGlassTokens.confirmActionColor;
    final idle = theme.hintColor;

    // 유니코드 ① 은 글꼴 테두리 두께를 못 줄여서, 얇은 원 + 숫자로 그린다.
    // 이전 ① 크기(+50%)와 비슷한 지름.
    final diameter =
        (theme.textTheme.titleMedium?.fontSize ?? 16) * 1.5 * 1.1 * 1.25 * 1.5;
    final digitSize = diameter * 0.46;
    // 문항/정답 모드 공통: 살짝 위로.
    return Transform.translate(
      offset: Offset(0, translateY),
      child: Wrap(
        spacing: 8,
        children: [
          for (var n = 1; n <= 5; n++)
            InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => _toggleObjective(problem.cropId, n),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Container(
                  width: diameter,
                  height: diameter,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected.contains(n) ? accent : idle,
                      width: selected.contains(n) ? 3.8 : 3.2,
                    ),
                  ),
                  child: Text(
                    '$n',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: selected.contains(n) ? accent : idle,
                      fontSize: digitSize,
                      fontWeight: FontWeight.w700,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _objectiveAnswerText(String answer) {
    const circled = ['①', '②', '③', '④', '⑤'];
    return answer
        .split(',')
        .map((value) => int.tryParse(value.trim()))
        .whereType<int>()
        .where((number) => number >= 1 && number <= circled.length)
        .map((number) => circled[number - 1])
        .join(' ');
  }

  Widget _buildObjectiveInputPanel(
    ThemeData theme,
    PageProblem problem,
  ) {
    final answer = _answers[problem.cropId] ?? '';
    // 정답목록·문항모드 공통: 상단 상태/신고 + 하단 가운데 ①~⑤.
    return Container(
      color: Colors.white,
      child: Stack(
        children: [
          Positioned(
            left: 20,
            right: 20,
            bottom: 90,
            child: Center(child: _objectiveButtons(theme, problem)),
          ),
          Positioned(
            top: 12,
            left: 20,
            right: 20,
            child: Row(
              children: [
                Expanded(
                  child: IgnorePointer(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 8,
                      ),
                      child: Text(
                        '${_displayProblemNumber(problem)}번 답  ·  '
                        '${answer.isEmpty ? '입력 전' : _objectiveAnswerText(answer)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
                _buildReportIconButton(problem),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputPanel(ThemeData theme, PageProblem problem) {
    final partKey = problem.hasParts ? _selectedPartKey : null;
    final answerKey = _answerKeyOf(problem.cropId, partKey);
    final answer = _answers[answerKey] ?? '';
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
                      // null 반환(답 형태 후보 없음) 시 패드가 VLM 폴백을 탄다.
                      candidateSelector: (candidates) =>
                          pickPlausibleHandwritingCandidate(
                        candidates,
                        answerKind: problem.answerKind,
                      ),
                      remoteRecognizer: (png) =>
                          TextbookApi.instance.recognizeHandwriting(
                        imageBase64: base64Encode(png),
                        answerKind: problem.answerKind,
                      ),
                      onSnapshot: (payload) {
                        _handwritingSnapshots[problem.cropId] =
                            <String, dynamic>{
                          ...payload,
                          'input_mode': _InputMode.pencil.name,
                        };
                      },
                      onRecognizingChanged: (busy) =>
                          _setRecognizing(answerKey, busy),
                      onRecognized: (text, {sourceLatex}) => _setAnswer(
                        answerKey,
                        text,
                        displayLatex: sourceLatex,
                      ),
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
                          onChanged: (linear) => _setAnswer(answerKey, linear),
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
                      onChanged: (text) => _setAnswer(answerKey, text),
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
              child: Row(
                children: [
                  Expanded(
                    child: IgnorePointer(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Text(
                              '${_displayProblemNumber(problem)}번'
                              '${partKey == null ? '' : ' $partKey'} 답  ·  ',
                              style: const TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            // 인식·입력된 답은 2D 조판 수식으로 보여준다.
                            Flexible(
                              child: _isRecognizing(answerKey)
                                  ? _recognizingView(
                                      fontSize: 17,
                                      color: Colors.black,
                                    )
                                  : answer.isEmpty
                                      ? const Text(
                                          '입력 전',
                                          style: TextStyle(
                                            color: Colors.black,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        )
                                      : FittedBox(
                                          fit: BoxFit.scaleDown,
                                          alignment: Alignment.centerLeft,
                                          child: _answerMathView(
                                            answerKey,
                                            answer,
                                            fontSize: 19,
                                            color: Colors.black,
                                          ),
                                        ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  _buildReportIconButton(problem),
                  const SizedBox(width: 2),
                  _buildInputModeButton(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 시간제한 테스트 등 다른 풀이 흐름에서도 동일한 문항 PDF 렌더를 쓴다.
class TextbookProblemDocumentView extends StatelessWidget {
  const TextbookProblemDocumentView({
    super.key,
    required this.view,
  });

  final StudentTextbookProblemView view;

  @override
  Widget build(BuildContext context) {
    if (view.isQueued) {
      return const Center(child: YggLoadingIndicator());
    }
    final useSingleBodyPage = view.isFallback && view.hasBodyPagePdf;
    final url = useSingleBodyPage
        ? view.bodyPagePdfUrl
        : (view.isFallback ? (view.bodyPdfUrl ?? view.pdfUrl) : view.pdfUrl);
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null) {
      return const Center(child: Text('문항 PDF를 열 수 없어요.'));
    }
    return _ProblemPdfView(
      uri: uri,
      fallbackPage: useSingleBodyPage
          ? 1
          : (view.isFallback ? view.rawPage : null),
      itemRegion1k: view.isFallback ? view.itemRegion1k : null,
    );
  }
}

/// 객관식 선지를 고른다. 펜슬로 그은 체크는 [pencilStroke] 에 담아 넘긴다.
typedef _ObjectiveChoiceToggle = void Function(
  int choice, {
  List<Offset>? pencilStroke,
});

class _ProblemPdfView extends StatelessWidget {
  const _ProblemPdfView({
    super.key,
    required this.uri,
    this.fallbackPage,
    this.itemRegion1k,
    this.isObjective = false,
    this.selectedChoices = const <int>{},
    this.onToggleChoice,
    this.pencilMarks = const <int, List<Offset>>{},
    this.fallbackChoiceSelector,
  });

  final Uri uri;
  final int? fallbackPage;
  final List<int>? itemRegion1k;
  final bool isObjective;
  final Set<int> selectedChoices;
  final _ObjectiveChoiceToggle? onToggleChoice;
  final Map<int, List<Offset>> pencilMarks;
  final Widget? fallbackChoiceSelector;

  @override
  Widget build(BuildContext context) {
    if (fallbackPage != null) {
      return _FallbackProblemPdfPage(
        uri: uri,
        pageNumber: fallbackPage!,
        itemRegion1k: itemRegion1k,
        isObjective: isObjective,
        selectedChoices: selectedChoices,
        onToggleChoice: onToggleChoice,
        pencilMarks: pencilMarks,
        fallbackChoiceSelector: fallbackChoiceSelector,
      );
    }
    // 워커 산출물은 8절 본문 한 줄과 같은 폭의 PDF다. 화면에서는 기기
    // 너비 비율이 아니라 고정된 물리 폭으로 그린다.
    return _RenderedProblemPdfPage(
      uri: uri,
      isObjective: isObjective,
      selectedChoices: selectedChoices,
      onToggleChoice: onToggleChoice,
      pencilMarks: pencilMarks,
      fallbackChoiceSelector: fallbackChoiceSelector,
    );
  }
}

/// 주변 문항의 단일 문항 PDF를 미리 내려받아 전환 시 네트워크 대기를 없앤다.
///
/// 워커가 만든 작은 단일 문항 PDF만 캐시한다. 원본 교재 PDF fallback은
/// 파일이 클 수 있어 프리페치하지 않는다.
///
/// 한도는 선택 문항 + 앞뒤 이웃 4개를 담고도 페이지를 넘나들 여유가 남도록
/// 잡았다. 너무 작으면 예열해 둔 문항이 곧바로 밀려나 프리페치가 무의미해진다.
class _QuestionPdfCache {
  static const _maxEntries = 14;
  static final Map<String, Future<Uint8List>> _bytesByUrl =
      <String, Future<Uint8List>>{};

  static Future<void> prefetch(String? rawUrl) async {
    final uri = _parseUri(rawUrl);
    if (uri == null) return;
    try {
      await _bytesFor(uri);
    } catch (_) {
      _bytesByUrl.remove(uri.toString());
    }
  }

  static Future<PdfDocument> open(Uri uri) async {
    try {
      final bytes = await _bytesFor(uri);
      return PdfDocument.openData(bytes, sourceName: uri.toString());
    } catch (_) {
      _bytesByUrl.remove(uri.toString());
      return PdfDocument.openUri(uri);
    }
  }

  static Uri? _parseUri(String? rawUrl) {
    final value = rawUrl?.trim() ?? '';
    if (value.isEmpty) return null;
    return Uri.tryParse(value);
  }

  static Future<Uint8List> _bytesFor(Uri uri) {
    final key = uri.toString();
    final cached = _bytesByUrl[key];
    if (cached != null) return cached;

    while (_bytesByUrl.length >= _maxEntries) {
      _bytesByUrl.remove(_bytesByUrl.keys.first);
    }
    final request = _download(uri);
    _bytesByUrl[key] = request;
    return request;
  }

  static Future<Uint8List> _download(Uri uri) async {
    final response = await http.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('question_pdf_http_${response.statusCode}');
    }
    return response.bodyBytes;
  }
}

/// 원본보기용 1쪽 분리 PDF 전용 메모리 캐시.
/// 문항 보기 캐시와 분리해 소단원 전체(최대 24쪽)를 넉넉히 담아 둔다.
class _BodyPageBytesCache {
  static const _maxEntries = 24;
  static final Map<String, Future<Uint8List>> _bytesByPath =
      <String, Future<Uint8List>>{};

  static String _cacheKey(Uri uri) => uri.path;

  static Future<void> prefetch(String? rawUrl) async {
    final value = rawUrl?.trim() ?? '';
    if (value.isEmpty) return;
    final uri = Uri.tryParse(value);
    if (uri == null) return;
    try {
      await _bytesFor(uri);
    } catch (_) {
      _bytesByPath.remove(_cacheKey(uri));
    }
  }

  static Future<PdfDocument> open(Uri uri) async {
    try {
      final bytes = await _bytesFor(uri);
      return PdfDocument.openData(bytes, sourceName: uri.toString());
    } catch (_) {
      _bytesByPath.remove(_cacheKey(uri));
      return PdfDocument.openUri(uri);
    }
  }

  static Future<Uint8List> _bytesFor(Uri uri) {
    final key = _cacheKey(uri);
    final cached = _bytesByPath[key];
    if (cached != null) return cached;
    while (_bytesByPath.length >= _maxEntries) {
      _bytesByPath.remove(_bytesByPath.keys.first);
    }
    final request = _download(uri);
    _bytesByPath[key] = request;
    return request;
  }

  static Future<Uint8List> _download(Uri uri) async {
    final response = await http.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('body_page_pdf_http_${response.statusCode}');
    }
    return response.bodyBytes;
  }
}

/// 워커가 렌더한 단일 문항 PDF 표시.
///
/// 가로는 물리 105mm, 세로는 종횡비에 맞춘 고정 높이.
/// 세로 스크롤은 상위 시트(`SingleChildScrollView`)가 담당한다.
double _questionViewLogicalWidth(BuildContext context, double maxWidth) {
  final view = View.of(context);
  final dpr = view.devicePixelRatio <= 0 ? 1.0 : view.devicePixelRatio;
  final logicalPerInch = questionViewLogicalPixelsPerInch(
    useIosPanelPpi: !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS,
    devicePixelRatio: dpr,
    shortestPhysicalPixels: math.min(
      view.physicalSize.width,
      view.physicalSize.height,
    ),
    desktopPhysicalPpi: readDesktopPhysicalPpi(),
  );
  scheduleQuestionPreviewWindowFit(dpr);
  return questionViewLogicalWidth(
    maxWidth: maxWidth,
    logicalPixelsPerInch: logicalPerInch,
  );
}

class _RenderedProblemPdfPage extends StatefulWidget {
  const _RenderedProblemPdfPage({
    super.key,
    required this.uri,
    this.isObjective = false,
    this.selectedChoices = const <int>{},
    this.onToggleChoice,
    this.pencilMarks = const <int, List<Offset>>{},
    this.fallbackChoiceSelector,
    this.verticalInset = 10.0,
    this.headerLabel,
    this.gradedResult,
    this.gradeSeed = 0,
  });

  final Uri uri;
  final bool isObjective;
  final Set<int> selectedChoices;
  final _ObjectiveChoiceToggle? onToggleChoice;
  final Map<int, List<Offset>> pencilMarks;
  final Widget? fallbackChoiceSelector;
  final double verticalInset;
  final String? headerLabel;
  final bool? gradedResult;
  final int gradeSeed;

  @override
  State<_RenderedProblemPdfPage> createState() =>
      _RenderedProblemPdfPageState();
}

class _RenderedProblemPdfPageState extends State<_RenderedProblemPdfPage> {
  PdfDocument? _document;
  Map<int, PdfRect> _choiceMarkerRects = const <int, PdfRect>{};
  bool _choiceTextLoaded = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final document = await _QuestionPdfCache.open(widget.uri);
      if (!mounted) {
        await document.dispose();
        return;
      }
      var markerRects = const <int, PdfRect>{};
      if (document.pages.isNotEmpty) {
        try {
          final pageText = await document.pages.first.loadText();
          markerRects = _extractObjectiveChoiceRects(pageText);
        } catch (_) {
          // 텍스트 레이어 추출 실패 시 폴백 버튼으로 내려간다.
        }
      }
      if (!mounted) {
        await document.dispose();
        return;
      }
      setState(() {
        _document = document;
        _choiceMarkerRects = markerRects;
        _choiceTextLoaded = true;
      });
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
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('문항 PDF를 표시할 수 없어요.', textAlign: TextAlign.center),
          ),
          if (widget.fallbackChoiceSelector != null)
            widget.fallbackChoiceSelector!,
        ],
      );
    }
    final document = _document;
    if (document == null || document.pages.isEmpty) {
      return const SizedBox(
        height: 160,
        child: Center(child: YggLoadingIndicator()),
      );
    }
    final page = document.pages.first;
    final hasInlineChoices = widget.isObjective && _choiceMarkerRects.isNotEmpty;
    final renderZoom = _ZoomRenderScale.of(context);
    const inset = 10.0;
    final pdfWidget = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: inset,
        vertical: widget.verticalInset,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 8절 문항과 같은 글자 크기가 아이패드와 이 PC에서 같게 보이도록
          // 가로 105mm로 고정한다. 더 넓은 창은 같은 105mm만 쓰고 옆은
          // 비운다. 그보다 좁은 창에서만 안쪽 너비에 맞춘다.
          final width = _questionViewLogicalWidth(context, constraints.maxWidth);
          final height = width * (page.height / page.width);
          final pageSize = Size(width, height);
          final pdfBox = SizedBox(
            width: constraints.maxWidth,
            height: height,
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: width,
                height: height,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: PdfPageView(
                        document: document,
                        pageNumber: 1,
                        maximumDpi: 420,
                        pageSizeCallback: _zoomAwarePdfPageSize(
                          renderZoom,
                          maxDpi: 420,
                        ),
                        decoration: const BoxDecoration(color: Colors.white),
                      ),
                    ),
                    if (hasInlineChoices)
                      Positioned.fill(
                        child: _ObjectivePdfChoiceOverlay(
                          choiceRects: <int, Rect>{
                            for (final entry in _choiceMarkerRects.entries)
                              entry.key: entry.value.toRect(
                                page: page,
                                scaledPageSize: pageSize,
                              ),
                          },
                          selectedChoices: widget.selectedChoices,
                          pencilMarks: widget.pencilMarks,
                          onToggleChoice: widget.onToggleChoice,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
          final label = widget.headerLabel?.trim() ?? '';
          if (label.isEmpty) return pdfBox;
          // 8절 모의고사 인쇄물 본문 시작선(padX 10pt / 332.56pt)에 맞춰 번호를 올린다.
          final leftOffset = math.max(
            0.0,
            (constraints.maxWidth - width) / 2 + width * (10.0 / 332.56),
          );
          final fontSize = (width * (11.5 / 332.56)).clamp(15.0, 26.0);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.only(left: leftOffset),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _RedPencilGradeMark(
                    gradedResult: widget.gradedResult,
                    seed: widget.gradeSeed,
                    child: Text(
                      label,
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: fontSize,
                        fontWeight: FontWeight.w800,
                        height: 1.05,
                      ),
                    ),
                  ),
                ),
              ),
              pdfBox,
            ],
          );
        },
      ),
    );
    if (widget.isObjective &&
        _choiceTextLoaded &&
        !hasInlineChoices &&
        widget.fallbackChoiceSelector != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          pdfWidget,
          widget.fallbackChoiceSelector!,
        ],
      );
    }
    return pdfWidget;
  }
}

/// 단일 문항 PDF의 텍스트 레이어에서 객관식 선지 번호 ①~⑤의 위치를 찾는다.
///
/// 발문에 조건 ①, ② 등이 나올 수 있으므로 마지막으로 등장하는 각 번호를
/// 선지 라벨로 삼는다. 최소 4개 이상 잡혔을 때만 인라인 체크 대상로 쓴다.
Map<int, PdfRect> _extractObjectiveChoiceRects(PdfPageText pageText) {
  const circled = <String, int>{
    '①': 1,
    '②': 2,
    '③': 3,
    '④': 4,
    '⑤': 5,
    '⑴': 1,
    '⑵': 2,
    '⑶': 3,
    '⑷': 4,
    '⑸': 5,
  };
  final found = <int, PdfRect>{};
  for (final fragment in pageText.fragments) {
    final text = fragment.text;
    for (var i = 0; i < text.length; i++) {
      final number = circled[text[i]];
      if (number == null) continue;
      final rect = i < fragment.charRects.length
          ? fragment.charRects[i]
          : fragment.bounds;
      if (rect.isNotEmpty) {
        found[number] = rect;
      }
    }
  }
  return found.length >= 4 ? found : const <int, PdfRect>{};
}

class _ObjectivePdfChoiceOverlay extends StatefulWidget {
  const _ObjectivePdfChoiceOverlay({
    required this.choiceRects,
    required this.selectedChoices,
    this.pencilMarks = const <int, List<Offset>>{},
    this.onToggleChoice,
  });

  final Map<int, Rect> choiceRects;
  final Set<int> selectedChoices;
  final Map<int, List<Offset>> pencilMarks;
  final _ObjectiveChoiceToggle? onToggleChoice;

  @override
  State<_ObjectivePdfChoiceOverlay> createState() =>
      _ObjectivePdfChoiceOverlayState();
}

class _ObjectivePdfChoiceOverlayState
    extends State<_ObjectivePdfChoiceOverlay> {
  final List<Offset> _activeStroke = <Offset>[];
  int? _activePointer;
  Offset? _activeStartGlobal;
  bool _activeIsStylus = false;
  int _touchCount = 0;
  static const double _tapSlop = 12;

  int? _hitChoiceAt(Offset point) {
    int? bestChoice;
    var bestDistance = double.infinity;
    for (final entry in widget.choiceRects.entries) {
      final hitRect = entry.value.inflate(14);
      if (!hitRect.contains(point)) continue;
      final distance = (entry.value.center - point).distance;
      if (distance < bestDistance) {
        bestDistance = distance;
        bestChoice = entry.key;
      }
    }
    return bestChoice;
  }

  int? _hitChoiceFromStroke(List<Offset> points) {
    if (points.isEmpty) return null;
    var minX = points.first.dx;
    var maxX = points.first.dx;
    var minY = points.first.dy;
    var maxY = points.first.dy;
    for (final point in points) {
      if (point.dx < minX) minX = point.dx;
      if (point.dx > maxX) maxX = point.dx;
      if (point.dy < minY) minY = point.dy;
      if (point.dy > maxY) maxY = point.dy;
    }
    final strokeBounds = Rect.fromLTRB(minX, minY, maxX, maxY);
    // 화면을 크게 가로지르는 획은 선택 체크가 아니라 오터치로 본다.
    if (strokeBounds.width > 96 || strokeBounds.height > 96) {
      return null;
    }

    int? bestChoice;
    var bestScore = double.infinity;
    for (final entry in widget.choiceRects.entries) {
      final target = entry.value.inflate(14);
      final touchesPoint = points.any(target.contains);
      final overlapsBox = target.overlaps(strokeBounds);
      if (!touchesPoint && !overlapsBox) continue;
      final distance = (entry.value.center - strokeBounds.center).distance;
      if (distance < bestScore) {
        bestScore = distance;
        bestChoice = entry.key;
      }
    }
    return bestChoice;
  }

  void _finishPointer(PointerEvent event) {
    final isTouch = event.kind == PointerDeviceKind.touch;
    if (isTouch) {
      _touchCount = (_touchCount - 1).clamp(0, 10).toInt();
    }
    if (_activePointer != event.pointer) return;
    final stroke = List<Offset>.of(_activeStroke);
    final startGlobal = _activeStartGlobal;
    final wasStylus = _activeIsStylus;
    setState(() {
      _activePointer = null;
      _activeStartGlobal = null;
      _activeStroke.clear();
    });
    final onToggle = widget.onToggleChoice;
    if (onToggle == null || stroke.isEmpty) return;
    if (!wasStylus) {
      final moved = (stroke.last - stroke.first).distance;
      final globalMoved =
          startGlobal == null ? 0.0 : (event.position - startGlobal).distance;
      if (moved > _tapSlop || globalMoved > _tapSlop) return;
      final hit = _hitChoiceAt(stroke.last);
      if (hit != null) onToggle(hit);
      return;
    }
    final hit = _hitChoiceFromStroke(stroke);
    if (hit != null) onToggle(hit, pencilStroke: stroke);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: widget.onToggleChoice == null
          ? null
          : (event) {
              final isTouch = event.kind == PointerDeviceKind.touch;
              final isStylus = !isTouch;
              if (isTouch) {
                _touchCount += 1;
                if (_touchCount >= 2) {
                  if (_activePointer != null && !_activeIsStylus) {
                    setState(() {
                      _activePointer = null;
                      _activeStartGlobal = null;
                      _activeStroke.clear();
                    });
                  }
                  return;
                }
                // 손가락은 선지 번호 위를 눌렀을 때만 받는다 (나머지는 스크롤).
                if (_hitChoiceAt(event.localPosition) == null) return;
              }
              if (_activePointer != null) return;
              setState(() {
                _activePointer = event.pointer;
                _activeStartGlobal = event.position;
                _activeIsStylus = isStylus;
                _activeStroke
                  ..clear()
                  ..add(event.localPosition);
              });
            },
      onPointerMove: widget.onToggleChoice == null
          ? null
          : (event) {
              if (_activePointer != event.pointer) return;
              if (!_activeIsStylus) {
                if ((event.localPosition - _activeStroke.first).distance >
                    _tapSlop) {
                  setState(() {
                    _activePointer = null;
                    _activeStroke.clear();
                  });
                }
                return;
              }
              setState(() => _activeStroke.add(event.localPosition));
            },
      onPointerUp: widget.onToggleChoice == null ? null : _finishPointer,
      onPointerCancel: widget.onToggleChoice == null ? null : _finishPointer,
      child: CustomPaint(
        painter: _ObjectivePdfChoicePainter(
          choiceRects: widget.choiceRects,
          selectedChoices: widget.selectedChoices,
          pencilMarks: Map<int, List<Offset>>.of(widget.pencilMarks),
          activeStroke: _activeIsStylus
              ? List<Offset>.of(_activeStroke)
              : const <Offset>[],
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _ObjectivePdfChoicePainter extends CustomPainter {
  const _ObjectivePdfChoicePainter({
    required this.choiceRects,
    required this.selectedChoices,
    required this.pencilMarks,
    required this.activeStroke,
  });

  final Map<int, Rect> choiceRects;
  final Set<int> selectedChoices;

  /// 펜슬로 그은 체크. 없는 선택 번호는 손가락 터치라 초록 체크만 그린다.
  final Map<int, List<Offset>> pencilMarks;
  final List<Offset> activeStroke;

  @override
  void paint(Canvas canvas, Size size) {
    for (final choice in selectedChoices) {
      final stroke = pencilMarks[choice];
      if (stroke != null && stroke.length >= 2) {
        _paintPencilStroke(canvas, stroke);
        continue;
      }
      final rect = choiceRects[choice];
      if (rect == null) continue;
      _paintFingerCheck(canvas, rect);
    }
    if (activeStroke.length >= 2) {
      _paintPencilStroke(canvas, activeStroke);
    }
  }

  static void _paintFingerCheck(Canvas canvas, Rect rect) {
    const accent = YggGlassTokens.confirmActionColor;
    final center = rect.center;
    final radius = math.max(rect.width, rect.height) * 0.62 + 3.5;
    final checkPath = Path()
      ..moveTo(center.dx - radius * 0.55, center.dy - radius * 0.05)
      ..lineTo(center.dx - radius * 0.08, center.dy + radius * 0.45)
      ..lineTo(center.dx + radius * 0.72, center.dy - radius * 0.58);
    canvas.drawPath(
      checkPath,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  static void _paintPencilStroke(Canvas canvas, List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = YggGlassTokens.confirmActionColor.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _ObjectivePdfChoicePainter oldDelegate) {
    return oldDelegate.choiceRects != choiceRects ||
        !setEquals(oldDelegate.selectedChoices, selectedChoices) ||
        !_samePencilMarks(oldDelegate.pencilMarks, pencilMarks) ||
        oldDelegate.activeStroke.length != activeStroke.length ||
        (activeStroke.isNotEmpty &&
            oldDelegate.activeStroke.isNotEmpty &&
            oldDelegate.activeStroke.last != activeStroke.last);
  }

  bool _samePencilMarks(
    Map<int, List<Offset>> previous,
    Map<int, List<Offset>> next,
  ) {
    if (previous.length != next.length) return false;
    for (final entry in next.entries) {
      final other = previous[entry.key];
      if (other == null || other.length != entry.value.length) return false;
      if (entry.value.isEmpty) continue;
      if (other.first != entry.value.first || other.last != entry.value.last) {
        return false;
      }
    }
    return true;
  }
}

class _FallbackProblemPdfPage extends StatefulWidget {
  const _FallbackProblemPdfPage({
    required this.uri,
    required this.pageNumber,
    this.itemRegion1k,
    this.isObjective = false,
    this.selectedChoices = const <int>{},
    this.onToggleChoice,
    this.pencilMarks = const <int, List<Offset>>{},
    this.fallbackChoiceSelector,
  });

  final Uri uri;
  final int pageNumber;
  final List<int>? itemRegion1k;
  final bool isObjective;
  final Set<int> selectedChoices;
  final _ObjectiveChoiceToggle? onToggleChoice;
  final Map<int, List<Offset>> pencilMarks;
  final Widget? fallbackChoiceSelector;

  @override
  State<_FallbackProblemPdfPage> createState() =>
      _FallbackProblemPdfPageState();
}

class _FallbackProblemPdfPageState extends State<_FallbackProblemPdfPage> {
  PdfDocument? _document;
  Map<int, PdfRect> _choiceMarkerRects = const <int, PdfRect>{};
  bool _choiceTextLoaded = false;
  Object? _error;
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _FallbackProblemPdfPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri || oldWidget.pageNumber != widget.pageNumber) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    try {
      final document = await PdfDocument.openUri(
        widget.uri,
        useProgressiveLoading: true,
        preferRangeAccess: true,
      );
      if (!mounted || seq != _loadSeq) {
        await document.dispose();
        return;
      }
      var markerRects = const <int, PdfRect>{};
      if (document.pages.isNotEmpty) {
        final pageNumber =
            widget.pageNumber.clamp(1, document.pages.length).toInt();
        final page = document.pages[pageNumber - 1];
        try {
          final pageText = await page.loadText();
          markerRects = _extractFallbackChoiceRects(
            page,
            pageText,
            widget.itemRegion1k,
          );
        } catch (_) {}
      }
      if (!mounted || seq != _loadSeq) {
        await document.dispose();
        return;
      }
      final prev = _document;
      setState(() {
        _document = document;
        _choiceMarkerRects = markerRects;
        _choiceTextLoaded = true;
        _error = null;
      });
      if (prev != null && !identical(prev, document)) {
        unawaited(prev.dispose());
      }
    } catch (error) {
      if (mounted && seq == _loadSeq) setState(() => _error = error);
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
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('원본 교재 PDF를 표시할 수 없어요.', textAlign: TextAlign.center),
          ),
          if (widget.fallbackChoiceSelector != null)
            widget.fallbackChoiceSelector!,
        ],
      );
    }
    final document = _document;
    if (document == null) {
      return const SizedBox(
        height: 160,
        child: Center(child: YggLoadingIndicator()),
      );
    }
    final pageNumber =
        widget.pageNumber.clamp(1, document.pages.length).toInt();
    final page = document.pages[pageNumber - 1];
    final renderZoom = _ZoomRenderScale.of(context);
    final region = widget.itemRegion1k;
    if (region == null || region.length != 4) {
      final viewer = AspectRatio(
        aspectRatio: page.width / page.height,
        child: PdfPageView(
          document: document,
          pageNumber: pageNumber,
          maximumDpi: 360,
          pageSizeCallback: _zoomAwarePdfPageSize(renderZoom, maxDpi: 360),
          decoration: const BoxDecoration(color: Colors.white),
        ),
      );
      if (widget.isObjective && widget.fallbackChoiceSelector != null) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            viewer,
            widget.fallbackChoiceSelector!,
          ],
        );
      }
      return viewer;
    }
    final hasInlineChoices = widget.isObjective && _choiceMarkerRects.isNotEmpty;
    final cropped = _CroppedPdfPage(
      document: document,
      pageNumber: pageNumber,
      itemRegion1k: region,
      choiceMarkerRects: hasInlineChoices ? _choiceMarkerRects : const <int, PdfRect>{},
      selectedChoices: widget.selectedChoices,
      pencilMarks: widget.pencilMarks,
      onToggleChoice: widget.onToggleChoice,
    );
    if (widget.isObjective &&
        _choiceTextLoaded &&
        !hasInlineChoices &&
        widget.fallbackChoiceSelector != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          cropped,
          widget.fallbackChoiceSelector!,
        ],
      );
    }
    return cropped;
  }
}

Map<int, PdfRect> _extractFallbackChoiceRects(
  PdfPage page,
  PdfPageText pageText,
  List<int>? itemRegion1k,
) {
  if (itemRegion1k == null || itemRegion1k.length != 4) {
    return const <int, PdfRect>{};
  }
  const padding = 16.0;
  final topRatio = ((itemRegion1k[0] - padding) / 1000).clamp(0.0, 1.0);
  final leftRatio = ((itemRegion1k[1] - padding) / 1000).clamp(0.0, 1.0);
  final bottomRatio = ((itemRegion1k[2] + padding) / 1000).clamp(0.0, 1.0);
  final rightRatio = ((itemRegion1k[3] + padding) / 1000).clamp(0.0, 1.0);
  final cropPdfRect = PdfRect(
    page.width * leftRatio,
    page.height * (1.0 - topRatio),
    page.width * rightRatio,
    page.height * (1.0 - bottomRatio),
  );
  const circled = <String, int>{
    '①': 1,
    '②': 2,
    '③': 3,
    '④': 4,
    '⑤': 5,
    '⑴': 1,
    '⑵': 2,
    '⑶': 3,
    '⑷': 4,
    '⑸': 5,
  };
  final found = <int, PdfRect>{};
  for (final fragment in pageText.fragments) {
    final text = fragment.text;
    for (var i = 0; i < text.length; i++) {
      final number = circled[text[i]];
      if (number == null) continue;
      final rect = i < fragment.charRects.length
          ? fragment.charRects[i]
          : fragment.bounds;
      if (rect.isNotEmpty && cropPdfRect.overlaps(rect)) {
        found[number] = rect;
      }
    }
  }
  return found.length >= 4 ? found : const <int, PdfRect>{};
}

/// 원본보기용 페이지 단위 PDF + 좌표 기반 문항 입력 뷰.
///
/// 문항 보기와 동일한 제스쳐·입력 구조로 원본 PDF 페이지를 그대로 띄우고,
/// 저장된 문항 좌표(`item_region_1k`) 근처 필기·객관식 체크를 해당 문항 답안으로 연결한다.
class _BodyPageSolveView extends StatefulWidget {
  const _BodyPageSolveView({
    super.key,
    required this.uri,
    required this.pageNumber,
    required this.rawPage,
    required this.isSinglePagePdf,
    required this.viewportWidth,
    required this.problemsOnPage,
    required this.regionsByCrop,
    required this.numberBoxesByCrop,
    required this.choiceRegionsByCrop,
    required this.bodyPencilKey,
    required this.answers,
    required this.results,
    required this.gradedResultOf,
    required this.attemptCounts,
    required this.recognizingAnswerKeys,
    required this.objectivePencilMarks,
    required this.isOnHold,
    required this.usesSelfCheck,
    required this.displayNumberOf,
    required this.answerKeyOf,
    required this.answerMathBuilder,
    required this.onSelfCheck,
    required this.onFocusProblem,
    required this.onToggleChoice,
    required this.onRecognizingChanged,
    required this.onSnapshot,
    required this.onRecognized,
    this.onDocumentReady,
  });

  final Uri uri;
  final int pageNumber;
  final int rawPage;
  final bool isSinglePagePdf;
  final double viewportWidth;
  final List<PageProblem> problemsOnPage;
  final Map<String, List<int>> regionsByCrop;
  final Map<String, List<int>> numberBoxesByCrop;
  final Map<String, Map<int, List<int>>> choiceRegionsByCrop;
  final GlobalKey<MultiTargetPencilOverlayState> bodyPencilKey;
  final Map<String, String> answers;
  final Map<String, bool> results;
  final bool? Function(PageProblem problem) gradedResultOf;
  final Map<String, int> attemptCounts;
  final Set<String> recognizingAnswerKeys;
  final Map<String, Map<int, List<Offset>>> objectivePencilMarks;
  final bool Function(String cropId) isOnHold;
  final bool Function(PageProblem problem) usesSelfCheck;
  final String Function(PageProblem problem) displayNumberOf;
  final String Function(String cropId) answerKeyOf;
  final Widget Function(String answerKey, String answer) answerMathBuilder;
  final ValueChanged<PageProblem> onSelfCheck;
  final ValueChanged<PageProblem> onFocusProblem;
  final void Function(
    String cropId,
    int choice, {
    List<Offset>? pencilStroke,
  }) onToggleChoice;
  final void Function(String answerKey, bool busy) onRecognizingChanged;
  final void Function(String cropId, Map<String, dynamic> payload) onSnapshot;
  final void Function(String cropId, String text, {String? sourceLatex})
      onRecognized;
  final VoidCallback? onDocumentReady;

  @override
  State<_BodyPageSolveView> createState() => _BodyPageSolveViewState();
}

class _BodyPageSolveViewState extends State<_BodyPageSolveView> {
  PdfDocument? _document;
  Map<String, Map<int, PdfRect>> _choiceRectsByCrop =
      const <String, Map<int, PdfRect>>{};
  Object? _error;
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _BodyPageSolveView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri ||
        oldWidget.pageNumber != widget.pageNumber ||
        oldWidget.isSinglePagePdf != widget.isSinglePagePdf) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    try {
      final document = widget.isSinglePagePdf
          ? await _BodyPageBytesCache.open(widget.uri)
          : await PdfDocument.openUri(
              widget.uri,
              useProgressiveLoading: false,
              preferRangeAccess: true,
            );
      if (!mounted || seq != _loadSeq) {
        await document.dispose();
        return;
      }
      var choiceRectsByCrop = const <String, Map<int, PdfRect>>{};
      if (document.pages.isNotEmpty) {
        final pageNumber =
            widget.pageNumber.clamp(1, document.pages.length).toInt();
        final page = document.pages[pageNumber - 1];
        final objectiveRegions = <String, List<int>>{};
        for (final p in widget.problemsOnPage) {
          if (!p.isObjective) continue;
          // DB에 저장된 객관식 번호 좌표(choice_regions_1k)가 없는 문항만 PDF 텍스트 추출 시도
          final dbChoices = widget.choiceRegionsByCrop[p.cropId];
          if (dbChoices != null && dbChoices.length >= 4) continue;
          final r = widget.regionsByCrop[p.cropId];
          if (r != null && r.length == 4) {
            objectiveRegions[p.cropId] = r;
          }
        }
        if (objectiveRegions.isNotEmpty) {
          try {
            final pageText = await page.loadText();
            choiceRectsByCrop = _extractBodyPageObjectiveChoices(
              page,
              pageText,
              objectiveRegions,
            );
          } catch (_) {}
        }
      }
      if (!mounted || seq != _loadSeq) {
        await document.dispose();
        return;
      }
      final prev = _document;
      setState(() {
        _document = document;
        _choiceRectsByCrop = choiceRectsByCrop;
        _error = null;
      });
      widget.onDocumentReady?.call();
      if (prev != null && !identical(prev, document)) {
        unawaited(prev.dispose());
      }
    } catch (error) {
      if (mounted && seq == _loadSeq) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    final document = _document;
    _document = null;
    if (document != null) unawaited(document.dispose());
    super.dispose();
  }

  PageProblem? _problemForId(String cropId) {
    for (final p in widget.problemsOnPage) {
      if (p.cropId == cropId) return p;
    }
    return null;
  }

  bool _hasChoiceCoords(String cropId) {
    final db = widget.choiceRegionsByCrop[cropId];
    if (db != null && db.length >= 4) return true;
    final pdf = _choiceRectsByCrop[cropId];
    return pdf != null && pdf.length >= 4;
  }

  bool _canWriteTarget(String cropId) {
    final p = _problemForId(cropId);
    if (p == null) return false;
    if (widget.isOnHold(cropId)) return false;
    if (widget.usesSelfCheck(p)) return false;
    // 인쇄된 ①~⑤ 좌표가 있는 객관식은 선지 체크를 쓰고, 좌표가 없는 객관식(주관식 전환 등)은 필기로 받는다.
    if (p.isObjective && _hasChoiceCoords(cropId)) return false;
    final key = widget.answerKeyOf(cropId);
    return widget.results[key] != true;
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('원본 교재 PDF를 표시할 수 없어요.')),
      );
    }
    final document = _document;
    if (document == null || document.pages.isEmpty) {
      return const SizedBox(
        height: 260,
        child: Center(child: YggLoadingIndicator()),
      );
    }
    final pageNumber =
        widget.pageNumber.clamp(1, document.pages.length).toInt();
    final page = document.pages[pageNumber - 1];
    final renderZoom = _ZoomRenderScale.of(context);
    final pageWidth = math.max(240.0, widget.viewportWidth);
    final pageHeight = pageWidth * (page.height / page.width);
    final pageSize = Size(pageWidth, pageHeight);

    final objectiveSelectedByCrop = <String, Set<int>>{};
    final objectiveChoicesScaled = <String, Map<int, Rect>>{};
    final objectiveMarksScaled = <String, Map<int, List<Offset>>>{};
    for (final p in widget.problemsOnPage) {
      if (!p.isObjective) continue;
      final dbChoices = widget.choiceRegionsByCrop[p.cropId];
      if (dbChoices != null && dbChoices.length >= 4) {
        objectiveChoicesScaled[p.cropId] = <int, Rect>{
          for (final entry in dbChoices.entries)
            entry.key: Rect.fromLTRB(
              pageWidth * (entry.value[1] / 1000.0),
              pageHeight * (entry.value[0] / 1000.0),
              pageWidth * (entry.value[3] / 1000.0),
              pageHeight * (entry.value[2] / 1000.0),
            ),
        };
      } else {
        final rawRects = _choiceRectsByCrop[p.cropId];
        if (rawRects != null && rawRects.isNotEmpty) {
          objectiveChoicesScaled[p.cropId] = <int, Rect>{
            for (final entry in rawRects.entries)
              entry.key: entry.value.toRect(
                page: page,
                scaledPageSize: pageSize,
              ),
          };
        }
      }
      objectiveSelectedByCrop[p.cropId] = (widget.answers[p.cropId] ?? '')
          .split(',')
          .map((s) => int.tryParse(s.trim()))
          .whereType<int>()
          .toSet();
      final marks = widget.objectivePencilMarks[p.cropId];
      if (marks != null && marks.isNotEmpty) {
        objectiveMarksScaled[p.cropId] = marks;
      }
    }

    const accent = YggGlassTokens.confirmActionColor;
    const cautionColor = Color(0xFFE0A63C);

    final gradedNumberMarks = <({Rect rect, bool isCorrect, int seed})>[];
    for (final p in widget.problemsOnPage) {
      final graded = widget.gradedResultOf(p);
      if (graded == null) continue;
      final nb = widget.numberBoxesByCrop[p.cropId];
      final r = widget.regionsByCrop[p.cropId];
      Rect? numberRect;
      if (nb != null && nb.length == 4) {
        numberRect = Rect.fromLTRB(
          pageWidth * (nb[1] / 1000.0),
          pageHeight * (nb[0] / 1000.0),
          pageWidth * (nb[3] / 1000.0),
          pageHeight * (nb[2] / 1000.0),
        );
      } else if (r != null && r.length == 4) {
        final left = pageWidth * (r[1] / 1000.0);
        final top = pageHeight * (r[0] / 1000.0);
        numberRect = Rect.fromLTWH(
          left,
          top,
          math.max(28.0, pageWidth * 0.045),
          math.max(16.0, pageHeight * 0.018),
        );
      }
      if (numberRect != null) {
        gradedNumberMarks.add((
          rect: numberRect,
          isCorrect: graded,
          seed: p.cropId.hashCode,
        ));
      }
    }

    return Center(
      child: SizedBox(
        width: pageWidth,
        height: pageHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: PdfPageView(
                document: document,
                pageNumber: pageNumber,
                maximumDpi: 360,
                pageSizeCallback:
                    _zoomAwarePdfPageSize(renderZoom, maxDpi: 360),
                decoration: const BoxDecoration(color: Colors.white),
              ),
            ),
            // 정답 확인 대상 문항 왼쪽 세로줄 + 인식 결과 뱃지
            for (final p in widget.problemsOnPage)
              if (widget.regionsByCrop[p.cropId] != null)
                ...() {
                  final r = widget.regionsByCrop[p.cropId]!;
                  final left = pageWidth * (r[1] / 1000.0);
                  final top = pageHeight * (r[0] / 1000.0);
                  final right = pageWidth * (r[3] / 1000.0);
                  final bottom = pageHeight * (r[2] / 1000.0);
                  final boxW = math.max(24.0, right - left);
                  final boxH = math.max(16.0, bottom - top);
                  final held = widget.isOnHold(p.cropId);
                  final key = widget.answerKeyOf(p.cropId);
                  final answer = widget.answers[key] ?? '';
                  final res = widget.results[key];
                  final usesSelf = widget.usesSelfCheck(p);
                  final recognizing =
                      widget.recognizingAnswerKeys.contains(key);
                  final showSelfBar = !held && usesSelf && res != true;
                  final showPill = held ||
                      recognizing ||
                      (!p.isObjective && answer.isNotEmpty);

                  return <Widget>[
                    if (showSelfBar)
                      Positioned(
                        left: math.max(0.0, left - 4),
                        top: math.max(0.0, top - 2),
                        width: math.min(
                          pageWidth - math.max(0.0, left - 4),
                          boxW + 8,
                        ),
                        height: math.min(
                          pageHeight - math.max(0.0, top - 2),
                          boxH + 4,
                        ),
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: () => widget.onSelfCheck(p),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              width: 3.0,
                              height: double.infinity,
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.85),
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (showPill)
                      Positioned(
                        right: math.max(4.0, pageWidth - right),
                        top: math.max(2.0, top - 2),
                        child: IgnorePointer(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (held)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: cautionColor.withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: const Text(
                                    '검토 중',
                                    style: TextStyle(
                                      color: cautionColor,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                )
                              else ...[
                                if (recognizing)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.white.withValues(alpha: 0.9),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.8,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                          accent,
                                        ),
                                      ),
                                    ),
                                  )
                                else if (!p.isObjective && answer.isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.white.withValues(alpha: 0.92),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: Colors.black
                                            .withValues(alpha: 0.08),
                                      ),
                                    ),
                                    child: widget.answerMathBuilder(
                                      key,
                                      answer,
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ),
                  ];
                }(),
            if (gradedNumberMarks.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _BodyRedPencilGradesPainter(
                      marks: gradedNumberMarks,
                    ),
                  ),
                ),
              ),
            if (objectiveChoicesScaled.isNotEmpty)
              Positioned.fill(
                child: _BodyObjectiveChoicesOverlay(
                  choiceRectsByCrop: objectiveChoicesScaled,
                  selectedChoicesByCrop: objectiveSelectedByCrop,
                  pencilMarksByCrop: objectiveMarksScaled,
                  resolveCropAt: (point) => _matchBodyProblemAt(
                    point,
                    pageSize,
                    widget.problemsOnPage,
                    widget.regionsByCrop,
                  ),
                  canInputCrop: (cropId) {
                    final p = _problemForId(cropId);
                    if (p == null) return false;
                    return !widget.isOnHold(cropId) &&
                        widget.results[widget.answerKeyOf(cropId)] != true;
                  },
                  onToggleChoice: widget.onToggleChoice,
                ),
              ),
            Positioned.fill(
              child: MultiTargetPencilOverlay(
                key: widget.bodyPencilKey,
                stylusOnly: true,
                resolveTarget: (localPos, canvasSize) => _matchBodyProblemAt(
                  localPos,
                  canvasSize,
                  widget.problemsOnPage,
                  widget.regionsByCrop,
                ),
                canWriteTarget: _canWriteTarget,
                onTargetFocused: (cropId) {
                  final p = _problemForId(cropId);
                  if (p != null) widget.onFocusProblem(p);
                },
                candidateSelectorFor: (cropId, candidates) {
                  final p = _problemForId(cropId);
                  return pickPlausibleHandwritingCandidate(
                    candidates,
                    answerKind: p?.answerKind ?? 'subjective',
                  );
                },
                remoteRecognizerFor: (cropId, png) {
                  final p = _problemForId(cropId);
                  return TextbookApi.instance.recognizeHandwriting(
                    imageBase64: base64Encode(png),
                    answerKind: p?.answerKind ?? 'subjective',
                  );
                },
                onSnapshotFor: widget.onSnapshot,
                onRecognizingChangedFor: (cropId, busy) {
                  widget.onRecognizingChanged(
                    widget.answerKeyOf(cropId),
                    busy,
                  );
                },
                onRecognizedFor: widget.onRecognized,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String? _matchBodyProblemAt(
  Offset localPos,
  Size canvasSize,
  List<PageProblem> problemsOnPage,
  Map<String, List<int>> regionsByCrop,
) {
  if (problemsOnPage.isEmpty ||
      canvasSize.width <= 0 ||
      canvasSize.height <= 0) {
    return null;
  }
  final x1k = (localPos.dx / canvasSize.width * 1000.0).clamp(0.0, 1000.0);
  final y1k = (localPos.dy / canvasSize.height * 1000.0).clamp(0.0, 1000.0);

  String? bestCropId;
  var bestScore = double.infinity;
  var bestCenterDist = double.infinity;
  for (final p in problemsOnPage) {
    final r = regionsByCrop[p.cropId];
    if (r == null || r.length != 4) continue;
    final top = r[0].toDouble();
    final left = r[1].toDouble();
    final bottom = r[2].toDouble();
    final right = r[3].toDouble();
    final dx = x1k < left ? (left - x1k) : (x1k > right ? x1k - right : 0.0);
    // 문항 아래 여백 필기는 위 문항으로 자연스럽게 귀속되도록, 위쪽 침범에만 가중치를 둔다.
    final dy = y1k < top
        ? (top - y1k) * 1.8
        : (y1k > bottom ? (y1k - bottom) : 0.0);
    final score = (dx * 1.4) * (dx * 1.4) + dy * dy;
    final cx = (left + right) * 0.5;
    final cy = (top + bottom) * 0.5;
    final centerDist = (x1k - cx) * (x1k - cx) + (y1k - cy) * (y1k - cy);
    if (score < bestScore - 1e-6 ||
        ((score - bestScore).abs() <= 1e-6 && centerDist < bestCenterDist)) {
      bestScore = score;
      bestCenterDist = centerDist;
      bestCropId = p.cropId;
    }
  }
  return bestCropId ?? problemsOnPage.first.cropId;
}

Map<String, Map<int, PdfRect>> _extractBodyPageObjectiveChoices(
  PdfPage page,
  PdfPageText pageText,
  Map<String, List<int>> objectiveRegionsByCrop,
) {
  if (objectiveRegionsByCrop.isEmpty || page.width <= 0 || page.height <= 0) {
    return const <String, Map<int, PdfRect>>{};
  }
  const circled = <String, int>{
    '①': 1,
    '②': 2,
    '③': 3,
    '④': 4,
    '⑤': 5,
    '⑴': 1,
    '⑵': 2,
    '⑶': 3,
    '⑷': 4,
    '⑸': 5,
  };
  final byCrop = <String, Map<int, PdfRect>>{};
  for (final fragment in pageText.fragments) {
    final text = fragment.text;
    for (var i = 0; i < text.length; i++) {
      final choice = circled[text[i]];
      if (choice == null) continue;
      final rect = i < fragment.charRects.length
          ? fragment.charRects[i]
          : fragment.bounds;
      if (rect.isEmpty) continue;
      final cx1k = ((rect.left + rect.right) * 0.5 / page.width) * 1000.0;
      final cy1k =
          (1.0 - ((rect.top + rect.bottom) * 0.5 / page.height)) * 1000.0;

      String? bestCropId;
      var bestDist = double.infinity;
      for (final entry in objectiveRegionsByCrop.entries) {
        final r = entry.value;
        final top = r[0] - 18.0;
        final left = r[1] - 18.0;
        final bottom = r[2] + 18.0;
        final right = r[3] + 18.0;
        final dx = cx1k < left
            ? (left - cx1k)
            : (cx1k > right ? cx1k - right : 0.0);
        final dy = cy1k < top
            ? (top - cy1k) * 1.6
            : (cy1k > bottom ? cy1k - bottom : 0.0);
        final dist = dx * dx + dy * dy;
        if (dist < bestDist) {
          bestDist = dist;
          bestCropId = entry.key;
        }
      }
      if (bestCropId != null && bestDist <= 65 * 65) {
        (byCrop[bestCropId] ??= <int, PdfRect>{})[choice] = rect;
      }
    }
  }
  return <String, Map<int, PdfRect>>{
    for (final entry in byCrop.entries)
      if (entry.value.length >= 4) entry.key: entry.value,
  };
}

class _BodyObjectiveChoicesOverlay extends StatefulWidget {
  const _BodyObjectiveChoicesOverlay({
    required this.choiceRectsByCrop,
    required this.selectedChoicesByCrop,
    required this.pencilMarksByCrop,
    required this.resolveCropAt,
    required this.canInputCrop,
    required this.onToggleChoice,
  });

  final Map<String, Map<int, Rect>> choiceRectsByCrop;
  final Map<String, Set<int>> selectedChoicesByCrop;
  final Map<String, Map<int, List<Offset>>> pencilMarksByCrop;
  final String? Function(Offset point) resolveCropAt;
  final bool Function(String cropId) canInputCrop;
  final void Function(
    String cropId,
    int choice, {
    List<Offset>? pencilStroke,
  }) onToggleChoice;

  @override
  State<_BodyObjectiveChoicesOverlay> createState() =>
      _BodyObjectiveChoicesOverlayState();
}

class _BodyObjectiveChoicesOverlayState
    extends State<_BodyObjectiveChoicesOverlay> {
  final List<Offset> _activeStroke = <Offset>[];
  int? _activePointer;
  Offset? _activeStartGlobal;
  String? _activeCropId;
  bool _activeIsStylus = false;
  int _touchCount = 0;
  static const double _tapSlop = 12;

  ({String cropId, int choice})? _hitChoiceAt(Offset point) {
    String? bestCrop;
    int? bestChoice;
    var bestDistance = double.infinity;
    for (final cropEntry in widget.choiceRectsByCrop.entries) {
      if (!widget.canInputCrop(cropEntry.key)) continue;
      for (final choiceEntry in cropEntry.value.entries) {
        final hitRect = choiceEntry.value.inflate(14);
        if (!hitRect.contains(point)) continue;
        final distance = (choiceEntry.value.center - point).distance;
        if (distance < bestDistance) {
          bestDistance = distance;
          bestCrop = cropEntry.key;
          bestChoice = choiceEntry.key;
        }
      }
    }
    if (bestCrop == null || bestChoice == null) return null;
    return (cropId: bestCrop, choice: bestChoice);
  }

  ({String cropId, int choice})? _hitChoiceFromStroke(
    String cropId,
    List<Offset> points,
  ) {
    final rects = widget.choiceRectsByCrop[cropId];
    if (rects == null || points.isEmpty) return null;
    var minX = points.first.dx;
    var maxX = points.first.dx;
    var minY = points.first.dy;
    var maxY = points.first.dy;
    for (final point in points) {
      if (point.dx < minX) minX = point.dx;
      if (point.dx > maxX) maxX = point.dx;
      if (point.dy < minY) minY = point.dy;
      if (point.dy > maxY) maxY = point.dy;
    }
    final strokeBounds = Rect.fromLTRB(minX, minY, maxX, maxY);
    if (strokeBounds.width > 96 || strokeBounds.height > 96) {
      return null;
    }
    int? bestChoice;
    var bestScore = double.infinity;
    for (final entry in rects.entries) {
      final target = entry.value.inflate(18);
      final touchesPoint = points.any(target.contains);
      final overlapsBox = target.overlaps(strokeBounds);
      if (!touchesPoint && !overlapsBox) continue;
      final distance = (entry.value.center - strokeBounds.center).distance;
      if (distance < bestScore) {
        bestScore = distance;
        bestChoice = entry.key;
      }
    }
    if (bestChoice == null) return null;
    return (cropId: cropId, choice: bestChoice);
  }

  void _finishPointer(PointerEvent event) {
    final isTouch = event.kind == PointerDeviceKind.touch;
    if (isTouch) {
      _touchCount = (_touchCount - 1).clamp(0, 10).toInt();
    }
    if (_activePointer != event.pointer) return;
    final stroke = List<Offset>.of(_activeStroke);
    final startGlobal = _activeStartGlobal;
    final wasStylus = _activeIsStylus;
    final cropId = _activeCropId;
    setState(() {
      _activePointer = null;
      _activeStartGlobal = null;
      _activeCropId = null;
      _activeStroke.clear();
    });
    if (stroke.isEmpty || cropId == null) return;
    if (!wasStylus) {
      final moved = (stroke.last - stroke.first).distance;
      final globalMoved =
          startGlobal == null ? 0.0 : (event.position - startGlobal).distance;
      if (moved > _tapSlop || globalMoved > _tapSlop) return;
      final hit = _hitChoiceAt(stroke.last);
      if (hit != null) {
        widget.onToggleChoice(hit.cropId, hit.choice);
      }
      return;
    }
    final hit = _hitChoiceFromStroke(cropId, stroke);
    if (hit != null) {
      widget.onToggleChoice(hit.cropId, hit.choice, pencilStroke: stroke);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        final isTouch = event.kind == PointerDeviceKind.touch;
        final isStylus = !isTouch;
        if (isTouch) {
          _touchCount += 1;
          if (_touchCount >= 2) {
            if (_activePointer != null && !_activeIsStylus) {
              setState(() {
                _activePointer = null;
                _activeStartGlobal = null;
                _activeCropId = null;
                _activeStroke.clear();
              });
            }
            return;
          }
        }
        if (_activePointer != null) return;
        final hit = _hitChoiceAt(event.localPosition);
        String? targetCropId = hit?.cropId;
        if (targetCropId == null && isStylus) {
          final resolved = widget.resolveCropAt(event.localPosition);
          if (resolved != null &&
              widget.choiceRectsByCrop.containsKey(resolved) &&
              widget.canInputCrop(resolved)) {
            targetCropId = resolved;
          }
        }
        if (targetCropId == null) return;
        setState(() {
          _activePointer = event.pointer;
          _activeStartGlobal = event.position;
          _activeCropId = targetCropId;
          _activeIsStylus = isStylus;
          _activeStroke
            ..clear()
            ..add(event.localPosition);
        });
      },
      onPointerMove: (event) {
        if (_activePointer != event.pointer) return;
        setState(() {
          _activeStroke.add(event.localPosition);
        });
      },
      onPointerUp: _finishPointer,
      onPointerCancel: _finishPointer,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _BodyObjectiveChoicesPainter(
            choiceRectsByCrop: widget.choiceRectsByCrop,
            selectedChoicesByCrop: widget.selectedChoicesByCrop,
            pencilMarksByCrop: widget.pencilMarksByCrop,
            activeStroke: _activeIsStylus ? _activeStroke : const <Offset>[],
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _BodyObjectiveChoicesPainter extends CustomPainter {
  const _BodyObjectiveChoicesPainter({
    required this.choiceRectsByCrop,
    required this.selectedChoicesByCrop,
    required this.pencilMarksByCrop,
    required this.activeStroke,
  });

  final Map<String, Map<int, Rect>> choiceRectsByCrop;
  final Map<String, Set<int>> selectedChoicesByCrop;
  final Map<String, Map<int, List<Offset>>> pencilMarksByCrop;
  final List<Offset> activeStroke;

  @override
  void paint(Canvas canvas, Size size) {
    for (final cropEntry in choiceRectsByCrop.entries) {
      final selected = selectedChoicesByCrop[cropEntry.key] ?? const <int>{};
      final marks =
          pencilMarksByCrop[cropEntry.key] ?? const <int, List<Offset>>{};
      for (final choice in selected) {
        final rect = cropEntry.value[choice];
        if (rect == null) continue;
        final stroke = marks[choice];
        if (stroke != null && stroke.length >= 2) {
          _ObjectivePdfChoicePainter._paintPencilStroke(canvas, stroke);
        } else {
          _ObjectivePdfChoicePainter._paintFingerCheck(canvas, rect);
        }
      }
    }
    if (activeStroke.length >= 2) {
      _ObjectivePdfChoicePainter._paintPencilStroke(canvas, activeStroke);
    }
  }

  @override
  bool shouldRepaint(covariant _BodyObjectiveChoicesPainter oldDelegate) {
    return oldDelegate.choiceRectsByCrop != choiceRectsByCrop ||
        oldDelegate.selectedChoicesByCrop != selectedChoicesByCrop ||
        oldDelegate.pencilMarksByCrop != pencilMarksByCrop ||
        oldDelegate.activeStroke != activeStroke;
  }
}

class _CroppedPdfPage extends StatelessWidget {
  const _CroppedPdfPage({
    required this.document,
    required this.pageNumber,
    required this.itemRegion1k,
    this.choiceMarkerRects = const <int, PdfRect>{},
    this.selectedChoices = const <int>{},
    this.pencilMarks = const <int, List<Offset>>{},
    this.onToggleChoice,
  });

  final PdfDocument document;
  final int pageNumber;
  final List<int> itemRegion1k;
  final Map<int, PdfRect> choiceMarkerRects;
  final Set<int> selectedChoices;
  final Map<int, List<Offset>> pencilMarks;
  final _ObjectiveChoiceToggle? onToggleChoice;

  @override
  Widget build(BuildContext context) {
    final page = document.pages[pageNumber - 1];
    final renderZoom = _ZoomRenderScale.of(context);
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
      return AspectRatio(
        aspectRatio: page.width / page.height,
        child: PdfPageView(
          document: document,
          pageNumber: pageNumber,
          maximumDpi: 360,
          pageSizeCallback: _zoomAwarePdfPageSize(renderZoom, maxDpi: 360),
          decoration: const BoxDecoration(color: Colors.white),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 가로는 뷰포트의 75%. 세로는 크롭 영역 높이 — 상위 시트가 함께 스크롤.
        final cropWidth = constraints.maxWidth * 0.75;
        final scale = cropWidth / (page.width * regionWidth);
        final pageWidth = page.width * scale;
        final pageHeight = page.height * scale;
        final cropHeight = pageHeight * regionHeight;
        final offsetX = -pageWidth * left;
        final offsetY = -pageHeight * top;
        final scaledPageSize = Size(pageWidth, pageHeight);

        return SizedBox(
          width: constraints.maxWidth,
          height: cropHeight,
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: cropWidth,
              height: cropHeight,
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
                        maximumDpi: 360,
                        pageSizeCallback:
                            _zoomAwarePdfPageSize(renderZoom, maxDpi: 360),
                        decoration: const BoxDecoration(color: Colors.white),
                      ),
                    ),
                    if (choiceMarkerRects.isNotEmpty)
                      Positioned.fill(
                        child: _ObjectivePdfChoiceOverlay(
                          choiceRects: <int, Rect>{
                            for (final entry in choiceMarkerRects.entries)
                              entry.key: entry.value
                                  .toRect(
                                    page: page,
                                    scaledPageSize: scaledPageSize,
                                  )
                                  .translate(offsetX, offsetY),
                          },
                          selectedChoices: selectedChoices,
                          pencilMarks: pencilMarks,
                          onToggleChoice: onToggleChoice,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 확대 정착 배율을 하위 [PdfPageView]에 전달해 레이아웃 크기는 유지한 채
/// 고해상도 비트맵으로 다시 그리게 한다.
class _ZoomRenderScale extends InheritedWidget {
  const _ZoomRenderScale({
    required this.scale,
    required super.child,
  });

  final double scale;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ZoomRenderScale>()?.scale ??
      1.0;

  @override
  bool updateShouldNotify(covariant _ZoomRenderScale oldWidget) =>
      (oldWidget.scale - scale).abs() > 0.01;
}

PdfPageViewSizeCallback _zoomAwarePdfPageSize(
  double renderZoom, {
  double maxDpi = 360,
}) {
  return (Size availableScreenSize, PdfPage page) {
    final factor = renderZoom.clamp(1.0, 4.0);
    final targetW = availableScreenSize.width * factor;
    final targetH = availableScreenSize.height * factor;
    final scale = math.min(
      maxDpi / 72.0,
      math.min(targetW / page.width, targetH / page.height),
    );
    return Size(page.width * scale, page.height * scale);
  };
}

enum _TwoFingerMode { none, undecided, zoom, swiped }

/// 문항보기·원본보기 공용 두 손가락 핀치 확대 + 스크롤/쓸기 중재 래퍼.
///
/// - `1.0x` 상태: 1손가락 세로 스크롤, 2손가락 좌우/상하 쓸기(문항 이동·연습장) 동작.
/// - 두 손가락 간격이 벌어지거나 좁혀지면(`>= 18px`) 쓸기를 잠그고 초점 기준 확대(`1.0x~4.0x`).
/// - 확대 상태(`> 1.02x`): 스타일러스는 변형 역행렬을 통해 원래 `1.0x` 좌표에 오차 없이 필기하고,
///   손가락 드래그로 상하(스크롤)·좌우(`panX`) 이동이 가능하다.
class _ZoomableSolvePane extends StatefulWidget {
  const _ZoomableSolvePane({
    required this.scrollController,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.resetToken,
    required this.child,
    this.onSwipe,
    this.onSwipeUp,
    this.onSwipeDown,
  });

  final ScrollController scrollController;
  final double viewportWidth;
  final double viewportHeight;
  final Object? resetToken;
  final Widget child;
  final ValueChanged<int>? onSwipe;
  final VoidCallback? onSwipeUp;
  final VoidCallback? onSwipeDown;

  @override
  State<_ZoomableSolvePane> createState() => _ZoomableSolvePaneState();
}

class _ZoomableSolvePaneState extends State<_ZoomableSolvePane> {
  static const double _minScale = 1.0;
  static const double _maxScale = 4.0;
  static const double _pinchCommitDelta = 18.0;
  static const double _horizontalSwipeThreshold = 72.0;
  static const double _verticalSwipeThreshold = 56.0;

  final GlobalKey _scaledBoxKey = GlobalKey();
  final Map<int, Offset> _touchPointers = <int, Offset>{};

  double _scale = 1.0;
  double _panX = 0.0;
  double _renderZoom = 1.0;
  Timer? _renderZoomTimer;

  _TwoFingerMode _twoFingerMode = _TwoFingerMode.none;
  double _twoFingerStartSpan = 0.0;
  Offset _twoFingerStartCenter = Offset.zero;
  double _pinchBaseScale = 1.0;
  double _pinchStartSpan = 1.0;
  Offset _pinchAnchorContent = Offset.zero;

  bool _trackpadZooming = false;
  double _trackpadBaseScale = 1.0;

  @override
  void didUpdateWidget(covariant _ZoomableSolvePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetToken != widget.resetToken) {
      _resetZoomImmediate();
    } else if (_scale > 1.0 &&
        oldWidget.viewportWidth != widget.viewportWidth) {
      _panX = _panX.clamp(-widget.viewportWidth * (_scale - 1.0), 0.0);
    }
  }

  @override
  void dispose() {
    _renderZoomTimer?.cancel();
    super.dispose();
  }

  void _resetZoomImmediate() {
    _renderZoomTimer?.cancel();
    _scale = 1.0;
    _panX = 0.0;
    _renderZoom = 1.0;
    _twoFingerMode = _TwoFingerMode.none;
    _trackpadZooming = false;
  }

  double get _scrollOffset =>
      widget.scrollController.hasClients ? widget.scrollController.offset : 0.0;

  double get _unscaledContentHeight {
    final ro = _scaledBoxKey.currentContext?.findRenderObject();
    if (ro is _RenderScaledContentBox && ro.unscaledChildHeight > 0) {
      return math.max(widget.viewportHeight, ro.unscaledChildHeight);
    }
    return widget.viewportHeight;
  }

  static double _bucketForScale(double s) {
    if (s <= 1.05) return 1.0;
    if (s <= 1.75) return 1.75;
    if (s <= 2.6) return 2.6;
    return 3.6;
  }

  void _scheduleRenderZoomUpdate() {
    _renderZoomTimer?.cancel();
    final targetBucket = _bucketForScale(_scale);
    if (targetBucket == 1.0 && _renderZoom != 1.0) {
      setState(() => _renderZoom = 1.0);
      return;
    }
    _renderZoomTimer = Timer(const Duration(milliseconds: 140), () {
      if (!mounted) return;
      final next = _bucketForScale(_scale);
      if ((next - _renderZoom).abs() > 0.01) {
        setState(() => _renderZoom = next);
      }
    });
  }

  void _beginPinchAnchor(double span, Offset viewportFocal) {
    _pinchBaseScale = _scale;
    _pinchStartSpan = math.max(1.0, span);
    _pinchAnchorContent = Offset(
      (viewportFocal.dx - _panX) / _scale,
      (viewportFocal.dy + _scrollOffset) / _scale,
    );
  }

  void _applyAnchoredZoom(double nextScale, Offset viewportFocal) {
    final clampedScale = nextScale.clamp(_minScale, _maxScale);
    final minPanX = -widget.viewportWidth * (clampedScale - 1.0);
    final rawPanX = viewportFocal.dx - _pinchAnchorContent.dx * clampedScale;
    final clampedPanX = rawPanX.clamp(minPanX, 0.0);

    final contentH = _unscaledContentHeight;
    final maxScroll = math.max(0.0, contentH * clampedScale - widget.viewportHeight);
    final rawScrollY = _pinchAnchorContent.dy * clampedScale - viewportFocal.dy;
    final clampedScrollY = rawScrollY.clamp(0.0, maxScroll);

    // 경계 클램핑이 걸렸을 때 반대 방향 조작이 즉시 반응하도록 앵커를 재동기화한다.
    _pinchAnchorContent = Offset(
      (viewportFocal.dx - clampedPanX) / clampedScale,
      (viewportFocal.dy + clampedScrollY) / clampedScale,
    );

    setState(() {
      _scale = clampedScale;
      _panX = clampedPanX;
    });

    if (widget.scrollController.hasClients) {
      final position = widget.scrollController.position;
      if ((position.pixels - clampedScrollY).abs() > 0.1) {
        position.correctPixels(clampedScrollY);
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        position.notifyListeners();
      }
    }
  }

  void _zoomAtPoint(double nextScale, Offset viewportPoint) {
    final clamped = nextScale < 1.03 ? 1.0 : nextScale.clamp(_minScale, _maxScale);
    _pinchAnchorContent = Offset(
      (viewportPoint.dx - _panX) / _scale,
      (viewportPoint.dy + _scrollOffset) / _scale,
    );
    _applyAnchoredZoom(clamped, viewportPoint);
    _scheduleRenderZoomUpdate();
  }

  (Offset, Offset) _firstTwoPointers() {
    final it = _touchPointers.values.iterator;
    it.moveNext();
    final a = it.current;
    it.moveNext();
    final b = it.current;
    return (a, b);
  }

  void _handleTouchDown(PointerDownEvent event) {
    _touchPointers[event.pointer] = event.localPosition;
    if (_touchPointers.length == 2) {
      final (p1, p2) = _firstTwoPointers();
      final span = (p1 - p2).distance;
      final center = (p1 + p2) / 2.0;
      _twoFingerStartSpan = span;
      _twoFingerStartCenter = center;
      if (_scale > 1.02) {
        _twoFingerMode = _TwoFingerMode.zoom;
        _beginPinchAnchor(span, center);
        setState(() {});
      } else {
        _twoFingerMode = _TwoFingerMode.undecided;
      }
    }
  }

  void _handleTouchMove(PointerMoveEvent event) {
    final prevPos = _touchPointers[event.pointer];
    if (prevPos == null) return;
    _touchPointers[event.pointer] = event.localPosition;

    if (_touchPointers.length == 1) {
      // 확대 상태에서는 1손가락 가로 드래그로 좌우 이동도 함께 지원 (세로는 ScrollView 담당).
      if (_scale > 1.01 && _twoFingerMode == _TwoFingerMode.none) {
        final dx = event.localPosition.dx - prevPos.dx;
        if (dx != 0) {
          final nextPanX =
              (_panX + dx).clamp(-widget.viewportWidth * (_scale - 1.0), 0.0);
          if ((nextPanX - _panX).abs() > 0.05) {
            setState(() => _panX = nextPanX);
          }
        }
      }
      return;
    }

    final (p1, p2) = _firstTwoPointers();
    final span = (p1 - p2).distance;
    final center = (p1 + p2) / 2.0;

    if (_twoFingerMode == _TwoFingerMode.undecided) {
      final spanDelta = (span - _twoFingerStartSpan).abs();
      final dx = center.dx - _twoFingerStartCenter.dx;
      final dy = center.dy - _twoFingerStartCenter.dy;

      if (_twoFingerStartSpan >= 20.0 && spanDelta >= _pinchCommitDelta) {
        _twoFingerMode = _TwoFingerMode.zoom;
        _beginPinchAnchor(span, center);
        setState(() {});
        return;
      }
      if (dx.abs() >= _horizontalSwipeThreshold && dx.abs() >= dy.abs() * 1.2) {
        _twoFingerMode = _TwoFingerMode.swiped;
        widget.onSwipe?.call(dx < 0 ? 1 : -1);
        return;
      }
      if (dy.abs() >= _verticalSwipeThreshold && dy.abs() >= dx.abs() * 1.2) {
        _twoFingerMode = _TwoFingerMode.swiped;
        if (dy < 0) {
          widget.onSwipeUp?.call();
        } else {
          widget.onSwipeDown?.call();
        }
        return;
      }
      return;
    }

    if (_twoFingerMode == _TwoFingerMode.zoom && _pinchStartSpan > 8.0) {
      final targetScale = _pinchBaseScale * (span / _pinchStartSpan);
      _applyAnchoredZoom(targetScale, center);
    }
  }

  void _handleTouchEnd(PointerEvent event) {
    if (!_touchPointers.containsKey(event.pointer)) return;
    _touchPointers.remove(event.pointer);
    if (_touchPointers.length < 2 && _twoFingerMode != _TwoFingerMode.none) {
      final wasZoom = _twoFingerMode == _TwoFingerMode.zoom;
      _twoFingerMode = _TwoFingerMode.none;
      if (_scale < 1.03) {
        setState(() {
          _scale = 1.0;
          _panX = 0.0;
          _renderZoom = 1.0;
        });
      } else if (wasZoom) {
        setState(() {});
        _scheduleRenderZoomUpdate();
      }
    }
  }

  Offset _globalToViewport(Offset globalPos) {
    final ro = context.findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      return ro.globalToLocal(globalPos);
    }
    return globalPos;
  }

  @override
  Widget build(BuildContext context) {
    final lockScroll = _twoFingerMode == _TwoFingerMode.zoom || _trackpadZooming;
    return ClipRect(
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          if (event.kind == PointerDeviceKind.touch) {
            _handleTouchDown(event);
          }
        },
        onPointerMove: (event) {
          if (event.kind == PointerDeviceKind.touch) {
            _handleTouchMove(event);
          }
        },
        onPointerUp: (event) {
          if (event.kind == PointerDeviceKind.touch) {
            _handleTouchEnd(event);
          }
        },
        onPointerCancel: (event) {
          if (event.kind == PointerDeviceKind.touch) {
            _handleTouchEnd(event);
          }
        },
        onPointerPanZoomStart: (event) {
          _trackpadZooming = false;
          _trackpadBaseScale = _scale;
        },
        onPointerPanZoomUpdate: (event) {
          if (!_trackpadZooming && (event.scale - 1.0).abs() >= 0.02) {
            _trackpadZooming = true;
            _trackpadBaseScale = _scale / event.scale;
            _beginPinchAnchor(100.0, event.localPosition);
            setState(() {});
          }
          if (_trackpadZooming) {
            final target = _trackpadBaseScale * event.scale;
            final focal = event.localPosition + event.localPanDelta;
            _pinchAnchorContent = Offset(
              (event.localPosition.dx - _panX) / _scale,
              (event.localPosition.dy + _scrollOffset) / _scale,
            );
            _applyAnchoredZoom(target, focal);
          } else if (_scale > 1.01 && event.localPanDelta.dx != 0) {
            final nextPanX = (_panX + event.localPanDelta.dx)
                .clamp(-widget.viewportWidth * (_scale - 1.0), 0.0);
            if ((nextPanX - _panX).abs() > 0.05) {
              setState(() => _panX = nextPanX);
            }
          }
        },
        onPointerPanZoomEnd: (_) {
          if (_trackpadZooming) {
            _trackpadZooming = false;
            if (_scale < 1.03) {
              setState(() {
                _scale = 1.0;
                _panX = 0.0;
                _renderZoom = 1.0;
              });
            } else {
              setState(() {});
              _scheduleRenderZoomUpdate();
            }
          }
        },
        child: SingleChildScrollView(
          controller: widget.scrollController,
          physics: lockScroll ? const NeverScrollableScrollPhysics() : null,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerSignal: (signal) {
              if (signal is PointerScaleEvent) {
                GestureBinding.instance.pointerSignalResolver.register(
                  signal,
                  (ev) {
                    final s = ev as PointerScaleEvent;
                    _zoomAtPoint(
                      _scale * s.scale,
                      _globalToViewport(s.position),
                    );
                  },
                );
              } else if (signal is PointerScrollEvent) {
                if (HardwareKeyboard.instance.isControlPressed &&
                    signal.scrollDelta.dy != 0) {
                  GestureBinding.instance.pointerSignalResolver.register(
                    signal,
                    (ev) {
                      final s = ev as PointerScrollEvent;
                      final factor = math.exp(-s.scrollDelta.dy / 300.0);
                      _zoomAtPoint(
                        _scale * factor,
                        _globalToViewport(s.position),
                      );
                    },
                  );
                } else if (_scale > 1.01 && signal.scrollDelta.dx != 0) {
                  final nextPanX = (_panX - signal.scrollDelta.dx)
                      .clamp(-widget.viewportWidth * (_scale - 1.0), 0.0);
                  if ((nextPanX - _panX).abs() > 0.05) {
                    setState(() => _panX = nextPanX);
                  }
                }
              }
            },
            child: _ZoomRenderScale(
              scale: _renderZoom,
              child: _ScaledContentBox(
                key: _scaledBoxKey,
                scale: _scale,
                panX: _panX,
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScaledContentBox extends SingleChildRenderObjectWidget {
  const _ScaledContentBox({
    super.key,
    required this.scale,
    required this.panX,
    required super.child,
  });

  final double scale;
  final double panX;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderScaledContentBox(scale: scale, panX: panX);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderScaledContentBox renderObject,
  ) {
    renderObject
      ..scale = scale
      ..panX = panX;
  }
}

class _RenderScaledContentBox extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  _RenderScaledContentBox({
    required double scale,
    required double panX,
  })  : _scale = scale,
        _panX = panX;

  double _scale;
  double get scale => _scale;
  set scale(double value) {
    if (_scale == value) return;
    _scale = value;
    markNeedsLayout();
  }

  double _panX;
  double get panX => _panX;
  set panX(double value) {
    if (_panX == value) return;
    _panX = value;
    markNeedsPaint();
  }

  double unscaledChildHeight = 0;

  Matrix4 _buildTransform() =>
      Matrix4.diagonal3Values(_scale, _scale, 1.0)
        ..setTranslationRaw(_panX, 0.0, 0.0);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final c = child;
    if (c == null) return constraints.smallest;
    final childSize = c.getDryLayout(
      BoxConstraints(
        minWidth: constraints.minWidth,
        maxWidth: constraints.maxWidth,
      ),
    );
    return constraints.constrain(
      Size(childSize.width, childSize.height * _scale),
    );
  }

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      unscaledChildHeight = 0;
      size = constraints.smallest;
      return;
    }
    c.layout(
      BoxConstraints(
        minWidth: constraints.minWidth,
        maxWidth: constraints.maxWidth,
      ),
      parentUsesSize: true,
    );
    unscaledChildHeight = c.size.height;
    size = constraints.constrain(
      Size(c.size.width, c.size.height * _scale),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final c = child;
    if (c == null) return;
    if (_scale == 1.0 && _panX == 0.0) {
      layer = null;
      context.paintChild(c, offset);
      return;
    }
    layer = context.pushTransform(
      needsCompositing,
      offset,
      _buildTransform(),
      (PaintingContext ctx, Offset ofs) => ctx.paintChild(c, ofs),
      oldLayer: layer is TransformLayer ? layer as TransformLayer? : null,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final c = child;
    if (c == null) return false;
    if (_scale == 1.0 && _panX == 0.0) {
      return c.hitTest(result, position: position);
    }
    return result.addWithPaintTransform(
      transform: _buildTransform(),
      position: position,
      hitTest: (BoxHitTestResult res, Offset transformed) =>
          c.hitTest(res, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {
    if (_scale == 1.0 && _panX == 0.0) return;
    transform.multiply(_buildTransform());
  }
}

/// 두 손가락 쓸기로 문항 이동 및 연습장 열기·닫기.
///
/// 펜슬(스타일러스)은 제외하고 손가락 터치 포인터가 2개일 때만 인식한다.
/// - 왼쪽 쓸기 = 다음 문항(+1), 오른쪽 쓸기 = 이전 문항(-1)
/// - 위로 쓸기 = 연습장 열기, 아래로 쓸기 = 연습장 접기(닫기)
class _TwoFingerHorizontalSwipe extends StatefulWidget {
  const _TwoFingerHorizontalSwipe({
    required this.onSwipe,
    this.onSwipeUp,
    this.onSwipeDown,
    required this.child,
  });

  final ValueChanged<int> onSwipe;
  final VoidCallback? onSwipeUp;
  final VoidCallback? onSwipeDown;
  final Widget child;

  @override
  State<_TwoFingerHorizontalSwipe> createState() =>
      _TwoFingerHorizontalSwipeState();
}

class _TwoFingerHorizontalSwipeState extends State<_TwoFingerHorizontalSwipe> {
  final Map<int, Offset> _pointers = <int, Offset>{};
  Offset? _startAvg;
  bool _armed = false;
  bool _fired = false;
  static const _horizontalThreshold = 72.0;
  static const _verticalThreshold = 56.0;

  static bool _isTouchPointer(PointerEvent event) =>
      event.kind == PointerDeviceKind.touch;

  Offset _average() {
    var sum = Offset.zero;
    for (final p in _pointers.values) {
      sum += p;
    }
    return sum / _pointers.length.toDouble();
  }

  void _resetGesture() {
    _armed = false;
    _fired = false;
    _startAvg = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (!_isTouchPointer(event)) return;
        _pointers[event.pointer] = event.position;
        if (_pointers.length == 2) {
          _armed = true;
          _fired = false;
          _startAvg = _average();
        }
      },
      onPointerMove: (event) {
        if (!_pointers.containsKey(event.pointer)) return;
        _pointers[event.pointer] = event.position;
        if (!_armed || _fired || _pointers.length < 2 || _startAvg == null) {
          return;
        }
        final dx = _average().dx - _startAvg!.dx;
        final dy = _average().dy - _startAvg!.dy;
        if (dx.abs() >= _horizontalThreshold && dx.abs() >= dy.abs() * 1.2) {
          _fired = true;
          widget.onSwipe(dx < 0 ? 1 : -1);
          return;
        }
        if (dy.abs() >= _verticalThreshold && dy.abs() >= dx.abs() * 1.2) {
          if (dy < 0 && widget.onSwipeUp != null) {
            _fired = true;
            widget.onSwipeUp!();
          } else if (dy > 0 && widget.onSwipeDown != null) {
            _fired = true;
            widget.onSwipeDown!();
          }
        }
      },
      onPointerUp: (event) {
        _pointers.remove(event.pointer);
        if (_pointers.length < 2) _resetGesture();
      },
      onPointerCancel: (event) {
        _pointers.remove(event.pointer);
        if (_pointers.length < 2) _resetGesture();
      },
      child: widget.child,
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

class _SolveHeaderIconButton extends StatelessWidget {
  const _SolveHeaderIconButton({
    required this.tooltip,
    required this.svg,
    required this.onPressed,
  });

  final String tooltip;
  final String svg;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      icon: SvgPicture.string(
        svg,
        width: 22,
        height: 22,
        colorFilter: const ColorFilter.mode(Colors.black, BlendMode.srcIn),
      ),
    );
  }
}

/// Icons8 iOS Outlined "Empty Flag" (id 11710).
const String _reportFlagSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 50 50"><path d="M 9 0.5 L 9 49 L 11 49 L 11 30.6875 L 44.375 16.9375 L 46.625 16 L 44.375 15.0625 L 10.375 1.0625 Z M 11 3.5 L 41.34375 16 L 11 28.5 Z"/></svg>';

/// Icons8 iOS Outlined "Pencil" (id 11737).
const String _pencilModeSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 50 50"><path d="M 42.90625 2.90625 C 41.851563 2.90625 40.796875 3.296875 40 4.09375 L 39.15625 4.90625 C 38.953125 4.800781 38.722656 4.769531 38.5 4.8125 C 38.308594 4.855469 38.136719 4.953125 38 5.09375 L 6.59375 36.5 C 6.496094 36.597656 6.421875 36.714844 6.375 36.84375 L 3.0625 45.65625 C 2.929688 46.019531 3.019531 46.429688 3.296875 46.703125 C 3.570313 46.980469 3.980469 47.070313 4.34375 46.9375 L 13.15625 43.625 C 13.285156 43.578125 13.402344 43.503906 13.5 43.40625 L 44.90625 12 C 45.242188 11.652344 45.285156 11.113281 45 10.71875 L 45.8125 9.90625 C 47.40625 8.3125 47.40625 5.6875 45.8125 4.09375 C 45.015625 3.296875 43.960938 2.90625 42.90625 2.90625 Z M 42.90625 4.90625 C 43.453125 4.90625 44.003906 5.097656 44.40625 5.5 C 45.214844 6.308594 45.214844 7.691406 44.40625 8.5 L 43.625 9.3125 L 40.625 6.3125 L 41.40625 5.5 C 41.808594 5.097656 42.359375 4.90625 42.90625 4.90625 Z M 38.6875 7.1875 L 42.8125 11.3125 L 40.0625 14.03125 L 35.96875 9.9375 Z M 34.53125 11.34375 L 38.65625 15.46875 L 12.75 41.34375 L 12 40.5625 L 12 39 C 12 38.449219 11.550781 38 11 38 L 9.4375 38 L 8.65625 37.25 Z M 7.65625 39.09375 L 8.28125 39.71875 C 8.472656 39.90625 8.734375 40.007813 9 40 L 10 40 L 10 41 C 9.992188 41.265625 10.09375 41.527344 10.28125 41.71875 L 10.90625 42.34375 L 7.09375 43.78125 L 6.21875 42.90625 Z"/></svg>';

/// Icons8 iOS Outlined "Square Root" (id 6485).
const String _formulaModeSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 50 50"><path d="M 31.8125 9 C 31.472656 9.0625 31.1875 9.300781 31.0625 9.625 L 19.9375 37.46875 L 13.90625 24.5625 C 13.738281 24.214844 13.386719 23.996094 13 24 L 9 24 L 9 26 L 12.34375 26 L 19.09375 40.4375 C 19.261719 40.804688 19.632813 41.03125 20.035156 41.019531 C 20.4375 41.007813 20.792969 40.75 20.9375 40.375 L 32.6875 11 L 41 11 L 41 9 L 32 9 C 31.96875 9 31.9375 9 31.90625 9 C 31.875 9 31.84375 9 31.8125 9 Z"/></svg>';

/// Icons8 iOS Outlined "Keypad" (id 23272).
const String _keyboardModeSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 50 50"><path d="M 5 3 C 3.90625 3 3 3.90625 3 5 L 3 9 C 3 10.09375 3.90625 11 5 11 L 13 11 C 14.09375 11 15 10.09375 15 9 L 15 5 C 15 3.90625 14.09375 3 13 3 Z M 21 3 C 19.90625 3 19 3.90625 19 5 L 19 9 C 19 10.09375 19.90625 11 21 11 L 29 11 C 30.09375 11 31 10.09375 31 9 L 31 5 C 31 3.90625 30.09375 3 29 3 Z M 37 3 C 35.90625 3 35 3.90625 35 5 L 35 9 C 35 10.09375 35.90625 11 37 11 L 45 11 C 46.09375 11 47 10.09375 47 9 L 47 5 C 47 3.90625 46.09375 3 45 3 Z M 5 5 L 13 5 L 13 9 L 5 9 Z M 21 5 L 29 5 L 29 9 L 21 9 Z M 37 5 L 45 5 L 45 9 L 37 9 Z M 5 15 C 3.90625 15 3 15.90625 3 17 L 3 21 C 3 22.09375 3.90625 23 5 23 L 13 23 C 14.09375 23 15 22.09375 15 21 L 15 17 C 15 15.90625 14.09375 15 13 15 Z M 21 15 C 19.90625 15 19 15.90625 19 17 L 19 21 C 19 22.09375 19.90625 23 21 23 L 29 23 C 30.09375 23 31 22.09375 31 21 L 31 17 C 31 15.90625 30.09375 15 29 15 Z M 37 15 C 35.90625 15 35 15.90625 35 17 L 35 21 C 35 22.09375 35.90625 23 37 23 L 45 23 C 46.09375 23 47 22.09375 47 21 L 47 17 C 47 15.90625 46.09375 15 45 15 Z M 5 17 L 13 17 L 13 21 L 5 21 Z M 21 17 L 29 17 L 29 21 L 21 21 Z M 37 17 L 45 17 L 45 21 L 37 21 Z M 5 27 C 3.90625 27 3 27.90625 3 29 L 3 33 C 3 34.09375 3.90625 35 5 35 L 13 35 C 14.09375 35 15 34.09375 15 33 L 15 29 C 15 27.90625 14.09375 27 13 27 Z M 21 27 C 19.90625 27 19 27.90625 19 29 L 19 33 C 19 34.09375 19.90625 35 21 35 L 29 35 C 30.09375 35 31 34.09375 31 33 L 31 29 C 31 27.90625 30.09375 27 29 27 Z M 37 27 C 35.90625 27 35 27.90625 35 29 L 35 33 C 35 34.09375 35.90625 35 37 35 L 45 35 C 46.09375 35 47 34.09375 47 33 L 47 29 C 47 27.90625 46.09375 27 45 27 Z M 5 29 L 13 29 L 13 33 L 5 33 Z M 21 29 L 29 29 L 29 33 L 21 33 Z M 37 29 L 45 29 L 45 33 L 37 33 Z M 21 39 C 19.90625 39 19 39.90625 19 41 L 19 45 C 19 46.09375 19.90625 47 21 47 L 29 47 C 30.09375 47 31 46.09375 31 45 L 31 41 C 31 39.90625 30.09375 39 29 39 Z M 21 41 L 29 41 L 29 45 L 21 45 Z"/></svg>';

/// 학습앱 정답 시트의 확인 버튼과 같은 한 겹 알약.
const String _gradeCheckSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none"><path stroke="#000" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" d="M 2.8 11.54 L 8.74 16.76 L 17.2 3.86"/></svg>';

class _TextbookSolveFabBar extends StatefulWidget {
  const _TextbookSolveFabBar({
    required this.pendingCount,
    required this.grading,
    required this.onGrade,
    this.gradeLabel = '채점',
  });

  final int pendingCount;
  final bool grading;
  final VoidCallback onGrade;
  final String gradeLabel;

  @override
  State<_TextbookSolveFabBar> createState() => _TextbookSolveFabBarState();
}

class _TextbookSolveFabBarState extends State<_TextbookSolveFabBar> {
  bool _hovering = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final canTap = widget.pendingCount > 0 && !widget.grading;
    const accent = YggGlassTokens.confirmActionColor;
    final color = _hovering && canTap
        ? Color.lerp(accent, Colors.white, 0.16)!
        : accent;
    return AnimatedScale(
      scale: _pressed && canTap ? 0.96 : 1,
      duration: Duration(milliseconds: _pressed ? 70 : 140),
      curve: _pressed ? Curves.easeOutCubic : Curves.easeOutBack,
      child: Opacity(
        opacity: canTap ? 1 : 0.45,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) {
            setState(() {
              _hovering = false;
              _pressed = false;
            });
          },
          cursor: canTap ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            onTapDown: canTap ? (_) => setState(() => _pressed = true) : null,
            onTapUp: canTap ? (_) => setState(() => _pressed = false) : null,
            onTapCancel: canTap ? () => setState(() => _pressed = false) : null,
            onTap: canTap ? widget.onGrade : null,
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: 120,
              height: 52,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                alignment: Alignment.center,
                padding: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(26),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Transform.translate(
                      offset: const Offset(0, -1),
                      child: widget.grading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Badge(
                              isLabelVisible: widget.pendingCount > 0,
                              backgroundColor: Colors.white,
                              textColor: accent,
                              label: Text('${widget.pendingCount}'),
                              child: SvgPicture.string(
                                _gradeCheckSvg,
                                width: 20,
                                height: 20,
                                colorFilter: const ColorFilter.mode(
                                  Colors.white,
                                  BlendMode.srcIn,
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.gradeLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontFamily: 'Pretendard',
                        fontSize: 18,
                        height: 1,
                        letterSpacing: 1.4,
                        fontWeight: FontWeight.w400,
                      ),
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

/// iOS 스타일 페이지(단원) 슬라이드 시트.
class _IosPageSheet extends StatelessWidget {
  const _IosPageSheet({
    required this.onClose,
    required this.child,
  });

  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) > 220) onClose();
      },
      child: Material(
        color: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(16),
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 28,
                offset: Offset(-6, 0),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '페이지',
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                      ),
                    ),
                    IconButton(
                      tooltip: '닫기',
                      onPressed: onClose,
                      icon: Icon(
                        Icons.close_rounded,
                        color: isDark ? Colors.white70 : Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                thickness: 0.5,
                color: isDark ? Colors.white12 : Colors.black12,
              ),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

/// 임시 연습장 — 채점/저장 없는 필기 공간.
class _ScratchPracticeSheet extends StatefulWidget {
  const _ScratchPracticeSheet({
    super.key,
    required this.onHandleTap,
    required this.onHeightDrag,
    required this.onClose,
  });

  final VoidCallback onHandleTap;
  final ValueChanged<double> onHeightDrag;
  final VoidCallback onClose;

  @override
  State<_ScratchPracticeSheet> createState() => _ScratchPracticeSheetState();
}

class _ScratchPracticeSheetState extends State<_ScratchPracticeSheet> {
  final List<List<Offset>> _strokes = <List<Offset>>[];
  int? _activePointer;
  bool _activeIsStylus = false;
  int _touchPointerCount = 0;
  Offset? _strokeStartGlobal;
  bool _strokeIsDraw = false;
  static const _tapSlop = 10.0;

  void clearStrokes() => setState(() => _strokes.clear());

  void _startStroke(Offset position) {
    setState(() => _strokes.add(<Offset>[position]));
  }

  void _extendStroke(Offset position) {
    if (_strokes.isEmpty) return;
    final previous = _strokes.last.last;
    final distance = (position - previous).distance;
    // 마우스 이벤트는 간격이 클 수 있어 보간해 선으로 이어 준다.
    final steps = (distance / 2.5).ceil().clamp(1, 48);
    setState(() {
      for (var step = 1; step <= steps; step++) {
        final t = step / steps;
        _strokes.last.add(Offset.lerp(previous, position, t)!);
      }
    });
  }

  void _discardLastStroke() {
    if (_strokes.isEmpty) return;
    setState(() => _strokes.removeLast());
  }

  void _finishStroke() {
    if (_strokes.length < 2) return;
    final scribble = _strokes.last;
    final committed = _strokes.sublist(0, _strokes.length - 1);
    final targets = scribbleEraseIndices(committed, scribble);
    if (targets.isEmpty) return;
    setState(() {
      _strokes.removeLast();
      for (var i = targets.length - 1; i >= 0; i--) {
        _strokes.removeAt(targets[i]);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const radius = BorderRadius.vertical(top: Radius.circular(18));
    final surface = isDark ? const Color(0xFF1C1C1E) : Colors.white;
    // 모달 형태: 바깥 decoration 에 라운드+위쪽 그림자, 안쪽만 ClipRRect.
    // (elevation/Clip.none 조합은 화면 옆으로 그림자가 번짐)
    return Padding(
      padding: const EdgeInsets.only(top: _kScratchTopShadow),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: surface,
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Color(isDark ? 0x66000000 : 0x33000000),
              blurRadius: 22,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Column(
            children: [
              // 상단 크롬(핸들+타이틀): 탭=접기/펼치기, 세로 드래그=높이.
              _ScratchSheetHandle(
                onTap: widget.onHandleTap,
                onHeightDrag: widget.onHeightDrag,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 28,
                      width: double.infinity,
                      child: Center(
                        child: Container(
                          width: 44,
                          height: 5,
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.28)
                                : Colors.black.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
                      child: Row(
                        children: [
                          Text(
                            '연습장',
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: clearStrokes,
                            child: const Text('지우기'),
                          ),
                          IconButton(
                            tooltip: '닫기',
                            onPressed: widget.onClose,
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, thickness: 0.5),
              Expanded(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) {
                    final isStylus = event.kind == PointerDeviceKind.stylus ||
                        event.kind == PointerDeviceKind.invertedStylus;
                    if (!isStylus) {
                      _touchPointerCount += 1;
                      if (_touchPointerCount >= 2) {
                        if (_activePointer != null && !_activeIsStylus) {
                          _discardLastStroke();
                          _activePointer = null;
                          _strokeStartGlobal = null;
                          _strokeIsDraw = false;
                        }
                        return;
                      }
                    } else if (_activePointer != null && !_activeIsStylus) {
                      _discardLastStroke();
                      _activePointer = null;
                      _strokeStartGlobal = null;
                      _strokeIsDraw = false;
                    }
                    if (_activePointer != null) return;
                    _activePointer = event.pointer;
                    _activeIsStylus = isStylus;
                    _strokeStartGlobal = event.position;
                    _strokeIsDraw = false;
                    _startStroke(event.localPosition);
                  },
                  onPointerMove: (event) {
                    if (_activePointer != event.pointer) return;
                    if (!_activeIsStylus && _touchPointerCount >= 2) return;
                    final start = _strokeStartGlobal;
                    if (start != null &&
                        !_strokeIsDraw &&
                        (event.position - start).distance >= _tapSlop) {
                      _strokeIsDraw = true;
                    }
                    if (_strokeIsDraw) {
                      _extendStroke(event.localPosition);
                    }
                  },
                  onPointerUp: (event) {
                    final isStylus = event.kind == PointerDeviceKind.stylus ||
                        event.kind == PointerDeviceKind.invertedStylus;
                    if (!isStylus) {
                      _touchPointerCount =
                          (_touchPointerCount - 1).clamp(0, 10).toInt();
                    }
                    if (_activePointer != event.pointer) return;
                    // 짧게 터치만 하면 접기/펼치기 (점 남기지 않음).
                    if (!_strokeIsDraw) {
                      _discardLastStroke();
                      widget.onHandleTap();
                    } else {
                      _finishStroke();
                    }
                    _activePointer = null;
                    _activeIsStylus = false;
                    _strokeStartGlobal = null;
                    _strokeIsDraw = false;
                  },
                  onPointerCancel: (event) {
                    final isStylus = event.kind == PointerDeviceKind.stylus ||
                        event.kind == PointerDeviceKind.invertedStylus;
                    if (!isStylus) {
                      _touchPointerCount =
                          (_touchPointerCount - 1).clamp(0, 10).toInt();
                    }
                    if (_activePointer != event.pointer) return;
                    if (!_strokeIsDraw) _discardLastStroke();
                    _activePointer = null;
                    _activeIsStylus = false;
                    _strokeStartGlobal = null;
                    _strokeIsDraw = false;
                  },
                  child: ColoredBox(
                    color: Colors.transparent,
                    child: CustomPaint(
                      painter: _ScratchStrokePainter(
                        strokes: _strokes,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 연습장 상단 크롬 — 짧은 터치는 접기/펼치기, 세로 이동은 높이 드래그.
/// 자식 버튼(지우기/닫기)은 Listener 보다 먼저 히트되므로 그대로 동작한다.
class _ScratchSheetHandle extends StatefulWidget {
  const _ScratchSheetHandle({
    required this.onTap,
    required this.onHeightDrag,
    required this.child,
  });

  final VoidCallback onTap;
  final ValueChanged<double> onHeightDrag;
  final Widget child;

  @override
  State<_ScratchSheetHandle> createState() => _ScratchSheetHandleState();
}

class _ScratchSheetHandleState extends State<_ScratchSheetHandle> {
  int? _pointer;
  Offset? _start;
  bool _dragging = false;
  static const _dragSlop = 10.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (_pointer != null) return;
        _pointer = event.pointer;
        _start = event.position;
        _dragging = false;
      },
      onPointerMove: (event) {
        if (_pointer != event.pointer || _start == null) return;
        final dy = event.position.dy - _start!.dy;
        if (!_dragging && dy.abs() >= _dragSlop) {
          _dragging = true;
        }
        if (_dragging) {
          widget.onHeightDrag(event.delta.dy);
        }
      },
      onPointerUp: (event) {
        if (_pointer != event.pointer) return;
        // 거의 움직이지 않은 터치는 접기/펼치기.
        // (버튼이 onPressed 를 받은 경우에도 높이 토글이 겹칠 수 있어,
        //  버튼 hit 영역은 자식이 absorb — Listener 는 버블만 받음.
        //  버튼 탭은 보통 작은 이동이므로, 버튼 위에서는 토글을 건너뛴다.)
        if (!_dragging) {
          final box = context.findRenderObject() as RenderBox?;
          if (box != null) {
            final local = box.globalToLocal(event.position);
            final size = box.size;
            // 오른쪽 액션 버튼 영역(대략 마지막 140px)은 토글 제외.
            if (local.dx < size.width - 140) {
              widget.onTap();
            }
          } else {
            widget.onTap();
          }
        }
        _pointer = null;
        _start = null;
        _dragging = false;
      },
      onPointerCancel: (event) {
        if (_pointer != event.pointer) return;
        _pointer = null;
        _start = null;
        _dragging = false;
      },
      child: widget.child,
    );
  }
}

class _ScratchStrokePainter extends CustomPainter {
  const _ScratchStrokePainter({
    required this.strokes,
    required this.color,
  });

  final List<List<Offset>> strokes;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final strokePaint = Paint()
      ..color = color
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final dotPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    for (final stroke in strokes) {
      if (stroke.length < 2) {
        if (stroke.isNotEmpty) {
          canvas.drawCircle(stroke.first, 1.2, dotPaint);
        }
        continue;
      }
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (var i = 1; i < stroke.length; i++) {
        path.lineTo(stroke[i].dx, stroke[i].dy);
      }
      canvas.drawPath(path, strokePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ScratchStrokePainter oldDelegate) => true;
}

class _ReportProblemInput {
  const _ReportProblemInput({required this.issueTypes, required this.note});

  final List<String> issueTypes;
  final String note;
}

/// 문항 신고 다이얼로그 — 사유 선택 후 접수하면 문항이 검토 중(보류)이 된다.
class _ReportProblemDialog extends StatefulWidget {
  const _ReportProblemDialog({required this.problemNumber});

  final String problemNumber;

  @override
  State<_ReportProblemDialog> createState() => _ReportProblemDialogState();
}

class _ReportProblemDialogState extends State<_ReportProblemDialog> {
  static const List<(String, String)> _issueOptions = [
    ('question_error', '문제가 이상해요'),
    ('answer_error', '정답이 잘못된 것 같아요'),
    ('answer_input_blocked', '정답 입력이 안되요'),
    ('handwriting_recognition', '필기 인식이 잘 안돼요'),
    ('render_error', '문항이 잘리거나 그림이 이상해요'),
    ('other', '기타'),
  ];

  /// 필기 인식 신고만 단독 선택하면 문항은 보류되지 않는다.
  bool get _handwritingOnly =>
      _selectedTypes.length == 1 &&
      _selectedTypes.contains('handwriting_recognition');

  final Set<String> _selectedTypes = <String>{};
  final TextEditingController _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    const accent = YggGlassTokens.confirmActionColor;

    return Dialog(
      backgroundColor: isDark ? const Color(0xFF1F2A2A) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${widget.problemNumber}번 문항 신고',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _handwritingOnly
                    ? '방금 쓴 필기가 함께 전송돼 인식 개선에 사용돼요. 문항은 계속 풀 수 있어요.'
                    : '접수하면 선생님이 확인할 때까지 이 문항은 채점에서 제외돼요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (key, label) in _issueOptions)
                    FilterChip(
                      label: Text(label),
                      selected: _selectedTypes.contains(key),
                      selectedColor: accent.withValues(alpha: 0.16),
                      checkmarkColor: accent,
                      onSelected: (on) => setState(() {
                        if (on) {
                          _selectedTypes.add(key);
                        } else {
                          _selectedTypes.remove(key);
                        }
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _noteController,
                maxLines: 3,
                minLines: 2,
                decoration: InputDecoration(
                  hintText: '자세한 내용이 있으면 적어 주세요 (선택)',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('취소'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _selectedTypes.isEmpty
                        ? null
                        : () => Navigator.of(context).pop(
                              _ReportProblemInput(
                                issueTypes:
                                    _selectedTypes.toList(growable: false),
                                note: _noteController.text.trim(),
                              ),
                            ),
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text(
                      '신고 접수',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 문항 번호 텍스트 위에 사람이 빨간 색연필로 넉넉하게 메긴 듯한
/// 동그라미(맞음) / 체크(틀림) 표시를 얹는 래퍼.
class _RedPencilGradeMark extends StatelessWidget {
  const _RedPencilGradeMark({
    super.key,
    required this.gradedResult,
    required this.child,
    this.seed = 0,
    this.scaleFactor = 1.0,
  });

  final bool? gradedResult;
  final Widget child;
  final int seed;
  final double scaleFactor;

  @override
  Widget build(BuildContext context) {
    final res = gradedResult;
    if (res == null) return child;
    return CustomPaint(
      foregroundPainter: _SingleRedPencilGradePainter(
        isCorrect: res,
        seed: seed,
        scaleFactor: scaleFactor,
      ),
      child: child,
    );
  }
}

class _SingleRedPencilGradePainter extends CustomPainter {
  const _SingleRedPencilGradePainter({
    required this.isCorrect,
    required this.seed,
    required this.scaleFactor,
  });

  final bool isCorrect;
  final int seed;
  final double scaleFactor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    _RedPencilStrokeDrawer.paintMark(
      canvas,
      Offset.zero & size,
      isCorrect: isCorrect,
      seed: seed,
      scaleFactor: scaleFactor,
    );
  }

  @override
  bool shouldRepaint(covariant _SingleRedPencilGradePainter oldDelegate) =>
      oldDelegate.isCorrect != isCorrect ||
      oldDelegate.seed != seed ||
      oldDelegate.scaleFactor != scaleFactor;
}

class _BodyRedPencilGradesPainter extends CustomPainter {
  const _BodyRedPencilGradesPainter({required this.marks});

  final List<({Rect rect, bool isCorrect, int seed})> marks;

  @override
  void paint(Canvas canvas, Size size) {
    for (final m in marks) {
      _RedPencilStrokeDrawer.paintMark(
        canvas,
        m.rect,
        isCorrect: m.isCorrect,
        seed: m.seed,
        scaleFactor: 1.0,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BodyRedPencilGradesPainter oldDelegate) {
    if (oldDelegate.marks.length != marks.length) return true;
    for (var i = 0; i < marks.length; i += 1) {
      final a = oldDelegate.marks[i];
      final b = marks[i];
      if (a.rect != b.rect || a.isCorrect != b.isCorrect || a.seed != b.seed) {
        return true;
      }
    }
    return false;
  }
}

class _RedPencilStrokeDrawer {
  _RedPencilStrokeDrawer._();

  static double _unitVariation(int seed, int salt) {
    final h = ((seed ^ (salt * 0x9E3779B9)) * 0x85EBCA6B) & 0x7fffffff;
    return (h % 1000) / 500.0 - 1.0; // -1.0 .. +1.0
  }

  static void paintMark(
    Canvas canvas,
    Rect targetRect, {
    required bool isCorrect,
    required int seed,
    double scaleFactor = 1.0,
  }) {
    final nw = targetRect.width;
    final nh = targetRect.height;
    final cx = targetRect.center.dx;
    final cy = targetRect.center.dy;

    if (isCorrect) {
      // 번호에 딱 붙지 않고 넉넉하게 감싸는 손그림 동그라미.
      final rx =
          math.max(nw * 0.78 + 15.0 * scaleFactor, nh * 1.35 + 11.0 * scaleFactor);
      final ry =
          math.max(nh * 1.12 + 12.0 * scaleFactor, rx * 0.72);
      final tilt = (-0.16) + _unitVariation(seed, 1) * 0.05;
      final cosT = math.cos(tilt);
      final sinT = math.sin(tilt);
      final startDeg = -58.0 + _unitVariation(seed, 2) * 8.0;
      final sweepDeg = -392.0 - (_unitVariation(seed, 3).abs() * 14.0);
      final wavePhase = _unitVariation(seed, 4) * math.pi;

      final path = Path();
      const steps = 44;
      for (var i = 0; i <= steps; i += 1) {
        final t = i / steps;
        final rad = (startDeg + sweepDeg * t) * (math.pi / 180.0);
        // 시작~끝이 살짝 어긋나며 겹치는 자연스러운 손획 반경 변화
        final spiral = 0.94 + 0.13 * t + 0.025 * math.sin(rad * 2.0 + wavePhase);
        final lx = rx * spiral * math.cos(rad);
        final ly = ry * spiral * math.sin(rad);
        final px = cx + lx * cosT - ly * sinT;
        final py = cy + lx * sinT + ly * cosT;
        if (i == 0) {
          path.moveTo(px, py);
        } else {
          path.lineTo(px, py);
        }
      }
      final sw = (math.min(rx, ry) * 0.115).clamp(2.5, 4.2);
      _drawColoredPencilPath(canvas, path, sw);
      return;
    }

    // 틀림: 번호 위를 넉넉하게 가로지르며 우상단으로 길게 뻗는 빨간 색연필 체크(✓).
    final spanW = math.max(nw * 1.15 + 26.0 * scaleFactor, 54.0 * scaleFactor);
    final spanH = math.max(nh * 1.55 + 24.0 * scaleFactor, 46.0 * scaleFactor);
    final jitterX = _unitVariation(seed, 5) * 2.0;
    final jitterY = _unitVariation(seed, 6) * 1.8;

    final start = Offset(
      cx - spanW * 0.36 + jitterX,
      cy - spanH * 0.05 + jitterY,
    );
    final vertex = Offset(
      cx - spanW * 0.11 + jitterX * 0.5,
      cy + spanH * 0.34 - jitterY * 0.4,
    );
    final control = Offset(
      cx + spanW * 0.18,
      cy - spanH * 0.08,
    );
    final end = Offset(
      cx + spanW * 0.62 - jitterX * 0.6,
      cy - spanH * 0.62 + jitterY * 0.5,
    );

    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..lineTo(vertex.dx, vertex.dy)
      ..quadraticBezierTo(control.dx, control.dy, end.dx, end.dy);

    final sw = (math.min(spanW, spanH) * 0.072).clamp(2.7, 4.3);
    _drawColoredPencilPath(canvas, path, sw);
  }

  static void _drawColoredPencilPath(
    Canvas canvas,
    Path path,
    double strokeWidth,
  ) {
    // 종이 결에 묻는 부드러운 색연필 번짐층
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFE03131).withValues(alpha: 0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 1.65
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..blendMode = BlendMode.multiply
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.85),
    );
    // 중심 색연필 심지 획
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFD62828).withValues(alpha: 0.78)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..blendMode = BlendMode.multiply,
    );
    // 색연필 건식 결 1
    canvas.drawPath(
      path.shift(const Offset(-0.6, -0.45)),
      Paint()
        ..color = const Color(0xFFC92A2A).withValues(alpha: 0.34)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 0.52
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..blendMode = BlendMode.multiply,
    );
    // 색연필 건식 결 2
    canvas.drawPath(
      path.shift(const Offset(0.55, 0.45)),
      Paint()
        ..color = const Color(0xFFE84545).withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 0.44
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..blendMode = BlendMode.multiply,
    );
  }
}

/// 셀프 채점 다이얼로그 — 정답을 보여주고 학생이 O/X 선택.
/// [viewOnly]면 채점 버튼 없이 정답 확인만 한다 (답지 표기 비교용).
class _SelfCheckDialog extends StatelessWidget {
  const _SelfCheckDialog({
    required this.title,
    required this.revealed,
    this.myAnswer,
    this.viewOnly = false,
  });

  final String title;
  final RevealedAnswer revealed;
  final String? myAnswer;
  final bool viewOnly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    const accent = YggGlassTokens.confirmActionColor;
    const wrongColor = Color(0xFFE57373);
    final isImageAnswer =
        revealed.answerKind.trim().toLowerCase() == 'image' &&
            (revealed.imageUrl?.trim().isNotEmpty ?? false);
    final displayAnswer = ConfirmedAnswerMathFormatter.selectDisplayAnswer(
      answerKind: revealed.answerKind,
      answerText: revealed.answerText,
      answerLatex2d: revealed.answerLatex2d,
    );

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
                title,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              if (isImageAnswer)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
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
                    errorBuilder: (_, __, ___) =>
                        displayAnswer == '-'
                            ? Text(
                                '(정답 이미지를 불러오지 못했어요)',
                                style: theme.textTheme.titleMedium
                                    ?.copyWith(color: Colors.black87),
                              )
                            : ConfirmedAnswerMathView(
                                displayAnswer: displayAnswer,
                              ),
                  ),
                )
              else
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x1F000000)),
                  ),
                  child: displayAnswer == '-'
                      ? Text(
                          '(등록된 정답 표기가 없어요)',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.black87,
                            fontWeight: FontWeight.w600,
                            height: 1.5,
                          ),
                        )
                      : ConfirmedAnswerMathView(
                          displayAnswer: displayAnswer,
                        ),
                ),
              if (myAnswer != null && myAnswer!.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      '내가 쓴 답:  ',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.hintColor),
                    ),
                    Flexible(
                      child: MathLatexView.linear(
                        myAnswer!.trim(),
                        fontSize: 17,
                        color: theme.hintColor,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              if (viewOnly)
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('확인',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                )
              else ...[
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
            ],
          ),
        ),
      ),
    );
  }
}
