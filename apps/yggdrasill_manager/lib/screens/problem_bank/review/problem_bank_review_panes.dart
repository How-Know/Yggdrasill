import 'package:flutter/material.dart';

import '../problem_bank_models.dart';
import 'problem_bank_review_mode.dart';

typedef ProblemBankQuestionBuilder = Widget Function(
  BuildContext context,
  ProblemBankQuestion question,
);

class ExamPaperReviewPane extends StatelessWidget {
  const ExamPaperReviewPane({
    required this.questions,
    required this.questionBuilder,
    super.key,
  });

  final List<ProblemBankQuestion> questions;
  final ProblemBankQuestionBuilder questionBuilder;

  @override
  Widget build(BuildContext context) {
    const maxCardWidth = 420.0;
    const gap = 10.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (!width.isFinite || width <= 0) return const SizedBox.shrink();
        var columns = 1;
        while (columns < 50) {
          final cardWidth = (width - gap * (columns - 1)) / columns;
          if (cardWidth <= maxCardWidth) break;
          columns++;
        }
        final cardWidth = (width - gap * (columns - 1)) / columns;
        return SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final question in questions)
                  SizedBox(
                    key: ValueKey('exam-question-${question.id}'),
                    width: cardWidth,
                    child: questionBuilder(context, question),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class TextbookPageReviewPane extends StatefulWidget {
  const TextbookPageReviewPane({
    required this.questions,
    required this.questionBuilder,
    required this.panelColor,
    required this.fieldColor,
    required this.borderColor,
    required this.textColor,
    required this.textSubColor,
    required this.accentColor,
    this.availablePages = const <int>[],
    this.totalPageCount,
    this.initialPage,
    this.onPageRequested,
    super.key,
  });

  final List<ProblemBankQuestion> questions;
  final ProblemBankQuestionBuilder questionBuilder;
  final Color panelColor;
  final Color fieldColor;
  final Color borderColor;
  final Color textColor;
  final Color textSubColor;
  final Color accentColor;
  final List<int> availablePages;
  final int? totalPageCount;
  final int? initialPage;
  final ValueChanged<int>? onPageRequested;

  @override
  State<TextbookPageReviewPane> createState() => _TextbookPageReviewPaneState();
}

class _TextbookPageReviewPaneState extends State<TextbookPageReviewPane> {
  int? _selectedPage;
  late final TextEditingController _pageController;
  String _pageInputError = '';

  List<int> get _pages {
    final total = widget.totalPageCount ?? 0;
    if (total > 0) {
      return List<int>.generate(total, (index) => index + 1);
    }
    final pages = <int>{
      ...widget.availablePages.where((page) => page > 0),
      ...textbookPagesOf(widget.questions),
    }.toList()
      ..sort();
    return pages;
  }

  List<int> get _pageChipCandidates {
    final pages = _pages;
    final selected = _effectivePage;
    if (pages.length <= 12 || selected == null) return pages;
    final candidates = <int>{
      pages.first,
      for (var page = selected - 3; page <= selected + 3; page++)
        if (page >= pages.first && page <= pages.last) page,
      pages.last,
    }.toList()
      ..sort();
    return candidates;
  }

  int? get _effectivePage {
    final pages = _pages;
    if (pages.isEmpty) return null;
    if (_selectedPage != null && pages.contains(_selectedPage)) {
      return _selectedPage;
    }
    return pages.first;
  }

  @override
  void initState() {
    super.initState();
    _selectedPage = widget.initialPage;
    _pageController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncPageController();
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TextbookPageReviewPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pages = _pages;
    if (widget.initialPage != oldWidget.initialPage &&
        widget.initialPage != null &&
        pages.contains(widget.initialPage)) {
      _selectedPage = widget.initialPage;
    }
    if (_selectedPage != null && !pages.contains(_selectedPage)) {
      _selectedPage = pages.isEmpty ? null : pages.first;
    }
    _syncPageController();
  }

  void _syncPageController() {
    final text = _effectivePage?.toString() ?? '';
    if (_pageController.text == text) return;
    _pageController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _selectPage(int page) {
    if (!_pages.contains(page)) return;
    setState(() {
      _selectedPage = page;
      _pageInputError = '';
      _syncPageController();
    });
    widget.onPageRequested?.call(page);
  }

  void _movePage(int delta) {
    final page = _effectivePage;
    if (page == null) return;
    final index = _pages.indexOf(page);
    final nextIndex = index + delta;
    if (nextIndex < 0 || nextIndex >= _pages.length) return;
    _selectPage(_pages[nextIndex]);
  }

  void _submitPage(String value) {
    final requested = int.tryParse(value.trim());
    if (requested != null && _pages.contains(requested)) {
      _selectPage(requested);
      return;
    }
    setState(() {
      _pageInputError = widget.totalPageCount == null
          ? '해당 페이지에 추출 문항이 없습니다.'
          : '1쪽부터 ${widget.totalPageCount}쪽 사이로 입력해주세요.';
      _syncPageController();
    });
  }

  @override
  Widget build(BuildContext context) {
    final page = _effectivePage;
    if (page == null) {
      return Center(
        child: Text(
          '표시할 문항이 없습니다.',
          style: TextStyle(color: widget.textSubColor),
        ),
      );
    }
    final pageQuestions = textbookQuestionsOnPage(widget.questions, page);
    final pageIndex = _pages.indexOf(page);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: widget.fieldColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: widget.borderColor),
          ),
          child: Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const ValueKey('textbook-page-previous'),
                    tooltip: '이전 PDF 페이지',
                    onPressed: pageIndex > 0 ? () => _movePage(-1) : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  SizedBox(
                    width: 76,
                    child: TextField(
                      key: const ValueKey('textbook-page-input'),
                      controller: _pageController,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.go,
                      onSubmitted: _submitPage,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: widget.textColor,
                        fontWeight: FontWeight.w800,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 9,
                        ),
                        filled: true,
                        fillColor: widget.panelColor,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        suffixText: '쪽',
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('textbook-page-next'),
                    tooltip: '다음 PDF 페이지',
                    onPressed: pageIndex < _pages.length - 1
                        ? () => _movePage(1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${pageIndex + 1} / ${_pages.length} 페이지',
                    style: TextStyle(
                      color: widget.textSubColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              Text(
                '$page쪽 · ${pageQuestions.length}문항 · '
                '검수 ${pageQuestions.where((q) => q.isChecked).length} · '
                '미검수 ${pageQuestions.where((q) => !q.isChecked).length}',
                style: TextStyle(
                  color: widget.textSubColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                '페이지 검수 · 학습앱 노출 확정은 문서 단위',
                style: TextStyle(
                  color: widget.textSubColor,
                  fontSize: 10.5,
                ),
              ),
            ],
          ),
        ),
        if (_pageInputError.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(
            _pageInputError,
            style: const TextStyle(color: Color(0xFFDE6A73), fontSize: 11),
          ),
        ],
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final candidate in _pageChipCandidates) ...[
                _PageChip(
                  page: candidate,
                  questions:
                      textbookQuestionsOnPage(widget.questions, candidate),
                  selected: candidate == page,
                  panelColor: widget.panelColor,
                  fieldColor: widget.fieldColor,
                  borderColor: widget.borderColor,
                  textColor: widget.textColor,
                  textSubColor: widget.textSubColor,
                  accentColor: widget.accentColor,
                  onTap: () => _selectPage(candidate),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ExamPaperReviewPane(
            key: PageStorageKey<String>('textbook-page-$page'),
            questions: pageQuestions,
            questionBuilder: widget.questionBuilder,
          ),
        ),
      ],
    );
  }
}

class _PageChip extends StatelessWidget {
  const _PageChip({
    required this.page,
    required this.questions,
    required this.selected,
    required this.panelColor,
    required this.fieldColor,
    required this.borderColor,
    required this.textColor,
    required this.textSubColor,
    required this.accentColor,
    required this.onTap,
  });

  final int page;
  final List<ProblemBankQuestion> questions;
  final bool selected;
  final Color panelColor;
  final Color fieldColor;
  final Color borderColor;
  final Color textColor;
  final Color textSubColor;
  final Color accentColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final reviewed = questions.where((question) => question.isChecked).length;
    return Material(
      color: selected ? accentColor.withValues(alpha: 0.16) : fieldColor,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: selected ? accentColor : borderColor),
          ),
          child: Text(
            '$page쪽  $reviewed/${questions.length}',
            style: TextStyle(
              color: selected ? textColor : textSubColor,
              fontSize: 12,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
