import 'dart:async';

import 'package:flutter/material.dart';
import 'memo_dialogs.dart';
import 'payment_management_dialog.dart';
import 'makeup_quick_dialog.dart';
import '../app_overlays.dart';
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

  const HomeBottomActionPill({
    super.key,
    required this.backgroundColor,
    required this.onTap,
    required this.child,
    this.padding = EdgeInsets.zero,
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
        width: pillWidth,
        height: pillHeight,
        child: Container(
          alignment: Alignment.center,
          padding: padding,
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(pillRadius),
            boxShadow: pillBoxShadow(),
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

class _MainFabAlternativeState extends State<MainFabAlternative>
    with SingleTickerProviderStateMixin {
  late AnimationController _fabController;
  late Animation<double> _rotationAnimation;
  late Animation<Offset> _slideAnimation1;
  late Animation<Offset> _slideAnimation2;
  late Animation<Offset> _slideAnimation3;
  late Animation<double> _fadeAnimation;
  late Animation<double> _shapeAnimation; // 직사각형 -> 원형 애니메이션

  bool _isFabExpanded = false;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>?
      _snackBarController;
  OverlayEntry? _menuOverlay; // FAB 확장 시 드롭다운 버튼을 오버레이로 표시

  @override
  void initState() {
    super.initState();
    gradingModeActive.addListener(_onGradingModeChanged);
    _fabController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );

    // 회전 애니메이션 (+ -> X)
    _rotationAnimation = Tween<double>(begin: 0.0, end: 0.125).animate(
      CurvedAnimation(parent: _fabController, curve: Curves.easeInOut),
    );

    // 페이드 애니메이션
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fabController, curve: Curves.easeOut),
    );

    // 🎯 직사각형 -> 원형 모양 변화 애니메이션
    _shapeAnimation = Tween<double>(begin: 16.0, end: 28.0).animate(
      CurvedAnimation(parent: _fabController, curve: Curves.easeInOut),
    );

    // 아래에서 위로 슬라이드 애니메이션 (3개 버튼용 - 엇갈린 타이밍)
    _slideAnimation1 = Tween<Offset>(
      begin: const Offset(0, 1.2), // 수강 (가장 아래, 첫 번째로 나타남)
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _fabController,
      curve: const Interval(0.0, 0.8, curve: Curves.easeOutBack), // 부드럽게 튀어나옴
    ));

    _slideAnimation2 = Tween<Offset>(
      begin: const Offset(0, 1.2), // 보강 (중간, 두 번째로 나타남)
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _fabController,
      curve: const Interval(0.1, 0.9, curve: Curves.easeOutBack), // 약간 늦게 시작
    ));

    _slideAnimation3 = Tween<Offset>(
      begin: const Offset(0, 1.2), // 상담 (가장 위, 마지막에 나타남)
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _fabController,
      curve: const Interval(0.2, 1.0, curve: Curves.easeOutBack), // 가장 늦게 시작
    ));
  }

  void _onGradingModeChanged() {
    if (gradingModeActive.value && _isFabExpanded) {
      _collapseFabMenu();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    gradingModeActive.removeListener(_onGradingModeChanged);
    _removeMenuOverlay();
    _fabController.dispose();
    super.dispose();
  }

  void _showFloatingSnackBar(BuildContext context, String message) {
    _snackBarController = ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF2A2A2A),
        behavior: SnackBarBehavior.fixed,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _insertMenuOverlay(BuildContext context) {
    // 삽입되지 않은 OverlayEntry에 remove()를 호출하면 assert가 발생하므로 mounted 체크
    if (_menuOverlay != null && _menuOverlay!.mounted) {
      _menuOverlay!.remove();
    }
    _menuOverlay = OverlayEntry(
      builder: (ctx) {
        // + 버튼 상단 ↔ 수강 pill 하단 = [fabMenuItemSpacing] (pill 간격과 동일)
        final double bottomOffset = FabTabBarTokens.fabBarBottomInset +
            FabTabBarTokens.fabBarHeight +
            FabTabBarTokens.fabMenuItemSpacing;
        return Positioned(
          right: FabTabBarTokens.fabBarRightInset,
          bottom: bottomOffset,
          child: IgnorePointer(
            ignoring: !_isFabExpanded,
            child: Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 위에서부터: 메모 -> 보강 -> 수강
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
                      // ✅ 즉시 드롭다운 닫기(다이얼로그가 열려있는 동안에도 FAB 메뉴가 남지 않게)
                      _collapseFabMenu();
                      showDialog(
                        context: context,
                        barrierDismissible: true,
                        builder: (context) => const MakeupQuickDialog(),
                      );
                    },
                  ),
                  const SizedBox(height: FabTabBarTokens.fabMenuItemSpacing),
                  _buildMenuButton(
                    label: '수강',
                    icon: Icons.credit_card,
                    slideAnimation: _slideAnimation1,
                    onTap: () {
                      // ✅ 수강료 결제 관리 다이얼로그를 열면 드롭다운을 즉시 접는다
                      _collapseFabMenu();
                      showDialog(
                        context: context,
                        builder: (context) => PaymentManagementDialog(
                          onClose: () {
                            _collapseFabMenu();
                          },
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    // 전용 레이어에 삽입:
    // - 플로팅 메모 배너보다 위
    // - 오른쪽 사이드시트(메모 슬라이드)보다 아래
    //
    // rootOverlay로 fallback하면 다시 사이드시트 "위"에 뜨므로 fallback 금지.
    final overlay = fabDropdownOverlayKey.currentState;
    if (overlay == null) {
      // 첫 프레임/리빌드 타이밍에 아직 레이어가 준비되지 않았을 수 있어 다음 프레임에 재시도
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
    // 삽입되지 않은 OverlayEntry에 remove()를 호출하면 assert가 발생하므로 mounted 체크
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

  Widget _buildPrimaryFabButton() {
    if (gradingModeActive.value) {
      return FabStyleActionButton(
        icon: Icons.history_rounded,
        onPressed: () {
          final action = homeGradingHistoryAction;
          if (action != null) unawaited(action());
        },
      );
    }
    return AnimatedBuilder(
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
    );
  }

  Widget _buildExamFabButton({
    required bool enabled,
    required bool dialogOpen,
  }) {
    return Opacity(
      opacity: enabled && !dialogOpen ? 1.0 : 0.45,
      child: IgnorePointer(
        ignoring: !enabled || dialogOpen,
        child: FabStyleActionButton(
          icon: Icons.event_note_rounded,
          onPressed: () {
            _collapseFabMenu();
            final action = examScheduleAction;
            if (action != null) unawaited(action());
          },
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
                return ValueListenableBuilder<bool>(
                  valueListenable: ExamModeService.instance.isOn,
                  builder: (context, examModeOn, ____) {
                    return ValueListenableBuilder<bool>(
                      valueListenable:
                          ExamModeService.instance.suppressExamActionCluster,
                      builder: (context, suppressExamButton, _____) {
                        return ValueListenableBuilder<bool>(
                          valueListenable:
                              ExamModeService.instance.examScheduleDialogOpen,
                          builder: (context, examScheduleDialogOpen, ______) {
                            final shouldShowBatchConfirmFab =
                                widget.showHomeBatchConfirmFab &&
                                    showBatchConfirmFab;
                            final canRunBatchConfirm =
                                shouldShowBatchConfirmFab &&
                                    pendingConfirmCount > 0 &&
                                    homeBatchConfirmAction != null;
                            final shouldShowExamFab =
                                examModeOn && !suppressExamButton;
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                if (shouldShowBatchConfirmFab) ...[
                                  Opacity(
                                    opacity: canRunBatchConfirm ? 1.0 : 0.45,
                                    child: IgnorePointer(
                                      ignoring: !canRunBatchConfirm,
                                      child: HomeBottomActionPill(
                                        backgroundColor: FabTabBarTokens
                                            .previewConfirmActionColor,
                                        onTap: () async {
                                          final action = homeBatchConfirmAction;
                                          if (action == null) return;
                                          await action();
                                        },
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.check_rounded,
                                              size: 21,
                                              color: Colors.white,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              '반환',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 17,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                ],
                                if (shouldShowExamFab) ...[
                                  _buildExamFabButton(
                                    enabled: examScheduleAction != null,
                                    dialogOpen: examScheduleDialogOpen,
                                  ),
                                  const SizedBox(width: 12),
                                ],
                                Column(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    _buildPrimaryFabButton(),
                                  ],
                                ),
                              ],
                            );
                          },
                        );
                      },
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
      if (mounted) {
        _showFloatingSnackBar(context, '메모가 추가되었습니다.');
      }
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
}
