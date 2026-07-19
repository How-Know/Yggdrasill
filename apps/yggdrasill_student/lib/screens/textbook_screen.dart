import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/textbook_api.dart';
import 'textbook_solve_screen.dart';

const double _coverA4Ratio = 1.414;
const double _cardMaxWidth = 240;
const double _cardGap = 20;
const double _coverToMetaSpacing = 14;
const double _cardMetaHeight = 77;
const double _cardRadius = 28;

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
      body = LayoutBuilder(
        builder: (context, constraints) {
          const horizontalPadding = 24.0;
          final availableWidth =
              math.max(1.0, constraints.maxWidth - horizontalPadding * 2);
          final crossAxisCount = math.max(
            1,
            ((availableWidth + _cardGap) / (_cardMaxWidth + _cardGap)).ceil(),
          );
          final cardWidth = (availableWidth - _cardGap * (crossAxisCount - 1)) /
              crossAxisCount;
          final cardHeight =
              cardWidth * _coverA4Ratio + _coverToMetaSpacing + _cardMetaHeight;
          return RefreshIndicator(
            onRefresh: _refresh,
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                mainAxisExtent: cardHeight,
                crossAxisSpacing: _cardGap,
                mainAxisSpacing: _cardGap,
              ),
              itemCount: books.length,
              itemBuilder: (context, i) => _BookCard(
                book: books[i],
                onTap: () => _openBook(books[i]),
              ),
            ),
          );
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
          child: Text(
            '교재 풀기',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              height: 1.15,
            ),
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
    final progress = book.totalProblems == 0
        ? 0.0
        : book.completedCount / book.totalProblems;
    final accuracy = book.gradedCount == 0
        ? null
        : (book.correctCount / book.gradedCount * 100).round();
    final coverUri = Uri.tryParse(book.coverRef);
    final hasNetworkCover = coverUri != null &&
        (coverUri.scheme == 'http' || coverUri.scheme == 'https');
    final coverColor = book.colorValue == null
        ? const Color(0xFF2B2B2B)
        : Color(book.colorValue!);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(_cardRadius),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1 / _coverA4Ratio,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(_cardRadius),
                  boxShadow: const [
                    BoxShadow(color: Color(0x1A000000), blurRadius: 14),
                    BoxShadow(
                      color: Color(0x29000000),
                      blurRadius: 18,
                      spreadRadius: -2,
                      offset: Offset(3, 7),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(_cardRadius),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      hasNetworkCover
                          ? Image.network(
                              book.coverRef,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  _CoverFallback(color: coverColor),
                            )
                          : _CoverFallback(color: coverColor),
                      Positioned(
                        top: 12,
                        left: 12,
                        right: 12,
                        child: _CompletionEstimateBadge(
                          book: book,
                          progress: progress,
                        ),
                      ),
                      if (book.startedAt != null)
                        Center(
                          child: _DaysSinceStartBadge(
                            startedAt: book.startedAt!,
                          ),
                        ),
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 12,
                        child: _CoverProgressOverlay(
                          book: book,
                          progress: progress,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: _coverToMetaSpacing),
            SizedBox(
              height: _cardMetaHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            book.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                        if (book.gradeLabel.trim().isNotEmpty) ...[
                          const SizedBox(width: 8),
                          _GradePill(label: book.gradeLabel),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          accuracy == null ? '정답률 -' : '정답률 $accuracy%',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 14.5,
                            color: theme.hintColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _dateLabel(book.startedAt),
                          textAlign: TextAlign.right,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 14.5,
                            color: theme.hintColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CoverFallback extends StatelessWidget {
  const _CoverFallback({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: color,
      child: const Center(
        child: Icon(
          Icons.menu_book_rounded,
          size: 36,
          color: Colors.white60,
        ),
      ),
    );
  }
}

class _GradePill extends StatelessWidget {
  const _GradePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.black.withValues(alpha: 0.08),
          width: 0.5,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface,
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String _dateLabel(DateTime? value) {
  if (value == null) return '-';
  final year = (value.year % 100).toString().padLeft(2, '0');
  return '$year.${value.month.toString().padLeft(2, '0')}.${value.day.toString().padLeft(2, '0')}';
}

class _DaysSinceStartBadge extends StatelessWidget {
  const _DaysSinceStartBadge({required this.startedAt});

  final DateTime startedAt;

  @override
  Widget build(BuildContext context) {
    final startDate = DateTime(startedAt.year, startedAt.month, startedAt.day);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = math.max(1, today.difference(startDate).inDays + 1);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Text(
          '시작한 지 $days일째',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _CompletionEstimateBadge extends StatelessWidget {
  const _CompletionEstimateBadge({
    required this.book,
    required this.progress,
  });

  final StudentTextbook book;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final label = _estimateLabel();
    return Align(
      alignment: Alignment.centerLeft,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }

  String _estimateLabel() {
    if (progress >= 1) return '완주 완료';
    final startedAt = book.startedAt;
    if (startedAt == null || book.correctCount < 5 || progress <= 0) {
      return '예상 약 6개월';
    }

    final elapsedDays =
        math.max(1, DateTime.now().difference(startedAt).inDays + 1);
    final observedTotalDays = elapsedDays / progress;
    final evidenceWeight = (book.correctCount / 30).clamp(0.0, 1.0);
    final estimatedDays =
        (180 * (1 - evidenceWeight) + observedTotalDays * evidenceWeight)
            .clamp(14.0, 730.0);
    final months = estimatedDays / 30.4375;
    final differenceWeeks = ((180 - estimatedDays) / 7).round();
    final comparison = differenceWeeks == 0
        ? '6개월 기준과 비슷'
        : differenceWeeks > 0
            ? '기준보다 $differenceWeeks주 빠름'
            : '기준보다 ${differenceWeeks.abs()}주 느림';
    return '예상 ${months.toStringAsFixed(1)}개월 · $comparison';
  }
}

class _CoverProgressOverlay extends StatelessWidget {
  const _CoverProgressOverlay({
    required this.book,
    required this.progress,
  });

  final StudentTextbook book;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(11, 9, 11, 5),
        child: Column(
          children: [
            _OverlayProgressRow(label: '전체', value: progress),
            if (book.series == 'ssen')
              for (final stage in const ['A', 'B', 'C'])
                _OverlayProgressRow(
                  label: stage,
                  value: book.stageProgress[stage]?.progress ?? 0,
                ),
          ],
        ),
      ),
    );
  }
}

class _OverlayProgressRow extends StatelessWidget {
  const _OverlayProgressRow({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: value.clamp(0, 1),
                minHeight: 5,
                backgroundColor: Colors.white24,
                color: YggGlassTokens.confirmActionColor,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 34,
            child: Text(
              '${(value * 100).round()}%',
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
