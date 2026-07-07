import 'package:flutter/material.dart';

/// 글래스(블러) UI 공용 토큰.
///
/// 학습앱의 FabTabBarTokens에서 여러 위젯이 공유하는 값만 추출했다.
/// (원본: apps/yggdrasill/lib/screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart)
class YggGlassTokens {
  YggGlassTokens._();

  /// 글래스 시트/스낵바 공용 블러 강도.
  static const double menuGlassBlurSigma = 18;

  /// 확인/주요 액션 색 (브랜드 그린).
  static const Color confirmActionColor = Color(0xFF33A373);
}
