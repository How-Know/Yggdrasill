import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image_picker/image_picker.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/student_api.dart';
import '../services/student_avatar_recent_photos.dart';
import '../services/student_avatar_session.dart';
import '../widgets/student_avatar_view.dart';
import '../widgets/student_status_island.dart';
import 'avatar_circle_crop_screen.dart';

/// 프로필 사진 편집 — 전체 화면. 상태 아일랜드는 호스트 오버레이로 상단 유지.
class ProfileAvatarEditScreen extends StatefulWidget {
  const ProfileAvatarEditScreen({
    super.key,
    required this.studentName,
  });

  final String studentName;

  static Future<void> open(BuildContext context, {required String studentName}) {
    // 과제 상세 시트와 동일: 아래에서 위로 슬라이드.
    const duration = Duration(milliseconds: 420);
    return Navigator.of(context, rootNavigator: true).push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: duration,
        reverseTransitionDuration: duration,
        pageBuilder: (context, animation, secondaryAnimation) {
          return ProfileAvatarEditScreen(studentName: studentName);
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curve = CurvedAnimation(
            parent: animation,
            curve: Curves.easeInOutCubic,
            reverseCurve: Curves.easeInOutCubic,
          );
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(curve),
            child: child,
          );
        },
      ),
    );
  }

  @override
  State<ProfileAvatarEditScreen> createState() =>
      _ProfileAvatarEditScreenState();
}

class _ProfileAvatarEditScreenState extends State<ProfileAvatarEditScreen> {
  late StudentAvatarKind _kind;
  late String _emoji;
  late int _monogramStyle;
  Uint8List? _photoBytes;
  String? _photoUrl;
  bool _photoDirty = false;
  bool _picking = false;
  bool _saving = false;
  List<Uint8List> _recentPhotos = const [];

  @override
  void initState() {
    super.initState();
    final s = StudentAvatarSession.instance;
    _kind = s.kind;
    _emoji = s.emoji;
    _monogramStyle = s.monogramStyleIndex;
    _photoBytes = s.photoBytes;
    _photoUrl = s.photoUrl;
    _loadRecentPhotos();
  }

  String get _name =>
      widget.studentName.trim().isEmpty ? '학생' : widget.studentName.trim();

  Future<void> _loadRecentPhotos() async {
    var list = await StudentAvatarRecentPhotos.instance.load();
    final current = _photoBytes;
    if (current != null &&
        current.isNotEmpty &&
        !list.any((b) => StudentAvatarRecentPhotos.sameBytes(b, current))) {
      list = await StudentAvatarRecentPhotos.instance.push(current);
    }
    if (!mounted) return;
    setState(() => _recentPhotos = list);
  }

  Future<void> _applyCroppedPhoto(Uint8List cropped) async {
    final recent = await StudentAvatarRecentPhotos.instance.push(cropped);
    if (!mounted) return;
    setState(() {
      _kind = StudentAvatarKind.photo;
      _photoBytes = cropped;
      _photoUrl = null;
      _photoDirty = true;
      _recentPhotos = recent;
    });
  }

  void _selectRecentPhoto(Uint8List bytes) {
    setState(() {
      _kind = StudentAvatarKind.photo;
      _photoBytes = bytes;
      _photoUrl = null;
      _photoDirty = true;
    });
  }

  bool _isSelectedPhoto(Uint8List bytes) {
    if (_kind != StudentAvatarKind.photo || _photoBytes == null) return false;
    return StudentAvatarRecentPhotos.sameBytes(_photoBytes!, bytes);
  }

