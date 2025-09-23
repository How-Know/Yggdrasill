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
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 중앙 타이틀: 좌우 아이콘 폭과 무관하게 정확히 중앙
                Center(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 28,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                // 왼쪽 아이콘들
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
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
                  ),
                ),
                // 오른쪽 액션들
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (actions != null) ...actions!,
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
                          child: InkWell(
                            onTap: () {
                              showDialog(
                                context: context,
                                barrierDismissible: true,
                                builder: (ctx) => const _LoginDialog(),
                              );
                            },
                            child: CircleAvatar(
                              radius: 16,
                              backgroundColor: Colors.grey.shade700,
                              child: const Icon(Icons.person, color: Colors.white70, size: 20),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
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

class _LoginDialog extends StatefulWidget {
  const _LoginDialog();
  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF18181A),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFF2A2A2A))),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('로그인', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white70),
                    tooltip: '닫기',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text('기존 회원', style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 6),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  hintText: '이메일',
                  hintStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: const Color(0xFF2A2A2A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2A2A2A))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2A2A2A))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2A82D2))),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: _obscure,
                decoration: InputDecoration(
                  hintText: '비밀번호',
                  hintStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: const Color(0xFF2A2A2A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2A2A2A))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2A2A2A))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2A82D2))),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off, color: Colors.white54),
                  ),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 10),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(_error!, style: const TextStyle(color: Color(0xFFE53E3E), fontSize: 12)),
                ),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        final email = _emailController.text.trim();
                        final pw = _passwordController.text;
                        if (email.isEmpty || !email.contains('@')) { setState(() => _error = '이메일 형식을 확인하세요.'); return; }
                        if (pw.isEmpty || pw.length < 6) { setState(() => _error = '비밀번호는 6자 이상이어야 합니다.'); return; }
                        setState(() => _error = null);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('로그인(UI만 구현)')));
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1976D2),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('로그인', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(height: 1, color: Color(0xFF2A2A2A)),
              const SizedBox(height: 12),
              const Text('회원가입', style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 8),
              SizedBox(
                height: 44,
                child: OutlinedButton.icon(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Google로 회원가입(UI만 구현)')));
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Color(0xFF2A2A2A)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    backgroundColor: const Color(0xFF2A2A2A),
                  ),
                  icon: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Image.network(
                      'https://www.gstatic.com/firebasejs/ui/2.0.0/images/auth/google.svg',
                      width: 18,
                      height: 18,
                      errorBuilder: (c, e, s) => const Icon(Icons.account_circle, size: 18, color: Colors.white70),
                    ),
                  ),
                  label: const Text('Google로 회원가입'),
                ),
              ),
              const SizedBox(height: 4),
              const Text('Supabase 제공 양식에 맞춰 OAuth 버튼만 먼저 노출합니다.', style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
