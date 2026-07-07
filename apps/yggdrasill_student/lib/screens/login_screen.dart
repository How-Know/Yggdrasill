import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/student_api.dart';
import 'signup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = '아이디와 비밀번호를 입력해 주세요.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await StudentApi.instance.signIn(username: username, password: password);
      // 성공 시 AuthGate가 홈으로 전환한다.
    } catch (_) {
      setState(() => _error = '아이디 또는 비밀번호가 맞지 않아요.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Mneme',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'KakaoBigSans',
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      color: dlg.text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '학생용',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: dlg.textSub),
                  ),
                  const SizedBox(height: 40),
                  TextField(
                    controller: _usernameController,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: '아이디',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    onSubmitted: (_) => _login(),
                    decoration: const InputDecoration(
                      labelText: '비밀번호',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ],
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: _busy ? null : _login,
                    style: FilledButton.styleFrom(
                      backgroundColor: YggGlassTokens.confirmActionColor,
                      minimumSize: const Size.fromHeight(52),
                    ),
                    child: _busy
                        ? const YggLoadingIndicator(size: 20)
                        : const Text(
                            '로그인',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const SignupScreen(),
                              ),
                            );
                          },
                    child: Text(
                      '가입코드로 계정 만들기',
                      style: TextStyle(color: dlg.textSub),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
