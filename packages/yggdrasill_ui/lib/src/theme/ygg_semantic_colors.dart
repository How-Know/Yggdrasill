import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 역할 기반 색상 토큰. UI는 가능한 한 [Color] 리터럴 대신 이 확장을 사용한다.
///
/// 원본: apps/yggdrasill/lib/theme/ygg_semantic_colors.dart (시범 공유 추출)
@immutable
class YggSemanticColors extends ThemeExtension<YggSemanticColors> {
  final Color surfaceBase;

  const YggSemanticColors({
    required this.surfaceBase,
  });

  /// 화면 전체 배경 — Light mode (순백보다 부드러운 오프화이트)
  static const Color surfaceBaseLight = Color(0xFFF8F8F8);

  /// 화면 전체 배경 — Dark mode 후보 (Preview에서 Enter로 순환)
  static const List<Color> surfaceBaseDarkCandidates = [
    Color(0xFF0B1112), // 신형 틸 다크 (현재 설정/NavRail)
    Color(0xFF1F1F1F), // 레거시 메인 셸 회색 (비교용)
    Color(0xFF000000), // 순수 검정 (비교용)
  ];

  static const List<String> surfaceBaseDarkCandidateLabels = [
    '#0B1112',
    '#1F1F1F',
    '#000000',
  ];

  /// 화면 전체 배경 — Dark mode (목업 확정)
  static const Color surfaceBaseDarkDefault = Color(0xFF000000);

  static String hex(Color color) {
    final value = color.toARGB32() & 0xFFFFFF;
    return '#${value.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  factory YggSemanticColors.light() {
    return const YggSemanticColors(surfaceBase: surfaceBaseLight);
  }

  factory YggSemanticColors.dark({Color? surfaceBase}) {
    return YggSemanticColors(
      surfaceBase: surfaceBase ?? surfaceBaseDarkDefault,
    );
  }

  @override
  YggSemanticColors copyWith({Color? surfaceBase}) {
    return YggSemanticColors(
      surfaceBase: surfaceBase ?? this.surfaceBase,
    );
  }

  @override
  YggSemanticColors lerp(ThemeExtension<YggSemanticColors>? other, double t) {
    if (other is! YggSemanticColors) return this;
    return YggSemanticColors(
      surfaceBase: Color.lerp(surfaceBase, other.surfaceBase, t) ?? surfaceBase,
    );
  }
}

extension YggSemanticColorsContext on BuildContext {
  Color get yggSurfaceBase {
    return Theme.of(this).extension<YggSemanticColors>()?.surfaceBase ??
        YggSemanticColors.surfaceBaseDarkDefault;
  }
}

class AppThemeController {
  AppThemeController._();

  static const String _prefsKey = 'app_theme_mode';
  static final ValueNotifier<ThemeMode> mode = ValueNotifier<ThemeMode>(
    ThemeMode.light,
  );

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    mode.value = _themeModeFromString(prefs.getString(_prefsKey));
  }

  static Future<void> setMode(ThemeMode next) async {
    mode.value = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, _themeModeToString(next));
  }

  static ThemeMode _themeModeFromString(String? raw) {
    switch ((raw ?? '').trim()) {
      case 'system':
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.light;
    }
  }

  static String _themeModeToString(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'system';
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
    }
  }
}
