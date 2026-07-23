import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/textbook_api.dart';
import '../widgets/student_page_title.dart';
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

  Future<void> _openAddTextbook() async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const _AddTextbookSheet(),
    );
    if (added == true && mounted) {
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final books = _books;

    return StudentCollapsingTitlePage(
      title: '교재 풀기',
      onRefresh: _refresh,
      bodyBuilder: (context, topInset, bottomInset) {
        if (_error != null) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(24, topInset + 40, 24, bottomInset),
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Center(
                child: OutlinedButton(
                  onPressed: _refresh,
                  child: const Text('다시 시도'),
                ),
              ),
            ],
          );
        }
        if (books == null) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(top: topInset + 80, bottom: bottomInset),
            children: const [Center(child: YggLoadingIndicator())],
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            const horizontalPadding = 24.0;
            final availableWidth =
                math.max(1.0, constraints.maxWidth - horizontalPadding * 2);
            final crossAxisCount = math.max(
              1,
              ((availableWidth + _cardGap) / (_cardMaxWidth + _cardGap)).ceil(),
            );
            final cardWidth =
                (availableWidth - _cardGap * (crossAxisCount - 1)) /
                    crossAxisCount;
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                topInset + 8,
                horizontalPadding,
                bottomInset,
              ),
              child: Wrap(
                spacing: _cardGap,
                runSpacing: _cardGap,
                children: [
                  for (final book in books)
                    SizedBox(
                      width: cardWidth,
                      child: _BookCard(
                        book: book,
                        onOpen: () => _openBook(book),
                      ),
                    ),
                  SizedBox(
                    width: cardWidth,
                    child: _AddTextbookCard(onTap: _openAddTextbook),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _BookCard extends StatefulWidget {
  const _BookCard({required this.book, required this.onOpen});

  final StudentTextbook book;
  final VoidCallback onOpen;

  @override
  State<_BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<_BookCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final book = widget.book;
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 커버 탭 → 교재 열기
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onOpen,
            borderRadius: BorderRadius.circular(_cardRadius),
            child: AspectRatio(
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
                        child: _CoverStartDateLabel(startedAt: book.startedAt),
                      ),
                      if (book.startedAt != null)
                        Center(
                          child: Transform.translate(
                            offset: const Offset(0, -20),
                            child: _DaysSinceStartBadge(
                              startedAt: book.startedAt!,
                            ),
                          ),
                        ),
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 12,
                        child: _CoverProgressOverlay(progress: progress),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: _coverToMetaSpacing),
        // 메타 탭 → 상세 시트 펼침/접기 (커버와 분리)
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
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
                        AnimatedRotation(
                          turns: _expanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 26,
                            color: theme.hintColor,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _expanded
              ? _BookDetailSheet(book: book, progress: progress)
              : const SizedBox(width: double.infinity),
        ),
      ],
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

/// 커버 왼쪽 상단 시작일 — 검정, 배경 없이 큰 날짜.
class _CoverStartDateLabel extends StatelessWidget {
  const _CoverStartDateLabel({required this.startedAt});

  final DateTime? startedAt;

  @override
  Widget build(BuildContext context) {
    return Text(
      _dateLabel(startedAt),
      style: const TextStyle(
        color: Colors.black,
        fontSize: 19.2, // 16 × 1.2
        fontWeight: FontWeight.w800,
        height: 1.1,
        letterSpacing: -0.2,
      ),
    );
  }
}

/// 커버 중앙 — 2줄, 일수 강조, 검정·배경 없음.
class _DaysSinceStartBadge extends StatelessWidget {
  const _DaysSinceStartBadge({required this.startedAt});

  final DateTime startedAt;

  @override
  Widget build(BuildContext context) {
    final startDate = DateTime(startedAt.year, startedAt.month, startedAt.day);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = math.max(1, today.difference(startDate).inDays + 1);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '시작한 지',
          style: TextStyle(
            color: Colors.black,
            fontSize: 15.6, // 13 × 1.2
            fontWeight: FontWeight.w700,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '$days일째',
          style: const TextStyle(
            color: Colors.black,
            fontSize: 26.4, // 22 × 1.2
            fontWeight: FontWeight.w800,
            height: 1.05,
            letterSpacing: -0.4,
          ),
        ),
      ],
    );
  }
}

