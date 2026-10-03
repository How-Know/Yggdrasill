import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'memo_dialogs.dart';
import 'payment_management_dialog.dart';
import 'makeup_quick_dialog.dart';
import '../app_overlays.dart';
import 'app_confirm_button.dart';
import 'home_grading_history_icon.dart';
import 'solid_capsule_action_bar.dart';
import 'dialog_tokens.dart';
import '../services/exam_mode.dart';
import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

/// 홈 하단 **확인** FAB·M5 **질문 칩**이 같은 레이아웃 경로(`GestureDetector` → 고정 `SizedBox` → `Container`)를 쓰도록 통일.
/// Scaffold FAB 슬롯과 본문 하단은 배치만 다를 뿐, 픽셀 치수는 동일해야 한다.
class HomeBottomActionPill extends StatelessWidget {
  static const double pillWidth = 120;
  static const double pillHeight = 56;
  static const double pillRadius = 28;

  final Color backgroundColor;
  final VoidCallback onTap;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double width;
  final bool showShadow;

  const HomeBottomActionPill({
    super.key,
    required this.backgroundColor,
    required this.onTap,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.width = pillWidth,
    this.showShadow = true,
  });

  static List<BoxShadow> pillBoxShadow() => [
        BoxShadow(
          color: Colors.black.withOpacity(0.2),
          spreadRadius: 1,
          blurRadius: 4,
          offset: const Offset(0, 2),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: width,
        height: pillHeight,
        child: Container(
          alignment: Alignment.center,
          padding: padding,
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(pillRadius),
            boxShadow: showShadow ? pillBoxShadow() : null,
          ),
          child: child,
        ),
      ),
    );
  }
}

class MainFabAlternative extends StatefulWidget {
  final bool showHomeBatchConfirmFab;

  const MainFabAlternative({
    Key? key,
    this.showHomeBatchConfirmFab = false,
  }) : super(key: key);

  @override
  State<MainFabAlternative> createState() => _MainFabAlternativeState();
}

class _MainFabAlternativeState extends State<MainFabAlternative> {
  @override
  void initState() {
    super.initState();
    gradingModeActive.addListener(_onGradingModeChanged);
  }

