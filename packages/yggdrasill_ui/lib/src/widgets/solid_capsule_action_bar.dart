import 'package:flutter/material.dart';

/// 불투명 알약형 상단 액션 버튼 모음 토큰.
///
/// 학습앱 문제은행·시간표 등에서 쓰는 솔리드 캡슐 스타일과 동일.
class SolidCapsuleActionBarTokens {
  const SolidCapsuleActionBarTokens._();

  static const Color backgroundDark = Color(0xFF000000);
  static const Color backgroundLight = Color(0xFFFFFFFF);

  static Color background(Brightness brightness) =>
      brightness == Brightness.dark ? backgroundDark : backgroundLight;

  static Color border(Brightness brightness) => brightness == Brightness.dark
      ? Colors.white.withValues(alpha: 0.12)
      : Colors.black.withValues(alpha: 0.04);

  static List<BoxShadow> boxShadows(Brightness brightness) => [
        BoxShadow(
          color: Colors.black.withValues(
            alpha: brightness == Brightness.dark ? 0.22 : 0.08,
          ),
          blurRadius: 28,
          offset: const Offset(0, 12),
        ),
      ];

  static Color iconColor(
    Brightness brightness, {
    bool selected = false,
    bool accentWhenSelected = false,
  }) {
    if (brightness == Brightness.dark) {
      return const Color(0xFFF4F5F5);
    }
    if (accentWhenSelected && selected) {
      return const Color(0xFF1A6B5E);
    }
    if (selected) {
      return const Color(0xFF111A1D);
    }
    return Colors.black;
  }
}

Animation<double> _solidCapsuleBounceScale(AnimationController controller) {
  return TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 1.14)
          .chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 40,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.14, end: 0.92)
          .chain(CurveTween(curve: Curves.easeInOutCubic)),
      weight: 28,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 0.92, end: 1.0)
          .chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 32,
    ),
  ]).animate(controller);
}

/// 단일 아이콘 캡슐일 때 셸 전체 바운스를 자식 버튼에 노출.
class _SolidCapsuleBounceScope extends InheritedWidget {
  const _SolidCapsuleBounceScope({
    required this.playBounce,
    required super.child,
  });

  final VoidCallback playBounce;

  static _SolidCapsuleBounceScope? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_SolidCapsuleBounceScope>();
  }

  @override
  bool updateShouldNotify(_SolidCapsuleBounceScope oldWidget) => false;
}

/// 불투명 알약 배경 위에 아이콘 버튼을 가로로 묶는 공용 셸.
class SolidCapsuleActionBar extends StatefulWidget {
  const SolidCapsuleActionBar({
    super.key,
    this.child,
    this.children,
    this.padding = SolidCapsuleActionBar.defaultPadding,
    this.itemSpacing = 22,
    this.borderRadius = 999,
  }) : assert(child != null || children != null);

  final Widget? child;
  final List<Widget>? children;
  final EdgeInsetsGeometry padding;
  final double itemSpacing;
  final double borderRadius;

  static const EdgeInsets defaultPadding =
      EdgeInsets.symmetric(horizontal: 14, vertical: 8);

  @override
  State<SolidCapsuleActionBar> createState() => _SolidCapsuleActionBarState();
}

class _SolidCapsuleActionBarState extends State<SolidCapsuleActionBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bounce;
  late final Animation<double> _scale;

  /// 아이콘 1개짜리 닫기/완료 버튼 — 캡슐 전체를 스케일한다.
  bool get _scaleShell {
    if (widget.child != null) return true;
    final kids = widget.children;
    return kids != null && kids.length == 1;
  }

  @override
  void initState() {
    super.initState();
    _bounce = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
    _scale = _solidCapsuleBounceScale(_bounce);
  }

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  void _playBounce() {
    _bounce
      ..stop()
      ..value = 0
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final radius = BorderRadius.circular(widget.borderRadius);

    final Widget rowChild;
    if (widget.children != null) {
      final items = <Widget>[];
      for (var i = 0; i < widget.children!.length; i++) {
        if (i > 0) items.add(SizedBox(width: widget.itemSpacing));
        items.add(widget.children![i]);
      }
      rowChild = Row(mainAxisSize: MainAxisSize.min, children: items);
    } else {
      rowChild = widget.child!;
    }

    Widget shell = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: SolidCapsuleActionBarTokens.boxShadows(brightness),
      ),
      child: Container(
        padding: widget.padding,
        decoration: BoxDecoration(
          color: SolidCapsuleActionBarTokens.background(brightness),
          borderRadius: radius,
          border: Border.all(
            color: SolidCapsuleActionBarTokens.border(brightness),
          ),
        ),
        child: rowChild,
      ),
    );

    if (_scaleShell) {
      shell = _SolidCapsuleBounceScope(
        playBounce: _playBounce,
        child: AnimatedBuilder(
          animation: _scale,
          builder: (context, child) {
            return Transform.scale(
              scale: _scale.value,
              filterQuality: FilterQuality.medium,
              child: child,
            );
          },
          child: shell,
        ),
      );
    }

    return shell;
  }
}

