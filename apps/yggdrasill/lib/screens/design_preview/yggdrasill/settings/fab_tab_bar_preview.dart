import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

/// FAB 스타일 탭바 색상·치수 토큰 (Preview 전용 — 본앱 미적용).
class FabTabBarTokens {
  const FabTabBarTokens._();

  /// Preview 학원 탭·FAB 탭 라벨 공통 기준 글자 크기
  static const double previewAcademyBaseFontSize = 16;

  static const double fabBarHeight = 56;
  /// [MainFabAlternative] + 버튼과 동일한 하단 여백
  /// (Scaffold FAB margin 16 + FAB 내부 `bottom` padding 16)
  static const double fabBarBottomInset = 32;

  /// [MainFabAlternative] + 버튼과 동일한 오른쪽 여백
  /// (Scaffold FAB margin 16 + FAB 내부 `right` padding 16)
  static const double fabBarRightInset = 32;

  /// 글래스 블러 강도 (값↑ 뒤 화면 전체가 더 흐려져 비침)
  static const double fabBarBlurSigma = 28.0;

  /// FAB 스타일 탭바·+ 버튼 라벨 — Preview 학원 탭 [previewAcademyBaseFontSize]와 동일
  static const double fabBarLabelFontSize = previewAcademyBaseFontSize;

  /// Preview — 학원정보 패널 배경 Dark (스크린샷 기준)
  static const Color previewAcademyInfoPanelDark = Color(0xFF121212);

  /// Preview — 학원정보 패널 배경 Light (스크린샷 기준)
  static const Color previewAcademyInfoPanelLight = Color(0xFFF2F2F6);

  static Color previewAcademyInfoPanelFor(Brightness brightness) {
    return brightness == Brightness.light
        ? previewAcademyInfoPanelLight
        : previewAcademyInfoPanelDark;
  }

  /// Preview — 학원 탭 상단 여백
  static const double previewAcademyTopInset = 24;

  /// Preview — 학원 탭 최상단 「학원정보」 제목 글자 크기
  static const double previewAcademyMainTitleFontSize = 32;

  /// Preview — 「학원정보」 제목 **밑변** ↔ 로고 **상단** 사이 고정 간격.
  ///
  /// 제목 줄 높이는 [previewAcademyMainTitleStyle] `height: 1.15` → 약 37px
  /// (32 × 1.15). 로고까지의 시각적 여백 = 이 값만큼.
  static const double previewAcademyMainTitleToLogoSpacing = 36;

  /// Preview — 학원 섹션 카드 라운드
  static const double previewAcademyGroupedCardRadius = 28;

  /// Preview — 그룹 카드 행 세로 패딩 (상·하 각각)
  static const double previewAcademyGroupedRowPaddingVertical = 26;

  /// Preview — 그룹 카드 리스트 **내부** 좌우 패딩 (행·디바이더 indent/endIndent)
  static const double previewAcademyGroupedRowPaddingHorizontal = 24;

  /// Preview — 섹션 scope 바깥 좌우 패딩 (`_buildPreviewAcademySectionScope`)
  /// 화면 가장자리 ↔ 카드 외곽 = 이 값. 카드 안 텍스트까지는 + [previewAcademyGroupedRowPaddingHorizontal].
  static const double previewAcademySectionScopePaddingHorizontal = 16;

  /// Preview — 학원 탭 섹션(그룹 카드·운영시간 등) 공통 최대 너비
  static const double previewAcademySectionMaxWidth = 813;

  /// Preview — 로고 ↔ 변경 버튼 간격
  static const double previewAcademyLogoToChangeSpacing = 24;

  /// Preview — 변경 버튼 제외, 그룹 카드(리스트) 사이 세로 간격
  static const double previewAcademySectionListSpacing = 40;

  /// Preview — iOS형 드롭다운·글래스 메뉴 라운드
  static const double previewAcademyMenuRadius = 28;

  /// Preview — 운영시간 요일 활성 스위치 (가로 pill, 기준 76 대비 −10%)
  static const double previewAcademySwitchWidth = 68.4;
  static const double previewAcademySwitchHeight = 28;
  static const double previewAcademySwitchInset = 2.5;

  /// Preview — 스위치 thumb 너비 배율 (기준 대비 +10%)
  static const double previewAcademySwitchThumbWidthScale = 1.1;

  /// Preview — 요일 활성 스위치 애니메이션
  static const Duration previewAcademySwitchDuration =
      Duration(milliseconds: 280);
  static const Curve previewAcademySwitchCurve = Curves.easeOutBack;

  /// Preview — 글래스 드롭다운 열림 애니메이션
  static const Duration previewAcademyMenuOpenDuration =
      Duration(milliseconds: 220);

  /// Preview — 글래스 드롭다운 닫힘 애니메이션 (열림보다 빠르게)
  static const Duration previewAcademyMenuCloseDuration =
      Duration(milliseconds: 90);

  /// Preview — 글래스 메뉴 틴트 (불투명도 90%)
  static const Color previewAcademyMenuGlassTintLight = Color(0xE6FFFFFF);
  static const Color previewAcademyMenuGlassTintDark = Color(0xE61C1C1E);

  /// Preview — 글래스 드롭다운 뒤 화면 흐림 (BackdropFilter)
  static const double previewAcademyMenuGlassBlurSigma = 18;
  static const Color previewAcademyMenuGlassHoverOverlayLight =
      Color(0x12FFFFFF);
  static const Color previewAcademyMenuGlassHoverOverlayDark =
      Color(0x12FFFFFF);

