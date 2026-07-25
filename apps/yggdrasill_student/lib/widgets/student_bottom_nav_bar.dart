import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

/// 학습앱 `FabStyleTabBar` 글래스 토큰을 학생앱 하단 네비에 맞춘 값.
abstract final class StudentBottomNavTokens {
  static const double height = 64;
  static const double nowPlayingHeight = 64;
  static const double nowPlayingGap = 10;
  static const double bottomInset = 20;
  static const double horizontalInset = 24;
  static const double padding = 6;
  static const double tabWidth = 72;
  static const double iconSize = 30;
  static const double searchGap = 10;
  static const Duration searchAnimDuration = Duration(milliseconds: 280);

  /// 검색/탭 펼침·축소 공통 — 약한 오버슈트(바운스).
  static const Curve searchBounceCurve = Cubic(0.22, 1.28, 0.36, 1.0);

  /// 스크롤 1줄 모드에서 탭/검색/미니바 공통 축소 비율 (−10%).
  static const double compactScale = 0.90;
  static const Duration chromeAnimDuration = Duration(milliseconds: 420);
  static const double blurDark = 28;
  static const double blurLight = 10;

  /// 1줄 모드 미니바 최대 너비 (화면 전체 사용 방지).
  static const double nowPlayingCompactMaxWidth = 300;

  /// lightShadows(blur 4 + offset y 2)가 잘리지 않도록 확보할 여백.
  static const double shadowExtent = 6;

  static const Color darkSurface = Color(0x80212121);
  static const Color darkHighlight = Color(0x9A383838);
  static const Color darkSelected = Color(0xFFF4F5F5);
  static const Color darkUnselected = Color(0xFF9AA0A0);

  static const Color lightSurface = Color(0x80FFFFFF);
  static const Color lightHighlight = Color(0xB8CFCFCF);
  static const Color lightSelected = Color(0xFF000000);
  static const Color lightUnselected = Color(0xFF6B6B6B);

  static const List<BoxShadow> lightShadows = [
    BoxShadow(
      color: Color(0x24000000),
      blurRadius: 4,
      offset: Offset(0, 2),
    ),
  ];

  /// 본문이 바에 가리지 않도록 확보할 하단 여백.
  /// [compactChrome]이면 탭·미니바·검색이 한 줄이라 nowPlaying 높이를 더하지 않는다.
  static double contentBottomPadding(
    BuildContext context, {
    bool includeNowPlaying = false,
    bool compactChrome = false,
  }) {
    final barH = compactChrome ? height * compactScale : height;
    final nowPlaying = (!compactChrome && includeNowPlaying)
        ? nowPlayingHeight + nowPlayingGap
        : 0.0;
    return barH +
        nowPlaying +
        bottomInset +
        MediaQuery.paddingOf(context).bottom;
  }

  static double blurFor(Brightness brightness) =>
      brightness == Brightness.light ? blurLight : blurDark;
}

/// 글래스 가장자리 하이라이트.
///
/// 균일한 흰 테두리는 유리 표면과 분리된 외곽선처럼 도드라져 보이므로,
/// 위쪽만 살짝 밝고 아래로 갈수록 사라지는 그라데이션 헤어라인으로
/// "빛을 받는 유리 윗면" 느낌만 남긴다. (pill 형태 전제: radius = height/2)
class GlassRimPainter extends CustomPainter {
  const GlassRimPainter({required this.isDark});

  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(0.25),
      Radius.circular(size.height / 2),
    );
    final topAlpha = isDark ? 0.14 : 0.30;
    final bottomAlpha = isDark ? 0.02 : 0.04;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: topAlpha),
          Colors.white.withValues(alpha: bottomAlpha),
        ],
      ).createShader(rect);
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant GlassRimPainter oldDelegate) =>
      oldDelegate.isDark != isDark;
}

class _StudentNavDestination {
  const _StudentNavDestination({
    required this.label,
    this.icon,
    this.selectedIcon,
    this.customIconBuilder,
  });

  final String label;
  final IconData? icon;
  final IconData? selectedIcon;
  final Widget Function(Color color, bool selected, double size)?
      customIconBuilder;
}

/// 하단 플로팅 글래스 네비게이션 바.
/// [collapsed]이면 원형으로 줄어 현재 탭 아이콘만 보여 준다.
class StudentBottomNavBar extends StatefulWidget {
  const StudentBottomNavBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.collapsed = false,
    this.onCollapsedTap,
    this.scale = 1,
    this.animateSize = true,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final bool collapsed;
  final VoidCallback? onCollapsedTap;
  final double scale;

