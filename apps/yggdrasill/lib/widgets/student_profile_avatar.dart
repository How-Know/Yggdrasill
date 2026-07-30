import 'package:flutter/material.dart';

import '../models/student.dart';

/// 학습앱에서 학생 프로필 사진/이모지/모노그램을 그리는 원형 아바타.
class StudentProfileAvatar extends StatelessWidget {
  const StudentProfileAvatar({
    super.key,
    required this.student,
    required this.radius,
    this.fallbackColor,
  });

  final Student student;
  final double radius;
  final Color? fallbackColor;

  static const monogramStyles = <List<Color>>[
    [Color(0xFFF5C542), Color(0xFF3DCC7A)],
    [Color(0xFF7BE0C2), Color(0xFF5B8DEF)],
    [Color(0xFF34C759), Color(0xFF30D158)],
    [Color(0xFFFF8A65), Color(0xFFFF5252)],
    [Color(0xFFAB47BC), Color(0xFF5C6BC0)],
    [Color(0xFF26C6DA), Color(0xFF42A5F5)],
  ];

  static const emojiBackgrounds = <String, Color>{
    '🦉': Color(0xFF3A3A3C),
    '🦊': Color(0xFFE8A87C),
    '🐼': Color(0xFFE8E8ED),
    '🐯': Color(0xFFFFD54F),
    '🐸': Color(0xFF81C784),
    '🐙': Color(0xFFCE93D8),
    '🦄': Color(0xFFF8BBD0),
    '🐵': Color(0xFFBCAAA4),
  };

  static String monogramLabel(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    final chars = trimmed.characters.toList();
    if (chars.length == 1) return chars.first;
    return '${chars[chars.length - 2]}${chars[chars.length - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    final kind = (student.avatarKind ?? '').trim().toLowerCase();

    if (kind == 'photo') {
      final url = (student.avatarUrl ?? '').trim();
      if (url.isNotEmpty) {
        return ClipOval(
          child: Image.network(
            url,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _fallbackDisk(size),
          ),
        );
      }
    }

    if (kind == 'emoji') {
      final emoji = (student.avatarEmoji ?? '').trim();
      if (emoji.isNotEmpty) {
        return Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: emojiBackgrounds[emoji] ?? const Color(0xFF3A3A3C),
          ),
          child: Text(
            emoji,
            style: TextStyle(fontSize: radius * 1.05, height: 1.1),
          ),
        );
      }
    }

    if (kind == 'monogram' || kind == 'photo' || kind.isEmpty) {
      final idx = (student.avatarMonogramStyle ?? 0)
          .clamp(0, monogramStyles.length - 1);
      final colors = monogramStyles[idx];
      final label = monogramLabel(student.name);
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
          ),
        ),
      );
    }

    return _fallbackDisk(size);
  }

  Widget _fallbackDisk(double size) {
    final initial = student.name.trim().isEmpty
        ? '?'
        : student.name.trim().characters.first;
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: fallbackColor ?? const Color(0xFF2C3A3A),
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * 0.8,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
