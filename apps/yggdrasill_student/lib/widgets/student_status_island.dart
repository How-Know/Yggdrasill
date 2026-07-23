import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// iOS 다이나믹 아일랜드 스타일 상태 영역.
///
/// 공부중/휴식중 표시는 이후 연결 — 지금은 레이아웃만.
class StudentStatusIsland extends StatelessWidget {
  const StudentStatusIsland({super.key});

  static const double height = 36;
  static const double minWidth = 128;

  /// SafeArea + `kToolbarHeight` 중앙 대비 아일랜드 중점 하향 오프셋.
  /// 다른 AppBar 콘텐츠도 이 값으로 Y를 맞춘다.
  static const double centerOffsetY = 10;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 다이나믹 아일랜드처럼 항상 진한 캡슐 (라이트/다크 공통).
    final fill = isDark ? const Color(0xFF1C1C1E) : const Color(0xFF0B0B0D);
    final border = isDark ? Colors.white10 : Colors.black12;

    return Semantics(
      label: '학습 상태',
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: minWidth,
          minHeight: height,
          maxHeight: height,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: border),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 상태 점 자리 (공부중=녹 / 휴식중=주황 예정).
                SizedBox(
                  width: 8,
                  height: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0xFF3A3A3C),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                SizedBox(width: 8),
                // 라벨 자리 — 실제 상태 문구는 이후 연결.
                SizedBox(
                  width: 72,
                  height: 12,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0xFF3A3A3C),
                      borderRadius: BorderRadius.all(Radius.circular(6)),
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

/// 아일랜드와 **동일한** 세로 슬롯 (SafeArea + 툴바 56 + centerOffsetY).
/// 이 슬롯 안에서 CrossAxisAlignment.center / Center 한 위젯은 아일랜드 중점과 Y가 같다.
class StudentStatusIslandToolbarSlot extends StatelessWidget {
  const StudentStatusIslandToolbarSlot({
    super.key,
    required this.child,
    this.ignorePointer = false,
  });

  final Widget child;
  final bool ignorePointer;

  /// AppBar preferredSize 높이 = 상태바 + 툴바.
  static double preferredHeight(BuildContext context) =>
      MediaQuery.paddingOf(context).top + kToolbarHeight;

  @override
  Widget build(BuildContext context) {
    final slot = SafeArea(
      bottom: false,
      child: SizedBox(
        height: kToolbarHeight,
        child: Transform.translate(
          offset: const Offset(0, StudentStatusIsland.centerOffsetY),
          child: child,
        ),
      ),
    );
    return ignorePointer ? IgnorePointer(child: slot) : slot;
  }
}

/// Navigator 위에 올려 탭·push 전환에도 같은 자리에 유지한다.
class StudentStatusIslandHost extends StatelessWidget {
  const StudentStatusIslandHost({super.key, required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, _) {
        final loggedIn =
            Supabase.instance.client.auth.currentSession != null;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (child != null) child!,
            if (loggedIn)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: StudentStatusIslandToolbarSlot(
                  ignorePointer: true,
                  child: Center(child: StudentStatusIsland()),
                ),
              ),
          ],
        );
      },
    );
  }
}