/// [SolidCapsuleActionBar] 내부 텍스트 버튼.
class SolidCapsuleTextActionButton extends StatelessWidget {
  const SolidCapsuleTextActionButton({
    super.key,
    this.tooltip,
    required this.label,
    this.onPressed,
    this.selected = false,
    this.horizontalPadding = 12,
  });

  final String? tooltip;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final fg = SolidCapsuleActionBarTokens.iconColor(
      brightness,
      selected: selected,
    );

    final button = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 10,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ),
      ),
    );

    if (tooltip == null || tooltip!.isEmpty) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// [SolidCapsuleActionBar] 내부 아이콘 버튼.
///
/// Ink 호버/스플래시 없음. 단일 아이콘 캡슐이면 셸 전체가 바운스하고,
/// 여러 아이콘이 묶인 경우에는 아이콘만 바운스한다.
class SolidCapsuleActionButton extends StatefulWidget {
  const SolidCapsuleActionButton({
    super.key,
    this.tooltip,
    required this.icon,
    this.onPressed,
    this.selected = false,
    this.accentWhenSelected = false,
    this.iconSize = 25,
    this.hitSize = 40,
  });

  final String? tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;
  final bool accentWhenSelected;
  final double iconSize;
  final double hitSize;

  @override
  State<SolidCapsuleActionButton> createState() =>
      _SolidCapsuleActionButtonState();
}

class _SolidCapsuleActionButtonState extends State<SolidCapsuleActionButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bounce;
  late final Animation<double> _scale;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _bounce = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
    _scale = _solidCapsuleBounceScale(_bounce);
  }

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  Future<void> _handleTap() async {
    if (widget.onPressed == null || _busy) return;
    _busy = true;
    try {
      final shell = _SolidCapsuleBounceScope.maybeOf(context);
      if (shell != null) {
        shell.playBounce();
      } else {
        _bounce
          ..stop()
          ..value = 0
          ..forward();
      }
      // 확대 피크까지 기다린 뒤 액션 — 바로 pop 되어도 피드백이 보인다.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (!mounted) return;
      widget.onPressed!();
    } finally {
      if (mounted) _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final fg = SolidCapsuleActionBarTokens.iconColor(
      brightness,
      selected: widget.selected,
      accentWhenSelected: widget.accentWhenSelected,
    );
    final enabled = widget.onPressed != null;
    final shellScales = _SolidCapsuleBounceScope.maybeOf(context) != null;

    Widget icon = SizedBox(
      width: widget.hitSize,
      height: widget.hitSize,
      child: Icon(
        widget.icon,
        size: widget.iconSize,
        color: enabled ? fg : fg.withValues(alpha: 0.35),
      ),
    );

    // 셸이 전체를 키울 때는 아이콘만 따로 키우지 않는다.
    if (!shellScales) {
      icon = AnimatedBuilder(
        animation: _scale,
        builder: (context, child) {
          return Transform.scale(
            scale: _scale.value,
            filterQuality: FilterQuality.medium,
            child: child,
          );
        },
        child: icon,
      );
    }

    final button = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? _handleTap : null,
      child: icon,
    );

    final tip = widget.tooltip;
    if (tip == null || tip.isEmpty) return button;
    return Tooltip(message: tip, child: button);
  }
}
