import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

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

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final surface = context.yggSurfaceBase;
    return Scaffold(
      backgroundColor: surface,
      // SafeArea 없음 — 본문이 아일랜드·하단 탭바 영역까지 확장.
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
          Positioned(
            left: StudentBottomNavTokens.horizontalInset,
            right: StudentBottomNavTokens.horizontalInset,
            bottom: StudentBottomNavTokens.bottomInset +
                MediaQuery.paddingOf(context).bottom,
            child: Center(
              child: StudentBottomNavBar(
                selectedIndex: _index,
                onDestinationSelected: (i) => setState(() => _index = i),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
