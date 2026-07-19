import 'package:flutter/material.dart';

import 'ygg_semantic_colors.dart';

/// 학습앱(main.dart)과 동일한 라이트/다크 ThemeData 빌더.
///
/// Kakao 폰트는 각 앱이 assets로 포함해야 한다 (폰트 패밀리명만 공유).
ThemeData buildYggLightTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: _accent,
    brightness: Brightness.light,
  ).copyWith(
    primary: _accent,
    surface: YggSemanticColors.surfaceBaseLight,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: colorScheme,
    extensions: const <ThemeExtension<dynamic>>[
      YggSemanticColors(
        surfaceBase: YggSemanticColors.surfaceBaseLight,
      ),
    ],
    scaffoldBackgroundColor: YggSemanticColors.surfaceBaseLight,
    appBarTheme: const AppBarTheme(
      toolbarHeight: 80,
      backgroundColor: YggSemanticColors.surfaceBaseLight,
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: YggSemanticColors.surfaceBaseLight,
      selectedIconTheme: IconThemeData(color: Colors.black, size: 30),
      unselectedIconTheme: IconThemeData(color: Colors.black54, size: 30),
      minWidth: 84,
      indicatorColor: Color(0xFFE5E5EA),
      groupAlignment: -1,
      useIndicator: true,
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFF1976D2),
      foregroundColor: Colors.white,
    ),
    inputDecorationTheme: _inputDecorationTheme(
      borderColor: const Color(0x33000000),
      fillColor: Colors.white,
    ),
    textSelectionTheme: _textSelectionTheme,
    fontFamily: 'KakaoSmallSans',
    textTheme: _kakaoTextTheme,
  );
}

ThemeData buildYggDarkTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: _accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: _accent,
    surface: YggSemanticColors.surfaceBaseDarkDefault,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    extensions: const <ThemeExtension<dynamic>>[
      YggSemanticColors(
        surfaceBase: YggSemanticColors.surfaceBaseDarkDefault,
      ),
    ],
    scaffoldBackgroundColor: YggSemanticColors.surfaceBaseDarkDefault,
    appBarTheme: const AppBarTheme(
      toolbarHeight: 80,
      backgroundColor: YggSemanticColors.surfaceBaseDarkDefault,
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: YggSemanticColors.surfaceBaseDarkDefault,
      selectedIconTheme: IconThemeData(color: Colors.white, size: 30),
      unselectedIconTheme: IconThemeData(color: Colors.white70, size: 30),
      minWidth: 84,
      indicatorColor: Color(0xFF0F467D),
      groupAlignment: -1,
      useIndicator: true,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F1F),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white24),
      ),
      textStyle: const TextStyle(color: Colors.white),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFF1976D2),
      foregroundColor: Colors.white,
    ),
    inputDecorationTheme: _inputDecorationTheme(
      borderColor: const Color(0x3DFFFFFF),
      fillColor: const Color(0xFF15171C),
    ),
    textSelectionTheme: _textSelectionTheme,
    fontFamily: 'KakaoSmallSans',
    textTheme: _kakaoTextTheme,
  );
}

const Color _accent = Color(0xFF33A373);

const TextSelectionThemeData _textSelectionTheme = TextSelectionThemeData(
  cursorColor: _accent,
  selectionColor: Color(0x5933A373),
  selectionHandleColor: _accent,
);

InputDecorationTheme _inputDecorationTheme({
  required Color borderColor,
  required Color fillColor,
}) {
  const radius = BorderRadius.all(Radius.circular(10));
  return InputDecorationTheme(
    filled: true,
    fillColor: fillColor,
    border: const OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: Colors.transparent),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: borderColor),
    ),
    focusedBorder: const OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: _accent, width: 1.6),
    ),
    floatingLabelStyle: const TextStyle(
      color: _accent,
      fontWeight: FontWeight.w700,
    ),
  );
}

const TextTheme _kakaoTextTheme = TextTheme(
  displayLarge: TextStyle(fontFamily: 'KakaoBigSans'),
  displayMedium: TextStyle(fontFamily: 'KakaoBigSans'),
  displaySmall: TextStyle(fontFamily: 'KakaoBigSans'),
  headlineLarge: TextStyle(fontFamily: 'KakaoBigSans'),
  headlineMedium: TextStyle(fontFamily: 'KakaoBigSans'),
  headlineSmall: TextStyle(fontFamily: 'KakaoBigSans'),
  titleLarge: TextStyle(fontFamily: 'KakaoBigSans'),
  titleMedium: TextStyle(fontFamily: 'KakaoBigSans'),
  titleSmall: TextStyle(fontFamily: 'KakaoBigSans'),
  bodyLarge: TextStyle(fontFamily: 'KakaoSmallSans'),
  bodyMedium: TextStyle(fontFamily: 'KakaoSmallSans'),
  bodySmall: TextStyle(fontFamily: 'KakaoSmallSans'),
  labelLarge: TextStyle(fontFamily: 'KakaoSmallSans'),
  labelMedium: TextStyle(fontFamily: 'KakaoSmallSans'),
  labelSmall: TextStyle(fontFamily: 'KakaoSmallSans'),
);
