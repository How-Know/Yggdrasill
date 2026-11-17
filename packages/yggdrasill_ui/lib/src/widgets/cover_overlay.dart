import 'package:flutter/material.dart';

import 'dialog_tokens.dart';

/// 표지(교재 표지·출력물·단색 배경) 위에 정보를 올리는 카드의 공통 규칙.
/// 규칙 설명: docs/design-system.md §5.1 "표지 오버레이 카드".
class CoverOverlayStyle {
  /// 어두운 표지 위 흰 글자면 true, 출력물·밝은 단색 표지 위 검은 글자면 false.
  final bool onDark;
  final bool hasImage;

  /// 채점 과제카드(기준 너비 288)의 글자 대비 비율. 1이면 제목 32·배지 17.
  final double typeScale;

  /// 배지 높이. 지정하면 [typeScale]을 곱하지 않는다.
  final double? pillHeightOverride;

  /// 배지 글자 크기. 지정하면 [typeScale]을 곱하지 않는다.
  final double? pillFontSizeOverride;

  const CoverOverlayStyle({
    required this.onDark,
    required this.hasImage,
    this.typeScale = 1,
    this.pillHeightOverride,
    this.pillFontSizeOverride,
  });

  static const double pillHeight = 32;
  static const double pillFontSize = 17;
  static const Color darkInk = Color(0xFF111418);
  static const String _fontFamily = 'Pretendard';

  /// 카드 가장자리 ↔ 정보 사이 여백. 카드 축소 시 10까지 줄어든다.
  static double padFor(double scale) =>
      (16.0 * scale).clamp(10.0, 16.0).toDouble();

  /// 같은 묶음 안 줄 사이 간격.
  /// 채점 과제카드의 페이지↔과제번호 배지는 여기에 2를 더한다.
  static double gapFor(double scale) =>
      (8.0 * scale).clamp(5.0, 8.0).toDouble();

  Color get ink => onDark ? Colors.white : darkInk;

  Color get inkSecondary => onDark
      ? Colors.white.withValues(alpha: 0.82)
      : darkInk.withValues(alpha: 0.64);

  List<Shadow> get textShadows => onDark
      ? <Shadow>[
          Shadow(
            color: Colors.black.withValues(alpha: hasImage ? 0.42 : 0.18),
            blurRadius: 10,
            offset: const Offset(0, 1),
          ),
        ]
      : const <Shadow>[];

  double get scaledPillFontSize =>
      pillFontSizeOverride ?? pillFontSize * typeScale;

  double get scaledPillHeight =>
      pillHeightOverride ?? pillHeight * typeScale;

  TextStyle get pillTextStyle => TextStyle(
        color: ink,
        fontSize: scaledPillFontSize,
        fontFamily: _fontFamily,
        fontWeight: FontWeight.w600,
        height: 1.0,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// 표지 위 큰 제목(학생 이름·교재명). 기준 32 w700 Pretendard.
  TextStyle titleStyle(BuildContext context) {
    final base = DefaultTextStyle.of(context).style;
    return base.copyWith(
      fontFamily: _fontFamily,
      fontWeight: FontWeight.w700,
      fontSize: 32 * typeScale,
      height: 1.15,
      color: ink,
      letterSpacing: -0.4 * typeScale,
      shadows: textShadows,
    );
  }
}

/// 상·하단 띠만 어둡게(밝은 표지는 밝게) 하는 스크림. 표지 중앙은 그대로 보인다.
class CoverScrim extends StatelessWidget {
  final CoverOverlayStyle style;

  /// 위쪽 띠가 끝나는 지점(0~1).
  final double topEnd;

  /// 아래쪽 띠가 시작하는 지점(0~1).
  final double bottomStart;

  /// 위쪽 띠. 채점 과제카드·정답책 카드는 끈 상태라, 되돌릴 때는 true로 둔다.
  final bool showTop;

  const CoverScrim({
    super.key,
    required this.style,
    this.topEnd = 0.40,
    this.bottomStart = 0.56,
    this.showTop = true,
  });

  @override
  Widget build(BuildContext context) {
    final color = style.onDark ? Colors.black : Colors.white;
    final top = style.onDark ? (style.hasImage ? 0.66 : 0.30) : 0.88;
    final bottom = style.onDark ? (style.hasImage ? 0.78 : 0.36) : 0.92;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: [0.0, topEnd, bottomStart, 1.0],
            colors: [
              color.withValues(alpha: showTop ? top : 0.0),
              color.withValues(alpha: 0.0),
              color.withValues(alpha: 0.0),
              color.withValues(alpha: bottom),
            ],
          ),
        ),
      ),
    );
  }
}

