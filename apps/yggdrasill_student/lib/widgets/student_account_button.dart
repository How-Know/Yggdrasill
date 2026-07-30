import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../screens/profile_avatar_edit_screen.dart';
import '../services/student_api.dart';
import 'student_avatar_view.dart';

/// 상단 타이틀 줄 오른쪽에 두는 계정 아바타 버튼.
class StudentAccountButton extends StatefulWidget {
  const StudentAccountButton({super.key});

  @override
  State<StudentAccountButton> createState() => _StudentAccountButtonState();
}

class _StudentAccountButtonState extends State<StudentAccountButton> {
  late Future<StudentInfo?> _infoFuture;

  @override
  void initState() {
    super.initState();
    _infoFuture = StudentApi.instance.getInfo();
  }

  Future<void> _openAccount() async {
    StudentInfo? info;
    try {
      info = await _infoFuture;
    } catch (_) {
      // 계정 정보 조회가 실패해도 로그아웃은 제공한다.
    }
    if (!mounted) return;
    await showStudentAccountSheet(context: context, info: info);
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '계정',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _openAccount,
        child: FutureBuilder<StudentInfo?>(
          future: _infoFuture,
          builder: (context, snapshot) {
            final name = snapshot.data?.name.trim() ?? '';
            if (name.isEmpty) {
              return StudentAvatarFallbackInitial(name: '?', radius: 20);
            }
            return StudentAvatarView(name: name, radius: 20);
          },
        ),
      ),
    );
  }
}

/// 학습앱 설정 [PreviewAcademyDialogRoute]와 같은 페이드+슬라이드 모션.
Future<void> showStudentAccountSheet({
  required BuildContext context,
  required StudentInfo? info,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '계정',
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (context, animation, secondaryAnimation) {
      return _StudentAccountSheet(info: info);
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
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(curve),
          child: child,
        ),
      );
    },
  );
}

/// 학습앱 설정 입력 시트(PreviewAcademyDialogSheet) 토큰에 맞춘 계정 모달.
abstract final class _AccountSheetTokens {
  static const double radius = 34;
  static const double borderInset = 4;
  static const double innerPadH = 16;
  static const double innerPadTop = 12;
  static const double innerPadBottom = 20;
  static const double headerToBody = 28;
  static const double cardRadius = 28;
  static const double rowPadH = 24;
  static const double rowPadV = 18;
  /// 학습앱 학원 로고(지름 180)보다 작은 시트용 아바타.
  static const double avatarRadius = 54;
  static const Color surfaceDark = Color(0xFF1C1C1E);
  static const Color surfaceLight = Color(0xFFF2F2F7);
  static const Color groupDark = Color(0xFF2C2C2E);
  static const Color destructive = Color(0xFFFF554F);

  static Color surface(Brightness b) =>
      b == Brightness.dark ? surfaceDark : surfaceLight;

  static Color groupFill(Brightness b) =>
      b == Brightness.dark ? groupDark : Colors.white;

  static Color headerIconBg(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF3A3A3C) : const Color(0xFFE5E5EA);

  static Color subtleBorder(Brightness b) => b == Brightness.dark
      ? const Color(0x33FFFFFF)
      : const Color(0x33000000);
}

class _StudentAccountSheet extends StatefulWidget {
  const _StudentAccountSheet({required this.info});

  final StudentInfo? info;

  @override
  State<_StudentAccountSheet> createState() => _StudentAccountSheetState();
}

