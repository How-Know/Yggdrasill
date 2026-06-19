import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'app_bar_title.dart'; // for AccountButton
import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../theme/ygg_semantic_colors.dart';

const double _navIconSize = 35.2;
const double _navMenuIconStrokeWidth = 2.64;
const double _navIconStrokeWidthSelected = 3.0;
/// 하단 탭 비선택 — 라이트·다크 공통 (선택 시 [_navIconStrokeWidthSelected]).
const double _navIconStrokeWidthUnselected = 2.0;
const double _navDestinationVerticalPadding = 16.0;
const double _navHighlightWidth = 67.8;
const double _navHighlightHeight = 38.7;
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
    double strokeWidth = _navMenuIconStrokeWidth,
  }) {
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _NavIconPainter(
            kind: kind,
            color: color,
            strokeWidth: strokeWidth,
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
    final strokeWidth = selected
        ? _navIconStrokeWidthSelected
        : _navIconStrokeWidthUnselected;
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
                padding: const EdgeInsets.only(bottom: 16.0, top: 8.0),
                radius: 20,
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

  const _NavIconPainter({
    required this.kind,
    required this.color,
    required this.strokeWidth,
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

    switch (kind) {
      case _NavIconKind.package:
        _paintPackage(canvas, paint, p);
        break;
      case _NavIconKind.home:
        _paintHome(canvas, paint, p);
        break;
      case _NavIconKind.student:
        _paintStudent(canvas, paint, p, r);
        break;
      case _NavIconKind.time:
        _paintTime(canvas, paint, p, r);
        break;
      case _NavIconKind.learning:
        _paintLearning(canvas, paint, ps);
        break;
      case _NavIconKind.resources:
        _paintResources(canvas, paint, p);
        break;
      case _NavIconKind.settings:
        _paintSettings(canvas, paint, ps, r);
        break;
    }
  }

  void _paintPackage(
    Canvas canvas,
    Paint paint,
    Offset Function(double x, double y) p,
  ) {
    final top = Path()
      ..moveTo(p(12, 3).dx, p(12, 3).dy)
      ..lineTo(p(20, 7.5).dx, p(20, 7.5).dy)
      ..lineTo(p(12, 12).dx, p(12, 12).dy)
      ..lineTo(p(4, 7.5).dx, p(4, 7.5).dy)
      ..close();
    final left = Path()
      ..moveTo(p(4, 7.5).dx, p(4, 7.5).dy)
      ..lineTo(p(12, 12).dx, p(12, 12).dy)
      ..lineTo(p(12, 21).dx, p(12, 21).dy)
      ..lineTo(p(4, 16.5).dx, p(4, 16.5).dy)
      ..close();
    final right = Path()
      ..moveTo(p(20, 7.5).dx, p(20, 7.5).dy)
      ..lineTo(p(12, 12).dx, p(12, 12).dy)
      ..lineTo(p(12, 21).dx, p(12, 21).dy)
      ..lineTo(p(20, 16.5).dx, p(20, 16.5).dy)
      ..close();
    canvas
      ..drawPath(top, paint)
      ..drawPath(left, paint)
      ..drawPath(right, paint);
  }

  void _paintHome(
    Canvas canvas,
    Paint paint,
    Offset Function(double x, double y) p,
  ) {
    final path = Path()
      ..moveTo(p(5, 11).dx, p(5, 11).dy)
      ..lineTo(p(12, 5).dx, p(12, 5).dy)
      ..lineTo(p(19, 11).dx, p(19, 11).dy)
      ..lineTo(p(19, 20).dx, p(19, 20).dy)
      ..lineTo(p(15, 20).dx, p(15, 20).dy)
      ..lineTo(p(15, 15).dx, p(15, 15).dy)
      ..lineTo(p(9, 15).dx, p(9, 15).dy)
      ..lineTo(p(9, 20).dx, p(9, 20).dy)
      ..lineTo(p(5, 20).dx, p(5, 20).dy)
      ..close();
    canvas.drawPath(path, paint);
  }

  void _paintStudent(
    Canvas canvas,
    Paint paint,
    Offset Function(double x, double y) p,
    double Function(double logical) r,
  ) {
    canvas.drawCircle(p(12, 7.5), r(3.0), paint);
    final path = Path()
      ..moveTo(p(5, 20).dx, p(5, 20).dy)
      ..cubicTo(
        p(6.2, 15.8).dx,
        p(6.2, 15.8).dy,
        p(7.9, 14).dx,
        p(7.9, 14).dy,
        p(12, 14).dx,
        p(12, 14).dy,
      )
      ..cubicTo(
        p(16.1, 14).dx,
        p(16.1, 14).dy,
        p(17.8, 15.8).dx,
        p(17.8, 15.8).dy,
        p(19, 20).dx,
        p(19, 20).dy,
      );
    canvas.drawPath(path, paint);
  }

  void _paintTime(
    Canvas canvas,
    Paint paint,
    Offset Function(double x, double y) p,
    double Function(double logical) r,
  ) {
    final faceCenter = p(12, 12.5);

    canvas.drawCircle(faceCenter, r(8.0), paint);

    // 10:10 — 분침(2시) / 시침(10시)
    canvas
      ..drawLine(faceCenter, p(16.7, 9.9), paint)
      ..drawLine(faceCenter, p(8.4, 10.4), paint);
  }

  void _paintLearning(
    Canvas canvas,
    Paint paint,
    Offset Function(double x, double y) ps,
  ) {
    // 좌·우 반구 외곽선 유지, 내부 장식만 제거(굵은 stroke에서도 깔끔).
    final left = Path()
      ..moveTo(ps(10.85, 5).dx, ps(10.85, 5).dy)
      ..cubicTo(
        ps(7.8, 5).dx,
        ps(7.8, 5).dy,
        ps(6, 7.2).dx,
        ps(6, 7.2).dy,
        ps(6.6, 10.2).dx,
        ps(6.6, 10.2).dy,
      )
      ..cubicTo(
        ps(4.4, 11).dx,
        ps(4.4, 11).dy,
        ps(4, 14.2).dx,
        ps(4, 14.2).dy,
        ps(6.6, 15.4).dx,
        ps(6.6, 15.4).dy,
      )
      ..cubicTo(
        ps(6.2, 18).dx,
        ps(6.2, 18).dy,
        ps(8, 20).dx,
        ps(8, 20).dy,
        ps(10.85, 19).dx,
        ps(10.85, 19).dy,
      )
      ..lineTo(ps(10.85, 5).dx, ps(10.85, 5).dy);
    final right = Path()
      ..moveTo(ps(13.15, 5).dx, ps(13.15, 5).dy)
      ..cubicTo(
        ps(16.2, 5).dx,
        ps(16.2, 5).dy,
        ps(18, 7.2).dx,
        ps(18, 7.2).dy,
        ps(17.4, 10.2).dx,
        ps(17.4, 10.2).dy,
      )
      ..cubicTo(
        ps(19.6, 11).dx,
        ps(19.6, 11).dy,
        ps(20, 14.2).dx,
        ps(20, 14.2).dy,
        ps(17.4, 15.4).dx,
        ps(17.4, 15.4).dy,
      )
      ..cubicTo(
        ps(17.8, 18).dx,
        ps(17.8, 18).dy,
        ps(16, 20).dx,
        ps(16, 20).dy,
        ps(13.15, 19).dx,
        ps(13.15, 19).dy,
      )
      ..lineTo(ps(13.15, 5).dx, ps(13.15, 5).dy);
    canvas
      ..drawPath(left, paint)
      ..drawPath(right, paint);
  }

  void _paintResources(
    Canvas canvas,
    Paint paint,
    Offset Function(double x, double y) p,
  ) {
    final left = Path()
      ..moveTo(p(4, 6).dx, p(4, 6).dy)
      ..cubicTo(
        p(6.7, 5.6).dx,
        p(6.7, 5.6).dy,
        p(9.4, 6.2).dx,
        p(9.4, 6.2).dy,
        p(11.5, 8).dx,
        p(11.5, 8).dy,
      )
      ..lineTo(p(11.5, 20).dx, p(11.5, 20).dy)
      ..cubicTo(
        p(9.4, 18.2).dx,
        p(9.4, 18.2).dy,
        p(6.7, 17.6).dx,
        p(6.7, 17.6).dy,
        p(4, 18).dx,
        p(4, 18).dy,
      )
      ..close();
    final right = Path()
      ..moveTo(p(20, 6).dx, p(20, 6).dy)
      ..cubicTo(
        p(17.3, 5.6).dx,
        p(17.3, 5.6).dy,
        p(14.6, 6.2).dx,
        p(14.6, 6.2).dy,
        p(12.5, 8).dx,
        p(12.5, 8).dy,
      )
      ..lineTo(p(12.5, 20).dx, p(12.5, 20).dy)
      ..cubicTo(
        p(14.6, 18.2).dx,
        p(14.6, 18.2).dy,
        p(17.3, 17.6).dx,
        p(17.3, 17.6).dy,
        p(20, 18).dx,
        p(20, 18).dy,
      )
      ..close();
    canvas
      ..drawPath(left, paint)
      ..drawPath(right, paint);
  }

  void _paintSettings(
    Canvas canvas,
    Paint paint,
    Offset Function(double x, double y) ps,
    double Function(double logical) r,
  ) {
    const scale = _navIconLearningSettingsScale;
    final path = Path();
    const teeth = 8;
    for (int i = 0; i < teeth * 2; i++) {
      final radius = i.isEven ? 7.7 : 6.2;
      final angle = -math.pi / 2 + i * math.pi / teeth;
      final point = ps(
        12 + math.cos(angle) * radius,
        12 + math.sin(angle) * radius,
      );
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
    canvas.drawCircle(ps(12, 12), r(2.8 * scale), paint);
  }

  @override
  bool shouldRepaint(covariant _NavIconPainter oldDelegate) {
    return oldDelegate.kind != kind ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