  /// Preview — 섹션 타이틀 줄 ↔ 아래 카드 간격 (타이틀 줄만 좁게)
  static const double previewAcademySectionHeaderToCardSpacing = 8;

  static const double previewAcademyChevronSize = 20;

  /// Preview — 확인·저장·변경 등 주요 액션 문구 색 (본앱 `_kSignatureGreen`과 동일)
  static const Color previewConfirmActionColor = Color(0xFF33A373);

  /// Preview — iOS형 입력 시트 (학원명 등)
  static const double previewAcademyInputSheetRadius = 34;
  /// 600 × 1.3
  static const double previewAcademyInputSheetMaxWidth = 780;
  static const double previewAcademyInputSheetMinHeight = 320;
  static const double previewAcademyInputSheetFieldLabelWidth = 72;

  /// 시트 바깥(화면 ↔ 시트 테두리) 좌·우
  static const double previewAcademyInputSheetOuterPaddingHorizontal = 24;

  /// 시트 테두리 ↔ 콘텐츠(헤더·입력 카드) 사이
  static const double previewAcademyInputSheetBorderInset = 4;

  /// [previewAcademyInputSheetBorderInset] 안쪽 — 헤더·본문 inner
  static const double previewAcademyInputSheetInnerPaddingTop = 12;
  static const double previewAcademyInputSheetInnerPaddingHorizontal = 16;
  static const double previewAcademyInputSheetInnerPaddingBottom = 20;

  /// 헤더 행 ↔ 입력 그룹 카드 (12 + 8)
  static const double previewAcademyInputSheetHeaderToFieldSpacing = 20;

  /// 입력 그룹 카드 안 — 카드 행 [previewAcademyGroupedRowPaddingHorizontal]과 동일
  static const double previewAcademyInputSheetFieldPaddingHorizontal = 24;

  /// 라벨 ↔ 입력란 가로 간격
  static const double previewAcademyInputSheetLabelToFieldSpacing = 32;

  /// 입력 행 한 줄 상·하 패딩 (각각)
  static const double previewAcademyInputSheetFieldRowPaddingVertical = 16;

  /// 학원 탭 카드 라벨 왼쪽 = scope(16) + 카드 행(24). 시트 inner(16) + 필드(24)와 동일.
  static const double previewAcademyInputSheetFieldInsetFromSheet =
      previewAcademySectionScopePaddingHorizontal +
      previewAcademyGroupedRowPaddingHorizontal;

  /// Preview — 학원 로고 (지름 180)
  static const double previewAcademyLogoDiameter = 180;
  static const double previewAcademyLogoRadius = 90;

  /// Preview — 학원 로고 플레이스홀더 아이콘 크기
  static const double previewAcademyLogoIconSize = 69;

  /// Preview — 「변경」 버튼 세로 패딩
  static const double previewAcademyChangeButtonPaddingVertical = 14;

  /// Preview — 학원정보 탭 Pretendard (`Pretendard-Bold.otf` 등록)
  static const String previewHeadlineFontFamily = 'Pretendard';
  static const FontWeight previewHeadlineFontWeight = FontWeight.w700;
  static const FontWeight previewAcademyRowLabelFontWeight = FontWeight.w400;

  static TextStyle previewPageTitleStyle(PreviewAcademyPanelStyle style) {
    return TextStyle(
      fontFamily: previewHeadlineFontFamily,
      fontWeight: previewHeadlineFontWeight,
      fontSize: previewAcademyBaseFontSize,
      color: style.title,
    );
  }

  /// Preview — 학원 탭 최상단 「학원정보」 전용 (32px).
  static TextStyle previewAcademyMainTitleStyle(PreviewAcademyPanelStyle style) {
    return TextStyle(
      fontFamily: previewHeadlineFontFamily,
      fontWeight: previewHeadlineFontWeight,
      fontSize: previewAcademyMainTitleFontSize,
      height: 1.15,
      color: style.title,
    );
  }

  static TextStyle previewInternalTitleStyle(PreviewAcademyPanelStyle style) {
    return TextStyle(
      fontFamily: previewHeadlineFontFamily,
      fontWeight: previewAcademyRowLabelFontWeight,
      fontSize: previewAcademyBaseFontSize,
      color: style.title,
    );
  }

  static TextStyle previewSectionTitleStyle(PreviewAcademyPanelStyle style) {
    return previewInternalTitleStyle(style);
  }

  static TextStyle previewRowLabelStyle(PreviewAcademyPanelStyle style) {
    return previewInternalTitleStyle(style);
  }

  static TextStyle previewRowValueStyle(PreviewAcademyPanelStyle style) {
    return TextStyle(
      color: style.rowValue,
      fontSize: previewAcademyBaseFontSize,
      fontWeight: FontWeight.w400,
    );
  }

  /// Preview — 카드 행 값/플레이스홀더 (학원정보·정원·지불방식 통일)
  static TextStyle previewAcademyFieldDisplayStyle(
    PreviewAcademyPanelStyle style, {
    required bool isEmpty,
  }) {
    return previewRowValueStyle(style).copyWith(
      color: isEmpty ? style.hint : style.rowValue,
    );
  }

  static TextStyle previewBodyTextStyle(
    PreviewAcademyPanelStyle style, {
    Color? color,
    FontWeight fontWeight = FontWeight.w400,
  }) {
    return TextStyle(
      fontFamily: previewHeadlineFontFamily,
      fontSize: previewAcademyBaseFontSize,
      fontWeight: fontWeight,
      color: color ?? style.inputText,
      decoration: TextDecoration.none,
      decorationThickness: 0,
    );
  }

