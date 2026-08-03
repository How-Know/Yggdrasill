import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/homework_session.dart';
import '../services/student_api.dart';
import 'student_bottom_nav_bar.dart';

/// 커스텀 탭바 위 — 현재 수행 중 과제 미니 플레이어.
class HomeworkNowPlayingBar extends StatelessWidget {
  const HomeworkNowPlayingBar({
    super.key,
    required this.group,
    this.coverRef,
    this.busy = false,
    this.inline = false,
    this.scale = 1,
    this.width,
    required this.onPlayPause,
    required this.onSubmit,
    this.onExpand,
  });

  final HomeworkGroup group;
  final String? coverRef;
  final bool busy;

  /// 탭·검색과 한 줄에 끼워 넣을 때 (스크롤 축소).
  final bool inline;
  final double scale;

  /// 지정 시 이 너비로 고정 (화면 전체 Expanded 방지).
  final double? width;
  final VoidCallback onPlayPause;
  final VoidCallback onSubmit;

  /// 표지·제목 영역 탭 → 전체 과제 시트.
  final VoidCallback? onExpand;

  static const double height = 64;
  static const double _coverSize = 44;
  static const double _coverRadius = 8;
  static const double _maxWidth = 420;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final surface = isDark
        ? StudentBottomNavTokens.darkSurface
        : StudentBottomNavTokens.lightSurface;
    final titleColor = isDark
        ? StudentBottomNavTokens.darkSelected
        : StudentBottomNavTokens.lightSelected;
    final subColor = isDark
        ? StudentBottomNavTokens.darkUnselected
        : StudentBottomNavTokens.lightUnselected;
    final blur = StudentBottomNavTokens.blurFor(brightness);
    final s = scale.clamp(0.5, 1.5);
    final barHeight = height * s;
    final radius = BorderRadius.circular(barHeight / 2);
    final running = HomeworkSession.instance.isRunningGroup(group.groupId);
    final title = group.title.isEmpty ? '(제목 없음)' : group.title;
    final subtitle = group.primaryMetaLine;
    final coverUri = Uri.tryParse(coverRef ?? '');
    final hasCover = !group.isPrintSource &&
        coverUri != null &&
        (coverUri.scheme == 'http' || coverUri.scheme == 'https');
    final coverSize = (inline ? 40.0 : _coverSize) * s;
    final coverRadius = (inline ? 7.0 : _coverRadius) * s;
    final barWidth = width ??
        (inline ? StudentBottomNavTokens.nowPlayingCompactMaxWidth : _maxWidth);