  Future<void> _pickPhoto() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 4096,
        maxHeight: 4096,
        imageQuality: 95,
      );
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      final cropped = await AvatarCircleCropScreen.open(
        context,
        imageBytes: bytes,
      );
      if (cropped == null || !mounted) return;
      await _applyCroppedPhoto(cropped);
    } catch (_) {
      if (!mounted) return;
      TopGlassSnackBar.show(
        context,
        message: '사진을 불러오지 못했어요.',
        icon: Icons.error_outline_rounded,
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _clearPhoto() {
    setState(() {
      _photoBytes = null;
      _photoUrl = null;
      _photoDirty = true;
      if (_kind == StudentAvatarKind.photo) {
        _kind = StudentAvatarKind.monogram;
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final session = StudentAvatarSession.instance;
    try {
      switch (_kind) {
        case StudentAvatarKind.photo:
          var url = _photoUrl;
          if (_photoDirty && _photoBytes != null) {
            url = await StudentApi.instance.uploadAvatarPhoto(_photoBytes!);
          }
          if (url == null || url.isEmpty) {
            await StudentApi.instance.setAvatar(
              kind: 'monogram',
              monogramStyle: _monogramStyle,
            );
            session.applyMonogram(_monogramStyle);
          } else {
            await StudentApi.instance.setAvatar(kind: 'photo', url: url);
            if (_photoBytes != null) {
              session.applyPhoto(_photoBytes!, url: url);
            } else {
              session.applyPhotoUrl(url);
            }
          }
        case StudentAvatarKind.emoji:
          await StudentApi.instance.setAvatar(kind: 'emoji', emoji: _emoji);
          session.applyEmoji(_emoji);
        case StudentAvatarKind.monogram:
          await StudentApi.instance.setAvatar(
            kind: 'monogram',
            monogramStyle: _monogramStyle,
          );
          session.applyMonogram(_monogramStyle);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      TopGlassSnackBar.show(
        context,
        message: '프로필 저장에 실패했어요.',
        icon: Icons.error_outline_rounded,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _previewAvatar({required double radius}) {
    final size = radius * 2;
    switch (_kind) {
      case StudentAvatarKind.photo:
        if (_photoBytes != null) {
          return ClipOval(
            child: Image.memory(
              _photoBytes!,
              width: size,
              height: size,
              fit: BoxFit.cover,
            ),
          );
        }
        final url = _photoUrl;
        if (url != null && url.isNotEmpty) {
          return ClipOval(
            child: Image.network(
              url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  StudentAvatarView(name: _name, radius: radius),
            ),
          );
        }
        return StudentAvatarView(name: _name, radius: radius);
      case StudentAvatarKind.emoji:
        final fluent = StudentAvatarSession.fluentOptionFor(_emoji);
        final bg = StudentAvatarSession.emojiBackground(_emoji) ??
            const Color(0xFF3A3A3C);
        return Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: bg,
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: fluent != null
              ? SvgPicture.asset(
                  fluent.asset,
                  width: radius * 1.35,
                  height: radius * 1.35,
                  fit: BoxFit.contain,
                )
              : Text(
                  _emoji,
                  style: TextStyle(fontSize: radius * 1.08, height: 1.1),
                ),
        );
      case StudentAvatarKind.monogram:
        final colors = StudentAvatarSession.monogramStyles[_monogramStyle];
        final label = StudentAvatarSession.monogramLabel(_name);
        return Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Text(
            label,
            style: TextStyle(
              color: Colors.white,
              fontSize: radius * (label.length >= 2 ? 0.7 : 0.88),
              fontWeight: FontWeight.w800,
              height: 1.05,
              letterSpacing: -0.6,
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF000000) : const Color(0xFFF2F2F7);
    final text = isDark ? Colors.white : Colors.black;
    final sub = text.withValues(alpha: 0.5);
    final chipBg = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA);
    final sectionSlot = isDark ? const Color(0xFF1C1C1E) : Colors.white;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: bg,
        body: Column(
          children: [
            StudentStatusIslandToolbarSlot(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    // 과제 상세 시트 뒤로가기와 동일 SolidCapsule 원형.
                    SolidCapsuleActionBar(
                      padding: const EdgeInsets.all(8),
                      children: [
                        SolidCapsuleActionButton(
                          tooltip: '닫기',
                          icon: Icons.close_rounded,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                    const Spacer(),
                    // 중앙은 상태 아일랜드 자리.
                    const SizedBox(width: 128),
                    const Spacer(),
                    SolidCapsuleActionBar(
                      padding: const EdgeInsets.all(8),
                      children: [
                        SolidCapsuleActionButton(
                          tooltip: '완료',
                          icon: Icons.check_rounded,
                          onPressed: _saving ? null : () => _save(),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: chipBg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  child: Text(
                    '아바타',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: text,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                children: [
                  const SizedBox(height: 12),
                  Center(
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        _previewAvatar(radius: 78),
                        if (_kind == StudentAvatarKind.photo &&
                            _photoBytes != null)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Material(
                              color: const Color(0xE63A3A3C),
                              shape: const CircleBorder(),
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: _clearPhoto,
                                child: const SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: Icon(
                                    Icons.remove_rounded,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  _SectionHeader(title: '사진', color: text, sub: sub),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 76,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        _CircleChoice(
                          selected: false,
                          onTap: _picking ? null : _pickPhoto,
                          child: _picking
                              ? const YggLoadingIndicator(size: 22)
                              : Icon(
                                  Icons.photo_library_rounded,
                                  color: sub,
                                  size: 28,
                                ),
                          fill: sectionSlot,
                        ),
                        for (var i = 0;
                            i < StudentAvatarRecentPhotos.maxCount;
                            i++) ...[
                          const SizedBox(width: 12),
                          if (i < _recentPhotos.length)
                            _CircleChoice(
                              selected: _isSelectedPhoto(_recentPhotos[i]),
                              onTap: () =>
                                  _selectRecentPhoto(_recentPhotos[i]),
                              fill: sectionSlot,
                              child: ClipOval(
                                child: Image.memory(
                                  _recentPhotos[i],
                                  width: 68,
                                  height: 68,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            )
                          else
                            _CircleChoice(
                              selected: false,
                              onTap: null,
                              fill: isDark
                                  ? const Color(0xFF2C2C2E)
                                  : const Color(0xFFE8E8ED),
                              child: const SizedBox.shrink(),
                            ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  _SectionHeader(title: '이모티콘', color: text, sub: sub),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 76,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (var i = 0;
                            i < StudentAvatarSession.sampleEmojis.length;
                            i++) ...[
                          if (i > 0) const SizedBox(width: 12),
                          Builder(
                            builder: (context) {
                              final item =
                                  StudentAvatarSession.sampleEmojis[i];
                              final selected = _kind ==
                                      StudentAvatarKind.emoji &&
                                  _emoji == item.$1;
                              return _CircleChoice(
                                selected: selected,
                                onTap: () => setState(() {
                                  _kind = StudentAvatarKind.emoji;
                                  _emoji = item.$1;
                                }),
                                fill: item.$2,
                                child: Text(
                                  item.$1,
                                  style: const TextStyle(
                                    fontSize: 34,
                                    height: 1.1,
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 76,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (var i = 0;
                            i < StudentAvatarSession.fluentEmojis.length;
                            i++) ...[
                          if (i > 0) const SizedBox(width: 12),
                          Builder(
                            builder: (context) {
                              final item =
                                  StudentAvatarSession.fluentEmojis[i];
                              final selected = _kind ==
                                      StudentAvatarKind.emoji &&
                                  _emoji == item.storageValue;
                              return _CircleChoice(
                                selected: selected,
                                onTap: () => setState(() {
                                  _kind = StudentAvatarKind.emoji;
                                  _emoji = item.storageValue;
                                }),
                                fill: item.background,
                                child: SvgPicture.asset(
                                  item.asset,
                                  width: 40,
                                  height: 40,
                                  fit: BoxFit.contain,
                                ),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  _SectionHeader(title: '모노그램', color: text, sub: sub),
                  const SizedBox(height: 12),
                  Builder(
                    builder: (context) {
                      final styles = StudentAvatarSession.monogramStyles;
                      final mid = (styles.length + 1) ~/ 2;
                      Widget row(int from, int to) {
                        return SizedBox(
                          height: 76,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: to - from,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 12),
                            itemBuilder: (context, local) {
                              final i = from + local;
                              return _CircleChoice(
                                selected:
                                    _kind == StudentAvatarKind.monogram &&
                                        _monogramStyle == i,
                                onTap: () => setState(() {
                                  _kind = StudentAvatarKind.monogram;
                                  _monogramStyle = i;
                                }),
                                fill: Colors.transparent,
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: styles[i],
                                ),
                                child: Text(
                                  StudentAvatarSession.monogramLabel(_name),
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.4,
                                    shadows: const [
                                      Shadow(
                                        color: Color(0x40000000),
                                        blurRadius: 4,
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        );
                      }

                      return Column(
                        children: [
                          row(0, mid),
                          const SizedBox(height: 12),
                          row(mid, styles.length),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.color,
    required this.sub,
  });

  final String title;
  final Color color;
  final Color sub;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: color,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(width: 2),
        Icon(Icons.chevron_right_rounded, size: 22, color: sub),
      ],
    );
  }
}

class _CircleChoice extends StatelessWidget {
  const _CircleChoice({
    required this.selected,
    required this.onTap,
    required this.child,
    required this.fill,
    this.gradient,
  });

  final bool selected;
  final VoidCallback? onTap;
  final Widget child;
  final Color fill;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    final ring = YggGlassTokens.confirmActionColor;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 72,
          height: 72,
          padding: EdgeInsets.all(selected ? 3 : 0),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: selected
                ? Border.all(color: ring, width: 3)
                : Border.all(color: Colors.transparent, width: 3),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: gradient == null ? fill : null,
              gradient: gradient,
            ),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
