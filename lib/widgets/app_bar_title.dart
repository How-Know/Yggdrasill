import 'package:flutter/material.dart';
import '../screens/settings/settings_screen.dart';

class AppBarTitle extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  final VoidCallback? onRefresh;
  final VoidCallback? onSettings;
  final List<Widget>? actions;

  const AppBarTitle({
    Key? key,
    required this.title,
    this.onBack,
    this.onForward,
    this.onRefresh,
    this.onSettings,
    this.actions,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5.0),
          child: AppBar(
            backgroundColor: const Color(0xFF1F1F1F),
            leadingWidth: 120,
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70),
                  onPressed: onBack ?? () {
                    if (Navigator.of(context).canPop()) {
                      Navigator.of(context).pop();
                    }
                  },
                  tooltip: '뒤로가기',
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward_ios, color: Colors.white70),
                  onPressed: onForward, // 앞으로가기(커스텀 필요)
                  tooltip: '앞으로가기',
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, color: Colors.white70),
                  onPressed: onRefresh,
                  tooltip: '새로고침',
                ),
              ],
            ),
            title: Text(
              title,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 28,
              ),
            ),
            centerTitle: true,
            toolbarHeight: 50,
            actions: [
              if (actions != null) ...actions!,
              IconButton(
                icon: const Icon(Icons.settings, color: Colors.white70),
                onPressed: onSettings ?? () {
                  Navigator.of(context).push(
                    PageRouteBuilder(
                      pageBuilder: (context, animation, secondaryAnimation) => const SettingsScreen(),
                      transitionsBuilder: (context, animation, secondaryAnimation, child) {
                        const begin = Offset(1.0, 0.0);
                        const end = Offset.zero;
                        const curve = Curves.ease;
                        final tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
                        return SlideTransition(
                          position: animation.drive(tween),
                          child: child,
                        );
                      },
                    ),
                  );
                },
                tooltip: '설정',
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: CircleAvatar(
                  radius: 16,
                  backgroundColor: Colors.grey.shade700,
                  child: const Icon(Icons.person, color: Colors.white70, size: 20),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Colors.black),
      ],
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(70);
}
