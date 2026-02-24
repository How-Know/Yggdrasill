import 'package:flutter/material.dart';
import '../../widgets/pill_tab_selector.dart';
import 'problem_bank_view.dart';
import 'curriculum_actions_view.dart';

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
      backgroundColor: const Color(0xFF0B1112),
      body: Column(
        children: [
          const SizedBox(height: 5),
          Center(
            child: PillTabSelector(
              selectedIndex: _selectedTab,
              tabs: const ['커리큘럼', '문제은행'],
              onTabSelected: (i) {
                setState(() {
                  _selectedTab = i;
                });
              },
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _selectedTab == 0
                ? const CurriculumActionsView()
                : const ProblemBankView(),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
