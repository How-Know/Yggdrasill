import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../main.dart' show rootNavigatorKey;
import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../services/update_service.dart';

/// 화면 상단 가운데에 표시되는 iOS 스타일 글래스 스낵바.
///
/// - 기존 하단 [SnackBar]를 대체한다.
/// - 일반 알림은 자동으로 사라진다.
/// - 업데이트 알림은 확인 전까지 유지되며, 다른 알림은 그 아래에 쌓인다.
class TopGlassSnackBar {
  TopGlassSnackBar._();

  static OverlayEntry? _hostEntry;
  static _TopGlassUpdateNoticeData? _updateNotice;
  static _TransientSnackRequest? _transient;

  /// 상단 스낵바를 표시한다. 업데이트 알림이 있으면 그 아래에 표시한다.
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

  /// 업데이트 알림을 상단 글래스 스낵바로 동기화한다.
  static void _syncUpdateNotice(_TopGlassUpdateNoticeData? data) {
    _updateNotice = data;
    final overlay = _resolveOverlay(null);
    if (overlay == null) {
      if (data == null && _transient == null) {
        _hostEntry?.remove();
        _hostEntry = null;
      }
      return;
    }
    if (data == null && _transient == null) {
      _hostEntry?.remove();
      _hostEntry = null;
      return;
    }
    _ensureHost(overlay);
    _hostEntry?.markNeedsBuild();
  }

  static OverlayState? _resolveOverlay(BuildContext? context) {
    return rootNavigatorKey.currentState?.overlay ??
        (context != null
            ? Overlay.maybeOf(context, rootOverlay: true) ??
                Overlay.maybeOf(context)
            : null);
  }

  static void _ensureHost(OverlayState overlay) {
    if (_hostEntry != null) return;
    _hostEntry = OverlayEntry(
      builder: (context) => _TopGlassSnackBarStack(
        updateNotice: _updateNotice,
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
    if (_updateNotice == null && _transient == null) {
      _hostEntry?.remove();
      _hostEntry = null;
      return;
    }
    _hostEntry?.markNeedsBuild();
  }
}

class _TopGlassUpdateNoticeData {
  const _TopGlassUpdateNoticeData({
    required this.tag,
    required this.onSnooze,
    required this.onUpdate,
    required this.updating,
  });

  final String tag;
  final VoidCallback onSnooze;
  final Future<void> Function() onUpdate;
  final bool updating;
}

/// [UpdateService] 알림을 상단 글래스 스낵바로 노출한다.
class TopGlassUpdateNoticeBridge extends StatefulWidget {
  const TopGlassUpdateNoticeBridge({super.key});

  @override
  State<TopGlassUpdateNoticeBridge> createState() =>
      _TopGlassUpdateNoticeBridgeState();
}

class _TopGlassUpdateNoticeBridgeState extends State<TopGlassUpdateNoticeBridge> {
  UpdateNotice? _notice;
  UpdateInfo _progress = const UpdateInfo(phase: UpdatePhase.idle);
  bool _updating = false;

  @override
  void initState() {
    super.initState();
    _notice = UpdateService.availableNoticeNotifier.value;
    _progress = UpdateService.progressNotifier.value;
    UpdateService.availableNoticeNotifier.addListener(_sync);
    UpdateService.progressNotifier.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    UpdateService.availableNoticeNotifier.removeListener(_sync);
    UpdateService.progressNotifier.removeListener(_sync);
    TopGlassSnackBar._syncUpdateNotice(null);
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    setState(() {
      _notice = UpdateService.availableNoticeNotifier.value;
      _progress = UpdateService.progressNotifier.value;
    });
    _publishNotice();
  }

  void _publishNotice() {
    final busy = _progress.phase == UpdatePhase.checking ||
        _progress.phase == UpdatePhase.downloading ||
        _progress.phase == UpdatePhase.readyToApply ||
        _updating;

    if (_notice == null || busy) {
      TopGlassSnackBar._syncUpdateNotice(null);
      return;
    }

    final notice = _notice!;
    TopGlassSnackBar._syncUpdateNotice(
      _TopGlassUpdateNoticeData(
        tag: notice.tag,
        updating: _updating,
        onSnooze: () {
          unawaited(UpdateService.snoozeAvailableUpdateNotice());
        },
        onUpdate: () async {
          if (_updating) return;
          setState(() => _updating = true);
          _publishNotice();
          try {
            await UpdateService.oneClickUpdate(context);
          } finally {
            if (mounted) {
              setState(() => _updating = false);
              _publishNotice();
            }
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
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
    required this.updateNotice,
    required this.transient,
    required this.onTransientDismissed,
  });

  final _TopGlassUpdateNoticeData? updateNotice;
  final _TransientSnackRequest? transient;
  final VoidCallback onTransientDismissed;

  static const double _stackGap = 8;
  static const double _topOffset = 12;
  static const double _outerHorizontalInset = 8;
  static const double _horizontalMargin = 16;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final topInset = media.padding.top;
    final horizontalMargin = _horizontalMargin + _outerHorizontalInset;
    final maxWidth =
        (media.size.width - horizontalMargin * 2).clamp(0.0, 520.0);
    final updateMaxWidth = (maxWidth * 0.7).clamp(0.0, 520.0).toDouble();

    final children = <Widget>[];
    if (updateNotice != null) {
      children.add(
        _TopGlassUpdateNoticePill(
          data: updateNotice!,
          maxWidth: updateMaxWidth,
        ),
      );
    }
    if (transient != null) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: _stackGap));
      }
      children.add(
        _TopGlassSnackBarContent(
          message: transient!.message,
          title: transient!.title,
          icon: transient!.icon,
          onDismissed: () {
            transient!.cancelTimer();
            onTransientDismissed();
          },
        ),
      );
    }

    if (children.isEmpty) return const SizedBox.shrink();

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
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopGlassUpdateNoticePill extends StatelessWidget {
  const _TopGlassUpdateNoticePill({
    required this.data,
    required this.maxWidth,
  });

  final _TopGlassUpdateNoticeData data;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return _TopGlassSnackBarShell(
      maxWidth: maxWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.notifications_none_rounded,
                color: _TopGlassSnackBarShell.titleColor,
                size: 20,
              ),
              SizedBox(width: 10),
              Text(
                '새 업데이트가 있어요',
                style: TextStyle(
                  color: _TopGlassSnackBarShell.titleColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  height: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${data.tag} 버전을 설치할 수 있어요.',
            style: TextStyle(
              color: _TopGlassSnackBarShell.messageColor.withValues(alpha: 0.92),
              fontSize: 14,
              fontWeight: FontWeight.w500,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: data.updating ? null : data.onSnooze,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0x40FFFFFF)),
                    foregroundColor: const Color(0xCCFFFFFF),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    '나중에 알림',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: data.updating ? null : () => data.onUpdate(),
                  style: FilledButton.styleFrom(
                    backgroundColor: FabTabBarTokens.previewConfirmActionColor,
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: data.updating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.system_update_alt, size: 17),
                  label: Text(
                    data.updating ? '업데이트 중...' : '업데이트',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      decoration: TextDecoration.none,
                    ),
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
    this.maxWidth,
    this.fade = 1,
  });

  final Widget child;
  final double? maxWidth;
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
    final blurSigma = FabTabBarTokens.previewAcademyMenuGlassBlurSigma;

    final pill = DecoratedBox(
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

    if (maxWidth == null) return pill;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth!),
      child: pill,
    );
  }
}
