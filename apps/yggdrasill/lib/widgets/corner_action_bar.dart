import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

/// 메뉴 화면이 오른쪽 아래 유리 막대에 자기 버튼을 넘기는 자리.
///
/// 막대 껍질은 [MainScreen]이 계속 들고 있어서, 학생·시간 메뉴를 오가도
/// 유리 막대를 지웠다 다시 넣지 않는다. 화면은 너비와 안쪽 버튼만 넘긴다.
class SharedCornerActionBarModel extends ChangeNotifier {
  final Map<int, double> _widths = {};
  final Map<int, double> _rights = {};
  final Map<int, bool> _visible = {};
  final Map<int, WidgetBuilder> _builders = {};

  double? widthFor(int menuIndex) => _widths[menuIndex];
  double? rightFor(int menuIndex) => _rights[menuIndex];
  bool visibleFor(int menuIndex) => _visible[menuIndex] ?? true;
  WidgetBuilder? builderFor(int menuIndex) => _builders[menuIndex];

  void bind({
    required int menuIndex,
    required double width,
    required bool visible,
    required WidgetBuilder builder,
    double right = FabTabBarTokens.fabBarRightInset,
  }) {
    _widths[menuIndex] = width;
    _rights[menuIndex] = right;
    _visible[menuIndex] = visible;
    _builders[menuIndex] = builder;
    _notifyAfterBuild();
  }

  void refresh() => _notifyAfterBuild();

  /// 빌더만 떼고 너비는 남긴다. 알림은 빌드 중이면 다음 프레임으로 미룬다.
  void unbindMenu(int menuIndex) {
    _builders.remove(menuIndex);
    _visible[menuIndex] = false;
    _notifyAfterBuild();
  }

  void _notifyAfterBuild() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        notifyListeners();
      });
      return;
    }
    notifyListeners();
  }
}

final sharedCornerActionBar = SharedCornerActionBarModel();

/// 하단 액션 막대 껍질. [MainScreen] 스택에 계속 붙어 있다.
///
/// 한 번 나타난 뒤에는 메뉴에 막대가 없어도 위젯을 지우지 않고 투명하게 둔다.
class SharedCornerActionBarHost extends StatefulWidget {
  const SharedCornerActionBarHost({super.key, required this.menuIndex});

  final int menuIndex;

  static const double barHeight = FabTabBarTokens.fabBarHeight;
  static const double barPadding = 6;
  static const Duration animDuration = Duration(milliseconds: 340);
  static const Duration contentFadeDuration = Duration(milliseconds: 180);

  @override
  State<SharedCornerActionBarHost> createState() =>
      _SharedCornerActionBarHostState();
}

class _SharedCornerActionBarHostState extends State<SharedCornerActionBarHost> {
  double? _latchedWidth;
  double? _latchedRight;
  int? _latchedMenu;
  Widget _latchedChild = const SizedBox.shrink();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sharedCornerActionBar,
      builder: (context, _) {
        final width = sharedCornerActionBar.widthFor(widget.menuIndex);
        final right = sharedCornerActionBar.rightFor(widget.menuIndex);
        final builder = sharedCornerActionBar.builderFor(widget.menuIndex);
        final show = width != null &&
            right != null &&
            sharedCornerActionBar.visibleFor(widget.menuIndex) &&
            builder != null;
        if (show) {
          _latchedWidth = width;
          _latchedRight = right;
          _latchedMenu = widget.menuIndex;
          _latchedChild = builder(context);
        }
        final shellWidth = _latchedWidth;
        final shellRight = _latchedRight;
        if (shellWidth == null || shellRight == null) {
          return const SizedBox.shrink();
        }
        return AnimatedPositioned(
          duration: SharedCornerActionBarHost.animDuration,
          curve: Curves.easeInOutCubic,
          right: shellRight,
          bottom: FabTabBarTokens.fabBarBottomInset,
          child: IgnorePointer(
            ignoring: !show,
            child: AnimatedOpacity(
              opacity: show ? 1 : 0,
              duration: SharedCornerActionBarHost.contentFadeDuration,
              curve: Curves.easeOutCubic,
              child: _CornerActionBarShell(
                width: shellWidth,
                child: AnimatedSwitcher(
                  duration: SharedCornerActionBarHost.contentFadeDuration,
                  child: KeyedSubtree(
                    key: ValueKey<int?>(_latchedMenu),
                    child: _latchedChild,
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

class _CornerActionBarShell extends StatelessWidget {
  const _CornerActionBarShell({required this.width, required this.child});

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const barHeight = SharedCornerActionBarHost.barHeight;
    final brightness = Theme.of(context).brightness;
    final palette = FabTabBarTokens.paletteFor(brightness);
    final radius = BorderRadius.circular(barHeight / 2);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: palette.boxShadows,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: FabTabBarTokens.fabRelatedBlurSigmaFor(brightness),
            sigmaY: FabTabBarTokens.fabRelatedBlurSigmaFor(brightness),
          ),
          child: AnimatedContainer(
            duration: SharedCornerActionBarHost.animDuration,
            curve: Curves.easeInOutCubic,
            width: width,
            height: barHeight,
            padding: const EdgeInsets.all(SharedCornerActionBarHost.barPadding),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: radius,
            ),
            child: ClipRect(child: child),
          ),
        ),
      ),
    );
  }
}
