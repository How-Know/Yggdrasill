import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/student_api.dart';
import 'signup_screen.dart';

/// 로그인 플로우 전용 — 카카오 대신 Pretendard.
ThemeData _loginPretendardTheme(BuildContext context) {
  final base = Theme.of(context);
  // ThemeData.copyWith 에는 fontFamily가 없음 → textTheme 로 적용.
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'Pretendard'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'Pretendard'),
  );
}

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
      final isDark = Theme.of(context).brightness == Brightness.dark;
      // 계정 시트 surface 와 동일 (#F2F2F7 / #1C1C1E).
      final sheetBg =
          isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
      final student = await showModalBottomSheet<QuickLoginStudent>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        backgroundColor: sheetBg,
        barrierColor: Colors.black.withValues(alpha: 0.4),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        constraints: const BoxConstraints(maxWidth: 560),
        builder: (context) => Theme(
          data: _loginPretendardTheme(context),
          child: _QuickLoginStudentSheet(roster: roster),
        ),
      );
      if (student == null || !mounted) return;
      await showPinLoginDialog(context: context, student: student);
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
    // 카카오큰글씨는 같은 pt여도 더 크게 보여, Pretendard는 학원명만 살짝 키움.
    const academyNameSize = 34.0;
    return Theme(
      data: _loginPretendardTheme(context),
      child: Scaffold(
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
                        fontFamily: 'Pretendard',
                        fontSize: academyNameSize,
                        fontWeight: FontWeight.w700,
                        color: dlg.text,
                      ),
                    ),
                    const SizedBox(height: 40),
                    TextField(
                      controller: _usernameController,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.next,
                      style: const TextStyle(fontFamily: 'Pretendard'),
                      decoration: const InputDecoration(
                        labelText: '아이디',
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _passwordController,
                      obscureText: true,
                      onSubmitted: (_) => _login(),
                      style: const TextStyle(fontFamily: 'Pretendard'),
                      decoration: const InputDecoration(
                        labelText: '비밀번호',
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          color: Colors.redAccent,
                        ),
                      ),
                    ],
                    const SizedBox(height: 22),
                    FilledButton(
                      onPressed: _busy ? null : _login,
                      style: FilledButton.styleFrom(
                        backgroundColor: YggGlassTokens.confirmActionColor,
                        minimumSize: const Size.fromHeight(52),
                        textStyle: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: _busy
                          ? const YggLoadingIndicator(size: 20)
                          : const Text('로그인'),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _busy || _quickBusy ? null : _openQuickLogin,
                      style: OutlinedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        foregroundColor: dlg.text,
                        side: BorderSide(
                          color: dlg.text.withValues(alpha: 0.35),
                        ),
                        minimumSize: const Size.fromHeight(52),
                        textStyle: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: _quickBusy
                          ? const YggLoadingIndicator(size: 20)
                          : const Text('빠른 로그인'),
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
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          color: dlg.textSub,
                        ),
                      ),
                    ),
                  ],
                ),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final text = isDark ? Colors.white : Colors.black;
    final sub = isDark
        ? Colors.white.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.4);
    final divider = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : const Color(0xFFE5E5EA);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '오늘 등원 예정',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
              color: text,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '계정과 PIN이 등록된 학생만 표시돼요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: sub,
              height: 1.35,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 18),
          if (roster.students.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 36),
              child: Text(
                '지금 빠른 로그인할 수 있는 학생이 없어요.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: sub,
                  decoration: TextDecoration.none,
                ),
              ),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: roster.students.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  thickness: 0.5,
                  color: divider,
                ),
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
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontWeight: FontWeight.w700,
                          color: YggGlassTokens.confirmActionColor,
                        ),
                      ),
                    ),
                    title: Text(
                      student.name,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: text,
                      ),
                    ),
                    subtitle: Text(
                      '${student.school}$grade$time',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 13,
                        color: sub,
                      ),
                    ),
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      color: sub,
                    ),
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

/// 프로필 편집 다이얼로그와 동일한 카드·헤더·슬라이드 모션.
Future<void> showPinLoginDialog({
  required BuildContext context,
  required QuickLoginStudent student,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'PIN 로그인',
    barrierColor: Colors.black.withValues(alpha: 0.4),
    transitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (context, animation, secondaryAnimation) {
      return Theme(
        data: _loginPretendardTheme(context),
        child: _PinLoginDialog(student: student),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curve = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.45),
            end: Offset.zero,
          ).animate(curve),
          child: child,
        ),
      );
    },
  );
}

class _PinLoginDialog extends StatefulWidget {
  const _PinLoginDialog({required this.student});

