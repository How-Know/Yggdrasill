import 'package:flutter/material.dart';

import '../../theme/manager_shell_colors.dart';

/// 왼쪽 커리큘럼 메뉴. 화면은 비어 있다.
/// 범용 사고틀·실전 알고리즘은 개념 탭 오른쪽 SkillScreen이 연다.
class CurriculumMenuScreen extends StatelessWidget {
  const CurriculumMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(color: ManagerShellColors.surfaceBase);
  }
}