class _StudentAccountSheetState extends State<_StudentAccountSheet> {
  bool _busy = false;
  final GlobalKey _themeMenuAnchorKey = GlobalKey();

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await StudentApi.instance.signOut();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      TopGlassSnackBar.show(
        context,
        message: '로그아웃에 실패했어요.',
        icon: Icons.error_outline_rounded,
      );
    }
  }

  void _mockTap(String label) {
    TopGlassSnackBar.show(
      context,
      message: '$label — 곧 추가될 예정이에요.',
      icon: Icons.info_outline_rounded,
    );
  }

  String _themeLabel(ThemeMode mode) =>
      mode == ThemeMode.dark ? '다크' : '기본';

  Future<void> _openThemeMenu() async {
    final box =
        _themeMenuAnchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final current = AppThemeController.mode.value;
    final pickedId = await YggGlassOptionMenu.show(
      context: context,
      anchor: box,
      selectedId: current == ThemeMode.dark ? 'dark' : 'light',
      options: const [
        YggGlassMenuOption(id: 'light', label: '기본'),
        YggGlassMenuOption(id: 'dark', label: '다크'),
      ],
    );
    if (pickedId == null || !mounted) return;
    await AppThemeController.setMode(
      pickedId == 'dark' ? ThemeMode.dark : ThemeMode.light,
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final text = isDark ? Colors.white : Colors.black;
    final sub = isDark
        ? Colors.white.withValues(alpha: 0.55)
        : Colors.black.withValues(alpha: 0.45);
    final divider = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);
    final media = MediaQuery.of(context);
    // 위만 여백, 좌·우·아래는 화면 끝까지 채운다.
    const topGap = 80.0;
    final sheetH = media.size.height - media.padding.top - topGap;

    final info = widget.info;
    final name = info?.name.trim().isNotEmpty == true
        ? info!.name.trim()
        : '학생 계정';
    final meta = [
      if (info != null && info.school.isNotEmpty) info.school,
      if (info?.grade != null) '${info!.grade}학년',
    ].join(' · ');

    const mockItems = ['알림', '학습 기록', '개인정보 및 권한'];

    return Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          width: media.size.width,
          height: sheetH,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _AccountSheetTokens.surface(brightness),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(_AccountSheetTokens.radius),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 32,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(_AccountSheetTokens.borderInset),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  _AccountSheetTokens.innerPadH,
                  _AccountSheetTokens.innerPadTop,
                  _AccountSheetTokens.innerPadH,
                  _AccountSheetTokens.innerPadBottom + media.padding.bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 44,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Text(
                            '계정',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: text,
                              decoration: TextDecoration.none,
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: _CircleIconButton(
                              backgroundColor: _AccountSheetTokens.headerIconBg(
                                brightness,
                              ),
                              borderColor: _AccountSheetTokens.subtleBorder(
                                brightness,
                              ),
                              icon: Icons.close_rounded,
                              iconColor: text,
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        padding: EdgeInsets.zero,
                        children: [
                          // 학원탭 로고·스크린샷형 — 상단 중앙 프로필.
                          const SizedBox(height: 20),
                          Center(
                            child: Material(
                              color: Colors.transparent,
                              shape: const CircleBorder(),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: () {
                                  unawaited(
                                    ProfileAvatarEditScreen.open(
                                      context,
                                      studentName: name,
                                    ),
                                  );
                                },
                                child: StudentAvatarView(
                                  name: name,
                                  radius: _AccountSheetTokens.avatarRadius,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),
                          Text(
                            name,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: text,
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.3,
                              height: 1.15,
                              decoration: TextDecoration.none,
                            ),
                          ),
                          if (meta.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              meta,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: sub,
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                height: 1.25,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ],
                          const SizedBox(height: 28),
                          _GroupedCard(
                            brightness: brightness,
                            children: [
                              _NavRow(
                                label: '학습 프로필',
                                trailingText: name,
                                text: text,
                                sub: sub,
                                onTap: () => _mockTap('학습 프로필'),
                              ),
                              Divider(
                                height: 1,
                                thickness: 1,
                                indent: _AccountSheetTokens.rowPadH,
                                endIndent: _AccountSheetTokens.rowPadH,
                                color: divider,
                              ),
                              ValueListenableBuilder<ThemeMode>(
                                valueListenable: AppThemeController.mode,
                                builder: (context, mode, _) {
                                  return _NavRow(
                                    label: '화면 테마',
                                    trailingText: _themeLabel(mode),
                                    text: text,
                                    sub: sub,
                                    trailing: YggGlassOptionMenuAnchor(
                                      key: _themeMenuAnchorKey,
                                      color: sub,
                                    ),
                                    onTap: _openThemeMenu,
                                  );
                                },
                              ),
                              for (final item in mockItems) ...[
                                Divider(
                                  height: 1,
                                  thickness: 1,
                                  indent: _AccountSheetTokens.rowPadH,
                                  endIndent: _AccountSheetTokens.rowPadH,
                                  color: divider,
                                ),
                                _NavRow(
                                  label: item,
                                  text: text,
                                  sub: sub,
                                  onTap: () => _mockTap(item),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '알림·학습 기록 등 일부 항목은 곧 연결될 예정이에요.',
                            style: TextStyle(
                              color: sub,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              height: 1.35,
                              decoration: TextDecoration.none,
                            ),
                          ),
                          const SizedBox(height: 20),
                          _GroupedCard(
                            brightness: brightness,
                            children: [
                              Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: _busy ? null : _signOut,
                                  borderRadius: BorderRadius.circular(
                                    _AccountSheetTokens.cardRadius,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: _AccountSheetTokens.rowPadH,
                                      vertical: _AccountSheetTokens.rowPadV,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '로그아웃',
                                            style: TextStyle(
                                              color: _busy
                                                  ? _AccountSheetTokens
                                                      .destructive
                                                      .withValues(alpha: 0.45)
                                                  : _AccountSheetTokens
                                                      .destructive,
                                              fontSize: 17,
                                              fontWeight: FontWeight.w700,
                                              decoration: TextDecoration.none,
                                            ),
                                          ),
                                        ),
                                        if (_busy)
                                          const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: YggLoadingIndicator(
                                              size: 18,
                                            ),
                                          )
                                        else
                                          Icon(
                                            Icons.chevron_right_rounded,
                                            size: 22,
                                            color: sub,
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                        ],
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

class _GroupedCard extends StatelessWidget {
  const _GroupedCard({
    required this.brightness,
    required this.children,
  });

  final Brightness brightness;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _AccountSheetTokens.groupFill(brightness),
        borderRadius: BorderRadius.circular(_AccountSheetTokens.cardRadius),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_AccountSheetTokens.cardRadius),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.label,
    required this.text,
    required this.sub,
    required this.onTap,
    this.trailingText,
    this.trailing,
  });

  final String label;
  final String? trailingText;
  final Widget? trailing;
  final Color text;
  final Color sub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: _AccountSheetTokens.rowPadH,
            vertical: _AccountSheetTokens.rowPadV,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: text,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              if (trailingText != null) ...[
                Text(
                  trailingText!,
                  style: TextStyle(
                    color: sub,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(width: 4),
              ],
              trailing ??
                  Icon(Icons.chevron_right_rounded, size: 22, color: sub),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({
    required this.backgroundColor,
    required this.borderColor,
    required this.icon,
    required this.iconColor,
    required this.onPressed,
  });

  final Color backgroundColor;
  final Color borderColor;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: backgroundColor,
        border: Border.all(color: borderColor, width: 0.5),
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(icon, size: 20, color: iconColor),
          ),
        ),
      ),
    );
  }
}
