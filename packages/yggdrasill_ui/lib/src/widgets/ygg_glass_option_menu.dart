import 'dart:async';

import 'package:flutter/material.dart';

/// 학습앱 PreviewAcademyGlassMenu와 같은 iOS형 글래스 옵션 메뉴.
class YggGlassMenuOption {
  const YggGlassMenuOption({required this.id, required this.label});

  final String id;
  final String label;
}

abstract final class YggGlassOptionMenu {
  YggGlassOptionMenu._();

  static const double menuWidth = 240;
  static const double menuRadius = 28;
  static const double topOffsetFromArrow = 12;
  static const Duration openDuration = Duration(milliseconds: 220);
  static const Duration closeDuration = Duration(milliseconds: 40);
  static const Color tintLight = Color(0xE6FFFFFF);
  static const Color tintDark = Color(0xE61C1C1E);
  static const Color hoverLight = Color(0x14000000);
  static const Color hoverDark = Color(0x12FFFFFF);

  static Future<String?> show({
    required BuildContext context,
    required RenderBox anchor,
    required String selectedId,
    required List<YggGlassMenuOption> options,
  }) {
    final anchorTopRight =
        anchor.localToGlobal(anchor.size.topRight(Offset.zero));
    final screenSize = MediaQuery.sizeOf(context);
    final top = anchorTopRight.dy - topOffsetFromArrow;
    final left = (anchorTopRight.dx - menuWidth)
        .clamp(8.0, screenSize.width - menuWidth - 8);

    final overlay = Overlay.of(context, rootOverlay: true);
    final completer = Completer<String?>();
    late final OverlayEntry entry;

    void removeEntry() {
      entry.remove();
      entry.dispose();
    }

    entry = OverlayEntry(
      builder: (overlayContext) => _YggGlassOptionMenuOverlay(
        left: left,
        top: top,
        menuWidth: menuWidth,
        selectedId: selectedId,
        options: options,
        onClosed: (result) {
          removeEntry();
          if (!completer.isCompleted) completer.complete(result);
        },
      ),
    );

    overlay.insert(entry);
    return completer.future;
  }
}

/// 학습앱과 같은 위·아래 화살표 앵커.
class YggGlassOptionMenuAnchor extends StatelessWidget {
  const YggGlassOptionMenuAnchor({
    super.key,
    this.color,
  });

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ??
        (Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF636366)
            : const Color(0xFFC7C7CC));
    return SizedBox(
      width: 22,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.keyboard_arrow_up, size: 14, color: c),
          Icon(Icons.keyboard_arrow_down, size: 14, color: c),
        ],
      ),
    );
  }
}

class _YggGlassOptionMenuOverlay extends StatefulWidget {
  const _YggGlassOptionMenuOverlay({
    required this.left,
    required this.top,
    required this.menuWidth,
    required this.selectedId,
    required this.options,
    required this.onClosed,
  });

  final double left;
  final double top;
  final double menuWidth;
  final String selectedId;
  final List<YggGlassMenuOption> options;
  final ValueChanged<String?> onClosed;

  @override
  State<_YggGlassOptionMenuOverlay> createState() =>
      _YggGlassOptionMenuOverlayState();
}