/// 표지 가장자리를 정리하는 안쪽 1px 선. 카드와 같은 반경을 넘긴다.
class CoverHairline extends StatelessWidget {
  final CoverOverlayStyle style;
  final double radius;

  const CoverHairline({super.key, required this.style, required this.radius});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: style.onDark
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.black.withValues(alpha: 0.08),
            width: 1,
          ),
        ),
      ),
    );
  }
}

enum CoverPillTone {
  /// 반투명 검정(밝은 표지에선 반투명 흰색) — 경과시간·과제번호·학년 등.
  neutral,

  /// 강조색 초록 — 숙제처럼 종류를 구분하는 배지.
  accent,
}

/// 표지 위 정보 배지. 높이 32 캡슐, 17pt Pretendard, 선택적 앞 아이콘.
class CoverPill extends StatelessWidget {
  final CoverOverlayStyle style;
  final String label;
  final CoverPillTone tone;

  /// 앞 아이콘. null이고 [tone]이 accent면 점(●)을 붙인다.
  final IconData? icon;

  /// 식별 코드처럼 또박또박 읽혀야 하는 값: 굵게 + 자간.
  final bool emphasize;

  /// 글자 길이에 맞춰 늘어난다. 칸이 좁아도 `…`로 줄이지 않는다.
  final bool shrinkWrap;

  /// 글자만큼만 차지하고, 칸이 좁으면 `…`로 줄인다.
  /// [shrinkWrap]이 켜져 있으면 그 동작을 따른다.
  final bool loose;

  /// 글자 굵기. 없으면 600, [emphasize]면 700.
  final FontWeight? fontWeight;

  /// 안쪽 여백. 없으면 배지 기본 여백(아이콘 있으면 왼쪽 10, 아니면 12, 오른쪽 12).
  final EdgeInsetsGeometry? padding;

  /// 높이를 고정하지 않고 글자와 여백이 높이를 정한다.
  final bool hugContent;

  /// 화면 글자 배율을 따른다. 끄면 배지는 항상 지정한 pt.
  final bool scaleText;

  const CoverPill({
    super.key,
    required this.style,
    required this.label,
    this.tone = CoverPillTone.neutral,
    this.icon,
    this.emphasize = false,
    this.shrinkWrap = false,
    this.loose = false,
    this.fontWeight,
    this.padding,
    this.hugContent = false,
    this.scaleText = false,
  });

  @override
  Widget build(BuildContext context) {
    final onDark = style.onDark;
    final isAccent = tone == CoverPillTone.accent;
    final Color fill;
    final Color border;
    final Color textColor;
    if (isAccent) {
      fill = onDark
          ? const Color(0xFF0F2A20).withValues(alpha: 0.88)
          : const Color(0xFFE8F6EF);
      border = kDlgAccent.withValues(alpha: onDark ? 0.60 : 0.45);
      textColor = onDark ? const Color(0xFF9FE3C6) : kDlgAccent;
    } else {
      fill = onDark
          ? Colors.black.withValues(alpha: 0.46)
          : Colors.white.withValues(alpha: 0.86);
      border = onDark
          ? Colors.white.withValues(alpha: 0.16)
          : Colors.black.withValues(alpha: 0.08);
      textColor = style.ink;
    }

    final scale = style.typeScale;
    final weight =
        fontWeight ?? (emphasize ? FontWeight.w700 : FontWeight.w600);
    Widget? leading;
    if (icon != null) {
      leading = Icon(
        icon,
        size: style.scaledPillFontSize,
        color: isAccent ? textColor : style.inkSecondary,
      );
    } else if (isAccent) {
      leading = Container(
        width: 7 * scale,
        height: 7 * scale,
        decoration: BoxDecoration(color: textColor, shape: BoxShape.circle),
      );
    }

    final textScaler = scaleText ? null : TextScaler.noScaling;
    return Container(
      height: hugContent ? null : style.scaledPillHeight,
      padding: padding ??
          EdgeInsets.fromLTRB(
            (leading == null ? 12 : 10) * scale,
            0,
            12 * scale,
            0,
          ),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[
            leading,
            SizedBox(width: 6 * scale),
          ],
          if (shrinkWrap)
            Text(
              label,
              maxLines: 1,
              softWrap: false,
              textScaler: textScaler,
              style: style.pillTextStyle.copyWith(
                color: textColor,
                fontWeight: weight,
                letterSpacing: emphasize ? 0.8 * scale : null,
              ),
            )
          else
            Flexible(
              fit: loose ? FlexFit.loose : FlexFit.tight,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textScaler: textScaler,
                style: style.pillTextStyle.copyWith(
                  color: textColor,
                  fontWeight: weight,
                  letterSpacing: emphasize ? 0.8 * scale : null,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
