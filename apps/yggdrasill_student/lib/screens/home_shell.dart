import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/homework_live_activity.dart';
import '../services/homework_session.dart';
import '../services/student_api.dart';
import '../services/student_attendance_session.dart';
import '../services/student_presence_session.dart';
import '../services/student_shell_chrome.dart';
import '../widgets/homework_now_playing_bar.dart';
import '../widgets/homework_now_playing_sheet.dart';
import '../widgets/student_bottom_nav_bar.dart';
import 'homework_screen.dart';
import 'profile_screen.dart';
import 'textbook_screen.dart';

/// 하단 플로팅 네비 + 풀블리드 본문. (아이패드 가로/세로 공통)
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with HomeworkNowPlayingActions {
  int _index = 0;
  bool _searchExpanded = false;
  /// 확장 시트가 Stack에 올라가 있는지 (슬라이드 아웃 중에도 true).
  bool _nowPlayingSheetMounted = false;
  /// 확장 중 1줄 크롬 강제. 닫기 시작과 동시에 false → 스크롤 축소와 같은 애니.
  bool _nowPlayingForceOneLine = false;

  @override
  void initState() {
    super.initState();
    HomeworkSession.instance.addListener(_onSessionChanged);
    StudentShellChrome.instance.addListener(_onChromeChanged);
    // Realtime + 1.2s 폴백 (학습앱과 동일 패턴).
    unawaited(HomeworkSession.instance.startSync());
    // 등원/하원 Realtime + 폴백 (키오스크 등원 즉시 반영).
    unawaited(StudentAttendanceSession.instance.startSync());
    // 학습앱에 학원/집 로그인 상태를 보여 주는 presence heartbeat.
    // iOS 는 다른 iPad 로그인 시 이 기기를 로그아웃아웃.
    StudentPresenceSession.instance.setOnIosDeviceReplaced(() async {
      await StudentPresenceSession.instance.stop(markOffline: false);
      await StudentApi.instance.signOut();
    });
    unawaited(StudentPresenceSession.instance.start());
    // iOS 잠금화면 Live Activity (비-iOS는 no-op).
    unawaited(HomeworkLiveActivity.instance.start());
    // 서버 아바타 → 세션 hydrate (계정 버튼/시트에 즉시 반영).
    unawaited(StudentApi.instance.getInfo());
  }

  @override
  void dispose() {
    unawaited(HomeworkLiveActivity.instance.stop());
    unawaited(HomeworkSession.instance.stopSync());
    unawaited(StudentAttendanceSession.instance.stopSync());
    unawaited(StudentPresenceSession.instance.stop(markOffline: true));
    HomeworkSession.instance.removeListener(_onSessionChanged);
    StudentShellChrome.instance.removeListener(_onChromeChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  void _onChromeChanged() {
    if (mounted) setState(() {});
  }

  void _setSearchExpanded(bool expanded) {
    if (_searchExpanded == expanded) return;
    setState(() => _searchExpanded = expanded);
    StudentShellChrome.instance.setSearchExpanded(expanded);
  }

  void _selectTab(int i) {
    StudentShellChrome.instance.clearTabsPin();
    StudentShellChrome.instance.setScrollCollapsed(false);
    setState(() => _index = i);
  }

  void _onCollapsedNavTap() {
    if (_searchExpanded) {
      _setSearchExpanded(false);
      return;
    }
    StudentShellChrome.instance.pinTabsOpen();
  }

  Future<void> _dismissMiniBar() async {
    final session = HomeworkSession.instance;
    final group = session.active;
    final wasRunning = group != null && session.isRunningGroup(group.groupId);
    _unmountNowPlayingSheet();
    await session.dismissMiniBar();
    if (!mounted || !wasRunning) return;
    TopGlassSnackBar.show(
      context,
      message: '과제를 일시정지했어요.',
      icon: Icons.pause_circle_outline_rounded,
    );
  }

  void _expandNowPlaying() {
    if (_nowPlayingSheetMounted) return;
    if (_searchExpanded) _setSearchExpanded(false);
    setState(() {
      _nowPlayingSheetMounted = true;
      _nowPlayingForceOneLine = true;
    });
  }

  /// 시트 닫기 시작 — 1줄 강제 해제해서 탭바가 스크롤 때처럼 펼쳐진다.
  void _beginCollapseNowPlaying() {
    if (!_nowPlayingForceOneLine) return;
    setState(() => _nowPlayingForceOneLine = false);
  }

  void _unmountNowPlayingSheet() {
    if (!_nowPlayingSheetMounted && !_nowPlayingForceOneLine) return;
    setState(() {
      _nowPlayingSheetMounted = false;
      _nowPlayingForceOneLine = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.yggSurfaceBase;
    final active = HomeworkSession.instance.active;
    final sessionBusy = HomeworkSession.instance.busy;
    final scrollCompact = StudentShellChrome.instance.compact;
    // 미니바 있을 때만 1줄 배치. 확장 시트에서는 열림 동안 1줄 강제.
    // 검색 펼치면 미니바를 위로. 닫기 시작 시 강제 해제 → 크롬 애니와 동기.
    final oneLineChrome = active != null &&
        !_searchExpanded &&
        (scrollCompact || _nowPlayingForceOneLine);

    return Scaffold(
      backgroundColor: surface,
      body: Stack(
        fit: StackFit.expand,
        children: [
          IndexedStack(
            index: _index,
            children: const [
              HomeworkScreen(),
              TextbookScreen(),
              ProfileScreen(),
            ],
          ),
          // 전체화면 확장 — 탭바·미니바보다 아래에 깔려 크롬이 위로 남는다.
          // 닫힘 슬라이드가 끝날 때까지 유지한다.
          if (_nowPlayingSheetMounted)
            Positioned.fill(
              child: HomeworkNowPlayingExpanded(
                onCloseBegin: _beginCollapseNowPlaying,
                onClose: _unmountNowPlayingSheet,
                onPlayPause: () => unawaited(handleNowPlayingPlayPause()),
                onSubmit: () => unawaited(handleNowPlayingSubmit()),
              ),
            ),
          Positioned(
            left: StudentBottomNavTokens.horizontalInset,
            right: StudentBottomNavTokens.horizontalInset,
            bottom: StudentBottomNavTokens.bottomInsetOf(context),
            // 미니바 유무와 무관하게 같은 크롬 — 탭바 하단 Y 고정.
            child: _AnimatedBottomChrome(
              oneLine: oneLineChrome,
              searchExpanded: _searchExpanded,
              selectedIndex: _index,
              group: active,
              coverRef: HomeworkSession.instance.coverRef,
              busy: sessionBusy,
              scrollCompact: scrollCompact && active == null,
              onCollapsedNavTap: _onCollapsedNavTap,
              onDestinationSelected: _selectTab,
              onSearchExpandedChanged: _setSearchExpanded,
              onPlayPause: handleNowPlayingPlayPause,
              onSubmit: handleNowPlayingSubmit,
              onExpandNowPlaying: _expandNowPlaying,
              onDismissMiniBar: () => unawaited(_dismissMiniBar()),
            ),
          ),
        ],
      ),
    );
  }
}

/// 미니바가 내려오고, 탭·검색이 좌우로 벌어지는 1줄 전환.
/// 탭/검색은 항상 클러스터 하단에 고정해 미니바 등장 시 Y가 흔들리지 않게 한다.
class _AnimatedBottomChrome extends StatelessWidget {
  const _AnimatedBottomChrome({
    required this.oneLine,
    required this.searchExpanded,
    required this.selectedIndex,
    required this.group,
    required this.coverRef,
    required this.busy,
    required this.scrollCompact,
    required this.onCollapsedNavTap,
    required this.onDestinationSelected,
    required this.onSearchExpandedChanged,
    required this.onPlayPause,
    required this.onSubmit,
    required this.onExpandNowPlaying,
    required this.onDismissMiniBar,
  });

  final bool oneLine;
  final bool searchExpanded;
  final int selectedIndex;
  final HomeworkGroup? group;
  final String? coverRef;
  final bool busy;

  /// 미니바 없을 때 스크롤 축소 (구조 유지 + 스케일만).
  final bool scrollCompact;
  final VoidCallback onCollapsedNavTap;
  final ValueChanged<int> onDestinationSelected;
  final ValueChanged<bool> onSearchExpandedChanged;
  final VoidCallback onPlayPause;
  final VoidCallback onSubmit;
  final VoidCallback onExpandNowPlaying;
  final VoidCallback onDismissMiniBar;

  @override
  Widget build(BuildContext context) {
    final hasNp = group != null;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: oneLine ? 1 : 0),
      duration: StudentBottomNavTokens.chromeAnimDuration,
      curve: Curves.easeInOutCubic,
      builder: (context, t, _) {
        return TweenAnimationBuilder<double>(
          // 검색 펼침/접힘·탭 원형 모프 — 양방향 약한 바운스.
          tween: Tween<double>(end: searchExpanded ? 1 : 0),
          duration: StudentBottomNavTokens.searchAnimDuration,
          curve: StudentBottomNavTokens.searchBounceCurve,
          builder: (context, searchT, _) {
            return TweenAnimationBuilder<double>(
              tween: Tween<double>(
                end: (!hasNp && scrollCompact && !searchExpanded)
                    ? StudentBottomNavTokens.compactScale
                    : 1.0,
              ),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              builder: (context, bareScale, _) {
                return _buildChrome(
                  context,
                  t: t,
                  searchT: searchT,
                  bareScale: bareScale,
                  hasNp: hasNp,
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildChrome(
    BuildContext context, {
    required double t,
    required double searchT,
    required double bareScale,
    required bool hasNp,
  }) {
    final spreadT = const Interval(
      0.0,
      0.52,
      curve: Curves.easeInOutCubic,
    ).transform(t);
    final liftT = const Interval(
      0.38,
      1.0,
      curve: Curves.easeOutCubic,
    ).transform(t);
    final scaleT = const Interval(
      0.38,
      1.0,
      curve: Curves.easeOut,
    ).transform(t);

    // 미니바 있을 때만 1줄 스케일, 없을 때는 bareScale.
    final scale = hasNp
        ? lerpDouble(1, StudentBottomNavTokens.compactScale, scaleT)!
        : bareScale;
    final barH = StudentBottomNavTokens.height * scale;
    final npH = HomeworkNowPlayingBar.height * scale;
    final gap = StudentBottomNavTokens.searchGap * scale;

    final tabCount = StudentBottomNavBar.destinations.length;
    final tabExpandedW = StudentBottomNavTokens.tabWidth * tabCount.toDouble();

    // 검색 펼침(searchT)에 맞춰 탭 슬롯도 원형 너비로 줄인다.
    // (collapsed만 true이고 슬롯이 그대로면 원형 탭과 검색바 사이가 벌어짐)
    final tabFullW0 = !hasNp ? tabExpandedW * scale : tabExpandedW;
    // 양방향 바운스: 펼침 e>1, 축소 e<0 — 치수는 안전 범위로 클램프.
    final bounceT = searchT.clamp(-0.12, 1.15);
    final tabW0 = lerpDouble(tabFullW0, barH, bounceT)!
        .clamp(barH * 0.92, tabFullW0 * 1.08);
    final tabW1 = barH;
    final tabW = lerpDouble(tabW0, tabW1, hasNp ? spreadT : 0)!;

    final searchExpandedW =
        (MediaQuery.sizeOf(context).width / 3).clamp(160.0, 280.0);
    final searchCircle = StudentBottomNavTokens.height * scale;
    // searchT로 클러스터/슬롯 너비 보간 (버튼 자체는 animateSize로 모프).
    final searchWStacked = lerpDouble(searchCircle, searchExpandedW, bounceT)!
        .clamp(searchCircle * 0.92, searchExpandedW * 1.12);

    final npW0 = 420.0;
    final npW1 = StudentBottomNavTokens.nowPlayingCompactMaxWidth;
    final npW = lerpDouble(npW0, npW1, spreadT)!;

    const shadowPad = StudentBottomNavTokens.shadowExtent;
    final gap0 = StudentBottomNavTokens.searchGap * scale;

    // 탭은 항상 클러스터 하단에 고정 (미니바 등장 시 화면 Y 불변).
    final aboveTab = hasNp ? lerpDouble(npH + gap, 0.0, liftT)! : 0.0;
    final clusterH = aboveTab + barH + shadowPad * 2;
    final bottomRowW0 = tabW0 + gap0 + searchWStacked;
    final clusterW0 =
        hasNp ? (bottomRowW0 > npW0 ? bottomRowW0 : npW0) : bottomRowW0;
    final clusterW1 = tabW1 + gap + npW1 + gap + searchCircle;
    final clusterW = hasNp
        ? lerpDouble(clusterW0, clusterW1, spreadT)! + shadowPad * 2
        : bottomRowW0 + shadowPad * 2;

    final contentLeft = shadowPad;
    final tabT = clusterH - shadowPad - barH;
    final searchTTop = tabT;

    // 2줄: NP는 탭 위. 1줄: NP는 탭과 같은 Y.
    final npT = lerpDouble(tabT - gap - npH, tabT, liftT)!;
    final bottomLeft0 = contentLeft + (clusterW0 - bottomRowW0) / 2;
    final tabL0 = bottomLeft0;
    final searchL0 = bottomLeft0 + tabW0 + gap0;
    final npL0 = contentLeft + (clusterW0 - npW0) / 2;

    final tabL1 = contentLeft;
    final npL1 = contentLeft + tabW1 + gap;
    final searchL1 = contentLeft + tabW1 + gap + npW1 + gap;

    final tabL = hasNp ? lerpDouble(tabL0, tabL1, spreadT)! : tabL0;
    final npL = lerpDouble(npL0, npL1, spreadT)!;
    final searchL = hasNp ? lerpDouble(searchL0, searchL1, spreadT)! : searchL0;

    // 검색 펼침이면 원형. 1줄 미니바 배치(t)에서도 원형.
    final navCollapsed =
        hasNp ? (searchExpanded || t > 0.55) : searchExpanded;
    // 검색 모프는 탭바 자체 width 애니와 슬롯(searchT)을 같이 씀.
    // 1줄 전환만 할 때는 부모가 tabW로 크기를 밀어 animateSize는 끈다.
    final navAnimateSize = searchExpanded || searchT > 0.01;

    // Center면 가용 높이 중앙 정렬 → 미니바 높이만큼 탭 Y가 흔들림.
    // 하단 고정으로 클러스터가 위로만 자라게 한다.
    return Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        width: clusterW,
        height: clusterH,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (hasNp)
              Positioned(
                left: npL,
                top: npT,
                width: npW,
                height: npH,
                child: _SwipeDownDismiss(
                  onDismiss: onDismissMiniBar,
                  child: HomeworkNowPlayingBar(
                    group: group!,
                    coverRef: coverRef,
                    busy: busy,
                    inline: t > 0.5,
                    scale: scale,
                    width: npW,
                    onPlayPause: onPlayPause,
                    onSubmit: onSubmit,
                    onExpand: onExpandNowPlaying,
                  ),
                ),
              ),
            Positioned(
              left: tabL - shadowPad,
              top: tabT - shadowPad,
              width: tabW + shadowPad * 2,
              height: barH + shadowPad * 2,
              child: Padding(
                padding: const EdgeInsets.all(shadowPad),
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  maxWidth: tabExpandedW * scale + 8,
                  child: StudentBottomNavBar(
                    selectedIndex: selectedIndex,
                    collapsed: navCollapsed,
                    scale: scale,
                    animateSize: navAnimateSize,
                    onCollapsedTap: onCollapsedNavTap,
                    onDestinationSelected: onDestinationSelected,
                  ),
                ),
              ),
            ),
            Positioned(
              left: searchL - shadowPad,
              top: searchTTop - shadowPad,
              height: barH + shadowPad * 2,
              child: Padding(
                padding: const EdgeInsets.all(shadowPad),
                child: StudentBottomNavSearchButton(
                  // 1줄일 땐 원형 유지, 2줄로 돌아온 뒤 펼침 애니.
                  expanded: searchExpanded && t < 0.35,
                  scale: scale,
                  animateSize: true,
                  onExpandedChanged: onSearchExpandedChanged,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 미니바를 아래로 스와이프하면 닫기.
class _SwipeDownDismiss extends StatefulWidget {
  const _SwipeDownDismiss({
    required this.child,
    required this.onDismiss,
  });

  final Widget child;
  final VoidCallback onDismiss;

  @override
  State<_SwipeDownDismiss> createState() => _SwipeDownDismissState();
}

class _SwipeDownDismissState extends State<_SwipeDownDismiss> {
  double _dy = 0;

  /// 초반엔 거의 선명, 중반 넘기면 급격히 사라짐 (easeInCubic).
  double _opacityFor(double dy) {
    final t = (dy / 110).clamp(0.0, 1.0);
    if (t <= 0.45) {
      // 0 → 0.45: 1.0 → ~0.92
      return 1.0 - (t / 0.45) * 0.08;
    }
    final u = ((t - 0.45) / 0.55).clamp(0.0, 1.0);
    return 0.92 * (1.0 - Curves.easeInCubic.transform(u));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: (details) {
        if (details.delta.dy < 0 && _dy <= 0) return;
        setState(() => _dy = (_dy + details.delta.dy).clamp(0.0, 140.0));
      },
      onVerticalDragEnd: (details) {
        final shouldDismiss =
            _dy > 48 || details.velocity.pixelsPerSecond.dy > 700;
        if (shouldDismiss) {
          widget.onDismiss();
        }
        setState(() => _dy = 0);
      },
      onVerticalDragCancel: () => setState(() => _dy = 0),
      child: Opacity(
        opacity: _opacityFor(_dy),
        child: Transform.translate(
          offset: Offset(0, _dy),
          child: widget.child,
        ),
      ),
    );
  }
}
