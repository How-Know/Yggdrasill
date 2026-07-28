import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/homework_session.dart';
import '../services/student_api.dart';
import '../services/textbook_api.dart';
import '../widgets/student_page_title.dart';
import 'textbook_solve_screen.dart';

/// 과제 그룹 목록 + 상세(수행/제출) 화면.
///
/// phase 모델(M5와 동일):
///   1 대기 → 탭하면 수행 시작
///   2 수행 → 상세에서 일시정지/제출
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
  String? _selectedGroupId;
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
      if (_selectedGroupId == null && groups.isNotEmpty) {
        _selectedGroupId = groups.first.groupId;
      }
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
    setState(() => _selectedGroupId = group.groupId);
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

  HomeworkGroup? _detailGroup(List<HomeworkGroup> groups) {
    final runningId = HomeworkSession.instance.runningGroupId;
    if (runningId != null) {
      for (final group in groups) {
        if (group.groupId == runningId) return group;
      }
    }
    for (final group in groups) {
      if (group.groupId == _selectedGroupId) return group;
    }
    return groups.isEmpty ? null : groups.first;
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final Widget body;
    if (groups == null) {
      body = Center(
        child: _error == null
            ? const YggLoadingIndicator(size: 32)
            : Text(_error!, textAlign: TextAlign.center),
      );
    } else if (groups.isEmpty) {
      body = RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: const [
            SizedBox(height: 160),
            Center(
              child: Text(
                '오늘은 등록된 과제가 없어요.',
                style: TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      );
    } else {
      body = LayoutBuilder(
        builder: (context, constraints) {
          final detail = _detailGroup(groups);
          final detailWidth =
              ((constraints.maxWidth - 68) / 3).clamp(280.0, 380.0);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: GridView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 8, 14, 112),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 560,
                      mainAxisExtent: 152,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 10,
                    ),
                    itemCount: groups.length,
                        itemBuilder: (context, i) => ListenableBuilder(
                          listenable: HomeworkSession.instance,
                          builder: (context, _) => _GroupCard(
                            group: groups[i],
                            coverRef: _coverRefFor(groups[i]),
                            showEqualizer: HomeworkSession.instance
                                .isRunningGroup(groups[i].groupId),
                            coverBadge: groups[i].phase == 4
                                ? '대기중'
                                : (groups[i].phase == 3 ? '제출됨' : null),
                            onTap: () => _onGroupTap(groups[i]),
                          ),
                        ),
                  ),
                ),
              ),
              SizedBox(
                width: detailWidth,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 8, 20, 112),
                  child: _HomeworkDetailPanel(group: detail!),
                ),
              ),
            ],
          );
        },
      );
    }

    return StudentCollapsingTitlePage(
      title: '과제',
      onRefresh: _refresh,
      actions: [
        IconButton(
          tooltip: '서술형 쓰기 추가',
          onPressed: _busy ? null : _addDescriptiveWriting,
          icon: const Icon(Icons.edit_note_rounded, size: 28),
        ),
      ],
      bodyBuilder: (context, topInset, bottomInset) {
        return Padding(
          padding: EdgeInsets.only(top: topInset),
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: body,
          ),
        );
      },
    );
  }
}

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
  final String? coverBadge;
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
                badgeLabel: coverBadge,
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
                        fontSize: 22,
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
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        color: dlg.textSub,
                        height: 1.2,
                      ),
                    ),
                  ],
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
    this.badgeLabel,
    this.bookLabel = '',
    this.courseLabel = '',
  });

  final double size;
  final double radius;
  final bool isPrint;
  final String? coverRef;
  final bool showEqualizer;
  final String? badgeLabel;
  final String bookLabel;
  final String courseLabel;

  @override
  Widget build(BuildContext context) {
    final fallback = isPrint ? Colors.white : const Color(0xFF2E7D32);
    final hasBadge = badgeLabel != null && badgeLabel!.isNotEmpty;
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
                Center(
                  child: Text(
                    badgeLabel!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                      height: 1,
                    ),
                  ),
                ),
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
                            fontSize: 17,
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
                            fontSize: 17,
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

/// 수행 중 표지 위 작은 이퀄라이저 바.
class _CoverEqualizer extends StatefulWidget {
  const _CoverEqualizer();

  @override
  State<_CoverEqualizer> createState() => _CoverEqualizerState();
}

class _CoverEqualizerState extends State<_CoverEqualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  static const _phases = <double>[0.0, 0.35, 0.7, 0.15, 0.55, 0.9, 0.25];

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
          width: 36,
          height: 28,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < _phases.length; i++) ...[
                if (i > 0) const SizedBox(width: 2.2),
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
    final height = 5.0 + t * 20.0;
    return Align(
      alignment: Alignment.center,
      child: Container(
        width: 2.8,
        height: height,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(99),
        ),
      ),
    );
  }
}

