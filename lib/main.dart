import 'package:flutter/material.dart';
import 'screens/main_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yggdrasill',
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          extendedPadding: const EdgeInsets.all(16),
          extendedTextStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      home: const MainScreen(),
    );
  }
}

 