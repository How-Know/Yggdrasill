import 'package:flutter/material.dart';

import 'student_account_button.dart';
import 'student_bottom_nav_bar.dart';
import 'student_status_island.dart';

/// 학생앱 공용 상단 타이틀 — 왼쪽 페이지명 + (옵션 액션) + 오른쪽 계정 버튼.
///
/// 타이틀 행 중점은 상태 아일랜드 중점과 같은 Y에 맞춘다.
class StudentPageTitle extends StatelessWidget {
  const StudentPageTitle({
    super.key,
    required this.title,
    this.actions = const <Widget>[],
  });

  final String title;
  final List<Widget> actions;

  static const double fontSize = 28;
  static const double barHeight = 48;

  /// SafeArea(상태바) + 툴바 중앙 + 아일랜드 오프셋 기준 top inset.
  static double topInsetOf(BuildContext context) =>
      MediaQuery.paddingOf(context).top +
      (kToolbarHeight / 2) +
      StudentStatusIsland.centerOffsetY -
      (barHeight / 2);

  /// 스크롤 본문 앞에 둘 타이틀 영역 전체 높이.
  static double extentOf(BuildContext context) =>
      topInsetOf(context) + barHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(24, topInsetOf(context), 24, 0),
      child: SizedBox(
        height: barHeight,
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w700,
                  height: 1.15,
                ),
              ),
            ),
            ...actions,
            if (actions.isNotEmpty) const SizedBox(width: 4),
            const StudentAccountButton(),
          ],
        ),
      ),
    );
  }
}

typedef StudentCollapsingBodyBuilder = Widget Function(
  BuildContext context,
  double topInset,
  double bottomInset,
);

/// 스크롤하면 타이틀이 페이드아웃되고, 본문은 아일랜드·하단 탭바 영역까지 확장.
class StudentCollapsingTitlePage extends StatefulWidget {
  const StudentCollapsingTitlePage({
    super.key,
    required this.title,
    this.actions = const <Widget>[],
    this.onRefresh,
    required this.bodyBuilder,
  });

  final String title;
  final List<Widget> actions;
  final Future<void> Function()? onRefresh;
  final StudentCollapsingBodyBuilder bodyBuilder;

  static const double fadeDistance = 56;

  @override
  State<StudentCollapsingTitlePage> createState() =>
      _StudentCollapsingTitlePageState();
}

class _StudentCollapsingTitlePageState extends State<StudentCollapsingTitlePage> {
  double _opacity = 1;

  void _updateOpacity(double pixels) {
    final next =
        (1 - pixels / StudentCollapsingTitlePage.fadeDistance).clamp(0.0, 1.0);
    if ((next - _opacity).abs() > 0.01) {
      setState(() => _opacity = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final topInset = StudentPageTitle.extentOf(context);
    final bottomInset = StudentBottomNavTokens.contentBottomPadding(context);
    var body = widget.bodyBuilder(context, topInset, bottomInset);
    if (widget.onRefresh != null) {
      body = RefreshIndicator(
        onRefresh: widget.onRefresh!,
        edgeOffset: topInset,
        child: body,
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis != Axis.vertical) return false;
        if (notification is ScrollUpdateNotification ||
            notification is ScrollEndNotification ||
            notification is OverscrollNotification) {
          _updateOpacity(notification.metrics.pixels);
        }
        return false;
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          body,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              ignoring: _opacity < 0.05,
              child: Opacity(
                opacity: _opacity,
                child: Transform.translate(
                  offset: Offset(0, -(1 - _opacity) * 12),
                  child: StudentPageTitle(
                    title: widget.title,
                    actions: widget.actions,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
