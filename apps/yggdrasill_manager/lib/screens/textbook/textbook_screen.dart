import 'package:flutter/material.dart';

import '../../theme/manager_shell_colors.dart';
import 'textbook_migration_pane.dart';

/// 교재 메뉴. 예전 교재 관리 화면은 쓰지 않으므로 마이그레이션 화면만 연다.
class TextbookScreen extends StatelessWidget {
  const TextbookScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: ManagerShellColors.surfaceBase,
      child: const TextbookMigrationPane(),
    );
  }
}
