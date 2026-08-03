import 'dart:async';
import 'dart:convert' show base64Encode;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pdfrx/pdfrx.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/handwriting_candidates.dart';
import '../services/student_api.dart';
import '../services/textbook_api.dart';
import '../widgets/math_expression_editor.dart';
import '../widgets/math_keypad.dart';
import '../widgets/math_latex_view.dart';
import '../widgets/pencil_input_pad.dart';
import '../widgets/student_page_title.dart';
import '../widgets/student_status_island.dart';

enum _InputMode { pencil, editor, keyboard }

enum _PaneMode { answers, question }

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
  });

  final String groupId;
  final String title;

  /// 배정된 문항 crop id. 페이지에 다른 문항이 섞여 있어도 이것만 보여준다.
  final Set<String> cropIds;

  /// 배정 문항이 있는 페이지. 이 페이지들 사이에서만 이동한다.
  final Set<int> rawPages;

  bool get isEmpty => cropIds.isEmpty;
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
  });

  final StudentTextbook book;
  final HomeworkSolveScope? homework;

  @override
  State<TextbookSolveScreen> createState() => _TextbookSolveScreenState();
}

class _TextbookSolveScreenState extends State<TextbookSolveScreen> {
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

  /// crop_id → 신고 상태 (open: 검토 중, accepted: 신고 인정, rejected: 반려)
  final Map<String, String> _reportStatuses = <String, String>{};

  /// crop_id → 마지막 필기 인식 스냅샷. 입력 모드 전환이나 문항 이동으로
  /// 필기 패드가 언마운트된 뒤에도 신고(필기 인식 불량)에 첨부할 수 있다.
  final Map<String, Map<String, dynamic>> _handwritingSnapshots =
      <String, Map<String, dynamic>>{};

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
  int _problemViewRequestEpoch = 0;
  final Map<String, StudentTextbookProblemView> _problemViewCache =
      <String, StudentTextbookProblemView>{};
  final Map<String, Future<StudentTextbookProblemView>> _problemViewRequests =
      <String, Future<StudentTextbookProblemView>>{};
  final Set<String> _prefetchedCropIds = <String>{};
  final Set<String> _neighborQueueRequestedCropIds = <String>{};

  /// 페이지를 열 때마다 증가. 예열은 백그라운드로 길게 도니까, 페이지가 바뀌면
  /// 지난 페이지의 예열이 계속 돌지 않도록 이 값으로 끊는다.
  int _pageEpoch = 0;

  /// 이미 다음 페이지 예열을 요청한 페이지 (rawPage|subKey).
  final Set<String> _nextPageWarmedKeys = <String>{};
  bool _grading = false;
  bool _treeOpen = false;

  /// 상단 바(뒤로·교재명·페이지·단원) 스크롤 페이드. 아일랜드는 Host에 남음.
  double _titleOpacity = 1;
  final ScrollController _answersScrollController = ScrollController();
  final ScrollController _questionScrollController = ScrollController();

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
  final GlobalKey<_ScratchPracticeSheetState> _scratchKey =
      GlobalKey<_ScratchPracticeSheetState>();
  final TextEditingController _keyboardController = TextEditingController();

  @override
  void dispose() {
    _problemViewRequestEpoch++;
    _answersScrollController.removeListener(_onAnswersScroll);
    _questionScrollController.removeListener(_onQuestionScroll);
    _answersScrollController.dispose();
    _questionScrollController.dispose();
    _keyboardController.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _answersScrollController.addListener(_onAnswersScroll);
    _questionScrollController.addListener(_onQuestionScroll);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    _loadTree(selectLastPage: true);
  }

