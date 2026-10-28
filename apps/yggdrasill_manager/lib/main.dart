import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'services/app_menu.dart';
import 'services/auth_service.dart';
import 'services/course_map_controller.dart';
import 'services/error_reporter.dart';
import 'screens/auth/login_screen.dart';
import 'screens/curriculum/curriculum_screen.dart';
import 'screens/curriculum/widgets/course_map_pane.dart';
import 'screens/arithmetic/arithmetic_screen.dart';
import 'screens/skill/skill_screen.dart';
import 'screens/problem_roadmap/problem_roadmap_screen.dart';
import 'screens/problem_bank/problem_bank_screen.dart';
import 'screens/trait_survey/trait_survey_screen.dart';
import 'screens/textbook/textbook_screen.dart';
import 'screens/think/think_screen.dart';
import 'screens/management/management_screen.dart';
import 'theme/manager_shell_colors.dart';
import 'widgets/app_navigation_bar.dart';
import 'widgets/textbook_background_extract_panel.dart';

void main() {
  // Zone 외부 비동기 에러(unawaited future, platform channel 등)까지 모두 잡기 위해
  // 앱 전체를 runZonedGuarded 로 감싼다. mouse_tracker assertion 처럼 1프레임에
  // 수백 번 튀는 에러는 ErrorReporter 내부에서 첫 1회만 풀 스택으로 덤프한다.
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();

    await ErrorReporter.instance.install();

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await windowManager.ensureInitialized();

      const windowOptions = WindowOptions(
        size: Size(1400, 900),
        minimumSize: Size(1200, 800),
        center: true,
        backgroundColor: ManagerShellColors.surfaceBase,
        skipTaskbar: false,
        title: 'Yggdrasill Manager',
        titleBarStyle: TitleBarStyle.normal,
      );

      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      });
    }

    try {
      await AuthService.initialize();
    } catch (e) {
      runApp(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _buildManagerTheme(),
        home: Scaffold(
          backgroundColor: ManagerShellColors.surfaceBase,
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 48),
                const SizedBox(height: 16),
                Text(
                  '초기화 실패: $e',
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                const Text(
                  '환경 변수를 확인해주세요:\n--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ));
      return;
    }

    runApp(const YggdrasillManagerApp());
  }, (Object error, StackTrace stack) {
    ErrorReporter.instance.reportZoneError(error, stack);
  });
}

class YggdrasillManagerApp extends StatelessWidget {
  const YggdrasillManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yggdrasill Manager',
      debugShowCheckedModeBanner: false,
      theme: _buildManagerTheme(),
      home: const AuthWrapper(),
    );
  }
}

