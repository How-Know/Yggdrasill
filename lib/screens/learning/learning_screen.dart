import 'package:flutter/material.dart';
import '../../widgets/app_bar_title.dart';
import '../../widgets/custom_tab_bar.dart';

class LearningScreen extends StatefulWidget {
  const LearningScreen({super.key});

  @override
  State<LearningScreen> createState() => _LearningScreenState();
}

class _LearningScreenState extends State<LearningScreen> {
  int _selectedTab = 0; // 0: 기록, 1: 커리큘럼

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1F1F1F),
      appBar: const AppBarTitle(title: '학습'),
      body: Column(
        children: [
          const SizedBox(height: 5),
          CustomTabBar(
            selectedIndex: _selectedTab,
            tabs: const ['기록', '커리큘럼'],
            onTabSelected: (i) {
              setState(() {
                _selectedTab = i;
              });
            },
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _selectedTab == 0
                ? const _LearningRecordsView()
                : const _LearningCurriculumView(),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _LearningRecordsView extends StatelessWidget {
  const _LearningRecordsView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        '학습 기록 화면 (준비 중)',
        style: const TextStyle(color: Colors.white70, fontSize: 18),
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


