import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/textbook_api.dart';
import 'textbook_solve_screen.dart';

/// "교재 풀기" 탭 — 정답 DB가 준비된 교재 목록 + 풀이 현황.
class TextbookScreen extends StatefulWidget {
  const TextbookScreen({super.key});

  @override
  State<TextbookScreen> createState() => _TextbookScreenState();
}

class _TextbookScreenState extends State<TextbookScreen> {
  List<StudentTextbook>? _books;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final books = await TextbookApi.instance.listTextbooks();
      if (!mounted) return;
      setState(() {
        _books = books;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '교재 목록을 불러오지 못했어요.\n$e');
    }
  }

  Future<void> _openBook(StudentTextbook book) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TextbookSolveScreen(book: book),
      ),
    );
    // 풀고 돌아오면 현황 갱신
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final books = _books;

    Widget body;
    if (_error != null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _refresh, child: const Text('다시 시도')),
          ],
        ),
      );
    } else if (books == null) {
      body = const Center(child: YggLoadingIndicator());
    } else if (books.isEmpty) {
      body = Center(
        child: Text(
          '풀 수 있는 교재가 아직 없어요.\n선생님이 교재를 연결하면 여기에 나타나요.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge,
        ),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _refresh,
        child: GridView.builder(
          padding: const EdgeInsets.all(24),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 420,
            mainAxisExtent: 180,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
          ),
          itemCount: books.length,
          itemBuilder: (context, i) => _BookCard(
            book: books[i],
            onTap: () => _openBook(books[i]),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 0),
          child: Text(
            '교재 풀기',
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        Expanded(child: body),
      ],
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({required this.book, required this.onTap});

  final StudentTextbook book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final progress =
        book.totalProblems == 0 ? 0.0 : book.gradedCount / book.totalProblems;
    final accuracy = book.gradedCount == 0
        ? null
        : (book.correctCount / book.gradedCount * 100).round();

    return Material(
      color: isDark ? const Color(0xFF1F2A2A) : Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.menu_book_rounded,
                      size: 22, color: YggGlassTokens.confirmActionColor),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      book.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                book.gradeLabel,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor),
              ),
              const Spacer(),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 8,
                  backgroundColor: theme.dividerColor.withValues(alpha: 0.25),
                  color: YggGlassTokens.confirmActionColor,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    '${book.gradedCount} / ${book.totalProblems} 문항',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (accuracy != null) ...[
                    const SizedBox(width: 12),
                    Text(
                      '정답률 $accuracy%',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: YggGlassTokens.confirmActionColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (book.lastDisplayPage != null ||
                      book.lastRawPage != null)
                    Text(
                      '최근 p.${book.lastDisplayPage ?? book.lastRawPage}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor),
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
