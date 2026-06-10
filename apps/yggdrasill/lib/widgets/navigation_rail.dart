import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'app_bar_title.dart'; // for AccountButton
import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../theme/ygg_semantic_colors.dart';

const double _navIconSize = 35.2;
const double _navIconStrokeWidth = 2.64;
const double _navDestinationVerticalPadding = 12.1;
const double _navHighlightWidth = 67.8;
const double _navHighlightHeight = 38.7;
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
  }) {
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _NavIconPainter(
            kind: kind,
            color: color,
            strokeWidth: _navIconStrokeWidth,
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
  }) {
    final icon = Center(
      child: _navIcon(kind, color: color),
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

  NavigationRailDestination _destination({
    required String tooltip,
    required _NavIconKind kind,
    required Color color,
    required Color highlightColor,
  }) {
    return NavigationRailDestination(
      padding: const EdgeInsets.symmetric(
        vertical: _navDestinationVerticalPadding,
      ),
      icon: Tooltip(
        message: tooltip,
        child: _navIconSlot(
          kind: kind,
          color: color,
          highlightColor: highlightColor,
          selected: false,
        ),
      ),
      selectedIcon: Tooltip(
        message: tooltip,
        child: _navIconSlot(
          kind: kind,
          color: color,
          highlightColor: highlightColor,
          selected: true,
        ),
      ),
      label: const Text(''),
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
    final double railWidth = NavigationRailTheme.of(context).minWidth ?? 84.0;
    return Column(
      children: [
        Expanded(
          child: NavigationRail(
            backgroundColor: navBackground,
            unselectedIconTheme:
                IconThemeData(color: navIconColor, size: _navIconSize),
            selectedIconTheme:
                IconThemeData(color: navIconColor, size: _navIconSize),
            selectedIndex: selectedIndex.clamp(0, 5),
            onDestinationSelected: onDestinationSelected,
            leading: Padding(
              padding: const EdgeInsets.only(
                top: navLeadingPaddingTop,
                bottom: _navLeadingPaddingBottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: AnimatedBuilder(
                      animation: rotationAnimation,
                      builder: (context, child) {
                        return Transform.rotate(
                          angle: rotationAnimation.value * (math.pi / 2),
                          child: _navIcon(
                            _NavIconKind.package,
                            color: navIconColor,
                          ),
                        );
                      },
                    ),
                    onPressed: onMenuPressed,
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
            useIndicator: false,
            destinations: [
              _destination(
                tooltip: '홈',
                kind: _NavIconKind.home,
                color: navIconColor,
                highlightColor: highlightColor,
              ),
              _destination(
                tooltip: '학생',
                kind: _NavIconKind.student,
                color: navIconColor,
                highlightColor: highlightColor,
              ),
              _destination(
                tooltip: '시간',
                kind: _NavIconKind.time,
                color: navIconColor,
                highlightColor: highlightColor,
              ),
              _destination(
                tooltip: '학습',
                kind: _NavIconKind.learning,
                color: navIconColor,
                highlightColor: highlightColor,
              ),
              _destination(
                tooltip: '자료',
                kind: _NavIconKind.resources,
                color: navIconColor,
                highlightColor: highlightColor,
              ),
              _destination(
                tooltip: '설정',
                kind: _NavIconKind.settings,
                color: navIconColor,
                highlightColor: highlightColor,
              ),
            ],
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
        _paintStudent(canvas, paint, p);
        break;
      case _NavIconKind.time:
        _paintTime(canvas, paint, p);
        break;
      case _NavIconKind.learning:
        _paintLearning(canvas, paint, p);
        break;
      case _NavIconKind.resources:
        _paintResources(canvas, paint, p);
        break;
      case _NavIconKind.settings:
        _paintSettings(canvas, paint, p);
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
  ) {
    canvas.drawCircle(p(12, 7.5), 3.0, paint);
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
  ) {
    canvas.drawCircle(p(12, 13), 7, paint);
    canvas.drawLine(p(12, 13), p(12, 9), paint);
    canvas.drawLine(p(12, 13), p(15, 13), paint);
    canvas.drawLine(p(9, 3), p(15, 3), paint);
    canvas.drawLine(p(12, 3), p(12, 5), paint);
  }

  void _paintLearning(
    Canvas canvas,
    Paint paint,
    Offset Function(double x, double y) p,
  ) {
    final left = Path()
      ..moveTo(p(11.2, 5).dx, p(11.2, 5).dy)
      ..cubicTo(
        p(7.8, 5).dx,
        p(7.8, 5).dy,
        p(6, 7.2).dx,
        p(6, 7.2).dy,
        p(6.6, 10.2).dx,
        p(6.6, 10.2).dy,
      )
      ..cubicTo(
        p(4.4, 11).dx,
        p(4.4, 11).dy,
        p(4, 14.2).dx,
        p(4, 14.2).dy,
        p(6.6, 15.4).dx,
        p(6.6, 15.4).dy,
      )
      ..cubicTo(
        p(6.2, 18).dx,
        p(6.2, 18).dy,
        p(8, 20).dx,
        p(8, 20).dy,
        p(11.2, 19).dx,
        p(11.2, 19).dy,
      )
      ..lineTo(p(11.2, 5).dx, p(11.2, 5).dy);
    final right = Path()
      ..moveTo(p(12.8, 5).dx, p(12.8, 5).dy)
      ..cubicTo(
        p(16.2, 5).dx,
        p(16.2, 5).dy,
        p(18, 7.2).dx,
        p(18, 7.2).dy,
        p(17.4, 10.2).dx,
        p(17.4, 10.2).dy,
      )
      ..cubicTo(
        p(19.6, 11).dx,
        p(19.6, 11).dy,
        p(20, 14.2).dx,
        p(20, 14.2).dy,
        p(17.4, 15.4).dx,
        p(17.4, 15.4).dy,
      )
      ..cubicTo(
        p(17.8, 18).dx,
        p(17.8, 18).dy,
        p(16, 20).dx,
        p(16, 20).dy,
        p(12.8, 19).dx,
        p(12.8, 19).dy,
      )
      ..lineTo(p(12.8, 5).dx, p(12.8, 5).dy);
    canvas
      ..drawPath(left, paint)
      ..drawPath(right, paint)
      ..drawLine(p(8, 10), p(10.5, 10), paint)
      ..drawLine(p(13.5, 14), p(16, 14), paint)
      ..drawCircle(p(7.8, 13.5), 0.8, paint)
      ..drawCircle(p(16.2, 10.5), 0.8, paint);
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
        p(12, 8).dx,
        p(12, 8).dy,
      )
      ..lineTo(p(12, 20).dx, p(12, 20).dy)
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
        p(12, 8).dx,
        p(12, 8).dy,
      )
      ..lineTo(p(12, 20).dx, p(12, 20).dy)
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
    Offset Function(double x, double y) p,
  ) {
    final path = Path();
    const teeth = 8;
    for (int i = 0; i < teeth * 2; i++) {
      final radius = i.isEven ? 8.0 : 6.4;
      final angle = -math.pi / 2 + i * math.pi / teeth;
      final point = p(12 + math.cos(angle) * radius, 12 + math.sin(angle) * radius);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
    canvas.drawCircle(p(12, 12), 2.8, paint);
  }

  @override
  bool shouldRepaint(covariant _NavIconPainter oldDelegate) {
    return oldDelegate.kind != kind ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
