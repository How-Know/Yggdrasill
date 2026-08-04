import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/homework_session.dart';
import 'student_bottom_nav_bar.dart';

/// 미니바 확장 — 셸 Stack 안에서 전체화면으로 깔리고,
/// 커스텀 탭바·미니바는 그 위에 남는다.
class HomeworkNowPlayingExpanded extends StatefulWidget {
  const HomeworkNowPlayingExpanded({
    super.key,
    required this.onCloseBegin,
    required this.onClose,
    required this.onPlayPause,
    required this.onSubmit,
  });

  /// 닫기 애니 시작 직후 — 탭바 1줄 해제를 스크롤 축소와 동기화.
  final VoidCallback onCloseBegin;
  final VoidCallback onClose;
  final VoidCallback onPlayPause;
  final VoidCallback onSubmit;

  /// 하단 크롬 1줄 전환과 동일 길이.
  static const Duration slideDuration =
      StudentBottomNavTokens.chromeAnimDuration;

  @override
  State<HomeworkNowPlayingExpanded> createState() =>
      _HomeworkNowPlayingExpandedState();
}

class _HomeworkNowPlayingExpandedState extends State<HomeworkNowPlayingExpanded>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slide;
  late final Animation<Offset> _offset;
  bool _closing = false;
  Timer? _paceTick;

  @override
  void initState() {
    super.initState();
    _slide = AnimationController(
      vsync: this,
      duration: HomeworkNowPlayingExpanded.slideDuration,
    );
    _offset = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slide,
      // 탭바 1줄 전환(_AnimatedBottomChrome)과 같은 커브.
      curve: Curves.easeInOutCubic,
      reverseCurve: Curves.easeInOutCubic,
    ));
    _slide.forward();
    // 수행 중 문항당 페이스를 초 단위로 갱신.
    _paceTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (HomeworkSession.instance.active != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _paceTick?.cancel();
    _slide.dispose();
    super.dispose();
  }

  Future<void> _requestClose() async {
    if (_closing) return;
    _closing = true;
    widget.onCloseBegin();
    await _slide.reverse();
    if (!mounted) return;
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface = isDark ? theme.colorScheme.surface : Colors.white;
    final text = theme.colorScheme.onSurface;
    final sub = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final divider = theme.colorScheme.onSurface.withValues(alpha: 0.08);
    final topInset = MediaQuery.paddingOf(context).top;
    final screenW = MediaQuery.sizeOf(context).width;
    // 1줄 크롬(탭+미니바+검색) 기준으로 하단 여백.
    final bottomPad = StudentBottomNavTokens.contentBottomPadding(
      context,
      includeNowPlaying: true,
      compactChrome: true,
    );
    final coverSize = (screenW * 0.58).clamp(200.0, 320.0);

    return SlideTransition(
      position: _offset,
      child: ListenableBuilder(
        listenable: HomeworkSession.instance,
        builder: (context, _) {
          final group = HomeworkSession.instance.active;
          if (group == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              unawaited(_requestClose());
            });
            return Material(color: surface, child: const SizedBox.expand());
          }

          final running =
              HomeworkSession.instance.isRunningGroup(group.groupId);
          final busy = HomeworkSession.instance.busy;
          final coverRef = HomeworkSession.instance.coverRef;
          final title = group.title.isEmpty ? '(제목 없음)' : group.title;
          final subtitle = group.primaryMetaLine;
          final children = group.children;

          return Material(
            color: surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: topInset + 8),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    // 가로·세로 패딩을 같게 해 정원형 뒤로가기.
                    child: SolidCapsuleActionBar(
                      padding: const EdgeInsets.all(8),
                      children: [
                        SolidCapsuleActionButton(
                          tooltip: '뒤로',
                          icon: Icons.chevron_left_rounded,
                          onPressed: () => unawaited(_requestClose()),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(24, 28, 24, bottomPad + 12),
                    children: [
                      Center(
                        child: _SheetCover(
                          size: coverSize,
                          radius: 16,
                          isPrint: group.isPrintSource,
                          coverRef: coverRef,
                        ),
                      ),
                      const SizedBox(height: 28),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                          color: text,
                          height: 1.2,
                        ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          subtitle,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: sub,
                            height: 1.25,
                          ),
                        ),
                      ],
                      if (group.pageCountLine.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          group.pageCountLine,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: sub,
                          ),
                        ),
                      ],
                      if (group
                          .averagePacePerProblemLine(isRunning: running)
                          .isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          group.averagePacePerProblemLine(isRunning: running),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: sub,
                          ),
                        ),
                      ],
                      const SizedBox(height: 22),
                      _NowPlayingActionRow(
                        running: running,
                        busy: busy,
                        onPlayPause: widget.onPlayPause,
                        onSubmit: widget.onSubmit,
                      ),
                      const SizedBox(height: 28),
                      Text(
                        '하위 과제',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: text,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (children.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: Text(
                              '세부 항목이 없어요.',
                              style: TextStyle(color: sub, fontSize: 15),
                            ),
                          ),
                        )
                      else
                        ...List.generate(children.length, (i) {
                          final child = children[i];
                          final done = child.phase >= 3;
                          return Column(
                            children: [
                              if (i > 0)
                                Divider(
                                  height: 1,
                                  indent: 40,
                                  endIndent: 8,
                                  color: divider,
                                ),
                              ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                leading: SizedBox(
                                  width: 28,
                                  child: Text(
                                    '${i + 1}',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: done
                                          ? YggGlassTokens.confirmActionColor
                                          : sub,
                                    ),
                                  ),
                                ),
                                title: Text(
                                  child.title.isEmpty
                                      ? '(제목 없음)'
                                      : child.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                    color: text,
                                    decoration: done
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                                ),
                                subtitle: child.memo.isNotEmpty
                                    ? Text(
                                        child.memo,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: sub,
                                        ),
                                      )
                                    : null,
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (child.page.isNotEmpty)
                                      Text(
                                        'p.${child.page}',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          color: sub,
                                        ),
                                      ),
                                    Icon(
                                      Icons.more_horiz_rounded,
                                      color: text,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        }),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 가운데 수행/일시정지 알약 + 오른쪽 원형 제출 (Apple Music형).