  /// false면 부모가 크기를 직접 애니메이트할 때 내부 AnimatedContainer를 끈다.
  final bool animateSize;

  static final destinations = <_StudentNavDestination>[
    _StudentNavDestination(
      label: '과제',
      customIconBuilder: (color, selected, size) => _AppsGridIcon(
        color: color,
        filled: selected,
        size: size * 0.95,
      ),
    ),
    _StudentNavDestination(
      label: '교재 풀기',
      customIconBuilder: (color, selected, size) => _TextbookStackIcon(
        color: color,
        filled: selected,
        size: size,
      ),
    ),
    _StudentNavDestination(
      label: '내 정보',
      customIconBuilder: (color, selected, size) => _ProfilePersonIcon(
        color: color,
        filled: selected,
        size: size * 0.95,
      ),
    ),
  ];

  Widget _iconFor(
    _StudentNavDestination destination, {
    required Color color,
    required bool selected,
    required double iconSize,
  }) {
    final custom = destination.customIconBuilder;
    if (custom != null) return custom(color, selected, iconSize);
    return Icon(
      selected ? destination.selectedIcon! : destination.icon!,
      size: iconSize,
      color: color,
    );
  }

  @override
  State<StudentBottomNavBar> createState() => _StudentBottomNavBarState();
}

class _StudentBottomNavBarState extends State<StudentBottomNavBar> {
  /// 터치 중인 탭 (하이라이트가 먼저 따라가고 살짝 커진다).
  int? _pressedIndex;

