import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool _quickBusy = false;
  String? _error;
  AcademyBranding _branding = const AcademyBranding(name: '정현수학교습소');

  @override
  void initState() {
    super.initState();
    _loadBranding();
  }

  Future<void> _loadBranding() async {
    try {
      final branding = await StudentApi.instance.getPublicAcademyBranding();
      if (mounted) setState(() => _branding = branding);
    } catch (_) {
      // 네트워크가 없어도 전용 앱의 학원명은 바로 표시한다.
    }
  }

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

  Future<void> _openQuickLogin() async {
    setState(() => _quickBusy = true);
    try {
      final roster = await StudentApi.instance.listQuickLoginStudents();
      if (!mounted) return;
      final student = await showModalBottomSheet<QuickLoginStudent>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        constraints: const BoxConstraints(maxWidth: 560),
        builder: (context) => _QuickLoginStudentSheet(roster: roster),
      );
      if (student == null || !mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _PinLoginDialog(student: student),
      );
    } on StudentApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } finally {
      if (mounted) setState(() => _quickBusy = false);
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
                  Center(
                    child: Container(
                      width: 120,
                      height: 120,
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: ClipOval(
                        child: Transform.scale(
                          scale: 1.12,
                          child: Image.asset(
                            'assets/branding/academy_logo.png',
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    _branding.name,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'KakaoBigSans',
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      color: dlg.text,
                    ),
                  ),
                  const SizedBox(height: 40),
                  TextField(
                    controller: _usernameController,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: '아이디',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    onSubmitted: (_) => _login(),
                    decoration: const InputDecoration(
                      labelText: '비밀번호',
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
                  FilledButton(
                    onPressed: _busy || _quickBusy ? null : _openQuickLogin,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF6B7280),
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(52),
                    ),
                    child: _quickBusy
                        ? const YggLoadingIndicator(size: 20)
                        : const Text(
                            '빠른 로그인',
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

class _QuickLoginStudentSheet extends StatelessWidget {
  const _QuickLoginStudentSheet({required this.roster});

  final QuickLoginRoster roster;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '오늘 등원 예정',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '계정과 PIN이 등록된 학생만 표시돼요.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.hintColor,
            ),
          ),
          const SizedBox(height: 18),
          if (roster.students.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 36),
              child: Text(
                '지금 빠른 로그인할 수 있는 학생이 없어요.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: roster.students.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final student = roster.students[index];
                  final grade =
                      student.grade == null ? '' : ' · ${student.grade}학년';
                  final time = student.startHour == null
                      ? ''
                      : ' · ${student.startHour!.toString().padLeft(2, '0')}:${(student.startMinute ?? 0).toString().padLeft(2, '0')}';
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 7,
                    ),
                    leading: CircleAvatar(
                      backgroundColor: YggGlassTokens.confirmActionColor
                          .withValues(alpha: 0.14),
                      foregroundColor: YggGlassTokens.confirmActionColor,
                      child: Text(
                        student.name.isEmpty ? '?' : student.name[0],
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    title: Text(
                      student.name,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text('${student.school}$grade$time'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).pop(student),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _PinLoginDialog extends StatefulWidget {
  const _PinLoginDialog({required this.student});

  final QuickLoginStudent student;

  @override
  State<_PinLoginDialog> createState() => _PinLoginDialogState();
}

class _PinLoginDialogState extends State<_PinLoginDialog> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _controller.text;
    if (pin.length < 4) {
      setState(() => _error = 'PIN 4자리를 입력해 주세요.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await StudentApi.instance.signInWithPin(
        studentId: widget.student.id,
        pin: pin,
      );
      if (mounted) Navigator.of(context).pop();
    } on StudentApiException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.message;
          _controller.clear();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '빠른 로그인에 실패했어요.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.student.name} 학생'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('M5에서 사용하는 PIN을 입력해 주세요.'),
            const SizedBox(height: 18),
            TextField(
              controller: _controller,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 8,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onSubmitted: (_) => _busy ? null : _submit(),
              decoration: const InputDecoration(
                labelText: 'PIN',
                counterText: '',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child:
              _busy ? const YggLoadingIndicator(size: 18) : const Text('로그인'),
        ),
      ],
    );
  }
}
