import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/student_api.dart';
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
  bool _questionBusy = false;

  Future<void> _raiseQuestion() async {
    if (_questionBusy) return;
    setState(() => _questionBusy = true);
    try {
      await StudentApi.instance.raiseQuestion();
      if (!mounted) return;
      TopGlassSnackBar.show(
        context,
        message: '선생님께 질문 요청을 보냈어요.',
        icon: Icons.front_hand_rounded,
      );
    } catch (_) {
      if (!mounted) return;
      TopGlassSnackBar.show(
        context,
        message: '질문 요청에 실패했어요. 다시 시도해 주세요.',
        icon: Icons.error_outline_rounded,
      );
    } finally {
      if (mounted) setState(() => _questionBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.yggSurfaceBase;
    return Scaffold(
      backgroundColor: surface,
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              leading: const SizedBox(height: 8),
              trailing: Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: IconButton.filledTonal(
                      tooltip: '선생님께 질문하기',
                      onPressed: _questionBusy ? null : _raiseQuestion,
                      style: IconButton.styleFrom(
                        backgroundColor:
                            YggGlassTokens.confirmActionColor.withValues(
                          alpha: 0.15,
                        ),
                        foregroundColor: YggGlassTokens.confirmActionColor,
                        minimumSize: const Size(56, 56),
                      ),
                      icon: _questionBusy
                          ? const YggLoadingIndicator(size: 20)
                          : const Icon(Icons.front_hand_rounded, size: 26),
                    ),
                  ),
                ),
              ),
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.menu_book_outlined),
                  selectedIcon: Icon(Icons.menu_book_rounded),
                  label: Text('과제'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.edit_note_outlined),
                  selectedIcon: Icon(Icons.edit_note_rounded),
                  label: Text('교재 풀기'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.person_outline_rounded),
                  selectedIcon: Icon(Icons.person_rounded),
                  label: Text('내 정보'),
                ),
              ],
            ),
            const VerticalDivider(width: 1, thickness: 0.5),
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