  static TextStyle previewMenuItemTextStyle(PreviewAcademyPanelStyle style) {
    return previewBodyTextStyle(
      style,
      color: style.title,
    );
  }

  static PreviewAcademyPanelStyle previewAcademyPanelStyleFor(
    Brightness brightness,
  ) {
    return PreviewAcademyPanelStyle.forBrightness(brightness);
  }

  // Dark — 글래스: 배경색 인지와 뒤 콘텐츠 비침의 균형
  static const Color fabBarDarkBase = Color(0xFF212121);
  static const Color fabBarDarkSurface = Color(0x80212121);
  static const Color fabBarDarkHighlight = Color(0x9A383838);
  static const Color fabBarDarkLabelSelected = Color(0xFFF4F5F5);
  static const Color fabBarDarkLabelUnselected = Color(0xFF9AA0A0);

  // Light — 글래스: 배경색 인지와 뒤 콘텐츠 비침의 균형
  static const Color fabBarLightBase = Color(0xFFFFFFFF);
  static const Color fabBarLightSurface = Color(0x80FFFFFF);
  static const Color fabBarLightHighlight = Color(0x99E6E6E6);
  static const Color fabBarLightLabelSelected = Color(0xFF000000);
  static const Color fabBarLightLabelUnselected = Color(0xFF6B6B6B);

  static FabTabBarPalette paletteFor(Brightness brightness) {
    if (brightness == Brightness.light) {
      return const FabTabBarPalette(
        surface: fabBarLightSurface,
        highlight: fabBarLightHighlight,
        labelSelected: fabBarLightLabelSelected,
        labelUnselected: fabBarLightLabelUnselected,
        boxShadows: [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 24,
            offset: Offset(0, 8),
            spreadRadius: 0,
          ),
          BoxShadow(
            color: Color(0x1F000000),
            blurRadius: 10,
            offset: Offset(0, 2),
            spreadRadius: 0,
          ),
        ],
      );
    }
    return const FabTabBarPalette(
      surface: fabBarDarkSurface,
      highlight: fabBarDarkHighlight,
      labelSelected: fabBarDarkLabelSelected,
      labelUnselected: fabBarDarkLabelUnselected,
      boxShadows: [],
    );
  }
}

/// Preview — 학원정보 패널 내 문구·입력 필드 색 (Light/Dark).
@immutable
class PreviewAcademyPanelStyle {
  final Color title;
  final Color hint;
  final Color inputText;
  final Color label;
  final Color border;
  final Color dropdownBackground;
  final Color icon;
  final Color avatarPlaceholderBackground;
  final Color avatarPlaceholderIcon;
  final Color groupedCardBackground;
  final Color rowValue;
  final Color chevron;
  final Color divider;
  final Color changeButtonBackground;
  final Color changeButtonText;

  const PreviewAcademyPanelStyle({
    required this.title,
    required this.hint,
    required this.inputText,
    required this.label,
    required this.border,
    required this.dropdownBackground,
    required this.icon,
    required this.avatarPlaceholderBackground,
    required this.avatarPlaceholderIcon,
    required this.groupedCardBackground,
    required this.rowValue,
    required this.chevron,
    required this.divider,
    required this.changeButtonBackground,
    required this.changeButtonText,
  });

  factory PreviewAcademyPanelStyle.forBrightness(Brightness brightness) {
    if (brightness == Brightness.light) {
      return const PreviewAcademyPanelStyle(
        title: Color(0xFF000000),
        hint: Color(0xFF6B6B6B),
        inputText: Color(0xFF000000),
        label: Color(0xFF6B6B6B),
        border: Color(0x4D000000),
        dropdownBackground: Color(0xFFFFFFFF),
        icon: Color(0xFF6B6B6B),
        avatarPlaceholderBackground: Color(0xFFE0E0E0),
        avatarPlaceholderIcon: Color(0xFF9E9E9E),
        groupedCardBackground: FabTabBarTokens.previewAcademyInfoPanelLight,
        rowValue: Color(0xFF8E8E93),
        chevron: Color(0xFFC7C7CC),
        divider: Color(0xFFE5E5EA),
        changeButtonBackground: Color(0xFFEAF3FF),
        changeButtonText: FabTabBarTokens.previewConfirmActionColor,
      );
    }
    return const PreviewAcademyPanelStyle(
      title: Color(0xFFFFFFFF),
      hint: Color(0xB3FFFFFF),
      inputText: Color(0xFFFFFFFF),
      label: Color(0xB3FFFFFF),
      border: Color(0x4DFFFFFF),
      dropdownBackground: Color(0xFF1F1F1F),
      icon: Color(0xB3FFFFFF),
      avatarPlaceholderBackground: Color(0xFF424242),
      avatarPlaceholderIcon: Color(0x8AFFFFFF),
      groupedCardBackground: FabTabBarTokens.previewAcademyInfoPanelDark,
      rowValue: Color(0xFF8E8E93),
      chevron: Color(0xFF636366),
      divider: Color(0xFF38383A),
      changeButtonBackground: Color(0xFF2C2C2E),
      changeButtonText: FabTabBarTokens.previewConfirmActionColor,
    );
  }

  InputDecoration inputDecoration(String labelText) {
    return InputDecoration(
      labelText: labelText,
      labelStyle: TextStyle(color: label),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: Color(0xFF33A373)),
      ),
    );
  }

  InputDecoration dropdownDecoration() {
    return InputDecoration(
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: Color(0xFF33A373)),
      ),
    );
  }
}

@immutable
class FabTabBarPalette {
  final Color surface;
  final Color highlight;
  final Color labelSelected;
  final Color labelUnselected;
  final List<BoxShadow> boxShadows;

