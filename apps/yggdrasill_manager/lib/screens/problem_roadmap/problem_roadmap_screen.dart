import 'package:flutter/material.dart';

import '../../theme/manager_shell_colors.dart';

import '../../services/course_map_controller.dart';
import '../curriculum/widgets/course_map_pane.dart';

/// 문항로드맵 메뉴. 개념 메뉴 왼쪽 칸과 같은 기준 과정 탐색도(같은 저장본·같은 편집 상태)를 크게 연다.
/// 설계: docs/architecture/course-map.md
class ProblemRoadmapScreen extends StatelessWidget {
  const ProblemRoadmapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: ManagerShellColors.surfaceBase,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '문항로드맵',
              style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            const Text(
              '과정별 대·중·소단원 흐름을 보고 고칩니다. 개념 메뉴 왼쪽 "교육과정 흐름"과 같은 자료입니다. '
              '나열 순서는 수업 흐름의 기준일 뿐 선행 관계가 아닙니다.',
              style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 16),
            ),
            const SizedBox(height: 20),
            Expanded(child: CourseMapPane(controller: CourseMapController.instance)),
          ],
        ),
      ),
    );
  }
}