  void _onGradingModeChanged() {
    if (gradingModeActive.value) {
      collapseNavRailPlusMenu?.call();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    gradingModeActive.removeListener(_onGradingModeChanged);
    super.dispose();
  }

  double _fabLeftInset(BuildContext context) {
    final railWidth = NavigationRailTheme.of(context).minWidth ??
        FabTabBarTokens.fabBarNavRailDefaultWidth;
    return railWidth + FabTabBarTokens.fabBarLeftInsetFromNavRail;
  }

  Widget _buildHistoryButton() {
    final brightness = Theme.of(context).brightness;
    const hit = 40.0;
    return Tooltip(
      message: '이전 채점',
      child: SolidCapsuleActionBar(
        padding: const EdgeInsets.all(8),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final action = homeGradingHistoryAction;
            if (action != null) unawaited(action());
          },
          child: SizedBox(
            width: hit,
            height: hit,
            child: Center(
              child: SvgPicture.string(
                homeGradingHistorySvg,
                width: 25,
                height: 25,
                colorFilter: ColorFilter.mode(
                  SolidCapsuleActionBarTokens.iconColor(brightness),
                  BlendMode.srcIn,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: gradingModeActive,
      builder: (context, _, __) {
        return ValueListenableBuilder<bool>(
          valueListenable: homeBatchConfirmFabVisible,
          builder: (context, showBatchConfirmFab, __) {
            return ValueListenableBuilder<int>(
              valueListenable: homeBatchConfirmPendingCount,
              builder: (context, pendingConfirmCount, ___) {
                return ValueListenableBuilder<int>(
                  valueListenable: homeBatchConfirmDraftSavingCount,
                  builder: (context, draftSavingCount, ____) {
                    final shouldShowBatchConfirmFab =
                        widget.showHomeBatchConfirmFab &&
                            showBatchConfirmFab;
                    final canRunBatchConfirm = shouldShowBatchConfirmFab &&
                        pendingConfirmCount > 0 &&
                        homeBatchConfirmAction != null;
                    final screenWidth =
                        MediaQuery.sizeOf(context).width;
                                final leftInset = _fabLeftInset(context);
                                final barWidth = (screenWidth -
                                        leftInset -
                                        FabTabBarTokens.fabBarRightInset)
                                    .clamp(0.0, double.infinity);
                                return SizedBox(
                                  width: barWidth,
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      const SizedBox.shrink(),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          if (gradingModeActive.value) ...[
                                            _buildHistoryButton(),
                                            if (shouldShowBatchConfirmFab)
                                              const SizedBox(width: 12),
                                          ],
                                          if (shouldShowBatchConfirmFab)
                                            Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                if (draftSavingCount > 0) ...[
                                                  const YggLoadingIndicator(
                                                    size: 22,
                                                  ),
                                                  const SizedBox(height: 8),
                                                ],
                                                AppConfirmButton(
                                                  enabled: canRunBatchConfirm,
                                                  onPressed: () async {
                                                    final action =
                                                        homeBatchConfirmAction;
                                                    if (action == null) return;
                                                    await action();
                                                  },
                                                ),
                                              ],
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

}

/// 시험일정 버튼 등이 레일 위 + 메뉴를 접을 때 호출한다.
VoidCallback? collapseNavRailPlusMenu;

bool navRailExamButtonVisible({
  required bool hidden,
  required bool examOn,
  required bool suppressExam,
}) {
  return !hidden && examOn && !suppressExam;
}

/// 시험기간에 네비게이션 레일 + 버튼 위에 뜨는 시험 버튼.
class NavRailExamButton extends StatelessWidget {
  const NavRailExamButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: hideGlobalMainFab,
      builder: (context, hidden, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: ExamModeService.instance.isOn,
          builder: (context, examOn, _) {
            return ValueListenableBuilder<bool>(
              valueListenable:
                  ExamModeService.instance.suppressExamActionCluster,
              builder: (context, suppressExam, _) {
                return ValueListenableBuilder<bool>(
                  valueListenable:
                      ExamModeService.instance.examScheduleDialogOpen,
                  builder: (context, dialogOpen, _) {
                    if (!navRailExamButtonVisible(
                      hidden: hidden,
                      examOn: examOn,
                      suppressExam: suppressExam,
                    )) {
                      return const SizedBox.shrink();
                    }
                    final enabled = examScheduleAction != null && !dialogOpen;
                    return Padding(
                      padding: const EdgeInsets.only(
                        bottom: FabTabBarTokens.navRailPlusGap,
                      ),
                      child: Opacity(
                        opacity: enabled ? 1 : 0.45,
                        child: IgnorePointer(
                          ignoring: !enabled,
                          child: FabStyleActionButton(
                            label: '시험',
                            onPressed: () {
                              collapseNavRailPlusMenu?.call();
                              final action = examScheduleAction;
                              if (action != null) unawaited(action());
                            },
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

/// 네비게이션 레일 하단, 프로필 버튼 위의 + 버튼.
class NavRailPlusButton extends StatefulWidget {
  const NavRailPlusButton({super.key});

  @override
  State<NavRailPlusButton> createState() => _NavRailPlusButtonState();
}

class _NavRailPlusButtonState extends State<NavRailPlusButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _fabController;
  late Animation<Offset> _slideAnimation1;
  late Animation<Offset> _slideAnimation2;
  late Animation<Offset> _slideAnimation3;
  late Animation<double> _fadeAnimation;

  bool _isFabExpanded = false;
  OverlayEntry? _menuOverlay;
  late final VoidCallback _collapseMenu;

  @override
  void initState() {
    super.initState();
    _collapseMenu = _collapseFabMenu;
    collapseNavRailPlusMenu = _collapseMenu;
    gradingModeActive.addListener(_hideIfNeeded);
    hideGlobalMainFab.addListener(_hideIfNeeded);
    _fabController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fabController, curve: Curves.easeOut),
    );
    _slideAnimation1 = Tween<Offset>(
      begin: const Offset(0, 1.2),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _fabController,
      curve: const Interval(0.0, 0.8, curve: Curves.easeOutBack),
    ));
    _slideAnimation2 = Tween<Offset>(
      begin: const Offset(0, 1.2),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _fabController,
      curve: const Interval(0.1, 0.9, curve: Curves.easeOutBack),
    ));
    _slideAnimation3 = Tween<Offset>(
      begin: const Offset(0, 1.2),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _fabController,
      curve: const Interval(0.2, 1.0, curve: Curves.easeOutBack),
    ));
  }

  void _hideIfNeeded() {
    if ((gradingModeActive.value || hideGlobalMainFab.value) &&
        _isFabExpanded) {
      _collapseFabMenu();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (identical(collapseNavRailPlusMenu, _collapseMenu)) {
      collapseNavRailPlusMenu = null;
    }
    gradingModeActive.removeListener(_hideIfNeeded);
    hideGlobalMainFab.removeListener(_hideIfNeeded);
    _removeMenuOverlay();
    _fabController.dispose();
    super.dispose();
  }

  double _plusLeft(BuildContext context) {
    final railWidth = NavigationRailTheme.of(context).minWidth ??
        FabTabBarTokens.fabBarNavRailDefaultWidth;
    return (railWidth - FabTabBarTokens.fabBarHeight) / 2;
  }

  void _insertMenuOverlay(BuildContext context) {
    if (_menuOverlay != null && _menuOverlay!.mounted) {
      _menuOverlay!.remove();
    }
    _menuOverlay = OverlayEntry(
      builder: (ctx) {
        return ValueListenableBuilder<bool>(
          valueListenable: ExamModeService.instance.isOn,
          builder: (_, examOn, __) {
            return ValueListenableBuilder<bool>(
              valueListenable:
                  ExamModeService.instance.suppressExamActionCluster,
              builder: (_, suppressExam, __) {
                return ValueListenableBuilder<bool>(
                  valueListenable: hideGlobalMainFab,
                  builder: (_, hidden, __) {
                    final examVisible = navRailExamButtonVisible(
                      hidden: hidden,
                      examOn: examOn,
                      suppressExam: suppressExam,
                    );
                    var bottomOffset = FabTabBarTokens.navRailPlusBottomInset +
                        FabTabBarTokens.fabBarHeight +
                        FabTabBarTokens.fabMenuItemSpacing;
                    if (examVisible) {
                      bottomOffset += FabTabBarTokens.navRailPlusGap +
                          FabTabBarTokens.fabBarHeight;
                    }
                    return Positioned(
          left: _plusLeft(ctx),
          bottom: bottomOffset,
          child: IgnorePointer(
            ignoring: !_isFabExpanded,
            child: Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildMenuButton(
                    label: '메모',
                    icon: Icons.edit_note,
                    slideAnimation: _slideAnimation3,
                    useFullIconSize: true,
                    onTap: () {
                      _openMemoAddDialog(context);
                    },
                  ),
                  const SizedBox(height: FabTabBarTokens.fabMenuItemSpacing),
                  _buildMenuButton(
                    label: '보강',
                    icon: Icons.event_repeat_rounded,
                    slideAnimation: _slideAnimation2,
                    onTap: () {
                      _collapseFabMenu();
                      showMakeupRegisterDialog(context);
                    },
                  ),
                  const SizedBox(height: FabTabBarTokens.fabMenuItemSpacing),
                  _buildMenuButton(
                    label: '수강',
                    icon: Icons.credit_card,
                    slideAnimation: _slideAnimation1,
                    onTap: () {
                      _collapseFabMenu();
                      showPaymentManagementDialog(context);
                    },
                  ),
                ],
              ),
            ),
          ),
        );
                  },
                );
              },
            );
          },
        );
      },
    );
    final overlay = fabDropdownOverlayKey.currentState;
    if (overlay == null) {
      final entry = _menuOverlay!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_isFabExpanded) return;
        final overlay2 = fabDropdownOverlayKey.currentState;
        if (overlay2 == null) return;
        if (!entry.mounted) {
          overlay2.insert(entry);
        }
      });
      return;
    }
    overlay.insert(_menuOverlay!);
  }

  void _removeMenuOverlay() {
    if (_menuOverlay != null && _menuOverlay!.mounted) {
      _menuOverlay!.remove();
    }
    _menuOverlay = null;
  }

  void _collapseFabMenu() {
    if (!mounted) return;
    setState(() {
      _isFabExpanded = false;
      _fabController.reverse();
      _removeMenuOverlay();
    });
  }

  Widget _buildMenuButton({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
    required Animation<Offset> slideAnimation,
    bool useFullIconSize = false,
  }) {
    return SlideTransition(
      position: slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: FabStyleMenuPill(
          label: label,
          icon: icon,
          onTap: onTap,
          useFullIconSize: useFullIconSize,
        ),
      ),
    );
  }

  Future<void> _openMemoAddDialog(BuildContext context) async {
    _collapseFabMenu();
    try {
      final result = await showDialog<MemoCreateResult>(
        context: context,
        barrierDismissible: true,
        useRootNavigator: true,
        builder: (_) => const MemoInputDialog(),
      );
      if (result == null) return;
      await addMemoFromCreateResult(result);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('메모가 추가되었습니다.'),
          backgroundColor: Color(0xFF2A2A2A),
          behavior: SnackBarBehavior.fixed,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('메모 추가 실패: $e'),
            backgroundColor: const Color(0xFFE53E3E),
            behavior: SnackBarBehavior.fixed,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: hideGlobalMainFab,
      builder: (context, hidden, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: gradingModeActive,
          builder: (context, grading, _) {
            if (hidden || grading) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(
                bottom: FabTabBarTokens.navRailPlusGap,
              ),
              child: AnimatedBuilder(
                animation: _fabController,
                builder: (context, child) {
                  return FabStyleActionButton(
                    icon: _isFabExpanded ? Icons.close : Icons.add,
                    onPressed: () {
                      setState(() {
                        _isFabExpanded = !_isFabExpanded;
                        if (_isFabExpanded) {
                          _fabController.forward();
                          _insertMenuOverlay(context);
                        } else {
                          _fabController.reverse();
                          _removeMenuOverlay();
                        }
                      });
                    },
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}