class _YggGlassOptionMenuOverlayState extends State<_YggGlassOptionMenuOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: YggGlassOptionMenu.openDuration,
      reverseDuration: YggGlassOptionMenu.closeDuration,
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _close([String? result]) async {
    if (_closing) return;
    _closing = true;
    await _controller.reverse();
    if (mounted) widget.onClosed(result);
  }

  @override
  Widget build(BuildContext context) {
    final barrierOpacity =
        Curves.easeOut.transform(_controller.value.clamp(0.0, 1.0));

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _close(),
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.22 * barrierOpacity),
              ),
            ),
          ),
          Positioned(
            left: widget.left,
            top: widget.top,
            width: widget.menuWidth,
            child: _MenuTransition(
              animation: _controller,
              child: _MenuPanel(
                selectedId: widget.selectedId,
                options: widget.options,
                animation: _controller,
                onOptionSelected: (id) => _close(id),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuTransition extends StatelessWidget {
  const _MenuTransition({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  static const _openCurve = Cubic(0.0, 0.88, 0.18, 1.0);
  static const _closeCurve = Cubic(0.55, 0.0, 1.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final shadows = isDark
        ? const <BoxShadow>[]
        : const [
            BoxShadow(
              color: Color(0x28000000),
              blurRadius: 24,
              offset: Offset(0, 10),
            ),
          ];
    final radius = BorderRadius.circular(YggGlassOptionMenu.menuRadius);

    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = animation.status == AnimationStatus.reverse
            ? _closeCurve.transform(animation.value)
            : _openCurve.transform(animation.value);
        final heightFactor = (0.1 + 0.9 * t).clamp(0.0, 1.0);
        final scale = 0.965 + 0.035 * t;
        final shadowProgress = ((animation.value - 0.9) / 0.1).clamp(0.0, 1.0);
        final shadowOpacity = Curves.easeOut.transform(shadowProgress);
        final animatedShadows = [
          for (final s in shadows)
            s.copyWith(
              color: Color.lerp(Colors.transparent, s.color, shadowOpacity)!,
            ),
        ];

        return Transform.scale(
          scale: scale,
          alignment: Alignment.topRight,
          filterQuality: FilterQuality.high,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: animatedShadows,
            ),
            child: ClipRRect(
              borderRadius: radius,
              clipBehavior: Clip.antiAlias,
              child: Align(
                alignment: Alignment.topRight,
                heightFactor: heightFactor,
                child: child,
              ),
            ),
          ),
        );
      },
      child: child,
    );
  }
}

class _MenuPanel extends StatelessWidget {
  const _MenuPanel({
    required this.selectedId,
    required this.options,
    required this.animation,
    required this.onOptionSelected,
  });

  final String selectedId;
  final List<YggGlassMenuOption> options;
  final Animation<double> animation;
  final ValueChanged<String> onOptionSelected;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tint =
        isDark ? YggGlassOptionMenu.tintDark : YggGlassOptionMenu.tintLight;
    final hover =
        isDark ? YggGlassOptionMenu.hoverDark : YggGlassOptionMenu.hoverLight;
    final title = isDark ? Colors.white : Colors.black;
    final radius = YggGlassOptionMenu.menuRadius;

    return Material(
      type: MaterialType.transparency,
      child: DefaultTextStyle(
        style: const TextStyle(
          decoration: TextDecoration.none,
          decorationColor: Colors.transparent,
        ),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: isDark ? const Color(0x33FFFFFF) : const Color(0x40FFFFFF),
              width: 0.5,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: ColoredBox(
              color: tint,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final option in options)
                      _MenuItem(
                        label: option.label,
                        selected: option.id == selectedId,
                        hoverOverlay: hover,
                        titleColor: title,
                        animation: animation,
                        onTap: () => onOptionSelected(option.id),
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

class _MenuItem extends StatefulWidget {
  const _MenuItem({
    required this.label,
    required this.selected,
    required this.hoverOverlay,
    required this.titleColor,
    required this.animation,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color hoverOverlay;
  final Color titleColor;
  final Animation<double> animation;
  final VoidCallback onTap;

  @override
  State<_MenuItem> createState() => _MenuItemState();
}

class _MenuItemState extends State<_MenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: widget.animation,
          builder: (context, child) {
            final showHover = _hovered &&
                widget.animation.status == AnimationStatus.completed;
            return ColoredBox(
              color: showHover ? widget.hoverOverlay : Colors.transparent,
              child: child!,
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: widget.selected
                      ? Icon(Icons.check, size: 18, color: widget.titleColor)
                      : null,
                ),
                Expanded(
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: widget.titleColor,
                      decoration: TextDecoration.none,
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
