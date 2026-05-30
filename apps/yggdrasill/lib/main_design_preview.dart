import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'screens/design_preview/design_preview_hub_screen.dart';
import 'widgets/dialog_tokens.dart';

/// 디자인 Preview 전용 창 (실사용 앱과 별도 프로세스).
///
/// 실행:
/// ```powershell
/// cd apps\yggdrasill
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
      backgroundColor: kDlgBg,
      title: 'Yggdrasill — Design Preview',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const _DesignPreviewApp());
}

class _DesignPreviewApp extends StatelessWidget {
  const _DesignPreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yggdrasill Design Preview',
      debugShowCheckedModeBanner: true,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: kDlgBg,
        fontFamily: 'KakaoSmallSans',
        textTheme: const TextTheme(
          titleLarge: TextStyle(fontFamily: 'KakaoBigSans'),
          titleMedium: TextStyle(fontFamily: 'KakaoBigSans'),
          titleSmall: TextStyle(fontFamily: 'KakaoBigSans'),
        ),
      ),
      home: const DesignPreviewHubScreen(),
    );
  }
}
