import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../main.dart' show rootNavigatorKey;
import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

/// 화면 상단 가운데에 표시되는 iOS 스타일 글래스 스낵바.
///
/// - 기존 하단 [SnackBar]를 대체한다.
/// - 뒷면이 비치는 글래스(BackdropFilter) 스타일이며, **기본(라이트) 모드에서도
///   어두운 톤**을 유지한다 (다크 드롭다운과 유사).
/// - [Opacity]로 전체를 감싸면 BackdropFilter가 동작하지 않으므로, 페이드는
///   틴트 알파로만 처리한다.
class TopGlassSnackBar {
  TopGlassSnackBar._();

  static OverlayEntry? _entry;

  /// 상단 스낵바를 표시한다. 이미 떠 있으면 교체한다.
  static void show(
    BuildContext context, {
    required String message,
    String? title,
    IconData? icon,
    Duration duration = const Duration(seconds: 2),
  }) {
    final overlay = rootNavigatorKey.currentState?.overlay ??
        Overlay.maybeOf(context, rootOverlay: true) ??
        Overlay.maybeOf(context);
    if (overlay == null) return;

    _removeImmediately();

    final entry = OverlayEntry(
      builder: (context) {
        return _TopGlassSnackBarContent(
          message: message,
          title: title,
          icon: icon,
          duration: duration,
          onDismissed: _removeImmediately,
        );
      },
    );
    _entry = entry;
    overlay.insert(entry);
  }

  static void _removeImmediately() {
    _entry?.remove();
    _entry = null;
  }
}

class _TopGlassSnackBarContent extends StatefulWidget {
  final String message;
  final String? title;
  final IconData? icon;
  final Duration duration;
  final VoidCallback onDismissed;

  const _TopGlassSnackBarContent({
    required this.message,
    required this.title,
    required this.icon,
    required this.duration,
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
  Timer? _dismissTimer;
  bool _dismissing = false;

  // 글래스 — 라이트/다크 공통 어두운 톤 (드롭다운 다크 틴트 기반, 약간 더 투명).
  static const Color _glassTintBase = Color(0xB31C1C1E);
  static const Color _borderColor = Color(0x33FFFFFF);
  static const Color _titleColor = Color(0xFFF5F5F7);
  static const Color _messageColor = Color(0xFFE3E3E6);

  static const double _horizontalPadding = 26; // 18 + 8
  static const double _outerHorizontalInset = 8; // 화면 가장자리 추가 여백

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
    _dismissTimer = Timer(widget.duration, _dismiss);
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    _dismissTimer?.cancel();
    try {
      await _controller.reverse();
    } finally {
      widget.onDismissed();
    }
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final topInset = media.padding.top;
    final horizontalMargin = 16.0 + _outerHorizontalInset;
    final maxWidth =
        (media.size.width - horizontalMargin * 2).clamp(0.0, 520.0);

    return Positioned(
      top: topInset + 12,
      left: horizontalMargin,
      right: horizontalMargin,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(0, -40 * (1 - _slide.value)),
            child: child,
          );
        },
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Material(
              type: MaterialType.transparency,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _dismiss,
                onVerticalDragEnd: (details) {
                  if ((details.primaryVelocity ?? 0) < 0) _dismiss();
                },
                child: AnimatedBuilder(
                  animation: _fade,
                  builder: (context, child) => _buildPill(_fade.value),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPill(double fade) {
    final radius = BorderRadius.circular(22);
    final glassTint = _glassTintBase.withValues(
      alpha: (_glassTintBase.a * fade).clamp(0.0, 1.0),
    );
    final blurSigma = FabTabBarTokens.previewAcademyMenuGlassBlurSigma;

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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.icon != null) ...[
                        Icon(widget.icon, color: _titleColor, size: 20),
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
                                  color: _titleColor.withValues(alpha: fade),
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
                                color: _messageColor.withValues(alpha: fade),
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
          ],
        ),
      ),
    );
  }
}
