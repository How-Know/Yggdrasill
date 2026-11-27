import 'package:flutter/material.dart';

import '../figure_engine/figure_editor_screen.dart';

/// 왼쪽 "그림" 메뉴(예전 이름: 커리큘럼). 그림 편집기를 연다.
/// 범용 사고틀·실전 알고리즘은 개념 탭 오른쪽 SkillScreen이 연다.
class CurriculumMenuScreen extends StatelessWidget {
  const CurriculumMenuScreen({super.key});

  @override
  Widget build(BuildContext context) => const FigureEditorScreen(embedded: true);
}
