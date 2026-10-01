import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'app_bar_title.dart'; // for AccountButton
import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../theme/ygg_semantic_colors.dart';

const double _navIconSize = 35.2;
/// 하단 계정 버튼 반지름. 지름이 네비 아이콘 캔버스와 같다.
const double _navAccountButtonRadius = _navIconSize / 2;
/// 하단 탭 아이콘 선 두께. 홈·학생과 아래 아이콘이 같은 굵기를 쓴다.
const double _navIconStrokeWidthUnselected = 2.0;
const double _navDestinationVerticalPadding = 18.0;
const double _navHighlightWidth = 67.8;
const double _navHighlightHeight = 40.7;
/// Material [NavigationRail] 기본 폭 — 오버레이·고정 배치 계산용.
const double navRailMinWidth = 84.0;

/// Material [NavigationRail] leading 위 고정 [SizedBox] (소스 `_verticalSpacer`).
const double navRailTopSpacer = 8.0;

/// 사이드시트 날짜 헤더와 수평 정렬 — leading [IconButton] 상단 inset.
const double navLeadingPaddingTop = 7.7;

/// leading 슬라이드시트 [IconButton] 탭 영역 (Material 기본 48).
const double navLeadingIconTapSize = 48.0;

/// 네비 패키지 버튼 행 **중심선** — Scaffold body 상단부터의 Y.
const double navPackageButtonRowCenterY = navRailTopSpacer +
    navLeadingPaddingTop +
    navLeadingIconTapSize / 2;

/// 사이드시트 날짜 헤더 행 상단 inset (행 중심 = [navPackageButtonRowCenterY]).
const double navSideSheetDateHeaderTopInset =
    navPackageButtonRowCenterY - navLeadingIconTapSize / 2;

const double _navLeadingPaddingBottom = 9.9;
const double _navDividerTopSpacing = 14.5;
const double _navDividerWidth = 38.7;
const Color _navIconColorDark = Color(0xFFEAF2F2);
const Color _navIconColorLight = Color(0xFF1F2933);
const Color _navIconColorLightSelected = Color(0xFF060B12);
const Color _navIconColorDarkSelected = Color(0xFFFFFFFF);

enum _NavIconKind {
  package,
  home,
  student,
  time,
  learning,
  resources,
  settings,
}

