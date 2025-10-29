import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io';
import 'services/auth_service.dart';
import 'screens/auth/login_screen.dart';
import 'screens/curriculum/curriculum_screen.dart';
import 'screens/arithmetic/arithmetic_screen.dart';
import 'screens/skill/skill_screen.dart';
import 'screens/problem_bank/problem_bank_screen.dart';
import 'screens/management/management_screen.dart';
import 'widgets/app_navigation_bar.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 데스크톱 플랫폼 설정
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    
    const windowOptions = WindowOptions(
      size: Size(1400, 900),
      minimumSize: Size(1200, 800),
      center: true,
      backgroundColor: Color(0xFF1F1F1F),
      skipTaskbar: false,
      title: 'Yggdrasill Manager',
      titleBarStyle: TitleBarStyle.normal,
    );
    
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // Supabase 초기화
  try {
    await AuthService.initialize();
  } catch (e) {
    // 초기화 실패 시 에러 메시지 표시
    runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF1F1F1F),
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
}

class YggdrasillManagerApp extends StatelessWidget {
  const YggdrasillManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yggdrasill Manager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1976D2),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF1F1F1F),
      ),
      home: const AuthWrapper(),
    );
  }
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
        backgroundColor: Color(0xFF1F1F1F),
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

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;

  final List<Widget> _screens = const [
    CurriculumScreen(),
    ArithmeticScreen(),
    SkillScreen(),
    ProblemBankScreen(),
    ManagementScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1F1F1F),
      body: Row(
        children: [
          // 좌측 네비게이션 바
          AppNavigationBar(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (index) {
              setState(() {
                _selectedIndex = index;
              });
            },
          ),
          
          // 메인 콘텐츠
          Expanded(
            child: Column(
              children: [
                // 상단 바 (로그아웃 버튼)
                Container(
                  height: 60,
                  decoration: const BoxDecoration(
                    color: Color(0xFF18181A),
                    border: Border(
                      bottom: BorderSide(color: Color(0xFF2A2A2A), width: 1),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: TextButton.icon(
                          onPressed: () async {
                            await AuthService.signOut();
                          },
                          icon: const Icon(Icons.logout, size: 18),
                          label: const Text('로그아웃'),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white70,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                
                // 콘텐츠 영역
                Expanded(
                  child: _screens[_selectedIndex],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