  /// 현재 페이지 문항을 렌더 큐에 넣는다.
  ///
  /// 교재 전체 예열은 콜드 교재에서 지금 볼 문항을 큐 뒤로 밀어내므로 쓰지
  /// 않고, 페이지 단위로만 예열한다.
  Future<void> _warmCurrentPageProblemViews(List<PageProblem> problems) async {
    final cropIds = <String>[
      for (final problem in problems) problem.cropId,
    ];
    if (cropIds.isEmpty) return;
    try {
      await TextbookApi.instance.warmPageProblemViews(
        cropIds: cropIds,
        selectedCropId: _selectedCropId,
      );
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

  void _selectFirstPage() {
    final pages = _flattenedPages();
    if (pages.isEmpty) return;
    final first = pages.first;
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
  /// 과제 스코프면 배정 문항이 있는 페이지만 남긴다.
  List<({TbPageStat page, String pathLabel})> _flattenedPages() {
    final tree = _tree;
    if (tree == null) return const [];
    final scope = widget.homework;
    final out = <({TbPageStat page, String pathLabel})>[];
    for (final big in tree.bigUnits) {
      for (final mid in big.mids) {
        for (final small in mid.smalls) {
          final pathLabel =
              '${mid.name} · ${small.name.isEmpty ? small.subKey : small.name}';
          for (final page in small.pages) {
            if (scope != null && !scope.rawPages.contains(page.rawPage)) {
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
    final scope = widget.homework;
    if (scope == null) return problems;
    return problems
        .where((p) => scope.cropIds.contains(p.cropId))
        .toList(growable: false);
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

  void _onAnswersScroll() {
    if (!mounted || _paneMode != _PaneMode.answers) return;
    _updateTitleFromScroll(_answersScrollController.offset);
  }

  void _onQuestionScroll() {
    if (!mounted || _paneMode != _PaneMode.question) return;
    _updateTitleFromScroll(_questionScrollController.offset);
  }

  void _updateTitleFromScroll(double pixels) {
    final next =
        (1 - pixels / StudentCollapsingTitlePage.fadeDistance).clamp(0.0, 1.0);
    if ((next - _titleOpacity).abs() > 0.01) {
      setState(() => _titleOpacity = next);
    }
  }

  void _resetTitleCollapse() {
    _titleOpacity = 1;
    if (_answersScrollController.hasClients) {
      _answersScrollController.jumpTo(0);
    }
    if (_questionScrollController.hasClients) {
      _questionScrollController.jumpTo(0);
    }
  }

  Future<void> _openPage(
    TbPageStat page,
    String pathLabel, {
    _PageEntrySelect select = _PageEntrySelect.auto,
  }) async {
    _expandTreeForPage(page);
    final epoch = ++_pageEpoch;
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
      _reportStatuses.clear();
      _expandedSetCrops.clear();
      _selectedCropId = null;
      _selectedPartKey = null;
      _problemViewRequestEpoch++;
      _problemView = null;
      _problemViewError = null;
      _loadingProblemView = false;
      _treeOpen = false;
    });
    try {
      final loaded = await TextbookApi.instance.pageProblems(
        bookId: widget.book.bookId,
        gradeLabel: widget.book.gradeLabel,
        rawPage: page.rawPage,
      );
      if (!mounted) return;
      final problems = _scopedProblems(loaded);
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
          if (p.reportStatus != null) {
            _reportStatuses[p.cropId] = p.reportStatus!;
          }
          // 세트형 파트별 기록 복원
          for (final pr in p.partResults) {
            final k = _answerKeyOf(p.cropId, pr.key);
            final partAnswer = pr.answer?.trim() ?? '';
            if (partAnswer.isNotEmpty) {
              _answers[k] = partAnswer;
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
        if (problems.isEmpty) return;
        switch (select) {
          case _PageEntrySelect.first:
            _selectPro(problems.first);
          case _PageEntrySelect.last:
            _selectPro(problems.last);
          case _PageEntrySelect.auto:
            // 첫 미완료 주관식(미풀이·오답) 자동 선택 (보류 문항 제외)
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
            if (_selectedCropId == null) {
              _selectPro(problems.first);
            }
        }
      });
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

  Future<void> _grade() async {
    if (_grading) return;
    final problems = _problems;
    if (problems == null) return;

    // 자동 채점 문항 중 새로 입력했거나 값이 바뀐 것만 제출
    final toSubmit = <String, String>{};
    final partSubmit = <String, Map<String, String>>{};
    final incomplete = <String>[];
    for (final p in problems) {
      if (_isOnHold(p.cropId)) continue; // 보류 문항은 채점 제외
      if (p.hasParts) {
        // 세트형: auto 파트별로 새 답만 제출
        for (final part in p.setParts) {
          if (part.isSelfCheck) continue;
          final k = _answerKeyOf(p.cropId, part.key);
          final answer = _answers[k]?.trim() ?? '';
          if (answer.isEmpty) continue;
          if (answer.contains('()')) {
            incomplete.add('${p.problemNumber}${part.key}');
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
      await _maybeCompleteHomework();
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
      TopGlassSnackBar.show(
        context,
        message: '과제를 모두 맞혔어요! 통과 처리했어요.',
        icon: Icons.verified_rounded,
      );
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
        title: '${problem.problemNumber}번 정답',
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
        homeworkGroupId: widget.homework?.groupId,
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
      await _maybeCompleteHomework();
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
        title: '${problem.problemNumber}번 답지 정답',
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
        title: '${problem.problemNumber}번 $partKey 정답',
        revealed: RevealedAnswer(
          answerKind: 'subjective',
          answerText: partText.isEmpty ? null : partText,
        ),
        myAnswer: _answers[answerKey],
      ),
    );
    if (marked == null || !mounted) return;

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
      await _maybeCompleteHomework();
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

  /// 답 상태 키 — 일반 문항은 crop_id, 세트형 파트는 'crop_id::(1)'.
  String _answerKeyOf(String cropId, String? partKey) =>
      partKey == null ? cropId : '$cropId::$partKey';

  /// 현재 입력 패널이 쓰는 답 상태 키.
  String? get _activeAnswerKey {
    final cropId = _selectedCropId;
    if (cropId == null) return null;
    return _answerKeyOf(cropId, _selectedPartKey);
  }

  void _setAnswer(String answerKey, String value) {
    if (_results[answerKey] == true) return;
    setState(() => _answers[answerKey] = value);
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

  /// 문항 선택 (입력 패널 대상 변경 — 에디터/키보드 상태 재생성).
  void _selectPro(PageProblem problem, {String? partKey}) {
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

  void _toggleObjective(String cropId, int number) {
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
    if (!selected.remove(number)) selected.add(number);
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
      if (problem != null) _selectPro(problem);
    });
  }

  int get _pendingGradeCount {
    final problems = _problems ?? const <PageProblem>[];
    var count = 0;
    for (final problem in problems) {
      if (_isOnHold(problem.cropId)) continue;
      if (problem.hasParts) {
        for (final part in problem.setParts) {
          if (part.isSelfCheck) continue;
          final k = _answerKeyOf(problem.cropId, part.key);
          final answer = _answers[k]?.trim() ?? '';
          if (answer.isEmpty || answer.contains('()')) continue;
          if (_gradedAnswers[k] == answer && _results.containsKey(k)) {
            continue;
          }
          count++;
        }
        continue;
      }
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

  Future<void> _moveProblem(int delta) async {
    if (_loadingProblems || delta == 0) return;
    final problems = _problems ?? const <PageProblem>[];
    if (problems.isEmpty) return;
    var index =
        problems.indexWhere((problem) => problem.cropId == _selectedCropId);

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
    final next = index + delta;
    if (next >= 0 && next < problems.length) {
      final target = problems[next];
      setState(() {
        if (target.hasParts) {
          // 다음 문제로 진입 → 첫 파트, 이전 문제로 진입 → 마지막 파트.
          final partKey = delta > 0
              ? target.setParts.first.key
              : target.setParts.last.key;
          _selectPro(target, partKey: partKey);
        } else {
          _selectPro(target);
        }
      });
      return;
    }
    // 페이지 경계 — 다음/이전 페이지의 첫·마지막 문항으로 이동.
    final pages = _flattenedPages();
    final current = _page;
    if (pages.isEmpty || current == null) return;
    final pageIndex =
        pages.indexWhere((entry) => entry.page.rawPage == current.rawPage);
    if (pageIndex < 0) return;
    final nextPageIndex = pageIndex + (delta > 0 ? 1 : -1);
    if (nextPageIndex < 0 || nextPageIndex >= pages.length) return;
    final entry = pages[nextPageIndex];
    await _openPage(
      entry.page,
      entry.pathLabel,
      select: delta > 0 ? _PageEntrySelect.first : _PageEntrySelect.last,
    );
  }

  void _togglePaneMode() {
    setState(() {
      _resetTitleCollapse();
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

  void _toggleScratchPad() {
    setState(() {
      if (_scratchOpen) {
        _scratchOpen = false;
        return;
      }
      final expanded = _scratchExpandedDefault(context);
      _scratchOpen = true;
      _scratchCollapsed = false;
      _scratchHeight =
          _scratchRestoredHeight > 0 ? _scratchRestoredHeight : expanded;
      _scratchRestoredHeight = _scratchHeight;
    });
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

  void _eraseCurrentInput() {
    final answerKey = _activeAnswerKey;
    if (answerKey == null || _results[answerKey] == true) return;
    switch (_inputMode) {
      case _InputMode.pencil:
        final hasStrokes = _pencilKey.currentState?.undoStroke() ?? false;
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

  void _clearCurrentInput() {
    // 연습장이 열려 있으면 FAB 모두지우기는 연습장 필기를 지운다.
    if (_scratchOpen) {
      _scratchKey.currentState?.clearStrokes();
      return;
    }
    final answerKey = _activeAnswerKey;
    if (answerKey == null || _results[answerKey] == true) return;
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
    _setAnswer(answerKey, '');
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
        problemNumber: problem.problemNumber,
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
      Map<String, dynamic>? payload;
      if (problem.cropId == _selectedCropId) {
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
    return Scaffold(
      backgroundColor: context.yggSurfaceBase,
      body: Stack(
        children: [
          Positioned.fill(
            child: _buildPagePanel(theme, topInset: titleExtent),
          ),
          // 딤 배리어 — 항상 두고 opacity 로 페이드 (시트 슬라이드와 동기).
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_treeOpen,
              child: AnimatedOpacity(
                opacity: _treeOpen ? 1 : 0,
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
            right: _treeOpen ? 0 : -(_kPageSheetWidth + _kPageSheetShadowBleed),
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
          if (!_treeOpen)
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
            child: IgnorePointer(
              ignoring: _titleOpacity < 0.05,
              child: Opacity(
                opacity: _titleOpacity,
                child: Transform.translate(
                  offset: Offset(0, -(1 - _titleOpacity) * 12),
                  child: _buildSolveTitleBar(theme),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSolveTitleBar(ThemeData theme) {
    final page = _page;
    final screenW = MediaQuery.sizeOf(context).width;
    // 좁은 화면에서 교재명·페이지 경로가 밀리지 않도록 폭 제한.
    final bookNameMaxW = (screenW * 0.28).clamp(96.0, 240.0);
    final pageMetaMaxW = (screenW * 0.30).clamp(72.0, 220.0);
    return Material(
      color: context.yggSurfaceBase,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          StudentStatusIslandToolbarSlot(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 공용 타이틀과 동일하게 왼쪽 여백 24.
                const SizedBox(width: 24),
                IconButton(
                  tooltip: '뒤로',
                  onPressed: () => Navigator.of(context).pop(),
                  style: IconButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(40, 40),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: bookNameMaxW),
                  child: Text(
                    widget.book.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontSize: StudentPageTitle.fontSize,
                      fontWeight: FontWeight.w700,
                      height: 1.15,
                    ),
                  ),
                ),
                const Spacer(),
                if (page != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: pageMetaMaxW),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'p.${page.shownPage}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
                  onPressed: () => _setTreeOpen(!_treeOpen),
                  icon: const Icon(Icons.segment_rounded),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
          const SizedBox(height: 8),
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
    if (problems.isEmpty) {
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
    for (final p in problems) {
      if (p.cropId == _selectedCropId) {
        selectedProblem = p;
        break;
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
        // 기존 Column flex 2:1 비율과 동일하게 입력 시트 높이를 고정.
        final inputH = (constraints.maxHeight - dividerH) / 3;
        final showAnswers = _paneMode == _PaneMode.answers;

        final body = showAnswers
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 2,
                    child: Stack(
                      children: [
                        ListView.builder(
                          controller: _answersScrollController,
                          // 하단 FAB(문항/정답 보기) 아래로 카드가 지나가도록 여백.
                          padding: EdgeInsets.fromLTRB(24, topInset + 12, 24, 72),
                          itemCount: problems.length,
                          itemBuilder: (context, i) => _problemRow(
                            theme,
                            problems[i],
                            showObjectiveButtons: false,
                          ),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 10,
                          child: Center(child: _buildPaneModeButton()),
                        ),
                      ],
                    ),
                  ),
                  divider,
                  Expanded(
                    flex: 1,
                    child: inputPanel,
                  ),
                ],
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  // 문항 시트는 입력 패널 아래까지 스크롤되도록 전체 높이를 쓴다.
                  Positioned.fill(
                    child: _buildQuestionPane(
                      theme,
                      selectedProblem,
                      topInset: topInset,
                      scrollUnderInset: inputH + dividerH,
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Material(
                      color: Colors.white,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          divider,
                          SizedBox(
                            height: inputH,
                            child: inputPanel,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: inputH + dividerH + 10,
                    child: Center(child: _buildPaneModeButton()),
                  ),
                ],
              );

        return Stack(
          children: [
            body,
            if (selectedProblem != null &&
                !selectedProblem.isObjective &&
                !_usesSelfCheckInput(selectedProblem) &&
                !_isOnHold(selectedProblem.cropId))
              Positioned(
                left: 16,
                bottom: bottomInset / 2 + 6,
                child: _buildInputModeButton(),
              ),
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
                child: _ScratchPracticeSheet(
                  key: _scratchKey,
                  onHandleTap: _onScratchHandleTap,
                  onHeightDrag: _onScratchHeightDrag,
                  onClose: () => setState(() => _scratchOpen = false),
                ),
              ),
            ),
            Positioned(
              right: 16,
              bottom: bottomInset / 2 + 6,
              child: _TextbookSolveFabBar(
                pendingCount: _pendingGradeCount,
                grading: _grading,
                canEdit: selectedProblem != null &&
                    !_usesSelfCheckInput(selectedProblem) &&
                    _results[_answerKeyOf(
                          selectedProblem.cropId,
                          selectedProblem.hasParts ? _selectedPartKey : null,
                        )] !=
                        true,
                hasAnswer: selectedProblem != null &&
                    (_answers[_answerKeyOf(
                          selectedProblem.cropId,
                          selectedProblem.hasParts ? _selectedPartKey : null,
                        )]
                            ?.isNotEmpty ??
                        false),
                scratchOpen: _scratchOpen,
                onPrevious: () => unawaited(_moveProblem(-1)),
                onNext: () => unawaited(_moveProblem(1)),
                onErase: _eraseCurrentInput,
                onClear: _clearCurrentInput,
                onNote: _toggleScratchPad,
                onGrade: _grade,
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

  Widget _buildQuestionPane(
    ThemeData theme,
    PageProblem? problem, {
    required double topInset,
    required double scrollUnderInset,
  }) {
    if (problem == null) {
      return Padding(
        padding: EdgeInsets.only(top: topInset),
        child: const Center(child: Text('표시할 문항이 없어요.')),
      );
    }
    // 시트 높이는 PDF 콘텐츠에 맞추고, 길면 입력 시트 아래로 같이 스크롤.
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        controller: _questionScrollController,
        // 하단 여백을 넉넉히 — 렌더된 문항 카드가 하단 FAB(정답 버튼)와
        // 겹치지 않게 한다.
        padding:
            EdgeInsets.fromLTRB(24, topInset + 12, 24, scrollUnderInset + 56),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _problemRow(
              theme,
              problem,
              showObjectiveButtons: false,
            ),
            const SizedBox(height: 12),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius:
                    BorderRadius.circular(YggGroupedLayoutTokens.cardRadius),
                border: Border.all(color: const Color(0x1F000000)),
              ),
              child: ClipRRect(
                borderRadius:
                    BorderRadius.circular(YggGroupedLayoutTokens.cardRadius),
                child: _buildProblemPdf(theme),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProblemPdf(ThemeData theme) {
    if (_loadingProblemView) {
      return const SizedBox(
        height: 160,
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

  /// 개념원리만 문항분류(필수유형 등)를 난이도/유형코드와 같은 회색 글씨로 표시.
  bool get _showCategoryLabel => widget.book.series == 'wonri';

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
                    Expanded(
                      child: held
                          ? Text(
                              '신고한 문항 · 선생님이 확인 중이에요',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: theme.hintColor,
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          : problem.isObjective && showObjectiveButtons
                              ? _objectiveButtons(theme, problem)
                              : !problem.isObjective && answer.isNotEmpty
                                  // 주관식 답은 2D 조판 수식으로 보여준다.
                                  ? Align(
                                      alignment: Alignment.centerLeft,
                                      child: MathLatexView.linear(
                                        answer,
                                        fontSize: theme.textTheme.titleMedium
                                                ?.fontSize ??
                                            16,
                                      ),
                                    )
                                  : Text(
                                      problem.isObjective
                                          ? (answer.isEmpty
                                              ? '객관식'
                                              : _objectiveAnswerText(answer))
                                          : (problem.isSelfCheck
                                              ? '공책에 풀고 정답을 확인해 보세요'
                                              : '답을 입력해 주세요'),
                                      style:
                                          theme.textTheme.titleMedium?.copyWith(
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
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        // 헤더 탭 = 항상 선택(입력 대상 변경). 접힘만 바꾸던
                        // 동작은 오른쪽 화살표로 분리한다.
                        onTap: () => setState(() => _selectPro(problem)),
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
                                      problem.problemNumber,
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
    const wrongColor = Color(0xFFE57373);
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
                    child: Text(
                      part.key,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  Expanded(
                    child: !part.isSelfCheck && answer.isNotEmpty
                        // 파트 답도 2D 조판 수식으로 보여준다.
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: MathLatexView.linear(
                              answer,
                              fontSize:
                                  theme.textTheme.titleSmall?.fontSize ?? 14,
                            ),
                          )
                        : Text(
                            part.isSelfCheck
                                ? (graded
                                    ? (result ? '맞았어요' : '틀렸어요 · 다시 확인해 보세요')
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
                  if (graded)
                    Icon(
                      result ? Icons.circle_outlined : Icons.close_rounded,
                      size: 22,
                      color: result ? accent : wrongColor,
                    )
                  else if (answer.isNotEmpty)
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

  Widget _objectiveButtons(ThemeData theme, PageProblem problem) {
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
      offset: const Offset(0, -12),
      child: Wrap(
        spacing: 8,
        children: [
          for (var n = 1; n <= 5; n++)
            InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => _toggleObjective(problem.cropId, n),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
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
                        '${problem.problemNumber}번 답  ·  '
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
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () => _reportProblem(problem),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 8,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.flag_outlined,
                        size: 18,
                        color: Colors.black,
                      ),
                      SizedBox(width: 6),
                      Text(
                        '신고',
                        style: TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
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
                      onRecognized: (text) => _setAnswer(answerKey, text),
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
                              '${problem.problemNumber}번'
                              '${partKey == null ? '' : ' $partKey'} 답  ·  ',
                              style: const TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            // 인식·입력된 답은 2D 조판 수식으로 보여준다.
                            Flexible(
                              child: answer.isEmpty
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
                                      child: MathLatexView.linear(
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
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: () => _reportProblem(problem),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 8,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.flag_outlined,
                          size: 18,
                          color: Colors.black,
                        ),
                        SizedBox(width: 6),
                        Text(
                          '신고',
                          style: TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
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
    // 워커 산출물(단일 문항 PDF)은 스크롤/줌 뷰어 대신 문항카드 썸네일처럼
    // 정적으로 그린다. 모든 산출물이 같은 폭(1단 폭)으로 렌더되므로
    // 가로폭 맞춤이면 문항 간 배율도 동일해진다.
    return _RenderedProblemPdfPage(uri: uri);
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

/// 워커가 렌더한 단일 문항 PDF 표시.
///
/// 가로는 뷰포트의 75%, 세로는 종횡비에 맞춘 고정 높이.
/// 세로 스크롤은 상위 시트(`SingleChildScrollView`)가 담당한다.
class _RenderedProblemPdfPage extends StatefulWidget {
  const _RenderedProblemPdfPage({required this.uri});

  final Uri uri;

  @override
  State<_RenderedProblemPdfPage> createState() =>
      _RenderedProblemPdfPageState();
}

class _RenderedProblemPdfPageState extends State<_RenderedProblemPdfPage> {
  PdfDocument? _document;
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
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Text('문항 PDF를 표시할 수 없어요.', textAlign: TextAlign.center),
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
    const inset = 10.0;
    return Padding(
      padding: const EdgeInsets.all(inset),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 가로를 뷰포트의 75%로 고정. 세로는 콘텐츠 높이 → 시트가 이에 맞춰진다.
          final width = constraints.maxWidth * 0.75;
          final height = width * (page.height / page.width);
          return SizedBox(
            width: constraints.maxWidth,
            height: height,
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: width,
                height: height,
                child: PdfPageView(
                  document: document,
                  pageNumber: 1,
                  decoration: const BoxDecoration(color: Colors.white),
                ),
              ),
            ),
          );
        },
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
        maxScale: 5,
        constrained: false,
        alignment: Alignment.topCenter,
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
        maxScale: 5,
        constrained: false,
        alignment: Alignment.topCenter,
        child: PdfPageView(
          document: document,
          pageNumber: pageNumber,
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
                        decoration: const BoxDecoration(color: Colors.white),
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

/// 두 손가락 가로 스와이프로 이전/다음 문항 이동.
///
/// 한 손가락 필기와 겹치지 않도록, 포인터가 2개일 때만 가로 이동을 인식한다.
/// (왼쪽 스와이프 = 다음, 오른쪽 스와이프 = 이전)
class _TwoFingerHorizontalSwipe extends StatefulWidget {
  const _TwoFingerHorizontalSwipe({
    required this.onSwipe,
    required this.child,
  });

  final ValueChanged<int> onSwipe;
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
  static const _threshold = 72.0;

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
        // 세로 스크롤성 제스처는 무시하고 가로가 뚜렷할 때만 이동.
        if (dx.abs() < _threshold || dx.abs() < dy.abs() * 1.2) return;
        _fired = true;
        widget.onSwipe(dx < 0 ? 1 : -1);
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
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [
          BoxShadow(
            color: Color(0x24000000),
            blurRadius: 18,
            offset: Offset(0, 7),
          ),
        ],
      ),
      child: ClipRRect(
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
    required this.scratchOpen,
    required this.onPrevious,
    required this.onNext,
    required this.onErase,
    required this.onClear,
    required this.onNote,
    required this.onGrade,
  });

  final int pendingCount;
  final bool grading;
  final bool canEdit;
  final bool hasAnswer;
  final bool scratchOpen;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onErase;
  final VoidCallback onClear;
  final VoidCallback onNote;
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
                icon: Icons.keyboard_backspace_rounded,
                onPressed: canEdit ? onErase : null,
              ),
              _SolveFabIconButton(
                tooltip: '모두 지우기',
                icon: Icons.delete_outline_rounded,
                onPressed: scratchOpen
                    ? onClear
                    : (canEdit && hasAnswer ? onClear : null),
              ),
              _SolveFabIconButton(
                tooltip: scratchOpen ? '연습장 닫기' : '연습장',
                icon: scratchOpen
                    ? Icons.edit_note_rounded
                    : Icons.note_alt_outlined,
                onPressed: onNote,
                active: scratchOpen,
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
                          Icons.check_box_outlined,
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
    this.active = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? YggGlassTokens.confirmActionColor : null;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 22, color: color),
      constraints: const BoxConstraints.tightFor(width: 43, height: 43),
      padding: EdgeInsets.zero,
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
                    if (_activePointer != null) return;
                    _activePointer = event.pointer;
                    _strokeStartGlobal = event.position;
                    _strokeIsDraw = false;
                    _startStroke(event.localPosition);
                  },
                  onPointerMove: (event) {
                    if (_activePointer != event.pointer) return;
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
                    if (_activePointer != event.pointer) return;
                    // 짧게 터치만 하면 접기/펼치기 (점 남기지 않음).
                    if (!_strokeIsDraw) {
                      _discardLastStroke();
                      widget.onHandleTap();
                    }
                    _activePointer = null;
                    _strokeStartGlobal = null;
                    _strokeIsDraw = false;
                  },
                  onPointerCancel: (event) {
                    if (_activePointer != event.pointer) return;
                    if (!_strokeIsDraw) _discardLastStroke();
                    _activePointer = null;
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
    final answerText = (revealed.answerText?.trim().isNotEmpty ?? false)
        ? revealed.answerText!.trim()
        : revealed.answerLatex2d?.trim() ?? '';
    final latex2d = revealed.answerLatex2d?.trim() ?? '';

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
                    // 답지 이미지와 동일하게 항상 밝은 배경 + 검은 글씨 —
                    // 종이 답지를 보는 느낌을 유지한다.
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x1F000000)),
                  ),
                  // 정답을 2D 조판 수식으로 보여준다. LaTeX 표기가 있으면
                  // 그대로, 없으면 선형 표기를 변환해 그린다.
                  child: latex2d.isNotEmpty
                      ? MathLatexView(
                          latex: latex2d,
                          fontSize: 24,
                          color: Colors.black87,
                        )
                      : answerText.isEmpty
                          ? Text(
                              '(등록된 정답 표기가 없어요)',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: Colors.black87,
                                fontWeight: FontWeight.w600,
                                height: 1.5,
                              ),
                            )
                          : MathLatexView.linear(
                              answerText,
                              fontSize: 24,
                              color: Colors.black87,
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
