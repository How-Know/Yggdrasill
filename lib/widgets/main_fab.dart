import 'package:flutter/material.dart';

class MainFab extends StatefulWidget {
  const MainFab({Key? key}) : super(key: key);

  @override
  State<MainFab> createState() => _MainFabState();
}

class _MainFabState extends State<MainFab> with SingleTickerProviderStateMixin {
  late AnimationController _fabController;
  late Animation<double> _fabScaleAnimation;
  late Animation<double> _fabOpacityAnimation;
  bool _isFabExpanded = false;
  double _fabBottomPadding = 16.0;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _snackBarController;

  @override
  void initState() {
    super.initState();
    _fabController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fabScaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _fabController, curve: Curves.easeOut),
    );
    _fabOpacityAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fabController, curve: Curves.easeOut),
    );
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

  @override
  Widget build(BuildContext context) {
    return AnimatedPadding(
      duration: const Duration(milliseconds: 200),
      padding: EdgeInsets.only(bottom: _fabBottomPadding, right: 16.0),
      child: Builder(
        builder: (context) => Column(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (_isFabExpanded) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                child: ScaleTransition(
                  scale: _fabScaleAnimation,
                  child: FadeTransition(
                    opacity: _fabOpacityAnimation,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        GestureDetector(
                          onTap: () {
                            _showFloatingSnackBar(context, '수강 등록 기능');
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF1976D2),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 28),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.add_rounded, color: Colors.white, size: 28),
                                const SizedBox(width: 14),
                                Text(
                                  '수강 등록',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF1976D2),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 28),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.chat_outlined, color: Colors.white, size: 28),
                              const SizedBox(width: 14),
                              Text(
                                '상담',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF1976D2),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 28),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.event_repeat_rounded, color: Colors.white, size: 28),
                              const SizedBox(width: 14),
                              Text(
                                '보강',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            FloatingActionButton(
              heroTag: 'main',
              onPressed: () {
                setState(() {
                  _isFabExpanded = !_isFabExpanded;
                  if (_isFabExpanded) {
                    _fabController.forward();
                  } else {
                    _fabController.reverse();
                  }
                });
              },
              shape: _isFabExpanded 
                ? const CircleBorder()
                : RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: AnimatedRotation(
                duration: const Duration(milliseconds: 200),
                turns: _isFabExpanded ? 0.125 : 0,
                child: Icon(_isFabExpanded ? Icons.close : Icons.add, size: 24),
              ),
            ),
          ],
        ),
      ),
    );
  }
} 