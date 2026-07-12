import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/textbook_api.dart';
import '../widgets/math_expression_editor.dart';
import '../widgets/math_keypad.dart';
import '../widgets/pencil_input_pad.dart';

enum _InputMode { pencil, editor, keyboard }

/// 교재 풀이 화면.
/// 좌: 단원트리(대→중→소→페이지), 우: 페이지 문항 + 정답 입력 + 일괄 채점.
class TextbookSolveScreen extends StatefulWidget {
  const TextbookSolveScreen({super.key, required this.book});

  final StudentTextbook book;

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

  /// crop_id → 채점 플래그 (unit_hint/unit_caution/form_differs)
  final Map<String, List<String>> _flags = <String, List<String>>{};

  /// 셀프 채점으로 기록된 문항
  final Set<String> _selfGraded = <String>{};

  String? _selectedCropId;
  _InputMode _inputMode = _InputMode.pencil;
  bool _grading = false;

  GlobalKey<MathExpressionEditorState> _editorKey =
      GlobalKey<MathExpressionEditorState>();
  final TextEditingController _keyboardController = TextEditingController();

  @override
  void dispose() {
    _keyboardController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadTree(selectLastPage: true);
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
              _openPage(page, '${big.name} · ${mid.name}');
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
      _flags.clear();
      _selfGraded.clear();
      _selectedCropId = null;
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
      if (_gradedAnswers[p.cropId] == answer && _results.containsKey(p.cropId)) {
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
      revealed = await TextbookApi.instance.revealAnswer(cropId: problem.cropId);
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
    setState(() => _answers[cropId] = value);
  }

  /// 문항 선택 (입력 패널 대상 변경 — 에디터/키보드 상태 재생성).
  void _selectPro(PageProblem problem) {
    _selectedCropId = problem.cropId;
    _editorKey = GlobalKey<MathExpressionEditorState>();
    _keyboardController.text = _answers[problem.cropId] ?? '';
  }

  void _toggleObjective(String cropId, int number) {
    final current = _answers[cropId] ?? '';
    final selected = current
        .split(',')
        .where((s) => s.trim().isNotEmpty)
        .map(int.parse)
        .toSet();
    if (!selected.remove(number)) selected.add(number);
    final sorted = selected.toList()..sort();
    _setAnswer(cropId, sorted.join(','));
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: context.yggSurfaceBase,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.book.name,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            Text(widget.book.gradeLabel,
                style:
                    theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ],
        ),
        backgroundColor: context.yggSurfaceBase,
        elevation: 0,
      ),
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 300, child: _buildTreePanel(theme)),
            const VerticalDivider(width: 1, thickness: 0.5),
            Expanded(child: _buildPagePanel(theme)),
          ],
        ),
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
            rows.add(_pageRow(theme, page, '${big.name} · ${mid.name}'));
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
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? accent : null,
                    ),
                  ),
                ),
                Text(
                  '${page.graded}/${page.total}',
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'p.${page.shownPage}',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      _pagePathLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: _grading ? null : _grade,
                style: FilledButton.styleFrom(
                  backgroundColor: YggGlassTokens.confirmActionColor,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 22, vertical: 14),
                ),
                icon: _grading
                    ? const YggLoadingIndicator(size: 18)
                    : const Icon(Icons.fact_check_outlined, size: 20),
                label: const Text('채점하기',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
            itemCount: problems.length,
            itemBuilder: (context, i) =>
                _problemRow(theme, problems[i]),
          ),
        ),
        if (selectedProblem != null && !selectedProblem.isObjective)
          _buildInputPanel(theme, selectedProblem),
      ],
    );
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
          onTap: problem.isObjective
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
                        onPressed: () => _selfCheck(problem),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: graded ? theme.hintColor : accent,
                          side: BorderSide(
                            color: (graded ? theme.hintColor : accent)
                                .withValues(alpha: 0.5),
                          ),
                        ),
                        icon: const Icon(Icons.visibility_outlined, size: 18),
                        label: Text(graded ? '다시 확인' : '정답 확인'),
                      ),
                      const SizedBox(width: 10),
                    ],
                    if (graded)
                      Icon(
                        result ? Icons.circle_outlined : Icons.close_rounded,
                        size: 26,
                        color: result ? accent : wrongColor,
                      )
                    else if (answer.isNotEmpty)
                      Icon(Icons.edit_rounded, size: 18, color: theme.hintColor),
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
    final isDark = theme.brightness == Brightness.dark;
    final answer = _answers[problem.cropId] ?? '';

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF17201F) : const Color(0xFFF4F6F5),
        border: Border(
          top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                '${problem.problemNumber}번 답',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (_inputMode != _InputMode.editor) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    answer.isEmpty ? '(입력 전)' : answer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: answer.isEmpty
                          ? theme.hintColor
                          : YggGlassTokens.confirmActionColor,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ] else
                const Spacer(),
              SegmentedButton<_InputMode>(
                segments: const [
                  ButtonSegment(
                    value: _InputMode.pencil,
                    icon: Icon(Icons.draw_outlined, size: 18),
                    label: Text('펜슬'),
                  ),
                  ButtonSegment(
                    value: _InputMode.editor,
                    icon: Icon(Icons.functions_rounded, size: 18),
                    label: Text('수식'),
                  ),
                  ButtonSegment(
                    value: _InputMode.keyboard,
                    icon: Icon(Icons.keyboard_outlined, size: 18),
                    label: Text('키보드'),
                  ),
                ],
                selected: {_inputMode},
                showSelectedIcon: false,
                onSelectionChanged: (modes) {
                  setState(() {
                    _inputMode = modes.first;
                    _keyboardController.text = _answers[problem.cropId] ?? '';
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          switch (_inputMode) {
            _InputMode.pencil => PencilInputPad(
                key: ValueKey('pad-${problem.cropId}'),
                onRecognized: (text) => _setAnswer(problem.cropId, text),
              ),
            _InputMode.editor => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MathExpressionEditor(
                    key: _editorKey,
                    initialLinear: answer,
                    onChanged: (linear) => _setAnswer(problem.cropId, linear),
                  ),
                  const SizedBox(height: 8),
                  MathKeypad(
                    onInsert: (t) => _editorKey.currentState?.insertText(t),
                    onFraction: () => _editorKey.currentState?.insertFraction(),
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
            _InputMode.keyboard => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: TextField(
                  controller: _keyboardController,
                  autofocus: true,
                  onChanged: (text) => _setAnswer(problem.cropId, text),
                  style: theme.textTheme.titleMedium,
                  decoration: InputDecoration(
                    hintText: '한글 답(예: 제2사분면, 유한소수)을 입력해 주세요',
                    filled: true,
                    fillColor: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
          },
        ],
      ),
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
    final answerText =
        (revealed.answerText?.trim().isNotEmpty ?? false)
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
                    loadingBuilder: (context, child, progress) =>
                        progress == null
                            ? child
                            : const SizedBox(
                                height: 80,
                                child: Center(
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
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
                  style:
                      theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
                ),
              ],
              const SizedBox(height: 20),
              Text(
                '내 풀이와 비교해서 스스로 채점해 주세요.',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
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
