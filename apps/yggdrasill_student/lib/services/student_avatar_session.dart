import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 세션 동안 유지되는 학생 아바타 선택 상태 (서버 hydrate + 로컬 미리보기).
enum StudentAvatarKind { monogram, emoji, photo }

class StudentAvatarSession extends ChangeNotifier {
  StudentAvatarSession._();
  static final StudentAvatarSession instance = StudentAvatarSession._();

  StudentAvatarKind kind = StudentAvatarKind.monogram;
  String emoji = '🦉';
  Uint8List? photoBytes;
  String? photoUrl;
  int monogramStyleIndex = 0;

  static const monogramStyles = <List<Color>>[
    [Color(0xFFF5C542), Color(0xFF3DCC7A)],
    [Color(0xFF7BE0C2), Color(0xFF5B8DEF)],
    [Color(0xFF34C759), Color(0xFF30D158)],
    [Color(0xFFFF8A65), Color(0xFFFF5252)],
    [Color(0xFFAB47BC), Color(0xFF5C6BC0)],
    [Color(0xFF26C6DA), Color(0xFF42A5F5)],
  ];

  /// 고퀄리티 샘플 이모티콘 (원형 배경색 페어).
  static const sampleEmojis = <(String, Color)>[
    ('🦉', Color(0xFF3A3A3C)),
    ('🦊', Color(0xFFE8A87C)),
    ('🐼', Color(0xFFE8E8ED)),
    ('🐯', Color(0xFFFFD54F)),
    ('🐸', Color(0xFF81C784)),
    ('🐙', Color(0xFFCE93D8)),
    ('🦄', Color(0xFFF8BBD0)),
    ('🐵', Color(0xFFBCAAA4)),
  ];

  void hydrateFromServer({
    String? kindRaw,
    String? url,
    String? emojiValue,
    int? monogramStyle,
  }) {
    final k = (kindRaw ?? '').trim().toLowerCase();
    switch (k) {
      case 'photo':
        final u = (url ?? '').trim();
        if (u.isEmpty) {
          kind = StudentAvatarKind.monogram;
          photoUrl = null;
          photoBytes = null;
          if (monogramStyle != null) {
            monogramStyleIndex =
                monogramStyle.clamp(0, monogramStyles.length - 1);
          }
        } else {
          kind = StudentAvatarKind.photo;
          if (photoUrl != u) photoBytes = null;
          photoUrl = u;
        }
      case 'emoji':
        kind = StudentAvatarKind.emoji;
        emoji = (emojiValue ?? '').trim().isEmpty ? '🦉' : emojiValue!.trim();
        photoBytes = null;
        photoUrl = null;
      case 'monogram':
        kind = StudentAvatarKind.monogram;
        monogramStyleIndex =
            (monogramStyle ?? 0).clamp(0, monogramStyles.length - 1);
        photoBytes = null;
        photoUrl = null;
      default:
        // 미설정이면 기본 모노그램 유지 (로컬 선택 덮어쓰지 않음 원하면 여기선 서버 우선).
        if (k.isEmpty) {
          kind = StudentAvatarKind.monogram;
          photoBytes = null;
          photoUrl = null;
          if (monogramStyle != null) {
            monogramStyleIndex =
                monogramStyle.clamp(0, monogramStyles.length - 1);
          }
        }
    }
    notifyListeners();
  }

  void applyMonogram(int styleIndex) {
    kind = StudentAvatarKind.monogram;
    monogramStyleIndex = styleIndex.clamp(0, monogramStyles.length - 1);
    photoBytes = null;
    photoUrl = null;
    notifyListeners();
  }

  void applyEmoji(String value) {
    kind = StudentAvatarKind.emoji;
    emoji = value;
    photoBytes = null;
    photoUrl = null;
    notifyListeners();
  }

  void applyPhoto(Uint8List bytes, {String? url}) {
    kind = StudentAvatarKind.photo;
    photoBytes = bytes;
    if (url != null) photoUrl = url;
    notifyListeners();
  }

  void applyPhotoUrl(String url) {
    kind = StudentAvatarKind.photo;
    photoUrl = url;
    notifyListeners();
  }

  void clearToMonogram() {
    kind = StudentAvatarKind.monogram;
    photoBytes = null;
    photoUrl = null;
    notifyListeners();
  }

  /// 모노그램에 넣을 1~2글자 (한글 이름 기준).
  static String monogramLabel(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    final chars = trimmed.characters.toList();
    if (chars.length == 1) return chars.first;
    // 세 글자 이상이면 이름 끝 2글자(성 제외)가 자연스럽다.
    return '${chars[chars.length - 2]}${chars[chars.length - 1]}';
  }
}
