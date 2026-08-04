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
    // 닉네임·아바타 등 최신 값을 반영하기 위해 열 때마다 다시 조회.
    final future = StudentApi.instance.getInfo();
    // setState(() => x = future) 는 Future를 반환해 예외가 난다.
    setState(() {
      _infoFuture = future;
    });
    StudentInfo? info;
    try {
      info = await future;
    } catch (_) {
      // 계정 정보 조회가 실패해도 로그아웃은 제공한다.
    }
    if (!mounted) return;
    await showStudentAccountSheet(context: context, info: info);
    if (!mounted) return;
    // 시트에서 닉네임이 바뀌었을 수 있으니 한 번 더 동기화.
    final refreshed = StudentApi.instance.getInfo();
    setState(() {
      _infoFuture = refreshed;
    });
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
              return const StudentAvatarFallbackInitial(name: '?', radius: 20);
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

/// 애플 뮤직형 프로필 편집 다이얼로그. 저장 시 trim된 닉네임, 취소 시 null.
Future<String?> showNicknameEditDialog({
  required BuildContext context,
  required String legalName,
  required String initialNickname,
}) {
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '프로필 편집',
    barrierColor: Colors.black.withValues(alpha: 0.4),
    transitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (context, animation, secondaryAnimation) {
      return _NicknameEditDialog(
        legalName: legalName,
        initialNickname: initialNickname,
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curve = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      // 하단에서 가운데로 올라오는 모션 (계정 시트·프로필 사진 편집과 같은 방향감).
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

class _NicknameEditDialog extends StatefulWidget {
  const _NicknameEditDialog({
    required this.legalName,
    required this.initialNickname,
  });

  final String legalName;
  final String initialNickname;

  @override
  State<_NicknameEditDialog> createState() => _NicknameEditDialogState();
}

class _NicknameEditDialogState extends State<_NicknameEditDialog> {
  late final TextEditingController _controller;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialNickname);
    _focus = FocusNode();
    // 커서는 끝으로 — 전체 선택(파란 하이라이트) 없음.
    final end = _controller.text.length;
    _controller.selection = TextSelection.collapsed(offset: end);
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

  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final nick = _controller.text.trim();
    try {
      // 체크 = 서버 저장 (별도 저장 버튼 없음).
      await StudentApi.instance.setNickname(nick.isEmpty ? null : nick);
      if (!mounted) return;
      Navigator.of(context).pop(nick);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      TopGlassSnackBar.show(
        context,
        message: '닉네임을 저장하지 못했어요.',
        icon: Icons.error_outline_rounded,
      );
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
    // 계정 시트 바깥면과 동일 surface (그룹 카드 white/2C2C2E 가 아님).
    final card = _AccountSheetTokens.surface(brightness);
    final media = MediaQuery.of(context);
    final dialogW = (media.size.width - 32).clamp(360.0, 560.0);
    // 기존 대비 높이 약 30% 축소.
    final dialogH = (media.size.height * 0.406).clamp(320.0, 450.0);

    final valueStyle = TextStyle(
      color: text,
      fontSize: 17,
      fontWeight: FontWeight.w400,
      letterSpacing: -0.2,
      height: 1.2,
    );
    final labelStyle = TextStyle(
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
                                '프로필 편집',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.3,
                                  color: text,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerLeft,
                                // 프로필 사진 편집·계정 시트와 동일 SolidCapsule.
                                child: SolidCapsuleActionBar(
                                  padding: const EdgeInsets.all(8),
                                  children: [
                                    SolidCapsuleActionButton(
                                      tooltip: '닫기',
                                      icon: Icons.close_rounded,
                                      onPressed: () =>
                                          Navigator.of(context).pop(),
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
                                      tooltip: '완료',
                                      icon: Icons.check_rounded,
                                      onPressed: _saving
                                          ? null
                                          : () => unawaited(_save()),
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
                                      widget.legalName,
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
                                    child: Text('닉네임', style: labelStyle),
                                  ),
                                  Expanded(
                                    child: TextField(
                                      controller: _controller,
                                      focusNode: _focus,
                                      textAlign: TextAlign.start,
                                      textInputAction: TextInputAction.done,
                                      maxLength: 20,
                                      onSubmitted: (_) => _save(),
                                      style: valueStyle,
                                      cursorColor: text,
                                      cursorWidth: 1.5,
                                      enableInteractiveSelection: true,
                                      decoration: InputDecoration(
                                        counterText: '',
                                        hintText: '닉네임',
                                        hintStyle: valueStyle.copyWith(
                                          color: sub,
                                        ),
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        disabledBorder: InputBorder.none,
                                        errorBorder: InputBorder.none,
                                        focusedErrorBorder: InputBorder.none,
                                        filled: false,
                                        isDense: true,
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Divider(height: 1, thickness: 0.5, color: divider),
                          ],
                        ),
                      ),
                      const Spacer(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
                        child: Text(
                          '닉네임은 계정에 표시되는 이름이에요. 실명은 바뀌지 않아요.',
                          style: TextStyle(
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

/// 학습앱 설정 입력 시트(PreviewAcademyDialogSheet) 토큰에 맞춘 계정 모달.
abstract final class _AccountSheetTokens {
  static const double radius = 34;
  static const double borderInset = 4;
  static const double innerPadH = 16;
  static const double innerPadTop = 12;
  static const double innerPadBottom = 20;
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

  /// students.nickname (아바타와 동일 테이블).
  String? _nickname;

  @override
  void initState() {
    super.initState();
    final nick = widget.info?.nickname?.trim() ?? '';
    _nickname = nick.isEmpty ? null : nick;
  }

  String get _legalName {
    final n = widget.info?.name.trim() ?? '';
    return n.isNotEmpty ? n : '학생 계정';
  }

  String get _displayName {
    final nick = (_nickname ?? '').trim();
    return nick.isNotEmpty ? nick : _legalName;
  }

  Future<void> _openNicknameEditDialog() async {
    final saved = await showNicknameEditDialog(
      context: context,
      legalName: _legalName,
      initialNickname: (_nickname ?? '').trim(),
    );
    // 취소(null). 체크는 다이얼로그에서 이미 서버 저장 후 값을 돌려준다.
    if (!mounted || saved == null) return;
    setState(() => _nickname = saved.isEmpty ? null : saved);
  }

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
    final name = _displayName;
    final legalName = _legalName;
    final hasNickname = (_nickname ?? '').trim().isNotEmpty;
    final meta = [
      if (info != null && info.school.isNotEmpty) info.school,
      if (info?.grade != null) '${info!.grade}학년',
    ].join(' · ');
    // Material DefaultTextStyle merge로 크기가 달라 보이지 않도록 동일 스타일 공유.
    final nameStyle = TextStyle(
      inherit: false,
      color: text,
      fontSize: 26,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.3,
      height: 1.15,
      fontFamily: Theme.of(context).textTheme.bodyLarge?.fontFamily,
      decoration: TextDecoration.none,
    );

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
                      height: 56,
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
                            child: _SolidCircleCloseButton(
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
                                      studentName: legalName,
                                    ),
                                  );
                                },
                                child: StudentAvatarView(
                                  name: legalName,
                                  radius: _AccountSheetTokens.avatarRadius,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),
                          // 닉네임(표시명)만 탭 가능. 실명 줄은 고정·비클릭.
                          // 폰트: 닉네임·이름 모두 nameStyle(26) — 이름 기준 통일.
                          Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 280),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap: () =>
                                          unawaited(_openNicknameEditDialog()),
                                      borderRadius: BorderRadius.circular(12),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 4,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            Flexible(
                                              child: Text(
                                                name,
                                                textAlign: TextAlign.center,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: nameStyle,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Icon(
                                              Icons.edit_rounded,
                                              size: 18,
                                              color: sub,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (hasNickname) ...[
                                    const SizedBox(height: 4),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      child: Text(
                                        legalName,
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: nameStyle,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
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

/// 프로필 편집 닫기와 동일 솔리드 스타일 · 정원형.
class _SolidCircleCloseButton extends StatelessWidget {
  const _SolidCircleCloseButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SolidCapsuleActionBar(
      padding: const EdgeInsets.all(8),
      children: [
        SolidCapsuleActionButton(
          tooltip: '닫기',
          icon: Icons.close_rounded,
          onPressed: onPressed,
        ),
      ],
    );
  }
}

