import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/student_api.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _codeController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordConfirmController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _codeController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _passwordConfirmController.dispose();
    super.dispose();
  }

  Future<void> _signup() async {
    final code = _codeController.text.trim();
    final username = _usernameController.text.trim().toLowerCase();
    final password = _passwordController.text;
    final confirm = _passwordConfirmController.text;

    String? message;
    if (code.isEmpty) {
      message = '선생님께 받은 가입코드를 입력해 주세요.';
    } else if (!RegExp(r'^[a-z0-9._-]{3,20}$').hasMatch(username)) {
      message = '아이디는 영문 소문자/숫자 3~20자로 만들어 주세요.';
    } else if (password.length < 6) {
      message = '비밀번호는 6자 이상이어야 해요.';
    } else if (password != confirm) {
      message = '비밀번호가 서로 달라요.';
    }
    if (message != null) {
      setState(() => _error = message);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await StudentApi.instance.signUp(
        code: code,
        username: username,
        password: password,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      TopGlassSnackBar.show(
        context,
        message: '가입이 완료됐어요. 환영해요!',
        icon: Icons.celebration_rounded,
      );
    } on StudentApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = '가입에 실패했어요. 잠시 후 다시 시도해 주세요.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('계정 만들기')),
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
                    '선생님께 받은 가입코드로\n나만의 아이디를 만들어요.',
                    style: TextStyle(fontSize: 16, color: dlg.textSub),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _codeController,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '가입코드',
                      hintText: '예: A2B3C4D5',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _usernameController,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '아이디 (영문 소문자/숫자 3~20자)',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '비밀번호 (6자 이상)',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _passwordConfirmController,
                    obscureText: true,
                    onSubmitted: (_) => _signup(),
                    decoration: const InputDecoration(
                      labelText: '비밀번호 확인',
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
                    onPressed: _busy ? null : _signup,
                    style: FilledButton.styleFrom(
                      backgroundColor: YggGlassTokens.confirmActionColor,
                      minimumSize: const Size.fromHeight(52),
                    ),
                    child: _busy
                        ? const YggLoadingIndicator(size: 20)
                        : const Text(
                            '가입하기',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
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
