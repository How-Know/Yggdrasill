import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'screens/main_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/student/student_screen.dart';
import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:shared_preferences/shared_preferences.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  final prefs = await SharedPreferences.getInstance();
  final maximize = prefs.getBool('fullscreen_enabled') ?? false;
  runApp(MyApp(maximizeOnStart: maximize));
}

class MyApp extends StatelessWidget {
  final bool maximizeOnStart;
  const MyApp({super.key, required this.maximizeOnStart});

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(milliseconds: 200));
      if (maximizeOnStart) {
        await windowManager.maximize();
        await windowManager.focus();
      } else {
        await windowManager.setMinimumSize(const Size(1600, 900));
        await windowManager.setSize(const Size(1600, 900));
        await windowManager.center();
        await windowManager.focus();
        final info = await windowManager.getBounds();
        print('실제 창 크기:  [36m${info.width} x ${info.height} [0m');
      }
    });
    return RawKeyboardListener(
      focusNode: FocusNode(),
      autofocus: true,
      onKey: (event) async {
        if (event is RawKeyDownEvent && event.logicalKey == LogicalKeyboardKey.f11) {
          bool isFull = await windowManager.isFullScreen();
          if (isFull) {
            await windowManager.setFullScreen(false);
            await windowManager.maximize();
          } else {
            await windowManager.setFullScreen(true);
          }
        }
      },
      child: MaterialApp(
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        navigatorKey: rootNavigatorKey,
        title: 'Yggdrasill',
        // 로케일 설정 추가
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en', 'US'), // 영어 (기본)
          Locale('ko', 'KR'), // 한국어
        ],
        locale: const Locale('ko', 'KR'), // 기본 로케일을 한국어로 설정
        theme: ThemeData(
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFF1F1F1F),
          appBarTheme: const AppBarTheme(
            toolbarHeight: 80,  // 기본 56에서 24px 추가
            backgroundColor: Color(0xFF1F1F1F),
          ),
          navigationRailTheme: const NavigationRailThemeData(
            backgroundColor: Color(0xFF1F1F1F),
            selectedIconTheme: IconThemeData(color: Colors.white, size: 30),
            unselectedIconTheme: IconThemeData(color: Colors.white70, size: 30),
            minWidth: 84,
            indicatorColor: Color(0xFF0F467D),
            groupAlignment: -1,
            useIndicator: true,
          ),
          tooltipTheme: TooltipThemeData(
            decoration: BoxDecoration(
              color: Color(0xFF1F1F1F),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.white24),
            ),
            textStyle: TextStyle(color: Colors.white),
          ),
          floatingActionButtonTheme: FloatingActionButtonThemeData(
            backgroundColor: const Color(0xFF1976D2),
            foregroundColor: Colors.white,
          ),
        ),
        home: MainScreen(),
        routes: {
          '/settings': (context) => const SettingsScreen(),
          '/students': (context) => const StudentScreen(),
        },
      ),
    );
  }
}

 