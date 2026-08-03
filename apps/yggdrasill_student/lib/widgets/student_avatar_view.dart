import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/student_avatar_session.dart';

/// [StudentAvatarSession] 상태를 그리는 원형 아바타.
class StudentAvatarView extends StatelessWidget {
  const StudentAvatarView({
    super.key,
    required this.name,
    required this.radius,
    this.showBorder = false,
  });

  final String name;
  final double radius;
  final bool showBorder;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: StudentAvatarSession.instance,
      builder: (context, _) {
        final session = StudentAvatarSession.instance;
        final size = radius * 2;
        Widget child;
        switch (session.kind) {
          case StudentAvatarKind.photo:
            final bytes = session.photoBytes;
            final url = session.photoUrl;
            if (bytes != null) {
              child = ClipOval(
                child: Image.memory(
                  bytes,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                ),
              );
            } else if (url != null && url.isNotEmpty) {
              child = ClipOval(
                child: Image.network(
                  url,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      _MonogramDisk(name: name, radius: radius),
                ),
              );
            } else {
              child = _MonogramDisk(name: name, radius: radius);
            }
          case StudentAvatarKind.emoji:
            child = _EmojiDisk(
              emoji: session.emoji,
              radius: radius,
            );
          case StudentAvatarKind.monogram:
            child = _MonogramDisk(
              name: name,
              radius: radius,
              styleIndex: session.monogramStyleIndex,
            );
        }

        if (!showBorder) return child;
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.2),
              width: 2,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: child,
        );
      },
    );
  }
}

class _EmojiDisk extends StatelessWidget {
  const _EmojiDisk({
    required this.emoji,
    required this.radius,
    this.showShadow = false,
  });

  final String emoji;
  final double radius;
  final bool showShadow;

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    final fluent = StudentAvatarSession.fluentOptionFor(emoji);
    final bg = StudentAvatarSession.emojiBackground(emoji) ??
        const Color(0xFF3A3A3C);
    final imageSize = radius * 1.35;

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: bg,
        boxShadow: showShadow
            ? const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 24,
                  offset: Offset(0, 10),
                ),
              ]
            : null,
      ),
      child: fluent != null
          ? SvgPicture.asset(
              fluent.asset,
              width: imageSize,
              height: imageSize,
              fit: BoxFit.contain,
            )
          : Text(
              emoji,
              style: TextStyle(fontSize: radius * 1.05, height: 1.1),
            ),
    );
  }
}

class _MonogramDisk extends StatelessWidget {
  const _MonogramDisk({
    required this.name,
    required this.radius,
    this.styleIndex,
  });

  final String name;
  final double radius;
  final int? styleIndex;

  @override
  Widget build(BuildContext context) {
    final idx = styleIndex ?? StudentAvatarSession.instance.monogramStyleIndex;
    final colors = StudentAvatarSession.monogramStyles[
        idx.clamp(0, StudentAvatarSession.monogramStyles.length - 1)];
    final label = StudentAvatarSession.monogramLabel(name);
    final size = radius * 2;

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
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * (label.length >= 2 ? 0.72 : 0.9),
          fontWeight: FontWeight.w800,
          height: 1.05,
          letterSpacing: label.length >= 2 ? -0.5 : 0,
          shadows: const [
            Shadow(
              color: Color(0x33000000),
              blurRadius: 6,
              offset: Offset(0, 1),
            ),
          ],
        ),
      ),
    );
  }
}

/// 세션 아바타가 없을 때 쓰는 단색 폴백 (계정 버튼 등).
class StudentAvatarFallbackInitial extends StatelessWidget {
  const StudentAvatarFallbackInitial({
    super.key,
    required this.name,
    required this.radius,
  });

  final String name;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim().characters.first;
    return CircleAvatar(
      radius: radius,
      backgroundColor: YggGlassTokens.confirmActionColor.withValues(alpha: 0.14),
      foregroundColor: YggGlassTokens.confirmActionColor,
      child: Text(
        initial,
        style: TextStyle(
          fontSize: radius * 0.75,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