  const FabTabBarPalette({
    required this.surface,
    required this.highlight,
    required this.labelSelected,
    required this.labelUnselected,
    required this.boxShadows,
  });
}

/// Preview — 학원명/주소/슬로건 iOS형 그룹 카드 한 줄.
class PreviewAcademyInfoRow {
  final String label;
  final String value;
  final String? emptyPlaceholder;
  final Widget? valueWidget;
  final Widget? trailing;
  final bool showChevron;
  final bool suppressInkHighlight;
  /// `trailing`이 chevron(20px)과 같은 열에 올 때 값 텍스트 오른쪽을 맞춤.
  final bool trailingAlignsWithChevron;
  /// 값이 있어도 [style.hint] 색으로 표시 (미입력·월결제 등).
  final bool valueUsesHintStyle;
  final VoidCallback? onTap;

  const PreviewAcademyInfoRow({
    required this.label,
    this.value = '',
    this.emptyPlaceholder,
    this.valueWidget,
    this.trailing,
    this.showChevron = true,
    this.suppressInkHighlight = false,
    this.trailingAlignsWithChevron = false,
    this.valueUsesHintStyle = false,
    this.onTap,
  });
}

/// Preview — 학원명·학원주소·슬로건 묶음 카드 (스크린샷 설정 앱형).
class PreviewAcademyGroupedFieldsCard extends StatelessWidget {
  final PreviewAcademyPanelStyle style;
  final List<PreviewAcademyInfoRow> rows;

  const PreviewAcademyGroupedFieldsCard({
    super.key,
    required this.style,
    required this.rows,
  });

  static BoxDecoration cardDecoration(PreviewAcademyPanelStyle style) {
    return BoxDecoration(
      color: style.groupedCardBackground,
      borderRadius: BorderRadius.circular(
        FabTabBarTokens.previewAcademyGroupedCardRadius,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: cardDecoration(style),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal,
                endIndent:
                    FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal,
                color: style.divider,
              ),
            Builder(
              builder: (context) {
                final row = rows[i];
                final valueIsEmpty = row.value.isEmpty;
                final valueTextStyle = FabTabBarTokens.previewAcademyFieldDisplayStyle(
                  style,
                  isEmpty: row.valueUsesHintStyle || valueIsEmpty,
                );
                final Widget valueArea;
                if (row.valueWidget != null && row.value.isEmpty) {
                  valueArea = row.valueWidget!;
                } else {
                  valueArea = Text(
                    valueIsEmpty
                        ? (row.emptyPlaceholder ?? '미입력')
                        : row.value,
                    textAlign: TextAlign.right,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: valueTextStyle,
                  );
                }

                final inlineTrailing =
                    row.trailing != null && row.trailingAlignsWithChevron;

                final rowContent = Row(
                  children: [
                    Text(
                      row.label,
                      style: FabTabBarTokens.previewRowLabelStyle(style),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: valueArea,
                      ),
                    ),
                    if (inlineTrailing) ...[
                      const SizedBox(width: 4),
                      row.trailing!,
                    ] else if (row.trailing == null && row.showChevron) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.chevron_right,
                        size: FabTabBarTokens.previewAcademyChevronSize,
                        color: style.chevron,
                      ),
                    ],
                  ],
                );

                Widget wrapTapTarget(Widget child) {
                  if (row.onTap == null) return child;
                  if (row.suppressInkHighlight) {
                    return MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: row.onTap,
                        behavior: HitTestBehavior.opaque,
                        child: child,
                      ),
                    );
                  }
                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: row.onTap,
                      child: child,
                    ),
                  );
                }

                if (row.trailing == null || inlineTrailing) {
                  return wrapTapTarget(
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: FabTabBarTokens
                            .previewAcademyGroupedRowPaddingHorizontal,
                        vertical: FabTabBarTokens
                            .previewAcademyGroupedRowPaddingVertical,
                      ),
                      child: rowContent,
                    ),
                  );
                }

                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FabTabBarTokens
                        .previewAcademyGroupedRowPaddingHorizontal,
                    vertical: FabTabBarTokens
                        .previewAcademyGroupedRowPaddingVertical,
                  ),
                  child: Row(
                    children: [
                      Expanded(child: wrapTapTarget(rowContent)),
                      SizedBox(
                        width: row.trailingAlignsWithChevron ? 4 : 8,
                      ),
                      row.trailing!,
                    ],
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// Preview — 스크린샷 기준 가로 pill 커스텀 스위치 (요일 활성 on/off).
class PreviewAcademyIosSwitch extends StatefulWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color activeColor;
  final Color inactiveColor;

  const PreviewAcademyIosSwitch({
    super.key,
    required this.value,
    this.onChanged,
    this.activeColor = FabTabBarTokens.previewConfirmActionColor,
    this.inactiveColor = const Color(0xFFE5E5EA),
  });

  @override
  State<PreviewAcademyIosSwitch> createState() => _PreviewAcademyIosSwitchState();
}

