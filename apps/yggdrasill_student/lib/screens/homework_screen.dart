import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/homework_session.dart';
import '../services/student_api.dart';
import '../services/student_attendance_session.dart';
import '../services/textbook_api.dart';
import 'homework_solve_launcher.dart';
import '../widgets/student_page_title.dart';
import '../widgets/student_progress_summary_card.dart';

/// 과제 그룹 목록 화면.
///
/// phase 모델(M5와 동일):
///   1 대기 → 탭하면 수행 시작
///   2 수행 → 미니바에서 일시정지/제출
///   3 제출 → 확인 대기 (조작 없음)
///   4 확인 → 탭하면 대기로 복귀
///       (완료 예약이면 서버는 대기→자동완료를 타지만 UI에는 대기를 비치지 않음)
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

  /// 페이지명: 닉네임(없으면 이름). 로드 전·실패 시 '과제'.
  String _pageTitle = '과제';

  @override
  void initState() {
    super.initState();
    HomeworkSession.instance.addListener(_onSessionChanged);
    unawaited(_loadPageTitle());
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

  Future<void> _loadPageTitle() async {
    try {
      final info = await StudentApi.instance.getInfo();
      if (!mounted || info == null) return;
      final name = info.displayName.trim();
      if (name.isEmpty) return;
      setState(() => _pageTitle = name);
    } catch (_) {
      // 제목은 기본값 '과제' 유지.
    }
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
      // 완료 예약 과제가 대기(1)로 잠깐 내려오는 구간은 목록에서 숨긴다.
      // 서버 자동완료 로직은 그대로 두고, 끝났는지는 상단 진행률로 본다.
      _groups = groups
          .where((g) => !_isTransientCompleteWaiting(g))
          .toList(growable: false);
      if (covers != null && covers.isNotEmpty) {
        _coverByBookKey = covers;
      }
      _error = null;
    });
  }

  /// 완료 버튼 경로: 확인(4)→대기(1)→자동완료 중 대기 UI만 건너뛴다.
  bool _isTransientCompleteWaiting(HomeworkGroup group) {
    return group.pendingComplete && group.phase == 1;
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
        message:
            g.pendingComplete ? '$title 확인이 끝났어요.' : '$title 확인이 끝났어요. 대기중이에요.',
        icon: g.pendingComplete
            ? Icons.check_circle_outline_rounded
            : Icons.hourglass_top_rounded,
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

  Future<bool> _transition(HomeworkGroup group, int fromPhase,
      {String? successMessage}) async {
    if (_busy) return false;
    var succeeded = false;
    if (fromPhase == 1) {
      HomeworkSession.instance.preferGroup(group.groupId);
    }
    setState(() => _busy = true);
    try {
      final result = await StudentApi.instance.groupTransition(
        groupId: group.groupId,
        fromPhase: fromPhase,
      );
      if (!mounted) return false;
      if (result['ok'] == true) {
        succeeded = true;
        if (successMessage != null) {
          TopGlassSnackBar.show(
            context,
            message: successMessage,
            icon: Icons.check_circle_outline_rounded,
          );
        }
      } else if (result['error'] == 'phase_mismatch') {
        await _refresh();
        if (!mounted) return false;
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
            if (!mounted) return false;
            if (retry['ok'] == true) {
              succeeded = true;
              if (successMessage != null) {
                TopGlassSnackBar.show(
                  context,
                  message: successMessage,
                  icon: Icons.check_circle_outline_rounded,
                );
              }
              return true;
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
    return succeeded;
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

  Future<void> _onGroupTap(HomeworkGroup group) async {
    HomeworkSession.instance.preferGroup(group.groupId);
    if (_busy) return;

    // 확인 완료(대기중) 탭 → 과제 찾아왔는지 묻고 대기로 전환.
    if (group.phase == 4) {
      await _confirmFoundHomework(group);
      return;
    }

    if (group.isHomework && group.phase <= 2) {
      final opened = await _openDigitalHomework(group);
      if (opened) return;
    }

    // 대기·일시정지(수행 phase인데 타이머 정지) 탭 → 수행 시작.
    // 미니바 pause 직후 목록이 아직 phase=2로 남아 있어도 재개되게 한다.
    if (!group.running && (group.phase == 1 || group.phase == 2)) {
      await _transition(
        group,
        1,
        successMessage: '${group.title} 시작!',
      );
    }
  }

  /// 문항 스냅샷이 있는 교재 숙제는 배정 범위만 교재 풀이 화면에서 연다.
  ///
  /// 본체는 [openDigitalHomeworkSolve] — 재생 시트의 「문제 풀기」 버튼과
  /// 같은 경로를 쓴다.
  Future<bool> _openDigitalHomework(HomeworkGroup group) async {
    if (!group.digitalSolvable || group.isPrintSource) return false;

    setState(() => _busy = true);
    try {
      return await openDigitalHomeworkSolve(
        context,
        group,
        coverRef: _coverRefFor(group),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
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
    if (yes != true) return;

    if (group.pendingComplete) {
      // 서버는 대기→자동완료를 그대로 타되, 목록에 대기 카드가 깜빡이지 않게 즉시 숨긴다.
      if (mounted) {
        setState(() {
          _groups = (_groups ?? const <HomeworkGroup>[])
              .where((g) => g.groupId != group.groupId)
              .toList(growable: false);
        });
      }
      await _transition(group, 4);
      return;
    }

    await _transition(group, 4, successMessage: '대기로 전환했어요.');
  }

  Widget _groupCardFor(HomeworkGroup group) {
    return ListenableBuilder(
      listenable: HomeworkSession.instance,
      builder: (context, _) => _GroupCard(
        group: group,
        coverRef: _coverRefFor(group),
        showEqualizer: HomeworkSession.instance.isRunningGroup(group.groupId),
        // 제출됨 → 흰 원형 로딩, 대기중 → 초록 체크
        coverBadge: group.phase == 4
            ? _CoverBadge.waiting
            : (group.phase == 3 ? _CoverBadge.submitted : null),
        onTap: () => unawaited(_onGroupTap(group)),
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
      const SizedBox(height: 28),
      const Padding(
        padding: EdgeInsets.fromLTRB(24, 0, 24, 0),
        child: _DailyAverageDummySection(),
      ),
      // 수업시간 카드 아래는 시각적으로 더 벌어 보이게 넉넉히 둔다.
      const SizedBox(height: 44),
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
      // 오늘 계획 풀: 오늘/다음(+스냅샷 이후 추가분) + 오늘 검사 예정 숙제.
      // 학습앱 홈과 같은 orderIndex 순 → 앞 2개 우선, 나머지 대기.
      final planPool = [
        ...groups.where((group) => group.isInClass),
        ...groups.where((group) => group.isHomework && group.isDueForCheck),
      ]..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
      final priority = planPool.take(2).toList(growable: false);
      final waiting = planPool.length > 2
          ? planPool.sublist(2)
          : const <HomeworkGroup>[];
      final homework = groups
          .where((group) => group.isHomework && !group.isDueForCheck)
          .toList(growable: false)
        ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
      final emptyStyle = TextStyle(
        fontSize: 15,
        color: Theme.of(context)
            .colorScheme
            .onSurface
            .withValues(alpha: 0.45),
      );
      children.addAll([
        const _HomeworkSectionHeader(title: '우선 과제'),
        if (priority.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 20, 4),
            child: Text('우선 과제가 없어요.', style: emptyStyle),
          )
        else
          _HomeworkHorizontalRow(
            children: [
              for (final group in priority) _groupCardFor(group),
            ],
          ),
        const SizedBox(height: 28),
        const _HomeworkSectionHeader(title: '대기 과제'),
        if (waiting.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 20, 4),
            child: Text('대기 과제가 없어요.', style: emptyStyle),
          )
        else
          _HomeworkHorizontalRow(
            children: [
              for (final group in waiting) _groupCardFor(group),
            ],
          ),
        const SizedBox(height: 28),
        const _HomeworkSectionHeader(title: '숙제'),
        // 2줄 지그재그 + 세 번째 줄에 과제 추가 카드.
        _HomeworkZigzagRow(
          trailingThirdRow: _AddHomeworkCard(
            enabled: !_busy,
            onTap: _openAddHomework,
          ),
          children: [
            for (final group in homework) _groupCardFor(group),
          ],
        ),
      ]);
    }

    return StudentCollapsingTitlePage(
      title: _pageTitle,
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
      padding: const EdgeInsets.fromLTRB(24, 0, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            title,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              height: 1.15,
              color: theme.colorScheme.onSurface,
            ),
          ),
          // Material chevron은 36 박스 안에 왼쪽 빈 여백이 커서
          // SizedBox 간격을 줄여도 시각 간격이 거의 안 줄어든다 → 왼쪽으로 당김.
          Transform.translate(
            offset: const Offset(-6, 0),
            child: Icon(
              Icons.chevron_right_rounded,
              size: 36,
              color: chevron,
            ),
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
        final columnCount = children.isEmpty ? 0 : (children.length + 1) ~/ 2;

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

/// iOS 스크린타임 스타일 더미 카드.
/// 접힘: 일일 평균 + 메인 수치 / 펼침: 주간 차트 + 하단 링크.
class _DailyAverageDummySection extends StatefulWidget {
  const _DailyAverageDummySection();

  @override
  State<_DailyAverageDummySection> createState() =>
      _DailyAverageDummySectionState();
}

class _DailyAverageDummySectionState extends State<_DailyAverageDummySection> {
  bool _expanded = false;
  StudentClassDurationWeek? _weekDuration;
  bool _loadingWeek = false;
  DateTime? _weekFetchedAt;
  Timer? _tick;
  int _planMinutes = 0;

  static const _cardRadius = 22.0;
  static const _teal = Color(0xFF64D2CF);
  static const _avgGreen = Color(0xFF34C759);
  static const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

  @override
  void initState() {
    super.initState();
    StudentAttendanceSession.instance.addListener(_onAttendanceChanged);
    HomeworkSession.instance.planProgressTick.addListener(_onPlanProgressTick);
    StudentAttendanceSession.instance.planGoalPresentedTick
        .addListener(_onPlanGoalPresented);
    // 세션이 아직 hydrate 전이면 한 번 더 당겨 온다.
    unawaited(
      StudentAttendanceSession.instance.refresh(includeNextClass: true),
    );
    unawaited(_reloadPlanMinutes());
    // 분 단위로 경과·남은 시간 갱신.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      final s = StudentAttendanceSession.instance;
      if (mounted && (s.arrival != null || s.plannedDepartureAt != null)) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    StudentAttendanceSession.instance.removeListener(_onAttendanceChanged);
    HomeworkSession.instance.planProgressTick
        .removeListener(_onPlanProgressTick);
    StudentAttendanceSession.instance.planGoalPresentedTick
        .removeListener(_onPlanGoalPresented);
    super.dispose();
  }

  void _onAttendanceChanged() {
    if (mounted) setState(() {});
  }

  void _onPlanProgressTick() => unawaited(_reloadPlanMinutes());

  void _onPlanGoalPresented() => unawaited(_reloadPlanMinutes());

  Future<void> _reloadPlanMinutes() async {
    try {
      final plan = await StudentApi.instance.todayPlanProgress();
      if (!mounted) return;
      setState(() => _planMinutes = plan.planMinutes);
    } catch (_) {
      // 계획 RPC 미배포 등 — 기존 표시 유지.
    }
  }

  /// 학습앱 `_formatRecommendedMinutesCompact` / 진행률 카드와 동일.
  String _formatPlanMinutes(int minutes) {
    final safe = math.max(0, minutes);
    final hours = safe ~/ 60;
    final remain = safe % 60;
    if (hours <= 0) return '${remain}분';
    if (remain == 0) return '${hours}시간';
    return '${hours}시간 $remain분';
  }

  Future<void> _ensureWeekLoaded({bool force = false}) async {
    if (!force && (_weekDuration != null || _loadingWeek)) return;
    setState(() => _loadingWeek = true);
    try {
      final week = await StudentApi.instance.classDurationWeek();
      if (!mounted) return;
      setState(() {
        _weekDuration = week;
        _weekFetchedAt = DateTime.now();
        _loadingWeek = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingWeek = false);
    }
  }

  void _toggle() {
    final next = !_expanded;
    setState(() => _expanded = next);
    if (next) unawaited(_ensureWeekLoaded(force: true));
  }

  Future<void> _openPlannedDepartureSheet() async {
    final session = StudentAttendanceSession.instance;
    final result = await showGeneralDialog<_PlannedDepartureResult>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '희망 하원 시간',
      barrierColor: Colors.black.withValues(alpha: 0.4),
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (context, animation, secondaryAnimation) {
        return _PlannedDepartureDialog(
          initialTime: session.plannedDepartureAt,
          initialReason: session.earlyLeaveReason,
          classEndTime: session.classEndTime,
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curve = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curve,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.45),
              end: Offset.zero,
            ).animate(curve),
            child: child,
          ),
        );
      },
    );
    if (result == null || !mounted) return;

    try {
      await StudentApi.instance.setPlannedDeparture(
        plannedDepartureAt: result.clear ? null : result.plannedAt,
        reason: result.clear ? null : result.reason,
      );
      await session.refresh(includeNextClass: true);
      if (!mounted) return;
      TopGlassSnackBar.show(
        context,
        message: result.clear ? '희망 하원 시간을 지웠어요.' : '희망 하원 시간을 저장했어요.',
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      TopGlassSnackBar.show(
        context,
        message: msg.contains('early_leave_reason_required')
            ? '수업 종료보다 일찍 가면 하원 사유를 적어 주세요.'
            : '희망 하원 시간을 저장하지 못했어요.',
      );
    }
  }

  /// 등원 시각 → 지금까지. 예: "6시간 23분째", "42분째".
  String _elapsedLabel() {
    final arrival = StudentAttendanceSession.instance.arrival;
    if (arrival == null) return '등원 전';
    final now = DateTime.now();
    var minutes = now.difference(arrival).inMinutes;
    if (minutes < 0) minutes = 0;
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    if (hours <= 0) return '$mins분째';
    if (mins == 0) return '$hours시간째';
    return '$hours시간 $mins분째';
  }

  /// 예: "오후 5시 30분 (2시간 15분 남음)" / 미설정.
  String _plannedDepartureLabel() {
    final planned = StudentAttendanceSession.instance.plannedDepartureAt;
    if (planned == null) return '미설정';
    final period = planned.hour < 12 ? '오전' : '오후';
    final h12 = planned.hour % 12 == 0 ? 12 : planned.hour % 12;
    final mm = planned.minute;
    final timePart = mm == 0 ? '$period ${h12}시' : '$period ${h12}시 ${mm}분';

    final now = DateTime.now();
    var remain = planned.difference(now).inMinutes;
    String remainPart;
    if (remain <= 0) {
      remainPart = '하원 시각이 지났어요';
    } else {
      final hours = remain ~/ 60;
      final mins = remain % 60;
      if (hours <= 0) {
        remainPart = '$mins분 남음';
      } else if (mins == 0) {
        remainPart = '$hours시간 남음';
      } else {
        remainPart = '$hours시간 $mins분 남음';
      }
    }
    return '$timePart ($remainPart)';
  }

  /// 다음 회차 — "수 16:00".
  String _nextClassLabel() {
    final next = StudentAttendanceSession.instance.nextClass?.classDateTime;
    if (next == null) return '일정 없음';
    final wd = _weekdays[next.weekday - 1];
    final hh = next.hour.toString().padLeft(2, '0');
    final mm = next.minute.toString().padLeft(2, '0');
    return '$wd $hh:$mm';
  }

  String _updatedLabel() {
    final at = _weekFetchedAt;
    if (at == null) {
      return _loadingWeek ? '수업시간 기록을 불러오는 중…' : '펼치면 주간 수업시간이 표시돼요';
    }
    final ampm = at.hour < 12 ? '오전' : '오후';
    final hour12 = at.hour % 12 == 0 ? 12 : at.hour % 12;
    final mm = at.minute.toString().padLeft(2, '0');
    return '오늘 $ampm $hour12:$mm에 업데이트됨';
  }

  List<String> _chartLabels() {
    final days = _weekDuration?.days;
    if (days == null || days.isEmpty) return const [];
    return [for (final d in days) d.weekday];
  }

  List<double> _chartValues(int yMax) {
    final days = _weekDuration?.days;
    if (days == null || days.isEmpty || yMax <= 0) return const [];
    return [
      for (final d in days) (d.minutes / yMax).clamp(0.0, 1.0),
    ];
  }

  double _chartAverage(int yMax) {
    final avg = _weekDuration?.averageMinutes;
    if (avg == null || yMax <= 0) return 0;
    return (avg / yMax).clamp(0.0, 1.0);
  }

  String _yMaxLabel(int yMaxMinutes) {
    final hours = (yMaxMinutes / 60).round();
    return '$hours시간';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface =
        isDark ? theme.colorScheme.surfaceContainerHigh : Colors.white;
    final text = theme.colorScheme.onSurface;
    final subText = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final divider =
        isDark ? Colors.white.withValues(alpha: 0.12) : const Color(0xFFC6C6C8);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.45);
    final yMax = _weekDuration?.yMaxMinutes ?? 240;

    // 진행률 카드(StudentProgressSummaryCard)와 동일 셸.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(_cardRadius),
            boxShadow: isDark
                ? null
                : const [
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 18,
                      offset: Offset(0, 6),
                    ),
                  ],
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(_cardRadius),
            clipBehavior: Clip.antiAlias,
            // InkWell 스플래시(회색 퍼짐) 없이 탭만 처리.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                    child: Builder(
                      builder: (context) {
                        // 진행률 카드 부제와 동일.
                        final labelStyle = theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                              color: subText,
                              height: 1.25,
                            ) ??
                            TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                              color: subText,
                              height: 1.25,
                            );
                        // 진행률 카드 숫자(84%)와 동일.
                        final valueStyle =
                            theme.textTheme.displaySmall?.copyWith(
                                  fontSize: 44,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -1.2,
                                  height: 1.0,
                                  color: text,
                                ) ??
                                TextStyle(
                                  fontSize: 44,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -1.2,
                                  height: 1.0,
                                  color: text,
                                );
                        final detailValueStyle = labelStyle.copyWith(
                          fontWeight: FontWeight.w700,
                          color: text,
                        );
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text('오늘 수업', style: labelStyle),
                                ),
                                Text('계획시간', style: labelStyle),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    _elapsedLabel(),
                                    style: valueStyle,
                                  ),
                                ),
                                Text(
                                  _formatPlanMinutes(_planMinutes),
                                  style: theme.textTheme.titleLarge?.copyWith(
                                        fontSize: 22,
                                        fontWeight: FontWeight.w700,
                                        height: 1.0,
                                        letterSpacing: -0.4,
                                        color: text,
                                      ) ??
                                      TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.w700,
                                        height: 1.0,
                                        letterSpacing: -0.4,
                                        color: text,
                                      ),
                                ),
                              ],
                            ),
                            if (_expanded) ...[
                              const SizedBox(height: 24),
                              Row(
                                children: [
                                  Text('하원 예정', style: labelStyle),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      _plannedDepartureLabel(),
                                      textAlign: TextAlign.end,
                                      style: detailValueStyle,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Text('다음 수업', style: labelStyle),
                                  const Spacer(),
                                  Text(
                                    _nextClassLabel(),
                                    style: detailValueStyle,
                                  ),
                                ],
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeInOutCubic,
                    alignment: Alignment.topCenter,
                    child: _expanded
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                // 상단 시간 수치 ↔ 그래프 여백: 기존 16(헤더 bottom) + 16.
                                padding:
                                    const EdgeInsets.fromLTRB(12, 16, 12, 8),
                                child: SizedBox(
                                  height: 196,
                                  child: _loadingWeek && _weekDuration == null
                                      ? const Center(
                                          child: YggLoadingIndicator(size: 28),
                                        )
                                      : _chartLabels().isEmpty
                                          ? Center(
                                              child: Text(
                                                '등록된 수업 요일이 없어요.',
                                                style: TextStyle(
                                                  fontSize: 15,
                                                  color: muted,
                                                ),
                                              ),
                                            )
                                          : _ScreenTimeWeekChart(
                                              labels: _chartLabels(),
                                              values: _chartValues(yMax),
                                              average: _chartAverage(yMax),
                                              yMaxLabel: _yMaxLabel(yMax),
                                              barColor: _teal,
                                              averageColor: _avgGreen,
                                              gridColor:
                                                  muted.withValues(alpha: 0.35),
                                              labelColor: muted,
                                            ),
                                ),
                              ),
                              Divider(
                                height: 1,
                                thickness: 0.33,
                                color: divider,
                              ),
                              // 2번째 카드 하단 행과 같은 푸터 크로마 +
                              // 학습앱「선생님 추가」(+ / 강조색) 패턴.
                              Builder(
                                builder: (context) {
                                  final hasPlan = StudentAttendanceSession
                                          .instance.plannedDepartureAt !=
                                      null;
                                  const accent = Color(0xFF33A373);
                                  return Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap: () => unawaited(
                                          _openPlannedDepartureSheet()),
                                      borderRadius: const BorderRadius.vertical(
                                        bottom: Radius.circular(_cardRadius),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          16,
                                          18,
                                          12,
                                          18,
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              hasPlan
                                                  ? Icons.schedule_rounded
                                                  : Icons.add,
                                              size: 22,
                                              color: accent,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              hasPlan
                                                  ? '희망 하원 시간 수정'
                                                  : '희망 하원 시간 추가',
                                              style: TextStyle(
                                                fontSize: 20,
                                                fontWeight: FontWeight.w600,
                                                letterSpacing: -0.2,
                                                color: accent,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Text(
            _updatedLabel(),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: subText,
            ),
          ),
        ),
      ],
    );
  }
}

