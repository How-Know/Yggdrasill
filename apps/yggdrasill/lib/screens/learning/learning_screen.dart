import 'package:flutter/material.dart';
import '../../app_overlays.dart';
import '../../theme/ygg_semantic_colors.dart';
import '../../services/exam_mode.dart';
import '../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import 'problem_bank_view.dart';
import 'curriculum_actions_view.dart';

class LearningScreen extends StatefulWidget {
  const LearningScreen({super.key});

  @override
  State<LearningScreen> createState() => _LearningScreenState();
}

class _LearningScreenState extends State<LearningScreen> {
  int _selectedTab = 0; // 0: 커리큘럼, 1: 문제은행
  final FabStyleScreenTabBarOverlay _tabOverlay = FabStyleScreenTabBarOverlay();

  @override
  void initState() {
    super.initState();
    _syncProblemBankOverlayVisibility();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncTabOverlay();
    });
  }

  @override
  void dispose() {
    _tabOverlay.dispose();
    ExamModeService.instance.suppressExamActionCluster.value = false;
    hideGlobalMemoFloatingBanners.value = false;
    super.dispose();
  }

  void _syncProblemBankOverlayVisibility() {
    final isProblemBankTab = _selectedTab == 1;
    ExamModeService.instance.suppressExamActionCluster.value = isProblemBankTab;
    hideGlobalMemoFloatingBanners.value = isProblemBankTab;
  }

  void _onLearningTabSelected(int i) {
    setState(() {
      _selectedTab = i;
    });
    _syncProblemBankOverlayVisibility();
    _syncTabOverlay();
  }

  void _syncTabOverlay() {
    _tabOverlay.sync(
      context,
      selectedIndex: _selectedTab,
      tabs: const ['커리큘럼', '문제은행'],
      onTabSelected: _onLearningTabSelected,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.yggSurfaceBase,
      body: Stack(
        children: [
          Positioned.fill(
            child: _selectedTab == 0
                ? const CurriculumActionsView()
                : const ProblemBankView(),
          ),
        ],
      ),
    );
  }
}
