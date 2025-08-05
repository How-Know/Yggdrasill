import 'package:flutter/material.dart';
import 'package:flutter_speed_dial/flutter_speed_dial.dart';

class MainFab extends StatefulWidget {
  const MainFab({Key? key}) : super(key: key);

  @override
  State<MainFab> createState() => _MainFabState();
}

class _MainFabState extends State<MainFab> {
  double _fabBottomPadding = 16.0;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _snackBarController;

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
    return Padding(
      padding: EdgeInsets.only(bottom: _fabBottomPadding),
      child: SpeedDial(
        icon: Icons.add,
        activeIcon: Icons.close,
        backgroundColor: const Color(0xFF1976D2),
        foregroundColor: Colors.white,
        activeForegroundColor: Colors.white,
        activeBackgroundColor: const Color(0xFF1976D2),
        visible: true,
        closeManually: false,
        // 🎯 아래에서 위로 튀어나오는 부드러운 애니메이션 설정
        curve: Curves.easeOutBack, // 부드럽게 튀어나오는 효과
        overlayColor: Colors.transparent, // 배경 색상 변화 제거
        overlayOpacity: 0.0, // 오버레이 효과 완전 제거
        elevation: 8.0,
        isOpenOnStart: false,
        childPadding: const EdgeInsets.all(5),
        spaceBetweenChildren: 4,
        // 버튼들이 아래에서 위로 나타나는 방향
        direction: SpeedDialDirection.up,
        children: [
          SpeedDialChild(
            child: const Icon(Icons.school, color: Colors.white),
            backgroundColor: const Color(0xFF1976D2),
            foregroundColor: Colors.white,
            label: '수강',
            labelStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
            labelBackgroundColor: const Color(0xFF1976D2),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 4.0,
            onTap: () {
              _showFloatingSnackBar(context, '수강 기능');
            },
          ),
          SpeedDialChild(
            child: const Icon(Icons.chat_outlined, color: Colors.white),
            backgroundColor: const Color(0xFF1976D2),
            foregroundColor: Colors.white,
            label: '상담',
            labelStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
            labelBackgroundColor: const Color(0xFF1976D2),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 4.0,
            onTap: () {
              _showFloatingSnackBar(context, '상담 기능');
            },
          ),
          SpeedDialChild(
            child: const Icon(Icons.event_repeat_rounded, color: Colors.white),
            backgroundColor: const Color(0xFF1976D2),
            foregroundColor: Colors.white,
            label: '보강',
            labelStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
            labelBackgroundColor: const Color(0xFF1976D2),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 4.0,
            onTap: () {
              _showFloatingSnackBar(context, '보강 기능');
            },
          ),
        ],
      ),
    );
  }
}