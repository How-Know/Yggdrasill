import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/homework_session.dart';
import '../services/student_api.dart';
import '../services/textbook_api.dart';
import '../widgets/student_page_title.dart';
import '../widgets/student_progress_summary_card.dart';

/// 과제 그룹 목록 화면.
///
/// phase 모델(M5와 동일):
///   1 대기 → 탭하면 수행 시작
///   2 수행 → 미니바에서 일시정지/제출
///   3 제출 → 확인 대기 (조작 없음)
///   4 확인 → 탭하면 대기로 복귀
class HomeworkScreen extends StatefulWidget {
  const HomeworkScreen({super.key});

  @override
  State<HomeworkScreen> createState() => _HomeworkScreenState();
}

class _HomeworkScreenState extends State<HomeworkScreen> {
  List<HomeworkGroup>? _groups;
  /// bookId|gradeLabel → cover_ref (활성 교재 목록에서 해석).
  Map<String, String> _coverByBookKey = const {};
  String? _error;
  bool _busy = false;
  Timer? _ticker;
  /// 확인(phase 4) 진입 스낵바용 — 이전 phase 스냅샷.
  final Map<String, int> _phaseByGroupId = {};

  @override
  void initState() {
    super.initState();
    HomeworkSession.instance.addListener(_onSessionChanged);
    // 목록은 HomeworkSession Realtime/폴백이 밀고, 여기선 초기 스냅샷 + 수동 새로고침.
    final cached = HomeworkSession.instance.lastGroups;
    if (cached != null) {
      _applyGroups(
        cached,
        covers: HomeworkSession.instance.lastCovers,
      );
    } else {
      _refresh();
    }
    // 수행 중 경과시간 갱신용 1초 틱.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && (_groups?.any((g) => g.running) ?? false)) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    HomeworkSession.instance.removeListener(_onSessionChanged);
    _ticker?.cancel();
    super.dispose();
  }

  /// 미니바 pause/play가 세션 목록을 갱신하면 이 화면도 즉시 맞춘다.
  void _onSessionChanged() {
    final groups = HomeworkSession.instance.lastGroups;
    if (!mounted || groups == null) return;
    _applyGroups(
      groups,
      covers: HomeworkSession.instance.lastCovers,
      notifyConfirmed: true,
    );
  }

  void _applyGroups(
    List<HomeworkGroup> groups, {
    Map<String, String>? covers,
    bool notifyConfirmed = false,
  }) {
    if (notifyConfirmed) {
      _notifyNewlyConfirmed(groups);
    } else {
      for (final g in groups) {
        _phaseByGroupId[g.groupId] = g.phase;
      }
    }
    setState(() {
      _groups = groups;
      if (covers != null && covers.isNotEmpty) {
        _coverByBookKey = covers;
      }
      _error = null;
    });
  }

  void _notifyNewlyConfirmed(List<HomeworkGroup> groups) {
    final hadSnapshot = _phaseByGroupId.isNotEmpty;
    final newly = <HomeworkGroup>[];
    for (final g in groups) {
      final prev = _phaseByGroupId[g.groupId];
      if (hadSnapshot && prev != null && prev != 4 && g.phase == 4) {
        newly.add(g);
      }
      _phaseByGroupId[g.groupId] = g.phase;
    }
    _phaseByGroupId.removeWhere(
      (id, _) => !groups.any((g) => g.groupId == id),
    );
    if (!mounted || newly.isEmpty) return;
    for (final g in newly) {
      final title = g.title.isEmpty ? '과제' : g.title;
      TopGlassSnackBar.show(
        context,
        message: '$title 확인이 끝났어요. 대기중이에요.',
        icon: Icons.hourglass_top_rounded,
      );
    }
  }

  Future<void> _refresh() async {
    try {
      final groupsFuture = StudentApi.instance.listHomeworkGroups();
      final booksFuture = TextbookApi.instance.listTextbooks().then(
            (books) => books,
            onError: (_, __) => const <StudentTextbook>[],
          );
      final groups = await groupsFuture;
      final books = await booksFuture;
      final covers = <String, String>{};
      for (final book in books) {
        final ref = book.coverRef.trim();
        if (ref.isEmpty) continue;
        covers['${book.bookId}|${book.gradeLabel}'] = ref;
        covers.putIfAbsent(book.bookId, () => ref);
      }
      HomeworkSession.instance.syncFromGroups(groups, covers: covers);
      if (!mounted) return;
      _applyGroups(groups, covers: covers, notifyConfirmed: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '과제를 불러오지 못했어요.\n$e');
    }
  }