class CustomNavigationRail extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final Animation<double> rotationAnimation;
  final VoidCallback onMenuPressed;

  const CustomNavigationRail({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.rotationAnimation,
    required this.onMenuPressed,
  });

  Widget _navIcon(
    _NavIconKind kind, {
    double size = _navIconSize,
    required Color color,
    double strokeWidth = _navIconStrokeWidthUnselected,
    bool filled = false,
  }) {
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _NavIconPainter(
            kind: kind,
            color: color,
            strokeWidth: strokeWidth,
            filled: filled,
          ),
        ),
      ),
    );
  }

  Widget _navIconSlot({
    required _NavIconKind kind,
    required Color color,
    required Color highlightColor,
    required bool selected,
    required Brightness brightness,
  }) {
    final filled = selected &&
        (kind == _NavIconKind.home ||
            kind == _NavIconKind.learning ||
            kind == _NavIconKind.settings ||
            kind == _NavIconKind.resources ||
            kind == _NavIconKind.time ||
            kind == _NavIconKind.student);
    final strokeWidth = _navIconStrokeWidthUnselected;
    final resolvedColor = selected
        ? (brightness == Brightness.light
            ? _navIconColorLightSelected
            : _navIconColorDarkSelected)
        : color;
    final icon = Center(
      child: _navIcon(
        kind,
        color: resolvedColor,
        strokeWidth: strokeWidth,
        filled: filled,
      ),
    );

    return SizedBox(
      width: _navHighlightWidth,
      height: _navHighlightHeight,
      child: selected
          ? DecoratedBox(
              decoration: BoxDecoration(
                color: highlightColor,
                borderRadius: BorderRadius.circular(_navHighlightHeight / 2),
              ),
              child: icon,
            )
          : icon,
    );
  }

  Widget _railDestination({
    required int index,
    required String tooltip,
    required _NavIconKind kind,
    required Color navIconColor,
    required Color highlightColor,
    required Brightness brightness,
  }) {
    final selected = selectedIndex == index;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onDestinationSelected(index),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: _navDestinationVerticalPadding,
            ),
            child: Center(
              child: _navIconSlot(
                kind: kind,
                color: navIconColor,
                highlightColor: highlightColor,
                selected: selected,
                brightness: brightness,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final navBackground = context.yggSurfaceBase;
    final brightness = Theme.of(context).brightness;
    final bool isDark = brightness == Brightness.dark;
    final Color navIconColor =
        isDark ? _navIconColorDark : _navIconColorLight;
    final palette = FabTabBarTokens.paletteFor(Theme.of(context).brightness);
    final Color highlightColor = palette.highlight;
    final Color dividerColor =
        isDark ? Colors.white24 : Colors.black26;
    final double railWidth =
        NavigationRailTheme.of(context).minWidth ?? navRailMinWidth;
    return Column(
      children: [
        Expanded(
          child: ColoredBox(
            color: navBackground,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    top: navRailTopSpacer + navLeadingPaddingTop,
                    bottom: _navLeadingPaddingBottom,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: onMenuPressed,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: SizedBox(
                            width: navLeadingIconTapSize,
                            height: navLeadingIconTapSize,
                            child: Center(
                              child: AnimatedBuilder(
                                animation: rotationAnimation,
                                builder: (context, child) {
                                  return Transform.rotate(
                                    angle: rotationAnimation.value *
                                        (math.pi / 2),
                                    child: _navIcon(
                                      _NavIconKind.package,
                                      color: navIconColor,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: _navDividerTopSpacing),
                      Container(
                        width: _navDividerWidth,
                        height: 1,
                        color: dividerColor,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    children: [
                      _railDestination(
                        index: 0,
                        tooltip: '홈',
                        kind: _NavIconKind.home,
                        navIconColor: navIconColor,
                        highlightColor: highlightColor,
                        brightness: brightness,
                      ),
                      _railDestination(
                        index: 1,
                        tooltip: '학생',
                        kind: _NavIconKind.student,
                        navIconColor: navIconColor,
                        highlightColor: highlightColor,
                        brightness: brightness,
                      ),
                      _railDestination(
                        index: 2,
                        tooltip: '시간',
                        kind: _NavIconKind.time,
                        navIconColor: navIconColor,
                        highlightColor: highlightColor,
                        brightness: brightness,
                      ),
                      _railDestination(
                        index: 3,
                        tooltip: '학습',
                        kind: _NavIconKind.learning,
                        navIconColor: navIconColor,
                        highlightColor: highlightColor,
                        brightness: brightness,
                      ),
                      _railDestination(
                        index: 4,
                        tooltip: '자료',
                        kind: _NavIconKind.resources,
                        navIconColor: navIconColor,
                        highlightColor: highlightColor,
                        brightness: brightness,
                      ),
                      _railDestination(
                        index: 5,
                        tooltip: '설정',
                        kind: _NavIconKind.settings,
                        navIconColor: navIconColor,
                        highlightColor: highlightColor,
                        brightness: brightness,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(
          width: railWidth,
          child: ColoredBox(
            color: navBackground,
            child: Align(
              alignment: Alignment.center,
              child: AccountButton(
                padding: EdgeInsets.only(
                  bottom: FabTabBarTokens.navRailAccountButtonBottomInset(
                    accountButtonRadius: _navAccountButtonRadius,
                  ),
                ),
                radius: _navAccountButtonRadius,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 학습·설정 아이콘 — 다른 탭 대비 시각적으로 작아 보여 10% 확대.
const double _navIconLearningSettingsScale = 1.1;

class _NavIconPainter extends CustomPainter {
  final _NavIconKind kind;
  final Color color;
  final double strokeWidth;
  final bool filled;

  const _NavIconPainter({
    required this.kind,
    required this.color,
    required this.strokeWidth,
    this.filled = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 24;
    Offset p(double x, double y) => Offset(x * s, y * s);
    double r(double logical) => logical * s;
    Offset ps(double x, double y, [double factor = _navIconLearningSettingsScale]) =>
        p(12 + (x - 12) * factor, 12 + (y - 12) * factor);

    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    switch (kind) {
      case _NavIconKind.package:
        _paintPackage(canvas, paint, p);
        break;
      case _NavIconKind.home:
        _paintHome(canvas, paint, fillPaint, p, filled: filled);
        break;
      case _NavIconKind.student:
        _paintStudent(canvas, paint, fillPaint, p, r, filled: filled);
        break;
      case _NavIconKind.time:
        _paintTime(canvas, paint, fillPaint, p, r, filled: filled);
        break;
      case _NavIconKind.learning:
        _paintLearning(canvas, paint, fillPaint, ps, r, filled: filled);
        break;
      case _NavIconKind.resources:
        _paintResources(canvas, paint, fillPaint, p, r, filled: filled);
        break;
      case _NavIconKind.settings:
        _paintSettings(canvas, paint, fillPaint, ps, r, filled: filled);
        break;
    }
  }

  void _paintPackage(
    Canvas canvas,
    Paint paint,
    Offset Function(double x, double y) p,
  ) {
    const factor = 1.3;
    Offset g(double x, double y) =>
        p(12 + (x - 12) * factor, 12 + (y - 12) * factor);
    final top = Path()
      ..moveTo(g(12, 3).dx, g(12, 3).dy)
      ..lineTo(g(20, 7.5).dx, g(20, 7.5).dy)
      ..lineTo(g(12, 12).dx, g(12, 12).dy)
      ..lineTo(g(4, 7.5).dx, g(4, 7.5).dy)
      ..close();
    final left = Path()
      ..moveTo(g(4, 7.5).dx, g(4, 7.5).dy)
      ..lineTo(g(12, 12).dx, g(12, 12).dy)
      ..lineTo(g(12, 21).dx, g(12, 21).dy)
      ..lineTo(g(4, 16.5).dx, g(4, 16.5).dy)
      ..close();
    final right = Path()
      ..moveTo(g(20, 7.5).dx, g(20, 7.5).dy)
      ..lineTo(g(12, 12).dx, g(12, 12).dy)
      ..lineTo(g(12, 21).dx, g(12, 21).dy)
      ..lineTo(g(20, 16.5).dx, g(20, 16.5).dy)
      ..close();
    canvas
      ..drawPath(top, paint)
      ..drawPath(left, paint)
      ..drawPath(right, paint);
  }

  void _paintHome(
    Canvas canvas,
    Paint paint,
    Paint fillPaint,
    Offset Function(double x, double y) p, {
    bool filled = false,
  }) {
    const factor = 1.3;
    Offset g(double x, double y) =>
        p(12 + (x - 12) * factor, 12 + (y - 12) * factor);
    final path = Path()
      ..moveTo(g(5, 11).dx, g(5, 11).dy)
      ..lineTo(g(12, 5).dx, g(12, 5).dy)
      ..lineTo(g(19, 11).dx, g(19, 11).dy)
      ..lineTo(g(19, 20).dx, g(19, 20).dy)
      ..lineTo(g(15, 20).dx, g(15, 20).dy)
      ..lineTo(g(15, 15).dx, g(15, 15).dy)
      ..lineTo(g(9, 15).dx, g(9, 15).dy)
      ..lineTo(g(9, 20).dx, g(9, 20).dy)
      ..lineTo(g(5, 20).dx, g(5, 20).dy)
      ..close();
    if (filled) {
      canvas.drawPath(path, fillPaint);
    }
    canvas.drawPath(path, paint);
  }

  void _paintStudent(
    Canvas canvas,
    Paint paint,
    Paint fillPaint,
    Offset Function(double x, double y) p,
    double Function(double logical) r, {
    bool filled = false,
  }) {
    const factor = 1.3;
    Offset g(double x, double y) =>
        p(12 + (x - 12) * factor, 12 + (y - 12) * factor);
    double gr(double logical) => r(logical * factor);
    final head = Path()
      ..addOval(Rect.fromCircle(center: g(12, 7.5), radius: gr(3.0)));
    if (filled) {
      canvas.drawPath(head, fillPaint);
    }
    canvas.drawPath(head, paint);
    final path = Path()
      ..moveTo(g(5, 20).dx, g(5, 20).dy)
      ..cubicTo(
        g(6.2, 15.8).dx,
        g(6.2, 15.8).dy,
        g(7.9, 14).dx,
        g(7.9, 14).dy,
        g(12, 14).dx,
        g(12, 14).dy,
      )
      ..cubicTo(
        g(16.1, 14).dx,
        g(16.1, 14).dy,
        g(17.8, 15.8).dx,
        g(17.8, 15.8).dy,
        g(19, 20).dx,
        g(19, 20).dy,
      );
    if (filled) {
      // 밑선은 그리지 않으므로, 채움만 어깨 끝보다 아래로 내려 하이라이트에서
      // 몸통 하단이 위로 말려 보이지 않게 한다.
      const bottom = 22.2;
      final body = Path.from(path)
        ..lineTo(g(19.6, bottom).dx, g(19.6, bottom).dy)
        ..lineTo(g(4.4, bottom).dx, g(4.4, bottom).dy)
        ..close();
      canvas.drawPath(body, fillPaint);
    }
    canvas.drawPath(path, paint);
  }

  void _paintTime(
    Canvas canvas,
    Paint paint,
    Paint fillPaint,
    Offset Function(double x, double y) p,
    double Function(double logical) r, {
    bool filled = false,
  }) {
    // Icons8 Clock. 평소 iOS Outlined(34), 선택 iOS Filled(10034).
    const outlineD =
        'M 25 2 C 12.309295 2 2 12.309295 2 25 C 2 37.690705 12.309295 48 25 48 C 37.690705 48 48 37.690705 48 25 C 48 12.309295 37.690705 2 25 2 z M 25 4 C 36.609824 4 46 13.390176 46 25 C 46 36.609824 36.609824 46 25 46 C 13.390176 46 4 36.609824 4 25 C 4 13.390176 13.390176 4 25 4 z M 24.984375 6.9863281 A 1.0001 1.0001 0 0 0 24 8 L 24 22.173828 A 3 3 0 0 0 22 25 A 3 3 0 0 0 22.294922 26.291016 L 16.292969 32.292969 A 1.0001 1.0001 0 1 0 17.707031 33.707031 L 23.708984 27.705078 A 3 3 0 0 0 25 28 A 3 3 0 0 0 28 25 A 3 3 0 0 0 26 22.175781 L 26 8 A 1.0001 1.0001 0 0 0 24.984375 6.9863281 z';
    const filledD =
        'M25,2C12.317,2,2,12.317,2,25s10.317,23,23,23s23-10.317,23-23S37.683,2,25,2z M25,28c-0.462,0-0.895-0.113-1.286-0.3 l-6.007,6.007C17.512,33.902,17.256,34,17,34s-0.512-0.098-0.707-0.293c-0.391-0.391-0.391-1.023,0-1.414l6.007-6.007 C22.113,25.895,22,25.462,22,25c0-1.304,0.837-2.403,2-2.816V8c0-0.553,0.447-1,1-1s1,0.447,1,1v14.184c1.163,0.413,2,1.512,2,2.816 C28,26.657,26.657,28,25,28z';
    Offset map(double x, double y) => p(x * 24 / 50, y * 24 / 50);
    final clock = _svgPath(filled ? filledD : outlineD, map, r(24 / 50))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      clock,
      Paint()
        ..color = filled ? fillPaint.color : paint.color
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
  }

  void _paintLearning(
    Canvas canvas,
    Paint paint,
    Paint fillPaint,
    Offset Function(double x, double y) ps,
    double Function(double logical) r, {
    bool filled = false,
  }) {
    // Icons8 Brain. 평소 iOS Outlined(2070), 선택 iOS Filled(2802).
    const outlineD =
        'M 21 0 C 14.988281 0 11.445313 3.277344 10.3125 6.15625 C 7.210938 6.734375 4.414063 8.8125 3 12.0625 C 1.546875 15.398438 1.609375 19.886719 3.90625 24.9375 C 2.605469 26.632813 1.851563 28.816406 2.21875 31.03125 C 2.578125 33.21875 4.09375 35.257813 6.71875 36.46875 C 5.65625 38.921875 6 41.316406 7.34375 43 C 8.738281 44.75 11.007813 45.710938 13.375 45.875 C 14.074219 47.707031 15.371094 48.921875 16.78125 49.4375 C 18.375 50.019531 19.996094 50 21 50 C 22.644531 50 24.089844 49.214844 25 48 C 25.910156 49.210938 27.359375 49.988281 29 50 C 30.117188 50.007813 31.738281 49.726563 33.3125 48.875 C 34.699219 48.125 35.933594 46.785156 36.625 44.9375 C 38.867188 44.859375 41.085938 44.390625 42.5625 42.96875 C 43.371094 42.1875 43.894531 41.109375 43.96875 39.84375 C 44.027344 38.84375 43.738281 37.710938 43.25 36.5 C 45.90625 35.296875 47.484375 33.265625 47.875 31.0625 C 48.269531 28.851563 47.472656 26.636719 46.09375 24.9375 C 48.390625 19.886719 48.453125 15.398438 47 12.0625 C 45.585938 8.8125 42.789063 6.734375 39.6875 6.15625 C 38.554688 3.277344 35.011719 0 29 0 C 27.515625 0 26.117188 0.382813 25.21875 1.53125 C 25.136719 1.636719 25.070313 1.761719 25 1.875 C 24.929688 1.761719 24.863281 1.636719 24.78125 1.53125 C 23.882813 0.382813 22.484375 0 21 0 Z M 21 2 C 22.203125 2 22.785156 2.199219 23.21875 2.75 C 23.652344 3.300781 24 4.496094 24 6.65625 L 24 45 C 24 46.824219 22.789063 48 21 48 C 20.003906 48 18.625 47.984375 17.46875 47.5625 C 16.3125 47.140625 15.386719 46.429688 14.96875 44.75 L 14.78125 44 L 14 44 C 11.972656 44 9.976563 43.089844 8.90625 41.75 C 7.835938 40.410156 7.515625 38.714844 8.84375 36.5 L 9.5 35.4375 L 8.3125 35.0625 C 5.601563 34.160156 4.484375 32.507813 4.1875 30.71875 C 3.898438 28.960938 4.523438 27.019531 5.65625 25.75 C 5.679688 25.730469 5.699219 25.710938 5.71875 25.6875 L 5.75 25.65625 C 5.75 25.65625 8.179688 23 11 23 C 14.5625 23 16.3125 24.71875 16.3125 24.71875 C 16.558594 25.011719 16.953125 25.136719 17.320313 25.042969 C 17.691406 24.949219 17.976563 24.648438 18.054688 24.277344 C 18.132813 23.902344 17.988281 23.515625 17.6875 23.28125 C 17.6875 23.28125 15.246094 21 11 21 C 8.503906 21 6.480469 22.300781 5.3125 23.28125 C 3.566406 19.003906 3.71875 15.457031 4.84375 12.875 C 6.078125 10.035156 8.480469 8.316406 11.09375 8 L 11.78125 7.90625 L 11.9375 7.28125 C 12.476563 5.398438 15.390625 2 21 2 Z M 29 2 C 34.609375 2 37.523438 5.398438 38.0625 7.28125 L 38.21875 7.90625 L 38.90625 8 C 41.519531 8.316406 43.921875 10.035156 45.15625 12.875 C 46.261719 15.414063 46.433594 18.878906 44.78125 23.0625 C 44.488281 23.199219 44.28125 23.464844 44.21875 23.78125 C 44.21875 23.78125 44.015625 24.710938 42.90625 25.78125 C 41.796875 26.851563 39.792969 28 36 28 C 35.640625 27.996094 35.304688 28.183594 35.121094 28.496094 C 34.941406 28.808594 34.941406 29.191406 35.121094 29.503906 C 35.304688 29.816406 35.640625 30.003906 36 30 C 40.207031 30 42.800781 28.648438 44.28125 27.21875 C 44.535156 26.976563 44.746094 26.742188 44.9375 26.5 C 45.765625 27.703125 46.164063 29.238281 45.90625 30.6875 C 45.589844 32.46875 44.402344 34.15625 41.6875 35.0625 L 40.59375 35.40625 L 41.09375 36.4375 C 41.789063 37.832031 42.015625 38.921875 41.96875 39.71875 C 41.921875 40.515625 41.644531 41.0625 41.15625 41.53125 C 40.199219 42.453125 38.246094 42.980469 36.125 43 C 34.84375 42.542969 33.847656 41.886719 33.15625 41 C 32.433594 40.070313 32 38.832031 32 37 C 32.007813 36.691406 31.871094 36.398438 31.632813 36.203125 C 31.398438 36.007813 31.082031 35.933594 30.78125 36 C 30.316406 36.105469 29.988281 36.523438 30 37 C 30 39.167969 30.566406 40.929688 31.59375 42.25 C 32.417969 43.308594 33.511719 44.03125 34.75 44.5625 C 34.234375 45.777344 33.347656 46.582031 32.34375 47.125 C 31.128906 47.78125 29.734375 48.003906 29 48 C 27.203125 47.988281 26 46.824219 26 45 L 26 6.65625 C 26 4.496094 26.347656 3.300781 26.78125 2.75 C 27.214844 2.199219 27.796875 2 29 2 Z M 18.90625 9.96875 C 18.863281 9.976563 18.820313 9.988281 18.78125 10 C 18.316406 10.105469 17.988281 10.523438 18 11 C 18 11.167969 17.828125 11.984375 17.15625 12.65625 C 16.484375 13.328125 15.300781 14 13 14 C 12.640625 13.996094 12.304688 14.183594 12.121094 14.496094 C 11.941406 14.808594 11.941406 15.191406 12.121094 15.503906 C 12.304688 15.816406 12.640625 16.003906 13 16 C 15.699219 16 17.519531 15.171875 18.59375 14.09375 C 19.667969 13.015625 20 11.832031 20 11 C 20.011719 10.710938 19.894531 10.433594 19.6875 10.238281 C 19.476563 10.039063 19.191406 9.941406 18.90625 9.96875 Z M 32.90625 11.96875 C 32.863281 11.976563 32.820313 11.988281 32.78125 12 C 32.316406 12.105469 31.988281 12.523438 32 13 C 32 14.332031 32.59375 16.03125 34.03125 17.46875 C 35.46875 18.90625 37.777344 20 41 20 C 41.359375 20.003906 41.695313 19.816406 41.878906 19.503906 C 42.058594 19.191406 42.058594 18.808594 41.878906 18.496094 C 41.695313 18.183594 41.359375 17.996094 41 18 C 38.222656 18 36.53125 17.09375 35.46875 16.03125 C 34.40625 14.96875 34 13.667969 34 13 C 34.011719 12.710938 33.894531 12.433594 33.6875 12.238281 C 33.476563 12.039063 33.191406 11.941406 32.90625 11.96875 Z M 10.75 30 C 10.199219 30.015625 9.765625 30.480469 9.78125 31.03125 C 9.796875 31.582031 10.261719 32.015625 10.8125 32 C 13.5 32.445313 14.65625 33.878906 15.3125 35.40625 C 15.96875 36.933594 16 38.5 16 39 C 15.996094 39.359375 16.183594 39.695313 16.496094 39.878906 C 16.808594 40.058594 17.191406 40.058594 17.503906 39.878906 C 17.816406 39.695313 18.003906 39.359375 18 39 C 18 38.503906 18 36.566406 17.15625 34.59375 C 16.3125 32.621094 14.480469 30.554688 11.15625 30 C 11.050781 29.984375 10.949219 29.984375 10.84375 30 C 10.8125 30 10.78125 30 10.75 30 Z';
    const filledD =
        'M 21 0 C 14.859375 0 11.351563 3.4375 10.25 6.09375 C 7.421875 6.640625 4.898438 8.519531 3.4375 11.1875 C 1.574219 14.597656 1.550781 18.863281 3.25 23.40625 C 4.886719 22.648438 7.035156 22 9.59375 22 C 14.339844 22 17.433594 24.097656 17.5625 24.1875 C 18.019531 24.5 18.125 25.109375 17.8125 25.5625 C 17.5 26.015625 16.894531 26.121094 16.4375 25.8125 C 16.410156 25.792969 13.691406 24 9.59375 24 C 6.929688 24 4.730469 24.847656 3.25 25.65625 C 2.1875 27.464844 1.832031 29.671875 2.34375 31.65625 C 2.894531 33.800781 4.378906 35.507813 6.59375 36.53125 C 5.746094 38.484375 5.8125 40.445313 6.78125 42.15625 C 7.996094 44.300781 10.484375 45.746094 13.25 45.96875 C 14.71875 50 19.078125 50 21 50 C 22.152344 50 23.175781 49.640625 24 49.03125 L 24 0.78125 C 23.242188 0.257813 22.257813 0 21 0 Z M 29 0 C 27.742188 0 26.757813 0.257813 26 0.78125 L 26 49 C 26.820313 49.609375 27.851563 49.992188 29 50 L 29.03125 50 C 31.167969 50 34.40625 48.964844 36.09375 46.28125 C 33.003906 44.742188 30 41.65625 30 37 C 30 36.445313 30.449219 36 31 36 C 31.550781 36 32 36.445313 32 37 C 32 42.101563 36.261719 44.273438 37.875 44.90625 C 40.445313 44.59375 42.328125 43.605469 43.28125 42.0625 C 44.191406 40.589844 44.222656 38.75 43.34375 36.5625 C 45.683594 35.503906 47.246094 33.695313 47.78125 31.4375 C 48.199219 29.679688 47.90625 27.78125 47.0625 26.15625 C 45.1875 27.96875 41.804688 30 36 30 C 35.449219 30 35 29.554688 35 29 C 35 28.445313 35.449219 28 36 28 C 42.683594 28 45.636719 25.027344 46.71875 23.5 C 48.449219 18.925781 48.4375 14.617188 46.5625 11.1875 C 45.101563 8.519531 42.578125 6.640625 39.75 6.09375 C 38.648438 3.4375 35.140625 0 29 0 Z M 19 10 C 19.550781 10 20 10.445313 20 11 C 20 12.390625 18.738281 16 13 16 C 12.449219 16 12 15.554688 12 15 C 12 14.445313 12.449219 14 13 14 C 17.078125 14 18 11.777344 18 11 C 18 10.445313 18.449219 10 19 10 Z M 33 12 C 33.550781 12 34 12.445313 34 13 C 34 14.632813 35.710938 18 41 18 C 41.550781 18 42 18.445313 42 19 C 42 19.554688 41.550781 20 41 20 C 34.199219 20 32 15.285156 32 13 C 32 12.445313 32.449219 12 33 12 Z M 11.15625 30 C 15.503906 30.722656 18 34.015625 18 39 C 18 39.554688 17.550781 40 17 40 C 16.449219 40 16 39.554688 16 39 C 16 36.703125 15.3125 32.746094 10.8125 32 C 10.265625 31.910156 9.910156 31.390625 10 30.84375 C 10.089844 30.296875 10.605469 29.902344 11.15625 30 Z';
    const scale = 1.0;
    Offset map(double x, double y) {
      final point = ps(x * 24 / 50, y * 24 / 50);
      final center = ps(12, 12);
      return center + (point - center) / _navIconLearningSettingsScale * scale;
    }
    final brain = _svgPath(filled ? filledD : outlineD, map, r(24 / 50) * scale)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      brain,
      Paint()
        ..color = filled ? fillPaint.color : paint.color
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
  }

  void _paintResources(
    Canvas canvas,
    Paint paint,
    Paint fillPaint,
    Offset Function(double x, double y) p,
    double Function(double logical) r, {
    bool filled = false,
  }) {
    // Icons8 Folder v2 (id 71186). 뷰박스는 50이다.
    const folderD =
        'M 5 4 C 3.3550302 4 2 5.3550302 2 7 L 2 16 L 2 18 L 2 43 C 2 44.64497 3.3550302 46 5 46 L 45 46 C 46.64497 46 48 44.64497 48 43 L 48 19 L 48 16 L 48 11 C 48 9.3550302 46.64497 8 45 8 L 18 8 C 18.08657 8 17.96899 8.000364 17.724609 7.71875 C 17.480227 7.437136 17.179419 6.9699412 16.865234 6.46875 C 16.55105 5.9675588 16.221777 5.4327899 15.806641 4.9628906 C 15.391504 4.4929914 14.818754 4 14 4 L 5 4 z M 5 6 L 14 6 C 13.93925 6 14.06114 6.00701 14.308594 6.2871094 C 14.556051 6.5672101 14.857231 7.0324412 15.169922 7.53125 C 15.482613 8.0300588 15.806429 8.562864 16.212891 9.03125 C 16.619352 9.499636 17.178927 10 18 10 L 45 10 C 45.56503 10 46 10.43497 46 11 L 46 13.1875 C 45.685108 13.07394 45.351843 13 45 13 L 5 13 C 4.6481575 13 4.3148915 13.07394 4 13.1875 L 4 7 C 4 6.4349698 4.4349698 6 5 6 z M 5 15 L 45 15 C 45.56503 15 46 15.43497 46 16 L 46 19 L 46 43 C 46 43.56503 45.56503 44 45 44 L 5 44 C 4.4349698 44 4 43.56503 4 43 L 4 18 L 4 16 C 4 15.43497 4.4349698 15 5 15 z';
    const filledFolderD =
        'M 5 4 C 3.346 4 2 5.346 2 7 L 2 13 L 3 13 L 47 13 L 48 13 L 48 11 C 48 9.346 46.654 8 45 8 L 18.044922 8.0058594 C 17.765922 7.9048594 17.188906 6.9861875 16.878906 6.4921875 C 16.111906 5.2681875 15.317 4 14 4 L 5 4 z M 3 15 C 2.448 15 2 15.448 2 16 L 2 43 C 2 44.657 3.343 46 5 46 L 45 46 C 46.657 46 48 44.657 48 43 L 48 16 C 48 15.448 47.552 15 47 15 L 3 15 z';
    Offset map(double x, double y) => p(x * 24 / 50, y * 24 / 50);
    final unit = r(24 / 50);
    final folder = _svgPath(filled ? filledFolderD : folderD, map, unit)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      folder,
      Paint()
        ..color = filled ? fillPaint.color : paint.color
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
  }

  void _paintSettings(
    Canvas canvas,
    Paint paint,
    Paint fillPaint,
    Offset Function(double x, double y) ps,
    double Function(double logical) r, {
    bool filled = false,
  }) {
    // Icons8 Settings (id 364). 뷰박스는 50이고, 가운데 구멍은 경로에 포함된다.
    const gearD =
        'M 22.205078 2 A 1.0001 1.0001 0 0 0 21.21875 2.8378906 L 20.246094 8.7929688 C 19.076509 9.1331971 17.961243 9.5922728 16.910156 10.164062 L 11.996094 6.6542969 A 1.0001 1.0001 0 0 0 10.708984 6.7597656 L 6.8183594 10.646484 A 1.0001 1.0001 0 0 0 6.7070312 11.927734 L 10.164062 16.873047 C 9.583454 17.930271 9.1142098 19.051824 8.765625 20.232422 L 2.8359375 21.21875 A 1.0001 1.0001 0 0 0 2.0019531 22.205078 L 2.0019531 27.705078 A 1.0001 1.0001 0 0 0 2.8261719 28.691406 L 8.7597656 29.742188 C 9.1064607 30.920739 9.5727226 32.043065 10.154297 33.101562 L 6.6542969 37.998047 A 1.0001 1.0001 0 0 0 6.7597656 39.285156 L 10.648438 43.175781 A 1.0001 1.0001 0 0 0 11.927734 43.289062 L 16.882812 39.820312 C 17.936999 40.39548 19.054994 40.857928 20.228516 41.201172 L 21.21875 47.164062 A 1.0001 1.0001 0 0 0 22.205078 48 L 27.705078 48 A 1.0001 1.0001 0 0 0 28.691406 47.173828 L 29.751953 41.1875 C 30.920633 40.838997 32.033372 40.369697 33.082031 39.791016 L 38.070312 43.291016 A 1.0001 1.0001 0 0 0 39.351562 43.179688 L 43.240234 39.287109 A 1.0001 1.0001 0 0 0 43.34375 37.996094 L 39.787109 33.058594 C 40.355783 32.014958 40.813915 30.908875 41.154297 29.748047 L 47.171875 28.693359 A 1.0001 1.0001 0 0 0 47.998047 27.707031 L 47.998047 22.207031 A 1.0001 1.0001 0 0 0 47.160156 21.220703 L 41.152344 20.238281 C 40.80968 19.078827 40.350281 17.974723 39.78125 16.931641 L 43.289062 11.933594 A 1.0001 1.0001 0 0 0 43.177734 10.652344 L 39.287109 6.7636719 A 1.0001 1.0001 0 0 0 37.996094 6.6601562 L 33.072266 10.201172 C 32.023186 9.6248101 30.909713 9.1579916 29.738281 8.8125 L 28.691406 2.828125 A 1.0001 1.0001 0 0 0 27.705078 2 L 22.205078 2 z M 23.056641 4 L 26.865234 4 L 27.861328 9.6855469 A 1.0001 1.0001 0 0 0 28.603516 10.484375 C 30.066026 10.848832 31.439607 11.426549 32.693359 12.185547 A 1.0001 1.0001 0 0 0 33.794922 12.142578 L 38.474609 8.7792969 L 41.167969 11.472656 L 37.835938 16.220703 A 1.0001 1.0001 0 0 0 37.796875 17.310547 C 38.548366 18.561471 39.118333 19.926379 39.482422 21.380859 A 1.0001 1.0001 0 0 0 40.291016 22.125 L 45.998047 23.058594 L 45.998047 26.867188 L 40.279297 27.871094 A 1.0001 1.0001 0 0 0 39.482422 28.617188 C 39.122545 30.069817 38.552234 31.434687 37.800781 32.685547 A 1.0001 1.0001 0 0 0 37.845703 33.785156 L 41.224609 38.474609 L 38.53125 41.169922 L 33.791016 37.84375 A 1.0001 1.0001 0 0 0 32.697266 37.808594 C 31.44975 38.567585 30.074755 39.148028 28.617188 39.517578 A 1.0001 1.0001 0 0 0 27.876953 40.3125 L 26.867188 46 L 23.052734 46 L 22.111328 40.337891 A 1.0001 1.0001 0 0 0 21.365234 39.53125 C 19.90185 39.170557 18.522094 38.59371 17.259766 37.835938 A 1.0001 1.0001 0 0 0 16.171875 37.875 L 11.46875 41.169922 L 8.7734375 38.470703 L 12.097656 33.824219 A 1.0001 1.0001 0 0 0 12.138672 32.724609 C 11.372652 31.458855 10.793319 30.079213 10.427734 28.609375 A 1.0001 1.0001 0 0 0 9.6328125 27.867188 L 4.0019531 26.867188 L 4.0019531 23.052734 L 9.6289062 22.117188 A 1.0001 1.0001 0 0 0 10.435547 21.373047 C 10.804273 19.898143 11.383325 18.518729 12.146484 17.255859 A 1.0001 1.0001 0 0 0 12.111328 16.164062 L 8.8261719 11.46875 L 11.523438 8.7734375 L 16.185547 12.105469 A 1.0001 1.0001 0 0 0 17.28125 12.148438 C 18.536908 11.394293 19.919867 10.822081 21.384766 10.462891 A 1.0001 1.0001 0 0 0 22.132812 9.6523438 L 23.056641 4 z M 25 17 C 20.593567 17 17 20.593567 17 25 C 17 29.406433 20.593567 33 25 33 C 29.406433 33 33 29.406433 33 25 C 33 20.593567 29.406433 17 25 17 z M 25 19 C 28.325553 19 31 21.674447 31 25 C 31 28.325553 28.325553 31 25 31 C 21.674447 31 19 28.325553 19 25 C 19 21.674447 21.674447 19 25 19 z';
    const filledGearD =
        'M47.16,21.221l-5.91-0.966c-0.346-1.186-0.819-2.326-1.411-3.405l3.45-4.917c0.279-0.397,0.231-0.938-0.112-1.282 l-3.889-3.887c-0.347-0.346-0.893-0.391-1.291-0.104l-4.843,3.481c-1.089-0.602-2.239-1.08-3.432-1.427l-1.031-5.886 C28.607,2.35,28.192,2,27.706,2h-5.5c-0.49,0-0.908,0.355-0.987,0.839l-0.956,5.854c-1.2,0.345-2.352,0.818-3.437,1.412l-4.83-3.45 c-0.399-0.285-0.942-0.239-1.289,0.106L6.82,10.648c-0.343,0.343-0.391,0.883-0.112,1.28l3.399,4.863 c-0.605,1.095-1.087,2.254-1.438,3.46l-5.831,0.971c-0.482,0.08-0.836,0.498-0.836,0.986v5.5c0,0.485,0.348,0.9,0.825,0.985 l5.831,1.034c0.349,1.203,0.831,2.362,1.438,3.46l-3.441,4.813c-0.284,0.397-0.239,0.942,0.106,1.289l3.888,3.891 c0.343,0.343,0.884,0.391,1.281,0.112l4.87-3.411c1.093,0.601,2.248,1.078,3.445,1.424l0.976,5.861C21.3,47.647,21.717,48,22.206,48 h5.5c0.485,0,0.9-0.348,0.984-0.825l1.045-5.89c1.199-0.353,2.348-0.833,3.43-1.435l4.905,3.441 c0.398,0.281,0.938,0.232,1.282-0.111l3.888-3.891c0.346-0.347,0.391-0.894,0.104-1.292l-3.498-4.857 c0.593-1.08,1.064-2.222,1.407-3.408l5.918-1.039c0.479-0.084,0.827-0.5,0.827-0.985v-5.5C47.999,21.718,47.644,21.3,47.16,21.221z M25,32c-3.866,0-7-3.134-7-7c0-3.866,3.134-7,7-7s7,3.134,7,7C32,28.866,28.866,32,25,32z';
    const scale = _navIconLearningSettingsScale;
    Offset map(double x, double y) => ps(x * 24 / 50, y * 24 / 50);
    final unit = r(24 / 50) * scale;
    final source = filled ? filledGearD : gearD;
    final gear = _svgPath(source, map, unit)..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      gear,
      Paint()
        ..color = filled ? fillPaint.color : paint.color
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
  }

  Path _svgPath(
    String source,
    Offset Function(double x, double y) map,
    double unit,
  ) {
    final path = Path();
    final tokens = RegExp(r'[MmLlHhVvCcSsAaZz]|-?\d*\.?\d+(?:e[-+]?\d+)?')
        .allMatches(source)
        .map((match) => match.group(0)!)
        .toList();
    var index = 0;
    var command = '';
    var x = 0.0;
    var y = 0.0;
    var startX = 0.0;
    var startY = 0.0;
    var lastCtrlX = 0.0;
    var lastCtrlY = 0.0;
    var smooth = false;
    final isCommand = RegExp(r'^[MmLlHhVvCcSsAaZz]$');
    double read() => double.parse(tokens[index++]);

    while (index < tokens.length) {
      if (isCommand.hasMatch(tokens[index])) {
        command = tokens[index];
        index++;
      }
      switch (command) {
        case 'M':
          x = read();
          y = read();
          final point = map(x, y);
          path.moveTo(point.dx, point.dy);
          startX = x;
          startY = y;
          command = 'L';
          smooth = false;
          break;
        case 'm':
          x += read();
          y += read();
          final point = map(x, y);
          path.moveTo(point.dx, point.dy);
          startX = x;
          startY = y;
          command = 'l';
          smooth = false;
          break;
        case 'L':
          x = read();
          y = read();
          final point = map(x, y);
          path.lineTo(point.dx, point.dy);
          smooth = false;
          break;
        case 'l':
          x += read();
          y += read();
          final point = map(x, y);
          path.lineTo(point.dx, point.dy);
          smooth = false;
          break;
        case 'H':
          x = read();
          final point = map(x, y);
          path.lineTo(point.dx, point.dy);
          smooth = false;
          break;
        case 'h':
          x += read();
          final point = map(x, y);
          path.lineTo(point.dx, point.dy);
          smooth = false;
          break;
        case 'V':
          y = read();
          final point = map(x, y);
          path.lineTo(point.dx, point.dy);
          smooth = false;
          break;
        case 'v':
          y += read();
          final point = map(x, y);
          path.lineTo(point.dx, point.dy);
          smooth = false;
          break;
        case 'C':
          final x1 = read();
          final y1 = read();
          final x2 = read();
          final y2 = read();
          x = read();
          y = read();
          final c1 = map(x1, y1);
          final c2 = map(x2, y2);
          final end = map(x, y);
          path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
          lastCtrlX = x2;
          lastCtrlY = y2;
          smooth = true;
          break;
        case 'c':
          final dx1 = read();
          final dy1 = read();
          final dx2 = read();
          final dy2 = read();
          final dx = read();
          final dy = read();
          final c1 = map(x + dx1, y + dy1);
          final c2 = map(x + dx2, y + dy2);
          lastCtrlX = x + dx2;
          lastCtrlY = y + dy2;
          x += dx;
          y += dy;
          final end = map(x, y);
          path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
          smooth = true;
          break;
        case 'S':
        case 's':
          final reflectedX = smooth ? 2 * x - lastCtrlX : x;
          final reflectedY = smooth ? 2 * y - lastCtrlY : y;
          final x2 = command == 'S' ? read() : x + read();
          final y2 = command == 'S' ? read() : y + read();
          final endX = command == 'S' ? read() : x + read();
          final endY = command == 'S' ? read() : y + read();
          final c1 = map(reflectedX, reflectedY);
          final c2 = map(x2, y2);
          final end = map(endX, endY);
          path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
          lastCtrlX = x2;
          lastCtrlY = y2;
          x = endX;
          y = endY;
          smooth = true;
          break;
        case 'A':
        case 'a':
          final rx = read() * unit;
          final ry = read() * unit;
          final rotation = read() * math.pi / 180;
          final largeArc = read() != 0;
          final sweep = read() != 0;
          if (command == 'A') {
            x = read();
            y = read();
          } else {
            x += read();
            y += read();
          }
          final point = map(x, y);
          path.arcToPoint(
            point,
            radius: Radius.elliptical(rx, ry),
            rotation: rotation,
            largeArc: largeArc,
            clockwise: sweep,
          );
          smooth = false;
          break;
        case 'Z':
        case 'z':
          path.close();
          x = startX;
          y = startY;
          smooth = false;
          break;
        default:
          index++;
          break;
      }
    }
    return path;
  }

  @override
  bool shouldRepaint(covariant _NavIconPainter oldDelegate) {
    return oldDelegate.kind != kind ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.filled != filled;
  }
}
