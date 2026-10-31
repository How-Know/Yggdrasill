import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../main.dart' show rootNavigatorKey;
import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../services/update_service.dart';
import 'app_dialog_action_button.dart';
import 'bottom_dialog.dart';
import 'dialog_tokens.dart';

/// 화면 상단 가운데에 표시되는 iOS 스타일 글래스 스낵바.
///
/// - 기존 하단 [SnackBar]를 대체한다.
/// - 일반 알림은 자동으로 사라진다.
/// - 업데이트 알림은 확인 전까지 유지되며, 다른 알림은 그 아래에 쌓인다.
class TopGlassSnackBar {
  TopGlassSnackBar._();

  static OverlayEntry? _hostEntry;
  static _TopGlassUpdateNoticeData? _updateNotice;
  static _UpdateProgressNotice? _progressNotice;
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

  /// 업데이트 제안·진행 창을 상단 스택에 동기화한다.
  static void _syncUpdatePanels({
    _TopGlassUpdateNoticeData? offer,
    _UpdateProgressNotice? progress,
  }) {
    _updateNotice = offer;
    _progressNotice = progress;
    final overlay = _resolveOverlay(null);
    final empty = offer == null && progress == null && _transient == null;
    if (overlay == null || empty) {
      if (empty) {
        _hostEntry?.remove();
        _hostEntry = null;
      }
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
        progressNotice: _progressNotice,
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
    if (_updateNotice == null && _progressNotice == null && _transient == null) {
      _hostEntry?.remove();
      _hostEntry = null;
      return;
    }
    _hostEntry?.markNeedsBuild();
  }
}

class _UpdateProgressNotice {
  const _UpdateProgressNotice({
    required this.title,
    required this.subtitle,
    required this.version,
    required this.ready,
    this.tag,
  });

  final String title;
  final String subtitle;
  final String version;
  final bool ready;
  final String? tag;
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
  String _version = '';

