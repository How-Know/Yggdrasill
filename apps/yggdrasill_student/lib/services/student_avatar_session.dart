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
    // 기존
    [Color(0xFFF5C542), Color(0xFF3DCC7A)],
    [Color(0xFF7BE0C2), Color(0xFF5B8DEF)],
    [Color(0xFF34C759), Color(0xFF30D158)],
    [Color(0xFFFF8A65), Color(0xFFFF5252)],
    [Color(0xFFAB47BC), Color(0xFF5C6BC0)],
    [Color(0xFF26C6DA), Color(0xFF42A5F5)],
    // 추가 (배경 색상 팔레트)
    [Color(0xFFFF8A65), Color(0xFFFF6B9D)], // 오렌지→핑크
    [Color(0xFF9B6DFF), Color(0xFF5B8DEF)], // 퍼플→블루
    [Color(0xFFFFD54F), Color(0xFFFFC107)], // 솔리드 옐로우
    [Color(0xFF4DD0E1), Color(0xFF26C6DA)], // 솔리드 시안
    [Color(0xFFA5D6A7), Color(0xFFFFB74D)], // 연녹→오렌지
    [Color(0xFFF8BBD0), Color(0xFFCE93D8)], // 핑크→라벤더
    [Color(0xFF1A237E), Color(0xFF283593)], // 네이비
    [Color(0xFFD4A574), Color(0xFFC49A6C)], // 골드/베이지
    [Color(0xFF424242), Color(0xFF616161)], // 다크 그레이
    [Color(0xFFE53935), Color(0xFFD32F2F)], // 솔리드 레드
  ];

  /// OS 폰트로 렌더하는 샘플 이모티콘 (원형 배경색 페어).
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

  /// Microsoft Fluent Emoji Flat (단색 SVG). 저장값은 `fluent:<id>`.
  static const fluentEmojis = <FluentEmojiOption>[
    FluentEmojiOption(
      id: 'owl',
      glyph: '🦉',
      asset: 'assets/emoji/fluent/owl.svg',
      background: Color(0xFF3A3A3C),
    ),
    FluentEmojiOption(
      id: 'fox',
      glyph: '🦊',
      asset: 'assets/emoji/fluent/fox.svg',
      background: Color(0xFFE8A87C),
    ),
    FluentEmojiOption(
      id: 'panda',
      glyph: '🐼',
      asset: 'assets/emoji/fluent/panda.svg',
      background: Color(0xFFE8E8ED),
    ),
    FluentEmojiOption(
      id: 'tiger',
      glyph: '🐯',
      asset: 'assets/emoji/fluent/tiger.svg',
      background: Color(0xFFFFD54F),
    ),
    FluentEmojiOption(
      id: 'frog',
      glyph: '🐸',
      asset: 'assets/emoji/fluent/frog.svg',
      background: Color(0xFF81C784),
    ),
    FluentEmojiOption(
      id: 'octopus',
      glyph: '🐙',
      asset: 'assets/emoji/fluent/octopus.svg',
      background: Color(0xFFCE93D8),
    ),
    FluentEmojiOption(
      id: 'unicorn',
      glyph: '🦄',
      asset: 'assets/emoji/fluent/unicorn.svg',
      background: Color(0xFFF8BBD0),
    ),
    FluentEmojiOption(
      id: 'monkey',
      glyph: '🐵',
      asset: 'assets/emoji/fluent/monkey.svg',
      background: Color(0xFFBCAAA4),
    ),
  ];

  static String encodeFluentEmoji(String id) => 'fluent:$id';

  static bool isFluentEmoji(String value) =>
      value.trim().startsWith('fluent:');

  static FluentEmojiOption? fluentOptionFor(String value) {
    final v = value.trim();
    if (!isFluentEmoji(v)) return null;
    final id = v.substring('fluent:'.length);
    for (final e in fluentEmojis) {
      if (e.id == id) return e;
    }
    return null;
  }

  static Color? emojiBackground(String value) {
    final fluent = fluentOptionFor(value);
    if (fluent != null) return fluent.background;
    for (final e in sampleEmojis) {
      if (e.$1 == value) return e.$2;
    }
    return null;
  }

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
    return '${chars[chars.length - 2]}${chars[chars.length - 1]}';
  }
}

/// Fluent Emoji 선택 항목 (번들 SVG).
class FluentEmojiOption {
  const FluentEmojiOption({
    required this.id,
    required this.glyph,
    required this.asset,
    required this.background,
  });

  final String id;
  final String glyph;
  final String asset;
  final Color background;

  String get storageValue => StudentAvatarSession.encodeFluentEmoji(id);
}
