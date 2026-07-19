import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../widgets/student_navigation_rail.dart';
import 'homework_screen.dart';
import 'profile_screen.dart';
import 'textbook_screen.dart';

/// 좌측 NavigationRail + 본문. (아이패드 가로/세로 공통)
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
      body: SafeArea(
        child: Row(
          children: [
            StudentNavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
            ),
            Expanded(
              child: IndexedStack(
                index: _index,
                children: const [
                  HomeworkScreen(),
                  TextbookScreen(),
                  ProfileScreen(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
