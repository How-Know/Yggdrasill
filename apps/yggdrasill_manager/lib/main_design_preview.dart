import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'screens/design_preview/design_preview_hub_screen.dart';

/// 매니저앱 디자인 Preview 전용 창 (실사용 앱과 별도 프로세스).
///
/// 실행:
/// ```powershell
/// cd apps\yggdrasill_manager
/// flutter run -d windows -t lib/main_design_preview.dart
/// ```
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1280, 900),
      minimumSize: Size(960, 640),
      center: true,
      backgroundColor: Color(0xFF1F1F1F),
      title: 'Yggdrasill Manager — Design Preview',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const _ManagerDesignPreviewApp());
}

class _ManagerDesignPreviewApp extends StatelessWidget {
  const _ManagerDesignPreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Manager Design Preview',
      debugShowCheckedModeBanner: true,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF33A373),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF1F1F1F),
        fontFamily: 'KakaoSmallSans',
        textTheme: const TextTheme(
          displayLarge: TextStyle(fontFamily: 'KakaoBigSans'),
          titleLarge: TextStyle(fontFamily: 'KakaoBigSans'),
          titleMedium: TextStyle(fontFamily: 'KakaoBigSans'),
          titleSmall: TextStyle(fontFamily: 'KakaoBigSans'),
        ),
      ),
      home: const DesignPreviewHubScreen(),
    );
  }
}