class _PreviewAcademyIosSwitchState extends State<PreviewAcademyIosSwitch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _position;

  static const _trackWidth = FabTabBarTokens.previewAcademySwitchWidth;
  static const _trackHeight = FabTabBarTokens.previewAcademySwitchHeight;
  static const _inset = FabTabBarTokens.previewAcademySwitchInset;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: FabTabBarTokens.previewAcademySwitchDuration,
    );
    _position = CurvedAnimation(
      parent: _controller,
      curve: FabTabBarTokens.previewAcademySwitchCurve,
      reverseCurve: Curves.easeInCubic,
    );
    _controller.value = widget.value ? 1.0 : 0.0;
  }

  void _animateTo(bool on) {
    if (on) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void didUpdateWidget(PreviewAcademyIosSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value == widget.value) return;
    final target = widget.value ? 1.0 : 0.0;
    if ((_controller.value - target).abs() > 0.01) {
      _animateTo(widget.value);
    }
  }

  void _handleTap() {
    if (widget.onChanged == null) return;
    final next = !widget.value;
    _animateTo(next);
    widget.onChanged!(next);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseThumbWidth = (_trackWidth - _inset * 2) / 2 - 1;
    final thumbWidth =
        baseThumbWidth * FabTabBarTokens.previewAcademySwitchThumbWidthScale;
    final thumbHeight = _trackHeight - _inset * 2;
    final thumbRadius = thumbHeight / 2;
    final thumbTravel = _trackWidth - thumbWidth - _inset * 2;

    return GestureDetector(
      onTap: widget.onChanged == null ? null : _handleTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: _trackWidth,
        height: _trackHeight,
        child: AnimatedBuilder(
          animation: _position,
          builder: (context, child) {
            final t = _position.value;
            final trackColor =
                Color.lerp(widget.inactiveColor, widget.activeColor, t)!;

            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(_trackHeight / 2),
                      color: trackColor,
                    ),
                  ),
                ),
                Positioned(
                  left: _inset + thumbTravel * t,
                  top: _inset,
                  width: thumbWidth,
                  height: thumbHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(thumbRadius),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// iOS형 메뉴 펼침 — 접힌 높이에서 아래로 펼쳐지는 효과.
class _PreviewAcademyGlassMenuTransition extends StatelessWidget {
  final Animation<double> animation;
  final Widget child;

  const _PreviewAcademyGlassMenuTransition({
    required this.animation,
    required this.child,
  });

  static const _openCurve = Cubic(0.16, 1.0, 0.3, 1.0);
  static const _closeCurve = Cubic(0.55, 0.0, 1.0, 1.0);

  double _easedProgress(Animation<double> anim) {
    if (anim.status == AnimationStatus.reverse) {
      return _closeCurve.transform(anim.value);
    }
    return _openCurve.transform(anim.value);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = _easedProgress(animation);
        final heightFactor = 0.08 + 0.92 * t;
        final scaleX = 0.96 + 0.04 * t;
        final slideY = (1 - t) * -6;

        return ClipRRect(
          borderRadius: BorderRadius.circular(
            FabTabBarTokens.previewAcademyMenuRadius,
          ),
          clipBehavior: Clip.antiAlias,
          child: Align(
            alignment: Alignment.topRight,
            heightFactor: heightFactor,
            child: Transform.translate(
              offset: Offset(0, slideY),
              child: Transform.scale(
                scaleX: scaleX,
                scaleY: 1,
                alignment: Alignment.topRight,
                filterQuality: FilterQuality.high,
                child: child,
              ),
            ),
          ),
        );
      },
      child: child,
    );
  }
}

/// Preview — 글래스 메뉴 패널 (고정 틴트 + 콘텐츠, 호버는 은은한 오버레이만).
class _PreviewAcademyGlassMenuPanel extends StatefulWidget {
  final PreviewAcademyPanelStyle style;
  final String selectedId;
  final List<PreviewAcademyMenuOption> options;
  final ValueChanged<String> onOptionSelected;

  const _PreviewAcademyGlassMenuPanel({
    required this.style,
    required this.selectedId,
    required this.options,
    required this.onOptionSelected,
  });

  @override
  State<_PreviewAcademyGlassMenuPanel> createState() =>
      _PreviewAcademyGlassMenuPanelState();
}