  String? _coverRefFor(HomeworkGroup group) {
    if (group.isPrintSource || group.bookId.isEmpty) return null;
    return _coverByBookKey['${group.bookId}|${group.gradeLabel}'] ??
        _coverByBookKey[group.bookId];
  }

  Future<void> _transition(HomeworkGroup group, int fromPhase,
      {String? successMessage}) async {
    if (_busy) return;
    if (fromPhase == 1) {
      HomeworkSession.instance.preferGroup(group.groupId);
    }
    setState(() => _busy = true);
    try {
      final result = await StudentApi.instance.groupTransition(
        groupId: group.groupId,
        fromPhase: fromPhase,
      );
      if (!mounted) return;
      if (result['ok'] == true) {
        if (successMessage != null) {
          TopGlassSnackBar.show(
            context,
            message: successMessage,
            icon: Icons.check_circle_outline_rounded,
          );
        }
      } else if (result['error'] == 'phase_mismatch') {
        await _refresh();
        if (!mounted) return;
        if (fromPhase == 1) {
          HomeworkGroup? latest;
          for (final g in _groups ?? const <HomeworkGroup>[]) {
            if (g.groupId == group.groupId) {
              latest = g;
              break;
            }
          }
          if (latest != null &&
              !latest.running &&
              (latest.phase == 1 || latest.phase == 2)) {
            final retry = await StudentApi.instance.groupTransition(
              groupId: group.groupId,
              fromPhase: 1,
            );
            if (!mounted) return;
            if (retry['ok'] == true) {
              if (successMessage != null) {
                TopGlassSnackBar.show(
                  context,
                  message: successMessage,
                  icon: Icons.check_circle_outline_rounded,
                );
              }
              return;
            }
          }
        }
        TopGlassSnackBar.show(
          context,
          message: '선생님이 방금 과제 상태를 바꿨어요. 목록을 새로고침해요.',
          icon: Icons.sync_rounded,
        );
      } else {
        TopGlassSnackBar.show(
          context,
          message: '처리에 실패했어요. (${result['error']})',
          icon: Icons.error_outline_rounded,
        );
      }
    } catch (_) {
      if (mounted) {
        TopGlassSnackBar.show(
          context,
          message: '통신에 실패했어요. 다시 시도해 주세요.',
          icon: Icons.wifi_off_rounded,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _refresh();
      }
    }
  }

  Future<void> _openAddHomework() async {
    if (_busy) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _AddHomeworkSheet(
        onDescriptiveWriting: () {
          Navigator.of(ctx).pop();
          unawaited(_addDescriptiveWriting());
        },
      ),
    );
  }

