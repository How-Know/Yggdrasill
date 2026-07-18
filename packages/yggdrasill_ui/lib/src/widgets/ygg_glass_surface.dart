import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/ygg_glass_tokens.dart';

/// Yggdrasill 공용 iOS 스타일 글래스 표면.
///
/// 배경색을 직접 칠하지 않고 뒤 콘텐츠를 블러 처리해 대형 화면에서도
/// 깊이감이 유지된다. [tint]로 밝은/어두운 배경에 맞출 수 있다.
class YggGlassSurface extends StatelessWidget {
  const YggGlassSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.borderRadius = const BorderRadius.all(Radius.circular(32)),
    this.blurSigma = YggGlassTokens.menuGlassBlurSigma,
    this.tint = const Color(0x8F16181D),
    this.borderColor = const Color(0x52FFFFFF),
    this.boxShadow = const [
      BoxShadow(
        color: Color(0x33000000),
        blurRadius: 30,
        offset: Offset(0, 14),
      ),
    ],
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final double blurSigma;
  final Color tint;
  final Color borderColor;
  final List<BoxShadow> boxShadow;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tint,
            borderRadius: borderRadius,
            border: Border.all(color: borderColor, width: 1),
            boxShadow: boxShadow,
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// 글래스 표면과 동일한 재질의 터치 버튼.
class YggGlassButton extends StatelessWidget {
  const YggGlassButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
    this.borderRadius = const BorderRadius.all(Radius.circular(999)),
    this.tint = const Color(0xA31B1D22),
    this.enabled = true,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final Color tint;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final effectiveOnPressed = enabled ? onPressed : null;
    return Opacity(
      opacity: enabled ? 1 : 0.48,
      child: YggGlassSurface(
        padding: EdgeInsets.zero,
        borderRadius: borderRadius,
        tint: tint,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: borderRadius,
            onTap: effectiveOnPressed,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}