class _PreviewAcademyGlassMenuPanelState
    extends State<_PreviewAcademyGlassMenuPanel> {
  int? _hoveredIndex;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = FabTabBarTokens.previewAcademyMenuRadius;
    final glassTint = isDark
        ? FabTabBarTokens.previewAcademyMenuGlassTintDark
        : FabTabBarTokens.previewAcademyMenuGlassTintLight;
    final hoverOverlay = isDark
        ? FabTabBarTokens.previewAcademyMenuGlassHoverOverlayDark
        : FabTabBarTokens.previewAcademyMenuGlassHoverOverlayLight;

    return Material(
      type: MaterialType.transparency,
      color: Colors.transparent,
      child: DefaultTextStyle(
        style: const TextStyle(
          decoration: TextDecoration.none,
          decorationColor: Colors.transparent,
        ),
        child: RepaintBoundary(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(
                color: isDark
                    ? const Color(0x33FFFFFF)
                    : const Color(0x40FFFFFF),
                width: 0.5,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x1A000000),
                  blurRadius: 20,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.passthrough,
                children: [
                  Positioned.fill(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(
                        sigmaX: FabTabBarTokens.previewAcademyMenuGlassBlurSigma,
                        sigmaY: FabTabBarTokens.previewAcademyMenuGlassBlurSigma,
                      ),
                      child: const ColoredBox(color: Colors.transparent),
                    ),
                  ),
                  ColoredBox(
                    color: glassTint,
                    child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (int i = 0; i < widget.options.length; i++)
                        MouseRegion(
                          onEnter: (_) => setState(() => _hoveredIndex = i),
                          onExit: (_) => setState(() => _hoveredIndex = null),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => widget
                                .onOptionSelected(widget.options[i].id),
                            child: ColoredBox(
                              color: _hoveredIndex == i
                                  ? hoverOverlay
                                  : Colors.transparent,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 14,
                                ),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 28,
                                      child: widget.options[i].id ==
                                              widget.selectedId
                                          ? Icon(
                                              Icons.check,
                                              size: FabTabBarTokens
                                                  .previewAcademyBaseFontSize,
                                              color: widget.style.title,
                                            )
                                          : null,
                                    ),
                                    Expanded(
                                      child: Text(
                                        widget.options[i].label,
                                        style: FabTabBarTokens
                                            .previewMenuItemTextStyle(
                                          widget.style,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Preview — 기본 정보 입력 시트에서 포커스할 필드.
enum PreviewAcademyBasicInfoField {
  academyName,
  academyAddress,
  slogan,
}

/// Preview — 학원명·주소·슬로건 입력 시트 결과.
class PreviewAcademyBasicInfoValues {
  final String academyName;
  final String academyAddress;
  final String slogan;

  const PreviewAcademyBasicInfoValues({
    required this.academyName,
    required this.academyAddress,
    required this.slogan,
  });
}

/// Preview — iOS형 기본 정보 입력 시트 (학원명·주소·슬로건).
class PreviewAcademyFieldInputSheet extends StatefulWidget {
  final PreviewAcademyPanelStyle style;
  final String title;
  final PreviewAcademyBasicInfoValues initialValues;
  final PreviewAcademyBasicInfoField initialFocusField;

  const PreviewAcademyFieldInputSheet({
    super.key,
    required this.style,
    required this.title,
    required this.initialValues,
    this.initialFocusField = PreviewAcademyBasicInfoField.academyName,
  });

  static Future<PreviewAcademyBasicInfoValues?> show({
    required BuildContext context,
    required PreviewAcademyPanelStyle style,
    String title = '학원정보',
    required PreviewAcademyBasicInfoValues initialValues,
    PreviewAcademyBasicInfoField initialFocusField =
        PreviewAcademyBasicInfoField.academyName,
  }) {
    return showGeneralDialog<PreviewAcademyBasicInfoValues>(
      context: context,
      barrierDismissible: true,
      barrierLabel: title,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, animation, secondaryAnimation) {
        return PreviewAcademyFieldInputSheet(
          style: style,
          title: title,
          initialValues: initialValues,
          initialFocusField: initialFocusField,
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curve = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curve,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1).animate(curve),
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<PreviewAcademyFieldInputSheet> createState() =>
      _PreviewAcademyFieldInputSheetState();
}

class _PreviewAcademyFieldInputSheetState
    extends State<PreviewAcademyFieldInputSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _sloganController;
  late final FocusNode _nameFocusNode;
  late final FocusNode _addressFocusNode;
  late final FocusNode _sloganFocusNode;

  static const _fieldLabels = ['학원명', '학원주소', '슬로건'];

  @override
  void initState() {
    super.initState();
    _nameController =
        TextEditingController(text: widget.initialValues.academyName);
    _addressController =
        TextEditingController(text: widget.initialValues.academyAddress);
    _sloganController =
        TextEditingController(text: widget.initialValues.slogan);
    _nameFocusNode = FocusNode();
    _addressFocusNode = FocusNode();
    _sloganFocusNode = FocusNode();
    for (final c in [_nameController, _addressController, _sloganController]) {
      c.addListener(_onFieldChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final focusNode = switch (widget.initialFocusField) {
        PreviewAcademyBasicInfoField.academyName => _nameFocusNode,
        PreviewAcademyBasicInfoField.academyAddress => _addressFocusNode,
        PreviewAcademyBasicInfoField.slogan => _sloganFocusNode,
      };
      focusNode.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final fieldContext = focusNode.context;
        if (fieldContext != null) {
          Scrollable.ensureVisible(
            fieldContext,
            alignment: 0.25,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
          );
        }
      });
    });
  }

  void _onFieldChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [_nameController, _addressController, _sloganController]) {
      c.removeListener(_onFieldChanged);
      c.dispose();
    }
    _nameFocusNode.dispose();
    _addressFocusNode.dispose();
    _sloganFocusNode.dispose();
    super.dispose();
  }

  void _close([PreviewAcademyBasicInfoValues? values]) {
    Navigator.of(context).pop(values);
  }

  void _confirm() {
    _close(
      PreviewAcademyBasicInfoValues(
        academyName: _nameController.text.trim(),
        academyAddress: _addressController.text.trim(),
        slogan: _sloganController.text.trim(),
      ),
    );
  }

  Widget _buildFieldRow({
    required String label,
    required TextEditingController controller,
    FocusNode? focusNode,
    required TextInputAction textInputAction,
    required VoidCallback? onSubmitted,
  }) {
    final hintStyle = FabTabBarTokens.previewAcademyFieldDisplayStyle(
      widget.style,
      isEmpty: true,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal:
            FabTabBarTokens.previewAcademyInputSheetFieldPaddingHorizontal,
        vertical:
            FabTabBarTokens.previewAcademyInputSheetFieldRowPaddingVertical,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: FabTabBarTokens.previewAcademyInputSheetFieldLabelWidth,
            child: Text(
              label,
              style: FabTabBarTokens.previewRowLabelStyle(widget.style),
            ),
          ),
          const SizedBox(
            width: FabTabBarTokens.previewAcademyInputSheetLabelToFieldSpacing,
          ),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              style: FabTabBarTokens.previewBodyTextStyle(
                widget.style,
                color: widget.style.inputText,
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText:
                    controller.text.trim().isEmpty ? '필수입력' : null,
                hintStyle: hintStyle,
              ),
              textInputAction: textInputAction,
              onSubmitted: (_) => onSubmitted?.call(),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetSurface =
        isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
    final groupedFill =
        isDark ? const Color(0xFF2C2C2E) : Colors.white;
    final headerIconBg =
        isDark ? const Color(0xFF3A3A3C) : const Color(0xFFE5E5EA);
    final subtleBorder = isDark
        ? const Color(0x33FFFFFF)
        : const Color(0x33000000);

    final controllers = [_nameController, _addressController, _sloganController];
    final focusNodes = [_nameFocusNode, _addressFocusNode, _sloganFocusNode];
    final submitActions = <VoidCallback?>[
      _addressFocusNode.requestFocus,
      _sloganFocusNode.requestFocus,
      _confirm,
    ];

    return Material(
      type: MaterialType.transparency,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: FabTabBarTokens.previewAcademyInputSheetMaxWidth,
            minHeight: FabTabBarTokens.previewAcademyInputSheetMinHeight,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal:
                  FabTabBarTokens.previewAcademyInputSheetOuterPaddingHorizontal,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: sheetSurface,
                borderRadius: BorderRadius.circular(
                  FabTabBarTokens.previewAcademyInputSheetRadius,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 32,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(
                  FabTabBarTokens.previewAcademyInputSheetBorderInset,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    FabTabBarTokens.previewAcademyInputSheetInnerPaddingHorizontal,
                    FabTabBarTokens.previewAcademyInputSheetInnerPaddingTop,
                    FabTabBarTokens.previewAcademyInputSheetInnerPaddingHorizontal,
                    FabTabBarTokens.previewAcademyInputSheetInnerPaddingBottom,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: 44,
                        child: Row(
                          children: [
                            _PreviewAcademyInputSheetIconButton(
                              backgroundColor: headerIconBg,
                              borderColor: subtleBorder,
                              icon: Icons.close,
                              iconColor: widget.style.title,
                              onPressed: () => _close(),
                            ),
                            Expanded(
                              child: Text(
                                widget.title,
                                textAlign: TextAlign.center,
                                style: FabTabBarTokens.previewPageTitleStyle(
                                  widget.style,
                                ).copyWith(fontWeight: FontWeight.w600),
                              ),
                            ),
                            _PreviewAcademyInputSheetConfirmPill(
                              borderColor: subtleBorder,
                              onPressed: _confirm,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(
                        height: FabTabBarTokens
                            .previewAcademyInputSheetHeaderToFieldSpacing,
                      ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: groupedFill,
                          borderRadius: BorderRadius.circular(
                            FabTabBarTokens.previewAcademyGroupedCardRadius,
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (int i = 0; i < _fieldLabels.length; i++) ...[
                              if (i > 0)
                                Divider(
                                  height: 1,
                                  thickness: 1,
                                  indent: FabTabBarTokens
                                      .previewAcademyInputSheetFieldPaddingHorizontal,
                                  endIndent: FabTabBarTokens
                                      .previewAcademyInputSheetFieldPaddingHorizontal,
                                  color: widget.style.divider,
                                ),
                              _buildFieldRow(
                                label: _fieldLabels[i],
                                controller: controllers[i],
                                focusNode: focusNodes[i],
                                textInputAction: i < _fieldLabels.length - 1
                                    ? TextInputAction.next
                                    : TextInputAction.done,
                                onSubmitted: submitActions[i],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewAcademyInputSheetIconButton extends StatelessWidget {
  final Color backgroundColor;
  final Color borderColor;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onPressed;

  const _PreviewAcademyInputSheetIconButton({
    required this.backgroundColor,
    required this.borderColor,
    required this.icon,
    required this.iconColor,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: backgroundColor,
        border: Border.all(color: borderColor, width: 0.5),
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(icon, size: 20, color: iconColor),
          ),
        ),
      ),
    );
  }
}

class _PreviewAcademyInputSheetConfirmPill extends StatelessWidget {
  final Color borderColor;
  final VoidCallback onPressed;

  const _PreviewAcademyInputSheetConfirmPill({
    required this.borderColor,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: FabTabBarTokens.previewConfirmActionColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor, width: 0.5),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(999),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            child: Icon(
              Icons.check,
              size: 22,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// Preview — 지불 방식 메뉴 앵커(위·아래 화살표). 행 전체 탭은 [PreviewAcademyInfoRow.onTap].
class PreviewAcademyPaymentMenuAnchor extends StatelessWidget {
  final PreviewAcademyPanelStyle style;

  const PreviewAcademyPaymentMenuAnchor({
    super.key,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: FabTabBarTokens.previewAcademyChevronSize,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.keyboard_arrow_up,
            size: 14,
            color: style.chevron,
          ),
          Icon(
            Icons.keyboard_arrow_down,
            size: 14,
            color: style.chevron,
          ),
        ],
      ),
    );
  }
}

/// Preview — 루트 오버레이 + 분리된 배리어/메뉴 레이어.
class _PreviewAcademyGlassMenuOverlay extends StatefulWidget {
  final double left;
  final double top;
  final double menuWidth;
  final PreviewAcademyPanelStyle style;
  final String selectedId;
  final List<PreviewAcademyMenuOption> options;
  final ValueChanged<String?> onClosed;

  const _PreviewAcademyGlassMenuOverlay({
    required this.left,
    required this.top,
    required this.menuWidth,
    required this.style,
    required this.selectedId,
    required this.options,
    required this.onClosed,
  });

  @override
  State<_PreviewAcademyGlassMenuOverlay> createState() =>
      _PreviewAcademyGlassMenuOverlayState();
}

class _PreviewAcademyGlassMenuOverlayState
    extends State<_PreviewAcademyGlassMenuOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _isClosing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: FabTabBarTokens.previewAcademyMenuOpenDuration,
      reverseDuration: FabTabBarTokens.previewAcademyMenuCloseDuration,
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _close([String? result]) async {
    if (_isClosing) return;
    _isClosing = true;
    await _controller.reverse();
    if (mounted) {
      widget.onClosed(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final barrierOpacity =
        Curves.easeOut.transform(_controller.value.clamp(0.0, 1.0));

    return Material(
      type: MaterialType.transparency,
      color: Colors.transparent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _close(),
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.22 * barrierOpacity),
              ),
            ),
          ),
          Positioned(
            left: widget.left,
            top: widget.top,
            width: widget.menuWidth,
            child: _PreviewAcademyGlassMenuTransition(
              animation: _controller,
              child: _PreviewAcademyGlassMenuPanel(
                style: widget.style,
                selectedId: widget.selectedId,
                options: widget.options,
                onOptionSelected: (id) => _close(id),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Preview — iOS 글래스 드롭다운 메뉴.
class PreviewAcademyGlassMenu {
  PreviewAcademyGlassMenu._();

  static Future<String?> show({
    required BuildContext context,
    required RenderBox anchor,
    required PreviewAcademyPanelStyle style,
    required String selectedId,
    required List<PreviewAcademyMenuOption> options,
  }) {
    final anchorBottomRight =
        anchor.localToGlobal(anchor.size.bottomRight(Offset.zero));
    final screenSize = MediaQuery.sizeOf(context);
    const menuWidth = 240.0;
    final top = anchorBottomRight.dy + 6;
    final left = (anchorBottomRight.dx - menuWidth)
        .clamp(8.0, screenSize.width - menuWidth - 8);

    final overlay = Overlay.of(context, rootOverlay: true);
    final completer = Completer<String?>();
    late final OverlayEntry entry;

    void removeEntry() {
      entry.remove();
      entry.dispose();
    }

    entry = OverlayEntry(
      builder: (overlayContext) => _PreviewAcademyGlassMenuOverlay(
        left: left,
        top: top,
        menuWidth: menuWidth,
        style: style,
        selectedId: selectedId,
        options: options,
        onClosed: (result) {
          removeEntry();
          if (!completer.isCompleted) {
            completer.complete(result);
          }
        },
      ),
    );

    overlay.insert(entry);
    return completer.future;
  }
}

class PreviewAcademyMenuOption {
  final String id;
  final String label;

  const PreviewAcademyMenuOption({
    required this.id,
    required this.label,
  });
}

/// 화면 하단 가운데 FAB 스타일 글래스 탭 셀렉터 (Preview 전용).
///
/// [Theme.of(context).brightness]에 따라 Dark/Light 팔레트를 자동 전환한다.
class FabStyleTabBar extends StatelessWidget {
  final int selectedIndex;
  final List<String> tabs;
  final ValueChanged<int> onTabSelected;
  final double height;
  final double fontSize;
  final double tabWidth;
  final double padding;

  const FabStyleTabBar({
    super.key,
    required this.selectedIndex,
    required this.tabs,
    required this.onTabSelected,
    this.height = FabTabBarTokens.fabBarHeight,
    this.fontSize = FabTabBarTokens.fabBarLabelFontSize,
    this.tabWidth = 96,
    this.padding = 6,
  });

  @override
  Widget build(BuildContext context) {
    final palette = FabTabBarTokens.paletteFor(Theme.of(context).brightness);
    final double radius = height / 2;
    final double innerHeight = (height - padding * 2).clamp(0.0, 9999.0);
    final double slotWidth = tabWidth;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: palette.boxShadows,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: FabTabBarTokens.fabBarBlurSigma,
            sigmaY: FabTabBarTokens.fabBarBlurSigma,
          ),
          child: Container(
            height: height,
            padding: EdgeInsets.all(padding),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: SizedBox(
            width: slotWidth * tabs.length,
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  left: selectedIndex * slotWidth,
                  top: 0,
                  bottom: 0,
                  width: slotWidth,
                  child: Container(
                    decoration: BoxDecoration(
                      color: palette.highlight,
                      borderRadius: BorderRadius.circular(innerHeight / 2),
                    ),
                  ),
                ),
                Row(
                  children: tabs.asMap().entries.map((entry) {
                    final index = entry.key;
                    final label = entry.value;
                    final isSelected = selectedIndex == index;
                    return GestureDetector(
                      onTap: () => onTabSelected(index),
                      behavior: HitTestBehavior.opaque,
                      child: SizedBox(
                        width: slotWidth,
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 200),
                            style: TextStyle(
                              color: isSelected
                                  ? palette.labelSelected
                                  : palette.labelUnselected,
                              fontWeight: FontWeight.w600,
                              fontSize: fontSize,
                            ),
                            child: Text(label),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    );
  }
}

/// 탭바와 동일한 글래스 스타일 원형 + 버튼 (Preview 전용).
class FabStyleActionButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final double size;
  final IconData icon;

  const FabStyleActionButton({
    super.key,
    this.onPressed,
    this.size = FabTabBarTokens.fabBarHeight,
    this.icon = Icons.add,
  });

  @override
  Widget build(BuildContext context) {
    final palette = FabTabBarTokens.paletteFor(Theme.of(context).brightness);

    return GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: palette.boxShadows,
        ),
        child: ClipOval(
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: FabTabBarTokens.fabBarBlurSigma,
              sigmaY: FabTabBarTokens.fabBarBlurSigma,
            ),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: palette.surface,
              ),
              child: Icon(
                icon,
                size: FabTabBarTokens.previewAcademyBaseFontSize + 8,
                color: palette.labelSelected,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
