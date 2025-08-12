import 'package:flutter/material.dart';
import 'payment_management_dialog.dart';
import 'makeup_quick_dialog.dart';

class MainFabAlternative extends StatefulWidget {
  const MainFabAlternative({Key? key}) : super(key: key);

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
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _snackBarController;
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
    setState(() {
      _fabBottomPadding = 80.0 + 16.0;
    });
    _snackBarController = ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF2A2A2A),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 16.0, right: 16.0, left: 16.0),
        duration: const Duration(seconds: 2),
      ),
    );
    _snackBarController?.closed.then((_) {
      if (mounted) {
        setState(() {
          _fabBottomPadding = 16.0;
        });
      }
    });
  }

  void _insertMenuOverlay(BuildContext context) {
    _menuOverlay?.remove();
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
                  // 위에서부터: 상담 -> 보강 -> 수강
                  _buildMenuButton(
                    label: '상담',
                    icon: Icons.chat_outlined,
                    slideAnimation: _slideAnimation3,
                    onTap: () {
                      _showFloatingSnackBar(context, '상담 기능');
                    },
                  ),
                  _buildMenuButton(
                    label: '보강',
                    icon: Icons.event_repeat_rounded,
                    slideAnimation: _slideAnimation2,
                    onTap: () {
                      showDialog(
                        context: context,
                        barrierDismissible: true,
                        builder: (context) => const MakeupQuickDialog(),
                      ).then((_) {
                        setState(() {
                          _isFabExpanded = false;
                          _fabController.reverse();
                          _removeMenuOverlay();
                        });
                      });
                    },
                  ),
                  _buildMenuButton(
                    label: '수강',
                    icon: Icons.credit_card,
                    slideAnimation: _slideAnimation1,
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (context) => PaymentManagementDialog(
                          onClose: () {
                            setState(() {
                              _isFabExpanded = false;
                              _fabController.reverse();
                              _removeMenuOverlay();
                            });
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
    Overlay.of(context).insert(_menuOverlay!);
  }

  void _removeMenuOverlay() {
    _menuOverlay?.remove();
    _menuOverlay = null;
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
                color: const Color(0xFF1976D2),
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
    return AnimatedPadding(
      duration: const Duration(milliseconds: 200),
      padding: EdgeInsets.only(bottom: _fabBottomPadding, right: 16.0),
      child: Column(
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
                    color: const Color(0xFF1976D2),
                    borderRadius: BorderRadius.circular(_shapeAnimation.value), // 동적으로 변하는 모서리
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
    );
  }
}