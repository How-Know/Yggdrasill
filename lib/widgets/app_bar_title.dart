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
    return Container(
      color: const Color(0xFF1F1F1F),
      padding: const EdgeInsets.only(top: 0, left: 0, right: 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 56,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 왼쪽 아이콘들
                Row(
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
                      onPressed: onForward,
                      tooltip: '앞으로가기',
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh, color: Colors.white70),
                      onPressed: onRefresh,
                      tooltip: '새로고침',
                    ),
                  ],
                ),
                // 타이틀
                Expanded(
                  child: Center(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                // 오른쪽 액션들
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (actions != null) ...actions!,
                    // apps 아이콘 버튼 추가
                    IconButton(
                      icon: const Icon(Icons.apps, color: Colors.white70),
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('앱스 버튼 클릭됨')),
                        );
                      },
                      tooltip: '앱스',
                    ),
                    IconButton(
                      icon: const Icon(Icons.settings, color: Colors.white70),
                      onPressed: onSettings ?? () {
                        Navigator.of(context).push(
                          PageRouteBuilder(
                            pageBuilder: (context, animation, secondaryAnimation) => const SettingsScreen(),
                            transitionsBuilder: (context, animation, secondaryAnimation, child) {
                              final isPop = animation.value < secondaryAnimation.value;
                              final beginOffset = isPop ? Offset.zero : Offset(1.0, 0.0);
                              final endOffset = isPop ? Offset(1.0, 0.0) : Offset.zero;
                              final slideAnimation = Tween<Offset>(begin: beginOffset, end: endOffset)
                                  .chain(CurveTween(curve: Curves.easeInOut))
                                  .animate(animation);
                              final fadeAnimation = Tween<double>(begin: 0.0, end: 1.0)
                                  .chain(CurveTween(curve: Curves.easeInOut))
                                  .animate(animation);
                              return SlideTransition(
                                position: slideAnimation,
                                child: FadeTransition(
                                  opacity: fadeAnimation,
                                  child: child,
                                ),
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
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.black),
        ],
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(70);
}
