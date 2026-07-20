import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'screens/kiosk_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ko_KR');
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const YggdrasillKioskApp());
}

class YggdrasillKioskApp extends StatelessWidget {
  const YggdrasillKioskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yggdrasill Kiosk',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const _KioskScrollBehavior(),
      theme: ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6EA8FF),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: Colors.white,
        fontFamilyFallback: const [
          'Pretendard',
          'Noto Sans KR',
          'Malgun Gothic',
        ],
      ),
      home: const Scaffold(
        resizeToAvoidBottomInset: false,
        body: KioskScreen(),
      ),
    );
  }
}

class _KioskScrollBehavior extends MaterialScrollBehavior {
  const _KioskScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
  };
}