  Future<void> _addDescriptiveWriting() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await StudentApi.instance.createDescriptiveWriting();
      if (mounted) {
        TopGlassSnackBar.show(
          context,
          message: '서술형 쓰기 과제를 추가했어요.',
          icon: Icons.edit_note_rounded,
        );
      }
    } catch (_) {
      if (mounted) {
        TopGlassSnackBar.show(
          context,
          message: '과제 추가에 실패했어요.',
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _refresh();
      }
    }
  }

  void _onGroupTap(HomeworkGroup group) {
    HomeworkSession.instance.preferGroup(group.groupId);
    if (_busy || group.isHomeworkOnly) return;

    // 확인 완료(대기중) 탭 → 과제 찾아왔는지 묻고 대기로 전환.
    if (group.phase == 4) {
      unawaited(_confirmFoundHomework(group));
      return;
    }

    // 대기·일시정지(수행 phase인데 타이머 정지) 탭 → 수행 시작.
    // 미니바 pause 직후 목록이 아직 phase=2로 남아 있어도 재개되게 한다.
    if (!group.running && (group.phase == 1 || group.phase == 2)) {
      unawaited(
        _transition(
          group,
          1,
          successMessage: '${group.title} 시작!',
        ),
      );
    }
  }

  Future<void> _confirmFoundHomework(HomeworkGroup group) async {
    final title = group.title.isEmpty ? '과제' : group.title;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: const Text('과제를 찾아왔나요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('아니요'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: YggGlassTokens.confirmActionColor,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('네'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await _transition(group, 4, successMessage: '대기로 전환했어요.');
    }
  }

  Widget _groupCardFor(HomeworkGroup group) {
    return ListenableBuilder(
      listenable: HomeworkSession.instance,
      builder: (context, _) => _GroupCard(
        group: group,
        coverRef: _coverRefFor(group),
        showEqualizer:
            HomeworkSession.instance.isRunningGroup(group.groupId),
        // 제출됨 → 흰 원형 로딩, 대기중 → 초록 체크
        coverBadge: group.phase == 4
            ? _CoverBadge.waiting
            : (group.phase == 3 ? _CoverBadge.submitted : null),
        onTap: () => _onGroupTap(group),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    // 진행률 카드 확장 시 아래 목록을 밀어내며 같은 ListView 스크롤을 쓴다.
    final children = <Widget>[
      // 교재 풀기 탭과 동일 좌우 여백(24) → 진행률 카드 너비 통일.
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        child: _TodayHomeworkProgressSection(
          coverByBookKey: _coverByBookKey,
        ),
      ),
      // 진행률 카드 아래는 시각적으로 더 벌어 보이게 넉넉히 둔다.
      const SizedBox(height: 36),
    ];

    if (groups == null) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 48),
          child: Center(
            child: _error == null
                ? const YggLoadingIndicator(size: 32)
                : Text(_error!, textAlign: TextAlign.center),
          ),
        ),
      );
    } else {
      final priority = groups.take(2).toList(growable: false);
      final waiting = groups.length > 2
          ? groups.sublist(2)
          : const <HomeworkGroup>[];
      children.addAll([
        const _HomeworkSectionHeader(title: '우선 과제'),
        if (priority.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 20, 4),
            child: Text(
              '우선 과제가 없어요.',
              style: TextStyle(
                fontSize: 15,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.45),
              ),
            ),
          )
        else
          _HomeworkHorizontalRow(
            children: [
              for (final group in priority) _groupCardFor(group),
            ],
          ),
        // 카드 줄 ↔ 다음 섹션 타이틀 = 18 + 타이틀 top 10 = 28
        const SizedBox(height: 18),
        const _HomeworkSectionHeader(title: '대기 과제'),
        // 2줄 지그재그 + 세 번째 줄에 과제 추가 카드.
        _HomeworkZigzagRow(
          children: [
            for (final group in waiting) _groupCardFor(group),
          ],
          trailingThirdRow: _AddHomeworkCard(
            enabled: !_busy,
            onTap: _openAddHomework,
          ),
        ),
      ]);
    }

    return StudentCollapsingTitlePage(
      title: '과제',
      onRefresh: _refresh,
      bodyBuilder: (context, topInset, bottomInset) {
        return Padding(
          padding: EdgeInsets.only(top: topInset),
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 112),
                children: children,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 스크린샷 스타일 섹션 제목: 굵은 제목 + 회색 chevron.
class _HomeworkSectionHeader extends StatelessWidget {
  const _HomeworkSectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chevron = theme.colorScheme.onSurface.withValues(alpha: 0.35);
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 20, 8),
      child: Row(
        children: [
          Text(
            title,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              height: 1.15,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(width: 2),
          Icon(
            Icons.chevron_right_rounded,
            size: 30,
            color: chevron,
          ),
        ],
      ),
    );
  }
}

/// 과제 카드를 한 줄에 가로로 나란히 배치한다.
///
/// 카드 너비는 화면 가용폭의 70.4%(이전 넓은 카드 88%의 80%)로 전부 동일.
/// 두 장이 한 화면에 안 들어가면 가로 스크롤한다.
class _HomeworkHorizontalRow extends StatelessWidget {
  const _HomeworkHorizontalRow({required this.children});

  final List<Widget> children;

  static const double _cardHeight = 152;
  static const double _gap = 12;
  /// 이전 스크롤 카드폭 비율(0.88)에서 20% 축소.
  static const double _cardWidthFactor = 0.88 * 0.8;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - 40; // 좌우 패딩 20
        final cardWidth = available * _cardWidthFactor;
        final n = children.length;

        final row = Row(
          children: [
            for (var i = 0; i < n; i += 1) ...[
              if (i > 0) const SizedBox(width: _gap),
              SizedBox(
                width: cardWidth,
                height: _cardHeight,
                child: children[i],
              ),
            ],
          ],
        );

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: row,
        );
      },
    );
  }
}

/// 대기 과제 — 2줄 열 우선 지그재그 + 선택적 세 번째 줄(과제 추가).
///
/// ```
/// [0] [2] [4] …
/// [1] [3] [5] …
/// [+]          ← trailingThirdRow
/// ```
class _HomeworkZigzagRow extends StatelessWidget {
  const _HomeworkZigzagRow({
    required this.children,
    this.trailingThirdRow,
  });

  final List<Widget> children;
  final Widget? trailingThirdRow;