  final QuickLoginStudent student;

  @override
  State<_PinLoginDialog> createState() => _PinLoginDialogState();
}

class _PinLoginDialogState extends State<_PinLoginDialog> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
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
        _focus.requestFocus();
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
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final text = isDark ? Colors.white : Colors.black;
    final sub = isDark
        ? Colors.white.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.4);
    final divider = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : const Color(0xFFE5E5EA);
    // 계정 시트 surface 와 동일.
    final card = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
    final media = MediaQuery.of(context);
    final dialogW = (media.size.width - 32).clamp(360.0, 560.0);
    final dialogH = (media.size.height * 0.406).clamp(320.0, 450.0);

    final valueStyle = TextStyle(
      fontFamily: 'Pretendard',
      color: text,
      fontSize: 17,
      fontWeight: FontWeight.w400,
      letterSpacing: -0.2,
      height: 1.2,
    );
    final labelStyle = TextStyle(
      fontFamily: 'Pretendard',
      color: text,
      fontSize: 17,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      decoration: TextDecoration.none,
    );

    return Material(
      type: MaterialType.transparency,
      child: Center(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + media.viewInsets.bottom,
          ),
          child: SizedBox(
            width: dialogW,
            height: dialogH,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: card,
                borderRadius: BorderRadius.circular(28),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x28000000),
                    blurRadius: 40,
                    offset: Offset(0, 16),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Theme(
                  data: Theme.of(context).copyWith(
                    splashColor: Colors.transparent,
                    highlightColor: Colors.transparent,
                    splashFactory: NoSplash.splashFactory,
                    textSelectionTheme: TextSelectionThemeData(
                      cursorColor: text,
                      selectionColor: Colors.transparent,
                      selectionHandleColor: Colors.transparent,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                        child: SizedBox(
                          height: 56,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Text(
                                'PIN 로그인',
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.3,
                                  color: text,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: SolidCapsuleActionBar(
                                  padding: const EdgeInsets.all(8),
                                  children: [
                                    SolidCapsuleActionButton(
                                      tooltip: '닫기',
                                      icon: Icons.close_rounded,
                                      onPressed: _busy
                                          ? null
                                          : () => Navigator.of(context).pop(),
                                    ),
                                  ],
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: SolidCapsuleActionBar(
                                  padding: const EdgeInsets.all(8),
                                  children: [
                                    SolidCapsuleActionButton(
                                      tooltip: '로그인',
                                      icon: Icons.check_rounded,
                                      onPressed: _busy
                                          ? null
                                          : () => unawaited(_submit()),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Divider(height: 1, thickness: 0.5, color: divider),
                            SizedBox(
                              height: 56,
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 104,
                                    child: Text('이름', style: labelStyle),
                                  ),
                                  Expanded(
                                    child: Text(
                                      widget.student.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: valueStyle.copyWith(
                                        decoration: TextDecoration.none,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Divider(height: 1, thickness: 0.5, color: divider),
                            SizedBox(
                              height: 56,
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 104,
                                    child: Text('PIN', style: labelStyle),
                                  ),
                                  Expanded(
                                    child: TextField(
                                      controller: _controller,
                                      focusNode: _focus,
                                      obscureText: true,
                                      keyboardType: TextInputType.number,
                                      textAlign: TextAlign.start,
                                      textInputAction: TextInputAction.done,
                                      maxLength: 8,
                                      enabled: !_busy,
                                      inputFormatters: [
                                        FilteringTextInputFormatter.digitsOnly,
                                      ],
                                      onSubmitted: (_) {
                                        if (!_busy) unawaited(_submit());
                                      },
                                      style: valueStyle,
                                      cursorColor: text,
                                      cursorWidth: 1.5,
                                      decoration: InputDecoration(
                                        counterText: '',
                                        hintText: '4자리 이상',
                                        hintStyle: valueStyle.copyWith(
                                          color: sub,
                                        ),
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        disabledBorder: InputBorder.none,
                                        filled: false,
                                        isDense: true,
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                    ),
                                  ),
                                  if (_busy)
                                    const Padding(
                                      padding: EdgeInsets.only(left: 8),
                                      child: YggLoadingIndicator(size: 18),
                                    ),
                                ],
                              ),
                            ),
                            Divider(height: 1, thickness: 0.5, color: divider),
                            if (_error != null) ...[
                              const SizedBox(height: 12),
                              Text(
                                _error!,
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  color: Colors.redAccent,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const Spacer(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
                        child: Text(
                          'M5에서 사용하는 PIN을 입력해 주세요.',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            color: sub,
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                            height: 1.35,
                            letterSpacing: -0.1,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