    return SizedBox(
      width: barWidth,
      height: barHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: isDark ? null : StudentBottomNavTokens.lightShadows,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: CustomPaint(
              foregroundPainter: GlassRimPainter(isDark: isDark),
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  (inline ? 12.0 : 18.0) * s,
                  8 * s,
                  8 * s,
                  8 * s,
                ),
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: radius,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: onExpand,
                          borderRadius: BorderRadius.circular(12 * s),
                          child: Row(
                            children: [
                              _Cover(
                                size: coverSize,
                                radius: coverRadius,
                                isPrint: group.isPrintSource,
                                coverRef: hasCover ? coverRef : null,
                              ),
                              SizedBox(width: (inline ? 10.0 : 12.0) * s),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: (inline ? 14.0 : 15.0) * s,
                                        fontWeight: FontWeight.w700,
                                        color: titleColor,
                                        height: 1.15,
                                      ),
                                    ),
                                    SizedBox(height: 2 * s),
                                    Text(
                                      subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: (inline ? 11.5 : 12.5) * s,
                                        fontWeight: FontWeight.w500,
                                        color: subColor,
                                        height: 1.15,
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
                    SizedBox(width: 2 * s),
                    _AnimatedPlayPauseButton(
                      running: running,
                      busy: busy,
                      size: 44 * s,
                      iconSize: (inline ? 28.0 : 30.0) * s,
                      color: titleColor,
                      onTap: onPlayPause,
                    ),
                    _IconButton(
                      tooltip: '제출',
                      size: 44 * s,
                      onTap: busy ? null : onSubmit,
                      child: Icon(
                        Icons.check_rounded,
                        size: (inline ? 28.0 : 30.0) * s,
                        color: YggGlassTokens.confirmActionColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 재생↔정지: 눌림 시 살짝 줄어든 뒤 아이콘이 크로스페이드로 바뀜 (스피너 없음).
class _AnimatedPlayPauseButton extends StatefulWidget {
  const _AnimatedPlayPauseButton({
    required this.running,
    required this.busy,
    required this.size,
    required this.iconSize,
    required this.color,
    required this.onTap,
  });

  final bool running;
  final bool busy;
  final double size;
  final double iconSize;
  final Color color;
  final VoidCallback onTap;

  @override
  State<_AnimatedPlayPauseButton> createState() =>
      _AnimatedPlayPauseButtonState();
}

class _AnimatedPlayPauseButtonState extends State<_AnimatedPlayPauseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 110),
      reverseDuration: const Duration(milliseconds: 160),
    );
    _scale = Tween<double>(begin: 1, end: 0.78).animate(
      CurvedAnimation(
        parent: _press,
        curve: Curves.easeInCubic,
        reverseCurve: Curves.easeOutBack,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant _AnimatedPlayPauseButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 상태 반영(또는 busy 종료) 후 줄어든 상태에서 다시 커지며 아이콘 전환.
    final settled = widget.running != oldWidget.running ||
        (oldWidget.busy && !widget.busy);
    if (settled && _press.isCompleted) {
      _press.reverse();
    }
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  Future<void> _handleTap() async {
    if (widget.busy) return;
    await _press.forward();
    if (!mounted) return;
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.running ? '일시정지' : '수행',
      child: InkWell(
        onTap: widget.busy ? null : () => unawaited(_handleTap()),
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Center(
            child: ScaleTransition(
              scale: _scale,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) {
                  return FadeTransition(
                    opacity: anim,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.72, end: 1).animate(anim),
                      child: child,
                    ),
                  );
                },
                child: Icon(
                  widget.running
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  key: ValueKey<bool>(widget.running),
                  size: widget.iconSize,
                  color: widget.color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.child,
    required this.onTap,
    required this.tooltip,
    this.size = 44,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: size,
          height: size,
          child: Center(child: child),
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({
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
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: coverRef == null
            ? ColoredBox(
                color: fallback,
                child: isPrint
                    ? const SizedBox.expand()
                    : const Center(
                        child: Icon(
                          Icons.menu_book_rounded,
                          color: Colors.white70,
                          size: 20,
                        ),
                      ),
              )
            : Image.network(
                coverRef!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => ColoredBox(
                  color: fallback,
                  child: const Center(
                    child: Icon(
                      Icons.menu_book_rounded,
                      color: Colors.white70,
                      size: 20,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

/// ListenableBuilder용 헬퍼 — 세션 액션 + 스낵바.
mixin HomeworkNowPlayingActions<T extends StatefulWidget> on State<T> {
  HomeworkSession get session => HomeworkSession.instance;

  Future<void> handleNowPlayingPlayPause() async {
    final group = session.active;
    if (group == null) return;
    // stale HomeworkGroup.running 대신 세션의 실제 러닝 상태를 본다.
    if (session.isRunningGroup(group.groupId)) {
      await session.pause();
      if (!mounted) return;
      TopGlassSnackBar.show(
        context,
        message: '과제를 일시정지했어요.',
        icon: Icons.pause_circle_outline_rounded,
      );
      return;
    }
    final result = await session.play(group.groupId);
    if (!mounted) return;
    if (result['ok'] == true) {
      TopGlassSnackBar.show(
        context,
        message: '${group.title} 시작!',
        icon: Icons.play_circle_outline_rounded,
      );
    } else if (result['error'] == 'phase_mismatch') {
      TopGlassSnackBar.show(
        context,
        message: '과제 상태가 바뀌었어요. 다시 시도해 주세요.',
        icon: Icons.sync_rounded,
      );
    } else {
      TopGlassSnackBar.show(
        context,
        message: '수행을 시작하지 못했어요.',
        icon: Icons.error_outline_rounded,
      );
    }
  }

  Future<void> handleNowPlayingSubmit() async {
    final group = session.active;
    if (group == null) return;
    final result = await session.submit();
    if (!mounted) return;
    if (result['ok'] == true) {
      TopGlassSnackBar.show(
        context,
        message: '과제를 제출했어요!',
        icon: Icons.check_circle_outline_rounded,
      );
    } else if (result['error'] == 'phase_mismatch') {
      TopGlassSnackBar.show(
        context,
        message: '제출할 수 없는 상태예요.',
        icon: Icons.sync_rounded,
      );
    } else {
      TopGlassSnackBar.show(
        context,
        message: '제출에 실패했어요.',
        icon: Icons.error_outline_rounded,
      );
    }
  }
}