  static const double _cardHeight = 152;
  static const double _gap = 12;
  static const double _cardWidthFactor = 0.88 * 0.8;
  /// 과제카드 표지와 동일 (_GroupCard._coverSize / 좌측 패딩).
  static const double _coverSize = 126.72;
  static const double _coverInset = 6;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty && trailingThirdRow == null) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - 40;
        final cardWidth = available * _cardWidthFactor;
        final columnCount =
            children.isEmpty ? 0 : (children.length + 1) ~/ 2;

        Widget cardAt(int index) {
          return SizedBox(
            width: cardWidth,
            height: _cardHeight,
            child: children[index],
          );
        }

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (columnCount > 0)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var col = 0; col < columnCount; col++) ...[
                      if (col > 0) const SizedBox(width: _gap),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          cardAt(col * 2),
                          if (col * 2 + 1 < children.length) ...[
                            const SizedBox(height: _gap),
                            cardAt(col * 2 + 1),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              if (trailingThirdRow != null) ...[
                if (columnCount > 0) const SizedBox(height: _gap),
                // 표지 썸네일과 같은 크기·왼쪽 정렬.
                // 상단 8 = _GroupCard 세로 패딩과 동일 → 1·2줄 간격과 시각적으로 맞춤.
                Padding(
                  padding: const EdgeInsets.only(left: _coverInset, top: 8),
                  child: SizedBox(
                    width: _coverSize,
                    height: _coverSize,
                    child: trailingThirdRow,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// 교재탭 `_AddTextbookCard`와 같은 점선 슬롯 — 과제카드 표지 크기.
class _AddHomeworkCard extends StatelessWidget {
  const _AddHomeworkCard({
    required this.onTap,
    this.enabled = true,
  });

  final VoidCallback onTap;
  final bool enabled;

  /// _GroupCard._coverRadius 와 동일.
  static const double _radius = 18.48;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.28)
        : Colors.black.withValues(alpha: 0.22);
    final fg = isDark ? Colors.white70 : Colors.black54;

    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(_radius),
          child: CustomPaint(
            painter: _DashedRRectPainter(
              color: borderColor,
              radius: _radius,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 32, color: fg),
                  const SizedBox(height: 4),
                  Text(
                    '과제 추가',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: fg,
                    ),
                  ),
                ],
              ),
            ),
          ),
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

/// 과제 추가 옵션 시트 — 지금은 서술형만 동작.
class _AddHomeworkSheet extends StatelessWidget {
  const _AddHomeworkSheet({required this.onDescriptiveWriting});

  final VoidCallback onDescriptiveWriting;

  static const double _sheetRadius = 28;
  static const double _groupRadius = 22;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
    final card = isDark ? const Color(0xFF2C2C2E) : Colors.white;
    final text = isDark ? Colors.white : Colors.black;
    final sub = text.withValues(alpha: 0.45);
    final divider = text.withValues(alpha: 0.08);

    Widget option({
      required String title,
      required String subtitle,
      required IconData icon,
      required BorderRadius inkRadius,
      VoidCallback? onTap,
    }) {
      final enabled = onTap != null;
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: inkRadius,
          child: Opacity(
            opacity: enabled ? 1 : 0.4,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Row(
                children: [
                  Icon(icon, size: 26, color: text),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: text,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: sub,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: sub,
                    size: 22,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    const topInk = BorderRadius.vertical(
      top: Radius.circular(_groupRadius),
    );
    const bottomInk = BorderRadius.vertical(
      bottom: Radius.circular(_groupRadius),
    );

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(_sheetRadius),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '과제 추가',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: text,
                  ),
                ),
                const SizedBox(height: 14),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: card,
                    borderRadius: BorderRadius.circular(_groupRadius),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(_groupRadius),
                    child: Column(
                      children: [
                        option(
                          title: '서술형 쓰기',
                          subtitle: '빈 서술형 쓰기 과제를 바로 만들어요',
                          icon: Icons.edit_note_rounded,
                          inkRadius: topInk,
                          onTap: onDescriptiveWriting,
                        ),
                        Divider(
                          height: 1,
                          indent: 18,
                          endIndent: 18,
                          color: divider,
                        ),
                        option(
                          title: '교재 과제',
                          subtitle: '곧 추가될 예정이에요',
                          icon: Icons.menu_book_rounded,
                          inkRadius: BorderRadius.zero,
                        ),
                        Divider(
                          height: 1,
                          indent: 18,
                          endIndent: 18,
                          color: divider,
                        ),
                        option(
                          title: '프린트 과제',
                          subtitle: '곧 추가될 예정이에요',
                          icon: Icons.description_outlined,
                          inkRadius: bottomInk,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 오늘 과제 완료율 요약 + (탭 시) iOS 배터리 스타일 상세 카드.
class _TodayHomeworkProgressSection extends StatefulWidget {
  const _TodayHomeworkProgressSection({required this.coverByBookKey});

  final Map<String, String> coverByBookKey;

  @override
  State<_TodayHomeworkProgressSection> createState() =>
      _TodayHomeworkProgressSectionState();
}

class _TodayHomeworkProgressSectionState
    extends State<_TodayHomeworkProgressSection> {
  // 요약 카드 수치는 아직 목업. 상세 리스트만 실데이터.
  static const int _percent = 84;
  static const int _averagePercent = 72;
  static const String _subtitle = '오늘 과제 5개 중 4개 완료';

  bool _expanded = false;
  List<TodayCompletedHomework>? _completed;
  bool _loadingCompleted = false;
  String? _completedError;

  Future<void> _toggle() async {
    final next = !_expanded;
    setState(() => _expanded = next);
    if (next) await _ensureCompletedLoaded();
  }

  Future<void> _ensureCompletedLoaded({bool force = false}) async {
    if (!force && (_completed != null || _loadingCompleted)) return;
    setState(() {
      _loadingCompleted = true;
      _completedError = null;
    });
    try {
      final rows = await StudentApi.instance.listTodayCompletedHomework();
      if (!mounted) return;
      setState(() {
        _completed = rows;
        _loadingCompleted = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _completedError = '완료 과제를 불러오지 못했어요.';
        _loadingCompleted = false;
      });
    }
  }

  String? _coverRefFor(TodayCompletedHomework item) {
    if (item.bookId.isEmpty) return null;
    return widget.coverByBookKey['${item.bookId}|${item.gradeLabel}'] ??
        widget.coverByBookKey[item.bookId];
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StudentProgressSummaryCard(
          percent: _percent,
          subtitle: _subtitle,
          onTap: () => unawaited(_toggle()),
          showInfoIcon: true,
          infoFilled: _expanded,
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeInOutCubic,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 28),
                    Text(
                      '일일 수행률',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w400,
                        letterSpacing: -0.2,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _TodayHomeworkDetailCard(
                      todayPercent: _percent,
                      averagePercent: _averagePercent,
                      completed: _completed,
                      loadingCompleted: _loadingCompleted,
                      completedError: _completedError,
                      coverRefFor: _coverRefFor,
                      onRetryCompleted: () =>
                          unawaited(_ensureCompletedLoaded(force: true)),
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// iOS 배터리 사용량 상세 레이아웃. 차트는 목업, 완료 리스트는 실데이터.
class _TodayHomeworkDetailCard extends StatelessWidget {
  const _TodayHomeworkDetailCard({
    required this.todayPercent,
    required this.averagePercent,
    required this.completed,
    required this.loadingCompleted,
    required this.completedError,
    required this.coverRefFor,
    required this.onRetryCompleted,
  });

  final int todayPercent;
  final int averagePercent;
  final List<TodayCompletedHomework>? completed;
  final bool loadingCompleted;
  final String? completedError;
  final String? Function(TodayCompletedHomework item) coverRefFor;
  final VoidCallback onRetryCompleted;

  /// 최근 14일 (마지막이 오늘) — 간격 축소로 더 많은 막대 표시.
  static const _weekLabels = [
    '수', '목', '금', '토', '일', '월', '화',
    '수', '목', '금', '토', '일', '월', '화',
  ];
  static const _weekValues = [
    0.42, 0.55, 0.48, 0.30, 0.22, 0.60, 0.58,
    0.55, 0.62, 0.48, 0.70, 0.58, 0.66, 0.84,
  ];

  static const _iosBlue = Color(0xFF007AFF);
  /// 상단 요약 카드와 동일.
  static const _cardRadius = 22.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface = isDark
        ? theme.colorScheme.surfaceContainerHigh
        : Colors.white;
    final text = theme.colorScheme.onSurface;
    final subText = theme.colorScheme.onSurface.withValues(alpha: 0.45);
    final divider = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : const Color(0xFFC6C6C8);
    final track = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : const Color(0xFFE5E5EA);
    final barIdle = isDark
        ? Colors.white.withValues(alpha: 0.28)
        : const Color(0xFFAEAEB2);
    final todayIndex = _weekValues.length - 1;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(_cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '오늘 오후 5:00까지 과제 수행률이 평소와 비슷합니다.',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                    height: 1.35,
                    color: text,
                  ),
                ),
                const SizedBox(height: 16),
                // 라벨 위 / 큰 숫자 아래 — 두 열
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '평균',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                              color: subText,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$averagePercent%',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w400,
                              letterSpacing: -0.6,
                              height: 1.05,
                              color: subText,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '오늘',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                              color: _iosBlue,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$todayPercent%',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w400,
                              letterSpacing: -0.6,
                              height: 1.05,
                              color: _iosBlue,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  height: 168,
                  child: _HomeworkWeekBarChart(
                    labels: _weekLabels,
                    values: _weekValues,
                    average: averagePercent / 100,
                    todayIndex: todayIndex,
                    trackColor: track,
                    barIdle: barIdle,
                    accent: _iosBlue,
                    labelColor: subText,
                  ),
                ),
                const SizedBox(height: 12),
                // 범례 (원형 도트)
                Row(
                  children: [
                    _ChartLegendDot(color: track, border: barIdle),
                    const SizedBox(width: 6),
                    Text(
                      '하루 종일',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: subText,
                      ),
                    ),
                    const SizedBox(width: 16),
                    const _ChartLegendDot(color: Color(0xFF8E8E93)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '오후 5:00까지 일일 수행률',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: text.withValues(alpha: 0.75),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 0.33, color: divider),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
            child: Text(
              '완료한 과제',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
                color: text,
              ),
            ),
          ),
          if (loadingCompleted && completed == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: YggLoadingIndicator(size: 28)),
            )
          else if (completedError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              child: Column(
                children: [
                  Text(
                    completedError!,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: subText),
                  ),
                  TextButton(
                    onPressed: onRetryCompleted,
                    child: const Text('다시 시도'),
                  ),
                ],
              ),
            )
          else if (completed == null || completed!.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Text(
                '오늘 완료한 과제가 없어요.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17, color: subText),
              ),
            )
          else
            for (var i = 0; i < completed!.length; i++) ...[
              if (i > 0)
                Padding(
                  // 16(패딩) + 86.4(표지) + 18.2(간격)
                  padding: const EdgeInsets.only(left: 120.6),
                  child: Divider(height: 1, thickness: 0.33, color: divider),
                ),
              _HomeworkDetailListTile(
                item: completed![i],
                coverRef: coverRefFor(completed![i]),
                text: text,
                subText: subText,
              ),
            ],
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Divider(height: 1, thickness: 0.33, color: divider),
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {},
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(_cardRadius),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 12, 18),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '모든 과제 기록 보기',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w400,
                          color: text,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 24,
                      color: subText.withValues(alpha: 0.8),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChartLegendDot extends StatelessWidget {
  const _ChartLegendDot({required this.color, this.border});

  final Color color;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: border == null
            ? null
            : Border.all(color: border!, width: 0.8),
      ),
    );
  }
}

class _HomeworkWeekBarChart extends StatelessWidget {
  const _HomeworkWeekBarChart({
    required this.labels,
    required this.values,
    required this.average,
    required this.todayIndex,
    required this.trackColor,
    required this.barIdle,
    required this.accent,
    required this.labelColor,
  });

  final List<String> labels;
  final List<double> values;
  final double average;
  final int todayIndex;
  final Color trackColor;
  final Color barIdle;
  final Color accent;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const labelH = 20.0;
        // 평균 라벨 자리
        const avgLabelW = 28.0;
        final chartH = constraints.maxHeight - labelH;
        final barsW = constraints.maxWidth - avgLabelW;

        return Column(
          children: [
            SizedBox(
              height: chartH,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: barsW,
                    child: Stack(
                      children: [
                        // 각 막대: 밝은 트랙 + 채움
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < values.length; i++) ...[
                              if (i > 0) const SizedBox(width: 2),
                              Expanded(
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  // 슬롯 대비 막대 굵기 (간격 축소와 함께 더 많은 일수 수용).
                                  child: FractionallySizedBox(
                                    widthFactor: 0.70,
                                    child: Stack(
                                      alignment: Alignment.bottomCenter,
                                      children: [
                                        Container(
                                          decoration: BoxDecoration(
                                            color: trackColor,
                                            borderRadius:
                                                BorderRadius.circular(3),
                                          ),
                                        ),
                                        FractionallySizedBox(
                                          heightFactor:
                                              values[i].clamp(0.04, 1.0),
                                          widthFactor: 1,
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: i == todayIndex
                                                  ? accent
                                                  : barIdle,
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        // 평균 실선
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: chartH * average.clamp(0.0, 1.0),
                          child: Container(
                            height: 1,
                            color: labelColor.withValues(alpha: 0.65),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: avgLabelW,
                    child: Stack(
                      children: [
                        Positioned(
                          left: 4,
                          bottom: chartH * average.clamp(0.0, 1.0) - 7,
                          child: Text(
                            '평균',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                              color: labelColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: labelH,
              child: Row(
                children: [
                  SizedBox(
                    width: barsW,
                    child: Row(
                      children: [
                        for (var i = 0; i < labels.length; i++) ...[
                          if (i > 0) const SizedBox(width: 2),
                          Expanded(
                            child: Text(
                              labels[i],
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w400,
                                color: labelColor,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: avgLabelW),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _HomeworkDetailListTile extends StatelessWidget {
  const _HomeworkDetailListTile({
    required this.item,
    required this.coverRef,
    required this.text,
    required this.subText,
  });

  final TodayCompletedHomework item;
  final String? coverRef;
  final Color text;
  final Color subText;

  static const _fontSize = 20.0;
  /// 아래 과제 리스트 표지와 같은 양식(72 → +20%).
  static const double _coverSize = 86.4;
  static const double _coverRadius = 12.6;
  /// 표지↔텍스트 간격 (14 → +30%).
  static const double _coverToTextGap = 18.2;
  /// 텍스트 줄 간격 (4 → +30%).
  static const double _lineGap = 5.2;

  @override
  Widget build(BuildContext context) {
    final title = item.title.trim().isEmpty ? '(제목 없음)' : item.title.trim();
    final coverUri = Uri.tryParse(coverRef ?? '');
    final hasNetworkCover = !item.isPrintSource &&
        coverUri != null &&
        (coverUri.scheme == 'http' || coverUri.scheme == 'https');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _HomeworkCoverThumb(
            size: _coverSize,
            radius: _coverRadius,
            isPrint: item.isPrintSource,
            coverRef: hasNetworkCover ? coverRef : null,
            showEqualizer: false,
            badge: null,
            // 축소 표지에서는 오버레이 라벨 생략(우측 텍스트로 충분).
            bookLabel: '',
            courseLabel: '',
          ),
          const SizedBox(width: _coverToTextGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: _fontSize,
                    fontWeight: FontWeight.w700,
                    color: text,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: _lineGap),
                Text(
                  item.pageCountLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: _fontSize,
                    fontWeight: FontWeight.w400,
                    color: subText,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: _lineGap),
                Text(
                  item.durationLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: _fontSize,
                    fontWeight: FontWeight.w400,
                    color: subText,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _CoverBadge { submitted, waiting }

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.group,
    required this.coverRef,
    required this.showEqualizer,
    required this.coverBadge,
    required this.onTap,
  });

  final HomeworkGroup group;
  final String? coverRef;
  final bool showEqualizer;
  final _CoverBadge? coverBadge;
  final VoidCallback onTap;

  static const double _coverSize = 126.72; // 105.6 * 1.2
  static const double _coverRadius = 18.48; // 15.4 * 1.2

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dlg = YggDialogColors.of(context);
    final title = group.title.isEmpty ? '(제목 없음)' : group.title;
    final coverUri = Uri.tryParse(coverRef ?? '');
    final hasNetworkCover = !group.isPrintSource &&
        coverUri != null &&
        (coverUri.scheme == 'http' || coverUri.scheme == 'https');

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Row(
            children: [
              _HomeworkCoverThumb(
                size: _coverSize,
                radius: _coverRadius,
                isPrint: group.isPrintSource,
                coverRef: hasNetworkCover ? coverRef : null,
                showEqualizer: showEqualizer,
                badge: coverBadge,
                bookLabel: group.sourceLabel,
                courseLabel: group.courseLabel,
              ),
              const SizedBox(width: 17.6),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                        color: dlg.text,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 10.6),
                    Text(
                      group.pageCountLine.isEmpty ? '-' : group.pageCountLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                        color: dlg.textSub,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
              // 기능은 아직 없음 — 자리만 잡아 둔다.
              IconButton(
                tooltip: '더보기',
                onPressed: () {},
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.more_horiz_rounded,
                  size: 28,
                  color: dlg.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 교재 표지 / 프린트(흰 배경) 썸네일 — 학습앱 채점 과제카드와 동일 규칙.
class _HomeworkCoverThumb extends StatelessWidget {
  const _HomeworkCoverThumb({
    required this.size,
    required this.radius,
    required this.isPrint,
    required this.coverRef,
    this.showEqualizer = false,
    this.badge,
    this.bookLabel = '',
    this.courseLabel = '',
  });

  final double size;
  final double radius;
  final bool isPrint;
  final String? coverRef;
  final bool showEqualizer;
  final _CoverBadge? badge;
  final String bookLabel;
  final String courseLabel;

  @override
  Widget build(BuildContext context) {
    final fallback = isPrint ? Colors.white : const Color(0xFF2E7D32);
    final hasBadge = badge != null;
    final book = bookLabel.trim();
    final course = courseLabel.trim();
    final hasMeta = book.isNotEmpty || course.isNotEmpty;
    Widget cover = coverRef == null
        ? ColoredBox(
            color: fallback,
            child: isPrint
                ? const SizedBox.expand()
                : const Center(
                    child: Icon(
                      Icons.menu_book_rounded,
                      color: Colors.white70,
                      size: 30.8,
                    ),
                  ),
          )
        : Image.network(
            coverRef!,
            fit: BoxFit.cover,
            width: size,
            height: size,
            errorBuilder: (_, __, ___) => ColoredBox(
              color: fallback,
              child: const Center(
                child: Icon(
                  Icons.menu_book_rounded,
                  color: Colors.white70,
                  size: 30.8,
                ),
              ),
            ),
          );

    if (showEqualizer || hasBadge) {
      cover = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 2.2, sigmaY: 2.2),
        child: cover,
      );
    }

    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1A000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              cover,
              if (showEqualizer) ...[
                const ColoredBox(color: Color(0x59000000)),
                const Center(child: _CoverEqualizer()),
              ] else if (hasBadge) ...[
                const ColoredBox(color: Color(0x66000000)),
                Center(child: _CoverBadgeIcon(badge: badge!)),
              ] else if (hasMeta) ...[
                // 하단 비네팅 — 여러 스톱으로 경계가 덜 보이게.
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x00000000),
                        Color(0x00000000),
                        Color(0x14000000),
                        Color(0x2E000000),
                        Color(0x52000000),
                      ],
                      stops: [0.0, 0.42, 0.62, 0.80, 1.0],
                    ),
                  ),
                ),
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (book.isNotEmpty)
                        Text(
                          book,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            height: 1.05,
                            letterSpacing: -0.35,
                          ),
                        ),
                      if (book.isNotEmpty && course.isNotEmpty)
                        const SizedBox(height: 4),
                      if (course.isNotEmpty)
                        Text(
                          course,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFD8D8DE),
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                            height: 1.05,
                            letterSpacing: -0.35,
                          ),
                        ),
                    ],
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

/// 표지 배지: 제출됨=흰 원형 로딩, 대기중=초록 체크.
class _CoverBadgeIcon extends StatelessWidget {
  const _CoverBadgeIcon({required this.badge});

  final _CoverBadge badge;

  @override
  Widget build(BuildContext context) {
    switch (badge) {
      case _CoverBadge.submitted:
        return const SizedBox(
          width: 42,
          height: 42,
          child: CircularProgressIndicator(
            strokeWidth: 5.5,
            color: Colors.white,
            strokeCap: StrokeCap.round,
          ),
        );
      case _CoverBadge.waiting:
        // Icon 위젯은 stroke 굵기를 못 바꿔서, 같은 글리프를 두껍게 그린다.
        return Text(
          String.fromCharCode(Icons.check_rounded.codePoint),
          style: TextStyle(
            fontFamily: Icons.check_rounded.fontFamily,
            package: Icons.check_rounded.fontPackage,
            fontSize: 52,
            fontWeight: FontWeight.w900,
            color: YggGlassTokens.confirmActionColor,
            height: 1,
          ),
        );
    }
  }
}

/// 수행 중 표지 위 작은 이퀄라이저 바.
class _CoverEqualizer extends StatefulWidget {
  const _CoverEqualizer();

  @override
  State<_CoverEqualizer> createState() => _CoverEqualizerState();
}

class _CoverEqualizerState extends State<_CoverEqualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  static const _phases = <double>[0.0, 0.35, 0.7, 0.15, 0.55];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return SizedBox(
          width: 44,
          height: 30,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < _phases.length; i++) ...[
                if (i > 0) const SizedBox(width: 3.2),
                _EqualizerBar(
                  progress: (_controller.value + _phases[i]) % 1.0,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _EqualizerBar extends StatelessWidget {
  const _EqualizerBar({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    // 가운데를 기준으로 위·아래로 대칭 확장.
    final t = (progress < 0.5 ? progress : 1 - progress) * 2;
    final height = 6.0 + t * 22.0;
    return Align(
      alignment: Alignment.center,
      child: Container(
        width: 5.0,
        height: height,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(99),
        ),
      ),
    );
  }
}
