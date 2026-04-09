import 'package:flutter/material.dart';
import 'memo_dialogs.dart';
import 'payment_management_dialog.dart';
import 'makeup_quick_dialog.dart';
import '../app_overlays.dart';

/// 홈 하단 **확인** FAB·M5 **질문 칩**이 같은 레이아웃 경로(`GestureDetector` → 고정 `SizedBox` → `Container`)를 쓰도록 통일.
/// Scaffold FAB 슬롯과 본문 하단은 배치만 다를 뿐, 픽셀 치수는 동일해야 한다.
class HomeBottomActionPill extends StatelessWidget {
  static const double pillWidth = 140;
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
  double _fabBottomPadding = 16.0;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>?
      _snackBarController;
  OverlayEntry? _menuOverlay; // FAB 확장 시 드롭다운 버튼을 오버레이로 표시

  @override
  void initState() {
    super.initState();
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

  @override
  void dispose() {
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
        // FAB 위치 기준: 오른쪽 16, 아래쪽(_fabBottomPadding + FAB 높이 56 + 간격 12)
        final double bottomOffset = _fabBottomPadding + 56 + 12;
        return Positioned(
          right: 16,
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
                    onTap: () {
                      _openMemoAddDialog(context);
                    },
                  ),
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
  }) {
    return SlideTransition(
      position: slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1B6B63),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    spreadRadius: 1,
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 28),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: Colors.white, size: 28),
                  const SizedBox(width: 14),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
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
      valueListenable: homeBatchConfirmFabVisible,
      builder: (context, showBatchConfirmFab, _) {
        return ValueListenableBuilder<int>(
          valueListenable: homeBatchConfirmPendingCount,
          builder: (context, pendingConfirmCount, __) {
            final shouldShowBatchConfirmFab =
                widget.showHomeBatchConfirmFab && showBatchConfirmFab;
            final canRunBatchConfirm = shouldShowBatchConfirmFab &&
                pendingConfirmCount > 0 &&
                homeBatchConfirmAction != null;
            return AnimatedPadding(
              duration: const Duration(milliseconds: 200),
              padding: EdgeInsets.only(bottom: _fabBottomPadding, right: 16.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (shouldShowBatchConfirmFab) ...[
                    Opacity(
                      opacity: canRunBatchConfirm ? 1.0 : 0.45,
                      child: IgnorePointer(
                        ignoring: !canRunBatchConfirm,
                        child: HomeBottomActionPill(
                          backgroundColor: const Color(0xFF1B6B63),
                          onTap: () async {
                            final action = homeBatchConfirmAction;
                            if (action == null) return;
                            await action();
                          },
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.check_rounded,
                                size: 21,
                                color: Colors.white,
                              ),
                              SizedBox(width: 8),
                              Text(
                                '확인',
                                style: TextStyle(
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
                  Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // 메뉴 버튼들은 오버레이에서 렌더링 (항상 최상단)
                      // 🎯 메인 FAB 버튼 (직사각형 -> 원형 모양 변화)
                      AnimatedBuilder(
                        animation: _fabController,
                        builder: (context, child) {
                          return GestureDetector(
                            onTap: () {
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
                            child: Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                color: const Color(0xFF1B6B63),
                                borderRadius: BorderRadius.circular(
                                    _shapeAnimation.value), // 동적으로 변하는 모서리
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.2),
                                    spreadRadius: 1,
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Center(
                                child: AnimatedRotation(
                                  duration: const Duration(milliseconds: 200),
                                  turns: _isFabExpanded ? 0.125 : 0,
                                  child: Icon(
                                    _isFabExpanded ? Icons.close : Icons.add,
                                    size: 24,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
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