class _PlannedDepartureResult {
  const _PlannedDepartureResult._({
    required this.clear,
    this.plannedAt,
    this.reason,
  });

  const _PlannedDepartureResult.save({
    required DateTime plannedAt,
    String? reason,
  }) : this._(clear: false, plannedAt: plannedAt, reason: reason);

  const _PlannedDepartureResult.clear() : this._(clear: true);

  final bool clear;
  final DateTime? plannedAt;
  final String? reason;
}

/// 오늘 예정 귀가 — 프로필 편집(`_NicknameEditDialog`)과 동일 셸·헤더.
class _PlannedDepartureDialog extends StatefulWidget {
  const _PlannedDepartureDialog({
    this.initialTime,
    this.initialReason,
    this.classEndTime,
  });

  final DateTime? initialTime;
  final String? initialReason;
  final DateTime? classEndTime;

  @override
  State<_PlannedDepartureDialog> createState() =>
      _PlannedDepartureDialogState();
}

class _PlannedDepartureDialogState extends State<_PlannedDepartureDialog> {
  late TimeOfDay _time;
  late final TextEditingController _reasonCtrl;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialTime ?? widget.classEndTime ?? DateTime.now();
    _time = TimeOfDay(hour: initial.hour, minute: initial.minute);
    _reasonCtrl = TextEditingController(text: widget.initialReason ?? '');
  }

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  DateTime _plannedAtToday() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, _time.hour, _time.minute);
  }

  bool _isEarlierThanClassEnd(DateTime planned) {
    final end = widget.classEndTime;
    if (end == null) return false;
    final endAt = DateTime(
      planned.year,
      planned.month,
      planned.day,
      end.hour,
      end.minute,
    );
    return planned.isBefore(endAt);
  }

  Future<void> _pickTime() async {
    final picked = await AppTimePickerDialog.show(
      context: context,
      title: '귀가 시각',
      initialTime: _time,
    );
    if (picked != null && mounted) setState(() => _time = picked);
  }

  void _save() {
    final planned = _plannedAtToday();
    final reason = _reasonCtrl.text.trim();
    if (_isEarlierThanClassEnd(planned) && reason.isEmpty) {
      TopGlassSnackBar.show(
        context,
        message: '수업 종료보다 일찍 가면 하원 사유를 적어 주세요.',
      );
      return;
    }
    Navigator.of(context).pop(
      _PlannedDepartureResult.save(
        plannedAt: planned,
        reason: reason.isEmpty ? null : reason,
      ),
    );
  }

  String _formatTimeOfDay(TimeOfDay t) {
    final period = t.hour < 12 ? '오전' : '오후';
    final h12 = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final mm = t.minute.toString().padLeft(2, '0');
    return '$period $h12:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final text = isDark ? Colors.white : Colors.black;
    final sub = isDark
        ? Colors.white.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.4);
    final divider =
        isDark ? Colors.white.withValues(alpha: 0.1) : const Color(0xFFE5E5EA);
    // 프로필 편집·계정 시트와 동일 surface.
    final card = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
    final media = MediaQuery.of(context);
    final dialogW = (media.size.width - 32).clamp(360.0, 560.0);
    final dialogH = (media.size.height * 0.42).clamp(340.0, 460.0);
    final early = _isEarlierThanClassEnd(_plannedAtToday());
    final end = widget.classEndTime;
    final endHint = end == null
        ? null
        : '정규 수업 종료 ${_formatTimeOfDay(TimeOfDay.fromDateTime(end))}';

    final valueStyle = TextStyle(
      color: text,
      fontSize: 17,
      fontWeight: FontWeight.w400,
      letterSpacing: -0.2,
      height: 1.2,
      decoration: TextDecoration.none,
    );
    final labelStyle = TextStyle(
      color: text,
      fontSize: 17,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      decoration: TextDecoration.none,
    );

    return Material(
      type: MaterialType.transparency,
      child: Center(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + media.viewInsets.bottom,
          ),
          child: SizedBox(
            width: dialogW,
            height: dialogH,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: card,
                borderRadius: BorderRadius.circular(28),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x28000000),
                    blurRadius: 40,
                    offset: Offset(0, 16),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Theme(
                  data: Theme.of(context).copyWith(
                    splashColor: Colors.transparent,
                    highlightColor: Colors.transparent,
                    splashFactory: NoSplash.splashFactory,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                        child: SizedBox(
                          height: 56,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Text(
                                '희망 하원 시간',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.3,
                                  color: text,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: SolidCapsuleActionBar(
                                  padding: const EdgeInsets.all(8),
                                  children: [
                                    SolidCapsuleActionButton(
                                      tooltip: '닫기',
                                      icon: Icons.close_rounded,
                                      onPressed: () =>
                                          Navigator.of(context).pop(),
                                    ),
                                  ],
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: SolidCapsuleActionBar(
                                  padding: const EdgeInsets.all(8),
                                  children: [
                                    SolidCapsuleActionButton(
                                      tooltip: '완료',
                                      icon: Icons.check_rounded,
                                      onPressed: _save,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Divider(height: 1, thickness: 0.5, color: divider),
                            Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: _pickTime,
                                child: SizedBox(
                                  height: 56,
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 104,
                                        child: Text('귀가 시각', style: labelStyle),
                                      ),
                                      Expanded(
                                        child: Text(
                                          _formatTimeOfDay(_time),
                                          textAlign: TextAlign.start,
                                          style: valueStyle,
                                        ),
                                      ),
                                      Icon(
                                        Icons.chevron_right_rounded,
                                        size: 22,
                                        color: sub,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            Divider(height: 1, thickness: 0.5, color: divider),
                            if (early) ...[
                              SizedBox(
                                height: 56,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: 104,
                                      child: Text('하원 사유', style: labelStyle),
                                    ),
                                    Expanded(
                                      child: TextField(
                                        controller: _reasonCtrl,
                                        textAlign: TextAlign.start,
                                        textInputAction: TextInputAction.done,
                                        onSubmitted: (_) => _save(),
                                        style: valueStyle,
                                        cursorColor: text,
                                        cursorWidth: 1.5,
                                        decoration: InputDecoration(
                                          hintText: '필수',
                                          hintStyle: valueStyle.copyWith(
                                            color: sub,
                                          ),
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          filled: false,
                                          isDense: true,
                                          contentPadding: EdgeInsets.zero,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Divider(
                                height: 1,
                                thickness: 0.5,
                                color: divider,
                              ),
                            ],
                            if (widget.initialTime != null) ...[
                              Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () => Navigator.of(context).pop(
                                    const _PlannedDepartureResult.clear(),
                                  ),
                                  child: SizedBox(
                                    height: 56,
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        '희망 하원 시간 지우기',
                                        style: labelStyle.copyWith(
                                          color: const Color(0xFFFF554F),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Divider(
                                height: 1,
                                thickness: 0.5,
                                color: divider,
                              ),
                            ],
                          ],
                        ),
                      ),
                      const Spacer(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
                        child: Text(
                          endHint == null
                              ? '오늘 몇 시까지 집에 가는지 적어 주세요. 필수는 아니에요.'
                              : '$endHint · 수업 종료보다 이르면 사유가 필요해요.',
                          style: TextStyle(
                            color: sub,
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                            height: 1.35,
                            letterSpacing: -0.1,
                            decoration: TextDecoration.none,
                          ),
                        ),
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

/// 스크린타임 스타일 주간 수업시간 막대 차트.
class _ScreenTimeWeekChart extends StatelessWidget {
  const _ScreenTimeWeekChart({
    required this.labels,
    required this.values,
    required this.average,
    required this.yMaxLabel,
    required this.barColor,
    required this.averageColor,
    required this.gridColor,
    required this.labelColor,
  });

  final List<String> labels;
  final List<double> values;
  final double average;
  final String yMaxLabel;
  final Color barColor;
  final Color averageColor;
  final Color gridColor;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const labelH = 22.0;
        const axisW = 44.0;
        final chartH = constraints.maxHeight - labelH;
        final barsW = constraints.maxWidth - axisW;

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
                        // 가로 점선 그리드
                        CustomPaint(
                          size: Size(barsW, chartH),
                          painter: _DashedGridPainter(color: gridColor),
                        ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < values.length; i++) ...[
                              if (i > 0) const SizedBox(width: 10),
                              Expanded(
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: FractionallySizedBox(
                                    widthFactor: 0.55,
                                    heightFactor: values[i].clamp(0.0, 1.0),
                                    child: values[i] <= 0
                                        ? const SizedBox.shrink()
                                        : DecoratedBox(
                                            decoration: BoxDecoration(
                                              color: barColor,
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        // 평균 점선
                        if (average > 0)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: chartH * average.clamp(0.0, 1.0),
                            child: CustomPaint(
                              size: Size(barsW, 1),
                              painter: _DashedLinePainter(color: averageColor),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: axisW,
                    child: Stack(
                      children: [
                        Positioned(
                          right: 0,
                          top: 0,
                          child: Text(
                            yMaxLabel,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                              color: labelColor,
                            ),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Text(
                            '0',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                              color: labelColor,
                            ),
                          ),
                        ),
                        if (average > 0)
                          Positioned(
                            left: 4,
                            bottom: chartH * average.clamp(0.0, 1.0) - 7,
                            child: Text(
                              '평균',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: averageColor,
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
                          if (i > 0) const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              labels[i],
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w400,
                                color: labelColor,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: axisW),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DashedGridPainter extends CustomPainter {
  _DashedGridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;
    const rows = 5;
    const dash = 3.0;
    const gap = 3.0;
    for (var r = 0; r <= rows; r++) {
      final y = size.height * (r / rows);
      var x = 0.0;
      while (x < size.width) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + dash, size.width), y),
          paint,
        );
        x += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedGridPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _DashedLinePainter extends CustomPainter {
  _DashedLinePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    const dash = 4.0;
    const gap = 3.0;
    var x = 0.0;
    final y = size.height / 2;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, y),
        Offset(math.min(x + dash, size.width), y),
        paint,
      );
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter oldDelegate) =>
      oldDelegate.color != color;
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
  bool _expanded = false;
  List<TodayCompletedHomework>? _completed;
  bool _loadingCompleted = false;
  String? _completedError;
  StudentTodayPlanProgress _planProgress = const StudentTodayPlanProgress();
  StudentTodayProductivity _productivity = const StudentTodayProductivity();
  List<StudentDailyPerformance> _dailyPerformance = const [];

  /// 과제 세션 목록 변화 감지용 (완료로 목록에서 빠지면 수행속도 갱신).
  Set<String> _trackedGroupIds = const {};
  Timer? _completedRefreshDebounce;
  Timer? _productivityRefreshTimer;

  @override
  void initState() {
    super.initState();
    _trackedGroupIds = {
      for (final g
          in HomeworkSession.instance.lastGroups ?? const <HomeworkGroup>[])
        g.groupId,
    };
    HomeworkSession.instance.addListener(_onHomeworkSessionChanged);
    HomeworkSession.instance.planProgressTick.addListener(_onPlanProgressTick);
    StudentAttendanceSession.instance.planGoalPresentedTick
        .addListener(_onPlanGoalPresented);
    _productivityRefreshTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _scheduleProgressReload(debounceMs: 0),
    );
    unawaited(_ensureCompletedLoaded(force: true));
  }

  @override
  void dispose() {
    _completedRefreshDebounce?.cancel();
    _productivityRefreshTimer?.cancel();
    HomeworkSession.instance.removeListener(_onHomeworkSessionChanged);
    HomeworkSession.instance.planProgressTick
        .removeListener(_onPlanProgressTick);
    StudentAttendanceSession.instance.planGoalPresentedTick
        .removeListener(_onPlanGoalPresented);
    super.dispose();
  }

  void _scheduleProgressReload({int debounceMs = 300}) {
    _completedRefreshDebounce?.cancel();
    _completedRefreshDebounce = Timer(Duration(milliseconds: debounceMs), () {
      if (mounted) unawaited(_ensureCompletedLoaded(force: true));
    });
  }

  void _onHomeworkSessionChanged() {
    final groups = HomeworkSession.instance.lastGroups;
    if (groups == null) return;
    final ids = {for (final g in groups) g.groupId};
    if (ids.length == _trackedGroupIds.length &&
        ids.containsAll(_trackedGroupIds)) {
      return;
    }
    _trackedGroupIds = ids;
    // 목록 변동(완료·배정 등) 직후 완료 RPC를 잠깐 디바운스해 갱신.
    _scheduleProgressReload(debounceMs: 400);
  }

  void _onPlanProgressTick() {
    // 채점/통과로 완료율이 바뀌면 그룹 id가 같아도 %를 다시 받는다.
    _scheduleProgressReload(debounceMs: 250);
  }

  void _onPlanGoalPresented() {
    // 학습앱 계획 저장 → 상단 %·계획시간 즉시 재조회.
    _scheduleProgressReload(debounceMs: 200);
  }

  Future<void> _toggle() async {
    final next = !_expanded;
    setState(() => _expanded = next);
    // 펼칠 때마다 다시 받아 학습앱 완료 반영을 바로 본다.
    if (next) await _ensureCompletedLoaded(force: true);
  }

  Future<void> _ensureCompletedLoaded({bool force = false}) async {
    if (!force && (_completed != null || _loadingCompleted)) return;
    setState(() {
      _loadingCompleted = true;
      _completedError = null;
    });
    try {
      // 리스트만 이번 등원 이후. 수행률·완료율은 아래 별도 RPC.
      final rows = await StudentApi.instance.listSessionCompletedHomework();
      StudentTodayPlanProgress plan = const StudentTodayPlanProgress();
      StudentTodayProductivity productivity = const StudentTodayProductivity();
      List<StudentDailyPerformance> dailyPerformance = const [];
      try {
        plan = await StudentApi.instance.todayPlanProgress();
      } catch (_) {
        // 계획 RPC 미배포 등 — 완료 목록은 그대로 보여준다.
      }
      try {
        productivity = await StudentApi.instance.todayProductivity();
      } catch (_) {
        // 생산성 RPC 미배포 등 — 기본 문구를 유지한다.
      }
      try {
        dailyPerformance = await StudentApi.instance.dailyPerformance(days: 8);
      } catch (_) {
        // 회차 스냅샷 RPC 미배포 등 — 그래프 빈 상태를 유지한다.
      }
      if (!mounted) return;
      setState(() {
        _completed = rows;
        _planProgress = plan;
        _productivity = productivity;
        _dailyPerformance = dailyPerformance;
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

  /// 오늘 계획 과제 완료 수. RPC 개수가 없으면 목록으로 추정.
  String _planGroupCompletionLabel() {
    if (_planProgress.hasGroupCounts) {
      return _planProgress.groupCompletionLabel;
    }
    final completed = _completed?.length ?? 0;
    final groups = HomeworkSession.instance.lastGroups ?? const <HomeworkGroup>[];
    final active = groups
        .where((g) => g.isInClass && !g.isAdditionalAfterSnapshot)
        .length;
    final total = completed + active;
    return '$total개 중 $completed개 완료';
  }

  /// 오늘 순수 수업시간 ÷ 오늘 새로 통과한 문항수.
  String _paceTrailingLabel() {
    final problems = _productivity.completedProblemCount;
    if (problems <= 0) return '오늘 수행속도';
    final sec = _productivity.productiveSeconds;
    if (sec <= 0) return '오늘 수행속도';
    final per = sec / problems / 60.0;
    if (per < 1) {
      final secs = (per * 60).round();
      if (secs <= 0) return '오늘 수행속도';
      return '한 문제 당 $secs초';
    }
    final whole = per.round();
    if ((per - whole).abs() < 0.05) {
      return '한 문제 당 $whole분';
    }
    return '한 문제 당 ${per.toStringAsFixed(1)}분';
  }

  String? _coverRefFor(TodayCompletedHomework item) {
    if (item.bookId.isEmpty) return null;
    return widget.coverByBookKey['${item.bookId}|${item.gradeLabel}'] ??
        widget.coverByBookKey[item.bookId];
  }

  @override
  Widget build(BuildContext context) {
    final percent = _planProgress.percent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StudentProgressSummaryCard(
          percent: percent,
          subtitle: '오늘 수업 계획',
          trailingSubtitle: _paceTrailingLabel(),
          trailingValue: _planGroupCompletionLabel(),
          onTap: () => unawaited(_toggle()),
          showInfoIcon: false,
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
                      todayPercent: percent,
                      dailyPerformance: _dailyPerformance,
                      completed: _completed,
                      loadingCompleted: _loadingCompleted,
                      completedError: _completedError,
                      coverRefFor: _coverRefFor,
                      onRetryCompleted: () =>
                          unawaited(_ensureCompletedLoaded(force: true)),
                      onViewAllRecords: () => unawaited(
                        _showRecentCompletedHomeworkDialog(
                          context,
                          coverByBookKey: widget.coverByBookKey,
                        ),
                      ),
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
    required this.dailyPerformance,
    required this.completed,
    required this.loadingCompleted,
    required this.completedError,
    required this.coverRefFor,
    required this.onRetryCompleted,
    required this.onViewAllRecords,
  });

  final int todayPercent;
  final List<StudentDailyPerformance> dailyPerformance;
  final List<TodayCompletedHomework>? completed;
  final bool loadingCompleted;
  final String? completedError;
  final String? Function(TodayCompletedHomework item) coverRefFor;
  final VoidCallback onRetryCompleted;
  final VoidCallback onViewAllRecords;

  static const _iosBlue = Color(0xFF007AFF);

  /// 상단 요약 카드와 동일.
  static const _cardRadius = 22.0;

  static String _performanceSummaryLine({
    required int todayPercent,
    required int? averagePercent,
  }) {
    if (averagePercent == null) {
      return '평균을 계산할 이전 수업 기록이 없습니다.';
    }
    final delta = todayPercent - averagePercent;
    if (delta <= -8) {
      return '오늘 과제 수행률이 평소보다 낮습니다.';
    }
    if (delta >= 8) {
      return '오늘 과제 수행률이 평소보다 높습니다.';
    }
    return '오늘 과제 수행률이 평소와 비슷합니다.';
  }

  static String _weekdayLabel(DateTime date) {
    const labels = ['월', '화', '수', '목', '금', '토', '일'];
    return labels[(date.weekday - 1).clamp(0, labels.length - 1)];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface =
        isDark ? theme.colorScheme.surfaceContainerHigh : Colors.white;
    final text = theme.colorScheme.onSurface;
    final subText = theme.colorScheme.onSurface.withValues(alpha: 0.45);
    final divider =
        isDark ? Colors.white.withValues(alpha: 0.12) : const Color(0xFFC6C6C8);
    final barIdle =
        isDark ? Colors.white.withValues(alpha: 0.28) : const Color(0xFFAEAEB2);
    final history = dailyPerformance.toList(growable: false)
      ..sort((a, b) => a.date.compareTo(b.date));
    final chartLabels =
        history.map((row) => _weekdayLabel(row.date)).toList(growable: false);
    final chartValues =
        history.map((row) => row.performanceRate).toList(growable: false);
    final todayIndex = history.isEmpty ? -1 : history.length - 1;
    final pastValues = history
        .take(todayIndex < 0 ? 0 : todayIndex)
        .where((row) => row.sessionCount > 0 && row.planMinutes > 0)
        .map((row) => row.performanceRate)
        .toList(growable: false);
    final double? chartAverage = pastValues.isEmpty
        ? null
        : pastValues.reduce((a, b) => a + b) / pastValues.length;

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
                  _performanceSummaryLine(
                    todayPercent: todayPercent,
                    averagePercent: chartAverage == null
                        ? null
                        : (chartAverage * 100).round(),
                  ),
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    height: 1.3,
                    color: text,
                  ),
                ),
                const SizedBox(height: 18),
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
                            chartAverage == null
                                ? '기록 없음'
                                : '${(chartAverage * 100).round()}%',
                            style: TextStyle(
                              fontSize: chartAverage == null ? 22 : 34,
                              fontWeight: FontWeight.w400,
                              letterSpacing: -0.8,
                              height: 1.0,
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
                          const Text(
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
                            style: const TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w400,
                              letterSpacing: -0.8,
                              height: 1.0,
                              color: _iosBlue,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                SizedBox(
                  height: 176,
                  child: _HomeworkWeekBarChart(
                    labels: chartLabels,
                    values: chartValues,
                    average: chartAverage ?? 0,
                    todayIndex: todayIndex,
                    barIdle: barIdle,
                    accent: _iosBlue,
                    labelColor: subText,
                  ),
                ),
                const SizedBox(height: 14),
                // 범례 (원형 도트)
                Row(
                  children: [
                    const _ChartLegendDot(
                      color: Colors.transparent,
                      border: Color(0xFF8E8E93),
                    ),
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
                        '현재까지 일일 수행률',
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
                '이번 수업에서 완료한 과제가 없어요.',
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
              onTap: onViewAllRecords,
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

Future<void> _showRecentCompletedHomeworkDialog(
  BuildContext context, {
  required Map<String, String> coverByBookKey,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '모든 과제 기록',
    barrierColor: Colors.black.withValues(alpha: 0.4),
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (context, animation, secondaryAnimation) {
      return _RecentCompletedHomeworkDialog(
        coverByBookKey: coverByBookKey,
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curve = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.08),
            end: Offset.zero,
          ).animate(curve),
          child: child,
        ),
      );
    },
  );
}

class _RecentCompletedHomeworkDialog extends StatefulWidget {
  const _RecentCompletedHomeworkDialog({required this.coverByBookKey});

  final Map<String, String> coverByBookKey;

  @override
  State<_RecentCompletedHomeworkDialog> createState() =>
      _RecentCompletedHomeworkDialogState();
}

class _RecentCompletedHomeworkDialogState
    extends State<_RecentCompletedHomeworkDialog> {
  List<TodayCompletedHomework>? _rows;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows =
          await StudentApi.instance.listRecentCompletedHomework(days: 30);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '과제 기록을 불러오지 못했어요.';
        _loading = false;
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface =
        isDark ? theme.colorScheme.surfaceContainerHigh : Colors.white;
    final text = theme.colorScheme.onSurface;
    final subText = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final divider =
        isDark ? Colors.white.withValues(alpha: 0.12) : const Color(0xFFC6C6C8);
    final media = MediaQuery.of(context);
    final dialogH = (media.size.height * 0.78).clamp(420.0, 720.0);

    return SafeArea(
      child: Center(
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 520,
              maxHeight: dialogH,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: isDark
                      ? null
                      : const [
                          BoxShadow(
                            color: Color(0x28000000),
                            blurRadius: 28,
                            offset: Offset(0, 12),
                          ),
                        ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: () => Navigator.of(context).maybePop(),
                              icon: Icon(
                                Icons.close_rounded,
                                color: subText,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                '모든 과제 기록',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.2,
                                  color: text,
                                ),
                              ),
                            ),
                            const SizedBox(width: 48),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        child: Text(
                          '최근 1달',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: subText,
                          ),
                        ),
                      ),
                      Divider(height: 1, thickness: 0.5, color: divider),
                      Expanded(
                        child: _loading
                            ? const Center(
                                child: YggLoadingIndicator(size: 28),
                              )
                            : _error != null
                                ? Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          _error!,
                                          style: TextStyle(
                                            fontSize: 16,
                                            color: subText,
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: () => unawaited(_load()),
                                          child: const Text('다시 시도'),
                                        ),
                                      ],
                                    ),
                                  )
                                : (_rows == null || _rows!.isEmpty)
                                    ? Center(
                                        child: Text(
                                          '최근 1달 완료한 과제가 없어요.',
                                          style: TextStyle(
                                            fontSize: 16,
                                            color: subText,
                                          ),
                                        ),
                                      )
                                    : ListView.separated(
                                        padding: const EdgeInsets.only(
                                          bottom: 12,
                                        ),
                                        itemCount: _rows!.length,
                                        separatorBuilder: (_, __) => Padding(
                                          padding: const EdgeInsets.only(
                                            left: 120.6,
                                          ),
                                          child: Divider(
                                            height: 1,
                                            thickness: 0.33,
                                            color: divider,
                                          ),
                                        ),
                                        itemBuilder: (context, index) {
                                          final item = _rows![index];
                                          return _HomeworkDetailListTile(
                                            item: item,
                                            coverRef: _coverRefFor(item),
                                            text: text,
                                            subText: subText,
                                            showFinishedDate: true,
                                          );
                                        },
                                      ),
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
        border: border == null ? null : Border.all(color: border!, width: 0.8),
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
    required this.barIdle,
    required this.accent,
    required this.labelColor,
  });

  final List<String> labels;
  final List<double> values;
  final double average;
  final int todayIndex;
  final Color barIdle;
  final Color accent;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const labelH = 26.0;
        // 평균 라벨 자리
        const avgLabelW = 30.0;
        final chartH = constraints.maxHeight - labelH;
        final barsW = constraints.maxWidth - avgLabelW;
        final avgY = chartH * average.clamp(0.0, 1.0);

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
                        // 알약형 막대 (배경 트랙 없음 — 스크린샷과 동일).
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < values.length; i++) ...[
                              if (i > 0) const SizedBox(width: 8),
                              Expanded(
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: FractionallySizedBox(
                                    widthFactor: 0.78,
                                    heightFactor: values[i].clamp(0.0, 1.0),
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color:
                                            i == todayIndex ? accent : barIdle,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
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
                          bottom: avgY,
                          child: Container(
                            height: 1,
                            color:
                                const Color(0xFF8E8E93).withValues(alpha: 0.85),
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
                          bottom: avgY - 7,
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
                          if (i > 0) const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              labels[i],
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w400,
                                color: i == todayIndex ? accent : labelColor,
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
    this.showFinishedDate = false,
  });

  final TodayCompletedHomework item;
  final String? coverRef;
  final Color text;
  final Color subText;
  final bool showFinishedDate;

  String get _finishedDateLine {
    final at = item.finishedAt?.toLocal();
    if (at == null) return '';
    final y = at.year.toString().padLeft(4, '0');
    final m = at.month.toString().padLeft(2, '0');
    final d = at.day.toString().padLeft(2, '0');
    return '$y.$m.$d';
  }

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
                if (showFinishedDate && _finishedDateLine.isNotEmpty) ...[
                  const SizedBox(height: _lineGap),
                  Text(
                    _finishedDateLine,
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
    // 진행률 카드 부제와 동일: onSurface @ 55%.
    final subText = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    // 홈 카드 전용 표시. 서버 group_title / 채점모드 / Now Playing 은 원본 title 유지.
    final rawTitle = group.title.isEmpty ? '(제목 없음)' : group.title;
    final title = group.isInClass && group.isAdditionalAfterSnapshot
        ? '+ $rawTitle'
        : rawTitle;
    final coverUri = Uri.tryParse(coverRef ?? '');
    final hasNetworkCover = !group.isPrintSource &&
        coverUri != null &&
        (coverUri.scheme == 'http' || coverUri.scheme == 'https');

    final coverLabels = <Widget>[
      if (group.inspectionLabel.isNotEmpty)
        _AssignmentOriginBadge(
          label: group.inspectionLabel,
          carryover: false,
          onCover: true,
        ),
      if (group.isHomework && group.assignmentOriginLabel.isNotEmpty)
        _AssignmentOriginBadge(
          label: group.assignmentOriginLabel,
          carryover: false,
          onCover: true,
        ),
    ];

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
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
                overlayLabels: coverLabels,
              ),
              const SizedBox(width: 28),
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
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
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
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        color: subText,
                        height: 1.2,
                      ),
                    ),
                    if (group.recommendedDurationLine.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        group.recommendedDurationLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                          color: subText,
                          height: 1.2,
                        ),
                      ),
                    ],
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

class _AssignmentOriginBadge extends StatelessWidget {
  const _AssignmentOriginBadge({
    required this.label,
    required this.carryover,
    this.onCover = false,
  });

  final String label;
  final bool carryover;
  final bool onCover;

  @override
  Widget build(BuildContext context) {
    final color =
        carryover ? const Color(0xFF5E5CE6) : YggGlassTokens.confirmActionColor;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: onCover ? color.withValues(alpha: 0.92) : color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        boxShadow: onCover
            ? const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            color: onCover ? Colors.white : color,
            fontSize: 13,
            fontWeight: FontWeight.w800,
            height: 1,
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
    this.overlayLabels = const [],
  });

  final double size;
  final double radius;
  final bool isPrint;
  final String? coverRef;
  final bool showEqualizer;
  final _CoverBadge? badge;
  final String bookLabel;
  final String courseLabel;
  final List<Widget> overlayLabels;

  @override
  Widget build(BuildContext context) {
    final fallback = isPrint ? Colors.white : const Color(0xFF2E7D32);
    final hasBadge = badge != null;
    final book = bookLabel.trim();
    final course = courseLabel.trim();
    // 표지 이미지가 있으면 제목/과정·하단 그라데이션은 숨긴다.
    final hasCoverImage = (coverRef ?? '').trim().isNotEmpty;
    final hasMeta =
        !hasCoverImage && (book.isNotEmpty || course.isNotEmpty);
    final hasOverlayLabels = overlayLabels.isNotEmpty;
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
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            height: 1.05,
                            letterSpacing: -0.35,
                            fontFamily: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.fontFamily,
                          ),
                        ),
                      if (book.isNotEmpty && course.isNotEmpty)
                        const SizedBox(height: 4),
                      if (course.isNotEmpty)
                        Text(
                          course,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: const Color(0xFFD8D8DE),
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                            height: 1.05,
                            letterSpacing: -0.35,
                            fontFamily: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.fontFamily,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (hasOverlayLabels)
                Positioned(
                  left: 8,
                  right: 8,
                  top: 8,
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: overlayLabels,
                  ),
                ),
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
