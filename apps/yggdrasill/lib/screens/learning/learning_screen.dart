import 'package:flutter/material.dart';
import '../../widgets/custom_tab_bar.dart';
import 'problem_bank_view.dart';

class LearningScreen extends StatefulWidget {
  const LearningScreen({super.key});

  @override
  State<LearningScreen> createState() => _LearningScreenState();
}

class _LearningScreenState extends State<LearningScreen> {
  int _selectedTab = 0; // 0: 커리큘럼, 1: 문제은행

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1F1F1F),
      body: Column(
        children: [
          const SizedBox(height: 5),
          CustomTabBar(
            selectedIndex: _selectedTab,
            tabs: const ['커리큘럼', '문제은행'],
            onTabSelected: (i) {
              setState(() {
                _selectedTab = i;
              });
            },
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _selectedTab == 0
                ? const _LearningCurriculumView()
                : const ProblemBankView(),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _LearningCurriculumView extends StatelessWidget {
  const _LearningCurriculumView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        '커리큘럼 화면 (준비 중)',
        style: const TextStyle(color: Colors.white70, fontSize: 18),
      ),
    );
  }
}