  void _setPressed(int? index) {
    if (_pressedIndex == index) return;
    setState(() => _pressedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final destinations = StudentBottomNavBar.destinations;
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final surface = isDark
        ? StudentBottomNavTokens.darkSurface
        : StudentBottomNavTokens.lightSurface;
    final highlight = isDark
        ? StudentBottomNavTokens.darkHighlight
        : StudentBottomNavTokens.lightHighlight;
    final selectedColor = isDark
        ? StudentBottomNavTokens.darkSelected
        : StudentBottomNavTokens.lightSelected;
    final unselectedColor = isDark
        ? StudentBottomNavTokens.darkUnselected
        : StudentBottomNavTokens.lightUnselected;
    final blur = StudentBottomNavTokens.blurFor(brightness);
    final s = widget.scale.clamp(0.5, 1.5);
    final height = StudentBottomNavTokens.height * s;
    final padding = StudentBottomNavTokens.padding * s;
    final tabWidth = StudentBottomNavTokens.tabWidth * s;
    final iconSize = StudentBottomNavTokens.iconSize * s;
    final radius = height / 2;
    final innerHeight = height - padding * 2;
    final safeIndex =
        widget.selectedIndex.clamp(0, destinations.length - 1).toInt();
    final expandedWidth = tabWidth * destinations.length;
    final width = widget.collapsed ? height : expandedWidth;
    final current = destinations[safeIndex];
    final duration = widget.animateSize
        ? StudentBottomNavTokens.searchAnimDuration
        : Duration.zero;
    final pressed = _pressedIndex;
    // 터치 다운 즉시 하이라이트가 눌린 탭으로 이동 (UITabBar 감각).
    final pillIndex = pressed ?? safeIndex;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: isDark ? null : StudentBottomNavTokens.lightShadows,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: CustomPaint(
            foregroundPainter: GlassRimPainter(isDark: isDark),
            child: AnimatedContainer(
              duration: duration,
              curve: StudentBottomNavTokens.searchBounceCurve,
              width: width,
              height: height,
              padding: EdgeInsets.all(padding),
              decoration: BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.circular(radius),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final availableWidth = constraints.maxWidth;
                  final slotWidth = destinations.isEmpty
                      ? availableWidth
                      : availableWidth / destinations.length;
                  return Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      AnimatedOpacity(
                        opacity: widget.collapsed ? 1 : 0,
                        duration: duration,
                        curve: Curves.easeInOutCubic,
                        child: IgnorePointer(
                          ignoring: !widget.collapsed,
                          child: Tooltip(
                            message: current.label,
                            child: GestureDetector(
                              onTap: widget.onCollapsedTap,
                              behavior: HitTestBehavior.opaque,
                              child: SizedBox(
                                width: innerHeight,
                                height: innerHeight,
                                child: Center(
                                  child: widget._iconFor(
                                    current,
                                    color: selectedColor,
                                    selected: true,
                                    iconSize: iconSize,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      AnimatedOpacity(
                        opacity: widget.collapsed ? 0 : 1,
                        duration: duration,
                        curve: Curves.easeInOutCubic,
                        child: IgnorePointer(
                          ignoring: widget.collapsed,
                          child: SizedBox(
                            width: availableWidth,
                            height: innerHeight,
                            child: Stack(
                              // 프레스 확대가 잘리지 않게 (바깥은 ClipRRect가 마감).
                              clipBehavior: Clip.none,
                              children: [
                                AnimatedPositioned(
                                  duration: const Duration(milliseconds: 260),
                                  curve: Curves.easeOutCubic,
                                  left: slotWidth * pillIndex,
                                  top: 0,
                                  bottom: 0,
                                  width: slotWidth,
                                  child: AnimatedScale(
                                    scale: pressed != null ? 1.07 : 1.0,
                                    duration: pressed != null
                                        ? const Duration(milliseconds: 120)
                                        : const Duration(milliseconds: 280),
                                    curve: pressed != null
                                        ? Curves.easeOutCubic
                                        : Curves.easeOutBack,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: highlight,
                                        borderRadius: BorderRadius.circular(
                                          innerHeight / 2,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Row(
                                  children: [
                                    for (var i = 0;
                                        i < destinations.length;
                                        i++)
                                      _NavTab(
                                        width: slotWidth,
                                        destination: destinations[i],
                                        selected: i == safeIndex,
                                        selectedColor: selectedColor,
                                        unselectedColor: unselectedColor,
                                        onPressed: () => _setPressed(i),
                                        onReleased: () {
                                          _setPressed(null);
                                          widget.onDestinationSelected(i);
                                        },
                                        onCanceled: () => _setPressed(null),
                                        iconSize: iconSize,
                                        iconBuilder: widget._iconFor,
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 원형 검색 버튼 → 펼치면 와이드 검색 캡슐 (마이크 아이콘 포함, 기능 없음).
class StudentBottomNavSearchButton extends StatefulWidget {
  const StudentBottomNavSearchButton({
    super.key,
    required this.expanded,
    required this.onExpandedChanged,
    this.scale = 1,
    this.animateSize = true,
  });

  final bool expanded;
  final ValueChanged<bool> onExpandedChanged;
  final double scale;
  final bool animateSize;

  @override
  State<StudentBottomNavSearchButton> createState() =>
      _StudentBottomNavSearchButtonState();
}

class _StudentBottomNavSearchButtonState
    extends State<StudentBottomNavSearchButton> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void didUpdateWidget(covariant StudentBottomNavSearchButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded && !oldWidget.expanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
    if (!widget.expanded && oldWidget.expanded) {
      _controller.clear();
      _focusNode.unfocus();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _expand() => widget.onExpandedChanged(true);

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final surface = isDark
        ? StudentBottomNavTokens.darkSurface
        : StudentBottomNavTokens.lightSurface;
    final selectedColor = isDark
        ? StudentBottomNavTokens.darkSelected
        : StudentBottomNavTokens.lightSelected;
    final unselectedColor = isDark
        ? StudentBottomNavTokens.darkUnselected
        : StudentBottomNavTokens.lightUnselected;
    final blur = StudentBottomNavTokens.blurFor(brightness);
    final s = widget.scale.clamp(0.5, 1.5);
    final height = StudentBottomNavTokens.height * s;
    final padding = StudentBottomNavTokens.padding * s;
    final iconSize = StudentBottomNavTokens.iconSize * s;
    final innerHeight = height - padding * 2;
    final radius = BorderRadius.circular(height / 2);
    final expanded = widget.expanded;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final expandedWidth = (screenWidth / 3).clamp(160.0, 280.0);
    final duration = widget.animateSize
        ? StudentBottomNavTokens.searchAnimDuration
        : Duration.zero;

    // 펼침만 트윈으로 애니메이트하고 scale 기반 치수는 즉시 반영한다.
    // (AnimatedContainer로 함께 묶으면 스크롤 축소 중 움직이는 목표값을
    //  뒤쫓아 탭바와 축소 타이밍이 어긋난다.)
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: expanded ? 1.0 : 0.0),
      duration: duration,
      curve: StudentBottomNavTokens.searchBounceCurve,
      builder: (context, e, _) {
        // 바운스 커브는 e∉[0,1] 가능 — 페이드는 클램프, 너비는 살짝 오버/언더슈트.
        final fade = e.clamp(0.0, 1.0);
        final widthT = e.clamp(-0.12, 1.15);
        final width = lerpDouble(height, expandedWidth, widthT)!
            .clamp(height * 0.92, expandedWidth * 1.12);
        final hPad = lerpDouble(padding, 14 * s, fade)!;
        final innerW = math.max(0.0, width - hPad * 2);
        return DecoratedBox(
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
                  width: width,
                  height: height,
                  padding: EdgeInsets.symmetric(
                    horizontal: hPad,
                    vertical: padding,
                  ),
                  decoration: BoxDecoration(
                    color: surface,
                    borderRadius: radius,
                  ),
                  child: ClipRect(
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.hardEdge,
                      children: [
                        Opacity(
                          opacity: 1 - fade,
                          child: IgnorePointer(
                            ignoring: expanded,
                            child: Tooltip(
                              message: '검색',
                              child: GestureDetector(
                                onTap: _expand,
                                behavior: HitTestBehavior.opaque,
                                child: SizedBox(
                                  width: innerHeight,
                                  height: innerHeight,
                                  child: Icon(
                                    Icons.search_rounded,
                                    size: iconSize,
                                    color: unselectedColor,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Opacity(
                          opacity: fade,
                          child: IgnorePointer(
                            ignoring: !expanded,
                            child: SizedBox(
                              width: innerW,
                              height: innerHeight,
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.search_rounded,
                                    size: 22 * s,
                                    color: selectedColor,
                                  ),
                                  SizedBox(width: 10 * s),
                                  Expanded(
                                    child: TextField(
                                      controller: _controller,
                                      focusNode: _focusNode,
                                      onChanged: (_) {},
                                      style: TextStyle(
                                        color: selectedColor,
                                        fontSize: 16 * s,
                                        fontWeight: FontWeight.w500,
                                      ),
                                      cursorColor: selectedColor,
                                      decoration: InputDecoration(
                                        isCollapsed: true,
                                        isDense: true,
                                        filled: false,
                                        fillColor: Colors.transparent,
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        disabledBorder: InputBorder.none,
                                        errorBorder: InputBorder.none,
                                        focusedErrorBorder: InputBorder.none,
                                        contentPadding: EdgeInsets.zero,
                                        hintText: '검색어를 입력하세요.',
                                        hintStyle: TextStyle(
                                          color: selectedColor.withValues(
                                            alpha: 0.45,
                                          ),
                                          fontSize: 15 * s,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(width: 4 * s),
                                  GestureDetector(
                                    onTap: () {},
                                    behavior: HitTestBehavior.opaque,
                                    child: SizedBox(
                                      width: 32 * s,
                                      height: innerHeight,
                                      child: Icon(
                                        Icons.mic_none_rounded,
                                        size: 22 * s,
                                        color: selectedColor,
                                      ),
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
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _NavTab extends StatelessWidget {
  const _NavTab({
    required this.width,
    required this.destination,
    required this.selected,
    required this.selectedColor,
    required this.unselectedColor,
    required this.onPressed,
    required this.onReleased,
    required this.onCanceled,
    required this.iconSize,
    required this.iconBuilder,
  });

  final double width;
  final _StudentNavDestination destination;
  final bool selected;
  final Color selectedColor;
  final Color unselectedColor;
  final VoidCallback onPressed;
  final VoidCallback onReleased;
  final VoidCallback onCanceled;
  final double iconSize;
  final Widget Function(
    _StudentNavDestination destination, {
    required Color color,
    required bool selected,
    required double iconSize,
  }) iconBuilder;

  @override
  Widget build(BuildContext context) {
    final color = selected ? selectedColor : unselectedColor;
    return Tooltip(
      message: destination.label,
      child: GestureDetector(
        onTapDown: (_) => onPressed(),
        onTapUp: (_) => onReleased(),
        onTapCancel: onCanceled,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: width,
          child: Center(
            child: iconBuilder(
              destination,
              color: color,
              selected: selected,
              iconSize: iconSize,
            ),
          ),
        ),
      ),
    );
  }
}

/// 사람(머리 원 + 활꼴 어깨) — 선택 filled, 미선택은 외곽만.
class _ProfilePersonIcon extends StatelessWidget {
  const _ProfilePersonIcon({
    required this.color,
    required this.filled,
    required this.size,
  });

  final Color color;
  final bool filled;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _ProfilePersonIconPainter(color: color, filled: filled),
      ),
    );
  }
}

class _ProfilePersonIconPainter extends CustomPainter {
  const _ProfilePersonIconPainter({
    required this.color,
    required this.filled,
  });

  final Color color;
  final bool filled;

  /// 스크린샷: 윗변 활꼴(반타원) + 하단 닫힌 직선.
  Path _bodyPath({
    required double cx,
    required double top,
    required double bottom,
    required double halfW,
  }) {
    final h = bottom - top;
    final corner = math.min(halfW * 0.35, h * 0.35);
    return Path()
      ..moveTo(cx - halfW + corner, bottom)
      ..lineTo(cx + halfW - corner, bottom)
      ..quadraticBezierTo(cx + halfW, bottom, cx + halfW, bottom - corner)
      ..cubicTo(
        cx + halfW,
        top + h * 0.28,
        cx + halfW * 0.55,
        top,
        cx,
        top,
      )
      ..cubicTo(
        cx - halfW * 0.55,
        top,
        cx - halfW,
        top + h * 0.28,
        cx - halfW,
        bottom - corner,
      )
      ..quadraticBezierTo(cx - halfW, bottom, cx - halfW + corner, bottom)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.shortestSide;
    final cx = cell / 2;
    final stroke = cell * 0.085;

    // 머리 ≈ 몸통 폭의 절반, 몸통은 납작한 닫힌 활꼴.
    final headR = cell * 0.22;
    final headCy = cell * 0.28;
    final gap = stroke * 1.15;
    final halfW = headR * 2.0;
    final bodyH = headR * 1.55;
    final bodyTop = headCy + headR + gap;
    final bodyBottom = bodyTop + bodyH;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final body = _bodyPath(
      cx: cx,
      top: bodyTop,
      bottom: bodyBottom,
      halfW: halfW,
    );

    if (filled) {
      canvas.drawCircle(Offset(cx, headCy), headR, paint);
      canvas.drawPath(body, paint);
      return;
    }

    final headOuter = Path()
      ..addOval(Rect.fromCircle(center: Offset(cx, headCy), radius: headR));
    final headInner = Path()
      ..addOval(
        Rect.fromCircle(
          center: Offset(cx, headCy),
          radius: math.max(0.0, headR - stroke),
        ),
      );
    canvas.drawPath(
      Path.combine(PathOperation.difference, headOuter, headInner),
      paint,
    );

    // 닫힌 경로를 스트로크로 — 상단 활·하단 직선 두께 동일.
    canvas.drawPath(
      body,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _ProfilePersonIconPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.filled != filled;
  }
}

/// 교재 스택(카드+위 레이어 2줄) — 선택 filled, 미선택은 외곽 스트로크.
class _TextbookStackIcon extends StatelessWidget {
  const _TextbookStackIcon({
    required this.color,
    required this.filled,
    required this.size,
  });

  final Color color;
  final bool filled;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _TextbookStackIconPainter(color: color, filled: filled),
      ),
    );
  }
}

class _TextbookStackIconPainter extends CustomPainter {
  const _TextbookStackIconPainter({
    required this.color,
    required this.filled,
  });

  final Color color;
  final bool filled;

  /// 동일한 라운드 정사각의 윗부분만 잘라, 뒤에 같은 사각형이 쌓인 것처럼 보이게 한다.
  Path _topSlice({
    required double left,
    required double top,
    required double side,
    required double corner,
    required double sliceH,
  }) {
    final full = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, side, side),
      Radius.circular(corner),
    );
    final band = Rect.fromLTWH(left - 1, top - 1, side + 2, sliceH + 1);
    return Path.combine(
      PathOperation.intersect,
      Path()..addRRect(full),
      Path()..addRect(band),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.shortestSide;
    // 스크린샷 비율: 앞 정사각이 주인공, 뒤는 얇은 윗변만 (전체 높이 과다 방지).
    final bodySide = cell * 0.72;
    final corner = bodySide * 0.20;
    final bodyLeft = (cell - bodySide) / 2;
    final bodyBottom = cell * 0.03;
    final bodyTop = cell - bodyBottom - bodySide;

    // 레이어 두께 ≈ 본체 높이의 ~9% — 두꺼운 슬라이스가 되지 않게.
    final sliceH = bodySide * 0.09;
    final gap = bodySide * 0.055;

    // 뒤로 갈수록 조금 좁아짐. 윗변 코너 반경은 앞과 동일.
    final back1Side = bodySide * 0.88;
    final back2Side = bodySide * 0.74;
    final back1Left = (cell - back1Side) / 2;
    final back2Left = (cell - back2Side) / 2;
    final back1Top = bodyTop - gap - sliceH;
    final back2Top = back1Top - gap - sliceH;

    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(bodyLeft, bodyTop, bodySide, bodySide),
      Radius.circular(corner),
    );
    final layer1 = _topSlice(
      left: back1Left,
      top: back1Top,
      side: back1Side,
      corner: corner,
      sliceH: sliceH,
    );
    final layer2 = _topSlice(
      left: back2Left,
      top: back2Top,
      side: back2Side,
      corner: corner,
      sliceH: sliceH,
    );

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    if (filled) {
      canvas.drawPath(layer2, paint);
      canvas.drawPath(layer1, paint);
      canvas.drawRRect(body, paint);
      return;
    }

    final inset = cell * 0.085;

    void drawRRectRing(RRect outer, double ring) {
      final inner = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          outer.left + ring,
          outer.top + ring,
          math.max(0.0, outer.width - ring * 2),
          math.max(0.0, outer.height - ring * 2),
        ),
        Radius.circular(math.max(0.0, outer.blRadiusX - ring)),
      );
      canvas.drawPath(
        Path.combine(
          PathOperation.difference,
          Path()..addRRect(outer),
          Path()..addRRect(inner),
        ),
        paint,
      );
    }

    void drawSliceRing({
      required double left,
      required double top,
      required double side,
      required double c,
      required double slice,
    }) {
      final outer = _topSlice(
        left: left,
        top: top,
        side: side,
        corner: c,
        sliceH: slice,
      );
      final inner = _topSlice(
        left: left + inset,
        top: top + inset,
        side: math.max(0.0, side - inset * 2),
        corner: math.max(0.0, c - inset),
        sliceH: math.max(inset, slice - inset),
      );
      canvas.drawPath(
        Path.combine(PathOperation.difference, outer, inner),
        paint,
      );
    }

    drawRRectRing(body, inset);
    drawSliceRing(
      left: back1Left,
      top: back1Top,
      side: back1Side,
      c: corner,
      slice: sliceH,
    );
    drawSliceRing(
      left: back2Left,
      top: back2Top,
      side: back2Side,
      c: corner,
      slice: sliceH,
    );
  }

  @override
  bool shouldRepaint(covariant _TextbookStackIconPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.filled != filled;
  }
}

/// 2×2 둥근 네모 그리드 — 선택 filled, 미선택은 동일 외곽에서 안쪽만 비움.
class _AppsGridIcon extends StatelessWidget {
  const _AppsGridIcon({
    required this.color,
    required this.filled,
    required this.size,
  });

  final Color color;
  final bool filled;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _AppsGridIconPainter(color: color, filled: filled),
      ),
    );
  }
}

class _AppsGridIconPainter extends CustomPainter {
  const _AppsGridIconPainter({
    required this.color,
    required this.filled,
  });

  final Color color;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.shortestSide;
    final gap = cell * 0.055;
    final corner = cell * 0.12;
    final tile = (cell - gap) / 2;
    final ring = cell * 0.09;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    for (var row = 0; row < 2; row++) {
      for (var col = 0; col < 2; col++) {
        final left = col * (tile + gap);
        final top = row * (tile + gap);
        final outer = RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, tile, tile),
          Radius.circular(corner),
        );
        if (filled) {
          canvas.drawRRect(outer, paint);
          continue;
        }
        final innerSize = math.max(0.0, tile - ring * 2);
        final innerCorner = math.max(0.0, corner - ring);
        final inner = RRect.fromRectAndRadius(
          Rect.fromLTWH(left + ring, top + ring, innerSize, innerSize),
          Radius.circular(innerCorner),
        );
        final ringPath = Path.combine(
          PathOperation.difference,
          Path()..addRRect(outer),
          Path()..addRRect(inner),
        );
        canvas.drawPath(ringPath, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _AppsGridIconPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.filled != filled;
  }
}