ThemeData _buildManagerTheme() {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF33A373),
      brightness: Brightness.dark,
    ),
    useMaterial3: true,
    scaffoldBackgroundColor: ManagerShellColors.surfaceBase,
    fontFamily: 'KakaoSmallSans',
    textTheme: const TextTheme(
      displayLarge: TextStyle(fontFamily: 'KakaoBigSans'),
      displayMedium: TextStyle(fontFamily: 'KakaoBigSans'),
      displaySmall: TextStyle(fontFamily: 'KakaoBigSans'),
      headlineLarge: TextStyle(fontFamily: 'KakaoBigSans'),
      headlineMedium: TextStyle(fontFamily: 'KakaoBigSans'),
      headlineSmall: TextStyle(fontFamily: 'KakaoBigSans'),
      titleLarge: TextStyle(fontFamily: 'KakaoBigSans'),
      titleMedium: TextStyle(fontFamily: 'KakaoBigSans'),
      titleSmall: TextStyle(fontFamily: 'KakaoBigSans'),
      bodyLarge: TextStyle(fontFamily: 'KakaoSmallSans'),
      bodyMedium: TextStyle(fontFamily: 'KakaoSmallSans'),
      bodySmall: TextStyle(fontFamily: 'KakaoSmallSans'),
      labelLarge: TextStyle(fontFamily: 'KakaoSmallSans'),
      labelMedium: TextStyle(fontFamily: 'KakaoSmallSans'),
      labelSmall: TextStyle(fontFamily: 'KakaoSmallSans'),
    ),
  );
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool _isAuthenticated = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkAuth();

    // 인증 상태 변화 감지
    AuthService.authStateChanges.listen((event) {
      final user = event.session?.user;
      setState(() {
        _isAuthenticated = user != null && AuthService.isAdmin();
      });
    });
  }

  Future<void> _checkAuth() async {
    final user = AuthService.currentUser;
    setState(() {
      _isAuthenticated = user != null && AuthService.isAdmin();
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: ManagerShellColors.surfaceBase,
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (!_isAuthenticated) {
      return const LoginScreen();
    }

    return const MainScreen();
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WindowListener {
  int _selectedIndex = 0;
  bool _preventClose = false;
  bool _closeAsking = false;

  bool get _desktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    AppMenu.instance.addListener(_onMenuRequest);
    if (_desktop) {
      windowManager.addListener(this);
      CourseMapController.instance.addListener(_syncPreventClose);
    }
  }

  @override
  void dispose() {
    AppMenu.instance.removeListener(_onMenuRequest);
    if (_desktop) {
      windowManager.removeListener(this);
      CourseMapController.instance.removeListener(_syncPreventClose);
      if (_preventClose) unawaited(_setPreventClose(false));
    }
    super.dispose();
  }

  /// 저장 안 한 과정 편집이 있을 때만 창 닫기를 붙잡는다. 없으면 닫기는 예전 그대로다.
  void _syncPreventClose() {
    final dirty = CourseMapController.instance.anyDirty;
    if (dirty == _preventClose) return;
    _preventClose = dirty;
    unawaited(_setPreventClose(dirty));
  }

  Future<void> _setPreventClose(bool value) async {
    try {
      await windowManager.setPreventClose(value);
    } catch (_) {}
  }

  @override
  void onWindowClose() async {
    if (_closeAsking) return;
    _closeAsking = true;
    try {
      final ok = !mounted ||
          await confirmDiscardCourseMapEdits(context, CourseMapController.instance, action: '창을 닫으면');
      if (!ok) return;
      await _setPreventClose(false);
      await windowManager.close();
    } finally {
      _closeAsking = false;
    }
  }

  Future<void> _logout() async {
    final ok = await confirmDiscardCourseMapEdits(context, CourseMapController.instance, action: '로그아웃하면');
    if (!ok) return;
    await AuthService.signOut();
  }

  void _onMenuRequest() {
    final index = AppMenu.instance.takeRequest();
    if (index == null || !mounted) return;
    setState(() => _selectedIndex = _normalizeIndex(index));
  }

  // 순서를 바꾸면 AppMenu 상수도 맞춘다.
  final List<Widget> _screens = const [
    CurriculumScreen(),
    ArithmeticScreen(),
    SkillScreen(),
    ProblemRoadmapScreen(),
    ProblemBankScreen(),
    TraitSurveyScreen(),
    TextbookScreen(),
    ThinkScreen(),
    ManagementScreen(),
  ];

  int _normalizeIndex(int index) {
    if (_screens.isEmpty) {
      return 0;
    }
    if (index < 0) {
      return 0;
    }
    final int maxIndex = _screens.length - 1;
    if (index > maxIndex) {
      return maxIndex;
    }
    return index;
  }

  @override
  Widget build(BuildContext context) {
    final int safeIndex = _normalizeIndex(_selectedIndex);
    return Scaffold(
      backgroundColor: ManagerShellColors.surfaceBase,
      body: Stack(
        children: [
          Row(
            children: [
              // 좌측 네비게이션 바
              AppNavigationBar(
                selectedIndex: safeIndex,
                onDestinationSelected: (index) {
                  setState(() {
                    _selectedIndex = _normalizeIndex(index);
                  });
                },
                onLogout: _logout,
              ),

              // 메인 콘텐츠
              Expanded(
                child: Column(
                  children: [
                    // 콘텐츠 영역
                    Expanded(
                      child: _screens[safeIndex],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const TextbookBackgroundExtractPanel(),
        ],
      ),
    );
  }
}
