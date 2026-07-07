import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/ygg_glass_tokens.dart';

/// 화면 상단 가운데에 표시되는 iOS 스타일 글래스 스낵바.
///
/// 원본: apps/yggdrasill/lib/widgets/top_glass_snack_bar.dart 에서
/// 앱 고유 결합(UpdateService, main.dart의 rootNavigatorKey)을 제거한
/// 범용 버전. 앱 시작 시 [navigatorKey]를 지정하면 어느 화면에서든
/// 루트 오버레이에 표시된다.
class TopGlassSnackBar {
  TopGlassSnackBar._();

  /// 루트 오버레이 해석에 사용할 navigator key (앱에서 1회 주입).
  static GlobalKey<NavigatorState>? navigatorKey;

  static OverlayEntry? _hostEntry;
  static _TransientSnackRequest? _transient;

  /// 상단 스낵바를 표시한다.
  static void show(
    BuildContext context, {
    required String message,
    String? title,
    IconData? icon,
    Duration duration = const Duration(seconds: 2),
  }) {
    final overlay = _resolveOverlay(context);
    if (overlay == null) return;

    _transient?.cancelTimer();
    _transient = _TransientSnackRequest(
      message: message,
      title: title,
      icon: icon,
      duration: duration,
      onDismissed: () {
        _transient = null;
        _rebuildOrRemoveHost();
      },
    );
    _transient!.startTimer();

    _ensureHost(overlay);
    _hostEntry?.markNeedsBuild();
  }

  static OverlayState? _resolveOverlay(BuildContext? context) {
    return navigatorKey?.currentState?.overlay ??
        (context != null
            ? Overlay.maybeOf(context, rootOverlay: true) ??
                Overlay.maybeOf(context)
            : null);
  }

  static void _ensureHost(OverlayState overlay) {
    if (_hostEntry != null) return;
    _hostEntry = OverlayEntry(
      builder: (context) => _TopGlassSnackBarStack(
        transient: _transient,
        onTransientDismissed: () {
          _transient = null;
          _rebuildOrRemoveHost();
        },
      ),
    );
    overlay.insert(_hostEntry!);
  }

  static void _rebuildOrRemoveHost() {
    if (_transient == null) {
      _hostEntry?.remove();
      _hostEntry = null;
      return;
    }
    _hostEntry?.markNeedsBuild();
  }
}

class _TransientSnackRequest {
  _TransientSnackRequest({
    required this.message,
    required this.title,
    required this.icon,
    required this.duration,
    required this.onDismissed,
  });

  final String message;
  final String? title;
  final IconData? icon;
  final Duration duration;
  final VoidCallback onDismissed;

  Timer? _timer;

  void startTimer() {
    _timer?.cancel();
    _timer = Timer(duration, onDismissed);
  }

  void cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }
}

class _TopGlassSnackBarStack extends StatelessWidget {
  const _TopGlassSnackBarStack({
    required this.transient,
    required this.onTransientDismissed,
  });

  final _TransientSnackRequest? transient;
  final VoidCallback onTransientDismissed;

  static const double _topOffset = 12;
  static const double _outerHorizontalInset = 8;
  static const double _horizontalMargin = 16;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final topInset = media.padding.top;
    const horizontalMargin = _horizontalMargin + _outerHorizontalInset;
    final maxWidth =
        (media.size.width - horizontalMargin * 2).clamp(0.0, 520.0);

    if (transient == null) return const SizedBox.shrink();

    return Positioned(
      top: topInset + _topOffset,
      left: horizontalMargin,
      right: horizontalMargin,
      child: Material(
        type: MaterialType.transparency,
        child: DefaultTextStyle.merge(
          style: const TextStyle(decoration: TextDecoration.none),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _TopGlassSnackBarContent(
                    message: transient!.message,
                    title: transient!.title,
                    icon: transient!.icon,
                    onDismissed: () {
                      transient!.cancelTimer();
                      onTransientDismissed();
                    },
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

class _TopGlassSnackBarContent extends StatefulWidget {
  final String message;
  final String? title;
  final IconData? icon;
  final VoidCallback onDismissed;

  const _TopGlassSnackBarContent({
    required this.message,
    required this.title,
    required this.icon,
    required this.onDismissed,
  });

  @override
  State<_TopGlassSnackBarContent> createState() =>
      _TopGlassSnackBarContentState();
}

class _TopGlassSnackBarContentState extends State<_TopGlassSnackBarContent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _slide;
  late final Animation<double> _fade;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      reverseDuration: const Duration(milliseconds: 260),
    );
    _slide = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _fade = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );
    _controller.forward();
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    try {
      await _controller.reverse();
    } finally {
      widget.onDismissed();
    }
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
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, -40 * (1 - _slide.value)),
          child: child,
        );
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _dismiss,
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) < 0) _dismiss();
        },
        child: AnimatedBuilder(
          animation: _fade,
          builder: (context, child) => _TopGlassSnackBarShell(
            fade: _fade.value,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(
                    widget.icon,
                    color: _TopGlassSnackBarShell.titleColor,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                ],
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.title != null) ...[
                        Text(
                          widget.title!,
                          style: TextStyle(
                            color: _TopGlassSnackBarShell.titleColor
                                .withValues(alpha: _fade.value),
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                      ],
                      Text(
                        widget.message,
                        textAlign: widget.title == null
                            ? TextAlign.center
                            : TextAlign.start,
                        style: TextStyle(
                          color: _TopGlassSnackBarShell.messageColor
                              .withValues(alpha: _fade.value),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
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
}

class _TopGlassSnackBarShell extends StatelessWidget {
  const _TopGlassSnackBarShell({
    required this.child,
    this.fade = 1,
  });

  final Widget child;
  final double fade;

  static const Color _glassTintBase = Color(0xB31C1C1E);
  static const Color _borderColor = Color(0x33FFFFFF);
  static const Color titleColor = Color(0xFFF5F5F7);
  static const Color messageColor = Color(0xFFE3E3E6);

  static const double _horizontalPadding = 26;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(22);
    final glassTint = _glassTintBase.withValues(
      alpha: (_glassTintBase.a * fade).clamp(0.0, 1.0),
    );
    const blurSigma = YggGlassTokens.menuGlassBlurSigma;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: const Color(0x40000000).withValues(alpha: 0.25 * fade),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: blurSigma,
                  sigmaY: blurSigma,
                ),
                child: const ColoredBox(color: Colors.transparent),
              ),
            ),
            ColoredBox(
              color: glassTint,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: _borderColor, width: 0.5),
                  borderRadius: radius,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: _horizontalPadding,
                    vertical: 14,
                  ),
                  child: child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