/// 상세 시트: 자식 과제 목록 + (마이그레이션 교재 과제면) 문항 풀기 진입.
class _HomeworkDetailPanel extends StatefulWidget {
  const _HomeworkDetailPanel({required this.group});

  final HomeworkGroup group;

  @override
  State<_HomeworkDetailPanel> createState() => _HomeworkDetailPanelState();
}

class _HomeworkDetailPanelState extends State<_HomeworkDetailPanel> {
  HomeworkGroup get group => widget.group;

  HomeworkMastery? _mastery;
  bool _launching = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMastery());
  }

  Future<void> _loadMastery() async {
    try {
      final mastery =
          await StudentApi.instance.homeworkMastery(group.groupId);
      if (mounted) setState(() => _mastery = mastery);
    } catch (_) {
      if (mounted) setState(() => _mastery = HomeworkMastery.none);
    }
  }

  /// 배정 문항만 풀도록 범위를 좁혀 풀이 화면을 연다.
  Future<void> _openSolve() async {
    if (_launching) return;
    setState(() => _launching = true);
    try {
      final problems =
          await StudentApi.instance.listHomeworkProblems(group.groupId);
      if (!mounted) return;
      if (problems.isEmpty) {
        TopGlassSnackBar.show(
          context,
          message: '이 과제에는 풀 수 있는 문항 정보가 없어요.',
          icon: Icons.info_outline_rounded,
        );
        return;
      }

      final bookId = problems.first.bookId;
      final gradeLabel = problems.first.gradeLabel;
      final books = await TextbookApi.instance.listTextbooks();
      if (!mounted) return;
      StudentTextbook? found;
      for (final b in books) {
        if (b.bookId == bookId && b.gradeLabel == gradeLabel) {
          found = b;
          break;
        }
      }
      final book = found;
      if (book == null) {
        TopGlassSnackBar.show(
          context,
          message: '교재를 찾지 못했어요.',
          icon: Icons.error_outline_rounded,
        );
        return;
      }

      // 이미 통과한 문항은 다시 내지 않는다 (오답만 재출제).
      final pending = problems.where((p) => !p.passed).toList(growable: false);
      final target = pending.isEmpty ? problems : pending;

      final scope = HomeworkSolveScope(
        groupId: group.groupId,
        title: group.title,
        cropIds: {for (final p in target) p.cropId},
        rawPages: {
          for (final p in target)
            if (p.rawPage != null) p.rawPage!,
        },
      );

      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => TextbookSolveScreen(book: book, homework: scope),
        ),
      );
      if (mounted) unawaited(_loadMastery());
    } catch (_) {
      if (mounted) {
        TopGlassSnackBar.show(
          context,
          message: '문항을 불러오지 못했어요.',
          icon: Icons.wifi_off_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mastery = _mastery;
    final problemBased = mastery?.problemBased ?? false;
    return YggGroupedCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            group.title.isEmpty ? '(제목 없음)' : group.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          if (group.pageSummary.isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(
              group.pageSummary,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
          if (problemBased) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(
                  mastery!.mastered
                      ? Icons.verified_rounded
                      : Icons.checklist_rounded,
                  size: 18,
                  color: mastery.mastered
                      ? YggGlassTokens.confirmActionColor
                      : theme.hintColor,
                ),
                const SizedBox(width: 6),
                Text(
                  '문항 ${mastery.passed}/${mastery.total} 통과',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: mastery.mastered
                        ? YggGlassTokens.confirmActionColor
                        : theme.hintColor,
                  ),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed:
                      _launching || mastery.mastered ? null : _openSolve,
                  icon: _launching
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.edit_note_rounded, size: 18),
                  label: Text(mastery.mastered ? '통과' : '풀기'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 8),
          Expanded(
            child: group.children.isEmpty
                ? Center(
                    child: Text(
                      '세부 항목이 없어요.',
                      style: TextStyle(color: theme.hintColor),
                    ),
                  )
                : ListView.separated(
                    itemCount: group.children.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final child = group.children[i];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: Icon(
                          child.phase >= 3
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          color: child.phase >= 3
                              ? YggGlassTokens.confirmActionColor
                              : const Color(0xFF9FB3B3),
                          size: 22,
                        ),
                        title: Text(
                          child.title,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: child.memo.isNotEmpty
                            ? Text(
                                child.memo,
                                style: TextStyle(
                                  color: theme.hintColor,
                                  fontSize: 12.5,
                                ),
                              )
                            : null,
                        trailing: child.page.isNotEmpty
                            ? Text(
                                'p.${child.page}',
                                style: TextStyle(
                                  color: theme.hintColor,
                                  fontSize: 13,
                                ),
                              )
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