String _completionEstimateLabel(StudentTextbook book, double progress) {
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

/// 메타 아래 펼침 — 예상 개월수 + A/B/C 진행률.
class _BookDetailSheet extends StatelessWidget {
  const _BookDetailSheet({
    required this.book,
    required this.progress,
  });

  final StudentTextbook book;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.07)
              : Colors.black.withValues(alpha: 0.045),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.06),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _completionEstimateLabel(book, progress),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                ),
              ),
              if (book.series == 'ssen') ...[
                const SizedBox(height: 10),
                for (final stage in const ['A', 'B', 'C']) ...[
                  _SheetProgressRow(
                    label: stage,
                    value: book.stageProgress[stage]?.progress ?? 0,
                  ),
                  if (stage != 'C') const SizedBox(height: 6),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CoverProgressOverlay extends StatelessWidget {
  const _CoverProgressOverlay({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
        child: _OverlayProgressRow(label: '전체', value: progress),
      ),
    );
  }
}

class _SheetProgressRow extends StatelessWidget {
  const _SheetProgressRow({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 22,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: value.clamp(0, 1),
              minHeight: 6,
              backgroundColor: theme.brightness == Brightness.dark
                  ? Colors.white12
                  : Colors.black12,
              color: YggGlassTokens.confirmActionColor,
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 36,
          child: Text(
            '${(value * 100).round()}%',
            textAlign: TextAlign.right,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }
}

class _OverlayProgressRow extends StatelessWidget {
  const _OverlayProgressRow({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Row(
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
    );
  }
}

/// 교재 카드와 같은 A4·radius 슬롯 — 배경 투명 + 점선 테두리.
class _AddTextbookCard extends StatelessWidget {
  const _AddTextbookCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.28)
        : Colors.black.withValues(alpha: 0.22);
    final fg = isDark ? Colors.white70 : Colors.black54;

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
              child: CustomPaint(
                painter: _DashedRRectPainter(
                  color: borderColor,
                  radius: _cardRadius,
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_rounded, size: 40, color: fg),
                      const SizedBox(height: 8),
                      Text(
                        '교재 추가',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: fg,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: _coverToMetaSpacing),
            const SizedBox(height: _cardMetaHeight),
          ],
        ),
      ),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({
    required this.color,
    required this.radius,
  });

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(1, 1, size.width - 2, size.height - 2),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      const dash = 7.0;
      const gap = 5.0;
      while (distance < metric.length) {
        final next = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}

/// 마이그레이션된 교재 목록에서 셀프 등록.
class _AddTextbookSheet extends StatefulWidget {
  const _AddTextbookSheet();

  @override
  State<_AddTextbookSheet> createState() => _AddTextbookSheetState();
}

class _AddTextbookSheetState extends State<_AddTextbookSheet> {
  List<AvailableTextbook>? _available;
  String? _error;
  String? _enrollingKey;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _available = null;
    });
    try {
      final list = await TextbookApi.instance.listAvailableTextbooks();
      if (!mounted) return;
      setState(() => _available = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '추가할 교재를 불러오지 못했어요.\n$e');
    }
  }

  Future<void> _enroll(AvailableTextbook book) async {
    final key = '${book.bookId}|${book.gradeLabel}';
    if (_enrollingKey != null) return;
    setState(() => _enrollingKey = key);
    try {
      await TextbookApi.instance.enrollTextbook(
        bookId: book.bookId,
        gradeLabel: book.gradeLabel,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _enrollingKey = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('교재를 추가하지 못했어요.\n$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final height = MediaQuery.sizeOf(context).height * 0.78;

    return Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: height,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.28)
                      : Colors.black.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '교재 추가',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '닫기',
                      onPressed: () => Navigator.of(context).pop(false),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  '정답이 준비된 교재를 골라 내 목록에 넣어요. 추가한 날부터 시작일이 계산돼요.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _buildBody(theme)),
              SizedBox(height: bottom + 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final list = _available;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('다시 시도')),
            ],
          ),
        ),
      );
    }
    if (list == null) {
      return const Center(child: YggLoadingIndicator());
    }
    if (list.isEmpty) {
      return Center(
        child: Text(
          '추가할 수 있는 교재가 없어요.\n이미 모두 추가했거나, 아직 준비된 교재가 없어요.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(color: theme.hintColor),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final book = list[i];
        final key = '${book.bookId}|${book.gradeLabel}';
        final busy = _enrollingKey == key;
        final coverUri = Uri.tryParse(book.coverRef);
        final hasCover = coverUri != null &&
            (coverUri.scheme == 'http' || coverUri.scheme == 'https');
        final coverColor = book.colorValue == null
            ? const Color(0xFF2B2B2B)
            : Color(book.colorValue!);

        return Material(
          color: theme.brightness == Brightness.dark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: busy || _enrollingKey != null ? null : () => _enroll(book),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 52,
                      height: 52 * _coverA4Ratio,
                      child: hasCover
                          ? Image.network(
                              book.coverRef,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  ColoredBox(color: coverColor),
                            )
                          : ColoredBox(color: coverColor),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          book.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          [
                            if (book.gradeLabel.trim().isNotEmpty)
                              book.gradeLabel.trim(),
                            '문항 ${book.totalProblems}',
                          ].join(' · '),
                          style: TextStyle(
                            color: theme.hintColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (busy)
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  else
                    const Icon(
                      Icons.add_circle_outline_rounded,
                      color: YggGlassTokens.confirmActionColor,
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
