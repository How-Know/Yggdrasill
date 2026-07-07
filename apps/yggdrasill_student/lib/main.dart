import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'services/app_config.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: resolveSupabaseUrl(),
    anonKey: resolveSupabaseAnonKey(),
  );
  await AppThemeController.load();
  TopGlassSnackBar.navigatorKey = rootNavigatorKey;

  runApp(const StudentApp());
}

class StudentApp extends StatelessWidget {
  const StudentApp({super.key});

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
          theme: buildYggLightTheme(),
          darkTheme: buildYggDarkTheme(),
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