  @override
  void initState() {
    super.initState();
    UpdateService.setAnnounceListener((message) {
      final ctx = rootNavigatorKey.currentContext;
      if (ctx == null) return;
      TopGlassSnackBar.show(
        ctx,
        message: message,
        duration: const Duration(seconds: 4),
      );
    });
    _notice = UpdateService.availableNoticeNotifier.value;
    _progress = UpdateService.progressNotifier.value;
    UpdateService.availableNoticeNotifier.addListener(_sync);
    UpdateService.progressNotifier.addListener(_sync);
    unawaited(_loadVersion());
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _version = info.version);
      _publishNotice();
    } catch (_) {}
  }

  @override
  void dispose() {
    UpdateService.setAnnounceListener(null);
    UpdateService.availableNoticeNotifier.removeListener(_sync);
    UpdateService.progressNotifier.removeListener(_sync);
    TopGlassSnackBar._syncUpdatePanels(offer: null, progress: null);
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
    final phase = _progress.phase;
    final showProgress = _updating ||
        phase == UpdatePhase.checking ||
        phase == UpdatePhase.downloading ||
        phase == UpdatePhase.readyToApply;

    if (showProgress) {
      final ready = phase == UpdatePhase.readyToApply;
      final title = phase == UpdatePhase.checking
          ? '업데이트 확인 중'
          : phase == UpdatePhase.downloading
              ? '업데이트 다운로드 중'
              : ready
                  ? '업데이트 적용 준비 완료'
                  : '업데이트 준비 중';
      final subtitle = _progress.message ??
          (phase == UpdatePhase.checking
              ? '최신 버전을 확인하고 있어요.'
              : phase == UpdatePhase.downloading
                  ? '업데이트 파일을 내려받고 있어요.'
                  : ready
                      ? '잠시 후 앱이 자동으로 재시작됩니다.'
                      : '업데이트 파일을 확인하고 있어요.');
      TopGlassSnackBar._syncUpdatePanels(
        offer: null,
        progress: _UpdateProgressNotice(
          title: title,
          subtitle: subtitle,
          version: _version,
          ready: ready,
          tag: _progress.tag,
        ),
      );
      return;
    }

    if (_notice == null) {
      TopGlassSnackBar._syncUpdatePanels(offer: null, progress: null);
      return;
    }

    final notice = _notice!;
    TopGlassSnackBar._syncUpdatePanels(
      progress: null,
      offer: _TopGlassUpdateNoticeData(
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
    required this.progressNotice,
    required this.transient,
    required this.onTransientDismissed,
  });

  final _TopGlassUpdateNoticeData? updateNotice;
  final _UpdateProgressNotice? progressNotice;
  final _TransientSnackRequest? transient;
  final VoidCallback onTransientDismissed;

  static const double _stackGap = 8;
  static const double _topOffset = 18;
  static const double _transientMaxWidth = 520;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final topInset = media.padding.top;
    final maxWidth = math.min(
      math.max(0.0, media.size.width - BottomDialogMetrics.outerHorizontalPadding * 2),
      BottomDialogMetrics.maxWidthCap,
    );

    final children = <Widget>[];
    if (progressNotice != null) {
      children.add(
        SizedBox(
          width: maxWidth,
          child: IgnorePointer(
            child: _UpdateGlassCard(
              icon: progressNotice!.ready
                  ? Icons.check_circle_outline
                  : Icons.system_update_alt_outlined,
              title: progressNotice!.title,
              child: _UpdateProgressBody(data: progressNotice!),
            ),
          ),
        ),
      );
    } else if (updateNotice != null) {
      children.add(
        SizedBox(
          width: maxWidth,
          child: _UpdateGlassCard(
          icon: Icons.system_update_alt_outlined,
          title: '새 업데이트가 있어요',
          onClose: updateNotice!.updating ? null : updateNotice!.onSnooze,
          footer: Row(
            children: [
              AppDialogCloseButton(
                label: '나중에',
                onPressed: updateNotice!.updating ? null : updateNotice!.onSnooze,
              ),
              const Spacer(),
              AppDialogConfirmButton(
                label: updateNotice!.updating ? '업데이트 중' : '업데이트',
                showIcon: false,
                onPressed: updateNotice!.updating
                    ? null
                    : () => updateNotice!.onUpdate(),
              ),
            ],
          ),
          child: BottomDialogLargeText(
            '${updateNotice!.tag} 버전을 설치할 수 있어요.',
          ),
        ),
        ),
      );
    }
    if (transient != null) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: _stackGap));
      }
      children.add(
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _transientMaxWidth),
          child: _TopGlassSnackBarContent(
          message: transient!.message,
          title: transient!.title,
          icon: transient!.icon,
          onDismissed: () {
            transient!.cancelTimer();
            onTransientDismissed();
          },
        ),
        ),
      );
    }

    if (children.isEmpty) return const SizedBox.shrink();

    return Positioned(
      top: topInset + _topOffset,
      left: 0,
      right: 0,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: DefaultTextStyle.merge(
            style: const TextStyle(decoration: TextDecoration.none),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

class _UpdateGlassCard extends StatelessWidget {
  const _UpdateGlassCard({
    required this.icon,
    required this.title,
    required this.child,
    this.footer,
    this.onClose,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? footer;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    final radius = BorderRadius.circular(BottomDialogMetrics.radius);
    const blurSigma = FabTabBarTokens.previewAcademyMenuGlassBlurSigma;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
                child: const ColoredBox(color: Colors.transparent),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: dlg.glassTint,
                border: Border.all(color: dlg.glassBorder, width: 0.5),
                borderRadius: radius,
              ),
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        BottomDialogMetrics.headerPaddingLeft,
                        BottomDialogMetrics.headerPaddingTop,
                        BottomDialogMetrics.headerPaddingRight,
                        BottomDialogMetrics.headerPaddingBottom,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            icon,
                            color: dlg.headerText,
                            size: BottomDialogMetrics.headerIconSize,
                          ),
                          const SizedBox(width: BottomDialogMetrics.headerIconGap),
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: dlg.headerText,
                                fontSize: BottomDialogMetrics.titleFontSize,
                                fontWeight: FontWeight.w800,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                          if (onClose != null)
                            IconButton(
                              tooltip: '나중에',
                              onPressed: onClose,
                              icon: Icon(Icons.close_rounded, color: dlg.closeIcon),
                            ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: dlg.divider),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        BottomDialogMetrics.bodyHorizontalPadding,
                        BottomDialogMetrics.bodyVerticalPadding,
                        BottomDialogMetrics.bodyHorizontalPadding,
                        BottomDialogMetrics.bodyVerticalPadding,
                      ),
                      child: child,
                    ),
                    if (footer != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          BottomDialogMetrics.bodyHorizontalPadding,
                          0,
                          BottomDialogMetrics.bodyHorizontalPadding,
                          BottomDialogMetrics.footerBottomPadding,
                        ),
                        child: footer,
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

class _UpdateProgressBody extends StatelessWidget {
  const _UpdateProgressBody({required this.data});

  final _UpdateProgressNotice data;

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    final meta = <String>[
      if (data.version.isNotEmpty) '지금 v${data.version}',
      if ((data.tag ?? '').isNotEmpty) data.tag!,
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        BottomDialogLargeText(data.subtitle),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            meta,
            style: TextStyle(
              color: dlg.textSub,
              fontSize: BottomDialogMetrics.smallFontSize,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.none,
            ),
          ),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            if (!data.ready) ...[
              const YggLoadingIndicator(),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: data.ready ? 1 : null,
                  minHeight: 4,
                  color: kDlgAccent,
                  backgroundColor: dlg.divider,
                ),
              ),
            ),
          ],
        ),
      ],
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

    return pill;
  }
}
