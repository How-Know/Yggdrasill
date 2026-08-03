import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'services/app_config.dart';
import 'widgets/student_status_island.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: resolveSupabaseUrl(),
    anonKey: resolveSupabaseAnonKey(),
  );
  await AppThemeController.load();
  TopGlassSnackBar.navigatorKey = rootNavigatorKey;
  // 상태 아일랜드 바로 아래에 스낵바가 오도록 상단 여백을 맞춘다.
  TopGlassSnackBar.topContentInsetBuilder = (context) {
    return (kToolbarHeight / 2) +
        StudentStatusIsland.centerOffsetY +
        (StudentStatusIsland.height / 2) +
        10;
  };

  runApp(const StudentApp());
}

class StudentApp extends StatelessWidget {
  const StudentApp({super.key});

  /// 학생앱 전역 서체 — 학습앱 카카오 테마 위에 Pretendard 를 덮어쓴다.
  static ThemeData _withPretendard(ThemeData base) {
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'Pretendard'),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'Pretendard'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppThemeController.mode,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'Mneme 학생',
          debugShowCheckedModeBanner: false,
          navigatorKey: rootNavigatorKey,
          themeMode: mode,
          theme: _withPretendard(buildYggLightTheme()),
          darkTheme: _withPretendard(buildYggDarkTheme()),
          builder: (context, child) => StudentStatusIslandHost(child: child),
          home: const _AuthGate(),
        );
      },
    );
  }
}

/// 세션 유무에 따라 로그인/홈을 전환한다.
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = Supabase.instance.client.auth.currentSession;
        if (session != null) {
          return const HomeShell();
        }
        return const LoginScreen();
      },
    );
  }
}