class _NowPlayingActionRow extends StatelessWidget {
  const _NowPlayingActionRow({
    required this.running,
    required this.busy,
    required this.onPlayPause,
    required this.onSubmit,
  });

  final bool running;
  final bool busy;
  final VoidCallback onPlayPause;
  final VoidCallback onSubmit;

  static const double _circleSize = 52;
  static const double _pillWidth = 168;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 스크린샷: 가운데 흰 알약 / 옆 반투명 원. 라이트는 반전.
    final pillBg = isDark ? Colors.white : Colors.black;
    final pillFg = isDark ? Colors.black : Colors.white;
    final circleBg = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.08);
    final circleFg = isDark ? Colors.white : Colors.black;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 왼쪽 슬롯 — 오른쪽 원형과 대칭으로 알약을 가운데 정렬.
        const SizedBox(width: _circleSize),
        const SizedBox(width: 12),
        SizedBox(
          width: _pillWidth,
          height: _circleSize,
          child: Material(
            color: pillBg,
            borderRadius: BorderRadius.circular(_circleSize / 2),
            child: InkWell(
              onTap: busy ? null : onPlayPause,
              borderRadius: BorderRadius.circular(_circleSize / 2),
              child: Opacity(
                opacity: busy ? 0.45 : 1,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      running
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 26,
                      color: pillFg,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      running ? '일시정지' : '수행',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: pillFg,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Tooltip(
          message: '제출',
          child: Material(
            color: circleBg,
            shape: const CircleBorder(),
            child: InkWell(
              onTap: busy ? null : onSubmit,
              customBorder: const CircleBorder(),
              child: Opacity(
                opacity: busy ? 0.45 : 1,
                child: SizedBox(
                  width: _circleSize,
                  height: _circleSize,
                  child: Icon(
                    Icons.check_rounded,
                    size: 24,
                    color: circleFg,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SheetCover extends StatelessWidget {
  const _SheetCover({
    required this.size,
    required this.radius,
    required this.isPrint,
    required this.coverRef,
  });

  final double size;
  final double radius;
  final bool isPrint;
  final String? coverRef;

  @override
  Widget build(BuildContext context) {
    final fallback = isPrint ? Colors.white : const Color(0xFF2E7D32);
    final uri = Uri.tryParse(coverRef ?? '');
    final hasNetwork = !isPrint &&
        uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https');

    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: const [
            BoxShadow(
              color: Color(0x28000000),
              blurRadius: 28,
              offset: Offset(0, 14),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: !hasNetwork
              ? ColoredBox(
                  color: fallback,
                  child: isPrint
                      ? const SizedBox.expand()
                      : Center(
                          child: Icon(
                            Icons.menu_book_rounded,
                            color: Colors.white70,
                            size: size * 0.28,
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
                    child: Center(
                      child: Icon(
                        Icons.menu_book_rounded,
                        color: Colors.white70,
                        size: size * 0.28,
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
